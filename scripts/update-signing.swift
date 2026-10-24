// Signature Ed25519 des mises à jour (les DMG publiés).
//
//   swift scripts/update-signing.swift generate | gh secret set UPDATE_SIGNING_KEY -R Slybald/oriel
//       Crée une paire de clés : la privée part sur stdout (vers le secret GitHub de la CI) et dans le
//       trousseau de session (secours) ; la publique s'affiche sur stderr, à intégrer dans l'app.
//   swift scripts/update-signing.swift sign <fichier>
//       Signature base64 sur stdout. Clé : $UPDATE_SIGNING_KEY, sinon le trousseau.
//   swift scripts/update-signing.swift verify <fichier> <signature base64> <clé publique base64>
import CryptoKit
import Foundation
import Security

let service = "io.github.slybald.claudenotch.update-signing"
let account = "release-signing-key"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func keychainKey() -> String? {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
}

func privateKey() -> Curve25519.Signing.PrivateKey {
    let env = ProcessInfo.processInfo.environment["UPDATE_SIGNING_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let encoded = (env?.isEmpty == false ? env : nil) ?? keychainKey(),
          let raw = Data(base64Encoded: encoded) else { fail("Clé privée introuvable (UPDATE_SIGNING_KEY ou trousseau).") }
    do { return try Curve25519.Signing.PrivateKey(rawRepresentation: raw) } catch { fail("Clé privée invalide.") }
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "generate":
    if keychainKey() != nil { fail("Une clé existe déjà dans le trousseau (\(service)) : rien n'est remplacé.") }
    let key = Curve25519.Signing.PrivateKey()
    let encoded = key.rawRepresentation.base64EncodedString()
    let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                              kSecAttrAccount as String: account, kSecValueData as String: Data(encoded.utf8),
                              kSecAttrLabel as String: "Oriel — clé de signature des mises à jour"]
    let status = SecItemAdd(add as CFDictionary, nil)
    guard status == errSecSuccess else { fail("Écriture dans le trousseau impossible (\(status)).") }
    FileHandle.standardError.write(Data("Clé publique : \(key.publicKey.rawRepresentation.base64EncodedString())\n".utf8))
    print(encoded, terminator: "")
case "sign":
    guard args.count == 2, let data = FileManager.default.contents(atPath: Array(args)[1]) else { fail("Usage : sign <fichier>") }
    do { print(try privateKey().signature(for: data).base64EncodedString()) } catch { fail("Signature impossible : \(error)") }
case "verify":
    let a = Array(args)
    guard a.count == 4, let data = FileManager.default.contents(atPath: a[1]),
          let signature = Data(base64Encoded: a[2].trimmingCharacters(in: .whitespacesAndNewlines)),
          let publicRaw = Data(base64Encoded: a[3]),
          let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicRaw) else {
        fail("Usage : verify <fichier> <signature base64> <clé publique base64>")
    }
    if publicKey.isValidSignature(signature, for: data) { print("signature valide") } else { fail("signature INVALIDE") }
default:
    fail("Usage : generate | sign <fichier> | verify <fichier> <signature> <clé publique>")
}
