import Testing
@testable import LeanTermCore

private func sample(_ running: Bool, alt: Bool = false, output: UInt64 = 0, at time: Double) -> SessionActivitySample {
    SessionActivitySample(foregroundJobRunning: running, alternateScreen: alt, outputCount: output, time: time)
}

@Test func indicatorWaitsForRevealDelayBeforeSweeping() {
    var model = SessionActivityModel()
    model.record(sample(true, at: 100))
    #expect(model.indicator == .idle)
    model.record(sample(true, at: 100.3))
    #expect(model.indicator == .idle)
    model.record(sample(true, at: 100.5))
    #expect(model.indicator == .sweeping)
}

@Test func quietJobHoldsAndResumedOutputSweepsAgain() {
    var model = SessionActivityModel()
    model.record(sample(true, at: 0))
    model.record(sample(true, at: 1))
    #expect(model.indicator == .sweeping)
    model.record(sample(true, at: 4.9))
    #expect(model.indicator == .sweeping)
    model.record(sample(true, at: 5.1))
    #expect(model.indicator == .holding)
    model.record(sample(true, output: 1, at: 8))
    #expect(model.indicator == .sweeping)
    model.record(sample(true, output: 1, at: 13.1))
    #expect(model.indicator == .holding)
}

@Test func alternateScreenSuppressesIndicatorOnlyWhileActive() {
    var model = SessionActivityModel()
    model.record(sample(true, at: 0))
    model.record(sample(true, alt: true, output: 1, at: 1))
    #expect(model.indicator == .idle)
    model.record(sample(true, alt: false, output: 2, at: 2))
    #expect(model.indicator == .sweeping)
}

@Test func longCommandFinishFiresOnce() {
    var model = SessionActivityModel()
    #expect(model.record(sample(true, at: 0)) == nil)
    #expect(model.record(sample(true, output: 1, at: 10)) == nil)
    #expect(model.record(sample(false, output: 1, at: 10.5)) == .finishedLongCommand(duration: 10.5))
    #expect(model.indicator == .idle)
    #expect(model.record(sample(false, output: 1, at: 11)) == nil)
}

@Test func commandExactlyAtThresholdCountsAsLong() {
    var model = SessionActivityModel()
    model.record(sample(true, at: 50))
    #expect(model.record(sample(false, at: 60)) == .finishedLongCommand(duration: 10))
}

@Test func shortCommandAndAlternateScreenJobsDoNotFire() {
    var short = SessionActivityModel()
    short.record(sample(true, at: 0))
    #expect(short.record(sample(false, at: 9.9)) == nil)

    var editor = SessionActivityModel()
    editor.record(sample(true, alt: true, at: 0))
    editor.record(sample(true, alt: false, at: 5))
    #expect(editor.record(sample(false, at: 30)) == nil)

    var laterAlternate = SessionActivityModel()
    laterAlternate.record(sample(true, at: 0))
    laterAlternate.record(sample(true, alt: true, at: 12))
    laterAlternate.record(sample(true, alt: false, at: 13))
    #expect(laterAlternate.record(sample(false, at: 20)) == nil)
}

@Test func nextJobStartsFreshAfterAlternateScreenJob() {
    var model = SessionActivityModel()
    model.record(sample(true, alt: true, at: 0))
    model.record(sample(false, at: 20))
    model.record(sample(true, at: 21))
    #expect(model.record(sample(false, at: 40)) == .finishedLongCommand(duration: 19))
}

@Test func pollingContinuesWhileRunningAndStopsAfterOutputSettles() {
    var model = SessionActivityModel()
    #expect(!model.needsPolling)
    model.record(sample(true, at: 0))
    #expect(model.needsPolling)
    model.record(sample(true, at: 20))
    #expect(model.needsPolling)
    model.record(sample(false, output: 5, at: 21))
    #expect(model.needsPolling) // output changed since the previous sample
    model.record(sample(false, output: 5, at: 21.5))
    #expect(!model.needsPolling)
}

@Test func outputWhileIdleRequestsOneMoreSampleOnly() {
    var model = SessionActivityModel()
    model.record(sample(false, output: 3, at: 0))
    #expect(model.needsPolling)
    #expect(model.indicator == .idle)
    model.record(sample(false, output: 3, at: 0.5))
    #expect(!model.needsPolling)
}

@Test func resetReturnsToIdleWithoutPollingOrEvent() {
    var model = SessionActivityModel()
    model.record(sample(true, output: 2, at: 0))
    model.record(sample(true, output: 2, at: 1))
    #expect(model.indicator == .sweeping)
    model.reset()
    #expect(model == SessionActivityModel())
    #expect(model.indicator == .idle && !model.needsPolling)
    #expect(model.record(sample(false, output: 2, at: 30)) == nil)
}

@Test func remoteSessionShowsNoIndicatorAndPollsOnlyOnOutput() {
    func remote(output: UInt64, at time: Double) -> SessionActivitySample {
        SessionActivitySample(foregroundJobRunning: true, alternateScreen: false, outputCount: output, time: time, remoteSession: true)
    }
    var model = SessionActivityModel()
    model.record(remote(output: 1, at: 0))
    model.record(remote(output: 2, at: 1))
    #expect(model.indicator == .idle)
    #expect(model.needsPolling)
    model.record(remote(output: 2, at: 1.5))
    #expect(!model.needsPolling)
}
