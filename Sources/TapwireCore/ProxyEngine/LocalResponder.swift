import Foundation
import NIOHTTP1

/// Answers requests addressed to the proxy itself: the CA download at http://tapwire.cert/
/// and http://<mac-ip>:<port>/cert, plus a small landing page.
enum LocalResponder {
    static let certHost = "tapwire.cert"

    struct Response {
        var status: Int
        var headers: [HeaderField]
        var body: Data
    }

    static func text(_ status: Int, _ message: String) -> Response {
        Response(status: status, headers: [HeaderField("Content-Type", "text/plain; charset=utf-8")], body: Data(message.utf8))
    }

    static func response(for head: HTTPRequestHead, engine: ProxyEngine) -> Response? {
        let path: String
        if let url = ParsedURL(string: head.uri) {
            guard url.host.lowercased() == certHost else { return nil }
            path = url.path
        } else if head.uri.hasPrefix("/") {
            // Origin-form request sent straight to the proxy port.
            if let host = head.headers["Host"].first, let (name, port) = ParsedURL.splitAuthority(host) {
                let isUs = name.lowercased() == certHost || port == engine.port
                    || NetworkInfo.isLocalAddress(name)
                guard isUs else { return nil }
            }
            path = String(head.uri.split(separator: "?", maxSplits: 1).first ?? "/")
        } else {
            return nil
        }
        return route(path.lowercased(), engine: engine)
    }

    private static func route(_ path: String, engine: ProxyEngine) -> Response {
        let ca = engine.ca
        switch path {
        case "/cert", "/cert.crt", "/cert.pem", "/ssl", "/ca", "/ca.crt":
            return Response(status: 200, headers: [
                HeaderField("Content-Type", "application/x-x509-ca-cert"),
                HeaderField("Content-Disposition", "attachment; filename=\"Tapwire-CA.crt\""),
                HeaderField("Cache-Control", "no-store"),
            ], body: Data(ca.pem.utf8))
        case "/cert.der":
            return Response(status: 200, headers: [
                HeaderField("Content-Type", "application/x-x509-ca-cert"),
                HeaderField("Content-Disposition", "attachment; filename=\"Tapwire-CA.der.crt\""),
            ], body: ca.der)
        case "/", "/index.html":
            let html = """
            <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
            <title>Tapwire</title><style>
            body{font:16px -apple-system,Roboto,sans-serif;max-width:560px;margin:32px auto;padding:0 16px;color:#1f2937}
            a.btn{display:block;background:#0f766e;color:#fff;text-align:center;padding:14px;border-radius:10px;text-decoration:none;font-weight:600}
            code{background:#f1f5f9;padding:2px 5px;border-radius:4px}</style></head><body>
            <h2>Tapwire certificate</h2>
            <p>Download the Tapwire root certificate to decrypt HTTPS traffic from this device.</p>
            <p><a class="btn" href="/cert">Download Tapwire-CA.crt</a></p>
            <p><b>Android:</b> Settings → Security → Encryption &amp; credentials → Install a certificate →
            CA certificate → choose <code>Tapwire-CA.crt</code>.</p>
            <p>Your app must trust user CAs in debug builds (<code>network_security_config.xml</code>).</p>
            <p style="color:#64748b;font-size:13px">\(ca.commonName)<br>SHA-256 \(ca.sha256Fingerprint)</p>
            </body></html>
            """
            return Response(status: 200, headers: [HeaderField("Content-Type", "text/html; charset=utf-8")], body: Data(html.utf8))
        default:
            return text(404, "Not found. Open http://\(certHost)/ to download the Tapwire certificate.")
        }
    }
}
