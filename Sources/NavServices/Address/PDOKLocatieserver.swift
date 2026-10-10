import Foundation
import NavCore

/// PDOK Locatieserver —— 荷兰政府的地址搜索（数据来自 BAG 地址与建筑登记）。
///
/// 免费、无需 key、覆盖全国每一个地址/邮编/街道/地名，在荷兰比任何商业地图都准、都快。
/// 文档：https://api.pdok.nl/bzk/locatieserver/search/v3_1/ui/
///
/// ⚠️ 本仓库的 CI 访问不到 PDOK，解析逻辑是按 v3_1 文档的响应格式写的、用样例测的；
///    第一次真机联调时请用 `PDOKLocatieserverTests` 里的样例对照一次真实响应。
public struct PDOKLocatieserver: PlaceProvider {
    public let name = "pdok"
    public var timeout: TimeInterval
    public var baseURL: URL
    /// 按距离加权（lat/lon 参数）。服务端拒绝时自动去掉重试一次。
    public var useProximity: Bool
    private let http: any HTTPClient

    public init(http: any HTTPClient = URLSessionHTTPClient(), timeout: TimeInterval = 2.5,
                baseURL: URL = URL(string: "https://api.pdok.nl/bzk/locatieserver/search/v3_1/")!,
                useProximity: Bool = true) {
        self.http = http
        self.timeout = timeout
        self.baseURL = baseURL
        self.useProximity = useProximity
    }

    static let fields = "id,type,weergavenaam,straatnaam,huisnummer,huisletter,huisnummertoevoeging,"
        + "postcode,woonplaatsnaam,centroide_ll,score"

    public func searchURL(for query: PlaceQuery, parsed: DutchAddressQuery, proximity: Bool) -> URL {
        var c = URLComponents(url: baseURL.appendingPathComponent("free"), resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "q", value: query.text),
            URLQueryItem(name: "rows", value: String(query.limit)),
            URLQueryItem(name: "fl", value: PDOKLocatieserver.fields),
        ]
        switch parsed.kind {
        case .postcodeHouseNumber, .streetHouseNumber:
            items.append(URLQueryItem(name: "fq", value: "type:adres"))
        case .postcode:
            items.append(URLQueryItem(name: "fq", value: "type:(postcode OR adres)"))
        case .freeText:
            items.append(URLQueryItem(name: "fq", value: "type:(adres OR postcode OR weg OR woonplaats)"))
        }
        if proximity, let near = query.near {
            items.append(URLQueryItem(name: "lat", value: String(format: "%.5f", near.latitude)))
            items.append(URLQueryItem(name: "lon", value: String(format: "%.5f", near.longitude)))
        }
        c.queryItems = items
        return c.url!
    }

    public func search(_ query: PlaceQuery, parsed: DutchAddressQuery) async throws -> [PlaceCandidate] {
        let proximity = useProximity && query.near != nil
        var (data, status) = try await http.get(searchURL(for: query, parsed: parsed, proximity: proximity),
                                                timeout: timeout)
        if status == 400 && proximity {
            (data, status) = try await http.get(searchURL(for: query, parsed: parsed, proximity: false), timeout: timeout)
        }
        guard status == 200 else { throw HTTPStatusError(status: status) }
        return try PDOKLocatieserver.parse(data)
    }

    // MARK: - 响应解析

    private struct Response: Decodable {
        struct Body: Decodable { var docs: [Doc] }
        struct Doc: Decodable {
            var id: String
            var type: String
            var weergavenaam: String
            var straatnaam: String?
            var huisnummer: Int?
            var huisletter: String?
            var huisnummertoevoeging: String?
            var postcode: String?
            var woonplaatsnaam: String?
            var centroide_ll: String?
            var score: Double?
        }
        var response: Body
    }

    public static func parse(_ data: Data) throws -> [PlaceCandidate] {
        let docs = try JSONDecoder().decode(Response.self, from: data).response.docs
        let maxScore = docs.compactMap(\.score).max() ?? 1
        return docs.map { d in
            let house = d.huisnummer.map { "\($0)\(d.huisletter ?? "")\(d.huisnummertoevoeging ?? "")".uppercased() }
            let kind: PlaceCandidate.Kind
            let title: String
            var subtitle: String?
            switch d.type {
            case "adres":
                kind = .address
                title = [d.straatnaam, house].compactMap { $0 }.joined(separator: " ")
                subtitle = [d.postcode, d.woonplaatsnaam].compactMap { $0 }.joined(separator: " ")
            case "postcode":
                kind = .postcode
                title = d.postcode ?? d.weergavenaam
                subtitle = [d.straatnaam, d.woonplaatsnaam].compactMap { $0 }.joined(separator: ", ")
            case "weg":
                kind = .street
                title = d.straatnaam ?? d.weergavenaam
                subtitle = d.woonplaatsnaam
            case "woonplaats", "gemeente":
                kind = .city
                title = d.woonplaatsnaam ?? d.weergavenaam
            default:
                kind = .street
                title = d.weergavenaam
            }
            return PlaceCandidate(id: "pdok:\(d.id)", title: title.isEmpty ? d.weergavenaam : title,
                                  subtitle: subtitle?.isEmpty == true ? nil : subtitle,
                                  coordinate: d.centroide_ll.flatMap(parseWKTPoint), kind: kind, provider: "pdok",
                                  relevance: maxScore > 0 ? (d.score ?? 0) / maxScore : 0.5,
                                  postcode: d.postcode?.replacingOccurrences(of: " ", with: "").uppercased(),
                                  houseNumber: house)
        }
    }

    /// "POINT(4.89520 52.37021)" → Coordinate（WKT 是"经度 纬度"顺序）。
    static func parseWKTPoint(_ s: String) -> Coordinate? {
        guard let open = s.firstIndex(of: "("), let close = s.lastIndex(of: ")"), open < close else { return nil }
        let parts = s[s.index(after: open)..<close].split(separator: " ").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        let c = Coordinate(latitude: parts[1], longitude: parts[0])
        return c.isValid ? c : nil
    }
}
