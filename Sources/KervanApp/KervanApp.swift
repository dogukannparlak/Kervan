import AppKit
import KervanIPC
import QueueKit
import ServiceManagement
import SwiftUI

@main
struct KervanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = QueueStore()
    @State private var clipboard = ClipboardWatcher()

    var body: some Scene {
        Window("Kervan", id: "main") {
            MainView()
                .environment(store)
                .frame(minWidth: 760, minHeight: 360)
                .task { start() }
        }
        .defaultSize(width: 980, height: 520)

        MenuBarExtra {
            MenuBarView()
                .environment(store)
                .task { start() }
        } label: {
            MenuBarLabel(active: store.active.count)
                .task { start() }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(store)
        }
    }

    /// Sahnelerden hangisi önce görünürse o başlatır; ikinci çağrılar etkisizdir.
    private func start() {
        store.start()
        clipboard.start(store: store)
        Snapshot.scheduleIfRequested()
    }
}

struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow
    let active: Int

    var body: some View {
        Group {
            if active > 0 {
                Label("\(active)", systemImage: "arrow.down.circle.fill").labelStyle(.titleAndIcon)
            } else {
                Image(systemName: "arrow.down.circle")
            }
        }
        // Menü çubuğu etiketi her zaman var: pencereyi (kapatılmış olsa da) yeniden açabilen yol buradan alınır.
        .onAppear { MainWindow.opener = { openWindow(id: "main") } }
    }
}

/// Ana pencereyi öne getirir; kapatılmışsa SwiftUI'nin `openWindow`'u ile yeniden açar.
@MainActor
enum MainWindow {
    static var opener: (() -> Void)?

    static func show() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            opener?()
        }
    }
}

/// Dock simgesine ya da Kervan.app'e tıklanınca pencere açılır; pencere kapanınca uygulama kapanmaz
/// (menü çubuğu, pano izleme ve bildirimler sürsün).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            MainWindow.show()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Task { @MainActor in MainWindow.show() } }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Oturum açılınca başlatma (ServiceManagement). Ad-hoc imzalı uygulamada başarısız olabilir; hata gösterilir.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
