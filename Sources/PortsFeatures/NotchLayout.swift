import CoreGraphics

/// The geometry NotchLayout needs from an NSScreen, in global screen coordinates (origin at the bottom left).
public struct NotchScreen: Equatable, Sendable {
    /// The display's CGDirectDisplayID, for logging.
    public var id: UInt32
    public var frame: CGRect
    public var visibleFrame: CGRect
    public var safeAreaTop: CGFloat
    public var auxiliaryTopLeft: CGRect?
    public var auxiliaryTopRight: CGRect?

    public init(
        id: UInt32, frame: CGRect, visibleFrame: CGRect, safeAreaTop: CGFloat = 0, auxiliaryTopLeft: CGRect? = nil,
        auxiliaryTopRight: CGRect? = nil
    ) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.safeAreaTop = safeAreaTop
        self.auxiliaryTopLeft = auxiliaryTopLeft
        self.auxiliaryTopRight = auxiliaryTopRight
    }
}

/// Where the notch panel sits. Its compact element never covers another app: on a notched screen it fills exactly the
/// notch until the pointer or keyboard focus reaches it, or a public share is active, and only then grows ears beside
/// the notch. A plain screen has only a thin hot zone at the top centre that reveals a pill inside the menu bar.
public enum NotchLayout {
    public static let earWidth: CGFloat = 56
    public static let plainCompactWidth: CGFloat = 148
    /// Between the menu bar and the expanded card.
    public static let gap: CGFloat = 3
    public static let hotZoneHeight: CGFloat = 4
    /// A lower menu bar is hidden: it auto-hides, or a full-screen app took the screen.
    public static let minimumMenuBarHeight: CGFloat = 18

    /// The notched built-in display wherever it is in the arrangement, otherwise the primary screen with the menu bar.
    /// Never the screen with keyboard focus, which would move the panel whenever another display's window is clicked.
    public static func preferredScreen(_ screens: [NotchScreen]) -> NotchScreen? {
        screens.first { notch($0) != nil } ?? screens.first
    }

    public static func menuBarHeight(_ screen: NotchScreen) -> CGFloat {
        max(screen.safeAreaTop, screen.frame.maxY - screen.visibleFrame.maxY)
    }

    /// The strip between the two unobscured top areas. Built from their widths, which do not depend on the coordinate
    /// space the areas are reported in.
    public static func notch(_ screen: NotchScreen) -> CGRect? {
        guard screen.safeAreaTop > 0, let left = screen.auxiliaryTopLeft, let right = screen.auxiliaryTopRight else {
            return nil
        }
        let width = screen.frame.width - left.width - right.width
        guard width > 0 else { return nil }
        return CGRect(
            x: screen.frame.minX + left.width, y: screen.frame.maxY - screen.safeAreaTop, width: width,
            height: screen.safeAreaTop)
    }

    /// Whether the compact element shows its counts: in ears beside the notch, or in the pill on a plain screen.
    /// `hovering` covers the pointer and keyboard focus. A share keeps the ears beside a notch visible; on a plain
    /// screen the menu bar item shows it.
    public static func revealsCounts(_ screen: NotchScreen, hovering: Bool, sharing: Bool = false) -> Bool {
        hovering || (sharing && notch(screen) != nil)
    }

    /// The compact element's frame, or nil while the menu bar of a plain screen is hidden.
    public static func compactFrame(_ screen: NotchScreen, hovering: Bool, sharing: Bool = false) -> CGRect? {
        let height = menuBarHeight(screen)
        let revealed = revealsCounts(screen, hovering: hovering, sharing: sharing)
        if let notch = notch(screen) {
            guard revealed else { return notch }
            return frame(screen, size: CGSize(width: notch.width + 2 * earWidth, height: height))
        }
        guard height >= minimumMenuBarHeight else { return nil }
        return frame(screen, size: CGSize(width: plainCompactWidth, height: revealed ? height : hotZoneHeight))
    }

    /// The expanded canvas: top-anchored at the screen top, so it grows out of the compact element, with its content
    /// `contentOffset` below that, under the menu bar.
    public static func panelFrame(_ screen: NotchScreen, content: CGSize) -> CGRect {
        frame(screen, size: CGSize(width: content.width, height: contentOffset(screen) + content.height))
    }

    public static func contentOffset(_ screen: NotchScreen) -> CGFloat { menuBarHeight(screen) + gap }

    /// A frame of `size` at the top of the screen, centred on the notch or on the screen.
    public static func frame(_ screen: NotchScreen, size: CGSize) -> CGRect {
        let midX = notch(screen)?.midX ?? screen.frame.midX
        return CGRect(
            x: midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height)
    }
}
