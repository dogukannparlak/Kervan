import KervanIPC
import QueueKit
import SwiftUI

/// Menü çubuğu penceresi: etkin indirmeler, hızlı ekleme, pencere ve ayarlar.
struct MenuBarView: View {
    @Environment(QueueStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var link = ""

    private var recent: [DownloadItem] {
        let items = store.sorted.filter { $0.kind != .group }
        return Array((store.active + items.filter { !$0.state.isActive }).prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Kervan").font(.headline)
                Spacer()
                if store.connected {
                    Text(store.active.isEmpty ? "boşta" : "\(store.active.count) iniyor · \(Format.bytes(Int64(store.totalSpeed)))/s")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Button("Servisi başlat") { store.startService() }.controlSize(.small)
                }
            }
            HStack {
                TextField("Link yapıştır", text: $link).textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Ekle", action: add).disabled(URL(string: link)?.scheme == nil)
            }
            if recent.isEmpty {
                Text("Kuyruk boş.").foregroundStyle(.secondary).font(.callout)
            } else {
                VStack(spacing: 8) {
                    ForEach(recent) { item in MenuRow(item: item) }
                }
            }
            if let message = store.message {
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Divider()
            HStack {
                Button("Pencereyi aç") {
                    openWindow(id: "main")
                    MainWindow.show()
                }
                SettingsLink { Text("Ayarlar…") }
                Spacer()
                Button("Çık") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 340)
    }

    private func add() {
        let text = link.trimmingCharacters(in: .whitespaces)
        guard URL(string: text)?.scheme != nil else { return }
        link = ""
        Task {
            let response = await store.send(Request(cmd: .add, url: text, cookies: "auto"))
            if response.entries != nil {
                store.message = "Çok videolu sayfa: seçmek için pencereden ekle."
            } else {
                store.message = response.ok ? "Eklendi: \(response.items?.first?.displayTitle ?? text)" : response.error
            }
        }
    }
}

struct MenuRow: View {
    @Environment(QueueStore.self) private var store
    let item: DownloadItem

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayTitle).lineLimit(1).font(.callout)
                if item.state.isActive || item.state == .queued || item.state == .paused {
                    ProgressView(value: item.fraction ?? 0).controlSize(.mini)
                }
                Text([item.state.label, item.fraction.map { "\(Int($0 * 100))%" } ?? "", item.speedText, item.etaText]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(item.state == .failed ? .red : .secondary).monospacedDigit()
            }
            Spacer(minLength: 4)
            ForEach(item.actions.filter { $0 != .remove }, id: \.self) { action in
                Button {
                    if action == .reveal { store.reveal(item) } else { Task { await store.perform(action, ids: [item.id ?? 0]) } }
                } label: {
                    Image(systemName: action.symbol)
                }
                .buttonStyle(.borderless)
                .help(action.title)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { store.open(item) }
    }
}
