import EngineCore
import Foundation
@testable import QueueKit
import Testing

@Suite struct ErrorTextTests {
    @Test(arguments: [
        ("ERROR: [youtube] abc: Video unavailable. This video has been removed by the uploader", "Video kaldırılmış"),
        ("ERROR: [youtube] abc: Private video. Sign in if you've been granted access to this video", "Video gizli"),
        ("ERROR: [youtube] abc: Sign in to confirm your age. This video may be inappropriate for some users.", "Yaş sınırlı"),
        ("ERROR: [youtube] abc: Sign in to confirm you're not a bot. Use --cookies-from-browser or --cookies", "bot denetimi"),
        ("ERROR: [vimeo] 123: This video is only available for logged-in users", "Site giriş istiyor"),
        ("ERROR: unable to download video data: HTTP Error 403: Forbidden", "Erişim reddedildi (403)"),
        ("The response status is not successful. status=403", "Erişim reddedildi (403)"),
        ("Resource not found", "Dosya bulunamadı (404)"),
        ("ERROR: Unsupported URL: https://example.com/", "desteklenmiyor"),
        ("ERROR: [Errno 28] No space left on device", "Diskte yer kalmadı"),
        ("ERROR: Unable to download webpage: <urlopen error timed out>", "Bağlantı sorunu"),
        ("ERROR: [generic] Unable to extract title", "yt-dlp'yi güncelle"),
        ("ERROR: The uploader has not made this video available in your country", "bölge kısıtlaması"),
    ])
    func translates(raw: String, expected: String) {
        let error = EngineError.toolFailed(.ytDlp, status: 1, message: raw)
        #expect(ErrorText.friendly(error).contains(expected))
        #expect(ErrorText.detail(error)?.contains(raw) == true)  // ham hata ayrıntıda kalır
    }

    @Test func unknownAndOwnErrorsStayAsIs() {
        let unknown = EngineError.toolFailed(.ytDlp, status: 1, message: "ERROR: tuhaf bir şey")
        #expect(ErrorText.friendly(unknown) == String(describing: unknown))
        #expect(ErrorText.detail(unknown) == nil)
        #expect(ErrorText.friendly(QueueError.notFound(3)) == "#3 bulunamadı.")
        #expect(ErrorText.friendly(EngineError.loginRequired(browser: "brave", detail: "x")).hasPrefix("brave çerezleriyle de"))
    }
}
