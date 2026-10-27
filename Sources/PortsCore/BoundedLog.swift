import Foundation

/// Launch output kept in a fixed-size ring of bytes. The pipe callback appends synchronously and copies at most
/// twice, so noisy children can neither queue unlimited Tasks nor trigger work proportional to the capacity.
/// Every byte ever appended has a position, which readers pass back as a cursor to receive only what is new.
final class BoundedLog: @unchecked Sendable {
    struct LogRead: Equatable {
        var bytes: [UInt8]
        /// Position after the last returned byte; pass it to the next read.
        var cursor: UInt64
        /// The bytes replace everything read before, because the cursor was missing or no longer valid.
        var reset: Bool
        /// Older bytes were discarded.
        var truncated: Bool
    }

    static let capacity = 262_144
    /// A truncated reset only drops a partial first line when its end is this close.
    private static let lineSearchLimit = 4096

    let capacity: Int
    private let lock = NSLock()
    /// Grows until it reaches the capacity, then wraps; `head` is the oldest byte once it is full.
    private var storage: [UInt8] = []
    private var head = 0
    private var total: UInt64 = 0

    init(capacity: Int = BoundedLog.capacity) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    /// The number of bytes ever appended, which is the cursor space.
    var written: UInt64 { lock.withLock { total } }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        data.withUnsafeBytes { source in lock.withLock { write(source) } }
    }

    func read(after cursor: UInt64?) -> LogRead {
        lock.withLock {
            let lower = total - UInt64(storage.count)
            let truncated = lower > 0
            guard let cursor, cursor >= lower, cursor <= total else {
                let bytes = retained(from: lower)
                var start = 0
                // The oldest byte may be in the middle of a character or, after truncation, of a line.
                while start < min(3, bytes.count), Self.isContinuation(bytes[start]) { start += 1 }
                if truncated,
                    let newline = bytes[start..<min(bytes.count, start + Self.lineSearchLimit)].firstIndex(of: 0x0A)
                {
                    start = newline + 1
                }
                return complete(bytes, from: start, reset: true, truncated: truncated)
            }
            return complete(retained(from: cursor), from: 0, reset: false, truncated: truncated)
        }
    }

    func snapshot() -> (text: String, truncated: Bool) {
        let read = read(after: nil)
        return (String(decoding: read.bytes, as: UTF8.self), read.truncated)
    }

    /// Caller holds the lock.
    private func write(_ source: UnsafeRawBufferPointer) {
        total += UInt64(source.count)
        guard source.count < capacity else {
            storage = Array(UnsafeRawBufferPointer(rebasing: source.suffix(capacity)))
            head = 0
            return
        }
        let room = capacity - storage.count
        storage.append(contentsOf: UnsafeRawBufferPointer(rebasing: source.prefix(room)))
        guard source.count > room else { return }
        let rest = UnsafeRawBufferPointer(rebasing: source.dropFirst(room))
        let first = min(rest.count, capacity - head)
        storage.withUnsafeMutableBytes { ring in
            UnsafeMutableRawBufferPointer(rebasing: ring[head..<(head + first)])
                .copyMemory(from: UnsafeRawBufferPointer(rebasing: rest.prefix(first)))
            UnsafeMutableRawBufferPointer(rebasing: ring[..<(rest.count - first)])
                .copyMemory(from: UnsafeRawBufferPointer(rebasing: rest.dropFirst(first)))
        }
        head = (head + rest.count) % capacity
    }

    /// The retained bytes from `start` to the newest one, in order. Caller holds the lock.
    private func retained(from start: UInt64) -> [UInt8] {
        let count = Int(total - start)
        guard count > 0 else { return [] }
        let begin = (head + storage.count - count) % storage.count
        let first = min(count, storage.count - begin)
        var result: [UInt8] = []
        result.reserveCapacity(count)
        result.append(contentsOf: storage[begin..<(begin + first)])
        result.append(contentsOf: storage[..<(count - first)])
        return result
    }

    /// Holds back a trailing character that still lacks bytes; the cursor then points at its first byte.
    private func complete(_ bytes: [UInt8], from start: Int, reset: Bool, truncated: Bool) -> LogRead {
        let end = max(start, bytes.count - Self.incompleteSuffixLength(bytes))
        return LogRead(
            bytes: Array(bytes[start..<end]), cursor: total - UInt64(bytes.count - end), reset: reset,
            truncated: truncated)
    }

    private static func isContinuation(_ byte: UInt8) -> Bool { byte & 0xC0 == 0x80 }

    private static func incompleteSuffixLength(_ bytes: [UInt8]) -> Int {
        for length in 1...3 where length <= bytes.count && !isContinuation(bytes[bytes.count - length]) {
            let lead = bytes[bytes.count - length]
            let needed = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
            return length < needed ? length : 0
        }
        return 0
    }
}
