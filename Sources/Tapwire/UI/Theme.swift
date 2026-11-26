import AppKit
import SwiftUI
import TapwireCore

// MARK: - Palette ("British GT": racing green, metallic sage, sunset gold, burgundy, ivory)

/// Colours that follow the window's light/dark appearance.
enum GT {
    private static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(rgb: isDark ? dark : light)
        })
    }

    // Surfaces
    static let window = dyn(0xF3EEE3, 0x0F1914)
    static let panel = dyn(0xFFFDF8, 0x13201A)
    static let subtle = dyn(0xEDE6D7, 0x0D1611)
    static let rail = dyn(0x163126, 0x07100C)
    static let field = dyn(0xE7DFCE, 0x1C2B24)
    static let selection = dyn(0xE2E9DB, 0x24392E)
    static let line = dyn(0xE2D9C7, 0x21322A)
    static let lineStrong = dyn(0xCDBFA6, 0x33473D)

    // Text
    static let text = dyn(0x1B211D, 0xF1EADB)
    static let text2 = dyn(0x565D57, 0xA9B2A6)
    static let onRail = dyn(0xB9C4B5, 0x8E9A8E)

    // Brand
    static let racingGreen = dyn(0x1F4A38, 0xC9A46A) // primary action colour (gold on dark)
    static let onPrimary = dyn(0xFFFFFF, 0x14110A)
    static let gold = dyn(0xB08A47, 0xC9A46A)
    static let goldBright = Color(nsColor: NSColor(rgb: 0xE3C78F))
    static let goldRing = Color(nsColor: NSColor(rgb: 0xC9A46A))
    static let champagne = dyn(0xF1E6CE, 0x2E2614)
    static let burgundy = dyn(0x7E2A36, 0xDE9099)
    static let paint1 = dyn(0x24473A, 0x3E6B57)
    static let paint2 = dyn(0x8FA88A, 0xB7C9A8)

    // Methods
    static let get = dyn(0x1F5A43, 0x86C2A2)
    static let post = dyn(0x8C2F3C, 0xDE9099)
    static let put = dyn(0x2F5677, 0x93B4D6)
    static let patch = dyn(0x6B3A62, 0xC9A1C5)
    static let delete = dyn(0xA3262A, 0xE57C7E)

    // Status
    static let ok = dyn(0x2F6B4A, 0x86C9A2)
    static let okSoft = dyn(0xDDEBDF, 0x173326)
    static let okDot = dyn(0x3F8A61, 0x6FB98F)
    static let info = dyn(0x2F5677, 0x93B4D6)
    static let infoSoft = dyn(0xDEE6EE, 0x1A2732)
    static let warn = dyn(0x7D5F24, 0xDDBA75)
    static let warnSoft = dyn(0xF1E6CC, 0x2E2614)
    static let err = dyn(0xA3262A, 0xE57C7E)
    static let errSoft = dyn(0xF4DCDA, 0x3A1B1D)
    static let tunnel = dyn(0x6B3A62, 0xC9A1C5)
    static let tunnelSoft = dyn(0xEBDDE7, 0x2C1F2B)

    static func method(_ m: String) -> Color {
        switch m.uppercased() {
        case "GET", "HEAD": return get
        case "POST": return post
        case "PUT": return put
        case "PATCH": return patch
        case "DELETE": return delete
        default: return text2
        }
    }

    // Type
    /// Engraved capitals for the crest and section titles (ships with macOS).
    static func engraved(_ size: CGFloat, bold: Bool = true) -> Font {
        .custom(bold ? "Copperplate-Bold" : "Copperplate", size: size)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Small spaced capitals, like a vintage dashboard label.
    static let label = Font.system(size: 10.5, weight: .semibold)
}

extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

// MARK: - Building blocks

/// Round "TW" crest in gold on racing green.
struct Crest: View {
    var size: CGFloat = 40
    var body: some View {
        ZStack {
            Circle().fill(GT.rail)
            Circle().strokeBorder(GT.goldRing, lineWidth: 1.5)
            Circle().strokeBorder(GT.goldRing.opacity(0.55), lineWidth: 1).padding(4)
            Text("TW").font(GT.engraved(size * 0.36)).foregroundStyle(GT.goldBright)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Tapwire")
    }
}

/// Gold double pinstripe, like a coachline on a car.
struct Coachline: View {
    var body: some View {
        VStack(spacing: 2) {
            Rectangle().fill(GT.gold).frame(height: 1)
            Rectangle().fill(GT.gold.opacity(0.45)).frame(height: 1)
        }
        .accessibilityHidden(true)
    }
}

/// Section label in spaced capitals.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(GT.label).tracking(1.4).foregroundStyle(GT.text2)
    }
}

struct MethodBadge: View {
    let method: String
    var width: CGFloat = 62
    var body: some View {
        let c = GT.method(method)
        Text(method.uppercased())
            .font(GT.mono(11, .semibold))
            .foregroundStyle(c)
            .lineLimit(1)
            .frame(width: width, height: 18)
            .background(method == "CONNECT" ? GT.field : c.opacity(0.13), in: RoundedRectangle(cornerRadius: 5))
    }
}

enum PillKind {
    case ok, info, warn, err, tunnel, pending, paused, mocked

    var ink: Color {
        switch self {
        case .ok: return GT.ok
        case .info: return GT.info
        case .warn: return GT.warn
        case .err: return GT.err
        case .tunnel: return GT.tunnel
        case .pending: return GT.text2
        case .paused: return GT.burgundy
        case .mocked: return GT.gold
        }
    }

    var soft: Color {
        switch self {
        case .ok: return GT.okSoft
        case .info: return GT.infoSoft
        case .warn: return GT.warnSoft
        case .err: return GT.errSoft
        case .tunnel: return GT.tunnelSoft
        case .pending: return GT.field
        case .paused: return GT.champagne
        case .mocked: return GT.champagne
        }
    }

    static func forStatus(_ code: Int) -> PillKind {
        switch code {
        case 200..<300: return .ok
        case 300..<400: return .info
        case 400..<500: return .warn
        default: return .err
        }
    }
}

struct Pill: View {
    let text: String
    let kind: PillKind
    var mono = true
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(kind.ink).frame(width: 6, height: 6)
            Text(text).font(mono ? GT.mono(11, .semibold) : .system(size: 11, weight: .semibold)).lineLimit(1)
        }
        .foregroundStyle(kind.ink)
        .padding(.leading, 7).padding(.trailing, 8).padding(.vertical, 2)
        .background(kind.soft, in: Capsule())
        .fixedSize()
    }
}

/// The status pill for a call, as shown in the list and the details header.
struct ExchangeStatusPill: View {
    let e: CapturedExchange
    var long = false

    var body: some View {
        let (text, kind) = Self.describe(e, long: long)
        Pill(text: text, kind: kind, mono: text.first?.isNumber == true)
            .help(e.error ?? e.statusText)
    }

    static func describe(_ e: CapturedExchange, long: Bool) -> (String, PillKind) {
        switch e.state {
        case .pausedRequest, .pausedResponse: return ("Paused", .paused)
        case .failed: return ("Failed", .err)
        case .aborted: return ("Aborted", .err)
        case .open: return (e.kind == .websocket ? "WebSocket" : "Tunnel", .tunnel)
        case .pending, .receiving: return ("Pending", .pending)
        case .completed:
            if e.kind == .tunnel { return ("Tunnel", .tunnel) }
            guard let r = e.response else { return ("Done", .ok) }
            let text = long ? "\(r.status) \(r.reason)" : "\(r.status)"
            return (text, PillKind.forStatus(r.status))
        }
    }
}

/// A small icon button for the top bar and inspector actions.
struct IconButton: View {
    let systemImage: String
    let help: String
    var title: String?
    var tint: Color = GT.text2
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 13, weight: .medium))
                if let title { Text(title).font(.system(size: 12.5, weight: .medium)) }
            }
            .foregroundStyle(tint)
            .padding(.horizontal, title == nil ? 7 : 9)
            .frame(minWidth: 30, minHeight: 28)
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(HoverButtonStyle())
        .help(help)
        .accessibilityLabel(title ?? help)
    }
}

struct HoverButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background((configuration.isPressed || hovering) ? GT.field : .clear, in: RoundedRectangle(cornerRadius: 7))
            .onHover { hovering = $0 }
    }
}

/// Filled capsule button (recording, environment).
struct CapsuleButtonStyle: ButtonStyle {
    var fill: Color = GT.field
    var ink: Color = GT.text
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(ink)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(fill.opacity(configuration.isPressed ? 0.7 : 1), in: Capsule())
    }
}

/// Primary / secondary / danger buttons (breakpoint actions and setup).
struct GTButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, danger }
    var kind: Kind = .secondary
    func makeBody(configuration: Configuration) -> some View {
        let (bg, fg): (Color, Color) = {
            switch kind {
            case .primary: return (GT.racingGreen, GT.onPrimary)
            case .secondary: return (GT.field, GT.text)
            case .danger: return (GT.errSoft, GT.err)
            }
        }()
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(bg.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Activity sparkline (seven bars).
struct Sparkline: View {
    let values: [Int]
    var body: some View {
        let peak = max(values.max() ?? 1, 1)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                RoundedRectangle(cornerRadius: 1)
                    .fill(GT.gold.opacity(v == 0 ? 0.25 : 0.7))
                    .frame(width: 2, height: max(2, CGFloat(v) / CGFloat(peak) * 13))
            }
        }
        .frame(height: 14, alignment: .bottom)
        .accessibilityHidden(true)
    }
}
