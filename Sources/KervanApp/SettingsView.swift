import AppKit
import KervanIPC
import QueueKit
import SwiftUI

struct SettingsView: View {
    @Environment(QueueStore.self) private var store
    @State private var loginItem = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        @Bindable var store = store
        Form {
            Section("İndirme") {
                LabeledContent("Klasör") {
                    HStack {
                        Text(store.settings.downloadDirectory).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Seç…", action: chooseFolder)
                    }
                }
                Toggle("Türe göre klasörle (Video, Müzik, Belgeler, Arşivler, Programlar)", isOn: $store.settings.categorize)
                Picker("Varsayılan kalite", selection: $store.settings.defaultPreset) {
                    ForEach(["best", "2160p", "1440p", "1080p", "720p", "480p", "audio", "mp3"], id: \.self) { Text($0).tag($0) }
                }
                Toggle("Altyazıyı göm", isOn: $store.settings.subtitles)
                TextField("Altyazı dilleri", text: $store.settings.subtitleLanguages, prompt: Text("tr,en"))
            }
            Section("Eşzamanlılık") {
                Stepper("Aynı anda en fazla \(store.settings.maxParallel) indirme", value: $store.settings.maxParallel, in: 1...10)
                Stepper("Aynı siteden en fazla \(store.settings.maxPerHost)", value: $store.settings.maxPerHost, in: 1...store.settings.maxParallel)
            }
            Section("yt-dlp") {
                Toggle("Günde bir kez kendiliğinden güncelle", isOn: $store.settings.autoUpdate)
                LabeledContent("Son kontrol") {
                    VStack(alignment: .trailing) {
                        Text(store.updateState.lastCheck?.formatted() ?? "henüz yok")
                        if let result = store.updateState.lastResult { Text(result).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Button("Şimdi güncelle") { Task { await store.updateYtDlp() } }
            }
            Section("Uygulama") {
                Toggle("Panoya video linki kopyalanınca öner", isOn: $store.settings.clipboardWatch)
                Toggle("Oturum açılınca başlat", isOn: $loginItem)
                    .onChange(of: loginItem) { _, enabled in
                        do {
                            try LoginItem.set(enabled)
                            loginError = nil
                        } catch {
                            loginError = "Ayarlanamadı: \(error.localizedDescription)"
                            loginItem = LoginItem.isEnabled
                        }
                    }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                LabeledContent("Servis", value: store.connected ? "kervand \(store.version ?? "") çalışıyor" : "çalışmıyor")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onChange(of: store.settings) { _, _ in Task { await store.saveSettings() } }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let path = panel.url?.path { store.settings.downloadDirectory = path }
    }
}
