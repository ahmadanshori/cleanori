import AppKit // `NSWorkspace`; the only file in the core that needs AppKit.
import Foundation

/// The live `ProcessInspector`: running apps from `NSWorkspace`, every other process from `sysctl`.
public struct SystemProcessInspector: ProcessInspector {
    public init() {}

    public func runningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    /// Every process whose arguments this user may read.
    ///
    /// The process list comes from `sysctl(KERN_PROC_ALL)` and each process's arguments from
    /// `sysctl(KERN_PROCARGS2)`. The kernel refuses the latter for other users' processes and for protected
    /// system ones; those are skipped without a word. What the lock conditions look for (Gradle daemons,
    /// emulators) runs as the user.
    ///
    /// Each call is a full sweep of the process table, so callers should not make it once per item.
    public func runningProcesses() -> [RunningProcess] {
        let pids = Self.allPIDs()
        guard !pids.isEmpty else { return [] }
        // One buffer for the whole sweep: `procargs` never exceeds `kern.argmax` bytes.
        var buffer = [UInt8](repeating: 0, count: Self.maximumArgumentBytes())
        var processes: [RunningProcess] = []
        for pid in pids {
            var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
            var size = buffer.count
            let status = buffer.withUnsafeMutableBytes { raw in
                sysctl(&mib, UInt32(mib.count), raw.baseAddress, &size, nil, 0)
            }
            guard status == 0, size > 0, size <= buffer.count else { continue } // not ours to read, or gone already
            if let process = Self.parseProcArgs(Data(buffer[..<size])) {
                processes.append(process)
            }
        }
        return processes
    }

    // MARK: - KERN_PROCARGS2

    /// Reads the buffer `sysctl(KERN_PROCARGS2)` returns:
    ///
    ///     int32   argc                  host byte order
    ///     char[]  exec_path, NUL        the path the program was started from
    ///     NUL...                        padding
    ///     argv[0] NUL ... argv[argc-1] NUL
    ///     environment strings ...
    ///
    /// `executable` is the last component of the exec path, and `arguments` are `argv[1...]` (not `argv[0]`);
    /// the environment is ignored. Empty arguments are kept.
    ///
    /// The buffer is not trusted. It can end anywhere, and `argc` is only an upper bound: whatever arguments
    /// are complete (end in a NUL) are returned, and a half-written last one is dropped. A truncated argument
    /// can only fail to match, never match falsely. `nil` means there is no usable program name: the buffer is
    /// shorter than `argc`, `argc` is negative, or the exec path is empty or has no NUL.
    ///
    /// An empty `argv[0]` cannot be told from padding, so it is skipped with the padding; the kernel's own
    /// `ps` has the same blind spot.
    public static func parseProcArgs(_ data: Data) -> RunningProcess? {
        let bytes = [UInt8](data) // contiguous and zero-based, whatever slice `data` was
        let headerSize = MemoryLayout<Int32>.size
        guard bytes.count >= headerSize else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc >= 0 else { return nil }

        var cursor = headerSize
        /// The NUL-terminated string at `cursor`, advancing past its NUL; `nil` when the NUL is missing.
        func nextString() -> String? {
            guard let end = bytes[cursor...].firstIndex(of: 0) else { return nil }
            defer { cursor = end + 1 }
            return String(decoding: bytes[cursor..<end], as: UTF8.self)
        }

        guard let execPath = nextString(),
              let program = execPath.split(separator: "/").last.map(String.init) else { return nil }
        while cursor < bytes.count, bytes[cursor] == 0 { cursor += 1 } // padding

        var arguments: [String] = []
        var seen: Int32 = 0 // strings read so far: argv[0] is the first
        while seen < argc, let argument = nextString() {
            if seen > 0 { arguments.append(argument) }
            seen += 1
        }
        return RunningProcess(executable: program, arguments: arguments)
    }

    // MARK: - sysctl

    /// The ids of all processes, from `sysctl(KERN_PROC_ALL)`.
    private static func allPIDs() -> [pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        let stride = MemoryLayout<kinfo_proc>.stride
        // The table can grow between asking for its size and reading it (ENOMEM), so ask again.
        for _ in 0..<5 {
            var size = 0
            guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
            let capacity = size / stride + 32 // room for processes that start in between
            var table = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
            var bytes = capacity * stride
            let status = table.withUnsafeMutableBytes { raw in
                sysctl(&mib, UInt32(mib.count), raw.baseAddress, &bytes, nil, 0)
            }
            if status == 0 {
                return table.prefix(bytes / stride).map(\.kp_proc.p_pid).filter { $0 > 0 }
            }
            guard errno == ENOMEM else { return [] }
        }
        return []
    }

    /// `kern.argmax`: the most bytes of arguments and environment a process can have.
    private static func maximumArgumentBytes() -> Int {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, UInt32(mib.count), &value, &size, nil, 0) == 0, value > 0 else {
            return 1 << 20 // 1 MiB, what macOS has always used
        }
        return Int(value)
    }
}
