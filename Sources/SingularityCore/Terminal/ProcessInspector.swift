import Darwin
import Foundation

/// Reads facts about running processes using macOS system calls. Used to name terminal tabs
/// after whatever runs in them, the way Terminal.app does, without any shell configuration.
public enum ProcessInspector {
    /// The process group in the foreground of a pseudo-terminal: the program that currently
    /// receives keyboard input (the shell at the prompt, or e.g. `claude` while it runs).
    /// `ptyFileDescriptor` is the terminal's master side.
    public static func foregroundProcessGroup(ptyFileDescriptor: Int32) -> pid_t? {
        let group = tcgetpgrp(ptyFileDescriptor)
        return group > 0 ? group : nil
    }

    /// The program name as it was invoked (argv[0], without directories or a login shell's
    /// leading "-"). We use argv[0] rather than the kernel's process name because the kernel
    /// reports the *resolved* file: `claude` is a symlink to a file named after its version.
    public static func programName(pid: pid_t) -> String? {
        guard let arguments = arguments(pid: pid), let first = arguments.first else { return nil }
        var name = (first as NSString).lastPathComponent
        if name.hasPrefix("-") { name.removeFirst() }
        return name.isEmpty ? nil : name
    }

    /// The process's current working directory.
    public static func currentDirectory(pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        // `vip_path` is a fixed-size C char array, which Swift imports as a tuple.
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    /// argv of a process, via `sysctl(KERN_PROCARGS2)`. The buffer layout is:
    /// [argc: Int32][executable path]\0[padding \0s][argv[0]]\0[argv[1]]\0…[environment…]
    public static func arguments(pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }

        let argc = buffer.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        var index = MemoryLayout<Int32>.size
        // Skip the executable path, then the NUL padding after it.
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }

        var result: [String] = []
        while result.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            result.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return result
    }
}
