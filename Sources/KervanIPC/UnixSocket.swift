import Darwin
import Foundation

public enum SocketError: Error, CustomStringConvertible {
    case pathTooLong(String)
    case system(String, Int32)
    case disconnected

    public var description: String {
        switch self {
        case .pathTooLong(let path): "Soket yolu çok uzun (en fazla 103 bayt): \(path)"
        case .system(let call, let code): "\(call) başarısız: \(String(cString: strerror(code)))"
        case .disconnected: "Bağlantı kapandı."
        }
    }
}

/// Satır başına bir JSON mesajı taşıyan bloklayan soket bağlantısı.
/// Okuma tek iş parçacığından yapılır; yazma kilitlidir (abonelik + yanıt aynı anda yazabilir).
public final class LineConnection: @unchecked Sendable {
    let fd: Int32
    private var buffer = Data()
    private let writeLock = NSLock()

    init(fd: Int32) {
        self.fd = fd
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    public func send<T: Encodable>(_ value: T) throws {
        var data = try IPCCoding.encoder().encode(value)
        data.append(0x0A)
        try writeLock.withLock {
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw SocketError.system("write", errno)
                    }
                    offset += written
                }
            }
        }
    }

    public func receive<T: Decodable>(_ type: T.Type) throws -> T {
        guard let line = readLine() else { throw SocketError.disconnected }
        return try IPCCoding.decoder().decode(type, from: line)
    }

    func readLine() -> Data? {
        while true {
            if let index = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<index]
                buffer.removeSubrange(buffer.startIndex...index)
                return Data(line)
            }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }

    public func close() {
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }

    /// Testler için birbirine bağlı iki uç.
    public static func pair() throws -> (LineConnection, LineConnection) {
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw SocketError.system("socketpair", errno) }
        return (LineConnection(fd: fds[0]), LineConnection(fd: fds[1]))
    }
}

enum UnixSocket {
    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw SocketError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }

    static func connect(path: String) throws -> LineConnection {
        var address = try address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system("socket", errno) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw SocketError.system("connect", code)
        }
        return LineConnection(fd: fd)
    }

    static func listen(path: String) throws -> Int32 {
        var address = try address(path)
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system("socket", errno) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { throw SocketError.system("bind", errno) }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 16) == 0 else { throw SocketError.system("listen", errno) }
        return fd
    }
}
