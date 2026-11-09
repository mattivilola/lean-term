import Foundation

public enum ProcessMetricsStatus: Equatable, Sendable {
    case paused
    case sampling
    case available
    case unavailable
}

/// One reading for this process. CPU and elapsed times use the same Mach tick unit.
public struct ProcessMetricsReading: Equatable, Sendable {
    public let startedAtTicks: UInt64
    public let uptimeTicks: UInt64
    public let cpuTimeTicks: UInt64
    public let physicalFootprintBytes: UInt64

    public init(startedAtTicks: UInt64 = 0, uptimeTicks: UInt64, cpuTimeTicks: UInt64, physicalFootprintBytes: UInt64) {
        self.startedAtTicks = startedAtTicks
        self.uptimeTicks = uptimeTicks
        self.cpuTimeTicks = cpuTimeTicks
        self.physicalFootprintBytes = physicalFootprintBytes
    }
}

public struct ProcessMetricsUsage: Equatable, Sendable {
    public let cpuPercent: Double?
    public let physicalFootprintBytes: UInt64
}

public struct ProcessMetricsSnapshot: Equatable, Sendable {
    public let status: ProcessMetricsStatus
    public let cpuPercent: Double?
    public let physicalFootprintBytes: UInt64?
    public let cpuHistory: [Double?]
    public let memoryHistory: [UInt64?]
    public let cpuScalePercent: Double
    public let memoryScaleBytes: UInt64

    public static let historyLimit = 60
    public static let minimumCPUScalePercent = 100.0
    public static let minimumMemoryScaleBytes: UInt64 = 128 * 1024 * 1024

    public init(status: ProcessMetricsStatus = .paused,
                cpuPercent: Double? = nil,
                physicalFootprintBytes: UInt64? = nil,
                cpuHistory: [Double?] = [],
                memoryHistory: [UInt64?] = [],
                cpuScalePercent: Double = minimumCPUScalePercent,
                memoryScaleBytes: UInt64 = minimumMemoryScaleBytes) {
        self.status = status
        self.cpuPercent = cpuPercent
        self.physicalFootprintBytes = physicalFootprintBytes
        self.cpuHistory = cpuHistory
        self.memoryHistory = memoryHistory
        self.cpuScalePercent = cpuScalePercent
        self.memoryScaleBytes = memoryScaleBytes
    }
}

/// Pure state and scale calculations shared by the process monitor and focused tests.
public struct ProcessMetricsModel: Sendable {
    public private(set) var snapshot = ProcessMetricsSnapshot()
    private var previousReadings: [Int32: ProcessMetricsReading] = [:]

    public init() {}

    public mutating func setRunning(_ enabled: Bool) {
        switch (snapshot.status, enabled) {
        case (.paused, true):
            snapshot = Self.makeSnapshot(status: .sampling, cpu: nil, memory: nil,
                                         cpuHistory: snapshot.cpuHistory, memoryHistory: snapshot.memoryHistory)
        case (.sampling, false), (.available, false), (.unavailable, false):
            previousReadings.removeAll()
            snapshot = Self.makeSnapshot(status: .paused, cpu: nil, memory: nil,
                                         cpuHistory: snapshot.cpuHistory + [nil],
                                         memoryHistory: snapshot.memoryHistory + [nil])
        default:
            break
        }
    }

    /// Sums one group against the last total sample, comparing CPU counters by process identity.
    public func usage(for readings: [Int32: ProcessMetricsReading]) -> ProcessMetricsUsage? {
        guard !readings.isEmpty else { return nil }
        var cpu: Double?
        var memory: UInt64 = 0
        for (pid, reading) in readings {
            let (sum, overflow) = memory.addingReportingOverflow(reading.physicalFootprintBytes)
            memory = overflow ? UInt64.max : sum
            if let previous = previousReadings[pid], let percent = Self.cpuPercent(from: previous, to: reading) {
                cpu = (cpu ?? 0) + percent
            }
        }
        return ProcessMetricsUsage(cpuPercent: cpu, physicalFootprintBytes: memory)
    }

    public mutating func record(_ readings: [Int32: ProcessMetricsReading]?) {
        guard snapshot.status != .paused else { return }

        guard let readings, let usage = usage(for: readings) else {
            previousReadings.removeAll()
            snapshot = Self.makeSnapshot(status: .unavailable, cpu: nil, memory: nil,
                                         cpuHistory: snapshot.cpuHistory + [nil],
                                         memoryHistory: snapshot.memoryHistory + [nil])
            return
        }

        previousReadings = readings
        let cpu = usage.cpuPercent
        let memory = usage.physicalFootprintBytes
        snapshot = Self.makeSnapshot(status: .available, cpu: cpu,
                                     memory: memory,
                                     cpuHistory: snapshot.cpuHistory + [cpu],
                                     memoryHistory: snapshot.memoryHistory + [memory])
    }

    /// CPU percent relative to one logical core. Mach timebase factors cancel because both
    /// process CPU time and elapsed time are expressed in Mach absolute-time ticks.
    public static func cpuPercent(from previous: ProcessMetricsReading,
                                  to current: ProcessMetricsReading) -> Double? {
        guard current.startedAtTicks == previous.startedAtTicks,
              current.uptimeTicks > previous.uptimeTicks,
              current.cpuTimeTicks >= previous.cpuTimeTicks else { return nil }

        let elapsedTicks = current.uptimeTicks - previous.uptimeTicks
        let cpuTicks = current.cpuTimeTicks - previous.cpuTimeTicks
        let percent = (Double(cpuTicks) / Double(elapsedTicks)) * 100
        return percent.isFinite && percent >= 0 ? percent : nil
    }

    private static func makeSnapshot(status: ProcessMetricsStatus,
                                    cpu: Double?,
                                    memory: UInt64?,
                                    cpuHistory: [Double?],
                                    memoryHistory: [UInt64?]) -> ProcessMetricsSnapshot {
        let boundedCPUHistory = Array(cpuHistory.suffix(ProcessMetricsSnapshot.historyLimit))
        let boundedMemoryHistory = Array(memoryHistory.suffix(ProcessMetricsSnapshot.historyLimit))
        let maxCPU = boundedCPUHistory.compactMap { $0 }.max() ?? 0
        let cpuScale = max(ProcessMetricsSnapshot.minimumCPUScalePercent,
                           ceil(maxCPU / 100) * 100)

        let maxMemory = boundedMemoryHistory.compactMap { $0 }.max() ?? 0
        let memoryScale = memoryScale(for: maxMemory)

        return ProcessMetricsSnapshot(status: status, cpuPercent: cpu,
                                      physicalFootprintBytes: memory,
                                      cpuHistory: boundedCPUHistory,
                                      memoryHistory: boundedMemoryHistory,
                                      cpuScalePercent: cpuScale,
                                      memoryScaleBytes: memoryScale)
    }

    private static func memoryScale(for maximumBytes: UInt64) -> UInt64 {
        var scale = ProcessMetricsSnapshot.minimumMemoryScaleBytes
        while maximumBytes > scale {
            guard scale <= UInt64.max / 2 else { return UInt64.max }
            scale *= 2
        }
        return scale
    }
}
