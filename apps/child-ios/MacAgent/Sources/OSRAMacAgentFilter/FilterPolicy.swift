import Foundation

/// The Mac's web-filter decision table: given a URL and the family's rules, what the content filter does.
///
/// Roadmap 5.9, build step (iii), ADR-0036. The semantics are ADR-0015's, which the Android DNS sinkhole
/// already implements in `DnsFilterPolicy`; this is the same table with the same precedence so a family
/// gets the same answer on a Mac as on a phone. Nothing here imports NetworkExtension: the provider moves
/// bytes, this decides, and the whole table is unit-tested without a signed process.
///
/// Precedence, highest first (ADR-0015 decision 1):
///  1. pause-internet — every request is blocked;
///  2. an explicit allowed domain, or a subdomain of one — allowed, whatever else says;
///  3. an explicit blocked domain, or a domain in a blocked category — blocked. A parent's block beats
///     SafeSearch: redirecting a blocked search host would leave the site reachable (#825 on the Flip4);
///  4. SafeSearch — a **redirect** to the same request with the engine's safety parameter set. A content
///     filter cannot rewrite a resolver answer the way the DNS sinkhole does, so this is a URL redirect and
///     the PR says so rather than implying the phone's mechanism;
///  5. otherwise allowed.
///
/// Matching is by DNS label suffix: `blocked.example` covers `www.blocked.example` but not
/// `notblocked.example`. Names are compared lower-case with the trailing dot removed.
public struct FilterPolicy: Codable, Equatable {
    public enum Decision: Equatable {
        case allow
        case block(reason: String)
        case redirect(URL)
    }

    public var pausedInternet: Bool
    public var safeSearchEnforced: Bool
    /// Normalised, non-empty and sorted, so two policies built from the same rules compare equal.
    public var allowedDomains: [String]
    public var blockedDomains: [String]
    /// Domain → category name, already narrowed to the categories this family blocks. Empty until a
    /// blocklist pack ships for the Mac; the table takes it as an input rather than inventing one.
    public var categoryDomains: [String: String]

    public init(pausedInternet: Bool = false,
                safeSearchEnforced: Bool = false,
                allowedDomains: [String] = [],
                blockedDomains: [String] = [],
                categoryDomains: [String: String] = [:]) {
        self.pausedInternet = pausedInternet
        self.safeSearchEnforced = safeSearchEnforced
        self.allowedDomains = Self.clean(allowedDomains)
        self.blockedDomains = Self.clean(blockedDomains)
        var categories: [String: String] = [:]
        for (domain, category) in categoryDomains {
            let name = Self.normalize(domain)
            let label = category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !name.isEmpty, !label.isEmpty { categories[name] = label }
        }
        self.categoryDomains = categories
    }

    // MARK: - Decision

    /// The host-only verdict, which is all pause, allow, block and category need.
    public func decide(host rawHost: String) -> Decision {
        switch verdict(forHost: rawHost) {
        case .blocked(let reason): return .block(reason: reason)
        case .allowedExplicitly, .unblocked: return .allow
        }
    }

    /// The full verdict, including the SafeSearch redirect.
    public func decide(url: URL) -> Decision {
        guard let host = url.host else { return .allow }
        switch verdict(forHost: host) {
        // A block or a pause outranks any redirect; an explicit allow outranks SafeSearch.
        case .blocked(let reason): return .block(reason: reason)
        case .allowedExplicitly: return .allow
        case .unblocked: break
        }
        guard safeSearchEnforced else { return .allow }
        guard let redirected = Self.safeSearchRedirect(url) else { return .allow }
        return .redirect(redirected)
    }

    enum Verdict: Equatable {
        case blocked(String)
        case allowedExplicitly
        case unblocked
    }

    func verdict(forHost rawHost: String) -> Verdict {
        let host = Self.normalize(rawHost)
        guard !host.isEmpty else { return .unblocked }
        if pausedInternet { return .blocked("paused_internet") }
        if Self.firstMatch(host, in: allowedDomains) != nil { return .allowedExplicitly }
        if let rule = Self.firstMatch(host, in: blockedDomains) { return .blocked("blocked_domain:\(rule)") }
        if let (rule, category) = Self.firstCategory(host, in: categoryDomains) {
            return .blocked("category:\(category):\(rule)")
        }
        return .unblocked
    }

    // MARK: - Matching

    /// Lower-case, no trailing dot, no surrounding whitespace. An IPv6 literal keeps its brackets.
    static func normalize(_ value: String) -> String {
        var name = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while name.hasSuffix(".") { name.removeLast() }
        return name
    }

    static func clean(_ domains: [String]) -> [String] {
        Array(Set(domains.map(normalize).filter { !$0.isEmpty })).sorted()
    }

    /// DNS label suffix: the name itself, or any subdomain of it.
    static func matches(_ host: String, _ rule: String) -> Bool {
        host == rule || host.hasSuffix("." + rule)
    }

    static func firstMatch(_ host: String, in rules: [String]) -> String? {
        rules.first { matches(host, $0) }
    }

    /// Deterministic: the alphabetically first matching rule, so a log line does not depend on dictionary order.
    static func firstCategory(_ host: String, in map: [String: String]) -> (String, String)? {
        for rule in map.keys.sorted() where matches(host, rule) {
            if let category = map[rule] { return (rule, category) }
        }
        return nil
    }

    // MARK: - SafeSearch

    /// The engines' own safety parameters. The hosts are Google's, Microsoft's and DuckDuckGo's public
    /// search endpoints, the same set the DNS sinkhole's tables carry.
    static let googleSafeHost = "forcesafesearch.google.com"
    static let bingSafeHost = "strict.bing.com"
    static let duckDuckGoSafeHost = "safe.duckduckgo.com"
    static let youTubeStrictHost = "restrict.youtube.com"
    static let youTubeModerateHost = "restrictmoderate.youtube.com"

    static let enforcementHosts: Set<String> = [
        googleSafeHost, bingSafeHost, duckDuckGoSafeHost, youTubeStrictHost, youTubeModerateHost,
    ]
    static let bingHosts: Set<String> = ["bing.com", "www.bing.com"]
    static let duckDuckGoHosts: Set<String> = ["duckduckgo.com", "www.duckduckgo.com", "start.duckduckgo.com"]

    /// `google.<tld>` or `www.google.<tld>`, where the tld is one or two 2–3 letter labels ("com", "ae",
    /// "co.uk"), so `mail.google.com` is not a search host. The same predicate as `DnsFilterPolicy`'s.
    static func isGoogleSearchHost(_ host: String) -> Bool {
        var name = host
        if name.hasPrefix("www.") { name.removeFirst(4) }
        guard name.hasPrefix("google.") else { return false }
        let tail = name.dropFirst("google.".count)
        let labels = tail.split(separator: ".")
        guard labels.count == 1 || labels.count == 2 else { return false }
        return labels.allSatisfy { label in
            (2...3).contains(label.count) && label.allSatisfy { $0.isASCII && $0.isLowercase && $0.isLetter }
        }
    }

    /// A redirect that sets the engine's safety parameter, or nil when the request is already safe, is not a
    /// search request, or is one of the enforcement hosts themselves (which must never be redirected or the
    /// rewrite loops).
    static func safeSearchRedirect(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rawHost = components.host else { return nil }
        let host = normalize(rawHost)
        guard !enforcementHosts.contains(host) else { return nil }
        let path = components.path

        if isGoogleSearchHost(host) {
            guard path.isEmpty || path == "/" || path == "/search" else { return nil }
            if queryValue("safe", components) == "active" { return nil }
            guard setQuery("safe", "active", &components) else { return nil }
            return components.url
        }
        if bingHosts.contains(host) {
            guard path.hasPrefix("/search") else { return nil }
            if queryValue("adlt", components) == "strict" { return nil }
            guard setQuery("adlt", "strict", &components) else { return nil }
            return components.url
        }
        if duckDuckGoHosts.contains(host) {
            guard path.isEmpty || path == "/" || path.hasPrefix("/html") else { return nil }
            if queryValue("kp", components) == "1" { return nil }
            guard setQuery("kp", "1", &components) else { return nil }
            return components.url
        }
        return nil
    }

    static func queryValue(_ name: String, _ components: URLComponents) -> String? {
        components.queryItems?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Replaces every occurrence of `name`, so a request carrying `safe=off` cannot win by repeating it.
    static func setQuery(_ name: String, _ value: String, _ components: inout URLComponents) -> Bool {
        var items = components.queryItems ?? []
        items.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        items.append(URLQueryItem(name: name, value: value))
        components.queryItems = items
        return components.url != nil
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case pausedInternet, safeSearchEnforced, allowedDomains, blockedDomains, categoryDomains
    }

    /// Decoded through the memberwise initialiser, so a snapshot written by an older daemon is normalised the
    /// same way a fresh one is: a hand-edited file cannot smuggle in a mixed-case or dotted rule.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(pausedInternet: try container.decodeIfPresent(Bool.self, forKey: .pausedInternet) ?? false,
                  safeSearchEnforced: try container.decodeIfPresent(Bool.self, forKey: .safeSearchEnforced) ?? false,
                  allowedDomains: try container.decodeIfPresent([String].self, forKey: .allowedDomains) ?? [],
                  blockedDomains: try container.decodeIfPresent([String].self, forKey: .blockedDomains) ?? [],
                  categoryDomains: try container.decodeIfPresent([String: String].self, forKey: .categoryDomains) ?? [:])
    }
}
