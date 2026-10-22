import EngineCore
import Foundation
import KervanIPC
import QueueKit

/// Günde bir kez yt-dlp'yi günceller (ayarda `autoUpdate` açıksa). Aktif indirme varken beklenir:
/// Homebrew dosyaları değiştirirken çalışan yt-dlp süreçleri bozulmasın.
final class AutoUpdater: Sendable {
    private let engine: QueueEngine
    private let settings: SettingsStore
    private let paths: KervanPaths
    private let gate = UpdateGate()

    init(engine: QueueEngine, settings: SettingsStore, paths: KervanPaths) {
        self.engine = engine
        self.settings = settings
        self.paths = paths
    }

    func start() {
        Task {
            try? await Task.sleep(for: .seconds(120))  // açılışı yavaşlatma
            while true {
                let state = UpdateState.load(paths: paths)
                let due = state.lastCheck.map { -$0.timeIntervalSinceNow > 24 * 3600 } ?? true
                if settings.value.autoUpdate && due {
                    if await engine.hasActiveDownloads {
                        try? await Task.sleep(for: .seconds(600))
                        continue
                    }
                    _ = try? await runNow()
                }
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    /// Şimdi güncelle (CLI `kervan update` ve günlük kontrol). Aynı anda tek güncelleme.
    func runNow() async throws -> UpdateState {
        guard await gate.enter() else { throw EngineError.toolFailed(.ytDlp, status: -1, message: "güncelleme zaten sürüyor") }
        defer { Task { await gate.leave() } }
        var state = UpdateState.load(paths: paths)
        state.lastCheck = Date()
        do {
            let result = try await ToolUpdater().update()
            state.lastResult = result.changed
                ? "yt-dlp \(result.before ?? "?") → \(result.after ?? "?")"
                : "yt-dlp güncel (\(result.after ?? "?"))"
            log("güncelleme: \(state.lastResult ?? "")")
            if result.changed { Notifier.show(("Kervan: yt-dlp güncellendi", state.lastResult ?? "")) }
        } catch {
            state.lastResult = "hata: \(error)"
            log("güncelleme başarısız: \(error)")
        }
        state.save(paths: paths)
        return state
    }
}

private actor UpdateGate {
    private var running = false

    func enter() -> Bool {
        if running { return false }
        running = true
        return true
    }

    func leave() { running = false }
}
