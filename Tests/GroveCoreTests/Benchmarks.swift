import Foundation
import Testing

@testable import GroveCore

/// Run with GROVE_BENCH_REPO=/path/to/big/repo swift test -c release --filter Benchmarks
@Suite(.enabled(if: ProcessInfo.processInfo.environment["GROVE_BENCH_REPO"] != nil))
struct Benchmarks {
    @Test func logParseAndLayout() async throws {
        let path = ProcessInfo.processInfo.environment["GROVE_BENCH_REPO"]!
        let repo = try await Repository.open(URL(fileURLWithPath: path))
        let clock = ContinuousClock()
        let start = clock.now
        var first: Duration?
        var firstRecord: Duration?
        var layout = GraphLayout(mainline: await repo.headID())
        var count = 0, maxWidth = 0
        for try await record in repo.logRecords(includeHEAD: true) {
            if firstRecord == nil { firstRecord = clock.now - start }
            guard let c = GitParse.commit(record) else { continue }
            let row = layout.add(id: c.id, parents: c.parents)
            maxWidth = max(maxWidth, row.width)
            count += 1
            if count == 300 { first = clock.now - start }
        }
        let total = clock.now - start
        print("BENCH commits=\(count) firstRecord=\(firstRecord!) first300=\(first!) total=\(total) maxLanes=\(maxWidth)")
        // Raw stream only (no parse / layout).
        let rawStart = clock.now
        var n = 0
        for try await _ in repo.logRecords(includeHEAD: true) { n += 1 }
        print("BENCH rawStream=\(clock.now - rawStart) records=\(n)")
        let statusStart = clock.now
        _ = try await repo.status()
        print("BENCH status=\(clock.now - statusStart)")
    }
}
