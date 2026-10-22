import AppKit
import KervanIPC
import QueueKit
import SwiftUI

/// Panoyu saniyede bir yoklar; video sitesi ya da dosya linki kopyalanınca sağ üstte küçük bir öneri gösterir.
/// Aynı link bir kez önerilir; öneri 10 sn sonra kendiliğinden kapanır. Ayarda kapatılabilir.
@MainActor
final class ClipboardWatcher {
    private var timer: Timer?
    private var changeCount = NSPasteboard.general.changeCount
    private var lastSuggested: URL?
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private weak var store: QueueStore?

    func start(store: QueueStore) {
        guard timer == nil else { return }
        self.store = store
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != changeCount else { return }
        changeCount = pasteboard.changeCount
        guard store?.settings.clipboardWatch == true, store?.connected == true,
              let url = ClipboardHeuristics.looksDownloadable(pasteboard.string(forType: .string) ?? ""), url != lastSuggested
        else { return }
        lastSuggested = url
        show(url)
    }

    private func show(_ url: URL) {
        guard let store else { return }
        hide()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 76),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: ClipboardSuggestion(url: url, onClose: { [weak self] in self?.hide() })
            .environment(store))
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - 376, y: frame.maxY - 92))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled { self?.hide() }
        }
    }

    private func hide() {
        hideTask?.cancel()
        panel?.orderOut(nil)
        panel = nil
    }
}

struct ClipboardSuggestion: View {
    @Environment(QueueStore.self) private var store
    let url: URL
    let onClose: () -> Void
    @State private var status: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(status ?? "Panoda indirilebilir link").font(.callout.weight(.semibold))
                Text("\(url.host() ?? "") \(url.path())").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if status == nil {
                Button("Ekle") { add() }.keyboardShortcut(.defaultAction)
            }
            Button { onClose() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .padding(12)
        .frame(width: 360, height: 76)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func add() {
        status = "Ekleniyor…"
        Task {
            let response = await store.send(Request(cmd: .add, url: url.absoluteString, cookies: "auto", items: nil))
            if response.entries != nil {
                status = "Çok videolu sayfa: pencereden ekle"
            } else {
                status = response.ok ? "✓ Kuyrukta" : (response.error ?? "Eklenemedi")
            }
            try? await Task.sleep(for: .seconds(2))
            onClose()
        }
    }
}
