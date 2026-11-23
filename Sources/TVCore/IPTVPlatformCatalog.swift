import Foundation

public struct IPTVPlatformRoom: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let caption: String
    public let cover: URL?
    public let offline: Bool
    public let folder: Bool
    public let folderFilters: [String: String]
    public var listsChannels = false
    var groupID: String?
    var channelName: String?

    public func channel(sourceID: String, platform: IPTVPlatform) -> Channel {
        let address = IPTVRoomAddress(sourceID: sourceID, platformID: platform.id, roomID: groupID ?? id, channelName: channelName)
        return Channel(name: title, group: platform.name, url: address.url, logo: cover, playback: PlaybackDescriptor(isLive: true))
    }
}

extension IPTVPlatform {
    public typealias ResolvedRoom = (channel: Channel, qualities: [StreamQuality], current: Int?)

    @MainActor static func registered(_ address: IPTVRoomAddress) -> Self? {
        IPTVLibrary.shared.records.first { $0.enabled && $0.id == address.sourceID }?.platforms.first { $0.id == address.platformID }
    }

    @MainActor public static func bilibiliChatRoom(_ url: URL) -> Int? {
        guard let room = IPTVRoomAddress(url), registered(room)?.chat == "bilibili" else { return nil }
        return Int(room.roomID)
    }

    func client(_ sourceID: String) -> CatalogClient {
        var client = CatalogClient(site: scopedSite(sourceID: sourceID), origin: origin)
        if site.native, let endpoint = URL(string: site.api) {
            client.iptvHTTP = IPTVPlatformHTTP(endpoint: endpoint, headers: PlaybackNormalization.headers(site.raw["header"]), usesCatPawRoutes: remoteCatRoute)
        }
        return client
    }

    private func call(sourceID: String, params: [String: String]) async throws -> [String: JSONValue] {
        let scoped = scopedSite(sourceID: sourceID)
        return try await ScriptRuntime.shared.request(site: scoped, scriptURL: try scoped.scriptURL(origin: origin), params: params,
                                                      http: HTTPClient(), origin: origin)
    }

    public var searchable: Bool {
        if let account, searchNeedsAccount, !SourceAccounts.signedIn(account) { return false }
        return adapter == .rooms || site.searchable
    }

    public func areas(sourceID: String) async throws -> [LiveArea] {
        let areas: [LiveArea]
        switch adapter {
        case .rooms:
            let reply = try await call(sourceID: sourceID, params: [:])
            guard let entries = reply["areas"]?.array else {
                throw TVError.unsupported(CatalogClient.providerError(reply) ?? "该平台未提供直播分类接口。")
            }
            areas = entries.compactMap { entry in
                guard let id = entry.object?["id"]?.string, let name = entry.object?["name"]?.string else { return nil }
                return LiveArea(id: id, name: name)
            }
        case .catalog:
            let home = try await client(sourceID).home()
            let recommended = home.videos.isEmpty ? [] : [LiveArea.recommended]
            areas = recommended + home.categories.map { LiveArea(id: $0.id, name: $0.name) }
        }
        var seen: Set<String> = []
        return (areas.isEmpty ? [.recommended] : areas).filter { seen.insert($0.id).inserted }
    }

    private var catChannelDirectory: Bool {
        let route = site.raw["catPawOpen"]?.string ?? site.api
        return (URLComponents(string: route)?.path ?? route).split(separator: "/").contains("live")
            && (site.isCatPawOpen || remoteCatRoute)
    }

    public func channels(sourceID: String, group: IPTVPlatformRoom) async throws -> [IPTVPlatformRoom] {
        let video = try await client(sourceID).detail(group.id)
        var names: Set<String> = []
        return video.episodes.compactMap { episode in
            guard names.insert(episode.name).inserted else { return nil }
            return IPTVPlatformRoom(id: episode.name, title: episode.name, caption: group.title, cover: group.cover,
                                    offline: false, folder: false, folderFilters: [:], groupID: group.id, channelName: episode.name)
        }
    }

    public func list(sourceID: String, area: String, query: String, page: Int,
                     filters: [String: String] = [:]) async throws -> (rooms: [IPTVPlatformRoom], more: Bool) {
        switch adapter {
        case .rooms:
            let params = query.isEmpty ? ["t": area, "pg": String(page)] : ["wd": query, "pg": String(page)]
            let reply = try await call(sourceID: sourceID, params: params)
            guard let values = reply["rooms"]?.array else {
                throw TVError.unsupported(CatalogClient.providerError(reply) ?? "该平台未提供直播间列表。")
            }
            let rooms = values.compactMap { value -> IPTVPlatformRoom? in
                guard let fields = value.object, let id = fields["id"]?.string, !id.isEmpty else { return nil }
                let title = fields["title"]?.string ?? fields["host"]?.string ?? id
                return IPTVPlatformRoom(id: id, title: LiveText.plain(title), caption: LiveText.plain(fields["host"]?.string ?? ""),
                                        cover: fields["cover"]?.string.flatMap { try? WebAddress.resolve($0, relativeTo: origin) },
                                        offline: Self.offline(fields), folder: false, folderFilters: [:])
            }
            return (rooms, reply["pagecount"]?.int.map { page < $0 } ?? !rooms.isEmpty)
        case .catalog:
            let client = client(sourceID)
            let home = area.isEmpty && query.isEmpty
            let result = home ? try await client.home() : try await client.list(category: area, query: query, page: page, filters: filters)
            let rooms = result.videos.filter { $0.action == nil }.map { video -> IPTVPlatformRoom in
                if catChannelDirectory, !query.isEmpty {
                    let name = Self.catSearchChannelName(video.name)
                    return IPTVPlatformRoom(id: "\(video.id.utf8.count):\(video.id)\(name)", title: video.name, caption: video.remarks,
                                            cover: video.poster, offline: false, folder: false, folderFilters: [:],
                                            groupID: video.id, channelName: name)
                }
                return IPTVPlatformRoom(id: video.isFolder ? video.folderCategoryID : video.id, title: video.name, caption: video.remarks, cover: video.poster,
                                 offline: ["未开播", "已下播", "直播已结束", "offline"].contains(video.remarks.lowercased()),
                                 folder: video.isFolder, folderFilters: video.folderFilters,
                                 listsChannels: catChannelDirectory && video.remarks.range(of: #"^\d+\s*个频道$"#, options: .regularExpression) != nil)
            }
            return (rooms, !home && page < result.pageCount)
        }
    }

    /// CatPaw live.js search includes the config name in parentheses and returns the group's ID for every hit.
    static func catSearchChannelName(_ title: String) -> String {
        title.replacingOccurrences(of: #" \([^()]*\)$"#, with: "", options: .regularExpression)
    }

    static func resolve(_ channel: Channel, room: IPTVRoomAddress) async throws -> ResolvedRoom {
        guard let platform = await registered(room) else { throw TVError.unsupported("该房间的直播来源已停用或移除，请在直播设置中重新启用。") }
        let result = try await platform.resolveCurrent(channel, room: room)
        try Task.checkCancellation()
        guard await registered(room) == platform else { throw TVError.unsupported("该房间的直播来源已更新，请重新打开。") }
        return result
    }

    private func resolveCurrent(_ reference: Channel, room: IPTVRoomAddress) async throws -> ResolvedRoom {
        switch adapter {
        case .rooms:
            let reply = try await call(sourceID: room.sourceID, params: ["play": room.roomID, "flag": room.quality.map(String.init) ?? ""])
            return try Self.stream(from: reply, reference: reference, room: room)
        case .catalog:
            let client = client(room.sourceID)
            let video = try await client.detail(room.roomID)
            guard !video.episodes.isEmpty else {
                let detail = video.synopsis.isEmpty ? video.remarks : video.synopsis
                throw TVError.unsupported(detail.isEmpty ? "直播间暂未开播或没有可用线路。" : detail)
            }
            // Each episode/group can be an independent CDN, each play reply can itself offer qualities.
            // Only ask the selected CDN for its streams. Never persist its current stream addresses.
            let episodes = room.channelName.map { selected in video.episodes.filter { $0.name == selected } } ?? video.episodes
            guard !episodes.isEmpty else { throw TVError.unsupported("频道已从该分组移除，请返回直播目录选择。") }
            let requested = room.quality ?? 0
            let route = requested >> 16
            guard episodes.indices.contains(route) else { throw TVError.unsupported("所选线路已失效，请重新选择。") }
            let plan = try await client.preparePlayback(episodes[route])
            let variant = requested & 0xffff
            guard plan.choices.indices.contains(variant) else { throw TVError.unsupported("所选清晰度已失效，请重新选择。") }
            let resolved = try await client.resolvePlayback(plan, choice: plan.choices[variant])
            var descriptor = resolved.playback ?? PlaybackDescriptor()
            descriptor.isLive = true
            var explicitHeaders = resolved.headers
            if let adapter = client.iptvHTTP {
                let inherited = IPTVHeaders.inherited(adapter.headers, from: adapter.endpoint, to: resolved.url)
                for (key, value) in inherited where !explicitHeaders.keys.contains(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) {
                    explicitHeaders[key] = value
                }
            }
            let channel = Channel(name: reference.name, group: name, url: resolved.url, logo: reference.logo, headers: explicitHeaders,
                                  subtitles: resolved.subtitles, playback: descriptor)
            var qualities: [StreamQuality] = []
            for (index, episode) in episodes.enumerated() {
                let prefix = [episode.flag, episode.name].filter { !$0.isEmpty }.joined(separator: " ")
                let count = index == route ? min(plan.choices.count, 65536) : 1
                for offset in 0..<count {
                    let id = (index << 16) | offset
                    let label = count > 1 ? [prefix, plan.choices[offset].name].joined(separator: " · ") : prefix
                    qualities.append(StreamQuality(id: id, label: label, url: room.withQuality(id).url))
                }
            }
            return (channel, qualities.count > 1 ? qualities : [], requested)
        }
    }

    private static func offline(_ fields: [String: JSONValue]) -> Bool {
        fields["live"] == .bool(false) || fields["isLive"] == .bool(false) ||
        ["offline", "ended", "closed"].contains(fields["status"]?.string?.lowercased() ?? "")
    }

    static func stream(from reply: [String: JSONValue], reference: Channel, room: IPTVRoomAddress) throws -> ResolvedRoom {
        if offline(reply) { throw TVError.unsupported("这个直播间尚未开播或已经下播。") }
        guard let address = reply["url"]?.string, var url = try? MediaAddress.resolve(address) else {
            throw TVError.unsupported(CatalogClient.providerError(reply) ?? "直播间暂时没有可播放的线路。")
        }
        let headers = PlaybackNormalization.headers(reply["headers"] ?? reply["header"])
        if reply["repair"]?.string == "discontinuity" { url = LiveRepair.address(url, headers: headers) }
        let resolved = Channel(name: reference.name, group: reference.group, url: url, logo: reference.logo, headers: headers,
                               playback: PlaybackDescriptor(format: reply["format"]?.string ?? url.pathExtension, isLive: true))
        var seen: Set<Int> = []
        let qualities = (reply["qualities"]?.array ?? []).compactMap { value -> StreamQuality? in
            guard let number = value.object?["id"]?.int, let label = value.object?["label"]?.string, seen.insert(number).inserted else { return nil }
            return StreamQuality(id: number, label: label, url: room.withQuality(number).url)
        }
        return (resolved, qualities, reply["current"]?.int ?? room.quality)
    }
}
