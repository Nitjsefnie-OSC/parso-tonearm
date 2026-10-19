import XCTest
@testable import TonearmCore

private func waitSynchronously(_ s: DispatchSemaphore, seconds: Double) -> Bool {
    s.wait(timeout: .now() + seconds) == .success
}
private func blockSynchronously(_ s: DispatchSemaphore) { s.wait() }

final class ResourceCoordinatorTests: XCTestCase {
    private let mb: Int64 = 1_048_576
    private static let mbs: Int64 = 1_048_576
    private final class Box: @unchecked Sendable {
        let lock = NSLock(); private var v: Int64?
        init(_ v: Int64?) { self.v = v }
        var value: Int64? { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
    }
    private func make(avail: Box, cap: Int64 = 768 * 1_048_576, pressure: Box? = nil) -> ResourceCoordinator {
        var c = ResourceCoordinatorConfig(); c.absoluteCapBytes = cap
        return ResourceCoordinator(config: c, availableMemory: { avail.value },
                                   pressureActive: { (pressure?.value ?? 0) != 0 })
    }
    private static func reserved(_ r: Result<ResourceCoordinator.Reservation, ResourceDenialReason>) -> ResourceCoordinator.Reservation? {
        if case .success(let v) = r { return v } else { return nil }
    }

    func testJointlyUnsafeWorkDenied() {
        let c = make(avail: Box(700 * mb))   // headroom 256 + reserve 96 -> 348 MB usable
        let a = Self.reserved(c.reserve(.queuePreview, bytes: 200 * mb))
        XCTAssertNotNil(a)
        // Each alone is safe, together they are not.
        XCTAssertEqual(c.reserve(.blendPreparation, bytes: 200 * mb).failureReason, .insufficientHeadroom)
        a?.release()
        XCTAssertNotNil(Self.reserved(c.reserve(.blendPreparation, bytes: 200 * mb)))
    }

    func testPendingAndResidentAccountedSeparately() {
        let c = make(avail: Box(3_000 * mb))
        let a = Self.reserved(c.reserve(.deckA, bytes: 100 * mb))!
        _ = Self.reserved(c.reserve(.deckB, bytes: 50 * mb))
        a.markResident()
        let s = c.snapshot()
        XCTAssertEqual(s.residentBytes, 100 * mb)
        XCTAssertEqual(s.pendingBytes, 50 * mb)
    }

    func testAbsoluteCapCoversResidentToo() {
        let c = make(avail: Box(10_000 * mb), cap: 300 * mb)
        let a = Self.reserved(c.reserve(.deckA, bytes: 200 * mb))!
        a.markResident()
        XCTAssertEqual(c.reserve(.deckB, bytes: 150 * mb).failureReason, .absoluteCap)
    }

    func testAToBHandoffRetainsAUntilReleased() {
        let c = make(avail: Box(10_000 * mb), cap: 400 * mb)
        let a = Self.reserved(c.reserve(.deckA, bytes: 200 * mb))!; a.markResident()
        let b = Self.reserved(c.reserve(.deckB, bytes: 150 * mb))!; b.markResident()
        XCTAssertEqual(c.reserve(.deckC, bytes: 100 * mb).failureReason, .absoluteCap)
        a.release()
        XCTAssertNotNil(Self.reserved(c.reserve(.deckC, bytes: 100 * mb)))
    }

    func testFreshRecheckAtAllocationTime() {
        let avail = Box(3_000 * mb)
        let c = make(avail: avail)
        let r = Self.reserved(c.reserve(.liveDecode, bytes: 200 * mb))!
        XCTAssertTrue(r.authorizeAllocation())
        avail.value = 400 * mb   // pressure arrives while queued
        XCTAssertFalse(r.authorizeAllocation())
        XCTAssertEqual(c.snapshot().lastDenial, .insufficientHeadroom)
    }

    func testCancelDoesNotReleaseUntilWorkerExits() async throws {
        let c = make(avail: Box(3_000 * mb))
        let mb = self.mb
        let started = DispatchSemaphore(value: 0)
        let finish = DispatchSemaphore(value: 0)
        let task = Task.detached { () -> Bool in
            try await c.run(.liveDecode, bytes: 100 * mb) { r in
                started.signal()
                blockSynchronously(finish)   // uninterruptible synchronous decoder
                return r.isCancellationRequested
            }
        }
        let didStart = await withCheckedContinuation { (k: CheckedContinuation<Bool, Never>) in
            DispatchQueue.global().async {
                k.resume(returning: waitSynchronously(started, seconds: 5))
            }
        }
        XCTAssertTrue(didStart)
        task.cancel()
        XCTAssertEqual(c.snapshot().pendingBytes, 100 * mb)
        finish.signal()
        _ = try await task.value
        XCTAssertEqual(c.snapshot().totalBytes, 0)
    }

    func testPressureShedsFutureButNotAudible() {
        let c = make(avail: Box(3_000 * mb), pressure: Box(1))
        XCTAssertEqual(c.reserve(.queuePreview, bytes: 10 * mb).failureReason, .memoryPressure)
        XCTAssertNotNil(Self.reserved(c.reserve(.outgoingTail, bytes: 10 * mb)))
    }

    func testCancelledReservationDeniesFurtherAllocation() {
        let c = make(avail: Box(3_000 * mb))
        let r = Self.reserved(c.reserve(.resample, bytes: 10 * mb))!
        r.cancel()
        XCTAssertFalse(r.authorizeAllocation())
        XCTAssertEqual(c.snapshot().pendingBytes, 10 * mb)
    }

    func testConcurrentChurnStaysBounded() async {
        let cap = 300 * mb
        let mb = self.mb
        let c = make(avail: Box(10_000 * mb), cap: cap)
        await withTaskGroup(of: Void.self) { g in
            for i in 0..<200 {
                g.addTask {
                    let kind: ResourceKind = [.queuePreview, .liveDecode, .blendPreparation, .audition][i % 4]
                    if let r = ResourceCoordinatorTests.reserved(c.reserve(kind, bytes: 40 * mb)) {
                        XCTAssertLessThanOrEqual(c.snapshot().totalBytes, cap)
                        r.release()
                    }
                }
            }
        }
        XCTAssertEqual(c.snapshot().totalBytes, 0)
    }
}

private extension Result {
    var failureReason: Failure? { if case .failure(let e) = self { return e } else { return nil } }
}
