/// Retains outgoing pages until the current transition finishes. Reversals reuse
/// their identities, so the renderer can retarget from its presentation values.
public struct DirectionalTransitionState<Page: Hashable & Sendable>: Sendable {
    public struct Layer: Identifiable, Sendable {
        public let id: Page
        /// The native insertion transition owns the first rendered frame.
        /// Kept separate from the visible target so mounting cannot skip entry.
        public let entryDirection: Double
        public fileprivate(set) var position: Double
        public fileprivate(set) var opacity: Double
    }

    public private(set) var layers: [Layer]
    public private(set) var selection: Page
    public private(set) var revision: UInt64 = 0

    public init(_ selection: Page) {
        self.selection = selection
        layers = [Layer(id: selection, entryDirection: 0, position: 0, opacity: 1)]
    }

    public mutating func select(_ page: Page, forward: Bool, animated: Bool, exitFraction: Double) {
        revision &+= 1
        selection = page
        let direction: Double = forward ? 1 : -1
        if !animated {
            layers = [Layer(id: page, entryDirection: 0, position: 0, opacity: 1)]
            return
        }

        for index in layers.indices {
            let active = layers[index].id == selection
            layers[index].position = active ? 0 : -direction * exitFraction
            layers[index].opacity = active ? 1 : 0
        }
        if !layers.contains(where: { $0.id == page }) {
            layers.append(Layer(id: page, entryDirection: direction, position: 0, opacity: 1))
        }
    }

    @discardableResult public mutating func complete(revision: UInt64) -> Bool {
        guard revision == self.revision else { return false }
        layers = [Layer(id: selection, entryDirection: 0, position: 0, opacity: 1)]
        return true
    }
}
