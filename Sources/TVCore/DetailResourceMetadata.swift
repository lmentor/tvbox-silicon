import Foundation

/// Search providers may return unrelated works or a different season. Parent
/// artwork and episode metadata apply only to the selected resource's identity.
public enum DetailResourceMetadata {
    public static func matching(_ details: TMDBMatch.Details?, title: String, year: String?, flag: String) -> TMDBMatch.Details? {
        guard let details else { return nil }
        let source = TMDBTitleMatching.key(title)
        let aliases = Set([details.name, details.originalName].map(TMDBTitleMatching.key).filter { !$0.isEmpty })
        guard !source.isEmpty, aliases.contains(source) else { return nil }
        let expectedYear = details.mediaType == .tv && (details.season?.number ?? 1) > 1
            ? details.season?.year : details.year
        if let sourceYear = TMDBTitleMatching.sourceYear(year, title: title, episodes: []).flatMap(Int.init),
           let expectedYear, sourceYear != expectedYear { return nil }
        if details.mediaType == .tv,
           let sourceSeason = TMDBTitleMatching.season(flag) ?? TMDBTitleMatching.season(title),
           sourceSeason != details.season?.number { return nil }
        return details
    }
}
