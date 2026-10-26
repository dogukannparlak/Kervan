import Darwin
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

        // Negatif satır sayısı servisi çökertmemeli.
        let log = try client.request(Request(cmd: .log, ids: [id], lines: -5))
        #expect(log.ok && log.log == [])

        let bad = try client.request(Request(cmd: .pause, ids: [999]))
        #expect(!bad.ok && bad.error == "#999 bulunamadı.")

        // Eklentiden gelen istek yerel ağa ulaşamaz; aynı link CLI/uygulamadan eklenebilir.
        var fromPage = Request(cmd: .add, url: "http://192.168.1.10/ok", dir: "/tmp/kervan-test", cookies: "none")
        fromPage.fromExtension = true
        let blocked = try client.request(fromPage)
        #expect(!blocked.ok && blocked.error?.contains("Yerel ağ") == true)
        fromPage.fromExtension = nil
        #expect(try client.request(fromPage).ok)

        let badURL = try client.request(Request(cmd: .add, url: "ftp://x"))
        #expect(!badURL.ok)

        // FakeExecutor'ün dosyası diskte yok: reveal açık hata vermeli, Finder açılmamalı.
        let reveal = try client.request(Request(cmd: .reveal, ids: [id]))
        #expect(!reveal.ok && reveal.error?.contains("dosya yok") == true)
    }

    @Test func endlessLineClosesConnection() throws {
        let (reader, writer) = try LineConnection.pair()
        Thread.detachNewThread {
            let chunk = [UInt8](repeating: 0x41, count: 1024 * 1024)
            for _ in 0..<(LineConnection.maxLineBytes / chunk.count + 2) {
                guard chunk.withUnsafeBytes({ Darwin.write(writer.fd, $0.baseAddress!, $0.count) }) > 0 else { return }
            }
            writer.close()
        }
        #expect(reader.readLine() == nil)
        reader.close()
    }

    @Test func socketPathLengthIsChecked() {
        #expect(throws: SocketError.self) { _ = try UnixSocket.address(String(repeating: "a", count: 200)) }
    }
}
