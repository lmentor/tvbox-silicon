import Foundation

/// A saved episode keeps its successful matching identity separately from titles
/// displayed by a provider or edited by a push. No signed media URL is retained.
public struct PlaybackDanmakuSelection: Codable, Hashable, Sendable {
    public var title: String
    public var episodeName: String
    public var year: String?
    public var cacheID: String?
    public var manual: Bool
    public var builtin: Bool
    public var sourceID: String?
    public var sourceAddress: String?
    public var publicCatalog: Bool?
    public var catalogEpisodeID: String?
    public var catalogEpisodeTitle: String?
    public var catalogEpisodeURL: String?
    public var animeID: String?
    public var bilibiliCID: String?

    public init(title: String, episodeName: String, year: String? = nil, cacheID: String? = nil,
                manual: Bool, builtin: Bool) {
        self.title = title; self.episodeName = episodeName; self.year = year
        self.cacheID = cacheID; self.manual = manual; self.builtin = builtin
    }

    public func matchingContext(_ context: PlaybackHistoryContext) -> PlaybackHistoryContext {
        var result = PlaybackHistoryContext(origin: context.origin, sourceKey: context.sourceKey,
            sourceName: context.sourceName, videoID: context.videoID, videoName: title,
            poster: context.poster, episodeID: context.episodeID, episodeName: episodeName, episodeFlag: context.episodeFlag)
        result.year = year ?? context.year
        result.historyScope = context.historyScope
        result.officialPage = context.officialPage
        return result
    }
}
