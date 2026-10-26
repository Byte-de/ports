import CoreGraphics

/// The window must contain both endpoints while its visible content animates.
/// A superseded completion cannot shrink the canvas of a newer transition.
public struct PanelResizeTransition: Sendable {
    public private(set) var canvas: CGSize
    public private(set) var target: CGSize
    public private(set) var revision: UInt64 = 0
    public private(set) var isAnimating = false

    public init(size: CGSize) {
        canvas = size
        target = size
    }

    @discardableResult public mutating func begin(to size: CGSize, animated: Bool) -> UInt64 {
        revision &+= 1
        target = size
        isAnimating = animated
        canvas = animated ? CGSize(width: max(canvas.width, size.width), height: max(canvas.height, size.height)) : size
        return revision
    }

    @discardableResult public mutating func complete(_ revision: UInt64) -> Bool {
        guard revision == self.revision else { return false }
        canvas = target
        isAnimating = false
        return true
    }
}
