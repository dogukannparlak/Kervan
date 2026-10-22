import AppKit
import KervanIPC
import QueueKit
import ServiceManagement
import SwiftUI

@main
struct KervanApp: App {
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
    let active: Int

    var body: some View {
        if active > 0 {
            Label("\(active)", systemImage: "arrow.down.circle.fill").labelStyle(.titleAndIcon)
        } else {
            Image(systemName: "arrow.down.circle")
        }
    }
}

/// Oturum açılınca başlatma (ServiceManagement). Ad-hoc imzalı uygulamada başarısız olabilir; hata gösterilir.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
