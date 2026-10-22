import AppKit

/// Test kancası: `KERVAN_SNAPSHOT_DIR` verilirse 4 sn sonra uygulamanın kendi pencerelerini PNG'ye yazar
/// (ekran kaydı izni gerekmez, yalnız Kervan pencereleri). Görsel kontrol için.
@MainActor
enum Snapshot {
    static func scheduleIfRequested() {
        guard let directory = ProcessInfo.processInfo.environment["KERVAN_SNAPSHOT_DIR"] else { return }
        Task {
            try? await Task.sleep(for: .seconds(4))
            for (index, window) in NSApp.windows.enumerated() where window.isVisible {
                guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                let name = window.title.isEmpty ? "pencere-\(index)" : window.title
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: directory).appending(path: "\(name).png"))
            }
        }
    }
}
