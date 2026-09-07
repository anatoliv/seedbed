import Foundation

/// Where "Support" points, and who has asked to be named.
///
/// Seedbed is free and MIT-licensed and stays that way: nothing here unlocks a
/// feature, because there is no feature to unlock. These are the links for
/// people who want to give something back anyway.
///
/// **A nil handle hides its button.** That is the whole configuration story —
/// there is no settings screen for this and no build flag. Keep the handles in
/// step with `.github/FUNDING.yml`, which is the same list in the form GitHub
/// reads for the Sponsor button on the repository.
enum SupportLinks {
    static let gitHubSponsorsHandle: String? = "anatoliv"
    static let koFiHandle: String? = "anatolivishnyakov"
    static let payPalHandle: String? = "anatolivishnyakov"

    /// Feature requests are ranked by reactions on the issue tracker rather
    /// than by a form nobody reads twice.
    static let roadmapURL = URL(string:
        "https://github.com/anatoliv/seedbed/issues?q=is%3Aissue+is%3Aopen+label%3Aroadmap+sort%3Areactions-%2B1-desc")

    static var gitHubSponsors: URL? {
        gitHubSponsorsHandle.flatMap { URL(string: "https://github.com/sponsors/\($0)") }
    }

    static var koFi: URL? {
        koFiHandle.flatMap { URL(string: "https://ko-fi.com/\($0)") }
    }

    static var payPal: URL? {
        payPalHandle.flatMap { URL(string: "https://paypal.me/\($0)") }
    }

    /// Every link that is configured, in the order the About page shows them.
    static var all: [(label: String, url: URL)] {
        var out: [(String, URL)] = []
        if let url = gitHubSponsors { out.append(("Sponsor", url)) }
        if let url = koFi { out.append(("Ko-fi", url)) }
        if let url = payPal { out.append(("PayPal", url)) }
        return out
    }
}

/// People who asked to be named, fetched from the site rather than compiled in.
///
/// **Why not a constant in this file.** Adding a supporter would otherwise mean
/// a release: a build, two notarizations and an update everyone installs, to
/// add one line of text. The list lives beside the site instead, so thanking
/// someone is a file edit and a deploy.
///
/// It fails quietly and completely. No network, a malformed file, an empty
/// list: the section does not appear, and nothing is said about it. A thank-you
/// that turns into an error message is worse than no thank-you.
@MainActor
final class Supporters: ObservableObject {
    struct Person: Codable, Identifiable, Hashable {
        let name: String
        let url: String?
        var id: String { name }
    }

    private struct Payload: Decodable {
        let version: Int?
        let supporters: [Person]
    }

    @Published private(set) var people: [Person] = []

    private static let feed = URL(string: "https://seedbed.dev/supporters.json")
    private static let cacheKey = "SupportersCache"

    /// The last good copy, so an offline launch still shows what it showed
    /// yesterday rather than dropping people who are still supporters.
    private static var cached: [Person] {
        get {
            guard let data = UserDefaults.standard.data(forKey: cacheKey),
                  let people = try? JSONDecoder().decode([Person].self, from: data)
            else { return [] }
            return people
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }

    init() { people = Self.cached }

    /// Refresh in the background. Called when the About page appears, which is
    /// the only place the list is shown, so nothing fetches unless someone looks.
    func refresh() {
        guard let feed = Self.feed else { return }
        Task { [weak self] in
            var request = URLRequest(url: feed)
            request.timeoutInterval = 10
            request.cachePolicy = .reloadRevalidatingCacheData
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let payload = try? JSONDecoder().decode(Payload.self, from: data)
            else { return }
            await MainActor.run {
                Self.cached = payload.supporters
                self?.people = payload.supporters
            }
        }
    }
}

extension Supporters.Person {
    var link: URL? { url.flatMap(URL.init(string:)) }
}
