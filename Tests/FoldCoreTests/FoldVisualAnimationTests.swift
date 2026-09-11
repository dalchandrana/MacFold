import Testing
@testable import FoldCore

@Test func physicalDefocusIsGentleAtOnsetAndConsistentAcrossRestingAngles() {
    for reference in [45.0,60,90,105,128,140] {
        var previous = 0.0
        for delta in [0.0,1,2,3,5,10,15] {
            let state = FoldVisualState.at(angle:reference-delta,reference:reference)
            #expect(state.defocus >= previous)
            #expect(abs(state.defocus-FoldVisualState.at(angle:128-delta,reference:128).defocus) < 1e-12)
            previous = state.defocus
        }
        #expect(FoldVisualState.at(angle:reference-2,reference:reference).defocus < 0.003)
        #expect(FoldVisualState.at(angle:reference-3,reference:reference).defocus < 0.01)
        #expect(FoldVisualState.at(angle:reference-15,reference:reference).defocus == 0.16)
        #expect(FoldVisualState.at(angle:reference,reference:reference).isClear)
        #expect(FoldVisualState.at(angle:5,reference:reference).progress == 1)
    }
    #expect(FoldVisualState.at(angle:.nan,reference:90).isClear)
}

private func trackingAnimation() -> FoldVisualAnimation {
    var animation = FoldVisualAnimation()
    let target = FoldVisualState.at(angle:75,reference:105)
    for tick in 0...120 { _ = animation.sample(target:target,at:Double(tick)/120) }
    return animation
}

@Test func lowRestingAnglesDoNotTurnTinyMovementsIntoBlackouts() {
    for reference in [5.0,10,15,20,25,30] {
        for (delta,maximum) in [(1.0,0.01),(2.0,0.03),(3.0,0.065),(5.0,0.16)] {
            let state = FoldVisualState.at(angle:reference-delta,reference:reference)
            #expect(state.progress <= maximum)
            #expect(state.defocus < 0.04)
        }
    }
}

@Test func everyReachableRestingAngleHasABoundedPerDegreeBlurChange() {
    for reference in 5...140 {
        var previous = FoldVisualState.clear
        for delta in 0...reference {
            let value = FoldVisualState.at(angle:Double(reference-delta),reference:Double(reference))
            #expect(value.progress >= previous.progress && value.progress <= 1)
            #expect(value.defocus >= previous.defocus && value.defocus <= 1)
            #expect(value.defocus-previous.defocus <= 0.13)
            previous = value
        }
    }
}

@Test func clearIsFiniteMonotonicAndCrossfadesOnlyNearTheEnd() {
    var animation = trackingAnimation()
    var previous = animation.value
    let start = animation.sample(target:.clear,at:1)
    #expect(start == previous)
    for tick in 1...72 {
        let value = animation.sample(target:.clear,at:1+Double(tick)/120)
        #expect(value.progress <= previous.progress)
        #expect(value.defocus <= previous.defocus)
        #expect(value.tilt <= previous.tilt)
        #expect(value.coverage <= previous.coverage)
        if tick < 54 { #expect(value.coverage == start.coverage) }
        previous = value
    }
    #expect(animation.sample(target:.clear,at:1.601).isClear)
    #expect(animation.sample(target:.clear,at:3).isClear)
}

@Test func interruptedReturnRetargetsFromTheCurrentVisualState() {
    var a = trackingAnimation(), reference = a
    _ = a.sample(target:.clear,at:1)
    _ = reference.sample(target:.clear,at:1)
    let target = FoldVisualState.at(angle:88,reference:90)
    let expected = reference.sample(target:.clear,at:1.52)
    let interrupted = a.sample(target:target,at:1.52)
    #expect(interrupted == expected)
    let next = a.sample(target:target,at:1.52+1.0/60)
    #expect(next.progress <= interrupted.progress && next.progress >= target.progress)
    #expect(next.coverage > interrupted.coverage)
}

@Test func sharedVisualClockMatchesAtThirtySixtyAndOneTwentyHz() {
    func run(_ fps: Int, extraPreviewSamples: Bool) -> FoldVisualState {
        var animation = trackingAnimation()
        _ = animation.sample(target:.clear,at:1)
        for tick in 1...(fps/2) {
            let t = 1+Double(tick)/Double(fps)
            if extraPreviewSamples { _ = animation.sample(target:.clear,at:t-0.25/Double(fps)) }
            _ = animation.sample(target:.clear,at:t)
        }
        return animation.value
    }
    let baseline = run(60,extraPreviewSamples:false)
    for fps in [30,60,120] {
        #expect(run(fps,extraPreviewSamples:false) == baseline)
        #expect(run(fps,extraPreviewSamples:true) == baseline)
    }
}

@Test(arguments: 1...5) func selectedDwellFinishesBeforeTheVisualReturnStarts(seconds: Int) {
    var detector = LidStillness(), animation = FoldVisualAnimation()
    let moving = FoldVisualState.at(angle:90,reference:105)
    for tick in 0..<(seconds*120) {
        let now = Double(tick)/120
        if tick%4 == 0 { detector.observe(angle:90,at:now,delay:Double(seconds)) }
        let state = animation.sample(target:detector.isStill ? .clear : moving,at:now)
        if now > 0.8 { #expect(state.isNear(moving)) }
    }
    detector.observe(angle:90,at:Double(seconds),delay:Double(seconds))
    #expect(detector.isStill)
    let start = animation.sample(target:.clear,at:Double(seconds))
    #expect(start.progress > 0)
    #expect(animation.sample(target:.clear,at:Double(seconds)+0.3).progress > 0)
    #expect(animation.sample(target:.clear,at:Double(seconds)+0.601).isClear)
}

@Test func physicalTiltUsesDegreesRatherThanEasedProgressAndClearsWithBlur() {
    for reference: Double in [15,45,90,128] {
        let state = FoldVisualState.at(angle:reference-10,reference:reference)
        #expect(abs(state.tilt-10 * .pi/180) < 1e-12)
    }
    #expect(FoldVisualState.at(angle:0,reference:140).tilt == 85 * .pi/180)
    var animation = trackingAnimation()
    let before = animation.value
    _ = animation.sample(target:.clear,at:1)
    let middle = animation.sample(target:.clear,at:1.3)
    #expect(abs(middle.tilt/before.tilt-middle.defocus/before.defocus) < 1e-12)
    #expect(animation.sample(target:.clear,at:1.601).tilt == 0)
}

@Test func counterRotationTracksMovingLidWithinOneDegreeWithoutOvershoot() {
    for fps in [30,60,120] {
        var animation = FoldVisualAnimation()
        for tick in 0...fps {
            let time = Double(tick)/Double(fps)
            let target = FoldVisualState.at(angle:105-60*time,reference:105)
            let value = animation.sample(target:target,at:time)
            #expect(value.tilt <= target.tilt)
            #expect((target.tilt-value.tilt)*180 / .pi < 1)
        }
        let target = FoldVisualState.at(angle:45,reference:105)
        #expect(animation.sample(target:target,at:1.1).tilt <= target.tilt)
    }
}
