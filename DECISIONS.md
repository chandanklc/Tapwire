# Decisions

Decisions made while building Tapwire, with reasons.

1. **Core framework + app.** All non-UI code lives in `TapwireCore.framework`, so unit tests and the
   headless integration test can drive the engine without launching the UI.
2. **Swift 5 language mode** (compiled with the Swift 6 toolchain) to keep the NIO channel-handler code
   free of strict-concurrency noise. Types crossing threads are `Sendable` or guarded by locks.
3. **Root CA uses P-256 (ECDSA)**: fast leaf signing and accepted by Android and macOS. Leaf certificates
   share one P-256 key pair (generated per launch), are valid for 397 days (Apple's limit for TLS
   server certificates is 398) and are cached in memory per host.
4. **CA private key is stored in the login Keychain** as a generic-password item. The public CA
   certificate is in `~/Library/Application Support/Tapwire/ca.pem`. Debug builds signed "to run
   locally" change their code signature on every rebuild, so macOS may ask once more for Keychain
   access after each rebuild. Choose "Always Allow".
