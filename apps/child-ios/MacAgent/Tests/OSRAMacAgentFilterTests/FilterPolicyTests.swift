import XCTest
@testable import OSRAMacAgentFilter

/// Each test names the fault it catches. The precedence is ADR-0015's, and the reference implementation is
/// Android's `DnsFilterPolicy`; a difference between them is the bug worth failing on.
final class FilterPolicyTests: XCTestCase {

    private func policy(blocked: [String] = [],
                        allowed: [String] = [],
                        categories: [String: String] = [:],
                        paused: Bool = false,
                        safeSearch: Bool = false) -> FilterPolicy {
        FilterPolicy(pausedInternet: paused,
                     safeSearchEnforced: safeSearch,
                     allowedDomains: allowed,
                     blockedDomains: blocked,
                     categoryDomains: categories)
    }

    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else { fatalError("bad fixture: \(string)") }
        return url
    }

    private func redirect(_ decision: FilterPolicy.Decision, _ file: StaticString = #filePath, _ line: UInt = #line) -> URL? {
        guard case .redirect(let url) = decision else {
            XCTFail("expected a redirect, got \(decision)", file: file, line: line)
            return nil
        }
        return url
    }

    private func reason(_ decision: FilterPolicy.Decision, _ file: StaticString = #filePath, _ line: UInt = #line) -> String? {
        guard case .block(let reason) = decision else {
            XCTFail("expected a block, got \(decision)", file: file, line: line)
            return nil
        }
        return reason
    }

    // MARK: - Matching

    // Mutant: a plain `contains`/`hasPrefix` match, which would block "notblocked.example" for a rule on
    // "blocked.example" — a family's block list would quietly swallow unrelated sites.
    func testOnlyTheRuleAndItsSubdomainsAreBlocked() {
        let p = policy(blocked: ["blocked.example"])
        XCTAssertEqual(p.decide(host: "blocked.example"), .block(reason: "blocked_domain:blocked.example"))
        XCTAssertEqual(p.decide(host: "www.blocked.example"), .block(reason: "blocked_domain:blocked.example"))
        XCTAssertEqual(p.decide(host: "a.b.blocked.example"), .block(reason: "blocked_domain:blocked.example"))
        XCTAssertEqual(p.decide(host: "notblocked.example"), .allow)
        XCTAssertEqual(p.decide(host: "blocked.example.org"), .allow)
    }

    // Mutant: comparing names as written, so a rule saved as "Blocked.Example." stops matching the host the
    // browser actually asks for.
    func testNamesAreComparedLowerCasedWithoutTheTrailingDot() {
        let p = policy(blocked: ["Blocked.Example."])
        XCTAssertEqual(p.decide(host: "WWW.BLOCKED.EXAMPLE"), .block(reason: "blocked_domain:blocked.example"))
        XCTAssertEqual(p.decide(host: ""), .allow)
    }

    // MARK: - Precedence

    // Mutant: checking the allow list after pause, which would let the parent's allow list punch through a
    // pause and leave one site reachable while the parent believes the internet is off.
    func testPauseBeatsAnExplicitAllow() {
        let p = policy(blocked: [], allowed: ["school.example"], paused: true)
        XCTAssertEqual(p.decide(host: "school.example"), .block(reason: "paused_internet"))
        XCTAssertEqual(p.decide(host: "anything.example"), .block(reason: "paused_internet"))
    }

    // Mutant: blocked rules winning over allowed ones, which makes the parent's "allow this site" button do
    // nothing whenever a category or a list also names it.
    func testAnExplicitAllowBeatsAnExplicitBlock() {
        let p = policy(blocked: ["example.com"], allowed: ["news.example.com"])
        XCTAssertEqual(p.decide(host: "news.example.com"), .allow)
        XCTAssertEqual(p.decide(host: "www.example.com"), .block(reason: "blocked_domain:example.com"))
    }

    // Mutant: allowing a category hit through when the domain is also in the allow list of a different family
    // — the category check must come after both explicit lists, and an allow still wins.
    func testAnExplicitAllowBeatsACategory() {
        let p = policy(allowed: ["games.example"], categories: ["games.example": "games"])
        XCTAssertEqual(p.decide(host: "games.example"), .allow)
    }

    // Mutant: consulting SafeSearch before the block list, which would redirect a blocked search host to the
    // safety host and leave the site reachable (#825 on the Flip4).
    func testABlockBeatsASafeSearchRedirect() {
        let p = policy(blocked: ["google.com"], safeSearch: true)
        XCTAssertEqual(p.decide(url: url("https://www.google.com/search?q=cats")),
                       .block(reason: "blocked_domain:google.com"))
    }

    func testACategoryBlocks() {
        let p = policy(categories: ["games.example": "games"])
        XCTAssertEqual(p.decide(host: "play.games.example"), .block(reason: "category:games:games.example"))
        XCTAssertEqual(p.decide(host: "example.org"), .allow)
    }

    // MARK: - SafeSearch

    // Mutant: treating SafeSearch as a block, or leaving the engine's own host redirected forever.
    func testSafeSearchRedirectsAGoogleSearchAndLeavesASafeOneAlone() {
        let p = policy(safeSearch: true)
        let redirected = redirect(p.decide(url: url("https://www.google.com/search?q=cats")))
        let components = redirected.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        XCTAssertEqual(components?.queryItems?.first { $0.name == "safe" }?.value, "active")
        XCTAssertEqual(components?.queryItems?.first { $0.name == "q" }?.value, "cats")

        XCTAssertEqual(p.decide(url: url("https://www.google.com/search?q=cats&safe=active")), .allow)
    }

    // Mutant: rewriting every google.<tld> URL, which would send Google Maps and Gmail to a search page.
    func testSafeSearchLeavesNonSearchGooglePathsAlone() {
        let p = policy(safeSearch: true)
        XCTAssertEqual(p.decide(url: url("https://maps.google.com/maps?q=cairo")), .allow)
        XCTAssertEqual(p.decide(url: url("https://mail.google.com/mail/u/0")), .allow)
        XCTAssertNotNil(redirect(p.decide(url: url("https://google.co.uk/search?q=cats"))))
    }

    // Mutant: appending the parameter instead of replacing it, so `safe=off&safe=active` lets the first one win.
    func testSafeSearchReplacesAConflictingParameter() {
        let p = policy(safeSearch: true)
        let redirected = redirect(p.decide(url: url("https://www.google.com/search?q=cats&safe=off")))
        let items = redirected.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? []
        XCTAssertEqual(items.filter { $0.name == "safe" }.map(\.value), ["active"])
    }

    func testSafeSearchCoversBingAndDuckDuckGo() {
        let p = policy(safeSearch: true)
        let bing = redirect(p.decide(url: url("https://www.bing.com/search?q=cats")))
        XCTAssertEqual(bing.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == "adlt" }?.value, "strict")
        let ddg = redirect(p.decide(url: url("https://duckduckgo.com/?q=cats")))
        XCTAssertEqual(ddg.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == "kp" }?.value, "1")
    }

    // Mutant: redirecting the enforcement hosts, which loops: the engine's own safety host would be sent to
    // itself on every request.
    func testTheEnforcementHostsAreNeverRedirected() {
        let p = policy(safeSearch: true)
        XCTAssertEqual(p.decide(url: url("https://forcesafesearch.google.com/search?q=cats")), .allow)
        XCTAssertEqual(p.decide(url: url("https://strict.bing.com/search?q=cats")), .allow)
        XCTAssertEqual(p.decide(host: "safe.duckduckgo.com"), .allow)
        // The exemption is for redirects only: a parent's block on the parent domain still reaches the
        // enforcement host, which is Android's documented behaviour (#825) and must not diverge here.
        let blocked = policy(blocked: ["google.com"], safeSearch: true)
        XCTAssertEqual(blocked.decide(host: "forcesafesearch.google.com"), .block(reason: "blocked_domain:google.com"))
    }

    func testSafeSearchOffLeavesTheUrlAlone() {
        let p = policy(safeSearch: false)
        XCTAssertEqual(p.decide(url: url("https://www.google.com/search?q=cats")), .allow)
    }

    // MARK: - Shape

    // Mutant: a snapshot written with rules in the order the server sent them, so two policies built from the
    // same rules compare unequal and every sync looks like a change.
    func testPolicyNormalisesAndSortsItsRules() {
        let p = FilterPolicy(allowedDomains: ["B.example", "b.example", " "],
                             blockedDomains: ["Z.example.", "a.example"],
                             categoryDomains: ["Games.Example.": " Games "])
        XCTAssertEqual(p.allowedDomains, ["b.example"])
        XCTAssertEqual(p.blockedDomains, ["a.example", "z.example"])
        XCTAssertEqual(p.categoryDomains, ["games.example": "games"])
    }

    // Mutant: decoding a snapshot by trusting its file, so a hand-edited or older file can carry a
    // mixed-case rule the matcher then never matches.
    func testDecodingNormalisesTheRulesToo() throws {
        let json = """
        {"pausedInternet":false,"safeSearchEnforced":true,"allowedDomains":["School.Example."],
         "blockedDomains":["Blocked.Example"],"categoryDomains":{"Games.Example":"Games"}}
        """
        let p = try JSONDecoder().decode(FilterPolicy.self, from: Data(json.utf8))
        XCTAssertEqual(p.allowedDomains, ["school.example"])
        XCTAssertEqual(p.blockedDomains, ["blocked.example"])
        XCTAssertEqual(p.categoryDomains, ["games.example": "games"])
        XCTAssertTrue(p.safeSearchEnforced)
    }

    // Mutant: sorting the category map inside `decide`, which allocates and sorts on every flow in the data
    // path. The order is prepared once per policy; this pins that a decision still sees the first rule.
    func testACategoryDecisionUsesThePreparedOrder() {
        let p = policy(categories: ["b.example": "games", "a.example": "games", "c.example": "social"])
        XCTAssertEqual(p.sortedCategoryDomains, ["a.example", "b.example", "c.example"])
        // A host that matches two rules must report the alphabetically first, whatever the dictionary order was.
        XCTAssertEqual(p.decide(host: "b.example"), .block(reason: "category:games:b.example"))
        XCTAssertEqual(p.decide(host: "c.example"), .block(reason: "category:social:c.example"))
    }

    // Mutant: comparing the rule as typed against the host as asked. The server stores whatever the parent
    // typed (`blockedDomains` is validated for length only), and a browser asks for the punycode form, so an
    // Arabic-script rule would silently block nothing — in the first market this product is sold in.
    func testAnArabicRuleAndThePunycodeHostAreTheSameName() {
        let unicodeRule = policy(blocked: ["مثال.شبكة"])
        let punycodeHost = "xn--mgbh0fb.xn--ngbc5azd"
        XCTAssertEqual(unicodeRule.decide(host: punycodeHost), .block(reason: "blocked_domain:xn--mgbh0fb.xn--ngbc5azd"))

        // And the other way round: a rule stored in punycode must match a host written in Arabic script.
        let asciiRule = policy(blocked: [punycodeHost])
        XCTAssertEqual(asciiRule.decide(host: "مثال.شبكة"), .block(reason: "blocked_domain:xn--mgbh0fb.xn--ngbc5azd"))
    }

    // A request with no host at all (a data: or file: URL) is not something a content filter blocks.
    func testAHostlessUrlIsAllowed() {
        let p = policy(blocked: ["example"], safeSearch: true)
        XCTAssertEqual(p.decide(url: url("file:///Users/child/notes.txt")), .allow)
    }
}
