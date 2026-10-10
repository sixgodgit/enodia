import Foundation
import NavCore

public struct PlaceCandidate: Sendable, Equatable, Identifiable, Codable {
    public enum Kind: String, Sendable, Codable {
        case favorite, recent, address, postcode, street, city, poi
    }

    public var id: String
    public var title: String
    public var subtitle: String?
    public var coordinate: Coordinate?
    public var kind: Kind
    /// 哪个来源给的（"local"、"pdok"、"mapkit"、"amap"）。
    public var provider: String
    /// 来源自己的相关度，归一化到 0–1。
    public var relevance: Double
    /// 规范化邮编（"3511AB"），用于跨来源去重。
    public var postcode: String?
    /// 规范化门牌（"12A"）。
    public var houseNumber: String?

    public init(id: String, title: String, subtitle: String? = nil, coordinate: Coordinate?, kind: Kind,
                provider: String, relevance: Double = 0.5, postcode: String? = nil, houseNumber: String? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.coordinate = coordinate
        self.kind = kind
        self.provider = provider
        self.relevance = relevance
        self.postcode = postcode
        self.houseNumber = houseNumber
    }
}

public struct PlaceQuery: Sendable, Equatable {
    public var text: String
    /// 当前位置：用来让近处的结果靠前。
    public var near: Coordinate?
    public var limit: Int

    public init(text: String, near: Coordinate? = nil, limit: Int = 10) {
        self.text = text
        self.near = near
        self.limit = limit
    }
}

/// 一个地址/POI 来源。每个来源有自己的硬超时：超时就不要它的结果了，绝不让它拖住其他来源。
public protocol PlaceProvider: Sendable {
    var name: String { get }
    var timeout: TimeInterval { get }
    func search(_ query: PlaceQuery, parsed: DutchAddressQuery) async throws -> [PlaceCandidate]
}

public struct PlaceSearchSnapshot: Sendable, Equatable {
    public var query: String
    public var results: [PlaceCandidate]
    /// 还没回来的来源。
    public var pending: [String]
    /// 出错或超时的来源。
    public var failed: [String]
    public var done: Bool
}

/// 地址入口层：所有来源同时出发，谁先回来先显示谁，结果逐步合并。
///
/// 典型时序（荷兰）：本地记录 < 5 ms → PDOK（政府 BAG 地址库）~100–300 ms → MapKit POI → 高德 POI（最慢）。
/// 用户看到的第一屏几乎总是本地或 PDOK 给的；高德只在找"商家"时有补充价值，而且不再是瓶颈。
public struct PlaceSearch: Sendable {
    public let providers: [any PlaceProvider]
    public var ranker: PlaceRanker

    public init(providers: [any PlaceProvider], ranker: PlaceRanker = PlaceRanker()) {
        self.providers = providers
        self.ranker = ranker
    }

    public func search(_ query: PlaceQuery) -> AsyncStream<PlaceSearchSnapshot> {
        let providers = self.providers
        let ranker = self.ranker
        let parsed = DutchAddressQuery(query.text)
        return AsyncStream { continuation in
            let task = Task {
                var collected: [PlaceCandidate] = []
                var pending = providers.map(\.name)
                var failed: [String] = []
                func snapshot(done: Bool) -> PlaceSearchSnapshot {
                    PlaceSearchSnapshot(query: query.text,
                                        results: ranker.rank(collected, query: query, parsed: parsed),
                                        pending: pending, failed: failed, done: done)
                }

                await withTaskGroup(of: (String, Result<[PlaceCandidate], Error>).self) { group in
                    for p in providers {
                        group.addTask {
                            do {
                                let r = try await withTimeout(p.timeout) { try await p.search(query, parsed: parsed) }
                                return (p.name, .success(r))
                            } catch {
                                return (p.name, .failure(error))
                            }
                        }
                    }
                    for await (name, result) in group {
                        pending.removeAll { $0 == name }
                        switch result {
                        case .success(let r): collected.append(contentsOf: r)
                        case .failure: failed.append(name)
                        }
                        if Task.isCancelled { return }
                        continuation.yield(snapshot(done: false))
                    }
                }
                continuation.yield(snapshot(done: true))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// 合并、去重、排序。
public struct PlaceRanker: Sendable {
    /// 去重时认为"同一个地方"的距离（米）。
    public var sameplaceRadius = 30.0

    public init() {}

    public func rank(_ candidates: [PlaceCandidate], query: PlaceQuery, parsed: DutchAddressQuery) -> [PlaceCandidate] {
        var merged: [PlaceCandidate] = []
        for c in candidates.sorted(by: { priority($0) > priority($1) }) {
            if let i = merged.firstIndex(where: { same($0, c) }) {
                if merged[i].coordinate == nil { merged[i].coordinate = c.coordinate }
            } else {
                merged.append(c)
            }
        }
        return Array(merged.sorted { score($0, query, parsed) > score($1, query, parsed) }.prefix(query.limit))
    }

    /// 同一个地方以哪个来源的条目为准：自己存的 > 政府地址库 > POI。
    private func priority(_ c: PlaceCandidate) -> Int {
        switch c.kind {
        case .favorite: return 5
        case .recent: return 4
        case .address, .postcode: return 3
        case .street, .city: return 2
        case .poi: return 1
        }
    }

    private func same(_ a: PlaceCandidate, _ b: PlaceCandidate) -> Bool {
        if let pa = a.postcode, let pb = b.postcode, let ha = a.houseNumber, let hb = b.houseNumber {
            return pa == pb && ha == hb
        }
        guard let ca = a.coordinate, let cb = b.coordinate else { return false }
        return Geo.distance(ca, cb) <= sameplaceRadius
            && DutchAddressQuery.normalize(a.title) == DutchAddressQuery.normalize(b.title)
    }

    func score(_ c: PlaceCandidate, _ query: PlaceQuery, _ parsed: DutchAddressQuery) -> Double {
        var s = c.relevance * 0.3
        switch c.kind {
        case .favorite: s += 0.6
        case .recent: s += 0.4
        case .address: s += 0.3
        case .postcode, .street: s += 0.2
        case .city: s += 0.15
        case .poi: s += 0.1
        }
        switch parsed.kind {
        case .postcode(let pc):
            if c.postcode == pc { s += 0.8 }
            if c.kind == .poi { s -= 0.3 }
        case .postcodeHouseNumber(let pc, _, _):
            if c.postcode == pc && c.houseNumber == parsed.houseNumberKey { s += 1.2 }
            else if c.postcode == pc { s += 0.4 }
            if c.kind == .poi { s -= 0.3 }
        case .streetHouseNumber:
            if c.kind == .address, c.houseNumber == parsed.houseNumberKey { s += 0.3 }
        case .freeText:
            break
        }
        if let near = query.near, let p = c.coordinate {
            s += 0.2 * exp(-Geo.distance(near, p) / 20_000)
        }
        return s
    }
}
