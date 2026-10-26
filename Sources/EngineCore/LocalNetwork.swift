import Foundation

/// Yerel ağ adresleri: localhost, özel/loopback/link-local IPv4 blokları, IPv6 loopback/ULA/link-local,
/// `.local` gibi yerel adlar ve tek etiketli adlar ("nas", "router").
/// Web sayfasından (eklentiden) gelen isteklerin kullanıcının yerel ağına ulaşmasını engellemek için.
/// Ad çözümlenmez: DNS ile yerel bir IP'ye çözülen alan adları burada yakalanmaz.
public enum LocalNetwork {
    public static func isLocal(_ url: URL) -> Bool {
        guard var host = url.host(percentEncoded: false)?.lowercased() else { return true }
        host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.hasSuffix(".") { host.removeLast() }
        if host.isEmpty || host == "localhost" { return true }
        if [".localhost", ".local", ".lan", ".internal", ".home.arpa"].contains(where: { host.hasSuffix($0) }) { return true }
        if host.contains(":") { return isLocalIPv6(host) }
        if let address = ipv4(host) { return isLocalIPv4(address) }
        return !host.contains(".")
    }

    /// inet_aton gibi okur: "127.0.0.1", "127.1", "0x7f.0.0.1", "2130706433" hepsi 127.0.0.1.
    static func ipv4(_ host: String) -> UInt32? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var values: [UInt32] = []
        for part in parts {
            let text = String(part)
            let value: UInt32?
            if text.hasPrefix("0x") {
                value = UInt32(text.dropFirst(2), radix: 16)
            } else if text.count > 1, text.hasPrefix("0") {
                value = UInt32(text.dropFirst(), radix: 8)
            } else {
                value = UInt32(text)
            }
            guard let value else { return nil }
            values.append(value)
        }
        // Son parça kalan baytların hepsini doldurur.
        var address: UInt32 = 0
        for (index, value) in values.dropLast().enumerated() {
            guard value <= 255 else { return nil }
            address |= value << UInt32(24 - 8 * index)
        }
        let restBits = 32 - 8 * (values.count - 1)
        guard let last = values.last, restBits == 32 || last < (UInt32(1) << UInt32(restBits)) else { return nil }
        return address | last
    }

    static func isLocalIPv4(_ address: UInt32) -> Bool {
        let a = address >> 24
        let b = (address >> 16) & 0xFF
        return a == 0 || a == 10 || a == 127
            || (a == 169 && b == 254)
            || (a == 172 && (16...31).contains(b))
            || (a == 192 && b == 168)
            || (a == 100 && (64...127).contains(b))  // CGNAT
    }

    static func isLocalIPv6(_ host: String) -> Bool {
        let host = host.split(separator: "%").first.map(String.init) ?? host  // bölge kimliği (fe80::1%en0)
        if host.hasPrefix("::ffff:"), let mapped = ipv4(String(host.dropFirst(7))) { return isLocalIPv4(mapped) }
        let groups = host.split(separator: ":").map { UInt16($0, radix: 16) }
        if groups.contains(nil) { return true }  // anlaşılmayan adres: güvenli taraf
        if groups.allSatisfy({ $0 == 0 }) { return true }  // ::
        if groups.dropLast().allSatisfy({ $0 == 0 }) && groups.last == 1 { return true }  // ::1
        guard !host.hasPrefix(":"), let first = groups.first ?? nil else { return false }
        return (first & 0xFE00) == 0xFC00 || (first & 0xFFC0) == 0xFE80
    }
}
