import CoreGraphics
import Foundation

enum MessageAuthor: String, Codable, Hashable {
    case human
    case ai
}

enum DeliveryState: Hashable {
    case sending
    case sent
    case failed
}

enum ChatLayoutStyle: String, CaseIterable, Identifiable {
    case classic
    case imessage

    var id: String { rawValue }
    var title: String {
        switch self {
        case .classic: return "经典"
        case .imessage: return "仿 iMessage"
        }
    }
}

enum ComposerStyle: String, CaseIterable, Identifiable {
    case original
    case wechat
    case telegram

    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: return "原有"
        case .wechat: return "微信式磨砂"
        case .telegram: return "Telegram 式"
        }
    }

    var note: String {
        switch self {
        case .original: return "跟着主题走的原有输入栏。"
        case .wechat: return "微信式磨砂：底部贴边，在线绿点放在输入框右侧，点它可以切换对话窗口。"
        case .telegram: return "Telegram 式：浮在聊天上的玻璃按钮。打字后录音键让位给发送键；输入框左边的绿点是在线状态，点它切换对话窗口。"
        }
    }
}

enum EchoBubbleStyle: String, Codable, CaseIterable, Identifiable {
    case classic
    case frosted
    case liquid

    var id: String { rawValue }
    var title: String {
        switch self {
        case .classic: return "经典"
        case .frosted: return "磨砂"
        case .liquid: return "液态玻璃"
        }
    }
}

enum EchoBubbleShapeStyle: String, Codable, CaseIterable, Identifiable {
    case standard
    case telegram
    case upperTail
    case jelly
    case neat

    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard: return "默认"
        case .telegram: return "仿 TG"
        case .upperTail: return "上尖角"
        case .jelly: return "软糖"
        case .neat: return "利落"
        }
    }

    /// The two silhouettes she tuned in the bubble fitting room (2026-09-27):
    /// four equal smoothed corners, no tail, radius and padding fixed.
    var smoothSpec: SmoothBubbleSpec? {
        switch self {
        case .jelly:
            return SmoothBubbleSpec(radius: 25, smoothing: 0.92, horizontalPadding: 16, verticalPadding: 10)
        case .neat:
            return SmoothBubbleSpec(radius: 14, smoothing: 0.60, horizontalPadding: 14, verticalPadding: 9)
        case .standard, .telegram, .upperTail:
            return nil
        }
    }
}

struct SmoothBubbleSpec: Hashable {
    let radius: CGFloat
    let smoothing: CGFloat
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
}

enum AIReplyTiming: String, Codable, CaseIterable, Identifiable {
    case immediate
    case bundled

    var id: String { rawValue }
    var title: String {
        switch self {
        case .immediate: return "立即回复"
        case .bundled: return "统一发送"
        }
    }
}

struct LiquidGlassSettings: Hashable {
    let strength: Double
    let dispersion: Double
    let rimWidth: Double
    let magnify: Double
    let blur: Double
    let size: Double
}

struct MessageTimer: Codable, Hashable {
    var label: String
    var minutes: Int
    var endsAt: String
    var status: String
    var doneAt: String?

    enum CodingKeys: String, CodingKey {
        case label, minutes, status
        case endsAt = "ends_at"
        case doneAt = "done_at"
    }
}

struct ToolStep: Decodable, Hashable {
    var tool: String?
    var cmd: String?
    var result: String?
}

private struct ActMeta: Decodable {
    var glyph: String?
    var steps: [ToolStep]?
}

struct Attachment: Codable, Hashable, Identifiable {
    var url: String
    var name: String
    var size: Int?
    var mime: String?
    var kind: String?
    var width: Double?
    var height: Double?
    var voice: Bool?
    /// 小红书笔记的配图（relay 展开链接时下载的）。归预览卡管，不再单独铺一排。
    var xhs: Bool?

    var id: String { "\(url)#\(name)" }
    var isImage: Bool { kind == "image" || mime?.hasPrefix("image/") == true }
    var isAudio: Bool { voice == true || kind == "audio" || mime?.hasPrefix("audio/") == true }
    var isXHS: Bool { xhs == true }
}

struct BundledMessagePart: Hashable, Identifiable {
    let id = UUID()
    let text: String
    let attachments: [Attachment]
    var messageID: Int? = nil

    var preview: String {
        if !text.isEmpty { return text.replacingOccurrences(of: "\n", with: " ") }
        if attachments.count == 1 { return attachments[0].name }
        return "\(attachments.count) 个附件"
    }
}

/// 她丢来的小红书链接，relay 替她读回来的那篇笔记（backend/xhs.py）。
/// 抓取要几秒，先到的是 status=loading 的空卡；抓不到就是 failed，只剩 url。
struct XHSCard: Decodable, Hashable {
    var status: String?
    var url: String?
    var title: String?
    var desc: String?
    var author: String?
    var images: [String]
    var imageCount: Int?
    var liked: Int?
    var commented: Int?
    var collected: Int?

    enum CodingKeys: String, CodingKey {
        case status, url, title, desc, author, images, liked, commented, collected
        case imageCount = "image_count"
    }

    init(from decoder: Decoder) throws {
        let v = try decoder.container(keyedBy: CodingKeys.self)
        status = (try? v.decodeIfPresent(String.self, forKey: .status)) ?? nil
        url = (try? v.decodeIfPresent(String.self, forKey: .url)) ?? nil
        title = (try? v.decodeIfPresent(String.self, forKey: .title)) ?? nil
        desc = (try? v.decodeIfPresent(String.self, forKey: .desc)) ?? nil
        author = (try? v.decodeIfPresent(String.self, forKey: .author)) ?? nil
        images = ((try? v.decodeIfPresent([String].self, forKey: .images)) ?? nil) ?? []
        imageCount = (try? v.decodeIfPresent(Int.self, forKey: .imageCount)) ?? nil
        liked = (try? v.decodeIfPresent(Int.self, forKey: .liked)) ?? nil
        commented = (try? v.decodeIfPresent(Int.self, forKey: .commented)) ?? nil
        collected = (try? v.decodeIfPresent(Int.self, forKey: .collected)) ?? nil
    }

    var isLoading: Bool { status == "loading" }
    var isReady: Bool { status == "ok" }
    var link: URL? { URL(string: url ?? "") }
}

struct MessageAskAnswer: Decodable, Hashable {
    let kind: String
    let index: Int?
    let text: String
}

struct MessageAsk: Decodable, Hashable {
    let question: String
    let options: [String]
    var answer: MessageAskAnswer?
    var answeredAt: String?

    enum CodingKeys: String, CodingKey {
        case question, options, answer
        case answeredAt = "answered_at"
    }
}

/// 「给你看一眼」——我发起的屏幕共享请求，她按确认才会开始录屏。
/// status: pending 等她按 / accepted 票据已发、等系统面板 / delivered 画面到了 /
/// declined 她说现在不行 / expired 这次没成（reason 说是哪种没成）。
struct MessagePeek: Decodable, Hashable {
    var note: String
    var status: String
    var reason: String?
    var expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case note, status, reason
        case expiresAt = "expires_at"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        note = (try? values.decode(String.self, forKey: .note)) ?? ""
        status = (try? values.decode(String.self, forKey: .status)) ?? "pending"
        reason = try? values.decode(String.self, forKey: .reason)
        expiresAt = try? values.decode(String.self, forKey: .expiresAt)
    }

    var isOpen: Bool { status == "pending" || status == "accepted" }
}

struct MessageAlbumEntry: Decodable, Hashable, Identifiable {
    let albumID: Int?
    let url: String
    let title: String
    let note: String

    var id: String { albumID.map { "album-\($0)" } ?? "\(url)#\(title)" }

    enum CodingKeys: String, CodingKey {
        case id, url, title, note
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        albumID = try values.decodeIfPresent(Int.self, forKey: .id)
        url = try values.decodeIfPresent(String.self, forKey: .url) ?? ""
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
        note = try values.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
}

struct MessageMeta: Decodable, Hashable {
    var attachments: [Attachment]
    var reactions: [String: String]
    var hidden: Bool
    var apiSession: String?
    var api: APIMessageUsage?
    var streamID: String?
    var sortAfter: Int?
    var starred: String?
    var timer: MessageTimer?
    var ask: MessageAsk?
    var peek: MessagePeek?
    var edited: Bool
    var glyph: String?
    var steps: [ToolStep]
    var bookRef: BookRef?
    var callStatus: String?
    var album: [MessageAlbumEntry]
    /// 这轮自动浮起了几条旧记忆（relay 的 recall 挂上来的）。思维卡拿它显示一行提示。
    var recalled: Int?
    /// 按需生成并由 relay 缓存的可见文本译文，键为 BCP-47 语言标签。
    var translations: [String: String]
    /// 她这条消息里那条小红书链接展开出来的笔记。
    var xhs: XHSCard?
    /// 统一回复模式下，这条消息属于哪一批；消息本身仍然独立落库、独立显示。
    var replyBundleID: String?
    /// true 表示这条已发到聊天页，但还没有放行给 AI。
    var replyDeferred: Bool

    enum CodingKeys: String, CodingKey {
        case attachments, api
        case reactions
        case hidden
        case apiSession = "api_session"
        case streamID = "stream_id"
        case sortAfter = "sort_after"
        case bookRef = "book_ref"
        case callStatus = "call_status"
        case replyBundleID = "reply_bundle_id"
        case replyDeferred = "reply_deferred"
        case starred, timer, ask, peek, edited, glyph, steps, act, album, recalled, translations, xhs
    }

    init(
        attachments: [Attachment] = [],
        reactions: [String: String] = [:],
        hidden: Bool = false,
        apiSession: String? = nil,
        streamID: String? = nil,
        sortAfter: Int? = nil
    ) {
        self.attachments = attachments
        self.reactions = reactions
        self.hidden = hidden
        self.apiSession = apiSession
        self.api = nil
        self.streamID = streamID
        self.sortAfter = sortAfter
        self.starred = nil
        self.timer = nil
        self.ask = nil
        self.peek = nil
        self.edited = false
        self.glyph = nil
        self.steps = []
        self.bookRef = nil
        self.callStatus = nil
        self.album = []
        self.recalled = nil
        self.translations = [:]
        self.xhs = nil
        self.replyBundleID = nil
        self.replyDeferred = false
    }

    /// meta 是个松散口袋，relay 侧偶尔会往同名键塞别的形状（2026-08-21：hidden 的
    /// timer-event 帧把 meta.timer 写成了字符串 "event"）。严格解码会让**整段**
    /// history 抛 typeMismatch → App 只剩「数据格式不正确」。所以这些结构化字段
    /// 一律容错：形状不对就当没有，别连累同一批的其它消息。
    private static func lenient<T: Decodable>(
        _ type: T.Type,
        _ values: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> T? {
        (try? values.decodeIfPresent(type, forKey: key)) ?? nil
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        attachments = Self.lenient([Attachment].self, values, .attachments) ?? []
        reactions = Self.lenient([String: String].self, values, .reactions) ?? [:]
        hidden = Self.lenient(Bool.self, values, .hidden) ?? false
        apiSession = Self.lenient(String.self, values, .apiSession)
        api = Self.lenient(APIMessageUsage.self, values, .api)
        if api == nil {
            let legacyAPI = try? APIMessageUsage(from: decoder)
            if legacyAPI?.runtime == "api_loop" { api = legacyAPI }
        }
        streamID = Self.lenient(String.self, values, .streamID)
        sortAfter = Self.lenient(Int.self, values, .sortAfter)
        starred = Self.lenient(String.self, values, .starred)
        timer = Self.lenient(MessageTimer.self, values, .timer)
        ask = Self.lenient(MessageAsk.self, values, .ask)
        peek = Self.lenient(MessagePeek.self, values, .peek)
        edited = Self.lenient(Bool.self, values, .edited) ?? false
        bookRef = Self.lenient(BookRef.self, values, .bookRef)
        callStatus = Self.lenient(String.self, values, .callStatus)
        album = Self.lenient([MessageAlbumEntry].self, values, .album) ?? []
        recalled = Self.lenient(Int.self, values, .recalled)
        translations = Self.lenient([String: String].self, values, .translations) ?? [:]
        xhs = Self.lenient(XHSCard.self, values, .xhs)
        replyBundleID = Self.lenient(String.self, values, .replyBundleID)
        replyDeferred = Self.lenient(Bool.self, values, .replyDeferred) ?? false
        let nestedAct = Self.lenient(ActMeta.self, values, .act)
        glyph = Self.lenient(String.self, values, .glyph) ?? nestedAct?.glyph
        steps = Self.lenient([ToolStep].self, values, .steps) ?? nestedAct?.steps ?? []
    }
}

struct ChatMessage: Decodable, Hashable, Identifiable {
    var id: Int
    var timestamp: String
    var author: MessageAuthor
    var kind: String
    var text: String
    var meta: MessageMeta
    var delivery: DeliveryState

    enum CodingKeys: String, CodingKey {
        case id
        case timestamp = "ts"
        case author = "from"
        case kind
        case text
        case meta
    }

    init(
        id: Int,
        timestamp: String,
        author: MessageAuthor,
        kind: String,
        text: String,
        meta: MessageMeta = MessageMeta(),
        delivery: DeliveryState = .sent
    ) {
        self.id = id
        self.timestamp = timestamp
        self.author = author
        self.kind = kind
        self.text = text
        self.meta = meta
        self.delivery = delivery
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int.self, forKey: .id)
        timestamp = try values.decode(String.self, forKey: .timestamp)
        author = try values.decode(MessageAuthor.self, forKey: .author)
        kind = try values.decodeIfPresent(String.self, forKey: .kind) ?? "reply"
        text = try values.decodeIfPresent(String.self, forKey: .text) ?? ""
        meta = try values.decodeIfPresent(MessageMeta.self, forKey: .meta) ?? MessageMeta()
        delivery = .sent
    }
}

struct HistoryResponse: Decodable {
    let messages: [ChatMessage]
}

struct APISession: Codable, Hashable, Identifiable {
    let id: String
    var title: String
    let body: BrainTarget
    let sinceID: Int
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, title, body
        case sinceID = "since_id"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? "新对话"
        body = try values.decodeIfPresent(BrainTarget.self, forKey: .body) ?? .loop
        sinceID = try values.decodeIfPresent(Int.self, forKey: .sinceID) ?? 0
        createdAt = try values.decodeIfPresent(String.self, forKey: .createdAt)
    }
}

struct SessionsResponse: Decodable {
    let activeSession: String?
    let sessions: [APISession]
    let created: APISession?

    enum CodingKeys: String, CodingKey {
        case sessions, created
        case activeSession = "active_session"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        activeSession = try values.decodeIfPresent(String.self, forKey: .activeSession)
        sessions = try values.decodeIfPresent([APISession].self, forKey: .sessions) ?? []
        created = try values.decodeIfPresent(APISession.self, forKey: .created)
    }
}

struct SearchResponse: Decodable {
    let results: [ChatMessage]
}

struct ReactionResponse: Decodable {
    let reactions: [String: String]
}

struct TimerResponse: Decodable {
    let timer: MessageTimer
}

struct AskResponse: Decodable {
    let ask: MessageAsk
}

struct PeekResponse: Decodable {
    let peek: MessagePeek
}

struct MessageNavigationRequest: Equatable {
    let token = UUID()
    let messageID: Int
}

struct SendResponse: Decodable {
    let id: Int
}

struct BundleReleaseResponse: Decodable {
    let id: Int
    let released: Int
}

struct VoiceResponse: Decodable {
    let id: Int
    let text: String?
    let attachment: Attachment?
}

struct StreamEnvelope: Decodable {
    let type: String?
    let active: Bool?
    let id: Int?
    let reactions: [String: String]?
    let streamID: String?
    let text: String?
    let done: Bool?
    let timestamp: String?
    let starred: String?
    let apiSession: String?
    let timer: MessageTimer?
    let ask: MessageAsk?
    let peek: MessagePeek?
    let post: MomentPost?
    let bookID: Int?
    let annotation: BookAnnotation?

    enum CodingKeys: String, CodingKey {
        case type, active, id, reactions, text, done, starred, timer, ask, peek, post, annotation
        case streamID = "stream_id"
        case timestamp = "ts"
        case apiSession = "api_session"
        case bookID = "book_id"
    }
}

struct ClawdPetState: Decodable, Equatable {
    let sid: String?
    let state: String
    let event: String?
    let toolName: String?
    let sessionTitle: String?
    let timestamp: String?

    static let idle = ClawdPetState(
        sid: nil,
        state: "idle",
        event: nil,
        toolName: nil,
        sessionTitle: nil,
        timestamp: nil
    )

    enum CodingKeys: String, CodingKey {
        case sid, state, event
        case toolName = "tool_name"
        case sessionTitle = "session_title"
        case timestamp = "ts"
    }

    var assetFilename: String {
        switch state {
        case "thinking": return "clawd-thinking.gif"
        case "working": return "clawd-typing.gif"
        case "juggling": return "clawd-juggling.gif"
        case "sweeping": return "clawd-sweeping.gif"
        case "error": return "clawd-error.gif"
        case "notification": return "clawd-notification.gif"
        case "carrying": return "clawd-carrying.gif"
        case "sleeping": return "clawd-sleeping.gif"
        default: return "clawd-idle.gif"
        }
    }

    var localizedLabel: String {
        switch state {
        case "thinking": return "在想"
        case "working": return "在敲"
        case "juggling": return "多线程"
        case "sweeping": return "清上下文"
        case "error": return "出错了"
        case "attention": return "等你"
        case "notification": return "有提示"
        case "carrying": return "搬东西"
        case "sleeping": return "睡了"
        default: return "闲着"
        }
    }

    var statusText: String {
        [localizedLabel, toolName, sessionTitle]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " · ")
    }
}

enum BrainTarget: String, Codable, CaseIterable, Identifiable {
    case desktop
    case codex
    case loop

    var id: String { rawValue }
    var title: String {
        switch self {
        case .desktop: return "Desktop"
        case .codex: return "Codex"
        case .loop: return "API"
        }
    }
}

struct BrainResponse: Decodable {
    let target: BrainTarget
}

struct LoopRoute: Codable {
    var index: Int?
    var url: String?
    var model: String?
}

struct LoopConfigResponse: Decodable {
    let mainChain: [LoopRoute]
    let apiPresets: [APIPreset]
    /// output_config.effort：API 身体的思考力度。旧版 relay 不吐这两个字段，按默认档走。
    let effort: String
    let effortLevels: [String]
    let prices: APIUsagePrices
    let cacheTTL: String

    enum CodingKeys: String, CodingKey {
        case mainChain = "main_chain"
        case apiPresets = "api_presets"
        case effort
        case effortLevels = "effort_levels"
        case prices
        case cacheTTL = "cache_ttl"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mainChain = try values.decodeIfPresent([LoopRoute].self, forKey: .mainChain) ?? []
        apiPresets = try values.decodeIfPresent([APIPreset].self, forKey: .apiPresets) ?? []
        effort = try values.decodeIfPresent(String.self, forKey: .effort) ?? "high"
        effortLevels = try values.decodeIfPresent([String].self, forKey: .effortLevels)
            ?? ["low", "medium", "high", "xhigh", "max"]
        prices = (try? values.decode(APIUsagePrices.self, forKey: .prices)) ?? APIUsagePrices()
        cacheTTL = (try? values.decode(String.self, forKey: .cacheTTL)) ?? "5m"
    }
}

struct APIPreset: Codable, Identifiable {
    let index: Int
    let name: String
    let url: String
    let model: String
    let keyMasked: String
    let active: Bool

    var id: Int { index }

    enum CodingKeys: String, CodingKey {
        case index, name, url, model, active
        case keyMasked = "key_masked"
    }
}

struct APIPresetInput: Encodable {
    let name: String
    let url: String
    let key: String
    let model: String
}

enum ChatMode: String, Codable, CaseIterable, Identifiable {
    case long
    case short
    var id: String { rawValue }
    var title: String { self == .long ? "长聊" : "短聊" }
}

struct ChatModeResponse: Decodable {
    let mode: ChatMode
    let stripTerminalPeriods: Bool

    enum CodingKeys: String, CodingKey {
        case mode
        case stripTerminalPeriods = "strip_terminal_periods"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decode(ChatMode.self, forKey: .mode)
        stripTerminalPeriods = try values.decodeIfPresent(Bool.self, forKey: .stripTerminalPeriods) ?? false
    }
}

indirect enum JSONValue: Decodable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let object = try? value.decode([String: JSONValue].self) { self = .object(object) }
        else if let array = try? value.decode([JSONValue].self) { self = .array(array) }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else { self = .null }
    }
}

struct QuotaResponse: Decodable {
    let raw: JSONValue
}

struct CodexQuotaResponse: Decodable {
    let ok: Bool
    let raw: JSONValue?
    let updatedAt: String?
    let ageSeconds: Double?
    let online: Bool?

    enum CodingKeys: String, CodingKey {
        case ok, raw, online
        case updatedAt = "updated_at"
        case ageSeconds = "age_seconds"
    }
}

/// 终端页：relay 把某个身体的 transcript 重建成"终端画面"后的一帧。
/// 后端逻辑在 backend/tgterm.py，端点 `/app/tgterm/tail`。
struct TerminalEvent: Decodable {
    let t: String
    let ts: String?
    let text: String?
    let name: String?
    let brief: String?
    let said: String?
    let hidden: Int?
    let isError: Bool?
    let source: String?

    enum CodingKeys: String, CodingKey {
        case t, ts, text, name, brief, said, hidden, source
        case isError = "is_error"
    }
}

struct TerminalStatus: Decodable {
    let model: String?
    let ctx: Int?
    let limit: Int?
    let pct: Double?
    let sid: String?
}

struct TerminalTailResponse: Decodable {
    let body: String?
    let alive: Bool?
    let events: [TerminalEvent]
    let offset: Int
    let size: Int?
    let dropped: Bool?
    let status: TerminalStatus?
}

struct APIUsageNumbers: Decodable {
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int
    let costUSD: Double?

    enum CodingKeys: String, CodingKey {
        case input, output
        case cacheRead = "cache_read"
        case cacheWrite = "cache_write"
        case costUSD = "cost_usd"
    }
}

struct APIKeepaliveStats: Decodable {
    let beats: Int
    let costUSD: Double
    let badCount: Int

    enum CodingKeys: String, CodingKey {
        case beats
        case costUSD = "cost_usd"
        case badCount = "bad_count"
    }
}

struct APIUsageEntry: Decodable, Identifiable {
    let id: Int
    let timestamp: String
    let model: String?
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int
    let costUSD: Double
    /// true = 上游报的实际花费（OpenRouter 每条都报）；false = 本地价目表估的
    let billed: Bool

    enum CodingKeys: String, CodingKey {
        case id, model, input, output, billed
        case timestamp = "ts"
        case cacheRead = "cache_read"
        case cacheWrite = "cache_write"
        case costUSD = "cost_usd"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int.self, forKey: .id)
        timestamp = try values.decode(String.self, forKey: .timestamp)
        model = try values.decodeIfPresent(String.self, forKey: .model)
        input = try values.decodeIfPresent(Int.self, forKey: .input) ?? 0
        output = try values.decodeIfPresent(Int.self, forKey: .output) ?? 0
        cacheRead = try values.decodeIfPresent(Int.self, forKey: .cacheRead) ?? 0
        cacheWrite = try values.decodeIfPresent(Int.self, forKey: .cacheWrite) ?? 0
        costUSD = try values.decodeIfPresent(Double.self, forKey: .costUSD) ?? 0
        billed = try values.decodeIfPresent(Bool.self, forKey: .billed) ?? false
    }

    var cacheHitRate: Double? {
        let denominator = input + cacheRead + cacheWrite
        guard denominator > 0 else { return nil }
        return Double(cacheRead) / Double(denominator)
    }
}

struct APIUsageStats: Decodable {
    let messages: Int
    let total: APIUsageNumbers
    let totalCostUSD: Double
    let average: APIUsageNumbers
    let cacheHitRate: Double
    let keepalive: APIKeepaliveStats
    let cacheTTL: String
    let recent: [APIUsageEntry]
    /// 这批里有几条用的是上游实报金额，其余是本地估算
    let billedRows: Int

    enum CodingKeys: String, CodingKey {
        case messages, total, keepalive, recent
        case totalCostUSD = "total_cost_usd"
        case average = "avg_per_message"
        case cacheHitRate = "cache_hit_rate"
        case cacheTTL = "cache_ttl"
        case billedRows = "billed_rows"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        messages = try values.decodeIfPresent(Int.self, forKey: .messages) ?? 0
        total = try values.decode(APIUsageNumbers.self, forKey: .total)
        totalCostUSD = try values.decodeIfPresent(Double.self, forKey: .totalCostUSD) ?? 0
        average = try values.decode(APIUsageNumbers.self, forKey: .average)
        cacheHitRate = try values.decodeIfPresent(Double.self, forKey: .cacheHitRate) ?? 0
        keepalive = try values.decode(APIKeepaliveStats.self, forKey: .keepalive)
        cacheTTL = try values.decodeIfPresent(String.self, forKey: .cacheTTL) ?? "?"
        recent = try values.decodeIfPresent([APIUsageEntry].self, forKey: .recent) ?? []
        billedRows = try values.decodeIfPresent(Int.self, forKey: .billedRows) ?? 0
    }
}

struct StarsResponse: Decodable { let stars: [ChatMessage] }

struct StarResponse: Decodable {
    let starred: String?
}

struct AlbumPhoto: Decodable, Identifiable {
    let albumID: Int?
    let url: String
    let timestamp: String
    let keptAt: String
    let title: String
    let note: String
    let author: MessageAuthor?
    var id: String { albumID.map { "album-\($0)" } ?? "\(timestamp)#\(url)" }

    enum CodingKeys: String, CodingKey {
        case id, url, title, note
        case timestamp = "ts"
        case keptAt = "kept_at"
        case author = "from"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        albumID = try values.decodeIfPresent(Int.self, forKey: .id)
        url = try values.decode(String.self, forKey: .url)
        timestamp = try values.decodeIfPresent(String.self, forKey: .timestamp) ?? ""
        keptAt = try values.decodeIfPresent(String.self, forKey: .keptAt) ?? timestamp
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? ""
        note = try values.decodeIfPresent(String.self, forKey: .note) ?? ""
        author = try values.decodeIfPresent(MessageAuthor.self, forKey: .author)
    }
}

struct AlbumResponse: Decodable { let photos: [AlbumPhoto] }

struct GiftPage: Decodable, Identifiable {
    let file: String
    let title: String
    let modified: String
    var id: String { file }

    enum CodingKeys: String, CodingKey {
        case file, title
        case modified = "mtime"
    }
}

struct GiftPagesResponse: Decodable { let pages: [GiftPage] }

struct GreetingPool: Codable {
    let slots: [String: [String]]
}

struct DesireThought: Decodable, Identifiable {
    let text: String
    let drive: String
    let kind: String
    let strength: Double
    let bornAt: Double?

    var id: String { "\(kind)#\(drive)#\(text)" }

    enum CodingKeys: String, CodingKey {
        case text, drive, kind, strength
        case bornAt = "born_at"
    }
}

struct DesireIntent: Decodable {
    let wantAction: String?
    let driveKey: String?
    let reason: String
    let score: Double?

    enum CodingKeys: String, CodingKey {
        case reason, score
        case wantAction = "want_action"
        case driveKey = "drive_key"
    }
}

struct DesireActivity: Decodable {
    let enabled: Bool
    let libidoMultiplier: Double
    let cooldownLeftSeconds: Int
    let today: Int
    let dailyCap: Int
    let bodyTarget: String
    let bodyOnline: Bool

    enum CodingKeys: String, CodingKey {
        case enabled, today
        case libidoMultiplier = "libido_mult"
        case cooldownLeftSeconds = "cooldown_left_sec"
        case dailyCap = "daily_cap"
        case bodyTarget = "body_target"
        case bodyOnline = "body_online"
    }
}

struct DesireState: Decodable {
    let drive: [String: Double]
    let intent: DesireIntent
    let thoughts: [DesireThought]
    let activity: DesireActivity

    enum CodingKeys: String, CodingKey {
        case drive, intent, thoughts
        case activity = "act"
    }
}

enum MomentKind: String, Codable, CaseIterable, Identifiable {
    case moment
    case journal
    var id: String { rawValue }
    var title: String { self == .moment ? "动态" : "日志" }
}

struct MomentComment: Codable, Identifiable, Hashable {
    let id: Int
    let timestamp: String
    let author: MessageAuthor
    let text: String
    let replyTo: MessageAuthor?

    enum CodingKeys: String, CodingKey {
        case id, author, text
        case timestamp = "ts"
        case replyTo = "reply_to"
    }
}

struct MomentMeta: Decodable, Hashable {
    let attachments: [Attachment]
    var likes: [String: String]
    var comments: [MomentComment]

    enum CodingKeys: String, CodingKey { case attachments, likes, comments }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        attachments = try values.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        likes = try values.decodeIfPresent([String: String].self, forKey: .likes) ?? [:]
        comments = try values.decodeIfPresent([MomentComment].self, forKey: .comments) ?? []
    }
}

struct MomentPost: Decodable, Identifiable, Hashable {
    let id: Int
    let timestamp: String
    let author: MessageAuthor
    let kind: MomentKind
    let text: String
    var meta: MomentMeta

    enum CodingKeys: String, CodingKey {
        case id, author, kind, text, meta
        case timestamp = "ts"
    }
}

struct MomentsResponse: Decodable {
    let posts: [MomentPost]
    let hasMore: Bool
    enum CodingKeys: String, CodingKey {
        case posts
        case hasMore = "has_more"
    }
}

struct MomentPostResponse: Decodable { let post: MomentPost }
struct MomentLikeResponse: Decodable { let likes: [String: String] }
struct MomentCommentResponse: Decodable { let comment: MomentComment }

struct CalendarEvent: Decodable, Identifiable, Hashable {
    let id: Int
    let date: String
    let time: String
    let title: String
    let kind: String
    let visible: Bool
    let author: MessageAuthor
    let recurrence: String
    let remind: Bool
    let daysSince: Int?
    let years: Int?

    enum CodingKeys: String, CodingKey {
        case id, date, time, title, kind, visible, author, remind, years
        case recurrence = "recur"
        case daysSince = "days_since"
    }
}

struct CalendarMonthResponse: Decodable {
    let year: Int
    let month: Int
    let today: String
    let events: [CalendarEvent]
    let holidays: [String: String]
}

struct AnniversarySummary: Decodable, Hashable {
    let id: Int
    let title: String
    let startDate: String
    let daysSince: Int

    enum CodingKeys: String, CodingKey {
        case id, title
        case startDate = "start_date"
        case daysSince = "days_since"
    }
}

struct AnniversaryResponse: Decodable {
    let anniversary: AnniversarySummary?
}

struct DesktopModelResponse: Decodable {
    let model: String
    let applied: Bool?
    let note: String?
}

struct ContextPending: Decodable {
    let newSID: String

    enum CodingKeys: String, CodingKey {
        case newSID = "new_sid"
    }
}

struct ContextStatus: Decodable {
    let ok: Bool
    let usageTokens: Int
    let thresholdText: String
    let triggerK: Int
    let auto: Bool
    let activeSID: String
    let pending: ContextPending?
    let forgeRounds: Int?
    let forgePhase: String?

    enum CodingKeys: String, CodingKey {
        case ok, auto, pending
        case usageTokens = "usage_tokens"
        case thresholdText = "threshold_k"
        case triggerK = "trigger_k"
        case activeSID = "active_sid"
        case forgeRounds = "forge_rounds"
        case forgePhase = "forge_phase"
    }
}

struct ContextThresholdResponse: Decodable {
    let triggerK: Int
    let auto: Bool
    let forgeRounds: Int?

    enum CodingKeys: String, CodingKey {
        case auto
        case triggerK = "trigger_k"
        case forgeRounds = "forge_rounds"
    }
}

/// 过隧道预览:保留 N 轮大概多少 token、从哪句开始(GET app/forge?rounds=N)。
struct ForgePreview: Decodable {
    let roundsTotal: Int
    let roundsKept: Int
    let estTokens: Int
    let firstTS: String?
    let firstMsg: String?

    enum CodingKeys: String, CodingKey {
        case roundsTotal = "rounds_total"
        case roundsKept = "rounds_kept"
        case estTokens = "est_tokens"
        case firstTS = "first_ts"
        case firstMsg = "first_msg"
    }
}

struct ForgeStatus: Decodable {
    let rounds: Int
    let phase: String?
    let preview: ForgePreview?
}

struct DesktopKeepaliveConfig: Decodable {
    let keepalive: Bool
}

struct DesktopKeepaliveStatus: Decodable {
    let ok: Bool
    let config: DesktopKeepaliveConfig
    let nextAt: String?
    let lastFireAt: String?
    let today: Int
    let brain: String

    enum CodingKeys: String, CodingKey {
        case ok, config, today, brain
        case nextAt = "next_at"
        case lastFireAt = "last_fire_at"
    }
}

struct ContextActionResponse: Decodable {
    let ok: Bool
    let action: String
}
