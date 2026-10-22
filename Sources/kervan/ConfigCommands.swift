import ArgumentParser
import EngineCore
import Foundation
import KervanIPC

struct Update: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "yt-dlp'yi şimdi günceller (servis zaten günde bir kez yapar).")

    func run() throws {
        print("yt-dlp güncelleniyor (ilk kurulumda ~40 MB indirilir)…")
        let state = try send(Request(cmd: .update)).update
        print(state?.lastResult ?? "sonuç yok")
    }
}

struct Config: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Ayarları gösterir ya da değiştirir.",
        discussion: """
        Anahtarlar: downloadDirectory, categorize, defaultPreset, subtitles, subtitleLanguages,
        autoUpdate, maxParallel, maxPerHost, clipboardWatch.
        Örnek: kervan config maxParallel 5 · kervan config categorize false
        """
    )

    @Argument(help: "Ayar adı (boşsa hepsi).")
    var key: String?

    @Argument(help: "Yeni değer.")
    var value: String?

    func run() throws {
        let client = try connect()
        var settings = try send(Request(cmd: .settings), with: client).settings ?? KervanSettings()
        guard let key else {
            print(String(decoding: try Self.encoder.encode(settings), as: UTF8.self))
            return
        }
        guard let value else {
            print(try Self.field(key, of: settings))
            return
        }
        try Self.set(key, to: value, in: &settings)
        let saved = try send(Request(cmd: .setSettings, settings: settings), with: client).settings ?? settings
        print("✓ \(key) = \(try Self.field(key, of: saved))")
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static func field(_ key: String, of settings: KervanSettings) throws -> String {
        let object = try JSONSerialization.jsonObject(with: encoder.encode(settings)) as? [String: Any] ?? [:]
        guard let value = object[key] else { throw ValidationError("Bilinmeyen ayar: \(key)") }
        if let bool = value as? Bool { return bool ? "true" : "false" }
        return "\(value)"
    }

    static func set(_ key: String, to text: String, in settings: inout KervanSettings) throws {
        func bool() throws -> Bool {
            switch text.lowercased() {
            case "true", "1", "evet", "açık", "on": return true
            case "false", "0", "hayır", "kapalı", "off": return false
            default: throw ValidationError("\(key) için true ya da false yaz.")
            }
        }
        func int() throws -> Int {
            guard let number = Int(text) else { throw ValidationError("\(key) için sayı yaz.") }
            return number
        }
        switch key {
        case "downloadDirectory": settings.downloadDirectory = NSString(string: text).expandingTildeInPath
        case "categorize": settings.categorize = try bool()
        case "defaultPreset": settings.defaultPreset = text
        case "subtitles": settings.subtitles = try bool()
        case "subtitleLanguages": settings.subtitleLanguages = text
        case "autoUpdate": settings.autoUpdate = try bool()
        case "maxParallel": settings.maxParallel = try int()
        case "maxPerHost": settings.maxPerHost = try int()
        case "clipboardWatch": settings.clipboardWatch = try bool()
        default: throw ValidationError("Bilinmeyen ayar: \(key)")
        }
    }
}
