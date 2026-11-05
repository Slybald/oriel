import XCTest
@testable import Oriel

/// Source à la main : jamais de vrai micro ni de vraie caméra.
final class FakeCaptureSource: CaptureSource {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var onChange: (([CaptureDevice]) -> Void)?
    var isListening: Bool { onChange != nil }

    func start(_ onChange: @escaping ([CaptureDevice]) -> Void) {
        startCount += 1
        self.onChange = onChange
    }

    func stop() {
        stopCount += 1
        onChange = nil
    }

    /// Le système signale la liste complète des appareils.
    func send(_ devices: [CaptureDevice]) { onChange?(devices) }
}

final class CaptureTests: XCTestCase {
    private let builtIn = CaptureDevice(id: "mic-1", name: "Micro MacBook", kind: .microphone, isRunning: false)
    private let usb = CaptureDevice(id: "mic-2", name: "Micro USB", kind: .microphone, isRunning: false)
    private let facetime = CaptureDevice(id: "cam-7", name: "Caméra FaceTime", kind: .camera, isRunning: false)

    private func on(_ device: CaptureDevice) -> CaptureDevice {
        CaptureDevice(id: device.id, name: device.name, kind: device.kind, isRunning: true)
    }

    private func make(ears: Bool? = nil) -> (CaptureModule, FakeCaptureSource, ManualScheduler) {
        let defaults = makeEphemeralDefaults(self)
        if let ears { defaults.set(ears, forKey: "capture.ears") }
        let source = FakeCaptureSource()
        let scheduler = ManualScheduler()
        let module = CaptureModule(defaults: defaults, source: source, scheduler: scheduler.scheduler, opener: { _ in })
        return (module, source, scheduler)
    }

    /// Le délai d'affichage écoulé.
    private func settle(_ scheduler: ManualScheduler) {
        scheduler.pending.forEach { scheduler.fire($0) }
    }

    // MARK: Règles pures

    func testStateKeepsRunningDevicesMicrophonesFirst() {
        let state = CaptureRules.state([on(facetime), on(usb), on(builtIn)])
        XCTAssertEqual(state.active.map(\.id), ["mic-1", "mic-2", "cam-7"])
        XCTAssertTrue(CaptureRules.state([builtIn, usb, facetime]).isEmpty)
    }

    func testMicrophoneNeedsInputsAndNoOutput() {
        XCTAssertTrue(CaptureRules.countsAsMicrophone(inputStreams: 1, outputStreams: 0))
        XCTAssertFalse(CaptureRules.countsAsMicrophone(inputStreams: 1, outputStreams: 1), "casque : musique ou voix ?")
        XCTAssertFalse(CaptureRules.countsAsMicrophone(inputStreams: 0, outputStreams: 2), "haut-parleurs")
    }

    func testListenerChangesOnPlugAndUnplug() {
        let diff = CaptureRules.listenerChanges(current: ["1", "2"], wanted: ["2", "3"])
        XCTAssertEqual(diff.add, ["3"])
        XCTAssertEqual(diff.remove, ["1"])
        let same = CaptureRules.listenerChanges(current: ["1"], wanted: ["1"])
        XCTAssertTrue(same.add.isEmpty && same.remove.isEmpty)
    }

    // MARK: Module : marche, arrêt

    func testNothingListensBeforeStart() {
        let (module, source, scheduler) = make()
        XCTAssertFalse(source.isListening)
        XCTAssertNil(module.ears)
        XCTAssertTrue(scheduler.pending.isEmpty)
        XCTAssertFalse(module.isEnabledByDefault, "désactivé par défaut")
    }

    func testStopRemovesListenersAndClearsEars() {
        let (module, source, scheduler) = make()
        module.start()
        XCTAssertTrue(source.isListening)
        source.send([on(builtIn)])
        settle(scheduler)
        XCTAssertNotNil(module.ears)
        module.stop()
        XCTAssertFalse(source.isListening, "écouteurs retirés")
        XCTAssertNil(module.ears)
        XCTAssertTrue(module.state.isEmpty)
        source.send([on(builtIn)])
        XCTAssertTrue(module.state.isEmpty, "un événement tardif est ignoré")
        XCTAssertTrue(scheduler.pending.isEmpty)
        module.stop()
        XCTAssertEqual(source.stopCount, 1)
    }

    func testStartTwiceListensOnce() {
        let (module, source, _) = make()
        module.start()
        module.start()
        XCTAssertEqual(source.startCount, 1)
    }

    // MARK: Module : affichage

    func testMicrophoneEarsAreOrangeAfterTheDelay() {
        let (module, source, scheduler) = make()
        module.start()
        source.send([on(builtIn), facetime])
        XCTAssertNil(module.ears, "pas avant le délai")
        XCTAssertEqual(scheduler.pending.map(\.delay), [CaptureRules.showDelay])
        settle(scheduler)
        XCTAssertEqual(module.ears?.symbol, "mic.fill")
        XCTAssertEqual(module.ears?.accentHex, CaptureModule.microphoneHex)
        XCTAssertFalse(module.ears?.alert ?? true)
    }

    func testCameraEarsAreGreenAndBothShowTheCamera() {
        let (module, source, scheduler) = make()
        module.start()
        source.send([builtIn, on(facetime)])
        settle(scheduler)
        XCTAssertEqual(module.ears?.symbol, "video.fill")
        XCTAssertEqual(module.ears?.accentHex, CaptureModule.cameraHex)
        source.send([on(builtIn), on(facetime)])
        settle(scheduler)
        XCTAssertEqual(module.ears?.symbol, "video.fill")
        XCTAssertEqual(module.ears?.accentHex, CaptureModule.microphoneHex, "micro + caméra : orange")
        XCTAssertEqual(module.state.active.count, 2)
    }

    func testBriefAccessNeverShows() {
        let (module, source, scheduler) = make()
        module.start()
        source.send([on(builtIn)])
        source.send([builtIn])
        XCTAssertTrue(scheduler.pending.isEmpty, "le délai est annulé")
        XCTAssertNil(module.ears)
        XCTAssertTrue(module.state.isEmpty)
    }

    func testStopOfTheMicrophoneHidesTheEarsAtOnce() {
        let (module, source, scheduler) = make()
        module.start()
        source.send([on(builtIn)])
        settle(scheduler)
        source.send([builtIn])
        XCTAssertNil(module.ears)
    }

    func testSeveralDevicesStayUntilTheLastStops() {
        let (module, source, scheduler) = make()
        module.start()
        source.send([on(builtIn), on(usb)])
        settle(scheduler)
        XCTAssertEqual(module.state.microphones.count, 2)
        source.send([builtIn, on(usb)])
        XCTAssertEqual(module.state.microphones.map(\.name), ["Micro USB"])
        XCTAssertNotNil(module.ears)
        source.send([builtIn, usb])
        XCTAssertNil(module.ears)
    }

    func testSwitchingDeviceKeepsTheEarsWithoutFlicker() {
        let (module, source, scheduler) = make()
        module.start()
        source.send([on(builtIn), usb])
        settle(scheduler)
        // Une app passe du micro intégré au micro USB : l'intercalaire suit sans disparaître ni attendre.
        source.send([builtIn, on(usb)])
        XCTAssertEqual(module.state.microphones.map(\.name), ["Micro USB"])
        XCTAssertTrue(scheduler.pending.isEmpty)
    }

    func testPluggingInAMicrophoneAlreadyRunning() {
        let (module, source, scheduler) = make()
        module.start()
        source.send([builtIn])
        XCTAssertTrue(scheduler.pending.isEmpty, "rien ne tourne : aucun délai")
        source.send([builtIn, on(usb)])
        settle(scheduler)
        XCTAssertEqual(module.state.microphones.map(\.id), ["mic-2"])
    }

    func testUnplugWhileRunningHidesTheEars() {
        let (module, source, scheduler) = make()
        module.start()
        source.send([builtIn, on(usb)])
        settle(scheduler)
        source.send([builtIn])
        XCTAssertNil(module.ears)
    }

    // MARK: Réglage

    func testEarsOffStopsRunningCollapsed() {
        let (module, _, _) = make(ears: false)
        XCTAssertFalse(module.keepsRunningWhenCollapsed)
        module.start()
        module.apply([on(builtIn)])
        XCTAssertNil(module.ears, "intercalaire désactivé")
    }

    func testEarsOnKeepsRunningCollapsed() {
        let (module, _, _) = make()
        XCTAssertTrue(module.keepsRunningWhenCollapsed)
    }

    func testNoAppNameIsEverShown() {
        let (module, source, scheduler) = make()
        module.start()
        source.send([on(builtIn)])
        settle(scheduler)
        XCTAssertEqual(module.ears?.text, "Micro", "l'état, pas une app devinée")
    }

    func testPrivacyLinksOpenTheRightPane() {
        var opened: [URL] = []
        let module = CaptureModule(defaults: makeEphemeralDefaults(self), source: FakeCaptureSource(),
                                   scheduler: ManualScheduler().scheduler, opener: { opened.append($0) })
        module.openPrivacy(camera: false)
        module.openPrivacy(camera: true)
        XCTAssertEqual(opened.map(\.absoluteString).map { String($0.split(separator: "?").last ?? "") },
                       ["Privacy_Microphone", "Privacy_Camera"])
    }

    func testNoUsageDescriptionAddedToInfoPlist() throws {
        let plist = try String(contentsOf: repositoryRoot.appendingPathComponent("Resources/Info.plist"))
        XCTAssertFalse(plist.contains("NSMicrophoneUsageDescription"))
        XCTAssertFalse(plist.contains("NSCameraUsageDescription"))
    }
}
