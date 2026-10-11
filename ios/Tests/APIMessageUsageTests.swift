import Foundation

@main
struct APIMessageUsageTests {
    static func decode(_ json: String) throws -> APIMessageTokens {
        try JSONDecoder().decode(APIMessageTokens.self, from: Data(json.utf8))
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    static func close(_ actual: Double?, _ expected: Double) -> Bool {
        actual.map { abs($0 - expected) < 0.00000001 } ?? false
    }

    static func main() throws {
        let prices = APIUsagePrices()
        let native = try decode(#"{"input_tokens":900,"output_tokens":100,"cache_read_input_tokens":80,"cache_creation_input_tokens":20}"#)
        expect(close(native.cacheHitRate, 0.08), "Native input excludes cache tokens, even when larger than the cache")
        expect(close(native.cost(prices: prices, cacheTTL: "5m"), 0.021495), "Native estimate uses all four token classes")
        expect(native.summary(prices: prices, cacheTTL: "5m") == "命中 8% · ≈$0.0215", "Estimated dollars must be marked")

        let openAI = try decode(#"{"prompt_tokens":1000,"completion_tokens":100,"prompt_tokens_details":{"cached_tokens":800}}"#)
        expect(close(openAI.cacheHitRate, 0.8), "OpenAI prompt includes cached tokens")
        expect(close(openAI.cost(prices: prices, cacheTTL: "5m"), 0.0117), "Do not charge cached OpenAI input twice")
        let responses = try decode(#"{"input_tokens":1000,"output_tokens":100,"input_tokens_details":{"cached_tokens":800}}"#)
        expect(close(responses.cacheHitRate, 0.8), "Responses input includes cached tokens")

        let reported = try decode(#"{"input_tokens":2,"output_tokens":358,"cache_creation_input_tokens":443,"cache_read_input_tokens":32281,"cost":0.059061}"#)
        expect(reported.summary(prices: prices, cacheTTL: "1h") == "命中 99% · $0.0591", "Use upstream cost without approximating it")
        let free = try decode(#"{"cost":0,"cost_details":{"upstream_inference_cost":1}}"#)
        expect(close(free.cost(prices: prices, cacheTTL: "5m"), 0), "Reported zero is a valid cost")
        let nested = try decode(#"{"cost_details":{"upstream_inference_cost":"0.125"}}"#)
        expect(close(nested.reportedCost, 0.125), "Accept nested and numeric string costs")

        let writes = try decode(#"{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":1000,"cache_creation":{"ephemeral_5m_input_tokens":400,"ephemeral_1h_input_tokens":600}}"#)
        expect(close(writes.cost(prices: prices, cacheTTL: "5m"), 0.0255), "Honor mixed cache TTL billing")
        let hour = try decode(#"{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":1000}"#)
        expect(close(hour.cost(prices: prices, cacheTTL: "1h"), 0.03), "Use configured TTL when per-TTL counts are absent")
        let custom = try JSONDecoder().decode(APIUsagePrices.self, from: Data(#"{"input":1,"output":2,"cache_read":0.1}"#.utf8))
        expect(close(openAI.cost(prices: custom, cacheTTL: "5m"), 0.00048), "Honor relay price overrides")

        let missing = try decode("{}")
        expect(missing.summary(prices: prices, cacheTTL: "5m") == nil, "Missing usage must not become fake zeros")
        let unknownCache = try decode(#"{"prompt_tokens":100,"completion_tokens":10}"#)
        expect(unknownCache.cacheHitRate == nil, "Missing cache data is unknown, not a miss")
        let malformed = try decode(#"{"input_tokens":"bad","cost":-1,"output_tokens":null,"cache_read_input_tokens":{}}"#)
        expect(malformed.summary(prices: prices, cacheTTL: "5m") == nil, "Invalid numbers must not break history or invent usage")
        print("PASS: per-message usage, provider token semantics, reported/estimated cost, TTL, price overrides and missing data")
    }
}
