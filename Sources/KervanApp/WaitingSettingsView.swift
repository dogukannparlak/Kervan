import EngineCore
import KervanIPC
import QueueKit
import SwiftUI

/// Beklemedeki öğelerin kalitesini seçer; "Kaydet ve başlat" öğeleri indirmeye alır.
struct WaitingSettingsView: View {
    @Environment(QueueStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let targets: [DownloadItem]
    @State private var preset = ""
    @State private var qualities: [QualityOption] = []
    @State private var loading = false
    @State private var error: String?

    private var choices: [(id: String, label: String)] {
        if !qualities.isEmpty {
            return qualities.map { ($0.preset, $0.label + ($0.size.map { "  ·  ~" + Format.bytes($0) } ?? "")) }
        }
        return [("best", "En iyi"), ("2160p", "2160p"), ("1440p", "1440p"), ("1080p", "1080p"), ("720p", "720p"),
                ("480p", "480p"), ("audio", "Yalnız ses (m4a)"), ("mp3", "MP3")]
    }

    var body: some View {
        Form {
            Text(targets.count == 1 ? targets[0].displayTitle : "\(targets.count) öğe").font(.headline).lineLimit(2)
            Picker("Kalite", selection: $preset) {
                ForEach(choices, id: \.id) { Text($0.label).tag($0.id) }
            }
            if loading { ProgressView("Kaliteler alınıyor…").controlSize(.small) }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Vazgeç") { dismiss() } }
            ToolbarItem(placement: .automatic) { Button("Kaydet") { Task { await save(start: false) } } }
            ToolbarItem(placement: .confirmationAction) { Button("Kaydet ve başlat") { Task { await save(start: true) } } }
        }
        .task {
            preset = targets.first?.presetId ?? store.settings.defaultPreset
            // Tek video seçiliyse o videonun gerçek kaliteleri gelir; liste/çoklu seçimde hazır liste kullanılır.
            guard targets.count == 1, let item = targets.first, item.kind == .video else { return }
            loading = true
            defer { loading = false }
            let response = await store.send(Request(cmd: .formats, url: item.url, cookies: "auto"))
            if let options = response.qualities?.options, !options.isEmpty {
                qualities = options
                if !options.contains(where: { $0.preset == preset }) { preset = options[0].preset }
            }
        }
    }

    private func save(start: Bool) async {
        let ids = targets.compactMap(\.id)
        var request = Request(cmd: .setPreset, preset: preset, ids: ids)
        request.size = qualities.first { $0.preset == preset }?.size
        let response = await store.send(request)
        guard response.ok else {
            error = response.error
            return
        }
        if start { await store.perform(.resume, ids: ids) }
        store.message = start ? "Başlatıldı: \(preset)" : "Kalite kaydedildi: \(preset)"
        dismiss()
    }
}
