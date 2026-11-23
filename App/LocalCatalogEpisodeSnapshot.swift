import Foundation
import TVCore

#if os(iOS)
/// A line's display data changes only with source/metadata inputs, not with the
/// artwork, playback progress, selected group or layout of the detail page.
struct LocalCatalogEpisodeSnapshot: Sendable {
    struct Input: Equatable, Sendable {
        let episodes: [Episode]
        let details: TMDBMatch.Details?
        let numbering: TMDBMatch.Numbering
        let offset: Int
        let sourceTitle: String
        let flag: String
        let fileDetails: [Episode.ID: String]
    }
    let input: Input
    let entries: [LocalCatalogDetailEpisode]
    let ordered: [LocalCatalogDetailRules.EpisodeKey]

    /// A nonisolated async boundary keeps filename parsing and TMDB alignment
    /// on the generic executor, including the first uncached detail opening.
    nonisolated static func prepare(_ input: Input) async -> Self? {
        guard !Task.isCancelled else { return nil }
        var metadata: [Episode.ID: TMDBMatch.EpisodeInfo] = [:]
        if let details = input.details, details.season != nil {
            let mapped = details.episodes(for: input.episodes.map(\.name), numbering: input.numbering, offset: input.offset)
            for (episode, info) in zip(input.episodes, mapped) { metadata[episode.id] = info }
        }
        guard !Task.isCancelled else { return nil }
        let entries = LocalCatalogDetailEpisode.entries(input.episodes, metadata: metadata, details: input.details,
                                                        sourceTitle: input.sourceTitle, flag: input.flag, fileDetails: input.fileDetails)
        let ordered = LocalCatalogDetailRules.ordered(entries.map(\.key))
        guard !Task.isCancelled else { return nil }
        return Self(input: input, entries: entries, ordered: ordered)
    }
}
#endif
