# Tapwire manual test checklist

Before you start: build and run Tapwire. If another proxy (e.g. Proxyman) uses port 9090, quit it
or change Tapwire's port in Settings → General.

## Setup
- [ ] First launch creates `~/Library/Application Support/Tapwire/` with `ca.pem` and `environments.json`.
- [ ] The window subtitle shows "Listening on <ip>:9090"; the menu bar icon shows the proxy as running.
- [ ] Certificates → This Mac → **Install & Trust** → password prompt → status **Trusted**.
- [ ] Turn on **System proxy** (admin prompt) → Safari traffic appears in the list.
- [ ] Turn it off → System Settings → Network → Wi-Fi → Proxies shows your previous settings again.
- [ ] Turn it on, quit Tapwire (⌘Q) → proxy settings are restored.

## Traffic and inspector
- [ ] `curl -x http://127.0.0.1:9090 http://example.com/` shows up with method, host, path, code, duration, size, time.
- [ ] Add `example.com` to Settings → SSL Proxying and run `curl -x http://127.0.0.1:9090 https://example.com/`
      → the row has a green open lock; Response → Body shows HTML.
- [ ] A host not on the list shows as a "(tunnel)" CONNECT row with byte counts.
- [ ] A JSON API call: Body → Pretty (coloured), Tree (expand/collapse), Raw, Hex. Copy body works.
- [ ] An image call shows Image preview; a form POST shows Form; Query and Cookies tabs fill in.
- [ ] Overview shows timing (bar + numbers) and sizes.
- [ ] Sidebar: domains with counts; pin one (right-click) → appears under Pinned; selecting filters the list.
- [ ] Filter bar: search finds text in a response body; method / status / type filters; "Decrypted only".
- [ ] Sidebar → right-click a domain → Show Only it: only that domain's calls are listed; All traffic's count matches.
      Also Show adds a second domain; Show Only *.parent works for subdomains.
- [ ] Right-click → Hide a noisy domain: its calls disappear and it moves to "Hidden by domain filter"; Unhide brings it back.
- [ ] Filter bar → Domains menu: toggling an entry or "Use Domain Filter" updates the list at once; Clear empties both lists.
- [ ] Settings → Domains: add `*.example.com` to Hide → example.com and its subdomains are hidden; quit and reopen → still saved.
- [ ] Sidebar shows the "Domain filter on" box with Edit… (opens Settings → Domains) and Turn Off.
- [ ] Magnifying-glass menu: URL / Headers / Bodies & messages scopes each only match their part.
- [ ] Regular expression on: `user/\d+` matches; an invalid pattern like `(` gives a red outline. Match case works.
- [ ] With a few thousand calls, typing in the search field stays smooth (a small spinner shows while bodies are searched).
- [ ] Click into a response body, press ⌘F → find bar; ⌘G / ⌘⇧G move between matches.
- [ ] `curl --http2 -x http://127.0.0.1:9090 https://example.com/ -o /dev/null -w '%{http_version}\n'` (example.com
      in SSL Proxying) prints `2`; the row's Overview shows Protocol HTTP/2. Turning off "Offer HTTP/2" prints `1.1`.
- [ ] Chrome or Safari through the proxy with a decrypted site: pages load, and breakpoints and mocks still work.
- [ ] Pause recording → new calls don't appear but still work. Clear (⌘K) empties the list.
- [ ] Context menu: Copy URL, Copy as cURL (paste in Terminal and run it), Copy bodies, Repeat (new row),
      Edit & Repeat (Compose opens prefilled), Save to File (all 3 formats), Delete.
- [ ] A gzip response (`curl --compressed …`) displays decoded; the client still receives gzip.

## Breakpoints
- [ ] Right-click a call → Add Breakpoint for This URL → the Rules window shows it (phase Both).
- [ ] Repeat the call → the Breakpoints window opens with the request paused; the toolbar shows "1 paused".
- [ ] Other calls keep flowing while it's paused.
- [ ] Edit the method, URL, a query param (table), a header (add/remove), the body (Format/Validate JSON) → Execute (⌘↩)
      → the server receives the edits (check with https://httpbin.org/anything).
- [ ] The response then pauses: change the status (picker and typed code), reason, a header, the body → Execute → the client gets it.
- [ ] Cancel (Esc) sends the original unchanged; Abort (⌘⌫) → curl reports an empty reply or connection error.
- [ ] Fire 3 matching calls at once → 3 queued in the sidebar; ⌘[ / ⌘] switch between them.
- [ ] Wait more than 10 s → the timeout warning appears; kill the client (Ctrl-C) → "client closed the connection".
- [ ] "Save Edited Response as Mock" creates a rule under "Saved mocks"; "Save Edited Request to File" writes a .http file.
- [ ] Toolbar breakpoint toggle / ⌘B / menu bar toggle turns all breakpoints off → calls no longer pause.

## Mocks
- [ ] Rules → Mocks → New Group → full mock: pattern `httpbin.org/status/*`, status 418, inline JSON, delay 1000
      → curl gets 418 after about 1 s and the list tags it "Mock: …".
- [ ] Full mock from a local file (e.g. a PNG) → served with the right Content-Type.
- [ ] Modify rule: response JSON edit `slideshow.title` = `"Changed"` on `httpbin.org/json` → title changes.
- [ ] Modify rule request side: add header `X-Test: 1` on `httpbin.org/headers` → echoed back.
- [ ] Turn off the rule, then the group → it stops applying.
- [ ] Match options: method, query param, header and body-contains each restrict matching.
- [ ] Right-click a call → Save as Mock → pre-filled with the real response.
- [ ] Export a group to JSON, delete it, import it → it's back.

## Environments
- [ ] Rules → Environments: edit "Dev" so `httpbin.org` → `https://postman-echo.com`, add header `x-env: dev`.
- [ ] Toolbar dropdown → Dev → `curl -x … https://httpbin.org/get` is answered by postman-echo (the HTTPS
      mapping works); the list shows a green dot; the inspector shows original → mapped; the x-env header is sent.
- [ ] Switch to None from the menu bar extra → calls go to httpbin again immediately.
- [ ] Path prefix mapping (`httpbin.org/anything` → `https://postman-echo.com/get`) keeps the rest of the path and the query.

## Sessions and export
- [ ] File → Save Session (⌘S) → `.tapwire` file; Clear; File → Open → the calls are back with bodies.
- [ ] Double-clicking a `.tapwire` file in Finder opens it in Tapwire.
- [ ] Export as HAR (⌘⇧E) → open in another HAR viewer or import back into Tapwire.
- [ ] Compose (⌘N): GET/POST with headers and a JSON body → the response shows below and in the list.
- [ ] Compose → Load → Paste Raw HTTP Request parses a copied raw request.

## Android
- [ ] Certificates → Android shows the IP, port and QR code; scanning the QR downloads the certificate.
- [ ] Phone Wi-Fi proxy → http://tapwire.cert/ loads the Tapwire page.
- [ ] Install the certificate; add the network_security_config (Copy buttons) to a debug build;
      the app's HTTPS calls show decrypted.
- [ ] Emulator with `-http-proxy http://10.0.2.2:9090` → traffic appears.
- [ ] A pinned host shows a red CONNECT row explaining the handshake failure.

## Extras
- [ ] Settings → Throttling → Slow 3G → page loads slowly; per-host scope throttles only listed hosts.
- [ ] Settings → External Proxy → traffic goes through it (e.g. a second proxy) except bypassed hosts.
- [ ] Settings → port change restarts the listener on the new port.
- [ ] Theme Light / Dark / System switches all windows.
- [ ] WebSocket (e.g. a websocket echo test page) → a row tagged WS with status 101, open, then closed with byte counts.
- [ ] The WS row opens on Messages: sent (green ↑) and received (blue ↓) messages appear live; selecting one
      shows it in the body viewer; Sent/Received filter, Hide ping/pong and the text filter work.
- [ ] Search for text that only appears in a WebSocket message → the WS row is found.
- [ ] Export as HAR → re-import → the WS row still has its messages.
- [ ] `scripts/release.sh` → `build/dist/Tapwire-<version>.dmg`; mount it and drag Tapwire to Applications; it launches.
- [ ] Certificates → Regenerate CA (confirm) → the new CA must be trusted again; old devices fail until updated.
