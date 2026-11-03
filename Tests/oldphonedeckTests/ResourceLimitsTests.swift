import Foundation
import Testing
@testable import oldphonedeck

struct ResourceLimitsTests {
    @Test func httpLimitReleaseAndRepeatedRelease() throws {
        let budget = HTTPConnectionBudget()
        let leases = try (0..<32).map { _ in try #require(budget.acquire()) }
        #expect(budget.count == 32)
        #expect(budget.acquire() == nil)
        leases[0].release()
        leases[0].release()
        let replacement = try #require(budget.acquire())
        #expect(budget.count == 32)
        #expect(budget.acquire() == nil)
        for lease in leases { lease.release() }
        replacement.release()
        #expect(budget.count == 0)
    }

    @Test func httpLeaseDeinitAndConcurrentCloseReleaseOnce() throws {
        let budget = HTTPConnectionBudget(limit: 1)
        var lease = budget.acquire()
        #expect(lease != nil)
        #expect(budget.count == 1)
        lease = nil
        #expect(lease == nil)
        #expect(budget.count == 0)
        let sharedLease = try #require(budget.acquire())
        DispatchQueue.concurrentPerform(iterations: 100) { _ in sharedLease.release() }
        #expect(budget.count == 0)
        let finalLease = try #require(budget.acquire())
        #expect(budget.acquire() == nil)
        finalLease.release()
    }

    @Test func mediaConnectionsAreBoundedIncludingPending() throws {
        let budget = MediaSessionBudget()
        let first = try #require(budget.acquire())
        let second = try #require(budget.acquire())
        #expect(budget.acquire() == nil)
        #expect(budget.producer == nil)
        budget.release(first)
        budget.release(first)
        let replacement = try #require(budget.acquire())
        #expect(budget.acquire() == nil)
        budget.release(second)
        budget.release(replacement)
        #expect(budget.count == 0)
    }

    @Test func pendingClientDoesNotReserveProducerAndSecondCannotDisplaceIt() throws {
        let budget = MediaSessionBudget()
        let pending = try #require(budget.acquire())
        let producer = try #require(budget.acquire())
        #expect(budget.authenticate(producer))
        #expect(!budget.authenticate(pending))
        #expect(!budget.authenticate(producer))
        budget.release(pending)
        #expect(budget.producer == producer)
        budget.release(producer)
        budget.release(producer)
        #expect(budget.producer == nil)
        #expect(!budget.authenticate(producer))
        let replacement = try #require(budget.acquire())
        #expect(budget.authenticate(replacement))
    }

    @Test func frameHandoffCoalescesWhileDestinationIsBlocked() {
        let queue = DispatchQueue(label: "handoff-test")
        let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        queue.async { entered.signal(); resume.wait() }
        #expect(entered.wait(timeout: .now() + 2) == .success)
        var delivered: [Data] = [] // accessed only on queue
        let handoff = LatestFrameHandoff(queue: queue) { delivered.append($0) }
        for i in 0..<10000 { handoff.submit(Data(String(i).utf8)) }
        resume.signal()
        queue.sync { #expect(delivered == [Data("9999".utf8)]) }
    }

    @Test func frameArrivingDuringDeliveryGetsOneLatestFollowup() {
        let queue = DispatchQueue(label: "handoff-reentrant-test")
        let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        var frames: [Data] = []
        let handoff = LatestFrameHandoff(queue: queue) { frame in
            frames.append(frame)
            if frames.count == 1 { entered.signal(); resume.wait() }
            else { done.signal() }
        }
        handoff.submit(Data([1]))
        #expect(entered.wait(timeout: .now() + 2) == .success)
        for _ in 0..<1000 { handoff.submit(Data([2])) }
        handoff.submit(Data([3]))
        resume.signal()
        #expect(done.wait(timeout: .now() + 2) == .success)
        queue.sync { #expect(frames == [Data([1]), Data([3])]) }
        // The idle -> scheduled transition must still work after a complete drain.
        handoff.submit(Data([4]))
        #expect(done.wait(timeout: .now() + 2) == .success)
        queue.sync { #expect(frames.last == Data([4])) }
    }

    @Test func audioUsesProposedTotalAndRestoresCapacity() throws {
        let budget = AudioQueueBudget()
        let first = try #require(budget.reserve(bytes: 6000)) // 187.5 ms
        #expect(budget.reserve(bytes: 2002) == nil)
        #expect(budget.count == 3000)
        let second = try #require(budget.reserve(bytes: 2000))
        #expect(budget.count == 4000)
        #expect(budget.reserve(bytes: 2) == nil)
        budget.complete(frames: first)
        budget.complete(frames: second)
        #expect(budget.count == 0)
        #expect(budget.reserve(bytes: 8000) == 4000)
    }

    @Test func audioRejectsMalformedEmptyAndIndividuallyTooLongChunks() {
        let budget = AudioQueueBudget()
        for bytes in [-2, 0, 1, 8191, 8192, 8194, Int.max] {
            #expect(budget.reserve(bytes: bytes) == nil)
        }
        // 8192 is valid on the wire, but 4096 frames alone exceed the 4000-frame playback budget.
        #expect(budget.count == 0)
    }

    @Test func concurrentAudioAdmissionNeverOverbooks() {
        let budget = AudioQueueBudget()
        DispatchQueue.concurrentPerform(iterations: 100) { _ in _ = budget.reserve(bytes: 200) }
        #expect(budget.count == 4000)
        DispatchQueue.concurrentPerform(iterations: 40) { _ in budget.complete(frames: 100) }
        #expect(budget.count == 0)
    }
}

struct PhoneMediaMessageTests {
    private func parse(_ data: Data, authenticated: Bool = true, token: String = "test-token") -> PhoneMediaMessage? {
        PhoneMediaMessage.parse(data, authenticated: authenticated, token: token)
    }

    @Test func firstMessageRequiresExactAuthentication() {
        #expect(parse(Data("Htest-token".utf8), authenticated: false) == .authentication)
        for wire in ["Hwrong", "Vtest-token", "Atest-token", "Htest-token\n", "H", ""] {
            #expect(parse(Data(wire.utf8), authenticated: false) == nil)
        }
        #expect(parse(Data("He\u{301}".utf8), authenticated: false, token: "é") == nil)
    }

    @Test func authenticationSizeBoundary() {
        let token = String(repeating: "a", count: 255)
        #expect(parse(Data(("H" + token).utf8), authenticated: false, token: token) == .authentication)
        #expect(parse(Data(("H" + token + "a").utf8), authenticated: false, token: token + "a") == nil)
    }

    @Test func unknownAndRepeatedAuthenticationFailClosed() {
        #expect(parse(Data("Htest-token".utf8)) == nil)
        #expect(parse(Data("Xanything".utf8)) == nil)
        #expect(parse(Data()) == nil)
    }

    @Test func videoMaximumAndMalformedEnvelopes() {
        var jpeg = Data([0xff, 0xd8])
        jpeg.append(Data(repeating: 0, count: PhoneMediaMessage.maximumMessageSize - 5))
        jpeg.append(contentsOf: [0xff, 0xd9])
        let wire = Data([UInt8(ascii: "V")]) + jpeg
        #expect(wire.count == 2 * 1024 * 1024)
        #expect(parse(wire) == .video(jpeg))
        #expect(parse(wire + Data([0])) == nil)
        for bad in [Data(), Data([0xff, 0xd8]), Data("not JPEG".utf8), Data([0xff, 0xd8, 0, 0])] {
            #expect(parse(Data([UInt8(ascii: "V")]) + bad) == nil)
        }
    }

    @Test func audioWireBoundaryEvenLengthAndEmpty() {
        let prefix = Data([UInt8(ascii: "A")])
        let pcm = Data(repeating: 0, count: 8192)
        #expect(parse(prefix + pcm) == .audio(pcm))
        #expect(parse(prefix + pcm + Data([0, 0])) == nil)
        #expect(parse(prefix + Data([0])) == nil)
        #expect(parse(prefix) == .audio(Data()))
    }
}
