#if !os(watchOS)
import Synchronization

/// Single-producer (main/control) and single-consumer (audio callback)
/// command handoff. A newer command supersedes an unread older one, which is
/// correct for restart/seek/schedule state and avoids locks or allocation in
/// the render callback.
final class BoundedDeckCommandMailbox: @unchecked Sendable {
    private enum Kind: Int { case none, begin, seek, schedule, pause, resume, cancel }
    private let sequence = Atomic<Int>(0)
    private let consumed = Atomic<Int>(0)
    private let kind = Atomic<Int>(0)
    private let a = Atomic<Int64>(0), b = Atomic<Int64>(0), c = Atomic<Int64>(0)
    private let d = Atomic<Int64>(0), e = Atomic<Int64>(0), f = Atomic<Int64>(0), g = Atomic<UInt32>(0)

    func begin(total: Int64, start: Int64, tempo: Double) { publish(.begin, total, start, tempo.bitPattern) }
    func seek(_ frame: Int64) { publish(.seek, frame) }
    func cancel() { publish(.cancel) }
    func pause() { publish(.pause) }
    func resume() { publish(.resume) }
    func schedule(_ plan: BoundedOverlapPlan) {
        publish(.schedule, plan.startClock, Int64(plan.fadeFrames), UInt64(bitPattern: plan.incomingStartFrame),
                plan.incomingTotalFrames, plan.incomingTempo.bitPattern, Int64(plan.minIncomingBufferedFrames),
                gain: plan.incomingGain)
    }

    func consume(into mixer: BoundedDeckMixer) {
        let next = sequence.load(ordering: .acquiring)
        guard next != consumed.load(ordering: .relaxed) else { return }
        let command = Kind(rawValue: kind.load(ordering: .relaxed)) ?? .none
        let values = (a.load(ordering: .relaxed), b.load(ordering: .relaxed), c.load(ordering: .relaxed),
                      d.load(ordering: .relaxed), e.load(ordering: .relaxed), f.load(ordering: .relaxed),
                      g.load(ordering: .relaxed))
        guard next == sequence.load(ordering: .acquiring) else { return }
        consumed.store(next, ordering: .releasing)
        switch command {
        case .begin: mixer.begin(totalFrames: values.0, startFrame: values.1, tempo: Double(bitPattern: UInt64(values.2)))
        case .seek: mixer.seek(to: values.0)
        case .schedule:
            mixer.schedule(.init(startClock: values.0, fadeFrames: Int(values.1), incomingStartFrame: values.2,
                                incomingTotalFrames: values.3, incomingTempo: Double(bitPattern: UInt64(values.4)),
                                incomingGain: Float(bitPattern: values.6), minIncomingBufferedFrames: Int(values.5)))
        case .pause: mixer.pause(.user)
        case .resume: mixer.resume()
        case .cancel: mixer.cancelOverlap()
        case .none: break
        }
    }

    private func publish(_ command: Kind, _ x: Int64 = 0, _ y: Int64 = 0, _ z: UInt64 = 0,
                         _ w: Int64 = 0, _ q: UInt64 = 0, _ r: Int64 = 0, gain: Float = 1) {
        a.store(x, ordering: .relaxed); b.store(y, ordering: .relaxed); c.store(Int64(bitPattern: z), ordering: .relaxed)
        d.store(w, ordering: .relaxed); e.store(Int64(bitPattern: q), ordering: .relaxed)
        f.store(r, ordering: .relaxed); g.store(gain.bitPattern, ordering: .relaxed)
        kind.store(command.rawValue, ordering: .relaxed)
        sequence.wrappingAdd(1, ordering: .releasing)
    }
}
#endif
