import AppKit
import Darwin
import LeanTermCore

@MainActor
final class ProcessMetricsMonitor {
    var onChange: (@MainActor (ProcessMetricsSnapshot) -> Void)?
    private(set) var snapshot = ProcessMetricsSnapshot()

    private var model = ProcessMetricsModel()
    private var timer: Timer?
    private let processID = getpid()

    func setRunning(_ enabled: Bool) {
        if enabled {
            guard timer == nil else { return }
            model.setRunning(true)
            publish()

            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sample() }
            }
            timer.tolerance = 0.2
            self.timer = timer
            RunLoop.main.add(timer, forMode: .default)
            sample()
        } else {
            guard timer != nil || model.snapshot.status != .paused else { return }
            timer?.invalidate()
            timer = nil
            model.setRunning(false)
            publish()
        }
    }

    private func sample() {
        model.record(readProcess())
        publish()
    }

    private func publish() {
        snapshot = model.snapshot
        onChange?(snapshot)
    }

    private func readProcess() -> ProcessMetricsReading? {
        var usage = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &usage) { usagePointer in
            let buffer = UnsafeMutableRawPointer(usagePointer)
                .assumingMemoryBound(to: rusage_info_t?.self)
            return proc_pid_rusage(processID, Int32(RUSAGE_INFO_V2), buffer)
        }
        guard result == 0 else { return nil }
        let (cpuTicks, overflow) = usage.ri_user_time.addingReportingOverflow(usage.ri_system_time)
        guard !overflow else { return nil }

        return ProcessMetricsReading(uptimeTicks: mach_absolute_time(),
                                     cpuTimeTicks: cpuTicks,
                                     physicalFootprintBytes: usage.ri_phys_footprint)
    }
}
