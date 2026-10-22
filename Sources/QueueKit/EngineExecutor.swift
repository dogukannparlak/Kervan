import EngineCore
import Foundation

/// Bir kuyruk öğesini gerçekten indiren taraf; testlerde sahtesi kullanılır.
public protocol DownloadExecuting: Sendable {
    func run(_ item: DownloadItem) -> AsyncThrowingStream<DownloadEvent, Error>
}

/// Öğe türüne göre yt-dlp ya da aria2 adapter'ını çalıştırır.
public struct EngineExecutor: DownloadExecuting {
    let ytDlp: YtDlpAdapter
    let aria2: Aria2Adapter?

    public init(locator: ToolLocator) throws {
        guard let ytDlpPath = locator.locate(.ytDlp) else { throw EngineError.toolMissing(.ytDlp) }
        ytDlp = YtDlpAdapter(executable: ytDlpPath, ffmpeg: locator.locate(.ffmpeg), environment: locator.environment)
        aria2 = locator.locate(.aria2c).map { Aria2Adapter(executable: $0, environment: locator.environment) }
    }

    public var resolver: LinkResolver { LinkResolver(ytDlp: ytDlp) }

    public func run(_ item: DownloadItem) -> AsyncThrowingStream<DownloadEvent, Error> {
        do {
            guard let url = URL(string: item.url) else { throw QueueError.invalidURL(item.url) }
            let directory = URL(filePath: item.destination)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            switch item.kind {
            case .http:
                guard let aria2 else { throw EngineError.toolMissing(.aria2c) }
                return aria2.download(url, to: directory, context: item.context)
            case .video:
                guard let preset = try PresetStore.named(item.presetId) else { throw QueueError.unknownPreset(item.presetId) }
                return ytDlp.download(url, preset: preset, to: directory, cookiesFromBrowser: item.cookiesBrowser,
                                      playlistItems: item.playlistIndex.map(String.init), context: item.context)
            case .group:
                throw QueueError.notDownloadable(item.id ?? 0)
            }
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }
}

public enum QueueError: Error, Equatable, CustomStringConvertible {
    case notFound(Int64)
    case invalidTransition(Int64, from: ItemState, to: ItemState)
    case unknownPreset(String)
    case invalidURL(String)
    case invalidSelection(String)
    case notDownloadable(Int64)

    public var description: String {
        switch self {
        case .notFound(let id): "#\(id) bulunamadı."
        case .invalidTransition(let id, let from, let to): "#\(id) şu an \(from.rawValue); \(to.rawValue) yapılamaz."
        case .unknownPreset(let id): "Bilinmeyen preset: \(id) (liste: kervan presets)."
        case .invalidURL(let url): "Geçerli bir http(s) linki değil: \(url)"
        case .invalidSelection(let text): "Geçersiz seçim: \(text) (ör. 1,3 ya da 2-5)."
        case .notDownloadable(let id): "#\(id) bir grup; kendisi inmez."
        }
    }
}

/// "1,3,5-7" → [1, 3, 5, 6, 7]; "all" → hepsi. 1 tabanlı, tekrarsız, sıralı.
public enum PlaylistSelection {
    public static func parse(_ text: String, count: Int) throws -> [Int] {
        if text.lowercased() == "all" { return Array(1...max(count, 1)).filter { $0 <= count } }
        var result = Set<Int>()
        for part in text.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
            switch bounds.count {
            case 1:
                guard let index = bounds[0] else { throw QueueError.invalidSelection(text) }
                result.insert(index)
            case 2:
                guard let low = bounds[0], let high = bounds[1], low <= high else { throw QueueError.invalidSelection(text) }
                result.formUnion(low...high)
            default:
                throw QueueError.invalidSelection(text)
            }
        }
        guard !result.isEmpty, result.allSatisfy({ (1...count).contains($0) }) else { throw QueueError.invalidSelection(text) }
        return result.sorted()
    }
}
