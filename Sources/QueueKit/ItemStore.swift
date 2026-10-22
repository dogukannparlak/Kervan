import Foundation
import GRDB

/// Kuyruğun SQLite kalıcılığı. Yalnız `kervand` yazar; CLI ve app soket üzerinden konuşur.
public final class ItemStore: Sendable {
    private let db: DatabaseQueue

    /// `path` nil ise bellek içi (testler).
    public init(path: URL?) throws {
        if let path {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            var configuration = Configuration()
            configuration.prepareDatabase { try $0.execute(sql: "PRAGMA journal_mode = WAL") }
            db = try DatabaseQueue(path: path.path, configuration: configuration)
        } else {
            db = try DatabaseQueue()
        }
        try Self.migrator.migrate(db)
    }

    public func all() throws -> [DownloadItem] {
        try db.read { try DownloadItem.order(Column("id")).fetchAll($0) }
    }

    public func insert(_ items: [DownloadItem]) throws -> [DownloadItem] {
        try db.write { db in
            try items.map { item in
                var item = item
                try item.insert(db)
                return item
            }
        }
    }

    public func update(_ item: DownloadItem) throws {
        try db.write { try item.update($0) }
    }

    public func delete(ids: [Int64]) throws {
        _ = try db.write { try DownloadItem.deleteAll($0, keys: ids) }
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "item") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("url", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("parentId", .integer).references("item", onDelete: .cascade)
                t.column("playlistIndex", .integer)
                t.column("title", .text)
                t.column("host", .text).notNull()
                t.column("presetId", .text).notNull()
                t.column("cookiesBrowser", .text)
                t.column("destination", .text).notNull()
                t.column("state", .text).notNull()
                t.column("attempt", .integer).notNull()
                t.column("maxAttempts", .integer).notNull()
                t.column("nextAttemptAt", .datetime)
                t.column("lastError", .text)
                t.column("bytesDone", .integer).notNull()
                t.column("bytesTotal", .integer)
                t.column("bytesTotalEstimate", .integer)
                t.column("speed", .double)
                t.column("eta", .integer)
                t.column("message", .text)
                t.column("outputPath", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("finishedAt", .datetime)
            }
        }
        return migrator
    }
}

/// Öğe başına araç log'u: `<dizin>/<id>.log`. İlerleme satırları yazılmaz, yalnız diğer çıktılar.
public final class LogStore: Sendable {
    let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func append(_ id: Int64, _ line: String) {
        let file = directory.appending(path: "\(id).log")
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: file)
        }
    }

    func tail(_ id: Int64, lines: Int) -> [String] {
        guard let text = try? String(contentsOf: directory.appending(path: "\(id).log"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").suffix(lines).map(String.init)
    }

    func remove(_ id: Int64) {
        try? FileManager.default.removeItem(at: directory.appending(path: "\(id).log"))
    }
}
