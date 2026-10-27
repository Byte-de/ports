import Testing

@testable import PortsCore

struct ArgumentCacheTests {
    private let identity = ProcessIdentity(pid: 42, startSeconds: 100, startMicroseconds: 1)
    private let node = ArgumentCache.Image(executable: "/usr/local/bin/node", name: "node", hasExecuted: true)
    /// Long after every test identity started, so lookups may be cached.
    private let settled: UInt64 = 1_000

    @Test func readsOnceWhileTheImageIsUnchanged() {
        var cache = ArgumentCache()
        var reads = 0
        for _ in 0..<3 {
            let arguments = cache.arguments(for: identity, image: node, now: settled) {
                reads += 1
                return ["node", "server.js"]
            }
            #expect(arguments == ["node", "server.js"])
        }
        #expect(reads == 1)
        #expect(cache.count == 1)
    }

    @Test func youngProcessesAreReadOnEveryLookupUntilTheyHaveSettled() {
        var cache = ArgumentCache()
        // npm rewrites its argv area in place while starting, so each early read can see a different title.
        var titles = [["node", "npm-cli.js", "run", "dev"], ["npm"], ["npm run dev"]]
        func lookup(now: UInt64) -> [String] {
            cache.arguments(for: identity, image: node, now: now) { titles.isEmpty ? nil : titles.removeFirst() }
        }
        let young = identity.startSeconds + ArgumentCache.settleSeconds - 1
        #expect(lookup(now: young) == ["node", "npm-cli.js", "run", "dev"])
        #expect(lookup(now: young) == ["npm"])
        #expect(cache.count == 0)
        #expect(lookup(now: young + 1) == ["npm run dev"])
        #expect(lookup(now: young + 2) == ["npm run dev"])
        #expect(titles.isEmpty)
        #expect(cache.count == 1)
    }

    @Test func readsAgainAfterExecOrForANewStartTime() {
        var cache = ArgumentCache()
        var reads = 0
        func lookup(_ identity: ProcessIdentity, _ image: ArgumentCache.Image) {
            _ = cache.arguments(for: identity, image: image, now: settled) {
                reads += 1
                return ["argv \(reads)"]
            }
        }
        // A forked node child shows its parent's argv until it execs node again.
        let forked = ArgumentCache.Image(executable: node.executable, name: node.name, hasExecuted: false)
        let otherExecutable = ArgumentCache.Image(executable: "/opt/homebrew/bin/bun", name: "node", hasExecuted: true)
        let bun = ArgumentCache.Image(executable: "/opt/homebrew/bin/bun", name: "bun", hasExecuted: true)
        let restarted = ProcessIdentity(pid: 42, startSeconds: 200, startMicroseconds: 1)
        let changes = [
            (identity, forked), (identity, node), (identity, otherExecutable), (identity, bun), (restarted, bun),
        ]
        for (expected, change) in changes.enumerated() {
            lookup(change.0, change.1)
            #expect(reads == expected + 1)
        }
        lookup(restarted, bun)
        #expect(reads == changes.count)
    }

    @Test func failedReadsAreRetried() {
        var cache = ArgumentCache()
        var reads = 0
        for _ in 0..<2 {
            let arguments = cache.arguments(for: identity, image: node, now: settled) {
                reads += 1
                return nil
            }
            #expect(arguments.isEmpty)
        }
        #expect(reads == 2)
        #expect(cache.count == 0)
    }

    @Test func retainPrunesProcessesNoLongerSeen() {
        var cache = ArgumentCache()
        let other = ProcessIdentity(pid: 43, startSeconds: 100)
        for seen in [identity, other] { _ = cache.arguments(for: seen, image: node, now: settled) { ["node"] } }
        #expect(cache.count == 2)
        cache.retain([other])
        #expect(cache.count == 1)
        var reads = 0
        _ = cache.arguments(for: other, image: node, now: settled) {
            reads += 1
            return ["node"]
        }
        _ = cache.arguments(for: identity, image: node, now: settled) {
            reads += 1
            return ["node"]
        }
        #expect(reads == 1)
    }
}
