import Darwin

/// Finds the agent process (`claude` or `codex`) behind a hook so Claudebar can drop
/// sessions whose process died without sending SessionEnd (killed terminal, crash, force quit).
enum ProcessLookup {
    static func agentProcess(named processName: String, startingAt pid: pid_t) -> pid_t? {
        var current = pid
        for _ in 0..<6 {
            guard current > 1 else { return nil }
            if name(of: current) == processName { return current }
            guard let parent = parent(of: current) else { return nil }
            current = parent
        }
        return nil
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Alive and still the agent's process (PIDs get reused after a reboot).
    static func isAgent(_ pid: pid_t, named processName: String) -> Bool {
        isAlive(pid) && name(of: pid) == processName
    }

    private static func name(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func parent(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }
}
