# Tapwire: Plan

Tapwire is a macOS HTTP/HTTPS debugging proxy (SwiftUI, macOS 14+, SwiftNIO).

## Architecture

```
┌──────────────────────────── Tapwire.app (SwiftUI) ─────────────────────────────┐
│ UI/            three-pane window, inspector, rules editors, breakpoint editor, │
│                compose, certificate/Android setup, settings, menu bar extra    │
│ App/           AppModel (@Observable, @MainActor): owns stores + engine         │
└───────────────────────────────┬────────────────────────────────────────────────┘
                                │ links
┌───────────────────────── TapwireCore.framework ────────────────────────────────┐
│ Model/         CapturedExchange, HeaderField, ParsedURL, HTTP helpers, bodies   │
│ ProxyEngine/   ProxyServer (NIO listener), ClientConnectionHandler (HTTP/1.1,  │
│                CONNECT, MITM via SNI + NIOSSL, WebSocket tunnel), Upstream     │
│                client (NIOAsyncChannel, TLS, external proxy), RequestPipeline  │
│                (rule order), Throttle, BodyDecoder (gzip/deflate/br), System   │
│                proxy (networksetup via AppleScript admin prompt)              │
│ Certificates/  CertificateAuthority (P-256 root CA, keychain-held key),        │
│                LeafCertificateCache, trust check/installation helpers          │
│ Rules/         URLPattern, HostPattern, BreakpointRule, MockRule/MockGroup,    │
│                Environment, RuleEngine, JSONKeyPath, modifications             │
│ Storage/       AppPaths, JSONFileStore, SessionFile (.tapwire), HAR 1.2, cURL, │
│                exchange exporters (JSON/raw HTTP/body)                        │
└────────────────────────────────────────────────────────────────────────────────┘
```

Threading: NIO event loops do the socket I/O. Each request is handled in a Swift `Task`
by `RequestPipeline` (async/await). The engine reads a lock-protected, immutable
`EngineConfiguration` snapshot. UI updates go to the main actor in batches (coalesced
every 100 ms). Breakpoints suspend only that request's Task through a continuation,
so other traffic keeps flowing.

Pipeline order (one request):
1. environment mapping (rewrite target + extra headers)
2. request mocks/modifications (Modify rules in order; a matching Full mock is chosen)
3. request breakpoint (Execute edited / Abort / Continue unchanged)
4. upstream (skipped when a Full mock matched) + throttling
5. response modifications
6. response breakpoint
7. write to client, record

## Targets
- `TapwireCore` (framework): everything except UI
- `Tapwire` (app)
- `TapwireCoreTests` (unit + integration tests; integration uses curl + a local NIO HTTPS server)

## Milestones
1. Project setup + proxy engine (HTTP, CONNECT, MITM, certs)
2. Traffic list + inspector
3. Breakpoints
4. Mocks
5. Environments
6. Save/sessions/HAR/repeat/compose
7. Throttling, menu bar, settings, polish
8. Integration test, README.md, TESTING.md, final build

Each milestone: clean `xcodebuild build`, `xcodebuild test`, git commit.
