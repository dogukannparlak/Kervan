import Darwin
import Foundation

/// Başlatılan child process'leri (pid + başlama zamanı) bir dosyada tutar.
/// `kervand` SIGKILL ile ölürse yt-dlp gibi çocuklar yetim kalır; servis yeniden
/// açılınca `reapOrphans` onları bulup durdurur, böylece aynı `.part` dosyasına iki süreç yazmaz.
/// Dosya ayarlanmadıysa (CLI) hiçbir şey yazılmaz.
public enum ChildRegistry {
    private static let state = RegistryState()

    public static func configure(file: URL) {
        state.configure(file)
    }

    static func register(pid: Int32) {
        guard let start = processInfo(pid)?.start else { return }
        state.update { $0[pid] = start }
    }

    static func unregister(pid: Int32) {
        state.update { $0[pid] = nil }
    }

    /// Kayıtlı ve hâlâ yaşayan yetim süreçleri (ebeveyni launchd = 1) durdurur; durdurulan pid'leri döner.
    @discardableResult
    public static func reapOrphans() -> [Int32] {
        let entries = state.load()
        var reaped: [Int32] = []
        for (pid, start) in entries {
            guard let info = processInfo(pid), info.start == start, info.ppid == 1 else { continue }
            kill(pid, SIGTERM)
            reaped.append(pid)
        }
        if !reaped.isEmpty {
            Thread.sleep(forTimeInterval: 2)
            for pid in reaped where processInfo(pid)?.start == entries[pid] { kill(pid, SIGKILL) }
        }
        state.update { $0.removeAll() }
        return reaped
    }

    static func processInfo(_ pid: Int32) -> (ppid: Int32, start: Int)? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return (info.kp_eproc.e_ppid, info.kp_proc.p_un.__p_starttime.tv_sec)
    }
}

private final class RegistryState: @unchecked Sendable {
    private let lock = NSLock()
    private var file: URL?
    private var entries: [Int32: Int] = [:]

    func configure(_ file: URL) {
        lock.withLock { self.file = file }
    }

    func load() -> [Int32: Int] {
        lock.withLock {
            guard let file, let text = try? String(contentsOf: file, encoding: .utf8) else { return [:] }
            entries = [:]
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: " ")
                if parts.count == 2, let pid = Int32(parts[0]), let start = Int(parts[1]) { entries[pid] = start }
            }
            return entries
        }
    }

    func update(_ change: (inout [Int32: Int]) -> Void) {
        lock.withLock {
            guard let file else { return }
            change(&entries)
            let text = entries.map { "\($0.key) \($0.value)" }.joined(separator: "\n")
            try? text.write(to: file, atomically: true, encoding: .utf8)
        }
    }
}
