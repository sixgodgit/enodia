import Foundation
import NavCore

/// 本机的地址记忆：收藏（"thuis"、"werk"）+ 最近去过 + 曾经选中过的搜索结果。
///
/// 个人导航的大部分目的地都在一个很小的集合里。这一层让它们在 5 ms 内出现，
/// 完全不碰网络 —— 这是解决"高德荷兰地址慢"最便宜也最有效的一步。
public actor LocalPlaceStore: PlaceProvider {
    public struct StoredPlace: Sendable, Codable, Equatable {
        public var candidate: PlaceCandidate
        public var isFavorite: Bool
        /// 额外的叫法（"thuis"、"kantoor"、"妈妈家"）。
        public var aliases: [String]
        public var lastUsed: Date
        public var useCount: Int
    }

    public nonisolated let name = "local"
    public nonisolated let timeout: TimeInterval = 0.25

    private var places: [StoredPlace]
    private let fileURL: URL?
    private let maxRecents: Int

    public init(fileURL: URL? = nil, maxRecents: Int = 300) {
        self.fileURL = fileURL
        self.maxRecents = maxRecents
        if let url = fileURL, let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([StoredPlace].self, from: data) {
            places = decoded
        } else {
            places = []
        }
    }

    public var all: [StoredPlace] { places }

    public func setFavorite(_ candidate: PlaceCandidate, aliases: [String] = [], at date: Date = Date()) {
        if let i = index(of: candidate) {
            places[i].isFavorite = true
            places[i].aliases = Array(Set(places[i].aliases + aliases))
        } else {
            places.append(StoredPlace(candidate: candidate, isFavorite: true, aliases: aliases, lastUsed: date, useCount: 0))
        }
        persist()
    }

    /// 用户选了某个结果（或者开到了某地）：记下来，下次本地秒出。
    public func remember(_ candidate: PlaceCandidate, at date: Date = Date()) {
        guard candidate.coordinate != nil else { return }   // 没坐标的记了也没用
        if let i = index(of: candidate) {
            places[i].lastUsed = date
            places[i].useCount += 1
        } else {
            places.append(StoredPlace(candidate: candidate, isFavorite: false, aliases: [], lastUsed: date, useCount: 1))
        }
        let recents = places.filter { !$0.isFavorite }
        if recents.count > maxRecents {
            let drop = Set(recents.sorted { $0.lastUsed < $1.lastUsed }.prefix(recents.count - maxRecents).map(\.candidate.id))
            places.removeAll { !$0.isFavorite && drop.contains($0.candidate.id) }
        }
        persist()
    }

    public func search(_ query: PlaceQuery, parsed: DutchAddressQuery) async throws -> [PlaceCandidate] {
        let tokens = parsed.normalized.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return [] }
        var hits: [(StoredPlace, Double)] = []
        for p in places {
            let c = p.candidate
            var matched = false
            if let pc = parsed.postcode, c.postcode == pc {
                matched = parsed.houseNumberKey == nil || parsed.houseNumberKey == c.houseNumber
            }
            if !matched {
                let haystack = ([c.title, c.subtitle ?? ""] + p.aliases)
                    .map(DutchAddressQuery.normalize).joined(separator: " ")
                    .split(separator: " ").map(String.init)
                matched = tokens.allSatisfy { t in haystack.contains { $0.hasPrefix(t) } }
            }
            if matched {
                // 常去 + 最近去过 → 更靠前。
                let recency = exp(-max(0, Date().timeIntervalSince(p.lastUsed)) / (30 * 86_400))
                hits.append((p, 0.5 + 0.05 * Double(min(p.useCount, 5)) + 0.25 * recency))
            }
        }
        return hits.sorted { $0.1 > $1.1 }.prefix(query.limit).map { p, relevance in
            var c = p.candidate
            c.kind = p.isFavorite ? .favorite : .recent
            c.provider = name
            c.relevance = relevance
            return c
        }
    }

    private func index(of c: PlaceCandidate) -> Int? {
        places.firstIndex { p in
            if p.candidate.id == c.id { return true }
            if let a = p.candidate.postcode, let b = c.postcode, let ha = p.candidate.houseNumber, let hb = c.houseNumber {
                return a == b && ha == hb
            }
            return false
        }
    }

    private func persist() {
        guard let url = fileURL, let data = try? JSONEncoder().encode(places) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
