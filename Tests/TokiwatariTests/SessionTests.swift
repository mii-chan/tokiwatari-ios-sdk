#if DEBUG
import Foundation
import Synchronization
import Testing
@testable import Tokiwatari

@Suite struct SessionTests {

    @Test func concurrentNextIsStrictlyMonotonic() {
        let session = TokiwatariLogSession()
        let threadCount = 8
        let callsPerThread = 2500
        let total = threadCount * callsPerThread

        let collected = Mutex<[[Int64]]>(Array(repeating: [], count: threadCount))
        let sessionIds = Mutex<Set<String>>([])

        DispatchQueue.concurrentPerform(iterations: threadCount) { index in
            var local: [Int64] = []
            local.reserveCapacity(callsPerThread)
            var ids: Set<String> = []
            for _ in 0..<callsPerThread {
                let (sessionId, sequence) = session.next()
                ids.insert(sessionId)
                local.append(sequence)
            }
            collected.withLock { $0[index] = local }
            sessionIds.withLock { $0.formUnion(ids) }
        }

        let perThread = collected.withLock { $0 }

        // Strictly increasing within each thread's observation order.
        for local in perThread {
            #expect(local.count == callsPerThread)
            #expect(zip(local, local.dropFirst()).allSatisfy { $0 < $1 })
        }

        // Globally: exactly 1...total with no duplicates and no gaps.
        let all = perThread.flatMap { $0 }
        #expect(all.count == total)
        #expect(Set(all).count == total)
        #expect(all.min() == 1)
        #expect(all.max() == Int64(total))

        // No session boundary occurred during the hammering.
        #expect(sessionIds.withLock { $0 }.count == 1)
    }

    @Test func startNewSessionResetsIdAndSequence() {
        let session = TokiwatariLogSession()
        let first = session.next()
        #expect(first.sequence == 1)

        session.startNewSession()
        let second = session.next()
        #expect(second.sequence == 1)
        #expect(second.sessionId != first.sessionId)
        #expect(session.currentId == second.sessionId)
    }

    @Test func timeoutBoundaryStartsNewSessionOnForeground() {
        let session = TokiwatariLogSession(timeout: 60)
        let first = session.next()

        // Not timed out yet: same session.
        session.startNewSessionIfTimedOut(now: Date().addingTimeInterval(30))
        #expect(session.currentId == first.sessionId)

        // Timed out: new session, sequence reset.
        session.startNewSessionIfTimedOut(now: Date().addingTimeInterval(120))
        #expect(session.currentId != first.sessionId)
        #expect(session.next().sequence == 1)
    }
}
#endif
