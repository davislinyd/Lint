import Darwin

/// One reading of a process's CPU time and memory, for the menu bar. `proc_pid_rusage` reads any
/// process of the same user (Lint itself and the llama-server it runs) without an entitlement.
public struct ProcessResourceSample: Equatable, Sendable {
    /// User plus system CPU time, in nanoseconds.
    public var cpuTime: UInt64
    /// `phys_footprint`, Activity Monitor's Memory column. A local model's weights are a file mapping
    /// the GPU reads, and are not in it.
    public var footprint: UInt64
    /// When it was read, in nanoseconds of uptime.
    public var takenAt: UInt64

    public init(cpuTime: UInt64, footprint: UInt64, takenAt: UInt64) {
        self.cpuTime = cpuTime
        self.footprint = footprint
        self.takenAt = takenAt
    }

    /// Nil when the process is gone or cannot be read.
    public static func read(pid: pid_t) -> ProcessResourceSample? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return nil }
        let ticks = info.ri_user_time + info.ri_system_time
        return ProcessResourceSample(
            cpuTime: ticks * UInt64(timebase.numer) / UInt64(timebase.denom),
            footprint: info.ri_phys_footprint,
            takenAt: clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        )
    }

    /// CPU use between an earlier reading and this one, as Activity Monitor counts it: 100% is one core
    /// kept busy, so a process using several cores goes past 100%.
    public func cpuPercent(since earlier: ProcessResourceSample) -> Double? {
        guard takenAt > earlier.takenAt, cpuTime >= earlier.cpuTime else { return nil }
        return Double(cpuTime - earlier.cpuTime) / Double(takenAt - earlier.takenAt) * 100
    }

    /// `ri_user_time` and `ri_system_time` count Mach ticks, not nanoseconds: on Apple silicon a tick
    /// is 125/3 ns.
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()
}
