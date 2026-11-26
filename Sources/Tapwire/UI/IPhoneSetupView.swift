import SwiftUI
import TapwireCore

/// Step-by-step setup for an iPhone or iPad on the same Wi-Fi, and for the iOS Simulator.
struct IPhoneSetupView: View {
    @Environment(AppModel.self) private var model
    @State private var interfaces = NetworkInfo.ipv4Interfaces()
    @State private var selectedIP = NetworkInfo.primaryIPv4 ?? "127.0.0.1"

    var port: Int { model.listeningPort ?? model.settings.port }
    var certURL: String { "http://\(selectedIP):\(port)/cert" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Proxy address").font(.headline)
                        HStack {
                            Picker("Mac IP", selection: $selectedIP) {
                                ForEach(interfaces) { Text("\($0.address)  (\($0.name))").tag($0.address) }
                                if interfaces.isEmpty { Text("127.0.0.1").tag("127.0.0.1") }
                            }
                            .fixedSize()
                            Button { interfaces = NetworkInfo.ipv4Interfaces() } label: { Image(systemName: "arrow.clockwise") }
                        }
                        Text("Server  \(selectedIP)").font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                        Text("Port    \(String(port))").font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                        if !model.isRunning { Label("The proxy is stopped.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                        if !model.settings.listenOnAllInterfaces {
                            Label("Listening on this Mac only: turn on \"Listen on all interfaces\" in Settings.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                        Text("Certificate: \(certURL)  or  http://tapwire.cert/ (once the proxy is set)")
                            .font(.callout).textSelection(.enabled)
                    }
                    Spacer()
                    VStack {
                        if let img = QRCode.image(for: certURL) {
                            Image(nsImage: img).interpolation(.none).resizable().frame(width: 170, height: 170)
                        }
                        Text("Scan with the iPhone Camera").font(.caption).foregroundStyle(.secondary)
                    }
                }

                GroupBox("1. Point the iPhone's Wi-Fi at Tapwire") {
                    steps([
                        "Connect the iPhone to the same Wi-Fi network as this Mac.",
                        "Settings → Wi-Fi → tap ⓘ next to your network → Configure Proxy → Manual.",
                        "Server: \(selectedIP) · Port: \(port) · Authentication off → Save.",
                    ])
                }
                GroupBox("2. Download and install the certificate") {
                    steps([
                        "Open http://tapwire.cert/ in Safari (other browsers can't install profiles), or scan the QR code above.",
                        "Tap Download, then Allow. iOS says \"Profile Downloaded\".",
                        "Settings → Profile Downloaded (near the top) → Install → enter your passcode → Install.",
                    ])
                }
                GroupBox("3. Turn on full trust (required)") {
                    VStack(alignment: .leading, spacing: 6) {
                        steps([
                            "Settings → General → About → Certificate Trust Settings (at the bottom).",
                            "Under \"Enable full trust for root certificates\", turn on Tapwire → Continue.",
                        ])
                        Text("Without this step the profile is installed but HTTPS still fails.")
                            .font(.caption).foregroundStyle(.secondary).padding(.leading, 4)
                    }
                }
                GroupBox("4. Decrypt your app's traffic") {
                    steps([
                        "In Tapwire, add your API host to Settings → SSL Proxying (e.g. *.myapp.com), or turn on Decrypt all.",
                        "Open your app: its calls appear with a green open lock.",
                    ])
                }
                GroupBox("iOS Simulator") {
                    steps([
                        "The Simulator uses this Mac's network settings, so turn on Use as System Proxy in Tapwire.",
                        "On the Mac, open http://127.0.0.1:\(port)/cert to save Tapwire-CA.crt, then drag the file onto the Simulator window and install the profile (Settings → Profile Downloaded → Install).",
                        "In the Simulator: Settings → General → About → Certificate Trust Settings → turn on Tapwire.",
                    ])
                }
                GroupBox("If HTTPS doesn't decrypt") {
                    steps([
                        "Check step 3: Certificate Trust Settings must show Tapwire turned on.",
                        "Apps that pin certificates (URLSession pinning, TrustKit, Alamofire ServerTrustManager) reject Tapwire's certificate. Turn pinning off in debug builds.",
                        "Some Apple services pin their certificates and never decrypt; leave their hosts out of SSL Proxying.",
                        "Failed handshakes show as red CONNECT rows with an explanation.",
                        "When you're done, set the iPhone's proxy back to Off, or it loses internet once Tapwire stops.",
                    ])
                }
            }
            .padding(20)
        }
    }

    private func steps(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, s in
                HStack(alignment: .firstTextBaseline) {
                    Text("\(i + 1).").foregroundStyle(.secondary).monospacedDigit()
                    Text(s).textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(4)
    }
}
