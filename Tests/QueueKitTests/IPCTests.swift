import EngineCore
import Foundation
@testable import KervanIPC
import QueueKit
import Testing

@Suite struct IPCTests {
    @Test func requestResponseOverSocketPair() async throws {
        let engine = try makeEngine(FakeExecutor())
        await engine.start()
        let (serverEnd, clientEnd) = try LineConnection.pair()
        let server = IPCServer(engine: engine)
        Thread.detachNewThread { server.serve(serverEnd) }
        let client = IPCClient(connection: clientEnd)

        let ping = try client.request(Request(cmd: .ping))
        #expect(ping.ok && ping.version == kervanVersion)

        let added = try client.request(Request(cmd: .add, url: "https://a.com/ok", dir: "/tmp/kervan-test", cookies: "none"))
        let id = try #require(added.items?.first?.id)
        #expect(await eventually { await engine.item(id)?.state == .done })

        let list = try client.request(Request(cmd: .list))
        #expect(list.items?.first?.state == .done)
        #expect(list.items?.first?.outputPath == "/tmp/ok.mp4")

        let bad = try client.request(Request(cmd: .pause, ids: [999]))
        #expect(!bad.ok && bad.error == "#999 bulunamadı.")

        let badURL = try client.request(Request(cmd: .add, url: "ftp://x"))
        #expect(!badURL.ok)
    }

    @Test func socketPathLengthIsChecked() {
        #expect(throws: SocketError.self) { _ = try UnixSocket.address(String(repeating: "a", count: 200)) }
    }
}
