import Darwin
import Foundation
import LeanTermCore

/// Reads the foreground process-group leader straight from the kernel; never shells out.
enum ForegroundProcessReader {
    /// Read the local shell's cwd, even when it does not emit OSC 7 directory reports.
    static func workingDirectory(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        guard path.hasPrefix("/") else { return nil }
        return ShellLaunch.localDirectory(from: URL(fileURLWithPath: path).absoluteString)
    }
    static func read(groupLeader pid: pid_t) -> ForegroundProcess? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        let arguments = ForegroundSession.remoteTools.contains(name) ? self.arguments(of: pid) : []
        return ForegroundProcess(name: name, arguments: arguments, effectiveUserID: info.kp_eproc.e_ucred.cr_uid)
    }

    /// KERN_PROCARGS2 layout: Int32 argc, exec path, NUL padding, then argc NUL-terminated strings.
    private static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        let bytes = buffer[..<size]
        let count = bytes.prefix(MemoryLayout<Int32>.size).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        var index = bytes.startIndex + MemoryLayout<Int32>.size
        while index < bytes.endIndex, bytes[index] != 0 { index += 1 }
        while index < bytes.endIndex, bytes[index] == 0 { index += 1 }
        var result: [String] = []
        while result.count < Int(count), index < bytes.endIndex {
            let end = bytes[index...].firstIndex(of: 0) ?? bytes.endIndex
            result.append(String(decoding: bytes[index..<end], as: UTF8.self))
            index = end + 1
        }
        return result
    }
}
