import Foundation

/// CLI ve app'in `kervand` istemcisi (bloklayan, tek bağlantı).
public final class IPCClient {
    private let connection: LineConnection

    public init(paths: KervanPaths = KervanPaths()) throws {
        connection = try UnixSocket.connect(path: paths.socket.path)
    }

    init(connection: LineConnection) {
        self.connection = connection
    }

    deinit { connection.close() }

    public func request(_ request: Request) throws -> Response {
        try connection.send(request)
        return try connection.receive(Response.self)
    }

    /// `subscribe` gönderir; sonra her değişiklik olayını `handler`'a verir. `handler` false dönerse biter.
    public func subscribe(_ handler: (Response) -> Bool) throws {
        let ack = try request(Request(cmd: .subscribe))
        guard ack.ok else { throw SocketError.disconnected }
        while true {
            let event = try connection.receive(Response.self)
            if !handler(event) { return }
        }
    }

    /// Servis çalışıyor mu?
    public static func ping(paths: KervanPaths = KervanPaths()) -> String? {
        guard let client = try? IPCClient(paths: paths), let response = try? client.request(Request(cmd: .ping)) else { return nil }
        return response.version
    }
}
