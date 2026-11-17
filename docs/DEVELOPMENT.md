# Development

Swift Package (no Xcode project), Swift 5.10 tools, macOS 13+.
Code map and design decisions: [ARCHITECTURE.md](ARCHITECTURE.md).

```sh
swift build
swift test
scripts/build.sh      # universal (arm64 + x86_64) build/Oriel.app, signed ad hoc by default
scripts/make-dmg.sh   # build/Oriel-<version>.dmg and its .sha256, checked after creation
```

- `VERSION=1.2.3 scripts/build.sh` sets the app version (default: `CFBundleShortVersionString` of
  `Resources/Info.plist`). `RELEASE_CHANNEL=1` marks the app as a release build
  (`OrielUpdateChannel = release` in its Info.plist): only those update themselves.
- `SIGN_KEYCHAIN=<keychain> SIGN_IDENTITY=<certificate name> scripts/build.sh` signs with that certificate
  instead of ad hoc (both variables or neither). This is what the release workflow does; local builds stay ad
  hoc, and macOS asks again for its accesses after each one.
- `scripts/test-local.sh [swift test options]` runs `swift test --parallel` without the test classes that put windows on
  your screen (the full suite runs in CI).
- `scripts/install.sh` builds and installs from source; `scripts/uninstall.sh` removes it.
- Translations: `Resources/en.lproj` and `Resources/fr.lproj`. The French text in the code is the key;
  `LocalizationTests` checks that every key used in the code has an English translation.
- PNG snapshots of the panel, with sample data: `ORIEL_SNAPSHOT_DIR=/some/folder swift test --filter SnapshotTests`.
- **Publishing a release** = pushing a `vX.Y.Z` tag. GitHub Actions runs the tests, builds the universal app
  in version X.Y.Z with `RELEASE_CHANNEL=1`, makes the DMG, signs it with the `UPDATE_SIGNING_KEY` secret
  (`scripts/update-signing.swift`, the job fails if signing fails or if the key does not match the one built
  into the app) and creates the release with the DMG, its SHA-256 and its signature. Installed copies pick it
  up on their own.

  ```sh
  git tag v1.2.0
  git push origin v1.2.0
  ```

  Losing the private signing key breaks automatic updates for every existing installation: they only accept
  DMGs signed with that key. The maintainer keeps a private backup of it.
- **Code signature**: the release workflow signs the app with a self-signed certificate (CN `Claude Notch
  Self-Signed`, code signing, 10 years) so that its designated requirement stays the same from one version to
  the next and macOS keeps the accesses granted to the app (TCC). Two more repository secrets are needed:
  `SIGNING_CERT_P12` (the `.p12`, base64) and `SIGNING_CERT_PASSWORD`; the job fails right away without them.
  The workflow imports the certificate into a temporary keychain and deletes it at the end.

  Do not replace this certificate lightly: a new one changes the requirement and every user gets the access
  prompts again.
