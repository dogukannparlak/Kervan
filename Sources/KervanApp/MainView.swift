import KervanIPC
import QueueKit
import SwiftUI

enum QueueFilter: String, CaseIterable, Identifiable {
    case all = "Tümü"
    case active = "Etkin"
    case waiting = "Beklemede"
    case done = "Biten"
    case failed = "Hatalı"

    var id: Self { self }

    func includes(_ item: DownloadItem) -> Bool {
        switch self {
        case .all: true
        case .active: !item.state.isFinished
        case .waiting: item.state == .waiting
        case .done: item.state == .done
        case .failed: item.state == .failed || item.state == .canceled
        }
    }
}

/// Onay bekleyen eylem (inen öğeyi iptal/silme).
struct PendingAction {
    let action: Request.Command
    let targets: [DownloadItem]

    var title: String {
        let what = targets.count == 1 ? "“\(targets[0].displayTitle)”" : "\(targets.count) öğe"
        return action == .cancel ? "\(what) iptal edilsin mi?" : "\(what) listeden silinsin mi?"
    }
}

struct MainView: View {
    @Environment(QueueStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var selection = Set<DownloadItem.ID>()
    @State private var filter = QueueFilter.all
    @State private var adding = false
    @State private var addingURL = ""
    @State private var pendingAction: PendingAction?
    @State private var configuring: [DownloadItem] = []

    /// Playlist çocukları grubun hemen altında, girintili.
    private var rows: [DownloadItem] {
        store.sorted.filter { $0.parentId == nil }.flatMap { item in
            item.kind == .group ? [item] + store.children(of: item) : [item]
        }.filter { filter.includes($0) }
    }

    private var selectedItems: [DownloadItem] { items(for: selection) }

    private func items(for ids: Set<DownloadItem.ID>) -> [DownloadItem] {
        ids.compactMap { $0.flatMap { store.items[$0] } }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !store.connected { ServiceBanner() }
            Table(rows, selection: $selection) {
                TableColumn("Ad") { item in
                    HStack(spacing: 6) {
                        if item.parentId != nil { Spacer().frame(width: 14) }
                        Image(systemName: icon(for: item)).foregroundStyle(.secondary).frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.displayTitle).lineLimit(1)
                            if let detail = detail(for: item) {
                                Text(detail).font(.caption).foregroundStyle(item.state == .failed ? .red : .secondary).lineLimit(1)
                            }
                        }
                    }
                    .help(item.lastError ?? item.url)
                }
                .width(min: 240, ideal: 420)
                TableColumn("Durum") { item in Text(item.state.label).foregroundStyle(color(for: item.state)) }
                    .width(90)
                TableColumn("İlerleme") { item in
                    if item.state == .waiting {
                        // Beklemedeyken yüzde yerine seçim ve başlatma düğmeleri.
                        HStack(spacing: 6) {
                            Button { configuring = [item] } label: {
                                Label(item.presetId, systemImage: "slider.horizontal.3").lineLimit(1)
                            }
                            .help("Kalite / ayarlar")
                            Button("İndir") { run(.resume, on: [item]) }
                                .buttonStyle(.borderedProminent)
                        }
                        .controlSize(.small)
                    } else if item.state == .done {
                        Text("100%").monospacedDigit().foregroundStyle(.secondary)
                    } else if let fraction = item.fraction {
                        HStack {
                            ProgressView(value: fraction).controlSize(.small)
                            Text("\(Int(fraction * 100))%").monospacedDigit().frame(width: 36, alignment: .trailing)
                        }
                    } else if item.state.isActive {
                        ProgressView().controlSize(.small)
                    }
                }
                .width(min: 170, ideal: 190)
                TableColumn("Boyut") { item in Text(item.state == .waiting ? "" : item.sizeText).monospacedDigit() }.width(80)
                TableColumn("Hız") { item in Text(item.speedText).monospacedDigit() }.width(80)
                TableColumn("Kalan") { item in Text(item.etaText).monospacedDigit() }.width(56)
            }
            .contextMenu(forSelectionType: DownloadItem.ID.self) { ids in
                let targets = items(for: ids)
                if targets.count == 1, let item = targets.first, item.state == .done {
                    Button("Aç") { store.open(item) }
                }
                if !targets.isEmpty, targets.allSatisfy({ $0.state == .waiting }) {
                    Button("Kalite / ayarlar…") { configuring = targets }
                }
                ForEach(commonActions(targets), id: \.self) { action in
                    Button(action.title) { run(action, on: targets) }
                }
                if targets.count == 1, let item = targets.first {
                    Divider()
                    Button("Linki kopyala") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.url, forType: .string)
                    }
                }
            } primaryAction: { ids in
                let targets = items(for: ids)
                if !targets.isEmpty, targets.allSatisfy({ $0.state == .waiting }) {
                    configuring = targets  // çift tıklama: beklemedeki öğenin ayarları
                } else if let item = targets.first {
                    store.open(item)
                }
            }
            .overlay {
                if rows.isEmpty {
                    ContentUnavailableView(store.items.isEmpty ? "Kuyruk boş" : "Bu filtrede öğe yok",
                                           systemImage: "arrow.down.circle",
                                           description: Text("Eklemek için ⌘N, linki buraya sürükle ya da Brave'de videonun üstündeki düğme."))
                }
            }
            StatusBar()
        }
        // Tarayıcıdan link ya da adres çubuğundan sürüklenen sayfa doğrudan eklenir.
        .dropDestination(for: URL.self) { urls, _ in
            store.addDropped(urls)
            return true
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    addingURL = ""
                    adding = true
                } label: { Label("Ekle", systemImage: "plus") }
                    .keyboardShortcut("n")
                    .help("Link ekle (⌘N)")
            }
            ToolbarItemGroup {
                ForEach([Request.Command.pause, .resume, .cancel, .retry, .reveal, .remove], id: \.self) { action in
                    Button { run(action, on: selectedItems) } label: { Label(action.title, systemImage: action.symbol) }
                        .disabled(!commonActions(selectedItems).contains(action))
                        .help(action.title)
                }
            }
            ToolbarItem {
                Button { Task { await store.clean() } } label: { Label("Bitenleri temizle", systemImage: "checkmark.circle.badge.xmark") }
                    .help("Bitmiş ve iptal edilmiş öğeleri listeden sil (dosyalar kalır)")
                    .disabled(!store.items.values.contains { $0.kind != .group && ($0.state == .done || $0.state == .canceled) })
            }
            if selectedItems.contains(where: { $0.state == .waiting }) {
                ToolbarItem {
                    Button { configuring = selectedItems.filter { $0.state == .waiting } } label: {
                        Label("Kalite / ayarlar", systemImage: "slider.horizontal.3")
                    }
                    .help("Seçili beklemedeki öğelerin kalitesini seç")
                }
            }
            if store.waitingCount > 0 {
                ToolbarItem {
                    Button { Task { await store.resumeWaiting() } } label: {
                        Label("Beklemedekileri başlat", systemImage: "play.circle")
                    }
                    .help("Beklemedeki \(store.waitingCount) öğeyi indirmeye başlat")
                }
            }
            ToolbarItem {
                // Dock ve menü çubuğu gizliyken uygulama menüsü yok; ayarlara buradan ulaşılır.
                SettingsLink { Label("Ayarlar", systemImage: "gearshape") }.help("Ayarlar (⌘,)")
            }
            ToolbarItem {
                Picker("Filtre", selection: $filter) {
                    ForEach(QueueFilter.allCases) { option in
                        Text(option == .waiting && store.waitingCount > 0 ? "Beklemede (\(store.waitingCount))" : option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .sheet(isPresented: Binding(get: { !configuring.isEmpty }, set: { if !$0 { configuring = [] } })) {
            WaitingSettingsView(targets: configuring).environment(store)
        }
        .sheet(isPresented: $adding) { AddView(initialURL: addingURL).environment(store) }
        .confirmationDialog(pendingAction?.title ?? "", isPresented: Binding(
            get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }
        ), presenting: pendingAction) { pending in
            Button(pending.action == .cancel ? "İndirmeyi iptal et" : "Sil", role: .destructive) {
                run(pending.action, on: pending.targets, confirmed: true)
            }
            Button("Vazgeç", role: .cancel) {}
        } message: { _ in
            Text("İnmekte olan kısım kaybolur.")
        }
        .onAppear {
            // Menü çubuğu simgesi gizliyse pencereyi yeniden açabilen yol buradan alınır.
            MainWindow.remember(openWindow)
            openPendingAdd()
        }
        .onChange(of: store.pendingAdd) { openPendingAdd() }
        .onDeleteCommand { run(.remove, on: selectedItems.filter { $0.actions.contains(.remove) }) }
    }

    /// Pano ya da menü çubuğundan gelen çok videolu sayfa: ekleme sayfası linkle açılır, seçim orada yapılır.
    private func openPendingAdd() {
        guard let link = store.pendingAdd else { return }
        store.pendingAdd = nil
        addingURL = link
        adding = true
    }

    /// Seçili öğelerin hepsinde geçerli eylemler.
    private func commonActions(_ targets: [DownloadItem]) -> [Request.Command] {
        guard let first = targets.first else { return [] }
        let shared = targets.dropFirst().reduce(Set(first.actions)) { $0.intersection($1.actions) }
        return first.actions.filter { shared.contains($0) && ($0 != .reveal || targets.count == 1) }
    }

    private func run(_ action: Request.Command, on targets: [DownloadItem], confirmed: Bool = false) {
        if action == .reveal, let item = targets.first { return store.reveal(item) }
        if !confirmed, action.needsConfirmation(for: targets) {
            pendingAction = PendingAction(action: action, targets: targets)
            return
        }
        Task { await store.perform(action, ids: targets.compactMap(\.id)) }
    }

    private func icon(for item: DownloadItem) -> String {
        if item.kind == .group { return "list.bullet" }
        if item.presetId == "audio" || item.presetId == "mp3" { return "music.note" }
        return item.kind == .http ? "doc" : "film"
    }

    private func detail(for item: DownloadItem) -> String? {
        if item.state == .failed { return item.lastError?.replacingOccurrences(of: "\n", with: " ") }
        var parts = [item.host]
        if item.kind == .video, item.presetId != "1080p" || item.state == .waiting { parts.append(item.presetId) }
        if let message = item.message, item.state != .done { parts.append(message) }
        return parts.joined(separator: " · ")
    }

    private func color(for state: ItemState) -> Color {
        switch state {
        case .downloading, .postprocessing: .accentColor
        case .failed: .red
        case .done: .secondary
        default: .primary
        }
    }
}

struct ServiceBanner: View {
    @Environment(QueueStore.self) private var store

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text("kervand çalışmıyor; kuyruk gösterilemiyor.")
            Spacer()
            Button("Başlat") { store.startService() }
        }
        .padding(8)
        .background(.yellow.opacity(0.12))
    }
}

struct StatusBar: View {
    @Environment(QueueStore.self) private var store

    var body: some View {
        HStack {
            if let message = store.message {
                Text(message).lineLimit(1).foregroundStyle(.secondary)
                Button("×") { store.message = nil }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Spacer()
            let active = store.active.count
            if active > 0 {
                Text("\(active) iniyor · \(Format.bytes(Int64(store.totalSpeed)))/s").monospacedDigit()
            } else {
                Text("\(store.items.values.filter { $0.kind != .group }.count) öğe")
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }
}
