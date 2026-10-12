import Foundation

struct APIClient {
    let baseURL: URL
    let secret: String

    func history(since: Int, limit: Int = 500, sessionID: String? = nil) async throws -> [ChatMessage] {
        var components = URLComponents(url: endpoint("app/history"), resolvingAgainstBaseURL: false)
        var queryItems = [
            URLQueryItem(name: "since", value: String(since)),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        if let sessionID, !sessionID.isEmpty {
            queryItems.append(URLQueryItem(name: "session_id", value: sessionID))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else { throw APIError.invalidURL }
        let data = try await data(for: request(url: url))
        return try decoder.decode(HistoryResponse.self, from: data).messages
    }

    /// 最新的 `limit` 条（before > 0 时是 id < before 的最新 `limit` 条），旧→新。
    /// 开屏只拉这一页；原样的响应体一并交回去当本地缓存。
    func recentHistory(before: Int = 0, limit: Int, sessionID: String? = nil) async throws -> (messages: [ChatMessage], raw: Data) {
        var components = URLComponents(url: endpoint("app/history"), resolvingAgainstBaseURL: false)
        var queryItems = [
            URLQueryItem(name: "tail", value: "1"),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        if before > 0 {
            queryItems.append(URLQueryItem(name: "before", value: String(before)))
        }
        if let sessionID, !sessionID.isEmpty {
            queryItems.append(URLQueryItem(name: "session_id", value: sessionID))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else { throw APIError.invalidURL }
        let data = try await data(for: request(url: url))
        return (try decoder.decode(HistoryResponse.self, from: data).messages, data)
    }

    static func decodeHistory(_ data: Data) throws -> [ChatMessage] {
        try JSONDecoder().decode(HistoryResponse.self, from: data).messages
    }

    func send(
        text: String,
        attachments: [Attachment],
        sessionID: String? = nil,
        deferReply: Bool = false,
        bundleID: String? = nil
    ) async throws -> SendResponse {
        var req = request(url: endpoint("app/send"), method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(
            SendPayload(
                text: text,
                attachments: attachments,
                apiSession: sessionID,
                deferReply: deferReply,
                bundleID: bundleID
            )
        )
        let responseData = try await data(for: req)
        return try decoder.decode(SendResponse.self, from: responseData)
    }

    func releaseReplyBundle(
        bundleID: String,
        messageIDs: [Int],
        sessionID: String? = nil
    ) async throws -> BundleReleaseResponse {
        var req = request(url: endpoint("app/send/bundle"), method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(
            BundleReleasePayload(bundleID: bundleID, messageIDs: messageIDs, apiSession: sessionID)
        )
        return try decoder.decode(BundleReleaseResponse.self, from: try await data(for: req))
    }

    func search(_ query: String, limit: Int = 80) async throws -> [ChatMessage] {
        var components = URLComponents(url: endpoint("app/search"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        guard let url = components?.url else { throw APIError.invalidURL }
        return try decoder.decode(SearchResponse.self, from: try await data(for: request(url: url))).results
    }

    func sessions() async throws -> SessionsResponse {
        try decoder.decode(SessionsResponse.self, from: try await data(for: request(url: endpoint("app/sessions"))))
    }

    func createSession(title: String, body: BrainTarget) async throws -> SessionsResponse {
        var req = request(url: endpoint("app/sessions"), method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(SessionCreatePayload(title: title, body: body, activate: true))
        return try decoder.decode(SessionsResponse.self, from: try await data(for: req))
    }

    func updateSession(id: String, title: String? = nil, active: Bool? = nil) async throws -> SessionsResponse {
        var req = request(url: endpoint("app/sessions/\(id)"), method: "PATCH")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(SessionUpdatePayload(title: title, active: active))
        return try decoder.decode(SessionsResponse.self, from: try await data(for: req))
    }

    func deleteSession(id: String) async throws -> SessionsResponse {
        try decoder.decode(
            SessionsResponse.self,
            from: try await data(for: request(url: endpoint("app/sessions/\(id)"), method: "DELETE"))
        )
    }

    func editMessage(id: Int, text: String) async throws -> ChatMessage {
        var req = request(url: endpoint("app/message/\(id)/edit"), method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(MessageEditPayload(text: text))
        return try decoder.decode(ChatMessage.self, from: try await data(for: req))
    }

    func regenerateMessage(id: Int) async throws {
        _ = try await data(for: request(url: endpoint("app/message/\(id)/regen"), method: "POST"))
    }

    func reactToMessage(id: Int, emoji: String) async throws -> [String: String] {
        var req = request(url: endpoint("app/message/\(id)/reaction"), method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(ReactionPayload(emoji: emoji))
        return try decoder.decode(ReactionResponse.self, from: try await data(for: req)).reactions
    }

    func translateThinking(messageID: Int) async throws -> String {
        var req = request(url: endpoint("app/message/\(messageID)/translation"), method: "POST")
        req.timeoutInterval = 130
        return try decoder.decode(
            ThinkingTranslationResponse.self,
            from: try await data(for: req)
        ).translation
    }

    func completeTimer(messageID: Int) async throws -> MessageTimer {
        let req = request(url: endpoint("app/timer/\(messageID)/done"), method: "POST")
        return try decoder.decode(TimerResponse.self, from: try await data(for: req)).timer
    }

    func upload(data: Data, name: String, mime: String) async throws -> Attachment {
        var components = URLComponents(url: endpoint("app/upload"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "name", value: name)]
        guard let url = components?.url else { throw APIError.invalidURL }
        var req = request(url: url, method: "POST")
        req.setValue(mime, forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        let responseData = try await self.data(for: req)
        return try decoder.decode(Attachment.self, from: responseData)
    }

    func prepareScreenShare(sessionID: String? = nil) async throws -> ScreenSharePreparation {
        let probeMarker = UUID().uuidString
        var req = request(url: endpoint("app/screen-share/session"), method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(
            ScreenShareSessionPayload(apiSession: sessionID, appGroupProbe: probeMarker)
        )
        let response = try decoder.decode(
            ScreenShareSessionResponse.self,
            from: try await data(for: req)
        )
        return try await publishScreenShareHandoff(response, probeMarker: probeMarker)
    }

    /// 领到票据之后的那半程：把交接单挂上本机端口，等录屏扩展来取。
    /// 自助共享和「给你看一眼」卡走的是同一段，区别只在票据从哪个端点签出来。
    private func publishScreenShareHandoff(
        _ response: ScreenShareSessionResponse,
        probeMarker: String
    ) async throws -> ScreenSharePreparation {
        let handoff = ScreenShareHandoffPayload(
            version: 1,
            relayURL: baseURL.absoluteString,
            ticket: response.ticket,
            expiresAt: response.expiresAt,
            probeMarker: probeMarker
        )
        guard let payloadData = try? JSONEncoder().encode(handoff),
              let handoffPayload = String(data: payloadData, encoding: .utf8) else {
            throw APIError.invalidResponse
        }
        let localHandoff = await ScreenShareLocalHandoff.publish(
            handoffPayload,
            expiresIn: response.expiresIn
        )
        return ScreenSharePreparation(
            expiresAt: response.expiresAt,
            expiresIn: response.expiresIn,
            probeID: response.probeID,
            localHandoffReady: localHandoff.isReady,
            localHandoffDiagnostic: localHandoff.diagnostic
        )
    }

    /// 她在卡上按了「给你看」：同一次调用里签票据、挂本机交接，
    /// 回到 UI 就能直接开系统广播面板。
    func acceptPeek(messageID: Int) async throws -> ScreenSharePreparation {
        let probeMarker = UUID().uuidString
        var req = request(url: endpoint("app/peek/\(messageID)/accept"), method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(
            ScreenShareSessionPayload(apiSession: nil, appGroupProbe: probeMarker)
        )
        let response = try decoder.decode(
            ScreenShareSessionResponse.self,
            from: try await data(for: req)
        )
        return try await publishScreenShareHandoff(response, probeMarker: probeMarker)
    }

    /// 她按了「现在不行」。
    func declinePeek(messageID: Int) async throws -> MessagePeek {
        let req = request(url: endpoint("app/peek/\(messageID)/decline"), method: "POST")
        return try decoder.decode(PeekResponse.self, from: try await data(for: req)).peek
    }

    func screenShareProbeStatus(probeID: String) async throws -> ScreenShareProbeStatus {
        try decoder.decode(
            ScreenShareProbeStatus.self,
            from: try await data(for: request(url: endpoint("app/screen-share/probe/\(probeID)")))
        )
    }

    /// `text` 是手机端现场转好的字。带上它，服务器就不用再转一遍，
    /// 耳朵那边只听语气（快得多），这段录音也会挂在她自己的气泡上。
    func sendVoiceAudio(
        data: Data,
        name: String,
        mime: String,
        callID: String? = nil,
        text: String? = nil,
        sessionID: String? = nil
    ) async throws -> VoiceResponse {
        var components = URLComponents(url: endpoint("app/voice"), resolvingAgainstBaseURL: false)
        var query = [URLQueryItem(name: "name", value: name)]
        if let callID, !callID.isEmpty { query.append(URLQueryItem(name: "call_id", value: callID)) }
        if let text, !text.isEmpty { query.append(URLQueryItem(name: "text", value: text)) }
        if let sessionID, !sessionID.isEmpty { query.append(URLQueryItem(name: "api_session", value: sessionID)) }
        components?.queryItems = query
        guard let url = components?.url else { throw APIError.invalidURL }
        var req = request(url: url, method: "POST")
        req.setValue(mime, forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        return try decoder.decode(VoiceResponse.self, from: try await self.data(for: req))
    }

    func sendVoiceText(
        _ text: String,
        source: String = "ios_speech",
        callID: String? = nil,
        sessionID: String? = nil
    ) async throws -> VoiceResponse {
        var req = request(url: endpoint("app/voice"), method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(
            VoiceTextPayload(text: text, source: source, callID: callID, apiSession: sessionID)
        )
        return try decoder.decode(VoiceResponse.self, from: try await data(for: req))
    }

    func callEvent(
        _ action: String,
        callID: String,
        messageID: Int? = nil,
        sessionID: String? = nil
    ) async throws -> SendResponse {
        var req = request(url: endpoint("app/call"), method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(
            CallPayload(action: action, callID: callID, messageID: messageID, apiSession: sessionID)
        )
        return try decoder.decode(SendResponse.self, from: try await data(for: req))
    }

    func tts(text: String, messageID: Int? = nil, persist: Bool = false) async throws -> Data {
        var req = request(url: endpoint("app/tts"), method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(TTSPayload(text: text, messageID: messageID, persist: persist))
        return try await data(for: req)
    }

    func ping() async throws {
        let req = request(url: endpoint("app/ping"), method: "POST")
        _ = try await data(for: req)
    }

    func brain() async throws -> BrainTarget {
        let responseData = try await data(for: request(url: endpoint("app/brain")))
        return try decoder.decode(BrainResponse.self, from: responseData).target
    }

    func setBrain(_ target: BrainTarget) async throws -> BrainTarget {
        var req = request(url: endpoint("app/brain"), method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(BrainPayload(target: target))
        let responseData = try await data(for: req)
        return try decoder.decode(BrainResponse.self, from: responseData).target
    }

    func loopConfig() async throws -> LoopConfigResponse {
        let responseData = try await data(for: request(url: endpoint("app/loop_config")))
        return try decoder.decode(LoopConfigResponse.self, from: responseData)
    }

    func setLoopModel(_ model: String, chainCount: Int) async throws -> LoopConfigResponse {
        var req = request(url: endpoint("app/loop_config"), method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let routes = (0..<max(1, chainCount)).map { index in
            LoopRoute(index: index, url: nil, model: index == 0 ? model : nil)
        }
        req.httpBody = try JSONEncoder().encode(LoopConfigPayload(mainChain: routes))
        let responseData = try await data(for: req)
        return try decoder.decode(LoopConfigResponse.self, from: responseData)
    }

    func activateAPIPreset(_ index: Int) async throws -> LoopConfigResponse {
        var req = request(url: endpoint("app/loop_config"), method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(LoopPresetPayload(activatePreset: index, apiPresets: nil))
        return try decoder.decode(LoopConfigResponse.self, from: try await data(for: req))
    }

    func replaceAPIPresets(_ presets: [APIPresetInput]) async throws -> LoopConfigResponse {
        var req = request(url: endpoint("app/loop_config"), method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(LoopPresetPayload(activatePreset: nil, apiPresets: presets))
        return try decoder.decode(LoopConfigResponse.self, from: try await data(for: req))
    }

    func setLoopEffort(_ effort: String) async throws -> LoopConfigResponse {
        var req = request(url: endpoint("app/loop_config"), method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(LoopEffortPayload(effort: effort))
        return try decoder.decode(LoopConfigResponse.self, from: try await data(for: req))
    }

    func chatMode() async throws -> ChatModeResponse {
        let responseData = try await data(for: request(url: endpoint("app/chat_mode")))
        return try decoder.decode(ChatModeResponse.self, from: responseData)
    }

    func setChatMode(_ mode: ChatMode) async throws -> ChatMode {
        var req = request(url: endpoint("app/chat_mode"), method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(ChatModePayload(mode: mode, stripTerminalPeriods: nil))
        return try decoder.decode(ChatModeResponse.self, from: try await data(for: req)).mode
    }

    func setShortChatStripTerminalPeriods(_ enabled: Bool, mode: ChatMode) async throws -> ChatModeResponse {
        var req = request(url: endpoint("app/chat_mode"), method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(
            ChatModePayload(mode: mode, stripTerminalPeriods: enabled)
        )
        return try decoder.decode(ChatModeResponse.self, from: try await data(for: req))
    }

    func quota() async throws -> QuotaResponse {
        try decoder.decode(QuotaResponse.self, from: try await data(for: request(url: endpoint("app/quota"))))
    }

    func codexQuota() async throws -> CodexQuotaResponse {
        try decoder.decode(CodexQuotaResponse.self, from: try await data(for: request(url: endpoint("app/codex_quota"))))
    }

    /// 终端页尾读。`after < 0` = 冷启动（服务端自适应回溯到至少含一句她的话），
    /// 否则按上一帧返回的字节偏移续读。
    func terminalTail(body: String, after: Int) async throws -> TerminalTailResponse {
        var components = URLComponents(url: endpoint("app/tgterm/tail"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "body", value: body),
            URLQueryItem(name: "after", value: String(after))
        ]
        guard let url = components?.url else { throw APIError.invalidURL }
        return try decoder.decode(TerminalTailResponse.self, from: try await data(for: request(url: url)))
    }

    func loopStats() async throws -> APIUsageStats {
        try decoder.decode(APIUsageStats.self, from: try await data(for: request(url: endpoint("app/loop_stats"))))
    }

    func stars() async throws -> [ChatMessage] {
        let responseData = try await data(for: request(url: endpoint("app/stars")))
        return try decoder.decode(StarsResponse.self, from: responseData).stars
    }

    func setStar(messageID: Int, on: Bool) async throws -> String? {
        var req = request(url: endpoint("app/star/\(messageID)"), method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(StarPayload(on: on))
        return try decoder.decode(StarResponse.self, from: try await data(for: req)).starred
    }

    func album() async throws -> [AlbumPhoto] {
        let responseData = try await data(for: request(url: endpoint("app/album")))
        return try decoder.decode(AlbumResponse.self, from: responseData).photos
    }

    func giftPages() async throws -> [GiftPage] {
        let responseData = try await data(for: request(url: endpoint("app/pages")))
        return try decoder.decode(GiftPagesResponse.self, from: responseData).pages
    }

    func answerAsk(messageID: Int, index: Int? = nil, text: String? = nil) async throws -> MessageAsk {
        var req = request(url: endpoint("app/ask/\(messageID)/answer"), method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(AskAnswerPayload(index: index, text: text))
        return try decoder.decode(AskResponse.self, from: try await data(for: req)).ask
    }

    func greetings() async throws -> GreetingPool {
        let responseData = try await data(for: request(url: endpoint("app/greetings")))
        return try decoder.decode(GreetingPool.self, from: responseData)
    }

    func desire() async throws -> DesireState {
        let responseData = try await data(for: request(url: endpoint("app/desire")))
        return try decoder.decode(DesireState.self, from: responseData)
    }

    func updateDesire(enabled: Bool? = nil, libidoMultiplier: Double? = nil) async throws {
        var req = request(url: endpoint("app/desire/config"), method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(
            DesireConfigPayload(actEnabled: enabled, libidoMultiplier: libidoMultiplier)
        )
        _ = try await data(for: req)
    }

    func giftPageURL(file: String) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        components.path = "/chat/pages/\(file)"
        components.query = nil
        return components.url
    }

    func moments(kind: MomentKind, before: Int? = nil, limit: Int = 20) async throws -> MomentsResponse {
        var components = URLComponents(url: endpoint("app/posts"), resolvingAgainstBaseURL: false)
        var items = [
            URLQueryItem(name: "kind", value: kind.rawValue),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        if let before { items.append(URLQueryItem(name: "before", value: String(before))) }
        components?.queryItems = items
        guard let url = components?.url else { throw APIError.invalidURL }
        return try decoder.decode(MomentsResponse.self, from: try await data(for: request(url: url)))
    }

    func createMoment(kind: MomentKind, text: String, attachments: [Attachment]) async throws -> MomentPost {
        var req = request(url: endpoint("app/posts"), method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(MomentCreatePayload(author: .human, kind: kind, text: text, attachments: attachments))
        return try decoder.decode(MomentPostResponse.self, from: try await data(for: req)).post
    }

    func likeMoment(id: Int, on: Bool) async throws -> [String: String] {
        var req = request(url: endpoint("app/posts/\(id)/like"), method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(MomentLikePayload(author: .human, on: on))
        return try decoder.decode(MomentLikeResponse.self, from: try await data(for: req)).likes
    }

    func commentMoment(id: Int, text: String, replyTo: MessageAuthor? = nil) async throws -> MomentComment {
        var req = request(url: endpoint("app/posts/\(id)/comment"), method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(MomentCommentPayload(author: .human, text: text, replyTo: replyTo))
        return try decoder.decode(MomentCommentResponse.self, from: try await data(for: req)).comment
    }

    func deleteMoment(id: Int) async throws {
        var components = URLComponents(url: endpoint("app/posts/\(id)"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "author", value: "human")]
        guard let url = components?.url else { throw APIError.invalidURL }
        _ = try await data(for: request(url: url, method: "DELETE"))
    }

    func calendar(year: Int, month: Int) async throws -> CalendarMonthResponse {
        var components = URLComponents(url: endpoint("app/calendar"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "year", value: String(year)),
            URLQueryItem(name: "month", value: String(month))
        ]
        guard let url = components?.url else { throw APIError.invalidURL }
        return try decoder.decode(CalendarMonthResponse.self, from: try await data(for: request(url: url)))
    }

    func anniversary() async throws -> AnniversarySummary? {
        let req = request(url: endpoint("app/calendar/anniversary"))
        return try decoder.decode(AnniversaryResponse.self, from: try await data(for: req)).anniversary
    }

    func createCalendarEvent(_ payload: CalendarCreatePayload) async throws -> CalendarEvent {
        var req = request(url: endpoint("app/calendar"), method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(payload)
        return try decoder.decode(CalendarEvent.self, from: try await data(for: req))
    }

    func deleteCalendarEvent(id: Int) async throws {
        _ = try await data(for: request(url: endpoint("app/calendar/\(id)"), method: "DELETE"))
    }

    func desktopModel() async throws -> DesktopModelResponse {
        let responseData = try await data(for: request(url: endpoint("app/desktop_model")))
        return try decoder.decode(DesktopModelResponse.self, from: responseData)
    }

    func setDesktopModel(_ model: String) async throws -> DesktopModelResponse {
        var req = request(url: endpoint("app/desktop_model"), method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(DesktopModelPayload(model: model))
        let responseData = try await data(for: req)
        return try decoder.decode(DesktopModelResponse.self, from: responseData)
    }

    func contextStatus() async throws -> ContextStatus {
        let responseData = try await data(for: request(url: endpoint("app/context_status")))
        return try decoder.decode(ContextStatus.self, from: responseData)
    }

    func updateContextThreshold(triggerK: Int? = nil, auto: Bool? = nil, forgeRounds: Int? = nil) async throws -> ContextThresholdResponse {
        var req = request(url: endpoint("app/context_threshold"), method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(ContextThresholdPayload(triggerK: triggerK, auto: auto, forgeRounds: forgeRounds))
        let responseData = try await data(for: req)
        return try decoder.decode(ContextThresholdResponse.self, from: responseData)
    }

    func desktopKeepalive() async throws -> DesktopKeepaliveStatus {
        let responseData = try await data(for: request(url: endpoint("app/keepalive")))
        return try decoder.decode(DesktopKeepaliveStatus.self, from: responseData)
    }

    func setDesktopKeepalive(_ enabled: Bool) async throws -> DesktopKeepaliveStatus {
        var req = request(url: endpoint("app/keepalive"), method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(DesktopKeepalivePayload(keepalive: enabled))
        let responseData = try await data(for: req)
        return try decoder.decode(DesktopKeepaliveStatus.self, from: responseData)
    }

    func clawdState() async throws -> ClawdPetState {
        let responseData = try await data(for: request(url: endpoint("app/clawd_state")))
        return try decoder.decode(ClawdPetState.self, from: responseData)
    }

    func clawdAssetURL(filename: String) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        components.path = "/chat/clawd/\(filename)"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    func performContextAction(_ action: String, sid: String? = nil, rounds: Int? = nil) async throws -> ContextActionResponse {
        var req = request(url: endpoint("app/context_action"), method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(ContextActionPayload(action: action, sid: sid, rounds: rounds))
        let responseData = try await data(for: req)
        return try decoder.decode(ContextActionResponse.self, from: responseData)
    }

    func forgeStatus(previewRounds: Int? = nil) async throws -> ForgeStatus {
        var components = URLComponents(url: endpoint("app/forge"), resolvingAgainstBaseURL: false)
        if let previewRounds {
            components?.queryItems = [URLQueryItem(name: "rounds", value: String(previewRounds))]
        }
        guard let url = components?.url else { throw APIError.invalidURL }
        let responseData = try await data(for: request(url: url))
        return try decoder.decode(ForgeStatus.self, from: responseData)
    }

    func streamRequest() -> URLRequest {
        var req = request(url: endpoint("app/stream"))
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        // Avoid an intermediary compressing and buffering the event stream.
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        req.timeoutInterval = 60 * 60
        return req
    }

    func attachmentRequest(path: String) -> URLRequest? {
        let url: URL?
        if let absolute = URL(string: path), absolute.scheme != nil {
            url = absolute
        } else {
            url = URL(string: path, relativeTo: baseURL)?.absoluteURL
        }
        guard let url else { return nil }
        return request(url: url)
    }

    private var decoder: JSONDecoder { JSONDecoder() }

    private func endpoint(_ path: String) -> URL {
        path.split(separator: "/").reduce(baseURL) { partial, component in
            partial.appendingPathComponent(String(component))
        }
    }

    private func request(url: URL, method: String = "GET") -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        req.setValue("TidalEcho-iOS/0.1", forHTTPHeaderField: "User-Agent")
        return req
    }

    /// 从后台回来，第一枪常打在 iOS 冻死的旧 keep-alive 连接上，报 -1005
    /// "The network connection was lost."。GET 重来一次就是新连接；POST 不重试，免得发两遍。
    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .networkConnectionLost && request.httpMethod == "GET" {
            try await Task.sleep(nanoseconds: 300_000_000)
            return try await URLSession.shared.data(for: request)
        }
    }

    private func data(for request: URLRequest) async throws -> Data {
        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw APIError.unauthorized }
            let detail = (try? JSONDecoder().decode(ErrorResponse.self, from: data).detail) ?? "HTTP \(http.statusCode)"
            throw APIError.server(detail)
        }
        return data
    }
}

private struct SendPayload: Encodable {
    let text: String
    let attachments: [Attachment]
    let apiSession: String?
    let deferReply: Bool
    let bundleID: String?

    enum CodingKeys: String, CodingKey {
        case text, attachments
        case apiSession = "api_session"
        case deferReply = "defer_reply"
        case bundleID = "bundle_id"
    }
}

private struct BundleReleasePayload: Encodable {
    let bundleID: String
    let messageIDs: [Int]
    let apiSession: String?

    enum CodingKeys: String, CodingKey {
        case bundleID = "bundle_id"
        case messageIDs = "message_ids"
        case apiSession = "api_session"
    }
}

struct ScreenSharePreparation: Hashable {
    let expiresAt: String
    let expiresIn: Int
    let probeID: String
    let localHandoffReady: Bool
    let localHandoffDiagnostic: String?
}

private struct ScreenShareSessionPayload: Encodable {
    let apiSession: String?
    let appGroupProbe: String

    enum CodingKeys: String, CodingKey {
        case apiSession = "api_session"
        case appGroupProbe = "app_group_probe"
    }
}

private struct ScreenShareSessionResponse: Decodable {
    let ticket: String
    let probeID: String
    let expiresAt: String
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case ticket
        case probeID = "probe_id"
        case expiresAt = "expires_at"
        case expiresIn = "expires_in"
    }
}

struct ScreenShareProbeStatus: Decodable, Hashable {
    let probeID: String
    let status: String
    let reason: String
    let checkedAt: String?

    enum CodingKeys: String, CodingKey {
        case probeID = "probe_id"
        case status, reason
        case checkedAt = "checked_at"
    }
}

private struct ScreenShareHandoffPayload: Encodable {
    let version: Int
    let relayURL: String
    let ticket: String
    let expiresAt: String
    let probeMarker: String
}

private struct DesireConfigPayload: Encodable {
    let actEnabled: Bool?
    let libidoMultiplier: Double?

    enum CodingKeys: String, CodingKey {
        case actEnabled = "act_enabled"
        case libidoMultiplier = "libido_mult"
    }
}

private struct SessionCreatePayload: Encodable {
    let title: String
    let body: BrainTarget
    let activate: Bool
}

private struct SessionUpdatePayload: Encodable {
    let title: String?
    let active: Bool?
}

private struct MessageEditPayload: Encodable { let text: String }
private struct ReactionPayload: Encodable { let emoji: String }
private struct ThinkingTranslationResponse: Decodable { let translation: String }

private struct VoiceTextPayload: Encodable {
    let text: String
    let source: String
    let callID: String?
    let apiSession: String?

    enum CodingKeys: String, CodingKey {
        case text, source
        case callID = "call_id"
        case apiSession = "api_session"
    }
}

private struct CallPayload: Encodable {
    let action: String
    let callID: String
    let messageID: Int?
    let apiSession: String?

    enum CodingKeys: String, CodingKey {
        case action
        case callID = "call_id"
        case messageID = "message_id"
        case apiSession = "api_session"
    }
}

private struct TTSPayload: Encodable {
    let text: String
    let messageID: Int?
    let persist: Bool

    enum CodingKeys: String, CodingKey {
        case text, persist
        case messageID = "message_id"
    }
}

private struct BrainPayload: Encodable { let target: BrainTarget }

private struct LoopConfigPayload: Encodable {
    let mainChain: [LoopRoute]
    enum CodingKeys: String, CodingKey { case mainChain = "main_chain" }
}

private struct LoopPresetPayload: Encodable {
    let activatePreset: Int?
    let apiPresets: [APIPresetInput]?
    enum CodingKeys: String, CodingKey {
        case activatePreset = "activate_preset"
        case apiPresets = "api_presets"
    }
}

private struct LoopEffortPayload: Encodable { let effort: String }

private struct ChatModePayload: Encodable {
    let mode: ChatMode?
    let stripTerminalPeriods: Bool?

    enum CodingKeys: String, CodingKey {
        case mode
        case stripTerminalPeriods = "strip_terminal_periods"
    }
}

private struct StarPayload: Encodable { let on: Bool }
private struct AskAnswerPayload: Encodable {
    let index: Int?
    let text: String?
}

private struct MomentCreatePayload: Encodable {
    let author: MessageAuthor
    let kind: MomentKind
    let text: String
    let attachments: [Attachment]
}

private struct MomentLikePayload: Encodable {
    let author: MessageAuthor
    let on: Bool
}

private struct MomentCommentPayload: Encodable {
    let author: MessageAuthor
    let text: String
    let replyTo: MessageAuthor?
    enum CodingKeys: String, CodingKey {
        case author, text
        case replyTo = "reply_to"
    }
}

struct CalendarCreatePayload: Encodable {
    let date: String
    let time: String
    let title: String
    let kind: String
    let visible: Bool
    let remind: Bool
}

private struct DesktopModelPayload: Encodable { let model: String }

private struct ContextThresholdPayload: Encodable {
    let triggerK: Int?
    let auto: Bool?
    let forgeRounds: Int?
    enum CodingKeys: String, CodingKey {
        case auto
        case triggerK = "trigger_k"
        case forgeRounds = "forge_rounds"
    }
}

private struct DesktopKeepalivePayload: Encodable {
    let keepalive: Bool
}

private struct ContextActionPayload: Encodable {
    let action: String
    let sid: String?
    let rounds: Int?
}

private struct ErrorResponse: Decodable {
    let detail: String
}

enum APIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case unauthorized
    case server(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "服务地址不正确"
        case .invalidResponse: return "服务器返回了无法识别的响应"
        case .unauthorized: return "连接密钥不正确"
        case .server(let detail): return detail
        }
    }
}
