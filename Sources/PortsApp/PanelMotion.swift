import AppKit
import SwiftUI

/// A small vocabulary, applied only to deliberate state changes, never polling.
enum PanelMotion {
    #if DEBUG
        static let preview = ProcessInfo.processInfo.environment["PORTS_MOTION_PREVIEW"]
    #else
        static let preview: String? = nil
    #endif

    static func duration(_ seconds: Double) -> Double { seconds * (preview == "slow" ? 10 : 1) }
    static func fade(_ seconds: Double) -> Animation {
        .timingCurve(0.23, 1, 0.32, 1, duration: duration(seconds))
    }
    /// A bounded ease-out keeps the whole transition below its time budget;
    /// a spring's perceptual duration would leave a longer settling tail.
    static func settle(_ seconds: Double) -> Animation {
        .timingCurve(0.25, 1, 0.5, 1, duration: duration(seconds))
    }
    static var resize: Animation {
        settle(0.22)
    }

    @MainActor static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || preview == "reduced"
    }

    /// Read synchronously in the action handler; asynchronous work retains its
    /// own intent. Keyboard and accessibility activations never incur travel.
    @MainActor static var isPointerEvent: Bool {
        guard let type = NSApp.currentEvent?.type else { return false }
        return [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp].contains(type)
    }

    /// The slow preview exercises transitions through Accessibility actions too.
    /// Production keyboard commands still skip spatial transitions.
    @MainActor static var animatesInteraction: Bool {
        preview == "slow" || isPointerEvent
    }
}

/// Interpolates layout itself so AppKit and the notch receive intermediate
/// intrinsic sizes, instead of resizing their windows to the final frame first.
struct AnimatedPanelHeight: AnimatableModifier {
    nonisolated var height: CGFloat
    nonisolated var animatableData: CGFloat {
        get { height }
        set { height = newValue }
    }
    func body(content: Content) -> some View {
        content.frame(height: height, alignment: .top)
    }
}

struct PanelPressFeedback: ViewModifier {
    let isPressed: Bool
    private var accessibility = PanelAccessibility()
    @State private var pointerPress = false

    init(isPressed: Bool) {
        self.isPressed = isPressed
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed && pointerPress && !accessibility.reduceMotion ? 0.96 : 1)
            .animation(accessibility.reduceMotion || isPressed ? nil : PanelMotion.settle(0.12), value: isPressed)
            .onChange(of: isPressed) { _, pressed in
                if pressed { pointerPress = PanelMotion.isPointerEvent }
            }
    }
}

/// Native material is confined to the navigation/controls layer. The content
/// panel keeps its quiet background; a second glass layer is never stacked on it.
struct ControlGlass: ViewModifier {
    let radius: CGFloat
    var usesLiquidGlass = true
    private var accessibility = PanelAccessibility()

    init(radius: CGFloat, usesLiquidGlass: Bool = true) {
        self.radius = radius
        self.usesLiquidGlass = usesLiquidGlass
    }

    func body(content: Content) -> some View {
        if #available(macOS 26, *), usesLiquidGlass && !accessibility.reduceTransparency {
            content.glassEffect(.regular, in: .rect(cornerRadius: radius))
        } else {
            content.background(PanelGlass(radius: radius))
        }
    }
}

/// Observe native preferences, with debug-only overrides for visual checks.
/// SwiftUI's system accessibility environment values are intentionally read-only.
struct PanelAccessibility: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency
    @Environment(\.colorSchemeContrast) private var systemContrast

    var reduceMotion: Bool { systemReduceMotion || PanelMotion.preview == "reduced" }
    var reduceTransparency: Bool { systemReduceTransparency || PanelMotion.preview == "reduced" }
    var contrast: ColorSchemeContrast { PanelMotion.preview == "reduced" ? .increased : systemContrast }
}
