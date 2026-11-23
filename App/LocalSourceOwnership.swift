import TVCore

extension Store {
    /// The compact picker already has the visible sources in subscription order.
    /// Build the ownership map once, rather than scanning all subscriptions and
    /// normalizing their URLs again for every tile on every picker update.
    func localHomeSources(in group: LocalSourceGroup) -> [Site] {
        guard let config = subscription else { return [] }
        var owners: [String: LocalSourceGroup] = [:]
        for entry in subscriptions where entry.enabled {
            guard let document = documents[entry.address] else { continue }
            let origin = LocalHomeSourceSelection.stableOrigin(document.origin.absoluteString)
            if owners[origin] == nil { owners[origin] = localSourceGroups[entry.address] ?? .subscription }
        }
        return homeSourceSites(config).filter { site in
            guard !site.isBuiltIn else { return false }
            let origin = LocalHomeSourceSelection.stableOrigin(site.origin(or: config.origin).absoluteString)
            return (owners[origin] ?? (site.runtime == .python ? .python : .subscription)) == group
        }
    }

    /// The import category owns navigation. A Python entry can itself contain a Node bundle,
    /// and an ordinary TVBox subscription can list Python alongside other script runtimes.
    func localSourceGroup(for site: Site) -> LocalSourceGroup {
        if let config = subscription {
            let origin = LocalHomeSourceSelection.stableOrigin(site.origin(or: config.origin).absoluteString)
            if let owner = subscriptions.first(where: {
                $0.enabled && documents[$0.address].map { LocalHomeSourceSelection.stableOrigin($0.origin.absoluteString) == origin } == true
            }) {
                return localSourceGroups[owner.address] ?? .subscription
            }
        }
        return site.runtime == .python ? .python : .subscription
    }
}
