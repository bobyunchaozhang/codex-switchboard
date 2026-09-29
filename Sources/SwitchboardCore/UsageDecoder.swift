import Foundation

public enum UsageDecoder {
    private struct Window: Decodable { let usedPercent: Double; let windowDurationMins: Int?; let resetsAt: Double? }
    private struct Bucket: Decodable { let limitName: String?; let primary: Window?; let secondary: Window? }
    private struct Credit: Decodable {
        let title: String?
        let status: String?
        let expiry: ResetCredit.Expiry
        enum CodingKeys: String, CodingKey { case title, status, expiresAt }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            title = try? values.decode(String.self, forKey: .title)
            status = try? values.decode(String.self, forKey: .status)
            if !values.contains(.expiresAt) { expiry = .unknown }
            else if (try? values.decodeNil(forKey: .expiresAt)) == true { expiry = .never }
            else if let seconds = try? values.decode(Double.self, forKey: .expiresAt),
                    seconds.isFinite, seconds >= 0, seconds <= 253_402_300_799 {
                expiry = .at(Date(timeIntervalSince1970: seconds))
            } else { expiry = .unknown }
        }
    }
    private struct Credits: Decodable {
        let availableCount: Int
        let credits: [Credit]?
        enum CodingKeys: String, CodingKey { case availableCount, credits }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            availableCount = try values.decode(Int.self, forKey: .availableCount)
            credits = try? values.decode([Credit].self, forKey: .credits)
        }
    }
    private struct Response: Decodable {
        let rateLimits: Bucket?
        let rateLimitsByLimitId: [String: Bucket]?
        let rateLimitResetCredits: Credits?
    }

    public static func decode(_ data: Data) throws -> Usage {
        let response = try JSONDecoder().decode(Response.self, from: data)
        let buckets: [String: Bucket]
        if let all = response.rateLimitsByLimitId, !all.isEmpty { buckets = all }
        else if let legacy = response.rateLimits { buckets = ["codex": legacy] }
        else { throw SwitchboardFailure.unavailable }
        var quotas: [Quota] = []
        for key in buckets.keys.sorted() {
            guard let bucket = buckets[key] else { continue }
            for (slot, window) in [("primary", bucket.primary), ("secondary", bucket.secondary)] {
                guard let window, window.usedPercent.isFinite else { continue }
                let period = title(minutes: window.windowDurationMins, slot: slot)
                let name = bucket.limitName.flatMap { $0.isEmpty ? nil : $0 } ?? key
                let label = buckets.count == 1 && key == "codex" ? period : "\(name) · \(period)"
                quotas.append(Quota(id: "\(key):\(slot)", title: label,
                                    remaining: min(100, max(0, 100 - window.usedPercent)),
                                    resetsAt: window.resetsAt.map(Date.init(timeIntervalSince1970:))))
            }
        }
        let details = response.rateLimitResetCredits?.credits?.enumerated().map { index, credit in
            ResetCredit(id: index, title: credit.title, expiry: credit.expiry, status: credit.status)
        }.sorted { left, right in
            func date(_ credit: ResetCredit) -> Date {
                if case .at(let date) = credit.expiry { return date }
                return .distantFuture
            }
            return date(left) == date(right) ? left.id < right.id : date(left) < date(right)
        }
        return Usage(quotas: quotas, resetCount: response.rateLimitResetCredits.map { max(0, $0.availableCount) },
                     resetCredits: details)
    }

    private static func title(minutes: Int?, slot: String) -> String {
        guard let minutes, minutes > 0 else { return slot == "primary" ? "Primary window" : "Secondary window" }
        if minutes == 10_080 { return "Weekly" }
        if minutes == 1_440 { return "Daily" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)-day" }
        if minutes % 60 == 0 { return "\(minutes / 60)-hour" }
        return "\(minutes)-minute"
    }
}
