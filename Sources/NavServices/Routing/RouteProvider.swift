import Foundation
import NavCore

/// 路线服务。NavigationEngine 发出 `RouteRequest`，宿主挑一个 provider 去算，结果用 `engine.offer` 交回。
///
/// 主 provider 是高德（ios/Amap/AmapRouteProvider.swift）。高德导航 SDK 是单例、一次只有一组路线，
/// 在导航中"顺便"算一条预算路线会把正在用的路线顶掉，所以预算请求交给第二个 provider（例如自建 OSRM），
/// 没有第二个 provider 就不做预算 —— 引擎照样能靠备选路线 + 偏航后重算工作。
public protocol RouteProvider: Sendable {
    var name: String { get }
    /// 能否在导航进行中计算"与当前导航无关"的路线（预算路线需要）。
    var supportsBackgroundCalculation: Bool { get }
    func routes(for request: RouteRequest) async throws -> [Route]
}

/// 按请求目的选 provider。
public struct RouteProviderRouter: Sendable {
    public var primary: any RouteProvider
    public var secondary: (any RouteProvider)?

    public init(primary: any RouteProvider, secondary: (any RouteProvider)? = nil) {
        self.primary = primary
        self.secondary = secondary
    }

    public func provider(for request: RouteRequest) -> (any RouteProvider)? {
        if case .speculative = request.purpose {
            if primary.supportsBackgroundCalculation { return primary }
            return secondary?.supportsBackgroundCalculation == true ? secondary : nil
        }
        return primary
    }
}
