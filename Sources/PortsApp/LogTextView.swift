import AppKit
import PortsCore
import SwiftUI

/// Reads a job's output for a log view, only what is new since the last read. The output page runs it only while its
/// surface is on screen, so a hidden or idle log costs one cheap read per tick and no text layout.
@MainActor
final class LogFeed {
    private static let interval: Duration = .milliseconds(500)
    private var cursor: UInt64?
    private var generation = 0
    /// Receives every reset and every read with new text. A new receiver, such as a recreated text view, starts with
    /// all of the retained output.
    var sink: ((LaunchOutput) -> Void)? {
        didSet {
            generation &+= 1
            cursor = nil
        }
    }
    /// Shows the newest output and follows it again.
    var scrollToEnd: (() -> Void)?

    func run(job: UUID, launcher: LaunchManager) async {
        // A run the page replaced may still wait for its read, which then belongs to neither cursor.
        generation &+= 1
        while !Task.isCancelled {
            let reading = generation
            if let output = await launcher.output(for: job, after: cursor), reading == generation {
                cursor = output.cursor
                if output.reset || !output.text.isEmpty { sink?(output) }
            }
            do { try await Task.sleep(for: Self.interval) } catch { return }
        }
    }
}

/// Selectable, wrapping plain text in a TextKit 2 text view. New output is appended instead of laying out the whole log
/// again, and the view follows the end while it is scrolled to the bottom. Reports go out on the next main-actor turn,
/// because they arrive during AppKit updates.
struct LogTextView: NSViewRepresentable {
    let feed: LogFeed
    /// The job's name, for VoiceOver.
    let name: String
    let onFollowChange: (Bool) -> Void
    let onEmptyChange: (Bool) -> Void
    /// New output arrived below the visible text since following stopped. Reported once until it follows again.
    let onUnseenOutput: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.appearance = NSAppearance(named: .darkAqua)
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.allowsUndo = false
            textView.drawsBackground = false
            textView.textContainerInset = NSSize(width: 16, height: 12)
            textView.typingAttributes = Coordinator.attributes
        }
        let coordinator = context.coordinator
        coordinator.attach(to: scrollView, view: self)
        feed.sink = { [weak coordinator] output in coordinator?.apply(output) }
        feed.scrollToEnd = { [weak coordinator] in coordinator?.scrollToEnd() }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject {
        static let attributes: [NSAttributedString.Key: Any] = {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byCharWrapping
            return [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor(DS.text), .paragraphStyle: paragraph,
            ]
        }()
        /// Scrolled this close to the end still counts as at the end.
        private static let followTolerance: CGFloat = 24
        /// Appends would otherwise grow the text without bound; trimming keeps whole lines of the newest text.
        private static let maximumLength = 600_000
        private static let trimmedLength = 400_000

        private weak var scrollView: NSScrollView?
        private var view: LogTextView?
        private var following = true
        private var reportedEmpty: Bool?
        private var reportedUnseen = false
        private var scrollingToEnd = false

        private var textView: NSTextView? { scrollView?.documentView as? NSTextView }

        func attach(to scrollView: NSScrollView, view: LogTextView) {
            self.scrollView = scrollView
            update(view)
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(boundsChanged(_:)), name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView)
        }

        func update(_ view: LogTextView) {
            if self.view?.name != view.name {
                textView?.setAccessibilityLabel(
                    String(
                        localized: "Output of \(view.name)",
                        comment: "VoiceOver label of a launched action's output; the argument is the action's name"))
            }
            self.view = view
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
        }

        func apply(_ output: LaunchOutput) {
            guard let textView, let storage = textView.textStorage else { return }
            let text = NSAttributedString(string: output.text, attributes: Self.attributes)
            storage.beginEditing()
            if output.reset { storage.setAttributedString(text) } else { storage.append(text) }
            if storage.length > Self.maximumLength { trim(storage) }
            storage.endEditing()
            if output.reset || following {
                scrollToEnd()
            } else if !output.text.isEmpty && !reportedUnseen {
                reportedUnseen = true
                Task { [weak self] in self?.view?.onUnseenOutput() }
            }
            let empty = storage.length == 0
            if empty != reportedEmpty {
                reportedEmpty = empty
                Task { [weak self] in self?.view?.onEmptyChange(empty) }
            }
        }

        func scrollToEnd() {
            scrollingToEnd = true
            textView?.scrollToEndOfDocument(nil)
            scrollingToEnd = false
            setFollowing(true)
        }

        /// Drops the oldest text up to the first line break past the part that is kept, so the view still starts at a
        /// line.
        private func trim(_ storage: NSTextStorage) {
            let start = storage.length - Self.trimmedLength
            let text = storage.mutableString
            let newline = text.range(
                of: "\n", options: .literal, range: NSRange(location: start, length: storage.length - start))
            let end =
                newline.location == NSNotFound
                ? text.rangeOfComposedCharacterSequence(at: start).location : NSMaxRange(newline)
            storage.deleteCharacters(in: NSRange(location: 0, length: end))
        }

        /// Scrolling up stops following; scrolling back to the end resumes it.
        @objc private func boundsChanged(_ notification: Notification) {
            guard !scrollingToEnd, let scrollView, let document = scrollView.documentView else { return }
            setFollowing(scrollView.contentView.bounds.maxY >= document.frame.height - Self.followTolerance)
        }

        private func setFollowing(_ value: Bool) {
            guard value != following else { return }
            following = value
            if value { reportedUnseen = false }
            Task { [weak self] in self?.view?.onFollowChange(value) }
        }
    }
}
