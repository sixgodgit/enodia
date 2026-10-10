// ⚠️ 未在本仓库 CI 中编译：需要 iOS SDK（MapKit）。
//
// Apple 地图的 POI 搜索：在荷兰覆盖商家/地点很好，系统自带、免费、无需 key。
// 地址（邮编+门牌）交给 PDOK，商家交给它；高德 POI 可以作为第四个来源接进 PlaceSearch，
// 但它最慢，给一个短超时，它回不来也不影响前三个来源的结果。

import Foundation
import MapKit
import NavCore
import NavServices

struct MapKitPlaceProvider: PlaceProvider {
    let name = "mapkit"
    var timeout: TimeInterval = 2.0

    func search(_ query: PlaceQuery, parsed: DutchAddressQuery) async throws -> [PlaceCandidate] {
        // 邮编类输入 PDOK 更准，这里不重复查。
        if parsed.postcode != nil { return [] }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query.text
        request.resultTypes = [.pointOfInterest, .address]
        if let near = query.near {
            request.region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: near.latitude, longitude: near.longitude),
                latitudinalMeters: 50_000, longitudinalMeters: 50_000)
        }
        let search = MKLocalSearch(request: request)
        let response = try await withTaskCancellationHandler {
            try await search.start()
        } onCancel: {
            search.cancel()
        }
        let items = response.mapItems.prefix(query.limit)
        return items.enumerated().map { i, item in
            let pm = item.placemark
            let postcode = pm.postalCode?.replacingOccurrences(of: " ", with: "").uppercased()
            return PlaceCandidate(
                id: "mapkit:\(pm.coordinate.latitude),\(pm.coordinate.longitude):\(item.name ?? "")",
                title: item.name ?? pm.thoroughfare ?? query.text,
                subtitle: [pm.thoroughfare.map { t in [t, pm.subThoroughfare].compactMap { $0 }.joined(separator: " ") },
                           pm.locality].compactMap { $0 }.joined(separator: ", "),
                coordinate: Coordinate(pm.coordinate.latitude, pm.coordinate.longitude),
                kind: item.pointOfInterestCategory != nil ? .poi : .address,
                provider: name,
                relevance: 1 - Double(i) / Double(max(1, items.count)),
                postcode: postcode,
                houseNumber: pm.subThoroughfare?.replacingOccurrences(of: " ", with: "").uppercased())
        }
    }
}
