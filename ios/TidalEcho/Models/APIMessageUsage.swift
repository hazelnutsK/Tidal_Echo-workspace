import Foundation

/// USD per million tokens, matching the relay's fallback price sheet. A newer
/// relay can supply overrides through loop/config without an app update.
struct APIUsagePrices: Decodable, Hashable {
    var input = 15.0
    var output = 75.0
    var cacheRead = 1.5
    var cacheWrite5m = 18.75
    var cacheWrite1h = 30.0

    init() {}

    enum CodingKeys: String, CodingKey {
        case input, output
        case cacheRead = "cache_read"
        case cacheWrite5m = "cache_write_5m"
        case cacheWrite1h = "cache_write_1h"
    }

    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        input = values.nonnegativeNumber(.input) ?? input
        output = values.nonnegativeNumber(.output) ?? output
        cacheRead = values.nonnegativeNumber(.cacheRead) ?? cacheRead
        cacheWrite5m = values.nonnegativeNumber(.cacheWrite5m) ?? cacheWrite5m
        cacheWrite1h = values.nonnegativeNumber(.cacheWrite1h) ?? cacheWrite1h
    }
}

struct APIMessageUsage: Decodable, Hashable {
    let runtime: String?
    let usage: APIMessageTokens?

    enum CodingKeys: String, CodingKey { case runtime, usage }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        runtime = try? values.decode(String.self, forKey: .runtime)
        usage = try? values.decode(APIMessageTokens.self, forKey: .usage)
    }
}

struct APIMessageTokens: Decodable, Hashable {
    let input: Double?
    let output: Double?
    let cacheRead: Double?
    let cacheWrite: Double?
    let cacheWrite5m: Double?
    let cacheWrite1h: Double?
    let reportedCost: Double?

    enum CodingKeys: String, CodingKey {
        case input = "input_tokens", prompt = "prompt_tokens"
        case output = "output_tokens", completion = "completion_tokens"
        case cacheRead = "cache_read_input_tokens", cacheWrite = "cache_creation_input_tokens"
        case promptDetails = "prompt_tokens_details", inputDetails = "input_tokens_details"
        case cacheCreation = "cache_creation"
        case write5m = "claude_cache_creation_5_m_tokens", write1h = "claude_cache_creation_1_h_tokens"
        case cost, costDetails = "cost_details"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let promptDetails = try? values.decode(TokenDetails.self, forKey: .promptDetails)
        let inputDetails = try? values.decode(TokenDetails.self, forKey: .inputDetails)
        let creation = try? values.decode(CacheCreation.self, forKey: .cacheCreation)
        cacheRead = values.nonnegativeNumber(.cacheRead) ?? promptDetails?.cached ?? inputDetails?.cached
        cacheWrite5m = creation?.fiveMinutes ?? values.nonnegativeNumber(.write5m)
        cacheWrite1h = creation?.oneHour ?? values.nonnegativeNumber(.write1h)
        cacheWrite = values.nonnegativeNumber(.cacheWrite)
            ?? ((cacheWrite5m != nil || cacheWrite1h != nil) ? (cacheWrite5m ?? 0) + (cacheWrite1h ?? 0) : nil)

        // Anthropic's input_tokens excludes cache reads/writes; OpenAI's prompt
        // (or Responses input with input_tokens_details) already includes them.
        if let nativeInput = values.nonnegativeNumber(.input), inputDetails == nil {
            input = nativeInput
        } else if let total = values.nonnegativeNumber(.prompt) ?? values.nonnegativeNumber(.input) {
            input = max(0, total - (cacheRead ?? 0) - (cacheWrite ?? 0))
        } else {
            input = nil
        }
        output = values.nonnegativeNumber(.output) ?? values.nonnegativeNumber(.completion)
        let details = try? values.decode(CostDetails.self, forKey: .costDetails)
        reportedCost = values.nonnegativeNumber(.cost) ?? details?.upstream
    }

    var cacheHitRate: Double? {
        guard let input, cacheRead != nil else { return nil }
        let total = input + (cacheRead ?? 0) + (cacheWrite ?? 0)
        return total > 0 ? min(1, (cacheRead ?? 0) / total) : nil
    }

    func cost(prices: APIUsagePrices, cacheTTL: String) -> Double? {
        if let reportedCost { return reportedCost }
        guard let input, let output else { return nil }
        let defaultWriteRate = cacheTTL == "1h" ? prices.cacheWrite1h : prices.cacheWrite5m
        let knownWrites = (cacheWrite5m ?? 0) + (cacheWrite1h ?? 0)
        let remainingWrites = max(0, (cacheWrite ?? 0) - knownWrites)
        return (input * prices.input + output * prices.output
            + (cacheRead ?? 0) * prices.cacheRead
            + (cacheWrite5m ?? 0) * prices.cacheWrite5m
            + (cacheWrite1h ?? 0) * prices.cacheWrite1h
            + remainingWrites * defaultWriteRate) / 1_000_000
    }

    func summary(prices: APIUsagePrices, cacheTTL: String) -> String? {
        let amount = cost(prices: prices, cacheTTL: cacheTTL)
        guard input != nil || output != nil || cacheRead != nil || amount != nil else { return nil }
        let hit = cacheHitRate.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
        let money = amount.map {
            (reportedCost == nil ? "≈" : "")
                + String(format: "$%.4f", locale: Locale(identifier: "en_US_POSIX"), $0)
        } ?? "—"
        return "命中 \(hit) · \(money)"
    }

    private struct TokenDetails: Decodable {
        let cached: Double?
        enum CodingKeys: String, CodingKey { case cached = "cached_tokens" }
        init(from decoder: Decoder) throws {
            cached = try decoder.container(keyedBy: CodingKeys.self).nonnegativeNumber(.cached)
        }
    }

    private struct CacheCreation: Decodable {
        let fiveMinutes: Double?
        let oneHour: Double?
        enum CodingKeys: String, CodingKey {
            case fiveMinutes = "ephemeral_5m_input_tokens", oneHour = "ephemeral_1h_input_tokens"
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            fiveMinutes = values.nonnegativeNumber(.fiveMinutes)
            oneHour = values.nonnegativeNumber(.oneHour)
        }
    }

    private struct CostDetails: Decodable {
        let upstream: Double?
        enum CodingKeys: String, CodingKey { case upstream = "upstream_inference_cost" }
        init(from decoder: Decoder) throws {
            upstream = try decoder.container(keyedBy: CodingKeys.self).nonnegativeNumber(.upstream)
        }
    }
}

private extension KeyedDecodingContainer {
    func nonnegativeNumber(_ key: Key) -> Double? {
        let number = (try? decode(Double.self, forKey: key))
            ?? (try? decode(String.self, forKey: key)).flatMap(Double.init)
        guard let number, number.isFinite, number >= 0 else { return nil }
        return number
    }
}
