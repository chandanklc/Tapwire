import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import TapwireCore

struct CertificatesWindow: View {
    @Environment(AppModel.self) private var model
    @AppStorage("devices.tab") private var tab = "iphone"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Connect a device").font(GT.engraved(24))
                    Coachline().frame(width: 120)
                    Text("Send a phone's, emulator's or this Mac's traffic through Tapwire.")
                        .font(.system(size: 13)).foregroundStyle(GT.text2)
                }
                Spacer()
                Picker("", selection: $tab) {
                    Text("iPhone").tag("iphone")
                    Text("Android & emulator").tag("android")
                    Text("This Mac").tag("mac")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 12)
            ConnectedDevicesStrip().padding(.horizontal, 24).padding(.bottom, 8)
            Rectangle().fill(GT.line).frame(height: 1)
            Group {
                switch tab {
                case "android": AndroidSetupView()
                case "mac": MacCertificateView()
                default: IPhoneSetupView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(GT.window)
        .frame(minWidth: 760, minHeight: 620)
    }
}

/// Live list of devices that are sending traffic right now.
struct ConnectedDevicesStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let phones = model.traffic.devices.filter { !$0.isLoopback }
        HStack(spacing: 8) {
            if phones.isEmpty {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text("Waiting for a device… once its Wi-Fi proxy points here, it shows up.")
                }
                .font(.system(size: 12)).foregroundStyle(GT.text2)
            } else {
                ForEach(phones.prefix(4)) { d in
                    let live = Date().timeIntervalSince(d.lastSeen) < 120
                    HStack(spacing: 6) {
                        Circle().fill(live ? GT.okDot : GT.lineStrong).frame(width: 7, height: 7)
                        Text(d.label).font(GT.mono(12, .medium))
                        Text("· \(d.total) calls").foregroundStyle(GT.text2)
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 10).frame(height: 24)
                    .background(live ? GT.okSoft : GT.field, in: Capsule())
                    .help(live ? "Connected — last call \(Int(Date().timeIntervalSince(d.lastSeen))) s ago" : "Seen earlier this session")
                }
            }
            Spacer()
        }
    }
}

/// A setup step: "1. Title" gets a numbered gold-ringed disc; other titles an info disc.
struct StepCard<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        let parts = title.split(separator: " ", maxSplits: 1)
        let numbered = parts.count == 2 && parts[0].hasSuffix(".") && Int(parts[0].dropLast()) != nil
        let number = numbered ? String(parts[0].dropLast()) : nil
        let heading = numbered ? String(parts[1]) : title
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(number != nil ? GT.racingGreen : GT.field)
                if let number {
                    Text(number).font(GT.mono(13, .semibold)).foregroundStyle(GT.onPrimary)
                } else {
                    Image(systemName: "info").font(.system(size: 12, weight: .bold)).foregroundStyle(GT.text2)
                }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 6) {
                Text(heading).font(.system(size: 14, weight: .semibold))
                content
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GT.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(GT.line, lineWidth: 1))
    }
}

struct MacCertificateView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmRegenerate = false
    @State private var busy = false

    var body: some View {
        Form {
            Section("Tapwire root certificate") {
                if let ca = model.ca {
                    LabeledContent("Name", value: ca.commonName)
                    LabeledContent("Expires", value: ca.notValidAfter.formatted(date: .long, time: .omitted))
                    LabeledContent("SHA-256") { Text(ca.sha256Fingerprint).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                    LabeledContent("Status") {
                        Label(model.trustStatus.title, systemImage: model.trustStatus == .trusted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(model.trustStatus == .trusted ? .green : .orange)
                    }
                } else {
                    ProgressView("Loading certificate…")
                }
            }
            Section {
                HStack {
                    Button {
                        busy = true
                        Task { await model.installAndTrustCertificate(); busy = false }
                    } label: { Label("Install & Trust (recommended)", systemImage: "checkmark.shield") }
                    .buttonStyle(.borderedProminent)
                    Button { model.installCertificateOpenKeychain() } label: { Label("Install Certificate on this Mac", systemImage: "key") }
                    if busy { ProgressView().controlSize(.small) }
                }
                Text("**Install & Trust** adds the certificate to your login keychain and marks it trusted; macOS asks for your password.")
                    .font(.callout)
                VStack(alignment: .leading, spacing: 4) {
                    Text("To trust it by hand after **Install Certificate on this Mac**:").font(.callout)
                    Text("1. In Keychain Access, choose the **login** keychain and the **Certificates** tab.")
                    Text("2. Search for **Tapwire CA** and double-click it.")
                    Text("3. Expand **Trust** and set **When using this certificate** to **Always Trust**.")
                    Text("4. Close the window and enter your password. Then click Refresh below.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                HStack {
                    Button("Refresh Status") { model.refreshTrustStatus() }
                    Button("Reveal Certificate in Finder") { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.caCertificateFile]) }
                    Button("Remove from Keychain") { Task { await model.removeCertificateFromKeychain() } }
                }
            } header: {
                Text("Trust on this Mac")
            }
            Section {
                Button("Regenerate CA…", role: .destructive) { confirmRegenerate = true }
                Text("Creates a new root certificate. Every device that trusted the old one must install the new one.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Danger zone")
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshTrustStatus() }
        .confirmationDialog("Regenerate the Tapwire CA?", isPresented: $confirmRegenerate) {
            Button("Regenerate", role: .destructive) { Task { await model.regenerateCA() } }
        } message: {
            Text("The current certificate is removed from your keychain and stops working on your phones and emulators.")
        }
    }
}

struct AndroidSetupView: View {
    @Environment(AppModel.self) private var model
    @State private var interfaces = NetworkInfo.ipv4Interfaces()
    @State private var selectedIP = NetworkInfo.primaryIPv4 ?? "127.0.0.1"
    @State private var copied: String?

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
                        Text("Host  \(selectedIP)").font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                        Text("Port  \(String(port))").font(.system(.title3, design: .monospaced)).textSelection(.enabled)
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
                        Text("Scan to download the certificate").font(.caption).foregroundStyle(.secondary)
                    }
                }

                StepCard("1. Point the phone's Wi-Fi at Tapwire") {
                    steps([
                        "Connect the phone to the same Wi-Fi network as this Mac.",
                        "Settings → Network & internet → Internet (or Wi-Fi) → tap the gear next to your network.",
                        "Edit (pencil) → Advanced options → Proxy → Manual.",
                        "Proxy hostname: \(selectedIP) · Proxy port: \(port) → Save.",
                        "Open http://tapwire.cert/ in Chrome: you should see the Tapwire page.",
                    ])
                }
                StepCard("2. Install the Tapwire certificate") {
                    steps([
                        "On http://tapwire.cert/ tap Download (or scan the QR code above).",
                        "Settings → Security & privacy → More security settings → Encryption & credentials → Install a certificate → CA certificate.",
                        "Accept the warning and pick Tapwire-CA.crt from Downloads.",
                        "Check it under Trusted credentials → User.",
                    ])
                }
                StepCard("3. Let your debug build trust user certificates") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Android 7+ apps ignore user-installed CAs unless the app opts in. Add this file as **app/src/debug/res/xml/network_security_config.xml** (or under main/ with debug-overrides only):")
                        ReadOnlyText(text: Self.networkSecurityConfig).frame(height: 150)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
                        HStack {
                            Button("Copy network_security_config.xml") { copy(Self.networkSecurityConfig, "config") }
                            Button("Copy AndroidManifest line") { copy(Self.manifestLine, "manifest") }
                            if let copied { Text("Copied \(copied)").font(.caption).foregroundStyle(.green) }
                        }
                        Text("In AndroidManifest.xml on the <application> element:").font(.callout)
                        Text(Self.manifestLine).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        Text("debug-overrides only applies when android:debuggable is true, so release builds are unaffected.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                StepCard("Android emulator") {
                    steps([
                        "The emulator reaches this Mac at 10.0.2.2.",
                        "Extended controls (…) → Settings → Proxy → Manual proxy configuration: host 10.0.2.2, port \(port). Or start it with: emulator -avd <name> -http-proxy http://10.0.2.2:\(port)",
                        "On API 30+ images you can also set Wi-Fi proxy like a phone (AndroidWifi → Proxy → Manual → 10.0.2.2:\(port)).",
                        "Install the certificate from http://tapwire.cert/ inside the emulator, the same way as on a phone.",
                        "Your app's local dev server on the Mac stays reachable as 10.0.2.2 (or map a host to it with an Environment).",
                    ])
                }
                StepCard("If HTTPS doesn't decrypt") {
                    steps([
                        "Add the host to Settings → SSL Proxying (wildcards like *.myapp.com work), or turn on Decrypt all.",
                        "Apps with certificate pinning (OkHttp CertificatePinner, pin-set in the config) reject Tapwire's certificate. Disable pinning in debug builds.",
                        "Failed handshakes show in the list as red CONNECT rows with an explanation.",
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

    private func copy(_ s: String, _ what: String) {
        copyToPasteboard(s)
        copied = what
    }

    static let networkSecurityConfig = """
    <?xml version="1.0" encoding="utf-8"?>
    <network-security-config>
        <debug-overrides>
            <trust-anchors>
                <!-- Trust user-installed CAs (Tapwire) in debuggable builds only -->
                <certificates src="user" />
                <certificates src="system" />
            </trust-anchors>
        </debug-overrides>
    </network-security-config>
    """

    static let manifestLine = #"android:networkSecurityConfig="@xml/network_security_config""#
}

enum QRCode {
    static func image(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}
