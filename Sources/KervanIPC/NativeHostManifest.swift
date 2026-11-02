import Foundation

/// Native Messaging manifest'ini kurulu tarayıcı klasörlerine yazar. `kervan extension install` ve
/// kervand (her açılışta, sessizce) aynı kodu kullanır; böylece manifest silinse ya da tarayıcı sonradan
/// kurulsa köprü kendiliğinden onarılır.
public enum NativeHostManifest {
    /// Yazılan tarayıcı klasörleri (Application Support'a göre). Köprü ikilisi yoksa boş döner.
    @discardableResult
    public static func install(paths: KervanPaths = KervanPaths()) throws -> [String] {
        let fileManager = FileManager.default
        let host = paths.bin.appending(path: "kervan-native-host")
        guard fileManager.isExecutableFile(atPath: host.path) else { return [] }
        let manifest: [String: Any] = [
            "name": KervanPaths.nativeHostName,
            "description": "Kervan indirme yöneticisi köprüsü",
            "path": host.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(KervanPaths.extensionID)/"],
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var installed: [String] = []
        for browser in KervanPaths.browserDirectories {
            let browserDir = support.appending(path: browser)
            guard fileManager.fileExists(atPath: browserDir.path) else { continue }
            let hosts = browserDir.appending(path: "NativeMessagingHosts")
            try fileManager.createDirectory(at: hosts, withIntermediateDirectories: true)
            let file = hosts.appending(path: "\(KervanPaths.nativeHostName).json")
            if (try? Data(contentsOf: file)) != data { try data.write(to: file) }
            installed.append(browser)
        }
        return installed
    }
}
