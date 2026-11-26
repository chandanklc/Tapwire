# Tapwire

Tapwire is a macOS HTTP/HTTPS debugging proxy for developers. Use it to watch, pause, edit, mock and
redirect your app's API traffic (iPhone, Android phone, emulator or Simulator) and the Mac's own traffic.

- Live traffic list with domain sidebar, saved show-only / hide domain lists, filters and search (URL, headers, bodies, WebSocket messages; regex)
- HTTPS decryption (MITM) per host or for everything, with a per-Mac root certificate; HTTP/2 to apps
- **WebSocket messages**: every frame in both directions, with a Messages tab
- **Breakpoints**: pause a request or response, edit anything, then Execute / Abort / Cancel
- **Mocks**: full mocks (no server) or modify rules (status, headers, body, JSON key paths), in groups
- **Environments**: redirect hosts (prod → staging → local) with extra headers, switch in one click
- Repeat, Compose, cURL, sessions (`.tapwire`), HAR 1.2 import/export, throttling, menu bar extra

## Download

Get the latest `Tapwire-<version>.dmg` from [Releases](https://github.com/chandanklc/Tapwire/releases), open it
and drag Tapwire to Applications. It runs on macOS 14 or later, on Apple silicon and Intel.

The app isn't notarized yet, so macOS blocks it the first time you open it. Click **Done**, then go to
**System Settings → Privacy & Security** and click **Open Anyway**. Or run this once:

```bash
xattr -dr com.apple.quarantine /Applications/Tapwire.app
```

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

## Why does Tapwire ask for my password?

| When | Why | How often |
|---|---|---|
| "Tapwire wants to use … app.tapwire.root-ca" | Reads its certificate key from your Keychain to decrypt HTTPS | Once per build; click **Always Allow** |
| **Install & Trust** certificate | Trusting a certificate is a system security change | Once (and after Regenerate CA) |
| **Use as System Proxy** on/off | Changing network settings needs admin rights | Each time you turn it on or off |

The Keychain prompt comes back after an update because the app isn't signed with an Apple Developer ID,
so macOS treats each new build as a different app.

## Trust the certificate on the Mac

1. Click the shield toolbar button (**Certificates & Device Setup**) → **This Mac**.
2. Click **Install & Trust**. macOS asks for your password and marks the Tapwire CA as trusted.
   Or click **Install Certificate on this Mac**: Keychain Access opens; double-click **Tapwire CA**,
   expand **Trust**, set **When using this certificate** to **Always Trust**, then close and enter your password.
3. The status shows **Trusted**.
4. To capture the Mac's own traffic, turn on **System proxy** in the toolbar (admin prompt). Tapwire
   saves your previous proxy settings and restores them on Stop or Quit.
5. Add hosts to decrypt under **Settings → SSL Proxying** (e.g. `*.myapp.com`), or turn on **Decrypt all**.

## iPhone setup

Tapwire → **Certificates & Device Setup → iPhone** shows these steps with your Mac's address and a QR code.

1. **Wi-Fi proxy:** iPhone on the same Wi-Fi → Settings → Wi-Fi → ⓘ → **Configure Proxy → Manual** →
   Server: your Mac's IP, Port: `9090`.
2. **Certificate:** open `http://tapwire.cert` in **Safari** → Download → Allow → Settings → **Profile Downloaded** → Install.
3. **Full trust (required):** Settings → General → About → **Certificate Trust Settings** → turn on **Tapwire**.
4. In Tapwire, add your API host to **SSL Proxying** (or turn on Decrypt all).

**iOS Simulator:** it uses the Mac's network, so turn on **Use as System Proxy**. Open `http://127.0.0.1:9090/cert`
on the Mac, drag the downloaded `Tapwire-CA.crt` onto the Simulator, install it, then turn on full trust as in step 3.

Apps that pin certificates (and some Apple services) won't decrypt. When you're done, set the iPhone's
proxy back to **Off**.

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

## Layout

Tapwire's "British GT" look: racing green, sunset gold, burgundy and ivory, in light and dark.

- **Rail** (far left): Traffic, Rules & mocks, Breakpoints (shows how many are paused), Environments,
  Connect a device, Settings.
- **Sources**: your traffic grouped by **Devices** (each phone by address; this Mac and emulators
  together) or as a flat **Hosts** list, each host with an activity sparkline. Click a device to show
  only its calls. Hide or show the column with ⌃⌘S. "Filter hosts" at the bottom narrows the list.
- **Top bar**: Recording (click to pause; it starts the proxy when stopped), the search field, Filters,
  Domains, environment, breakpoints, system proxy, compose, details position and clear.
- **Call list**: method and status badges, host and path, and a **timeline** bar showing when each call
  ran and for how long.
- **Details**: under the list (or on the right, ⌥⌘I) with **Request and Response side by side**, a
  timing bar (connect, sent, waiting, download) and Repeat / Edit / Breakpoint / Mock / cURL buttons.
  Each side remembers its last tab.

## Searching

Type `host:`, `status:`, `method:` or `device:` followed by a value and press space or Return to turn
it into a chip: `status:4xx`, `status:error`, `method:POST`, `host:*.myapp.com`, `device:192.168.1.52`,
`device:mac`. Put `!` before the value (`method:!OPTIONS`) or `-` before the key to exclude. ⌘L jumps
to the search field.

The search field matches **Everything** by default: URLs, headers, rule names, request and response
bodies (decoded from gzip/deflate/br) and WebSocket messages. Click the magnifying glass to limit it to
URL, Headers or Bodies & messages, or to turn on **Regular expression** and **Match case**. Body searches
run in the background, so typing stays fast with thousands of calls. Inside a body, ⌘F opens a find bar
(⌘G / ⌘⇧G for next and previous).

## Domain filter

Keep the list focused on the APIs you care about. Right-click a domain in the sidebar:

- **Show Only api.myapp.com** (or **Show Only \*.myapp.com**) lists just that domain. Add more with **Also Show**.
- **Hide graph.facebook.com** (or **Hide \*.facebook.com**) removes noisy domains such as analytics, ads and CDNs.

Hidden domains move to a dimmed **Hidden by domain filter** section at the bottom of the sidebar,
where you can unhide them. The **Domains** menu in the filter bar turns each entry on or off, or the
whole filter. Edit both lists in **Settings → Domains**. Wildcards work as in the rest of Tapwire;
`*.myapp.com` also matches `myapp.com`, and `:port` limits an entry to one port. A domain on both lists
is hidden. The lists are saved, and they only change what's shown: calls are still recorded, and
rules and breakpoints still apply.

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

## License

MIT. See [LICENSE](LICENSE).
