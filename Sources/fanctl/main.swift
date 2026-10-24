import FanControl
import Foundation

// fanctl : outil d'aide de Oriel qui écrit le mode des ventilateurs dans le SMC. Installé par l'app dans
// /Library/PrivilegedHelperTools (root:wheel 0755) et lancé par `sudo -n` grâce à une règle sudoers qui
// n'autorise que lui. Deux usages seulement :
//
//   fanctl auto   rend tous les ventilateurs à macOS, puis s'arrête.
//   fanctl hold   tient une vitesse fixe tant que l'app lui parle (protocole dans FanHold.swift) ; à la fin de
//                 l'entrée, au bout du bail, au-delà du seuil de température ou sur un signal : automatique.

setvbuf(stdout, nil, _IOLBF, 0)
let arguments = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data("fanctl : \(message)\n".utf8))
    exit(code)
}

guard arguments == ["auto"] || arguments == ["hold"] else { fail("usage : fanctl auto | fanctl hold", 64) }
guard geteuid() == 0 else { fail("droits root requis", 77) }
guard let smc = SMCConnection() else { fail("SMC inaccessible", 69) }

if arguments == ["auto"] {
    exit(Fans.setAutomatic(smc) ? 0 : 1)
}

/// Horloge monotone qui avance aussi pendant la veille : un bail ne survit pas à une nuit de sommeil.
func now() -> Double { Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9 }

let hold = FanHold(smc: smc, now: now())
guard !hold.fans.isEmpty else { fail("aucun ventilateur pilotable", 1) }
let thermals = Thermals(smc: smc)
_ = thermals.read() // cherche les sondes avant la première ligne de l'app

func finish(_ line: String) -> Never {
    print(line)
    exit(0)
}

// Les signaux d'arrêt passent par la file principale : retour en automatique, puis fin.
signal(SIGPIPE, SIG_IGN)
let signalSources = [SIGTERM, SIGINT, SIGHUP, SIGQUIT].map { number -> DispatchSourceSignal in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler { finish(hold.end(.signal)) }
    source.resume()
    return source
}

Thread {
    while let line = readLine(strippingNewline: true) {
        DispatchQueue.main.async {
            let reply = hold.receive(line, now: now())
            if hold.ending != nil { finish(reply) }
            print(reply)
        }
    }
    DispatchQueue.main.async { finish(hold.end(.closed)) }
}.start()

let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(200))
timer.setEventHandler {
    if let line = hold.tick(now: now(), hottest: thermals.read().hottest) { finish(line) }
}
timer.resume()
withExtendedLifetime(signalSources) { dispatchMain() }
