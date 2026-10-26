import AppKit
import KervanIPC
import QueueKit
import ServiceManagement
import SwiftUI

/// Uygulamanın kendi tercihleri (UserDefaults; servisin ayarlarından ayrı).
enum AppPreferences {
    /// Menü çubuğunda ↓ simgesi (varsayılan açık).
    static let showInMenuBar = "showInMenuBar"
    /// Dock simgesi (varsayılan kapalı: Kervan menü çubuğu uygulaması olarak, arka planda çalışır).
    static let showInDock = "showInDock"
    /// Pano izlemenin önermeyeceği siteler.
    static let ignoredHosts = "clipboardIgnoredHosts"

    static var menuBarVisible: Bool { UserDefaults.standard.object(forKey: showInMenuBar) as? Bool ?? true }

    /// Kervan.app Dock'suz (LSUIElement) başlar; ayar açıksa normal uygulamaya (Dock + uygulama menüsü) geçer.
    @MainActor static func applyDockPolicy() {
        NSApp.setActivationPolicy(UserDefaults.standard.bool(forKey: showInDock) ? .regular : .accessory)
    }
}

@main
struct KervanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = QueueStore()
    @State private var clipboard = ClipboardWatcher()
    @AppStorage(AppPreferences.showInMenuBar) private var showInMenuBar = true

    var body: some Scene {
        Window("Kervan", id: "main") {
            MainView()
                .environment(store)
                .frame(minWidth: 760, minHeight: 360)
                .task { start() }
        }
        .defaultSize(width: 980, height: 520)
        // Açılışta pencere yok, menü çubuğunda başlar; simge gizliyse pencere açılır (yoksa hiçbir giriş kalmaz).
        .defaultLaunchBehavior(showInMenuBar ? .suppressed : .presented)

        MenuBarExtra(isInserted: $showInMenuBar) {
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
        // Pencere kapatılmış olsa da yeniden açabilen yol (menü çubuğu simgesi gizliyse pencere görünümünden alınır).
        .onAppear { MainWindow.remember(openWindow) }
    }
}

/// Ana pencereyi öne getirir; kapatılmışsa SwiftUI'nin `openWindow`'u ile yeniden açar.
@MainActor
enum MainWindow {
    static var opener: (() -> Void)?

    static func remember(_ openWindow: OpenWindowAction) {
        if opener == nil { opener = { openWindow(id: "main") } }
    }

    static func show() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            opener?()
        }
    }
}

/// Kervan menü çubuğu uygulaması olarak açılır; Dock simgesine ya da Kervan.app'e yeniden tıklanınca pencere açılır.
/// Pencere kapanınca uygulama kapanmaz: arka planda menü çubuğu, pano izleme ve bildirimler sürer.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppPreferences.applyDockPolicy()
            if !AppPreferences.menuBarVisible {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    MainWindow.show()
                }
            }
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
