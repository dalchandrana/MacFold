import Foundation

/// Geometry and optical defocus have different responses to the same physical bend.
public struct FoldVisualState: Equatable, Sendable {
    public var progress: Double
    public var defocus: Double
    public var coverage: Double
    /// Physical rotation from the resting plane; independent of eased fold progress.
    public var tilt: Double
    public init(progress: Double, defocus: Double, coverage: Double = 1, tilt: Double = 0) {
        self.progress = progress; self.defocus = defocus; self.coverage = coverage; self.tilt = tilt
    }
    public static let clear = Self(progress: 0, defocus: 0, coverage: 0)
    public var isClear: Bool { self == .clear }

    public static func at(angle: Double, reference: Double) -> Self {
        guard angle.isFinite, reference.isFinite else { return .clear }
        let reference = min(140, max(5, reference))
        let delta = max(0, reference-angle)
        guard delta > 0 else { return .clear }
        // A low resting angle must not compress the whole effect into one or
        // two sensor degrees. The OS still owns actual lid-close sleep.
        let span = max(20, reference-5)
        let progress = ease(delta/span)
        // Barely visible for 1–3°, substantial at 15°, with room for deeper closure.
        let defocus = 0.16*ease(delta/15)*ease(delta/6)
            + 0.84*ease((delta-15)/max(10,span-15))
        return Self(progress: progress, defocus: min(1,defocus), tilt: min(85,delta) * .pi/180)
    }

    static func ease(_ t: Double) -> Double {
        let t = min(1,max(0,t)); return t*t*(3-2*t)
    }
    public func isNear(_ other: Self) -> Bool {
        abs(progress-other.progress) < 1e-7 && abs(defocus-other.defocus) < 1e-7
            && abs(coverage-other.coverage) < 1e-7 && abs(tilt-other.tilt) < 1e-7
    }
}

/// A shared absolute-time return, with fast tracking while the lid is moving.
/// Coverage hands the last, almost-clear pixels back to the real desktop.
public struct FoldVisualAnimation {
    public static let clearDuration: TimeInterval = 0.6
    public private(set) var value: FoldVisualState = .clear
    private var lastTime: TimeInterval?
    private var clearStart: TimeInterval?
    private var clearFrom: FoldVisualState = .clear

    public init() {}
    public mutating func reset() { self = Self() }
    public mutating func prime(at now: TimeInterval) { lastTime = now }

    public mutating func sample(target: FoldVisualState, at now: TimeInterval) -> FoldVisualState {
        guard now.isFinite, target.progress.isFinite, target.defocus.isFinite,
              target.coverage.isFinite, target.tilt.isFinite else { reset(); return .clear }
        let dt = lastTime.map { min(0.1,max(0,now-$0)) } ?? 0
        lastTime = now
        if let start = clearStart {
            let t = min(1,max(0,(now-start)/Self.clearDuration))
            let remaining = 1-FoldVisualState.ease(t)
            value = .init(progress:clearFrom.progress*remaining,defocus:clearFrom.defocus*remaining,
                coverage:clearFrom.coverage*(1-FoldVisualState.ease((t-0.75)/0.25)),
                tilt:clearFrom.tilt*remaining)
            if t >= 1 { value = .clear; clearStart = nil }
            if !target.isClear {
                clearStart = nil
                return value // Retarget from the current pixels, without an instantaneous jump.
            }
            return value
        }
        if target.isClear {
            if !value.isClear { clearFrom = value; clearStart = now }
            return value
        }
        let mix = 1-exp(-dt/0.045)
        value.progress += (target.progress-value.progress)*mix
        value.defocus += (target.defocus-value.defocus)*mix
        value.coverage += (target.coverage-value.coverage)*mix
        // Counter-rotation must stay close to the physical panel. A slower
        // response makes the desktop appear attached to the moving lid.
        // Optical softening keeps its gentler response and clearing clock.
        value.tilt += (target.tilt-value.tilt)*(1-exp(-dt/0.015))
        if value.isNear(target) { value = target }
        return value
    }
}
