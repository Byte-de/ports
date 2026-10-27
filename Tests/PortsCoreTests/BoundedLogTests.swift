import Foundation
import Testing

@testable import PortsCore

struct BoundedLogTests {
    private func makeLog(capacity: Int, _ chunks: [UInt8]...) -> BoundedLog {
        let log = BoundedLog(capacity: capacity)
        for chunk in chunks { log.append(Data(chunk)) }
        return log
    }

    private func text(_ read: BoundedLog.LogRead) -> String { String(decoding: read.bytes, as: UTF8.self) }

    @Test func appendBelowCapacityReadsEverything() {
        let log = makeLog(capacity: 16, Array("hello".utf8), Array(" world".utf8))
        let read = log.read(after: nil)
        #expect(text(read) == "hello world")
        #expect(read.cursor == 11)
        #expect(read.reset)
        #expect(!read.truncated)
        #expect(log.written == 11)
    }

    @Test func wrapKeepsNewestBytesInOrder() {
        let log = makeLog(capacity: 8, Array("abc".utf8), Array("defg".utf8), Array("hij".utf8), Array("k".utf8))
        let read = log.read(after: nil)
        #expect(text(read) == "defghijk")
        #expect(read.cursor == 11)
        #expect(read.truncated)
        log.append(Data("lmnopqr".utf8))
        #expect(text(log.read(after: nil)) == "klmnopqr")
        #expect(text(log.read(after: 15)) == "pqr")
    }

    @Test func oversizedAppendKeepsTail() {
        let log = makeLog(capacity: 4, Array("ab".utf8), Array("0123456789".utf8))
        #expect(text(log.read(after: nil)) == "6789")
        #expect(log.written == 12)
        log.append(Data("xy".utf8))
        let read = log.read(after: nil)
        #expect(text(read) == "89xy")
        #expect(read.cursor == 14)
        #expect(read.truncated)
    }

    @Test func cursorReturnsOnlyNewBytes() {
        let log = makeLog(capacity: 64, Array("one\n".utf8))
        let first = log.read(after: nil)
        #expect(text(first) == "one\n")
        log.append(Data("two\n".utf8))
        let second = log.read(after: first.cursor)
        #expect(text(second) == "two\n")
        #expect(second.cursor == 8)
        #expect(!second.reset)
        let third = log.read(after: second.cursor)
        #expect(third.bytes.isEmpty)
        #expect(third.cursor == 8)
        #expect(!third.reset)
    }

    @Test func incompleteTrailingUTF8IsHeldBack() {
        let euro = Array("€".utf8)
        let log = makeLog(capacity: 64, Array("a".utf8) + euro.prefix(2))
        let first = log.read(after: nil)
        #expect(text(first) == "a")
        #expect(first.cursor == 1)
        #expect(log.read(after: first.cursor).bytes.isEmpty)
        log.append(Data(euro.suffix(1)))
        let second = log.read(after: first.cursor)
        #expect(text(second) == "€")
        #expect(second.cursor == 4)
        #expect(!second.reset)
    }

    @Test func resetSkipsLeadingContinuationBytes() {
        // "€" is E2 82 AC, so a capacity of 3 keeps only its two continuation bytes before "y".
        let log = makeLog(capacity: 3, Array("€y".utf8))
        let read = log.read(after: nil)
        #expect(text(read) == "y")
        #expect(read.cursor == 4)
        // A delta read returns the bytes unchanged.
        #expect(log.read(after: 1).bytes == [0x82, 0xAC, 0x79])
    }

    @Test func staleCursorResets() {
        let log = makeLog(capacity: 8, Array("0123456789".utf8))
        let behind = log.read(after: 1)
        #expect(behind.reset)
        #expect(text(behind) == "23456789")
        #expect(log.read(after: 11).reset)
        let current = log.read(after: 2)
        #expect(!current.reset)
        #expect(text(current) == "23456789")
    }

    @Test func truncatedResetStartsAtNextLine() {
        // The newest 16 bytes start inside "first line".
        let truncated = makeLog(capacity: 16, Array("first line\nsecond\nthird\n".utf8))
        let read = truncated.read(after: nil)
        #expect(text(read) == "second\nthird\n")
        #expect(read.truncated)
        #expect(text(truncated.read(after: 8)) == "ne\nsecond\nthird\n")
        let complete = makeLog(capacity: 64, Array("first line\nsecond\n".utf8))
        #expect(text(complete.read(after: nil)) == "first line\nsecond\n")
        // A line break further away than 4096 bytes is not searched for.
        let long = makeLog(capacity: 8192, Array(repeating: UInt8(ascii: "x"), count: 9000) + Array("\nend".utf8))
        #expect(long.read(after: nil).bytes.count == 8192)
    }

    @Test func snapshotFlagsTruncation() {
        let log = makeLog(capacity: 8, Array("abc".utf8))
        let complete = log.snapshot()
        #expect(complete.text == "abc")
        #expect(!complete.truncated)
        log.append(Data("defghijk".utf8))
        let truncated = log.snapshot()
        #expect(truncated.text == "defghijk")
        #expect(truncated.truncated)
    }

    @Test func concurrentAppendsAreCounted() async {
        let log = BoundedLog(capacity: 1000)
        let chunk = Data("0123456789".utf8)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<1000 { log.append(chunk) }
                }
            }
        }
        #expect(log.written == 80_000)
        // Appends are atomic, so the ring holds whole chunks.
        #expect(text(log.read(after: nil)) == String(repeating: "0123456789", count: 100))
    }
}
