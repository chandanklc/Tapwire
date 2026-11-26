# Tapwire

Tapwire is a macOS HTTP/HTTPS debugging proxy for developers. Use it to watch, pause, edit, mock and
redirect your Android app's API traffic (phone on Wi-Fi or the emulator) and the Mac's own traffic.

- Live traffic list with domain sidebar, filters and search (URL, headers, bodies, WebSocket messages; regex)
- HTTPS decryption (MITM) per host or for everything, with a per-Mac root certificate; HTTP/2 to apps
- **WebSocket messages**: every frame in both directions, with a Messages tab
- **Breakpoints**: pause a request or response, edit anything, then Execute / Abort / Cancel
- **Mocks**: full mocks (no server) or modify rules (status, headers, body, JSON key paths), in groups
- **Environments**: redirect hosts (prod → staging → local) with extra headers, switch in one click
- Repeat, Compose, cURL, sessions (`.tapwire`), HAR 1.2 import/export, throttling, menu bar extra

## Build and run

Requirements: macOS 14+, Xcode 15+ (tested with Xcode 26), Homebrew.

```bash
brew install xcodegen
```

```bash
xcodegen generate
```

```bash
open Tapwire.xcodeproj
```

Choose the **Tapwire** scheme and Run (⌘R). From the command line:

```bash
xcodebuild -scheme Tapwire -configuration Debug -derivedDataPath build/DD build
```

```bash
open build/DD/Build/Products/Debug/Tapwire.app
```

Tests (unit + headless integration):

```bash
xcodebuild test -scheme Tapwire -derivedDataPath build/DD
```

```bash
./scripts/integration-test.sh
```

The proxy starts on port **9090** on all interfaces. If another tool already uses 9090, change the
port in **Settings → General**. Data lives in `~/Library/Application Support/Tapwire/` (settings,
rules, environments, the CA certificate). The CA private key is in your login Keychain
(item `app.tapwire.root-ca`). Debug builds are signed to run locally, so after a rebuild macOS may
ask once for Keychain access; choose **Always Allow**.

## Make a release (DMG)

```bash
scripts/release.sh
```

This builds a universal (Apple silicon + Intel) Release app and writes `build/dist/Tapwire-<version>.dmg`
plus a `.sha256` file. Without a certificate the app is signed ad hoc: it runs on your Mac, and other
Macs block it the first time until you click **Open Anyway** in System Settings → Privacy & Security.

To make a DMG anyone can open, you need an Apple Developer account and a **Developer ID Application**
certificate in your Keychain. Store notarization credentials once:

```bash
xcrun notarytool store-credentials tapwire-notary --apple-id you@example.com --team-id TEAMID
```

Then build, sign, notarize and staple:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" TEAM_ID=TEAMID NOTARY_PROFILE=tapwire-notary scripts/release.sh
```

The version comes from `MARKETING_VERSION` in `project.yml`.

## Trust the certificate on the Mac

1. Click the shield toolbar button (**Certificates & Device Setup**) → **This Mac**.
2. Click **Install & Trust**. macOS asks for your password and marks the Tapwire CA as trusted.
   Or click **Install Certificate on this Mac**: Keychain Access opens; double-click **Tapwire CA**,
   expand **Trust**, set **When using this certificate** to **Always Trust**, then close and enter your password.
3. The status shows **Trusted**.
4. To capture the Mac's own traffic, turn on **System proxy** in the toolbar (admin prompt). Tapwire
   saves your previous proxy settings and restores them on Stop or Quit.
5. Add hosts to decrypt under **Settings → SSL Proxying** (e.g. `*.myapp.com`), or turn on **Decrypt all**.

## Android setup

Open **Certificates & Device Setup → Android** for your Mac's IP, the port, a QR code and copy buttons.

### Phone on the same Wi-Fi
1. Settings → Network & internet → Internet → gear next to your Wi-Fi → Edit → Advanced → Proxy → **Manual**.
   Host = your Mac's IP (shown in Tapwire), port = 9090.
2. In Chrome open **http://tapwire.cert/** (or `http://<mac-ip>:9090/cert`, or scan the QR code)
   and download `Tapwire-CA.crt`.
3. Settings → Security & privacy → More security settings → Encryption & credentials →
   **Install a certificate → CA certificate** → pick `Tapwire-CA.crt`.
4. Make your **debug build** trust user CAs. Create `app/src/debug/res/xml/network_security_config.xml`:

   ```xml
   <?xml version="1.0" encoding="utf-8"?>
   <network-security-config>
       <debug-overrides>
           <trust-anchors>
               <certificates src="user" />
               <certificates src="system" />
           </trust-anchors>
       </debug-overrides>
   </network-security-config>
   ```

   and on `<application>` in `AndroidManifest.xml`:

   ```xml
   android:networkSecurityConfig="@xml/network_security_config"
   ```

   `debug-overrides` only applies to debuggable builds, so release builds are unaffected.
5. Add your API host to **SSL Proxying**. Its calls now show decrypted.

### Emulator
The emulator reaches the Mac at **10.0.2.2**. Set the proxy in Extended controls → Settings → Proxy
(manual, host `10.0.2.2`, port 9090), or start it with:

```bash
emulator -avd <your_avd> -http-proxy http://10.0.2.2:9090
```

Then install the certificate from http://tapwire.cert/ inside the emulator and add the
network_security_config as above.

## Breakpoints

- **Rules → Breakpoints** (or right-click a call → **Add Breakpoint for This URL**). Set a URL pattern
  (wildcard or regex), a method, and pause on Request, Response or both.
- When a call matches, it's held (other traffic keeps flowing) and the **Breakpoints** window opens.
  Several paused calls queue up in its sidebar; the toolbar shows a badge.
- Request phase: edit the method, full URL, query table, headers table and body (Format / Minify / Validate JSON).
  Response phase: edit the status (picker or free entry), reason, headers and body.
- **Execute** (⌘↩) sends your edits. **Cancel** (Esc) continues the original. **Abort** (⌘⌫) drops the
  connection so the app sees a network error. ⌘[ and ⌘] move between paused calls.
- The banner shows how long the call has waited and warns before typical client timeouts
  (OkHttp's default read timeout is 10 s). It also says when the client has disconnected.
- **Save…** saves the edited response as a mock, or the edited request/response to a file.
- Turn all breakpoints on or off from the toolbar, the menu bar extra, or ⌘B.

## Mocks

- **Rules → Mocks**: rules live in named groups ("Login errors", "Empty cart"). Each group and each rule has
  its own on/off switch. Rules apply in list order.
- Match: URL pattern, method, and optionally a query parameter, header or body text.
- **Full mock**: Tapwire answers itself with a status, headers and body (inline, or any local file),
  with an optional delay.
- **Modify**: the call goes to the real server. Request side: method, URL, query, headers, body, JSON key paths.
  Response side: status, headers, body, JSON key paths (e.g. `data.user.name` = `"Test"`, `data.items` = `[]`,
  `items[0].price` = `0`).
- Right-click any call → **Save as Mock** to create a full mock from the real response.
- Matched calls show the rule name as a tag in the list.
- Import/export groups as JSON from the Mocks tab.

## Environments

- **Rules → Environments**: each environment has a name, a colour, host mappings
  (`api.myapp.com/v1` → `https://staging.myapp.com:8443/v1`) and extra headers.
- Pick the active one from the toolbar dropdown or the menu bar. **None** = passthrough. Changes apply
  to new requests immediately.
- HTTPS works: Tapwire decrypts the source host, connects to the target with the right TLS name
  (SNI) and rewrites the Host header.
- Mapped calls show a coloured dot in the list and "original → mapped" in the inspector.
- Dev, Staging and Prod examples are pre-filled with placeholder hosts; edit them.

Rule order for every call: environment mapping → request mocks/modifications → request breakpoint →
server (skipped by a full mock) → response modifications → response breakpoint.

## Saving and exporting

- Right-click → **Save to File**: request, response or both as JSON, raw HTTP or body only.
- **File → Save Session** (`.tapwire`), **Open Session or HAR**, **Export Session as HAR**, or export
  selected calls as HAR from the context menu.
- **Repeat** re-sends a call; **Edit & Repeat** (or double-click) opens **Compose**, which also builds
  requests from scratch or from pasted raw HTTP. Composed requests go through the same rules.

## Searching

The search field matches **Everything** by default: URLs, headers, rule names, request and response
bodies (decoded from gzip/deflate/br) and WebSocket messages. Click the magnifying glass to limit it to
URL, Headers or Bodies & messages, or to turn on **Regular expression** and **Match case**. Body searches
run in the background, so typing stays fast with thousands of calls. Inside a body, ⌘F opens a find bar
(⌘G / ⌘⇧G for next and previous).

## WebSockets

WebSocket calls (tagged **WS**) open on the **Messages** tab: each message with direction, time, type,
size and a preview. Select one to see it in the body viewer (JSON is pretty-printed). You can filter
by direction, hide ping/pong, and filter by text. Tapwire keeps up to 10,000 messages per connection
and 256 KB per message. To keep messages readable, Tapwire removes the `permessage-deflate` offer from
the handshake, so the connection runs uncompressed. Messages are included in saved sessions and in
HAR exports (Chrome's `_webSocketMessages` format).

## HTTP/2

In decrypted HTTPS connections Tapwire offers HTTP/2 to the app, so apps and browsers that prefer
HTTP/2 use it. Calls show as `HTTP/2`. Tapwire still talks HTTP/1.1 to the server, and rules,
breakpoints and mocks work the same. Turn it off in **Settings → SSL Proxying**.

## Other features

- **Throttling** (Settings → Throttling): 4G, 3G, Slow 3G, EDGE, high latency or custom latency and
  bandwidth, for all hosts or a host list.
- **External proxy** (Settings → External Proxy), with a bypass list.
- **Menu bar extra**: proxy status, environment, breakpoints, throttling, system proxy.
- Light, dark or system theme.

## Known limits

- **Certificate pinning**: apps that pin certificates (OkHttp `CertificatePinner`, `<pin-set>`, or
  some SDKs) reject Tapwire's certificate. The handshake failure shows as a red CONNECT row. Disable
  pinning in debug builds or leave that host out of SSL Proxying.
- **Release builds** on Android 7+ ignore user-installed CAs unless the app opts in.
- **HTTP/3 / QUIC** uses UDP and bypasses HTTP proxies. Apps fall back to TCP when QUIC is blocked.
  Chrome and Cronet do this automatically.
- **HTTP/2 to servers** isn't used: Tapwire speaks HTTP/2 with the app but HTTP/1.1 with the server.
  Plain-HTTP `h2c` isn't supported. Server push and HTTP/2-only features (e.g. gRPC) don't work through Tapwire.
- **WebSocket** messages can be viewed but not paused or edited. WebSockets over HTTP/2 (RFC 8441)
  aren't offered, so clients open a separate HTTP/1.1 connection for them.
- Bodies larger than the memory limit (default 50 MB) are forwarded in full but can't be edited.
  Only the first preview MB (default 5) are shown.
- Some apps ignore the Android Wi-Fi proxy (e.g. ones that set their own proxy or use raw sockets).
