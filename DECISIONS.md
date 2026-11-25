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
5. **Store-and-forward for requests, streaming for responses.** Request bodies are collected first (so mocks
   can match on body text and breakpoints can edit them). Responses stream straight to the client
   unless a response rule or response breakpoint matches. Either way, at most the memory limit
   (default 50 MB) is kept in RAM per body; the rest spills to a temp file and is still forwarded in full.
   Bodies that spilled can't be edited by rules or breakpoints (forwarded unchanged, with a note).
6. **Rules match the original or the mapped URL.** With an environment active, a mock or breakpoint
   written for `api.myapp.com/*` still matches after the request is redirected to staging.
7. **Full mocks skip only the upstream call.** Response modifications and the response breakpoint
   still run on a mocked response, so you can tweak a mock live.
8. **Decoded bodies when editing.** When a rule or breakpoint edits a gzip/deflate/br body, Tapwire
   decodes it, applies the change and sends it with `Content-Encoding` removed. Untouched bodies keep
   their original bytes and encoding.
9. **Automatic decryption for rules.** A CONNECT is decrypted when the host is in the SSL Proxying list,
   "Decrypt all" is on, the active environment maps that host, or an enabled mock/breakpoint pattern
   names the host. Wildcard-host rules need the host in SSL Proxying.
10. **Wildcard patterns.** `*` is the only wildcard (`?` is literal because URLs use it). Patterns
    are case-insensitive. Without a scheme they match any scheme, without a port any port, and a bare host
    matches all its paths. A pattern without `?` also matches URLs that have a query string.
11. **Upstream connection pool.** Keep-alive connections to servers are reused (6 idle per host,
    50 s idle timeout). A request on a stale pooled connection is retried once on a fresh one.
12. **Abort = close.** "Abort" closes the client connection without a response, which clients
    report as a network error. A TCP RST (SO_LINGER 0) isn't available through NIO's socket-option
    API (it only takes Int32 values), so a plain close is the closest working alternative.
13. **WebSockets are tunnelled after the handshake.** The 101 handshake is recorded (and environment
    mapping applies); the frames are passed through as raw bytes and are not decoded.
14. **HTTP/2 and HTTP/3 aren't used.** ALPN offers only `http/1.1` to clients and servers. QUIC/HTTP/3
    (UDP) never reaches an HTTP proxy, so apps that use it (e.g. Cronet) must fall back to TCP.
15. **System proxy.** `networksetup` runs once through `osascript … with administrator privileges`
    for all enabled network services. The previous settings are saved to `system-proxy-backup.json`
    before changing anything, and restored on Stop, on Quit, or later from the toggle.
16. **One app target plus a core framework**, no XPC helper: the app isn't sandboxed and the engine
    runs on NIO event loops, off the main thread. The UI only gets batched updates (10 per second).
17. **Milestones 2–7 were committed together.** The UI for traffic, breakpoints, mocks, environments,
    sessions, settings and the menu bar shares one model and was built and verified (clean build +
    tests) as a unit.
18. **Echo server in the core framework.** `EchoServer` (local HTTP/HTTPS) lives in TapwireCore so the
    tests don't link SwiftNIO a second time.
19. **Default port conflict.** Port 9090 is also Proxyman's default. If something else listens there,
    Tapwire shows an error at launch; change the port in Settings → General.
