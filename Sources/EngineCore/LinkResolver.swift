import Foundation

/// `--cookies` değeri: "auto" → önce çerezsiz, site giriş isterse yedek tarayıcı;
/// "none" → hiç; "fallback" → doğrudan yedek tarayıcı (eklentide kullanıcı onayladıysa);
/// başka bir değer → doğrudan o tarayıcı.
public struct CookiePolicy: Sendable, Equatable, Codable {
    public let explicit: String?
    public let fallback: String?

    public init(explicit: String?, fallback: String?) {
        self.explicit = explicit
        self.fallback = fallback
    }

    public init(_ value: String, environment: [String: String] = ProcessInfo.processInfo.environment) {
        switch value.lowercased() {
        case "auto": self.init(explicit: nil, fallback: environment["KERVAN_COOKIES_BROWSER"] ?? "brave")
        case "none": self.init(explicit: nil, fallback: nil)
        case "fallback": self.init(explicit: environment["KERVAN_COOKIES_BROWSER"] ?? "brave", fallback: nil)
        default: self.init(explicit: value.lowercased(), fallback: nil)
        }
    }
}

public struct ResolvedLink: Sendable, Equatable {
    public let kind: DownloadKind
    /// İndirmede de kullanılacak tarayıcı (çerez gerekmediyse nil).
    public let cookiesBrowser: String?
    /// Kullanıcıya gösterilecek kısa notlar (ör. "çerez kullanıldı").
    public let notes: [String]

    public init(kind: DownloadKind, cookiesBrowser: String?, notes: [String]) {
        self.kind = kind
        self.cookiesBrowser = cookiesBrowser
        self.notes = notes
    }
}

public protocol LinkResolving: Sendable {
    func resolve(_ url: URL, cookies: CookiePolicy, context: RequestContext) async throws -> ResolvedLink
    func qualities(_ url: URL, cookies: CookiePolicy, context: RequestContext) async throws -> QualityList
}

extension LinkResolving {
    public func resolve(_ url: URL, cookies: CookiePolicy) async throws -> ResolvedLink {
        try await resolve(url, cookies: cookies, context: RequestContext())
    }

    public func qualities(_ url: URL, cookies: CookiePolicy, context: RequestContext) async throws -> QualityList {
        QualityList(title: nil, options: [])
    }
}

/// `URLClassifier` + çerez yedeği: site giriş isterse yedek tarayıcının çereziyle bir kez daha dener.
public struct LinkResolver: LinkResolving {
    let head: any HeadFetching
    let probe: @Sendable (URL, String?, RequestContext) async throws -> ProbeResult
    let formats: (@Sendable (URL, String?, RequestContext) async throws -> QualityList)?

    public init(ytDlp: YtDlpAdapter, head: any HeadFetching = URLSessionHeadFetcher()) {
        self.init(head: head, probe: { try await ytDlp.probe($0, cookiesFromBrowser: $1, context: $2) },
                  formats: { try await ytDlp.qualities($0, cookiesFromBrowser: $1, context: $2) })
    }

    init(head: any HeadFetching, probe: @escaping @Sendable (URL, String?, RequestContext) async throws -> ProbeResult,
         formats: (@Sendable (URL, String?, RequestContext) async throws -> QualityList)? = nil) {
        self.head = head
        self.probe = probe
        self.formats = formats
    }

    /// Kalite listesi; site giriş isterse `resolve` gibi yedek tarayıcının çereziyle bir kez daha dener.
    public func qualities(_ url: URL, cookies: CookiePolicy, context: RequestContext) async throws -> QualityList {
        guard let formats else { return QualityList(title: nil, options: []) }
        do {
            return try await formats(url, cookies.explicit, context)
        } catch let error where cookies.explicit == nil && cookies.fallback != nil && YtDlpAdapter.isLoginError(error) {
            return try await formats(url, cookies.fallback, context)
        }
    }

    public func resolve(_ url: URL, cookies: CookiePolicy, context: RequestContext) async throws -> ResolvedLink {
        let state = ResolveState(browser: cookies.explicit)
        let probe = probe
        let classifier = URLClassifier(head: head, headers: context.httpHeaders, probe: { url in
            do {
                return try await probe(url, state.browser, context)
            } catch let error where state.browser == nil && YtDlpAdapter.isLoginError(error) {
                guard let fallback = cookies.fallback else { throw error }
                state.use(fallback, note: "site giriş istedi; \(fallback) çerezleri kullanıldı")
                do {
                    return try await probe(url, fallback, context)
                } catch let error where YtDlpAdapter.isLoginError(error) {
                    throw EngineError.loginRequired(browser: fallback, detail: String(describing: error))
                }
            }
        })
        let kind = try await classifier.classify(url)
        return ResolvedLink(kind: kind, cookiesBrowser: kind == .http ? nil : state.browser, notes: state.notes)
    }
}

private final class ResolveState: @unchecked Sendable {
    private let lock = NSLock()
    private var _browser: String?
    private var _notes: [String] = []

    init(browser: String?) { _browser = browser }

    var browser: String? { lock.withLock { _browser } }
    var notes: [String] { lock.withLock { _notes } }

    func use(_ browser: String, note: String) {
        lock.withLock {
            _browser = browser
            _notes.append(note)
        }
    }
}
