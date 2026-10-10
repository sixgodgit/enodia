import Foundation

/// 荷兰地址输入的解析：识别"邮编 + 门牌号"这种荷兰人最常用、也最精确的输入方式。
///
/// 荷兰邮编 = 4 位数字（首位非 0）+ 2 个字母（不用 SA/SD/SS），一个邮编通常只覆盖一条街的一段；
/// 邮编 + 门牌号几乎唯一确定一个地址。识别出来就走精确查找，不用模糊搜索。
public struct DutchAddressQuery: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// "3511 AB"
        case postcode(String)
        /// "3511 AB 12-bis" → number 12, addition "BIS"
        case postcodeHouseNumber(postcode: String, number: Int, addition: String?)
        /// "Oudegracht 12A, Utrecht"
        case streetHouseNumber(street: String, number: Int, addition: String?, city: String?)
        case freeText
    }

    public let raw: String
    /// 用于本地匹配的规范化文本（小写、去变音符、地名别名）。
    public let normalized: String
    public let kind: Kind

    public init(_ raw: String) {
        self.raw = raw
        self.normalized = DutchAddressQuery.normalize(raw)
        self.kind = DutchAddressQuery.classify(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public var postcode: String? {
        switch kind {
        case .postcode(let p), .postcodeHouseNumber(let p, _, _): return p
        default: return nil
        }
    }

    /// "12" / "12A" / "12-2" 统一成 "12A"、"122"…… 这种形式用于和数据源比对。
    public var houseNumberKey: String? {
        switch kind {
        case .postcodeHouseNumber(_, let n, let a), .streetHouseNumber(_, let n, let a, _):
            return "\(n)\(a ?? "")"
        default: return nil
        }
    }

    // MARK: - 解析

    private static let postcodeRegex = try! NSRegularExpression(
        pattern: #"^([1-9][0-9]{3})\s?([A-Za-z]{2})(?:[\s,]*(\d{1,5})(?:\s*[-\s]?\s*([A-Za-z0-9]{1,4}))?)?$"#)
    private static let streetRegex = try! NSRegularExpression(
        pattern: #"^(.*?[^\d\s].*?)\s+(\d{1,5})(?:\s*-?\s*([A-Za-z]{1,3}|\d{1,3}))?\s*(?:,\s*(.+))?$"#)

    static func classify(_ s: String) -> Kind {
        let range = NSRange(s.startIndex..., in: s)
        if let m = postcodeRegex.firstMatch(in: s, range: range) {
            let letters = group(m, 2, s)!.uppercased()
            if !["SA", "SD", "SS"].contains(letters) {
                let pc = group(m, 1, s)! + letters
                if let n = group(m, 3, s).flatMap(Int.init) {
                    return .postcodeHouseNumber(postcode: pc, number: n, addition: group(m, 4, s)?.uppercased())
                }
                return .postcode(pc)
            }
        }
        if let m = streetRegex.firstMatch(in: s, range: range), let n = group(m, 2, s).flatMap(Int.init) {
            let street = group(m, 1, s)!.trimmingCharacters(in: .whitespaces)
            return .streetHouseNumber(street: street, number: n, addition: group(m, 3, s)?.uppercased(),
                                      city: group(m, 4, s)?.trimmingCharacters(in: .whitespaces))
        }
        return .freeText
    }

    private static func group(_ m: NSTextCheckingResult, _ i: Int, _ s: String) -> String? {
        let r = m.range(at: i)
        guard r.location != NSNotFound, let range = Range(r, in: s) else { return nil }
        return String(s[range])
    }

    // MARK: - 规范化

    /// 荷兰地名的正式名/日常名。用户输入哪个都能命中本地记录。
    static let aliases: [(String, String)] = [
        ("s gravenhage", "den haag"),
        ("s hertogenbosch", "den bosch"),
        ("the hague", "den haag"),
    ]

    public static func normalize(_ s: String) -> String {
        var t = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "nl_NL"))
        t = String(t.map { $0.isLetter || $0.isNumber ? $0 : " " })
        t = t.split(separator: " ").joined(separator: " ")
        for (formal, common) in aliases where t.contains(formal) {
            t = t.replacingOccurrences(of: formal, with: common)
        }
        return t
    }
}
