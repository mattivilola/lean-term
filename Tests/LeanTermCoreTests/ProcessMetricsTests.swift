import Testing
@testable import LeanTermCore

@Test func cpuPercentUsesMachTickRatiosAndAllowsMultipleCores() throws {
    let base = ProcessMetricsReading(uptimeTicks: 1_000_000, cpuTimeTicks: 700_000,
                                     physicalFootprintBytes: 64 * 1024 * 1024)
    // With the Mac's 125/3 Mach timebase, both deltas receive the same conversion factor;
    // 7.5M CPU ticks / 12.5M elapsed ticks is 60%, independent of that factor.
    let convertedCPUSeconds = 7_500_000.0 * 125 / 3 / 1_000_000_000
    let convertedElapsedSeconds = 12_500_000.0 * 125 / 3 / 1_000_000_000
    #expect(try #require(ProcessMetricsModel.cpuPercent(
        from: base,
        to: ProcessMetricsReading(uptimeTicks: 13_500_000, cpuTimeTicks: 8_200_000,
                                  physicalFootprintBytes: 64 * 1024 * 1024))) == 60)
    #expect(abs(convertedCPUSeconds / convertedElapsedSeconds * 100 - 60) < 1e-12)

    let busy = ProcessMetricsReading(uptimeTicks: 20, cpuTimeTicks: 31,
                                     physicalFootprintBytes: 0)
    #expect(ProcessMetricsModel.cpuPercent(
        from: ProcessMetricsReading(uptimeTicks: 10, cpuTimeTicks: 1, physicalFootprintBytes: 0),
        to: busy) == 300)
}

@Test func cpuPercentRejectsBadOrReversedCounters() {
    let base = ProcessMetricsReading(uptimeTicks: 10, cpuTimeTicks: 10, physicalFootprintBytes: 0)
    #expect(ProcessMetricsModel.cpuPercent(
        from: base,
        to: ProcessMetricsReading(uptimeTicks: 10, cpuTimeTicks: 12, physicalFootprintBytes: 0)) == nil)
    #expect(ProcessMetricsModel.cpuPercent(
        from: base,
        to: ProcessMetricsReading(uptimeTicks: 9, cpuTimeTicks: 12, physicalFootprintBytes: 0)) == nil)
    #expect(ProcessMetricsModel.cpuPercent(
        from: base,
        to: ProcessMetricsReading(uptimeTicks: 12, cpuTimeTicks: 9, physicalFootprintBytes: 0)) == nil)
}

@Test func modelUsesFirstReadingAsBaselineAndResetsAcrossPauseAndFailure() throws {
    var model = ProcessMetricsModel()
    model.setRunning(true)
    model.record(.init(uptimeTicks: 1_000, cpuTimeTicks: 500, physicalFootprintBytes: 80_000_000))
    #expect(model.snapshot.status == .available)
    #expect(model.snapshot.cpuPercent == nil)
    #expect(model.snapshot.physicalFootprintBytes == 80_000_000)

    model.record(.init(uptimeTicks: 2_000, cpuTimeTicks: 1_000, physicalFootprintBytes: 90_000_000))
    #expect(model.snapshot.cpuPercent == 50)

    model.setRunning(false)
    #expect(model.snapshot.status == .paused)
    #expect(model.snapshot.cpuPercent == nil)
    model.setRunning(true)
    model.record(.init(uptimeTicks: 100_000, cpuTimeTicks: 90_000, physicalFootprintBytes: 100_000_000))
    #expect(model.snapshot.cpuPercent == nil)

    model.record(nil)
    #expect(model.snapshot.status == .unavailable)
    #expect(model.snapshot.cpuPercent == nil && model.snapshot.physicalFootprintBytes == nil)
    model.record(.init(uptimeTicks: 102_000, cpuTimeTicks: 92_000, physicalFootprintBytes: 120_000_000))
    #expect(model.snapshot.cpuPercent == nil)
    model.record(.init(uptimeTicks: 103_000, cpuTimeTicks: 92_500, physicalFootprintBytes: 121_000_000))
    #expect(try #require(model.snapshot.cpuPercent) == 50)
}

@Test func historyStaysBoundedAndScalesExpandWithoutClamping() throws {
    var model = ProcessMetricsModel()
    model.setRunning(true)
    let above128MiB = ProcessMetricsSnapshot.minimumMemoryScaleBytes + 1
    for index in 0..<75 {
        let uptime = UInt64(index + 1) * 100
        model.record(.init(uptimeTicks: uptime,
                           cpuTimeTicks: UInt64(index) * 150,
                           physicalFootprintBytes: index == 74 ? above128MiB : 64 * 1024 * 1024))
    }

    let snapshot = model.snapshot
    #expect(snapshot.cpuHistory.count == ProcessMetricsSnapshot.historyLimit)
    #expect(snapshot.memoryHistory.count == ProcessMetricsSnapshot.historyLimit)
    #expect(snapshot.cpuScalePercent == 200)
    #expect(snapshot.cpuPercent == 150)
    #expect(snapshot.physicalFootprintBytes == above128MiB)
    #expect(snapshot.memoryScaleBytes == ProcessMetricsSnapshot.minimumMemoryScaleBytes * 2)
    #expect(try #require(snapshot.memoryHistory.last!) == above128MiB)
}
