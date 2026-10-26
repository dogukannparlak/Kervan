import AppKit
import EngineCore
import KervanIPC
import QueueKit
import SwiftUI

/// Link ekleme: kalite listesi (yt-dlp formatları), klasör, altyazı; çok videolu sayfada seçim.
struct AddView: View {
    @Environment(QueueStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var initialURL = ""
    @State private var url = ""
    @State private var preset = ""
    @State private var qualities: [QualityOption] = []
    @State private var loadingQualities = false
    @State private var folder: String?
    @State private var subtitles = false
    @State private var entries: [ProbeResult.Entry] = []
    @State private var selection = "all"
    @State private var busy = false
    @State private var error: String?
    /// Link zaten listede: "Yine de ekle" gösterilir.
    @State private var duplicateOf: Int64?

    private var presetChoices: [(id: String, label: String)] {
        if !qualities.isEmpty {
            return qualities.map { ($0.preset, $0.label + ($0.size.map { "  ·  ~" + Format.bytes($0) } ?? "")) }
        }
        return [("best", "En iyi"), ("2160p", "2160p"), ("1440p", "1440p"), ("1080p", "1080p"), ("720p", "720p"),
                ("480p", "480p"), ("audio", "Yalnız ses (m4a)"), ("mp3", "MP3")]
    }

    var body: some View {
        Form {
            TextField("Link", text: $url, prompt: Text("https://…"))
                .onSubmit { Task { await loadQualities() } }
            HStack {
                Picker("Kalite", selection: $preset) {
                    ForEach(presetChoices, id: \.id) { Text($0.label).tag($0.id) }
                }
                Button(loadingQualities ? "Alınıyor…" : "Kaliteleri getir") { Task { await loadQualities() } }
                    .disabled(loadingQualities || URL(string: url)?.scheme == nil)
            }
            LabeledContent("Klasör") {
                HStack {
                    Text(folder ?? (store.settings.categorize ? "\(store.settings.downloadDirectory)/<tür>" : store.settings.downloadDirectory))
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Button("Seç…") { chooseFolder() }
                    if folder != nil { Button("Varsayılan") { folder = nil } }
                }
            }
            Toggle("Altyazıyı göm (\(store.settings.subtitleLanguages))", isOn: $subtitles)
            if !entries.isEmpty {
                Section("Bu sayfada \(entries.count) video var") {
                    TextField("Hangileri", text: $selection, prompt: Text("all ya da 1,3 ya da 2-5"))
                    List(Array(entries.prefix(30).enumerated()), id: \.offset) { index, entry in
                        Text("\(index + 1). \(entry.title ?? entry.url ?? "?")").lineLimit(1)
                    }
                    .frame(height: 120)
                }
            }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if duplicateOf != nil {
                Button("Yine de ekle") { Task { await add(force: true) } }.disabled(busy)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(busy ? "Ekleniyor…" : "Ekle") { Task { await add() } }
                    .disabled(busy || URL(string: url)?.scheme == nil)
            }
        }
        .onAppear {
            url = initialURL.isEmpty ? (ClipboardHeuristics.looksDownloadable(NSPasteboard.general.string(forType: .string) ?? "")?.absoluteString ?? "") : initialURL
            preset = store.settings.defaultPreset
            subtitles = store.settings.subtitles
        }
    }

    private func loadQualities() async {
        guard !url.isEmpty else { return }
        loadingQualities = true
        defer { loadingQualities = false }
        let response = await store.send(Request(cmd: .formats, url: url.trimmingCharacters(in: .whitespaces), cookies: "auto"))
        if let options = response.qualities?.options, !options.isEmpty {
            qualities = options
            if !options.contains(where: { $0.preset == preset }) {
                preset = options.first { $0.preset == store.settings.defaultPreset }?.preset ?? options[0].preset
            }
            error = nil
        } else if !response.ok {
            error = response.error
        }
    }

    private func add(force: Bool = false) async {
        busy = true
        defer { busy = false }
        var request = Request(cmd: .add, url: url.trimmingCharacters(in: .whitespaces), preset: preset, dir: folder,
                              cookies: "auto", items: entries.isEmpty ? nil : selection, subtitles: subtitles)
        request.force = force
        request.size = qualities.first { $0.preset == preset }?.size
        let response = await store.send(request)
        duplicateOf = response.duplicateOf
        if !response.ok {
            error = response.error
        } else if let found = response.entries {
            entries = found
            error = nil
        } else {
            store.message = "Kuyruğa eklendi: \(response.items?.first?.displayTitle ?? url)"
            dismiss()
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let path = panel.url?.path { folder = path }
    }
}
