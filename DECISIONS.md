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
13. **WebSocket frames are passed through unchanged and parsed on the side.** After the 101 the
    connection is a byte tunnel; a parser reads a copy of each direction and records messages
    (superseded the earlier "not decoded" behaviour, see 20).
14. **HTTP/3 isn't used.** QUIC/HTTP/3 (UDP) never reaches an HTTP proxy, so apps that use it (e.g.
    Cronet) must fall back to TCP. HTTP/2 is offered to clients only (see 21).
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
20. **WebSocket messages without compression.** Tapwire removes `Sec-WebSocket-Extensions` from the
    client's handshake, so `permessage-deflate` is never negotiated. With context takeover the
    deflate state carries across messages, so a proxy that joins mid-stream or drops a frame can't
    decode them; uncompressed frames are always readable. Each connection keeps at most 10,000
    messages and 256 KB per message; the rest are counted. Messages are recorded at most every 150 ms
    to keep UI updates cheap. The switch from HTTP to tunnel now happens in one event-loop step, after
    a client frame sent immediately after the 101 was found to reach the HTTP handlers.
21. **HTTP/2 to clients, HTTP/1.1 to servers.** Decrypted connections offer `h2` and `http/1.1` via
    ALPN. Each HTTP/2 stream is converted to HTTP/1 messages (`HTTP2FramePayloadToHTTP1ServerCodec`) and
    handled by the same pipeline as HTTP/1.1, so rules, breakpoints and mocks need no changes. Upstream
    stays HTTP/1.1 because it works everywhere and keeps the connection pool simple; cookies that HTTP/2
    splits across headers are joined back into one. A setting turns HTTP/2 off.
22. **Search runs off the main thread when it reads bodies.** URL and header filters run directly; body
    searches wait 250 ms after typing stops and run in the background. As traffic arrives, only the
    calls that changed are re-checked. Regex uses `NSRegularExpression`, compiled once per pass.
23. **HAR WebSocket format.** Messages are exported as Chrome DevTools' `_resourceType: "websocket"` and
    `_webSocketMessages` (`type`, `time` in seconds, `opcode`, `data`, binary as base64), so Chrome and other
    HAR tools can read them. Close codes aren't part of that format and are lost on a HAR round trip
    (sessions keep them).
24. **Release script instead of an Xcode archive workflow.** `scripts/release.sh` builds a universal
    Release app, verifies the signature, makes a compressed DMG with an Applications link, and, when given
    a Developer ID identity and a notarytool profile, signs, notarizes and staples it. Without them it
    produces an ad-hoc signed DMG. Signing details come from environment variables, so no personal
    team ID is stored in the project.
25. **Ad-hoc releases run without the hardened runtime.** With the hardened runtime, library
    validation only loads frameworks signed by the app's Team ID. Ad-hoc signatures have no Team ID,
    so 1.0.0 couldn't load TapwireCore.framework and quit at launch. Ad-hoc builds now turn the
    hardened runtime off. Developer ID builds keep it, since notarization requires it and the app and
    framework share the Team ID. The release script launches each architecture with
    `--launch-check` (it exits once every library has loaded) and stops if that fails.
