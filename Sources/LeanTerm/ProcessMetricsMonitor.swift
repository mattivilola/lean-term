import AppKit
import Darwin
import LeanTermCore

struct PaneProcessUsage {
    let pid: pid_t
    let name: String
    let cpuPercent: Double?
    let physicalFootprintBytes: UInt64
}

@MainActor
final class ProcessMetricsMonitor {
    var onChange: (@MainActor () -> Void)?
    var shellPIDs: () -> [pid_t: UUID] = { [:] }
    private(set) var snapshot = ProcessMetricsSnapshot()
    private(set) var paneUsage: [UUID: ProcessMetricsUsage] = [:]
    private(set) var paneProcesses: [UUID: [PaneProcessUsage]] = [:]

    private var model = ProcessMetricsModel()
    private var timer: Timer?
    private var interval: TimeInterval = 1
    private var sampling = false
    private var generation = 0

    private struct Sample: Sendable {
        var total: [pid_t: ProcessMetricsReading] = [:]
        var panes: [UUID: [pid_t: ProcessMetricsReading]] = [:]
        var names: [pid_t: String] = [:]
    }

    /// Samples every `interval` seconds while enabled; changing the interval restarts the timer.
    func setRunning(_ enabled: Bool, interval: TimeInterval = 1) {
        if enabled {
            guard timer == nil || self.interval != interval else { return }
            let wasRunning = timer != nil
            timer?.invalidate()
            self.interval = interval
            if !wasRunning {
                model.setRunning(true)
                publish()
            }
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sample() }
            }
            timer.tolerance = interval * 0.2
            self.timer = timer
            RunLoop.main.add(timer, forMode: .default)
            sample()
        } else {
            guard timer != nil || model.snapshot.status != .paused else { return }
            timer?.invalidate()
            timer = nil
            generation += 1
            paneUsage.removeAll()
            paneProcesses.removeAll()
            model.setRunning(false)
            publish()
        }
    }

    private func sample() {
        guard timer != nil, !sampling else { return }
        sampling = true
        let generation = generation
        let shells = shellPIDs()
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) { Self.readSample(shells: shells) }.value
            self?.finish(result, generation: generation)
        }
    }

    private func finish(_ sample: Sample?, generation: Int) {
        sampling = false
        guard generation == self.generation else { self.sample(); return }
        paneUsage = sample?.panes.compactMapValues { model.usage(for: $0) } ?? [:]
        paneProcesses = sample?.panes.mapValues { readings in
            readings.map { pid, reading in
                PaneProcessUsage(pid: pid, name: sample?.names[pid] ?? "Process",
                                 cpuPercent: model.cpuPercent(for: pid, reading: reading),
                                 physicalFootprintBytes: reading.physicalFootprintBytes)
            }
        } ?? [:]
        model.record(sample?.total)
        publish()
    }

    private func publish() {
        snapshot = model.snapshot
        onChange?()
    }

    /// One process-table read supplies ancestry for all panes, including hidden tabs and background jobs.
    nonisolated private static func readSample(shells: [pid_t: UUID]) -> Sample? {
        let appPID = getpid()
        let listingStartedAt = mach_absolute_time()
        guard let entries = readProcessTable() else { return nil }
        var children: [pid_t: [Int]] = [:]
        for index in entries.indices where entries[index].kp_proc.p_pid > 0 {
            children[entries[index].kp_eproc.e_ppid, default: []].append(index)
        }
        var sample = Sample()
        var pending: [(pid: pid_t, pane: UUID?, index: Int?)] = [(appPID, nil, nil)]
        var visited = Set<pid_t>()
        while let process = pending.popLast() {
            guard visited.insert(process.pid).inserted else { continue }
            if let reading = readProcess(process.pid) {
                // A PID recycled after the table read belongs to a different process.
                guard reading.startedAtTicks <= listingStartedAt else { continue }
                sample.total[process.pid] = reading
                if let pane = process.pane, let index = process.index {
                    sample.panes[pane, default: [:]][process.pid] = reading
                    sample.names[process.pid] = withUnsafeBytes(of: entries[index].kp_proc.p_comm) { bytes in
                        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
                    }
                }
            }
            for index in children[process.pid, default: []] {
                let pid = entries[index].kp_proc.p_pid
                let pane = process.pid == appPID ? shells[pid] : process.pane
                pending.append((pid, pane, index))
            }
        }
        return sample
    }

    nonisolated private static func readProcessTable() -> ArraySlice<kinfo_proc>? {
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        let mibCount = UInt32(mib.count)
        let stride = MemoryLayout<kinfo_proc>.stride
        // Allow spare space and retry once if the process table grew between the two calls.
        for _ in 0..<2 {
            var bytes = 0
            guard sysctl(&mib, mibCount, nil, &bytes, nil, 0) == 0, bytes > 0 else { return nil }
            var entries = Array(repeating: kinfo_proc(), count: bytes / stride + 32)
            bytes = entries.count * stride
            let result = entries.withUnsafeMutableBytes { sysctl(&mib, mibCount, $0.baseAddress, &bytes, nil, 0) }
            if result == 0 { return entries.prefix(bytes / stride) }
            guard errno == ENOMEM else { return nil }
        }
        return nil
    }

    nonisolated private static func readProcess(_ processID: pid_t) -> ProcessMetricsReading? {
        var usage = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &usage) { usagePointer in
            let buffer = UnsafeMutableRawPointer(usagePointer)
                .assumingMemoryBound(to: rusage_info_t?.self)
            return proc_pid_rusage(processID, Int32(RUSAGE_INFO_V2), buffer)
        }
        guard result == 0 else { return nil }
        let (cpuTicks, overflow) = usage.ri_user_time.addingReportingOverflow(usage.ri_system_time)
        guard !overflow else { return nil }

        return ProcessMetricsReading(startedAtTicks: usage.ri_proc_start_abstime,
                                     uptimeTicks: mach_absolute_time(),
                                     cpuTimeTicks: cpuTicks,
                                     physicalFootprintBytes: usage.ri_phys_footprint)
    }
}
