import Foundation

/// İptal edilen indirmenin yarım dosyaları. `path`, aracın yazacağı dosyadır (yt-dlp `before_dl`
/// adı, aria2'nin dosyası). yt-dlp: "ad.f137.mp4.part", "ad.mp4.part-Frag12", "ad.mp4.ytdl", "ad.temp.mp4",
/// birleşmemiş "ad.f137.mp4", altyazı/kapak ("ad.tr.vtt", "ad.webp"). aria2: "ad.mp4" + "ad.mp4.aria2".
/// Bitmiş dosyaya (aria2 kontrol dosyası olmayan "ad.mp4") ve başka adlı dosyalara dokunulmaz.
public enum PartialFiles {
    public static func find(for path: String) -> [URL] {
        let target = URL(filePath: path)
        let directory = target.deletingLastPathComponent()
        let name = target.lastPathComponent
        let base = target.deletingPathExtension().lastPathComponent
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var found = Set<String>()
        if files.contains(name + ".aria2") { found.formUnion([name, name + ".aria2"]) }
        for file in files where file != name && file.hasPrefix(base + ".") && isPartial(String(file.dropFirst(base.count + 1))) {
            found.insert(file)
        }
        return found.sorted().map { directory.appending(path: $0) }
    }

    @discardableResult
    public static func remove(for path: String) -> [URL] {
        let files = find(for: path)
        for file in files { try? FileManager.default.removeItem(at: file) }
        return files
    }

    /// `rest`: adın tabandan sonraki kısmı ("f137.mp4.part", "mp4.ytdl", "temp.mp4", "tr.vtt").
    static func isPartial(_ rest: String) -> Bool {
        if rest == "part" || rest.hasSuffix(".part") || rest.contains(".part-Frag") || rest.hasSuffix(".ytdl") { return true }
        let parts = rest.split(separator: ".").map(String.init)
        guard let first = parts.first, let last = parts.last else { return false }
        if first == "temp" { return true }
        if parts.count >= 2, first.count > 1, first.hasPrefix("f") { return true }  // birleşmemiş biçim parçası (.f137)
        return parts.count <= 2 && ["vtt", "srt", "ass", "lrc", "webp", "jpg", "png"].contains(last)
    }
}
