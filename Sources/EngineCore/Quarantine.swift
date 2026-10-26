import Darwin
import Foundation

/// İnen dosyaya macOS karantina etiketi (`com.apple.quarantine`) koyar, tarayıcıların yaptığı gibi:
/// indirilen .app/.pkg/.dmg açılırken Gatekeeper denetler; video ve belgeler her zamanki gibi açılır.
public enum Quarantine {
    static let attribute = "com.apple.quarantine"

    /// Hata sessizce yutulur (dosya yoksa ya da dosya sistemi xattr desteklemiyorsa indirme yine başarılı).
    public static func mark(_ file: URL, agent: String = "Kervan", now: Date = Date()) {
        // 0081: indirilmiş, kullanıcı henüz açmamış (Chrome/Safari'nin yazdığı bayraklar).
        let value = "0081;\(String(Int(now.timeIntervalSince1970), radix: 16));\(agent);\(UUID().uuidString)"
        _ = value.withCString { pointer in
            setxattr(file.path, attribute, pointer, strlen(pointer), 0, 0)
        }
    }

    public static func value(of file: URL) -> String? {
        let size = getxattr(file.path, attribute, nil, 0, 0, 0)
        guard size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        let read = getxattr(file.path, attribute, &buffer, size, 0, 0)
        guard read > 0 else { return nil }
        return String(decoding: buffer.prefix(read), as: UTF8.self)
    }
}
