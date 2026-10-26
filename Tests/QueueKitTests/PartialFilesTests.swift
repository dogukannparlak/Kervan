import Foundation
@testable import QueueKit
import Testing

@Suite struct PartialFilesTests {
    @Test func findsOnlyPartialsOfThatDownload() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "kervan-p-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let partial = ["Joker [x1].f137.mp4.part", "Joker [x1].f140.m4a", "Joker [x1].mp4.ytdl", "Joker [x1].f137.mp4.part-Frag3",
                       "Joker [x1].temp.mp4", "Joker [x1].tr.vtt", "Dosya.zip", "Dosya.zip.aria2"]
        let kept = ["Joker [x1].mkv", "Joker [x2].f137.mp4.part", "Başka.mp4", "Bitti.zip"]
        for name in partial + kept { try Data().write(to: directory.appending(path: name)) }

        let video = PartialFiles.remove(for: directory.appending(path: "Joker [x1].mp4").path)
        #expect(Set(video.map(\.lastPathComponent)) == Set(partial.prefix(6)))
        #expect(Set(PartialFiles.find(for: directory.appending(path: "Dosya.zip").path).map(\.lastPathComponent))
                == ["Dosya.zip", "Dosya.zip.aria2"])
        #expect(PartialFiles.find(for: directory.appending(path: "Bitti.zip").path).isEmpty)  // kontrol dosyası yok: bitmiş
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(Set(left) == Set(kept + ["Dosya.zip", "Dosya.zip.aria2"]))
    }
}
