import AppKit
import PortsCore
import SwiftUI

/// Shared by the floating window, menu extra and notch. Dimensions are in points.
enum DS {
    static let panelWidth: CGFloat = 480
    static let panelRadius: CGFloat = 28
    static let navigationSpacing: CGFloat = 9
    static let navigationHeight: CGFloat = 48
    static let notchInset: CGFloat = 10
    static let rowHeight: CGFloat = 64
    static let background = Color(white: 0.045)
    static let surface = Color(white: 0.075)
    static let raised = Color.white.opacity(0.07)
    static let accent = Color(red: 102 / 255, green: 191 / 255, blue: 1)
    static let text = Color(white: 0.94)
    static let muted = Color(white: 0.59)
    static let line = Color.white.opacity(0.12)
    static let orange = Color(red: 0.86, green: 0.56, blue: 0.39)
    static let purple = Color(red: 0.66, green: 0.61, blue: 0.84)
    static let red = Color(red: 0.85, green: 0.37, blue: 0.40)

    static func tint(_ service: ServiceRecord) -> Color {
        if service.provider?.id == "claude" || service.provider?.id == "claude-desktop" { return orange }
        if service.provider?.id == "codex" { return accent }
        if service.kind == .agent { return purple }
        return service.framework == "Vite" ? purple : muted
    }

    static func symbol(_ service: ServiceRecord) -> String {
        service.provider?.symbol ?? (service.framework == "Vite" ? "bolt.fill" : "server.rack")
    }
}

private struct VisualEffect: NSViewRepresentable {
    let radius: CGFloat
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = radius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.layer?.cornerRadius = radius }
}

struct PanelGlass: View {
    var radius: CGFloat = DS.panelRadius
    private var accessibility = PanelAccessibility()

    init(radius: CGFloat = DS.panelRadius) {
        self.radius = radius
    }

    var body: some View {
        ZStack {
            if accessibility.reduceTransparency {
                DS.background
            } else {
                VisualEffect(radius: radius)
                LinearGradient(
                    colors: [.black.opacity(0.92), .black.opacity(0.70)], startPoint: .top, endPoint: .bottom)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(
                    .white.opacity(accessibility.contrast == .increased ? 0.6 : 0.13),
                    lineWidth: accessibility.contrast == .increased ? 1 : 0.75)
        }
        .shadow(color: .black.opacity(0.24), radius: 8, y: 4)
        .allowsHitTesting(false)
    }
}

/// Configure only our own SwiftUI window, never the menu extra or another app's window.
struct FloatingWindowStyle: NSViewRepresentable {
    final class WindowView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
        }
    }
    func makeNSView(context: Context) -> WindowView { WindowView() }
    func updateNSView(_ view: WindowView, context: Context) {}
}

extension View {
    func surface(radius: CGFloat = 12) -> some View {
        background(DS.raised, in: RoundedRectangle(cornerRadius: radius))
    }
    func overline() -> some View {
        font(.system(size: 10, weight: .medium)).tracking(0.8).foregroundStyle(DS.muted)
    }
}

struct ServiceIcon: View {
    let service: ServiceRecord
    var size: CGFloat = 24
    var body: some View {
        Image(systemName: DS.symbol(service))
            .font(.system(size: size * 0.7, weight: .regular))
            .foregroundStyle(DS.tint(service)).frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct StatusLabel: View {
    let state: ProcessState
    var compact = false
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(state == .paused ? DS.orange : DS.accent).frame(width: 5, height: 5)
            if !compact { Text(state == .paused ? "Pausiert" : "Läuft").font(.system(size: 11)) }
        }.foregroundStyle(state == .paused ? DS.orange : DS.accent)
            .accessibilityLabel(state == .paused ? "Pausiert" : "Prozess läuft")
    }
}

struct QuietButton: ButtonStyle {
    var tint: Color = DS.text
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium)).foregroundStyle(tint)
            .padding(.horizontal, 12).frame(minHeight: 40)
            .background(tint.opacity(configuration.isPressed ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 10))
            .modifier(PanelPressFeedback(isPressed: configuration.isPressed))
            .opacity(isEnabled ? 1 : 0.35)
    }
}

struct AccentButton: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium)).foregroundStyle(DS.background)
            .padding(.horizontal, 14).frame(minHeight: 40)
            .background(
                DS.text.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.3),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .modifier(PanelPressFeedback(isPressed: configuration.isPressed))
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var tint: Color = DS.muted
    var selected = false
    var immediateHelp = false
    var systemForeground = false
    let action: () -> Void
    @State private var hovered = false
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var isEnabled
    private var accessibility = PanelAccessibility()

    init(
        symbol: String, help: String, tint: Color = DS.muted, selected: Bool = false,
        immediateHelp: Bool = false, systemForeground: Bool = false, action: @escaping () -> Void
    ) {
        self.symbol = symbol
        self.help = help
        self.tint = tint
        self.selected = selected
        self.immediateHelp = immediateHelp
        self.systemForeground = systemForeground
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .regular))
                .foregroundStyle(
                    systemForeground
                        ? AnyShapeStyle(.primary)
                        : AnyShapeStyle(selected || (hovered && tint == DS.muted) ? DS.text : tint)
                )
                .frame(width: 40, height: 40)
                .background(
                    selected ? Color.white.opacity(0.12) : (hovered ? .white.opacity(0.055) : .clear), in: Circle()
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PanelIconStyle())
        .help(immediateHelp ? "" : help).accessibilityLabel(help)
        .focused($focused)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onHover { hovered = $0 }
        .opacity(isEnabled ? 1 : 0.28)
        .overlay(alignment: .top) {
            if immediateHelp && isEnabled && (hovered || focused) {
                Text(help).font(.system(size: 11, weight: .medium)).foregroundStyle(DS.text)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(DS.surface, in: Capsule())
                    .overlay(Capsule().strokeBorder(DS.line, lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                    .fixedSize().offset(y: -32).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .animation(accessibility.reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
    }
}

/// Alerts stay inside the existing transparent window. Keeping the underlying
/// view mounted preserves draft form fields when an operation reports an error.
private struct PanelAlertModifier<Actions: View>: ViewModifier {
    let title: String
    let message: String?
    let actions: Actions
    func body(content: Content) -> some View {
        content.disabled(message != nil).accessibilityHidden(message != nil)
            .overlay {
                if let message {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(title).font(.system(size: 16, weight: .medium))
                        ScrollView {
                            Text(message).font(.system(size: 12)).foregroundStyle(DS.muted)
                                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        }.frame(height: 100)
                        actions
                    }.padding(20).frame(width: DS.panelWidth - 48)
                        .background(DS.surface, in: RoundedRectangle(cornerRadius: 20))
                        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(DS.line, lineWidth: 0.75))
                        .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
                        .foregroundStyle(DS.text).accessibilityElement(children: .contain)
                        .accessibilityLabel(title)
                }
            }
    }
}

extension View {
    func panelAlert<Actions: View>(
        title: String, message: String?, @ViewBuilder actions: () -> Actions
    ) -> some View {
        modifier(PanelAlertModifier(title: title, message: message, actions: actions()))
    }
}

private struct PanelIconStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(PanelPressFeedback(isPressed: configuration.isPressed))
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 22, weight: .light)).foregroundStyle(DS.muted)
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(DS.text)
            Text(detail).font(.system(size: 11)).foregroundStyle(DS.muted).multilineTextAlignment(.center)
                .lineSpacing(3).frame(maxWidth: 310)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
    }
}

enum Format {
    static func memory(_ bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        if bytes >= 1_073_741_824 { return String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }
        return "\(bytes / 1_048_576) MB"
    }
    static func cpu(_ value: Double?) -> String { value.map { String(format: "%.1f %%", $0) } ?? "—" }
    static func uptime(_ start: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(start)))
        if seconds >= 3600 { return "\(seconds / 3600)h \((seconds % 3600) / 60)m" }
        if seconds >= 60 { return "\(seconds / 60)m" }
        return "\(seconds)s"
    }
    static func path(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

struct Sparkline: View {
    let values: [Double]
    var tint: Color = DS.accent
    var body: some View {
        GeometryReader { geometry in
            let maximum = max(10, values.max() ?? 10)
            Path { path in
                guard values.count > 1 else { return }
                for (index, value) in values.enumerated() {
                    let point = CGPoint(
                        x: geometry.size.width * CGFloat(index) / CGFloat(values.count - 1),
                        y: geometry.size.height * (1 - min(1, value / maximum)))
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }.stroke(tint, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        }.accessibilityLabel("CPU-Verlauf aus \(values.count) Messungen")
    }
}
