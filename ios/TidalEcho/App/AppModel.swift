import Combine
import Foundation
import SwiftUI
import UIKit

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case launching
        case signedOut
        case connecting
        case connected
    }

    @Published var phase: Phase = .launching
    @Published var messages: [ChatMessage] = []
    @Published var pendingAttachments: [Attachment] = []
    @Published var isTyping = false
    @Published var streamingThinking = ""
    @Published var streamingReply = ""
    @Published var isStreamConnected = false
    @Published var isLoadingHistory = false
    @Published var isLoadingOlderHistory = false
    @Published var canLoadOlderHistory = false
    @Published var sessions: [APISession] = []
    @Published var activeSessionID = AppModel.legacySessionID
    @Published var isLoadingSessions = false
    @Published var navigationRequest: MessageNavigationRequest?
    @Published var isUploading = false
    @Published var isUploadingVoice = false
    @Published var isSynthesizingMessageID: Int?
    @Published var errorMessage: String?
    @Published private(set) var chatMode: ChatMode = .long
    @Published private(set) var giftUnreadCount = 0
    @Published private(set) var momentsUnreadCount = 0
    /// 小克在书页边留了一句话：正开着那一章的阅读页会当场把它长出来。
    @Published var incomingBookAnnotation: BookAnnotationEvent?
    /// 这条共享卡上的系统广播按钮得她自己点（程序化那条路没走通）。
    @Published var peekManualPickerID: Int?
    /// 上一趟历史没读完（多半是后台被系统掐断）。回前台要补一次，
    /// 否则聊天就一直空着——她只能划掉 App 重开。
    private var historyNeedsReload = false
    /// 正在连（启动那趟或登录那趟）。回前台的自愈不该插队跑第二个 bootstrap。
    private var connectInFlight = false
    @Published var theme: EchoTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Keys.theme) }
    }
    @Published var chatLayoutStyle: ChatLayoutStyle {
        didSet { UserDefaults.standard.set(chatLayoutStyle.rawValue, forKey: Keys.chatLayoutStyle) }
    }
    @Published var composerStyle: ComposerStyle {
        didSet { UserDefaults.standard.set(composerStyle.rawValue, forKey: Keys.composerStyle) }
    }
    @Published var chatFont: EchoChatFont {
        didSet { UserDefaults.standard.set(chatFont.rawValue, forKey: Keys.chatFont) }
    }
    @Published private(set) var importedChatFonts: [ImportedChatFont]
    @Published var fontScale: Double {
        didSet { UserDefaults.standard.set(fontScale, forKey: Keys.fontScale) }
    }
    /// 我的气泡单独的字体；nil＝跟聊天字体一样。字号总是单独存。
    @Published var humanChatFont: EchoChatFont? {
        didSet { UserDefaults.standard.set(humanChatFont?.rawValue ?? "", forKey: Keys.humanChatFont) }
    }
    @Published var humanFontScale: Double {
        didSet { UserDefaults.standard.set(humanFontScale, forKey: Keys.humanFontScale) }
    }
    /// 朋友圈日志页的字体；nil＝照旧按聊天字体挑一款衬线。
    /// 思考/工具标题的字体；nil＝跟聊天字体。
    @Published var processTitleFont: EchoChatFont? {
        didSet { UserDefaults.standard.set(processTitleFont?.rawValue ?? "", forKey: Keys.processTitleFont) }
    }
    @Published var showsProcessDisclosure: Bool {
        didSet { UserDefaults.standard.set(showsProcessDisclosure, forKey: Keys.showsProcessDisclosure) }
    }
    @Published var journalFont: EchoChatFont? {
        didSet { UserDefaults.standard.set(journalFont?.rawValue ?? "", forKey: Keys.journalFont) }
    }
    @Published private(set) var savedAppearances: [SavedAppearance] {
        didSet { SavedAppearanceStore.save(savedAppearances) }
    }
    @Published var showsAIAvatar: Bool {
        didSet { UserDefaults.standard.set(showsAIAvatar, forKey: Keys.showsAIAvatar) }
    }
    @Published var showsAPIMessageUsage: Bool {
        didSet {
            UserDefaults.standard.set(showsAPIMessageUsage, forKey: Keys.showsAPIMessageUsage)
            if showsAPIMessageUsage {
                Task { _ = try? await settingsLoopConfig() }
            }
        }
    }
    @Published private(set) var apiUsagePrices = APIUsagePrices()
    @Published private(set) var apiUsageCacheTTL = "5m"
    @Published var aiBubbleOpacity: Double {
        didSet { UserDefaults.standard.set(aiBubbleOpacity, forKey: Keys.aiBubbleOpacity) }
    }
    @Published var humanBubbleOpacity: Double {
        didSet { UserDefaults.standard.set(humanBubbleOpacity, forKey: Keys.humanBubbleOpacity) }
    }
    @Published var bubbleRadius: Double {
        didSet { UserDefaults.standard.set(bubbleRadius, forKey: Keys.bubbleRadius) }
    }
    @Published var chatWeight: Double {
        didSet { UserDefaults.standard.set(chatWeight, forKey: Keys.chatWeight) }
    }
    @Published var backgroundOpacity: Double {
        didSet { UserDefaults.standard.set(backgroundOpacity, forKey: Keys.backgroundOpacity) }
    }
    @Published var backgroundBlur: Double {
        didSet { UserDefaults.standard.set(backgroundBlur, forKey: Keys.backgroundBlur) }
    }
    @Published var showsAIBubble: Bool {
        didSet { UserDefaults.standard.set(showsAIBubble, forKey: Keys.showsAIBubble) }
    }
    @Published var showsHumanAvatar: Bool {
        didSet { UserDefaults.standard.set(showsHumanAvatar, forKey: Keys.showsHumanAvatar) }
    }
    @Published var showsClawdPet: Bool {
        didSet { UserDefaults.standard.set(showsClawdPet, forKey: Keys.showsClawdPet) }
    }
    @Published var bubbleWidthScale: Double {
        didSet { UserDefaults.standard.set(bubbleWidthScale, forKey: Keys.bubbleWidthScale) }
    }
    /// 气泡内边距在主题基准值上的增减（pt），0＝主题原样。
    @Published var bubblePaddingX: Double {
        didSet { UserDefaults.standard.set(bubblePaddingX, forKey: Keys.bubblePaddingX) }
    }
    @Published var bubblePaddingY: Double {
        didSet { UserDefaults.standard.set(bubblePaddingY, forKey: Keys.bubblePaddingY) }
    }
    @Published var bubbleBorderWidth: Double {
        didSet { UserDefaults.standard.set(bubbleBorderWidth, forKey: Keys.bubbleBorderWidth) }
    }
    @Published var bubbleStyle: EchoBubbleStyle {
        didSet { UserDefaults.standard.set(bubbleStyle.rawValue, forKey: Keys.bubbleStyle) }
    }
    @Published var bubbleShapeStyle: EchoBubbleShapeStyle {
        didSet { UserDefaults.standard.set(bubbleShapeStyle.rawValue, forKey: Keys.bubbleShapeStyle) }
    }
    @Published var aiReplyTiming: AIReplyTiming {
        didSet { UserDefaults.standard.set(aiReplyTiming.rawValue, forKey: Keys.aiReplyTiming) }
    }
    @Published private(set) var bundledMessageParts: [BundledMessagePart] = []
    @Published private(set) var isSendingBundledMessage = false
    var hasPendingBundledMessageUploads: Bool {
        bundledMessageParts.contains { $0.messageID == nil }
    }
    @Published var liquidGlassStrength: Double {
        didSet { UserDefaults.standard.set(liquidGlassStrength, forKey: Keys.liquidGlassStrength) }
    }
    @Published var liquidGlassDispersion: Double {
        didSet { UserDefaults.standard.set(liquidGlassDispersion, forKey: Keys.liquidGlassDispersion) }
    }
    @Published var liquidGlassRimWidth: Double {
        didSet { UserDefaults.standard.set(liquidGlassRimWidth, forKey: Keys.liquidGlassRimWidth) }
    }
    @Published var liquidGlassMagnify: Double {
        didSet { UserDefaults.standard.set(liquidGlassMagnify, forKey: Keys.liquidGlassMagnify) }
    }
    @Published var liquidGlassBlur: Double {
        didSet { UserDefaults.standard.set(liquidGlassBlur, forKey: Keys.liquidGlassBlur) }
    }
    @Published var liquidGlassSize: Double {
        didSet { UserDefaults.standard.set(liquidGlassSize, forKey: Keys.liquidGlassSize) }
    }
    @Published var peerRemark: String {
        didSet { UserDefaults.standard.set(peerRemark, forKey: Keys.peerRemark) }
    }
    @Published var aiBubbleColorHex: String {
        didSet { UserDefaults.standard.set(aiBubbleColorHex, forKey: Keys.aiBubbleColor) }
    }
    @Published var humanBubbleColorHex: String {
        didSet { UserDefaults.standard.set(humanBubbleColorHex, forKey: Keys.humanBubbleColor) }
    }
    @Published var aiBubbleTextColorHex: String {
        didSet { UserDefaults.standard.set(aiBubbleTextColorHex, forKey: Keys.aiBubbleTextColor) }
    }
    @Published var humanBubbleTextColorHex: String {
        didSet { UserDefaults.standard.set(humanBubbleTextColorHex, forKey: Keys.humanBubbleTextColor) }
    }
    /// 思考 / 工具那一行的标题，和气泡下面的时间戳。空字符串＝跟主题的次要文字色走。
    @Published var processTitleColorHex: String {
        didSet { UserDefaults.standard.set(processTitleColorHex, forKey: Keys.processTitleColor) }
    }
    @Published var timestampColorHex: String {
        didSet { UserDefaults.standard.set(timestampColorHex, forKey: Keys.timestampColor) }
    }
    @Published var backgroundImage: UIImage?
    @Published var aiAvatarImage: UIImage?
    @Published var humanAvatarImage: UIImage?
    @Published private(set) var clawdPetState = ClawdPetState.idle

    private var client: APIClient?
    private let stream = SSEClient()
    private var heartbeatTask: Task<Void, Never>?
    private var incrementalSyncTask: Task<Void, Never>?
    private var typingTimeoutTask: Task<Void, Never>?
    private var streamFlushTask: Task<Void, Never>?
    private var typingSuppressedUntil = Date.distantPast
    private var streamingDraftTexts: [String: String] = [:]
    private var activeThinkingStreamID: String?
    private var activeReplyStreamID: String?
    private var isCatchingUp = false
    private var temporaryID = -1
    private var didBootstrap = false
    private var backgroundedAt: Date?
    /// 最近一次从服务器拉下来的最新窗口（加上之后新来的）。**不再是全量历史**——
    /// 更早的上翻时按需去服务器要（2026-09-30 之前开屏要翻 41 页 / 8.6 MB）。
    private var historyArchive: [ChatMessage] = []
    private var locallyHiddenMessageIDs: Set<Int> = []
    private var missedCallMessageIDs: Set<Int> = []
    private var pendingMissedCallMessageIDs: Set<Int> = []
    private var currentGiftTokens: Set<String> = []
    private var currentAIPostIDs: Set<Int> = []
    private var replyBundleID: String?

    private static let initialHistoryWindow = 120
    private static let olderHistoryPageSize = 80
    private static let streamFlushIntervalNanoseconds: UInt64 = 80_000_000
    static let legacySessionID = "__legacy__"

    private enum StreamDraftKind: String {
        case thinking
        case reply
    }

    private enum Keys {
        static let relayURL = "tidalEcho.relayURL"
        static let relaySecret = "relaySecret"
        static let theme = "tidalEcho.theme"
        static let chatLayoutStyle = "tidalEcho.chatLayoutStyle"
        static let composerStyle = "tidalEcho.composerStyle"
        static let chatFont = "tidalEcho.chatFont"
        static let fontScale = "tidalEcho.fontScale"
        static let humanChatFont = "tidalEcho.humanChatFont"
        static let humanFontScale = "tidalEcho.humanFontScale"
        static let journalFont = "tidalEcho.journalFont"
        static let processTitleFont = "tidalEcho.processTitleFont"
        static let showsProcessDisclosure = "tidalEcho.showsProcessDisclosure"
        static let showsAIAvatar = "tidalEcho.showsAIAvatar"
        static let showsAPIMessageUsage = "tidalEcho.showsAPIMessageUsage"
        static let bubbleOpacity = "tidalEcho.bubbleOpacity"
        static let aiBubbleOpacity = "tidalEcho.aiBubbleOpacity"
        static let humanBubbleOpacity = "tidalEcho.humanBubbleOpacity"
        static let bubbleRadius = "tidalEcho.bubbleRadius"
        static let chatWeight = "tidalEcho.chatWeight"
        static let backgroundOpacity = "tidalEcho.backgroundOpacity"
        static let backgroundBlur = "tidalEcho.backgroundBlur"
        static let showsAIBubble = "tidalEcho.showsAIBubble"
        static let showsHumanAvatar = "tidalEcho.showsHumanAvatar"
        static let showsClawdPet = "tidalEcho.showsClawdPet"
        static let bubbleWidthScale = "tidalEcho.bubbleWidthScale"
        static let bubblePaddingX = "tidalEcho.bubblePaddingX"
        static let bubblePaddingY = "tidalEcho.bubblePaddingY"
        static let bubbleBorderWidth = "tidalEcho.bubbleBorderWidth"
        static let bubbleStyle = "tidalEcho.bubbleStyle"
        static let bubbleShapeStyle = "tidalEcho.bubbleShapeStyle"
        static let aiReplyTiming = "tidalEcho.aiReplyTiming"
        static let telegramBubbleMetricsV1 = "tidalEcho.telegramBubbleMetricsV1"
        static let liquidGlassStrength = "tidalEcho.liquidGlassStrength"
        static let liquidGlassDispersion = "tidalEcho.liquidGlassDispersion"
        static let liquidGlassRimWidth = "tidalEcho.liquidGlassRimWidth"
        static let liquidGlassMagnify = "tidalEcho.liquidGlassMagnify"
        static let liquidGlassBlur = "tidalEcho.liquidGlassBlur"
        static let liquidGlassSize = "tidalEcho.liquidGlassSize"
        static let pwaBubbleMetricsV1 = "tidalEcho.pwaBubbleMetricsV1"
        static let paperPresetV3 = "tidalEcho.paperPresetV3"
        static let harborPresetV1 = "tidalEcho.harborPresetV1"
        static let nestPresetV1 = "tidalEcho.nestPresetV1"
        static let peerRemark = "tidalEcho.peerRemark"
        static let aiBubbleColor = "tidalEcho.aiBubbleColor"
        static let humanBubbleColor = "tidalEcho.humanBubbleColor"
        static let aiBubbleTextColor = "tidalEcho.aiBubbleTextColor"
        static let humanBubbleTextColor = "tidalEcho.humanBubbleTextColor"
        static let processTitleColor = "tidalEcho.processTitleColor"
        static let timestampColor = "tidalEcho.timestampColor"
        // Kept only to migrate the first shared text-color setting.
        static let bubbleTextColor = "tidalEcho.bubbleTextColor"
        static let lastNativeNotificationID = "tidalEcho.lastNativeNotificationID"
        static let activeSessionID = "tidalEcho.activeSessionID"
        static let locallyHiddenMessageIDs = "tidalEcho.locallyHiddenMessageIDs"
        static let missedCallMessageIDs = "tidalEcho.missedCallMessageIDs"
        static let pendingMissedCallMessageIDs = "tidalEcho.pendingMissedCallMessageIDs"
        static let seenGiftTokens = "tidalEcho.seenGiftTokens"
        static let seenAIPostIDs = "tidalEcho.seenAIPostIDs"
        static let greetingCache = "tidalEcho.greetingCache"
    }

    enum AppearanceImageKind: Equatable {
        case background
        case aiAvatar
        case humanAvatar

        var filename: String {
            switch self {
            case .background: return "chat-background.jpg"
            case .aiAvatar: return "ai-avatar.jpg"
            case .humanAvatar: return "human-avatar.jpg"
            }
        }
    }

    init() {
        let defaults = UserDefaults.standard
        let rawTheme = defaults.string(forKey: Keys.theme) ?? EchoTheme.mist.rawValue
        let initialTheme = EchoTheme(rawValue: rawTheme) ?? .mist
        let shouldMigratePaperPreset = initialTheme == .paper && !defaults.bool(forKey: Keys.paperPresetV3)
        let shouldMigrateHarborPreset = initialTheme == .harbor && !defaults.bool(forKey: Keys.harborPresetV1)
        let shouldMigrateNestPreset = initialTheme == .nest && !defaults.bool(forKey: Keys.nestPresetV1)
        theme = initialTheme
        chatLayoutStyle = ChatLayoutStyle(rawValue: defaults.string(forKey: Keys.chatLayoutStyle) ?? "") ?? .classic
        composerStyle = ComposerStyle(rawValue: defaults.string(forKey: Keys.composerStyle) ?? "") ?? .original
        let rawFont = defaults.string(forKey: Keys.chatFont) ?? EchoChatFont.system.rawValue
        let loadedFonts = ImportedFontStore.loadFonts()
        importedChatFonts = loadedFonts
        let savedFont = EchoChatFont(rawValue: rawFont) ?? .system
        if case .imported(let name) = savedFont, !loadedFonts.contains(where: { $0.postScriptName == name }) {
            chatFont = .system
            defaults.set(EchoChatFont.system.rawValue, forKey: Keys.chatFont)
        } else {
            chatFont = savedFont
        }
        let loadedFontScale = defaults.object(forKey: Keys.fontScale) == nil ? 1 : defaults.double(forKey: Keys.fontScale)
        fontScale = loadedFontScale
        humanChatFont = Self.storedFont(defaults.string(forKey: Keys.humanChatFont), imported: loadedFonts)
        humanFontScale = defaults.object(forKey: Keys.humanFontScale) == nil
            ? loadedFontScale
            : defaults.double(forKey: Keys.humanFontScale)
        journalFont = Self.storedFont(defaults.string(forKey: Keys.journalFont), imported: loadedFonts)
        processTitleFont = Self.storedFont(defaults.string(forKey: Keys.processTitleFont), imported: loadedFonts)
        showsProcessDisclosure = defaults.object(forKey: Keys.showsProcessDisclosure) == nil
            ? true
            : defaults.bool(forKey: Keys.showsProcessDisclosure)
        savedAppearances = SavedAppearanceStore.load()
        showsAIAvatar = defaults.object(forKey: Keys.showsAIAvatar) == nil ? true : defaults.bool(forKey: Keys.showsAIAvatar)
        showsAPIMessageUsage = defaults.bool(forKey: Keys.showsAPIMessageUsage)
        let legacyBubbleOpacity = defaults.object(forKey: Keys.bubbleOpacity) == nil
            ? 1
            : defaults.double(forKey: Keys.bubbleOpacity)
        aiBubbleOpacity = defaults.object(forKey: Keys.aiBubbleOpacity) == nil
            ? legacyBubbleOpacity
            : defaults.double(forKey: Keys.aiBubbleOpacity)
        humanBubbleOpacity = defaults.object(forKey: Keys.humanBubbleOpacity) == nil
            ? legacyBubbleOpacity
            : defaults.double(forKey: Keys.humanBubbleOpacity)
        let savedBubbleRadius = defaults.object(forKey: Keys.bubbleRadius) == nil ? 14 : defaults.double(forKey: Keys.bubbleRadius)
        if !defaults.bool(forKey: Keys.pwaBubbleMetricsV1), abs(savedBubbleRadius - 18) < 0.001 {
            // v1.11 used 18 as its native default; PWA resolves clamp(14px, 2vw, 20px)
            // to 14px on an iPhone. Migrate only the untouched old default once.
            bubbleRadius = 14
            defaults.set(14, forKey: Keys.bubbleRadius)
        } else {
            bubbleRadius = savedBubbleRadius
        }
        defaults.set(true, forKey: Keys.pwaBubbleMetricsV1)
        chatWeight = defaults.object(forKey: Keys.chatWeight) == nil ? 400 : defaults.double(forKey: Keys.chatWeight)
        backgroundOpacity = defaults.object(forKey: Keys.backgroundOpacity) == nil ? 1 : defaults.double(forKey: Keys.backgroundOpacity)
        backgroundBlur = defaults.object(forKey: Keys.backgroundBlur) == nil ? 0 : defaults.double(forKey: Keys.backgroundBlur)
        showsAIBubble = defaults.object(forKey: Keys.showsAIBubble) == nil ? true : defaults.bool(forKey: Keys.showsAIBubble)
        showsHumanAvatar = defaults.object(forKey: Keys.showsHumanAvatar) == nil ? false : defaults.bool(forKey: Keys.showsHumanAvatar)
        showsClawdPet = defaults.object(forKey: Keys.showsClawdPet) == nil ? true : defaults.bool(forKey: Keys.showsClawdPet)
        bubbleWidthScale = defaults.object(forKey: Keys.bubbleWidthScale) == nil ? 1 : defaults.double(forKey: Keys.bubbleWidthScale)
        bubblePaddingX = defaults.double(forKey: Keys.bubblePaddingX)
        bubblePaddingY = defaults.double(forKey: Keys.bubblePaddingY)
        bubbleBorderWidth = defaults.object(forKey: Keys.bubbleBorderWidth) == nil ? 0 : defaults.double(forKey: Keys.bubbleBorderWidth)
        bubbleStyle = EchoBubbleStyle(rawValue: defaults.string(forKey: Keys.bubbleStyle) ?? "") ?? .classic
        let savedBubbleShapeStyle = EchoBubbleShapeStyle(
            rawValue: defaults.string(forKey: Keys.bubbleShapeStyle) ?? ""
        ) ?? .standard
        if defaults.bool(forKey: Keys.telegramBubbleMetricsV1) {
            // Undo the one-release Telegram default without permanently
            // overriding shape choices made after this migration.
            bubbleShapeStyle = .standard
            defaults.set(EchoBubbleShapeStyle.standard.rawValue, forKey: Keys.bubbleShapeStyle)
            defaults.removeObject(forKey: Keys.telegramBubbleMetricsV1)
        } else {
            bubbleShapeStyle = savedBubbleShapeStyle
        }
        aiReplyTiming = AIReplyTiming(
            rawValue: defaults.string(forKey: Keys.aiReplyTiming) ?? ""
        ) ?? .immediate
        liquidGlassStrength = defaults.object(forKey: Keys.liquidGlassStrength) == nil ? 56.8 : defaults.double(forKey: Keys.liquidGlassStrength)
        liquidGlassDispersion = defaults.object(forKey: Keys.liquidGlassDispersion) == nil ? 0.39 : defaults.double(forKey: Keys.liquidGlassDispersion)
        liquidGlassRimWidth = defaults.object(forKey: Keys.liquidGlassRimWidth) == nil ? 0.28 : defaults.double(forKey: Keys.liquidGlassRimWidth)
        liquidGlassMagnify = defaults.object(forKey: Keys.liquidGlassMagnify) == nil ? 0 : defaults.double(forKey: Keys.liquidGlassMagnify)
        liquidGlassBlur = defaults.object(forKey: Keys.liquidGlassBlur) == nil ? 0.94 : defaults.double(forKey: Keys.liquidGlassBlur)
        liquidGlassSize = defaults.object(forKey: Keys.liquidGlassSize) == nil ? 174 : defaults.double(forKey: Keys.liquidGlassSize)
        peerRemark = defaults.string(forKey: Keys.peerRemark) ?? ""
        aiBubbleColorHex = defaults.string(forKey: Keys.aiBubbleColor) ?? ""
        humanBubbleColorHex = defaults.string(forKey: Keys.humanBubbleColor) ?? ""
        let legacyBubbleTextColor = defaults.string(forKey: Keys.bubbleTextColor) ?? ""
        aiBubbleTextColorHex = defaults.string(forKey: Keys.aiBubbleTextColor) ?? legacyBubbleTextColor
        humanBubbleTextColorHex = defaults.string(forKey: Keys.humanBubbleTextColor) ?? legacyBubbleTextColor
        processTitleColorHex = defaults.string(forKey: Keys.processTitleColor) ?? ""
        timestampColorHex = defaults.string(forKey: Keys.timestampColor) ?? ""
        activeSessionID = defaults.string(forKey: Keys.activeSessionID) ?? Self.legacySessionID
        if let hidden = defaults.array(forKey: Keys.locallyHiddenMessageIDs) as? [Int] {
            locallyHiddenMessageIDs = Set(hidden)
        }
        missedCallMessageIDs = Set((defaults.array(forKey: Keys.missedCallMessageIDs) as? [Int]) ?? [])
        pendingMissedCallMessageIDs = Set((defaults.array(forKey: Keys.pendingMissedCallMessageIDs) as? [Int]) ?? [])
        backgroundImage = Self.loadAppearanceImage(.background)
        aiAvatarImage = Self.loadAppearanceImage(.aiAvatar)
        humanAvatarImage = Self.loadAppearanceImage(.humanAvatar)
        if shouldMigratePaperPreset {
            applyPaperAppearancePreset()
            defaults.set(true, forKey: Keys.paperPresetV3)
        }
        if shouldMigrateHarborPreset {
            applyHarborAppearancePreset()
            defaults.set(true, forKey: Keys.harborPresetV1)
        }
        if shouldMigrateNestPreset {
            applyNestAppearancePreset()
            defaults.set(true, forKey: Keys.nestPresetV1)
        }
        NativeCallCoordinator.shared.onDeclineIncomingCall = { [weak self] messageID in
            await self?.markIncomingCallMissed(messageID: messageID)
        }
    }

    var savedServerAddress: String {
        UserDefaults.standard.string(forKey: Keys.relayURL) ?? ""
    }

    var connectionText: String {
        if isTyping { return "\(peerDisplayName)正在输入…" }
        return isStreamConnected ? "online" : "connecting…"
    }

    /// Every theme respects the wallpaper selected by the user. Paper used to
    /// suppress it here, which made the picker preview update while chat stayed
    /// pinned to the preset background.
    var visibleBackgroundImage: UIImage? {
        backgroundImage
    }

    var peerDisplayName: String {
        let value = peerRemark.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "小克" : value
    }

    var liquidGlassSettings: LiquidGlassSettings {
        LiquidGlassSettings(
            strength: liquidGlassStrength,
            dispersion: liquidGlassDispersion,
            rimWidth: liquidGlassRimWidth,
            magnify: liquidGlassMagnify,
            blur: liquidGlassBlur,
            size: liquidGlassSize
        )
    }

    var resolvedHumanChatFont: EchoChatFont { humanChatFont ?? chatFont }
    var journalLiteraryFont: EchoChatFont { journalFont ?? SpaceStyle.literaryFont(for: chatFont) }

    /// nil for an empty value, an unknown one, or an imported font that is no longer installed.
    private static func storedFont(_ raw: String?, imported: [ImportedChatFont]) -> EchoChatFont? {
        guard let raw, !raw.isEmpty, let font = EchoChatFont(rawValue: raw) else { return nil }
        if case .imported(let name) = font, !imported.contains(where: { $0.postScriptName == name }) { return nil }
        return font
    }

    func deleteImportedChatFont(_ font: ImportedChatFont) async throws {
        let removed = try await Task.detached(priority: .userInitiated) {
            try ImportedFontStore.deleteFont(postScriptName: font.postScriptName)
        }.value
        let gone = Set(removed + [font.postScriptName])
        func survives(_ choice: EchoChatFont?) -> Bool {
            guard case .imported(let name) = choice else { return true }
            return !gone.contains(name)
        }
        if !survives(chatFont) { chatFont = .system }
        if !survives(humanChatFont) { humanChatFont = nil }
        if !survives(journalFont) { journalFont = nil }
        if !survives(processTitleFont) { processTitleFont = nil }
        importedChatFonts.removeAll { gone.contains($0.postScriptName) }
        EchoChatFont.invalidateImportedFaceCache()
    }

    var availableChatFonts: [EchoChatFont] {
        EchoChatFont.allCases + importedChatFonts.map(\.chatFont)
    }

    func chatFontTitle(_ font: EchoChatFont) -> String {
        if case .imported(let name) = font {
            return importedChatFonts.first(where: { $0.postScriptName == name })?.displayName ?? font.title
        }
        return font.title
    }

    func importChatFont(from url: URL) async throws {
        let existing = importedChatFonts
        let imported = try await Task.detached(priority: .userInitiated) {
            try ImportedFontStore.importFont(from: url, existingFonts: existing)
        }.value
        importedChatFonts = ImportedFontStore.sorted(importedChatFonts + imported.filter { record in
            !importedChatFonts.contains(where: { $0.id == record.id })
        })
        EchoChatFont.invalidateImportedFaceCache()
        if let first = imported.first { chatFont = first.chatFont }
    }

    func applyTheme(_ nextTheme: EchoTheme) {
        theme = nextTheme
        switch nextTheme {
        case .paper:
            applyPaperAppearancePreset()
            UserDefaults.standard.set(true, forKey: Keys.paperPresetV3)
        case .harbor:
            applyHarborAppearancePreset()
            UserDefaults.standard.set(true, forKey: Keys.harborPresetV1)
        case .nest:
            applyNestAppearancePreset()
            UserDefaults.standard.set(true, forKey: Keys.nestPresetV1)
        case .mist:
            break
        }
    }

    private func applyPaperAppearancePreset() {
        chatFont = .rounded
        fontScale = 0.95
        humanFontScale = fontScale
        chatWeight = 340
        showsAIBubble = true
        bubbleStyle = .classic
        bubbleShapeStyle = .standard
        aiBubbleColorHex = "#EEEBE4"
        humanBubbleColorHex = "#E2C2C5"
        aiBubbleOpacity = 0.60
        humanBubbleOpacity = 0.60
        bubbleRadius = 21
        bubbleWidthScale = 1.20
        bubbleBorderWidth = 0
        backgroundOpacity = 1
        showsAIAvatar = true
        showsHumanAvatar = true
        installPresetImage(named: "paper-ai-avatar", kind: .aiAvatar)
        installPresetImage(named: "paper-human-avatar", kind: .humanAvatar)
    }

    private func applyHarborAppearancePreset() {
        chatFont = .system
        fontScale = 0.95
        humanFontScale = fontScale
        chatWeight = 440
        showsAIBubble = true
        showsAIAvatar = false
        showsHumanAvatar = false
        bubbleStyle = .classic
        bubbleShapeStyle = .standard
        aiBubbleColorHex = "#313131"
        humanBubbleColorHex = "#313131"
        aiBubbleTextColorHex = "#F8F8F6"
        humanBubbleTextColorHex = "#F8F8F6"
        aiBubbleOpacity = 0.60
        humanBubbleOpacity = 0.60
        bubbleRadius = 20
        bubbleWidthScale = 1.20
        bubbleBorderWidth = 0
        backgroundOpacity = 1
        backgroundBlur = 1
        installPresetImage(named: "harbor-background", kind: .background)
    }

    private func applyNestAppearancePreset() {
        chatFont = .anthropicSerif
        fontScale = 1
        humanFontScale = fontScale
        chatWeight = 400
        showsAIBubble = false
        showsAIAvatar = false
        showsHumanAvatar = false
        bubbleStyle = .classic
        bubbleShapeStyle = .standard
        aiBubbleColorHex = ""
        humanBubbleColorHex = "#EFEFEB"
        aiBubbleTextColorHex = "#1F1E1D"
        humanBubbleTextColorHex = "#1F1E1D"
        aiBubbleOpacity = 1
        humanBubbleOpacity = 1
        bubbleRadius = 22
        bubbleWidthScale = 1.16
        bubbleBorderWidth = 0
        backgroundOpacity = 1
    }

    private func installPresetImage(named name: String, kind: AppearanceImageKind) {
        let rootURL = Bundle.main.url(forResource: name, withExtension: "jpg")
        let nestedURL = Bundle.main.url(
            forResource: name,
            withExtension: "jpg",
            subdirectory: "ThemePresets"
        )
        guard let url = rootURL ?? nestedURL,
              let data = try? Data(contentsOf: url) else { return }
        try? saveAppearanceImage(data: data, kind: kind)
    }

    /// URLSession 在 Task 被取消时抛的是 URLError.cancelled，不是 CancellationError。
    /// 两个都得认——否则 iOS 在后台掐断的请求会被当成真故障弹到她脸上。
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError { return urlError.code == .cancelled }
        return false
    }

    /// 网络本身抖了一下（切后台回来的死连接、没信号、超时）。这类不该弹窗骂她，
    /// 记下要重载，等 SSE 重新连上自己补。
    static func isTransientNetwork(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .networkConnectionLost, .notConnectedToInternet, .timedOut,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .dataNotAllowed, .internationalRoamingOff, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        guard let secret = KeychainStore.read(account: Keys.relaySecret),
              !secret.isEmpty,
              let url = try? Self.normalizedRelayURL(savedServerAddress) else {
            phase = .signedOut
            return
        }
        await connect(url: url, secret: secret, persist: false)
    }

    func login(serverAddress: String, secret: String) async {
        do {
            let url = try Self.normalizedRelayURL(serverAddress)
            let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedSecret.isEmpty else { throw APIError.unauthorized }
            await connect(url: url, secret: trimmedSecret, persist: true)
        } catch {
            phase = .signedOut
            errorMessage = error.localizedDescription
        }
    }

    func logout() {
        stream.stop()
        heartbeatTask?.cancel()
        heartbeatTask = nil
        incrementalSyncTask?.cancel()
        incrementalSyncTask = nil
        client = nil
        messages = []
        historyArchive = []
        sessions = []
        canLoadOlderHistory = false
        pendingAttachments = []
        bundledMessageParts = []
        replyBundleID = nil
        isSendingBundledMessage = false
        resetStreamingDrafts()
        updateTypingState(false)
        isStreamConnected = false
        clawdPetState = .idle
        removeHistoryCaches()
        KeychainStore.delete(account: Keys.relaySecret)
        phase = .signedOut
    }

    func noteEnteredBackground() {
        backgroundedAt = Date()
    }

    /// 回到前台。iOS 冻过一次进程之后这边可能是半死的：后台那趟历史被掐断
    /// （聊天空着）、SSE 连着但不吐、轮询任务已经退出。统一在这里自愈一次，
    /// 别再让她划掉 App 重开。
    func resumeFromForeground() async {
        guard !connectInFlight else { return }
        switch phase {
        case .connecting, .signedOut:
            return                      // 正在连 / 她自己登出了,都不该插手
        case .launching:
            didBootstrap = false        // 上一趟没连成(多半被后台掐了),重来
            await bootstrap()
            return
        case .connected:
            break
        }
        guard let client else {
            // .connected 却没有 client 是个坏状态,重连一次
            didBootstrap = false
            await bootstrap()
            return
        }
        // 在后台待久了,SSE 多半已被系统掐死、却还没报错(绿点亮着但不吐字)——直接换一条新的
        let longBackground = backgroundedAt.map { Date().timeIntervalSince($0) > 20 } ?? false
        backgroundedAt = nil
        if longBackground || !isStreamConnected { startStream(using: client) }
        if historyNeedsReload || messages.isEmpty {
            await loadHistory(showLoadingState: messages.isEmpty)
        }
        // 这两个循环任务在后台可能已经自己退了(sleep 被打断就 return),重开是幂等的
        startIncrementalSync(using: client)
        startHeartbeat()
        await catchUp(using: client)
    }

    func refresh() async {
        guard client != nil else { return }
        if let settings = try? await settingsChatMode() {
            chatMode = settings.mode
        }
        await loadHistory()
    }

    func loadOlderHistory() async -> Int? {
        guard !isLoadingOlderHistory, canLoadOlderHistory,
              let oldestID = messages.filter({ $0.id > 0 }).map(\.id).min() else {
            canLoadOlderHistory = false
            return nil
        }
        isLoadingOlderHistory = true
        defer { isLoadingOlderHistory = false }
        let older: [ChatMessage]
        if let oldestIndex = historyArchive.firstIndex(where: { $0.id == oldestID }), oldestIndex > 0 {
            // 手里的窗口还没翻完(跳转过之后会这样),先用手里的
            older = Array(historyArchive[max(0, oldestIndex - Self.olderHistoryPageSize)..<oldestIndex])
        } else {
            guard let client else { return nil }
            let sessionID = activeSessionID
            do {
                let batch = try await client.recentHistory(
                    before: oldestID,
                    limit: Self.olderHistoryPageSize,
                    sessionID: sessionID
                ).messages
                guard sessionID == activeSessionID else { return nil }
                canLoadOlderHistory = batch.count >= Self.olderHistoryPageSize
                older = visibleHistoryMessages(batch)
            } catch {
                // 断网之类:canLoadOlderHistory 保持 true,她再往上划一下会再试
                return nil
            }
        }
        guard !older.isEmpty else { return nil }
        var merged = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
        older.forEach { merged[$0.id] = $0 }
        messages = merged.values.sorted(by: Self.messageComesBefore)
        return oldestID
    }

    func searchMessages(_ query: String) async throws -> [ChatMessage] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return try await requireClient().search(trimmed).filter { !locallyHiddenMessageIDs.contains($0.id) }
    }

    func sessionTitle(for message: ChatMessage) -> String {
        guard let id = message.meta.apiSession, !id.isEmpty else { return "Claude Code" }
        return sessions.first(where: { $0.id == id })?.title ?? "对话窗口"
    }

    func jumpToMessage(_ message: ChatMessage) async {
        let targetSession = normalizedSessionID(message.meta.apiSession)
        if targetSession != activeSessionID {
            await activateSession(targetSession)
        }
        guard let index = historyArchive.firstIndex(where: { $0.id == message.id }) else {
            await jumpToRemoteMessage(message)
            return
        }
        let start = max(0, index - 45)
        let end = min(historyArchive.count, index + 46)
        messages = Array(historyArchive[start..<end])
        // 窗口顶上没了也还可能有更早的——交给 loadOlderHistory 去服务器问
        canLoadOlderHistory = true
        navigationRequest = MessageNavigationRequest(messageID: message.id)
    }

    /// 搜到的消息不在手里的最新窗口里:去服务器把它前后各四十几条要回来。
    private func jumpToRemoteMessage(_ message: ChatMessage) async {
        guard let client else { return }
        let sessionID = activeSessionID
        do {
            async let beforePage = client.recentHistory(before: message.id + 1, limit: 46, sessionID: sessionID)
            async let afterPage = client.history(since: message.id, limit: 45, sessionID: sessionID)
            let earlier = try await beforePage
            let later = try await afterPage
            let window = visibleHistoryMessages(earlier.messages + later)
            guard sessionID == activeSessionID else { return }
            guard window.contains(where: { $0.id == message.id }) else {
                errorMessage = "没有在当前记录中找到这条消息"
                return
            }
            messages = Dictionary(window.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
                .values.sorted(by: Self.messageComesBefore)
            canLoadOlderHistory = true
            navigationRequest = MessageNavigationRequest(messageID: message.id)
        } catch {
            guard !Self.isCancellation(error) else { return }
            errorMessage = "跳转失败：\(error.localizedDescription)"
        }
    }

    func refreshSessions() async {
        guard let client else { return }
        isLoadingSessions = true
        defer { isLoadingSessions = false }
        do {
            applySessionsResponse(try await client.sessions(), chooseServerActiveWhenNeeded: false)
        } catch {
            sessions = []
        }
    }

    func activateSession(_ id: String) async {
        guard let client else { return }
        let next = normalizedSessionID(id)
        guard next != activeSessionID else { return }
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        do {
            applySessionsResponse(try await client.updateSession(id: next, active: true), chooseServerActiveWhenNeeded: false)
            activeSessionID = next
            UserDefaults.standard.set(next, forKey: Keys.activeSessionID)
            resetStreamingDrafts()
            updateTypingState(false)
            await loadHistory(showLoadingState: false)
        } catch {
            guard !Self.isCancellation(error) else { return }
            errorMessage = "切换对话失败：\(error.localizedDescription)"
        }
    }

    func createSession(body: BrainTarget, title: String? = nil) async throws {
        let fallback = body == .codex ? "Codex 对话" : "API 对话"
        let response = try await requireClient().createSession(title: title ?? fallback, body: body)
        applySessionsResponse(response, chooseServerActiveWhenNeeded: true)
        if let created = response.created {
            activeSessionID = created.id
        } else if let active = response.activeSession, !active.isEmpty {
            activeSessionID = active
        }
        UserDefaults.standard.set(activeSessionID, forKey: Keys.activeSessionID)
        historyArchive = []
        messages = []
        canLoadOlderHistory = false
        bundledMessageParts = []
        replyBundleID = nil
        resetStreamingDrafts()
    }

    func renameSession(id: String, title: String) async throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        applySessionsResponse(
            try await requireClient().updateSession(id: id, title: trimmed),
            chooseServerActiveWhenNeeded: false
        )
    }

    func deleteSession(id: String) async throws {
        let wasActive = activeSessionID == id
        let response = try await requireClient().deleteSession(id: id)
        applySessionsResponse(response, chooseServerActiveWhenNeeded: true)
        if wasActive {
            activeSessionID = normalizedSessionID(response.activeSession)
            UserDefaults.standard.set(activeSessionID, forKey: Keys.activeSessionID)
            await loadHistory()
        }
    }

    func editMessage(id: Int, text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        upsert(try await requireClient().editMessage(id: id, text: trimmed))
    }

    func regenerateMessage(id: Int) async throws {
        try await requireClient().regenerateMessage(id: id)
        typingSuppressedUntil = .distantPast
        updateTypingState(true)
    }

    func hideMessageLocally(id: Int) {
        guard id > 0 else {
            messages.removeAll { $0.id == id }
            return
        }
        locallyHiddenMessageIDs.insert(id)
        UserDefaults.standard.set(Array(locallyHiddenMessageIDs).sorted(), forKey: Keys.locallyHiddenMessageIDs)
        messages.removeAll { $0.id == id }
        historyArchive.removeAll { $0.id == id }
    }

    var activeSessionTitle: String {
        if activeSessionID == Self.legacySessionID { return "Claude Code" }
        return sessions.first(where: { $0.id == activeSessionID })?.title ?? "对话窗口"
    }

    private var activeWireSessionID: String? {
        activeSessionID == Self.legacySessionID ? nil : activeSessionID
    }

    /// 后台 fetch 只需要一个能拉新消息的 client。**绝不在后台跑整套 bootstrap**——
    /// 那会连着翻几百页历史，多半在系统给的时间窗里被掐断，留下一个空聊天、
    /// 一句 cancelled，和一个回前台再也不会重连的 .connected 状态。
    /// （她 2026-09-04 报的：切后台回来聊天全没了，非杀进程不可。）
    private func backgroundOnlyClient() -> APIClient? {
        guard let secret = KeychainStore.read(account: Keys.relaySecret), !secret.isEmpty,
              let url = try? Self.normalizedRelayURL(savedServerAddress) else { return nil }
        return APIClient(baseURL: url, secret: secret)
    }

    func backgroundRefreshForNotifications() async -> Bool {
        guard let client = client ?? backgroundOnlyClient() else { return false }
        let lastNotified = UserDefaults.standard.integer(forKey: Keys.lastNativeNotificationID)
        let visibleHistoryCursor = messages.map(\.id).filter { $0 > 0 }.max() ?? 0
        let historyCursor = max(visibleHistoryCursor, lastNotified)
        guard historyCursor > 0 else { return false }
        do {
            let fetched = try await client.history(since: historyCursor, limit: 100).filter { !$0.meta.hidden }
            let newestFetchedID = fetched.map(\.id).filter { $0 > 0 }.max() ?? historyCursor
            if lastNotified == 0 {
                fetched.forEach { upsert($0, allowsNativeArrival: false) }
                markNativeNotificationCursor(newestFetchedID)
                return false
            }
            var deliveredNativeEvent = false
            for message in fetched {
                let isNewForNotifications = message.id > lastNotified
                upsert(message, allowsNativeArrival: isNewForNotifications)
                if isNewForNotifications, message.author == .ai,
                   message.kind == "reply" || isFreshIncomingCall(message) {
                    deliveredNativeEvent = true
                }
            }
            markNativeNotificationCursor(newestFetchedID)
            return deliveredNativeEvent
        } catch {
            return false
        }
    }

    func sendMessage(text rawText: String) async {
        guard client != nil else { return }
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pendingAttachments
        guard !text.isEmpty || !attachments.isEmpty else { return }
        pendingAttachments = []
        _ = await deliverMessage(text: text, attachments: attachments)
    }

    func stageBundledMessage(text rawText: String) async {
        guard client != nil else { return }
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pendingAttachments
        guard !text.isEmpty || !attachments.isEmpty else { return }
        pendingAttachments = []
        let bundleID = replyBundleID ?? UUID().uuidString
        replyBundleID = bundleID
        let part = BundledMessagePart(text: text, attachments: attachments)
        bundledMessageParts.append(part)

        guard let messageID = await deliverMessage(
            text: text,
            attachments: attachments,
            deferReply: true,
            bundleID: bundleID
        ) else {
            bundledMessageParts.removeAll { $0.id == part.id }
            if bundledMessageParts.isEmpty { replyBundleID = nil }
            return
        }
        if let index = bundledMessageParts.firstIndex(where: { $0.id == part.id }) {
            bundledMessageParts[index].messageID = messageID
        }
    }

    func sendBundledMessages() async {
        guard let client, !isSendingBundledMessage, !bundledMessageParts.isEmpty,
              let bundleID = replyBundleID else { return }
        let messageIDs = bundledMessageParts.compactMap(\.messageID)
        guard messageIDs.count == bundledMessageParts.count else { return }
        isSendingBundledMessage = true
        defer { isSendingBundledMessage = false }
        typingSuppressedUntil = .distantPast
        updateTypingState(true)
        do {
            _ = try await client.releaseReplyBundle(
                bundleID: bundleID,
                messageIDs: messageIDs,
                sessionID: activeSessionID == Self.legacySessionID ? nil : activeSessionID
            )
            bundledMessageParts = []
            replyBundleID = nil
        } catch {
            updateTypingState(false)
            errorMessage = "统一发送失败：\(error.localizedDescription)"
        }
    }

    @discardableResult
    private func deliverMessage(
        text: String,
        attachments: [Attachment],
        deferReply: Bool = false,
        bundleID: String? = nil
    ) async -> Int? {
        guard let client else { return nil }

        temporaryID -= 1
        let tempID = temporaryID
        var optimisticMeta = MessageMeta(
            attachments: attachments,
            apiSession: activeSessionID == Self.legacySessionID ? nil : activeSessionID
        )
        optimisticMeta.replyBundleID = bundleID
        optimisticMeta.replyDeferred = deferReply
        let optimistic = ChatMessage(
            id: tempID,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            author: .human,
            kind: "user",
            text: text,
            meta: optimisticMeta,
            delivery: .sending
        )
        messages.append(optimistic)
        if !deferReply {
            // Show feedback immediately. The relay also broadcasts a typing event,
            // but that frame can arrive before the POST response on some iOS stacks.
            typingSuppressedUntil = .distantPast
            updateTypingState(true)
        }

        do {
            let response = try await client.send(
                text: text,
                attachments: attachments,
                sessionID: activeSessionID == Self.legacySessionID ? nil : activeSessionID,
                deferReply: deferReply,
                bundleID: bundleID
            )
            if let realIndex = messages.firstIndex(where: { $0.id == response.id }) {
                messages[realIndex].delivery = .sent
                messages.removeAll { $0.id == tempID }
            } else if let tempIndex = messages.firstIndex(where: { $0.id == tempID }) {
                messages[tempIndex].id = response.id
                messages[tempIndex].delivery = .sent
                historyArchive.append(messages[tempIndex])
                historyArchive.sort(by: Self.messageComesBefore)
            }
            return response.id
        } catch {
            if !deferReply { updateTypingState(false) }
            if let index = messages.firstIndex(where: { $0.id == tempID }) {
                messages[index].delivery = .failed
            }
            errorMessage = "发送失败：\(error.localizedDescription)"
            return nil
        }
    }

    func uploadImage(data: Data, name: String, mime: String) async {
        await uploadAttachment(data: data, name: name, mime: mime)
    }

    func uploadAttachment(data: Data, name: String, mime: String) async {
        guard let client else { return }
        isUploading = true
        defer { isUploading = false }
        do {
            pendingAttachments.append(try await client.upload(data: data, name: name, mime: mime))
        } catch {
            errorMessage = "附件上传失败：\(error.localizedDescription)"
        }
    }

    func prepareScreenShare() async throws -> ScreenSharePreparation {
        try await requireClient().prepareScreenShare(
            sessionID: activeSessionID == Self.legacySessionID ? nil : activeSessionID
        )
    }

    func screenShareProbeStatus(probeID: String) async throws -> ScreenShareProbeStatus {
        try await requireClient().screenShareProbeStatus(probeID: probeID)
    }

    func removePendingAttachment(_ attachment: Attachment) {
        pendingAttachments.removeAll { $0.id == attachment.id }
    }

    func attachmentRequest(for attachment: Attachment) -> URLRequest? {
        client?.attachmentRequest(path: attachment.url)
    }

    func authenticatedRequest(path: String) -> URLRequest? {
        client?.attachmentRequest(path: path)
    }

    func spaceStars() async throws -> [ChatMessage] { try await requireClient().stars() }
    func spaceAlbum() async throws -> [AlbumPhoto] { try await requireClient().album() }
    func spaceGiftPages() async throws -> [GiftPage] { try await requireClient().giftPages() }
    func giftPageURL(file: String) -> URL? { client?.giftPageURL(file: file) }

    func answerAsk(messageID: Int, index: Int? = nil, text: String? = nil) async throws {
        let ask = try await requireClient().answerAsk(messageID: messageID, index: index, text: text)
        updateAsk(messageID: messageID, ask: ask)
    }

    /// 她按了「给你看」：领一次性票据 → 挂本机交接 → 替她点开系统广播按钮。
    /// 那颗按钮藏在系统视图层级里，点不着就把卡片切成手点模式——绝不假装已经开了。
    func acceptPeek(messageID: Int) async throws {
        let preparation = try await requireClient().acceptPeek(messageID: messageID)
        markPeekStatus(messageID: messageID, "accepted")
        guard preparation.localHandoffReady else {
            peekManualPickerID = messageID
            throw APIError.server(preparation.localHandoffDiagnostic ?? "本机票据通道没能打开")
        }
        peekManualPickerID = ScreenBroadcastLauncher.present() ? nil : messageID
    }

    func declinePeek(messageID: Int) async throws {
        let peek = try await requireClient().declinePeek(messageID: messageID)
        if peekManualPickerID == messageID { peekManualPickerID = nil }
        updatePeek(messageID: messageID, peek: peek)
    }

    func greetingForCurrentTime() async -> String? {
        let defaults = UserDefaults.standard
        let pool: GreetingPool?
        do {
            let fresh = try await requireClient().greetings()
            if let data = try? JSONEncoder().encode(fresh) {
                defaults.set(data, forKey: Keys.greetingCache)
            }
            pool = fresh
        } catch {
            pool = defaults.data(forKey: Keys.greetingCache)
                .flatMap { try? JSONDecoder().decode(GreetingPool.self, from: $0) }
        }
        guard let lines = pool?.slots[Self.greetingSlot(for: Date())], !lines.isEmpty else { return nil }
        return lines.randomElement()
    }

    func desireState() async throws -> DesireState {
        try await requireClient().desire()
    }

    func updateDesire(enabled: Bool? = nil, libidoMultiplier: Double? = nil) async throws -> DesireState {
        let client = try requireClient()
        try await client.updateDesire(enabled: enabled, libidoMultiplier: libidoMultiplier)
        return try await client.desire()
    }

    func refreshSpaceUnreadCounts() async {
        do {
            updateGiftUnread(with: try await requireClient().giftPages())
        } catch {
            // Keep the last trustworthy count when the room is temporarily offline.
        }

        do {
            let client = try requireClient()
            let moments = try await client.moments(kind: .moment, limit: 100).posts
            let journals = try await client.moments(kind: .journal, limit: 100).posts
            updateMomentUnread(with: moments + journals)
        } catch {
            // The two badges are independent; one failed endpoint should not erase either count.
        }
    }

    func markGiftPagesRead(_ pages: [GiftPage]) {
        currentGiftTokens.formUnion(pages.map(Self.giftToken))
        let defaults = UserDefaults.standard
        var seen = Set(defaults.stringArray(forKey: Keys.seenGiftTokens) ?? [])
        seen.formUnion(currentGiftTokens)
        defaults.set(Array(seen), forKey: Keys.seenGiftTokens)
        giftUnreadCount = 0
    }

    func markCurrentMomentsRead() {
        let defaults = UserDefaults.standard
        var seen = Set((defaults.array(forKey: Keys.seenAIPostIDs) as? [Int]) ?? [])
        seen.formUnion(currentAIPostIDs)
        defaults.set(Array(seen), forKey: Keys.seenAIPostIDs)
        momentsUnreadCount = 0
    }

    func markAllMomentsRead() async {
        do {
            let client = try requireClient()
            let moments = try await client.moments(kind: .moment, limit: 100).posts
            let journals = try await client.moments(kind: .journal, limit: 100).posts
            currentAIPostIDs.formUnion((moments + journals).filter { $0.author == .ai }.map(\.id))
        } catch {
            // The snapshot already loaded by the space home is still safe to mark.
        }
        markCurrentMomentsRead()
    }

    func markMomentPostsRead(_ posts: [MomentPost]) {
        currentAIPostIDs.formUnion(posts.filter { $0.author == .ai }.map(\.id))
        markCurrentMomentsRead()
    }

    func setStar(messageID: Int, on: Bool) async throws {
        let starred = try await requireClient().setStar(messageID: messageID, on: on)
        if let index = messages.firstIndex(where: { $0.id == messageID }) {
            messages[index].meta.starred = starred
        }
        if let index = historyArchive.firstIndex(where: { $0.id == messageID }) {
            historyArchive[index].meta.starred = starred
        }
    }

    func reactToMessage(messageID: Int, emoji: String) async throws {
        let reactions = try await requireClient().reactToMessage(id: messageID, emoji: emoji)
        updateReactions(messageID: messageID, reactions: reactions)
    }

    func translateThinking(messageID: Int) async throws -> String {
        let translation = try await requireClient().translateThinking(messageID: messageID)
        if let index = messages.firstIndex(where: { $0.id == messageID }) {
            messages[index].meta.translations["zh-Hans"] = translation
        }
        if let index = historyArchive.firstIndex(where: { $0.id == messageID }) {
            historyArchive[index].meta.translations["zh-Hans"] = translation
        }
        return translation
    }

    func completeTimer(messageID: Int) async throws {
        let timer = try await requireClient().completeTimer(messageID: messageID)
        updateTimer(messageID: messageID, timer: timer)
    }

    func sendVoiceRecording(_ recording: VoiceRecordingResult) async -> Bool {
        guard let client else { return false }
        isUploadingVoice = true
        defer { isUploadingVoice = false }
        do {
            let response = try await client.sendVoiceAudio(
                data: recording.data,
                name: recording.name,
                mime: recording.mime,
                sessionID: activeWireSessionID
            )
            let echoedRows = try? await client.history(
                since: max(0, response.id - 1),
                limit: 2,
                sessionID: activeSessionID
            )
            let echoedVoice = echoedRows?.first(where: { $0.id == response.id })
            if let echoedVoice {
                // The persisted row contains the full acoustic/emotion line;
                // the upload response intentionally carries only the transcript.
                upsert(echoedVoice)
            } else if !messages.contains(where: { $0.id == response.id }) {
                let transcript = Self.voiceTextWithoutMicrophone(response.text ?? "")
                upsert(ChatMessage(
                    id: response.id,
                    timestamp: ISO8601DateFormatter().string(from: Date()),
                    author: .human,
                    kind: "voice",
                    text: transcript,
                    meta: MessageMeta(
                        attachments: response.attachment.map { [$0] } ?? [],
                        apiSession: activeWireSessionID
                    ),
                    delivery: .sent
                ))
            }
            await catchUp(using: client)
            return true
        } catch {
            errorMessage = "语音发送失败：\(error.localizedDescription)"
            return false
        }
    }

    private static func voiceTextWithoutMicrophone(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["🎙️", "🎤", "🎙"] where text.hasPrefix(prefix) {
            return String(text.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    func sendCallTranscript(_ text: String, callID: String) async throws -> VoiceResponse {
        let client = try requireClient()
        let response = try await client.sendVoiceText(
            text,
            source: "ios_speech",
            callID: callID,
            sessionID: activeWireSessionID
        )
        await catchUp(using: client)
        return response
    }

    /// 通话里说完的一句：转写和这句话的录音一起送。
    /// 录音会挂在她自己的气泡上（像语音条），也让耳朵听得见她是怎么说的。
    func sendCallUtterance(
        text: String,
        data: Data,
        name: String,
        mime: String,
        callID: String
    ) async throws -> VoiceResponse {
        let client = try requireClient()
        let response = try await client.sendVoiceAudio(
            data: data,
            name: name,
            mime: mime,
            callID: callID,
            text: text,
            sessionID: activeWireSessionID
        )
        await catchUp(using: client)
        return response
    }

    func sendCallAudioSegment(data: Data, name: String, mime: String, callID: String) async throws -> VoiceResponse {
        let client = try requireClient()
        let response = try await client.sendVoiceAudio(
            data: data,
            name: name,
            mime: mime,
            callID: callID,
            sessionID: activeWireSessionID
        )
        await catchUp(using: client)
        return response
    }

    private var incomingCallSessions: [Int: String] = [:]
    private var answeredCallMessageID: Int?

    func prepareIncomingCall(messageID: Int) async -> Bool {
        guard let session = incomingCallSessions[messageID] else { return false }
        await activateSession(session)
        guard activeSessionID == normalizedSessionID(session) else { return false }
        answeredCallMessageID = messageID
        return true
    }

    func postCallEvent(_ action: String, callID: String, messageID: Int? = nil) async throws {
        _ = try await requireClient().callEvent(
            action,
            callID: callID,
            messageID: messageID ?? (action == "start" ? answeredCallMessageID : nil),
            sessionID: activeWireSessionID
        )
        if action == "start" || action == "end" { answeredCallMessageID = nil }
    }

    private func markIncomingCallMissed(messageID: Int) async {
        guard messageID > 0 else { return }
        missedCallMessageIDs.insert(messageID)
        pendingMissedCallMessageIDs.insert(messageID)
        persistMissedCallState()
        applyMissedCallState(messageID: messageID)
        await flushPendingCallDeclines()
    }

    private func flushPendingCallDeclines() async {
        guard let client else { return }
        for messageID in pendingMissedCallMessageIDs.sorted() {
            do {
                _ = try await client.callEvent(
                    "decline",
                    callID: "incoming-\(messageID)",
                    messageID: messageID
                )
                pendingMissedCallMessageIDs.remove(messageID)
            } catch {
                // Keep it queued. The next successful connection retries the
                // idempotent server update so CallKit declines are never lost.
            }
        }
        persistMissedCallState()
    }

    private func applyMissedCallState(messageID: Int) {
        if let index = messages.firstIndex(where: { $0.id == messageID }) {
            messages[index].meta.callStatus = "missed"
        }
        if let index = historyArchive.firstIndex(where: { $0.id == messageID }) {
            historyArchive[index].meta.callStatus = "missed"
        }
    }

    private func persistMissedCallState() {
        UserDefaults.standard.set(missedCallMessageIDs.sorted(), forKey: Keys.missedCallMessageIDs)
        UserDefaults.standard.set(pendingMissedCallMessageIDs.sorted(), forKey: Keys.pendingMissedCallMessageIDs)
    }

    func synthesizeSpeech(text: String, messageID: Int? = nil, persist: Bool = false) async throws -> Data {
        try await requireClient().tts(text: text, messageID: messageID, persist: persist)
    }

    func speakMessage(_ message: ChatMessage) async {
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, isSynthesizingMessageID == nil else { return }
        isSynthesizingMessageID = message.id
        defer { isSynthesizingMessageID = nil }
        do {
            let data = try await synthesizeSpeech(text: text)
            try VoicePlaybackCenter.shared.play(data: data, id: "tts-\(message.id)")
        } catch {
            errorMessage = "朗读失败：\(error.localizedDescription)"
        }
    }

    func spaceMoments(kind: MomentKind, before: Int? = nil, limit: Int = 20) async throws -> MomentsResponse {
        try await requireClient().moments(kind: kind, before: before, limit: limit)
    }

    func uploadMomentImage(data: Data, name: String, mime: String) async throws -> Attachment {
        try await requireClient().upload(data: data, name: name, mime: mime)
    }

    func createMoment(kind: MomentKind, text: String, attachments: [Attachment]) async throws -> MomentPost {
        try await requireClient().createMoment(kind: kind, text: text, attachments: attachments)
    }

    func likeMoment(id: Int, on: Bool) async throws -> [String: String] {
        try await requireClient().likeMoment(id: id, on: on)
    }

    func commentMoment(id: Int, text: String, replyTo: MessageAuthor? = nil) async throws -> MomentComment {
        try await requireClient().commentMoment(id: id, text: text, replyTo: replyTo)
    }

    func deleteMoment(id: Int) async throws { try await requireClient().deleteMoment(id: id) }

    // MARK: - 书房

    func bookShelf() async throws -> [Book] { try await requireClient().books() }

    func importBook(data: Data, name: String) async throws -> BookImportResult {
        try await requireClient().uploadBook(data: data, name: name)
    }

    func removeBook(id: Int) async throws { try await requireClient().deleteBook(id: id) }

    func bookChapter(bookID: Int, index: Int) async throws -> BookChapter {
        try await requireClient().bookChapter(bookID: bookID, index: index)
    }

    func reportBookProgress(bookID: Int, chapter: Int, offset: Int) async throws -> BookProgressResponse {
        try await requireClient().reportBookProgress(bookID: bookID, chapter: chapter, offset: offset)
    }

    func annotateBook(
        bookID: Int,
        chapterIdx: Int,
        start: Int,
        end: Int,
        quote: String,
        note: String
    ) async throws -> BookAnnotation {
        try await requireClient().annotateBook(
            bookID: bookID, chapterIdx: chapterIdx, start: start, end: end, quote: quote, note: note
        )
    }

    func deleteBookAnnotation(id: Int) async throws {
        try await requireClient().deleteBookAnnotation(id: id)
    }

    func bookThread(bookID: Int, annotationIDs: [Int]) async throws -> [ChatMessage] {
        try await requireClient().bookThread(bookID: bookID, annotationIDs: annotationIDs)
    }

    /// 从书页里说的一句话。走主聊天流，所以照常触发打字提示。
    func sendFromBook(text: String, bookRef: BookRef) async throws {
        let client = try requireClient()
        typingSuppressedUntil = .distantPast
        updateTypingState(true)
        _ = try await client.sendFromBook(
            text: text,
            bookRef: bookRef,
            sessionID: activeSessionID == Self.legacySessionID ? nil : activeSessionID
        )
    }

    func spaceCalendar(year: Int, month: Int) async throws -> CalendarMonthResponse {
        try await requireClient().calendar(year: year, month: month)
    }

    func relationshipAnniversary() async throws -> AnniversarySummary? {
        try await requireClient().anniversary()
    }

    func createCalendarEvent(_ payload: CalendarCreatePayload) async throws -> CalendarEvent {
        try await requireClient().createCalendarEvent(payload)
    }

    func deleteCalendarEvent(id: Int) async throws { try await requireClient().deleteCalendarEvent(id: id) }

    func resolvedAIBubbleColor(default fallback: Color) -> Color {
        Color(hexString: aiBubbleColorHex) ?? fallback
    }

    func resolvedHumanBubbleColor(default fallback: Color) -> Color {
        Color(hexString: humanBubbleColorHex) ?? fallback
    }

    func resolvedAIBubbleTextColor(default fallback: Color) -> Color {
        Color(hexString: aiBubbleTextColorHex) ?? fallback
    }

    func resolvedHumanBubbleTextColor(default fallback: Color) -> Color {
        Color(hexString: humanBubbleTextColorHex) ?? fallback
    }

    /// nil 时各处保留自己原来的次要文字色（有的主题会再叠一层透明度）。
    var customProcessTitleColor: Color? { Color(hexString: processTitleColorHex) }
    var customTimestampColor: Color? { Color(hexString: timestampColorHex) }
    var bubblePaddingOffset: CGSize { CGSize(width: bubblePaddingX, height: bubblePaddingY) }

    func setProcessTitleColor(_ color: Color) {
        processTitleColorHex = Self.hexString(color) ?? ""
    }

    func setTimestampColor(_ color: Color) {
        timestampColorHex = Self.hexString(color) ?? ""
    }

    func setAIBubbleColor(_ color: Color) {
        aiBubbleColorHex = Self.hexString(color) ?? ""
    }

    func setHumanBubbleColor(_ color: Color) {
        humanBubbleColorHex = Self.hexString(color) ?? ""
    }

    func setAIBubbleTextColor(_ color: Color) {
        aiBubbleTextColorHex = Self.hexString(color) ?? ""
    }

    func setHumanBubbleTextColor(_ color: Color) {
        humanBubbleTextColorHex = Self.hexString(color) ?? ""
    }

    func resetBubbleColors() {
        aiBubbleColorHex = ""
        humanBubbleColorHex = ""
        aiBubbleTextColorHex = ""
        humanBubbleTextColorHex = ""
        processTitleColorHex = ""
        timestampColorHex = ""
        UserDefaults.standard.removeObject(forKey: Keys.bubbleTextColor)
    }

    // MARK: Saved appearances

    private var currentAppearanceValues: SavedAppearance.Values {
        SavedAppearance.Values(
            theme: theme.rawValue,
            chatLayoutStyle: chatLayoutStyle.rawValue,
            composerStyle: composerStyle.rawValue,
            chatFont: chatFont.rawValue,
            humanChatFont: humanChatFont?.rawValue,
            journalFont: journalFont?.rawValue,
            processTitleFont: processTitleFont?.rawValue,
            showsProcessDisclosure: showsProcessDisclosure,
            fontScale: fontScale,
            humanFontScale: humanFontScale,
            chatWeight: chatWeight,
            showsAIAvatar: showsAIAvatar,
            showsHumanAvatar: showsHumanAvatar,
            showsAIBubble: showsAIBubble,
            aiBubbleOpacity: aiBubbleOpacity,
            humanBubbleOpacity: humanBubbleOpacity,
            bubbleRadius: bubbleRadius,
            bubbleWidthScale: bubbleWidthScale,
            bubblePaddingX: bubblePaddingX,
            bubblePaddingY: bubblePaddingY,
            bubbleBorderWidth: bubbleBorderWidth,
            bubbleStyle: bubbleStyle.rawValue,
            bubbleShapeStyle: bubbleShapeStyle.rawValue,
            liquidGlassStrength: liquidGlassStrength,
            liquidGlassDispersion: liquidGlassDispersion,
            liquidGlassRimWidth: liquidGlassRimWidth,
            liquidGlassMagnify: liquidGlassMagnify,
            liquidGlassBlur: liquidGlassBlur,
            liquidGlassSize: liquidGlassSize,
            aiBubbleColorHex: aiBubbleColorHex,
            humanBubbleColorHex: humanBubbleColorHex,
            aiBubbleTextColorHex: aiBubbleTextColorHex,
            humanBubbleTextColorHex: humanBubbleTextColorHex,
            processTitleColorHex: processTitleColorHex,
            timestampColorHex: timestampColorHex,
            backgroundOpacity: backgroundOpacity,
            backgroundBlur: backgroundBlur
        )
    }

    /// Saves the current look as a new theme, or overwrites `existing` while keeping its name.
    func saveCurrentAppearance(named name: String, replacing existing: SavedAppearance? = nil) throws {
        let id = existing?.id ?? UUID()
        let wallpaperURL = try SavedAppearanceStore.backgroundURL(for: id)
        var hasBackground = false
        if backgroundImage != nil,
           let data = try? Data(contentsOf: Self.appearanceImageURL(.background)) {
            try data.write(to: wallpaperURL, options: [.atomic, .completeFileProtection])
            hasBackground = true
        } else {
            try? FileManager.default.removeItem(at: wallpaperURL)
        }
        let saved = SavedAppearance(
            id: id,
            name: existing?.name ?? name,
            createdAt: existing?.createdAt ?? Date(),
            updatedAt: Date(),
            hasBackground: hasBackground,
            values: currentAppearanceValues
        )
        if let index = savedAppearances.firstIndex(where: { $0.id == id }) {
            savedAppearances[index] = saved
        } else {
            savedAppearances.append(saved)
        }
    }

    func applySavedAppearance(_ saved: SavedAppearance) {
        let v = saved.values
        // Set the theme directly, not through applyTheme: its presets would
        // overwrite the saved values, and the launch-time preset migration is
        // marked done so it cannot replace them on the next start either.
        theme = EchoTheme(rawValue: v.theme) ?? theme
        for key in [Keys.paperPresetV3, Keys.harborPresetV1, Keys.nestPresetV1] {
            UserDefaults.standard.set(true, forKey: key)
        }
        chatLayoutStyle = ChatLayoutStyle(rawValue: v.chatLayoutStyle) ?? chatLayoutStyle
        composerStyle = ComposerStyle(rawValue: v.composerStyle) ?? composerStyle
        chatFont = Self.storedFont(v.chatFont, imported: importedChatFonts) ?? .system
        humanChatFont = Self.storedFont(v.humanChatFont, imported: importedChatFonts)
        journalFont = Self.storedFont(v.journalFont, imported: importedChatFonts)
        processTitleFont = Self.storedFont(v.processTitleFont, imported: importedChatFonts)
        showsProcessDisclosure = v.showsProcessDisclosure ?? true
        fontScale = v.fontScale
        humanFontScale = v.humanFontScale
        chatWeight = v.chatWeight
        showsAIAvatar = v.showsAIAvatar
        showsHumanAvatar = v.showsHumanAvatar
        showsAIBubble = v.showsAIBubble
        aiBubbleOpacity = v.aiBubbleOpacity
        humanBubbleOpacity = v.humanBubbleOpacity
        bubbleRadius = v.bubbleRadius
        bubbleWidthScale = v.bubbleWidthScale
        bubblePaddingX = v.bubblePaddingX
        bubblePaddingY = v.bubblePaddingY
        bubbleBorderWidth = v.bubbleBorderWidth
        bubbleStyle = EchoBubbleStyle(rawValue: v.bubbleStyle) ?? bubbleStyle
        bubbleShapeStyle = EchoBubbleShapeStyle(rawValue: v.bubbleShapeStyle) ?? bubbleShapeStyle
        liquidGlassStrength = v.liquidGlassStrength
        liquidGlassDispersion = v.liquidGlassDispersion
        liquidGlassRimWidth = v.liquidGlassRimWidth
        liquidGlassMagnify = v.liquidGlassMagnify
        liquidGlassBlur = v.liquidGlassBlur
        liquidGlassSize = v.liquidGlassSize
        aiBubbleColorHex = v.aiBubbleColorHex
        humanBubbleColorHex = v.humanBubbleColorHex
        aiBubbleTextColorHex = v.aiBubbleTextColorHex
        humanBubbleTextColorHex = v.humanBubbleTextColorHex
        processTitleColorHex = v.processTitleColorHex
        timestampColorHex = v.timestampColorHex
        backgroundOpacity = v.backgroundOpacity
        backgroundBlur = v.backgroundBlur

        // Copy the stored file as-is; saveAppearanceImage would re-encode the JPEG each time.
        if saved.hasBackground,
           let source = try? SavedAppearanceStore.backgroundURL(for: saved.id),
           let data = try? Data(contentsOf: source),
           let image = UIImage(data: data),
           let target = try? Self.appearanceImageURL(.background),
           (try? data.write(to: target, options: [.atomic, .completeFileProtection])) != nil {
            setAppearanceImage(image, kind: .background)
        } else {
            removeAppearanceImage(.background)
        }
    }

    func deleteSavedAppearance(_ saved: SavedAppearance) {
        if let url = try? SavedAppearanceStore.backgroundURL(for: saved.id) {
            try? FileManager.default.removeItem(at: url)
        }
        savedAppearances.removeAll { $0.id == saved.id }
    }

    /// The saved wallpaper, for the theme list thumbnail.
    func savedAppearanceBackground(_ saved: SavedAppearance) -> UIImage? {
        guard saved.hasBackground,
              let url = try? SavedAppearanceStore.backgroundURL(for: saved.id),
              let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    func saveAppearanceImage(data: Data, kind: AppearanceImageKind) throws {
        guard let original = UIImage(data: data) else { throw APIError.invalidResponse }
        let maxDimension: CGFloat = kind == .background ? 2200 : 640
        let image = Self.resizedImage(original, maxDimension: maxDimension)
        guard let encoded = image.jpegData(compressionQuality: kind == .background ? 0.84 : 0.9) else {
            throw APIError.invalidResponse
        }
        let url = try Self.appearanceImageURL(kind)
        try encoded.write(to: url, options: [.atomic, .completeFileProtection])
        setAppearanceImage(image, kind: kind)
    }

    func removeAppearanceImage(_ kind: AppearanceImageKind) {
        if let url = try? Self.appearanceImageURL(kind) {
            try? FileManager.default.removeItem(at: url)
        }
        setAppearanceImage(nil, kind: kind)
    }

    func settingsBrain() async throws -> BrainTarget {
        try await requireClient().brain()
    }

    func updateSettingsBrain(_ target: BrainTarget) async throws -> BrainTarget {
        try await requireClient().setBrain(target)
    }

    func settingsLoopConfig() async throws -> LoopConfigResponse {
        let config = try await requireClient().loopConfig()
        apiUsagePrices = config.prices
        apiUsageCacheTTL = config.cacheTTL
        return config
    }

    func apiUsageText(for message: ChatMessage) -> String? {
        guard showsAPIMessageUsage, message.author == .ai, message.kind == "reply",
              let api = message.meta.api, api.runtime == "api_loop" else { return nil }
        return api.usage?.summary(prices: apiUsagePrices, cacheTTL: apiUsageCacheTTL)
    }

    func updateLoopModel(_ modelID: String, chainCount: Int) async throws -> LoopConfigResponse {
        try await requireClient().setLoopModel(modelID, chainCount: chainCount)
    }

    func activateAPIPreset(_ index: Int) async throws -> LoopConfigResponse {
        try await requireClient().activateAPIPreset(index)
    }

    func replaceAPIPresets(_ presets: [APIPresetInput]) async throws -> LoopConfigResponse {
        try await requireClient().replaceAPIPresets(presets)
    }

    func setLoopEffort(_ effort: String) async throws -> LoopConfigResponse {
        try await requireClient().setLoopEffort(effort)
    }

    func settingsChatMode() async throws -> ChatModeResponse {
        let settings = try await requireClient().chatMode()
        chatMode = settings.mode
        return settings
    }

    func updateChatMode(_ mode: ChatMode) async throws -> ChatMode {
        let savedMode = try await requireClient().setChatMode(mode)
        chatMode = savedMode
        return savedMode
    }

    func updateShortChatStripTerminalPeriods(_ enabled: Bool, mode: ChatMode) async throws -> ChatModeResponse {
        let settings = try await requireClient().setShortChatStripTerminalPeriods(enabled, mode: mode)
        chatMode = settings.mode
        return settings
    }

    func settingsQuota() async throws -> QuotaResponse {
        try await requireClient().quota()
    }

    func settingsCodexQuota() async throws -> CodexQuotaResponse {
        try await requireClient().codexQuota()
    }

    func settingsAPIUsage() async throws -> APIUsageStats {
        try await requireClient().loopStats()
    }

    func terminalTail(body: String, after: Int) async throws -> TerminalTailResponse {
        try await requireClient().terminalTail(body: body, after: after)
    }

    func settingsDesktopModel() async throws -> DesktopModelResponse {
        try await requireClient().desktopModel()
    }

    func updateDesktopModel(_ modelID: String) async throws -> DesktopModelResponse {
        try await requireClient().setDesktopModel(modelID)
    }

    func settingsContextStatus() async throws -> ContextStatus {
        try await requireClient().contextStatus()
    }

    func updateContextThreshold(triggerK: Int? = nil, auto: Bool? = nil, forgeRounds: Int? = nil) async throws -> ContextThresholdResponse {
        try await requireClient().updateContextThreshold(triggerK: triggerK, auto: auto, forgeRounds: forgeRounds)
    }

    func settingsForgeStatus(previewRounds: Int? = nil) async throws -> ForgeStatus {
        try await requireClient().forgeStatus(previewRounds: previewRounds)
    }

    func settingsDesktopKeepalive() async throws -> DesktopKeepaliveStatus {
        try await requireClient().desktopKeepalive()
    }

    func updateDesktopKeepalive(_ enabled: Bool) async throws -> DesktopKeepaliveStatus {
        try await requireClient().setDesktopKeepalive(enabled)
    }

    func clawdPetGIFURL() -> URL? {
        client?.clawdAssetURL(filename: clawdPetState.assetFilename)
    }

    func performContextAction(_ action: String, sid: String? = nil, rounds: Int? = nil) async throws -> ContextActionResponse {
        try await requireClient().performContextAction(action, sid: sid, rounds: rounds)
    }

    static func normalizedRelayURL(_ raw: String) throws -> URL {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw APIError.invalidURL }
        if !value.contains("://") { value = "https://" + value }
        while value.hasSuffix("/") { value.removeLast() }
        guard var components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host != nil else { throw APIError.invalidURL }
        components.query = nil
        components.fragment = nil
        if components.path.isEmpty { components.path = "/relay" }
        guard let url = components.url else { throw APIError.invalidURL }
        return url
    }

    private func connect(url: URL, secret: String, persist: Bool) async {
        // Automatic keychain authentication stays behind the launch animation.
        // A manual login still keeps the form visible with its progress state.
        connectInFlight = true
        defer { connectInFlight = false }
        if phase != .launching {
            phase = .connecting
        }
        errorMessage = nil
        let nextClient = APIClient(baseURL: url, secret: secret)
        // 冷启动:先把上次存下的那屏聊天摆出来,网络在后面补。她不用盯着空白等。
        if !persist, messages.isEmpty, let cached = readHistoryCache(sessionID: activeSessionID), !cached.isEmpty {
            client = nextClient
            isLoadingHistory = true
            applyHistoryWindow(cached, requestedCount: Self.initialHistoryWindow)
            phase = .connected
        }
        do {
            _ = try await nextClient.history(since: 0, limit: 1)
            client = nextClient
            async let modeRequest = nextClient.chatMode()
            async let clawdRequest = nextClient.clawdState()
            if let settings = try? await modeRequest {
                chatMode = settings.mode
            }
            clawdPetState = (try? await clawdRequest) ?? .idle
            if persist {
                UserDefaults.standard.set(url.absoluteString, forKey: Keys.relayURL)
                try KeychainStore.save(secret, account: Keys.relaySecret)
            }
            startStream(using: nextClient)
            startIncrementalSync(using: nextClient)
            // Open the real-time stream before loading a potentially large history.
            // Otherwise the chat UI is already usable while replies are not yet observed.
            phase = .connected
            await loadInitialSessions(using: nextClient)
            await loadHistory()
            if UIApplication.shared.applicationState == .active {
                markNativeNotificationCursor(messages.map(\.id).filter { $0 > 0 }.max() ?? 0)
            }
            await waitForStreamConnection()
            await catchUp(using: nextClient)
            await flushPendingCallDeclines()
            startHeartbeat()
            if showsAPIMessageUsage { _ = try? await settingsLoopConfig() }
        } catch {
            isLoadingHistory = false
            if Self.isCancellation(error) {
                // 后台那趟连接被系统掐断:别登出、别报错——把重来的门留着，
                // 回到前台 resumeFromForeground() 会再连一次。
                client = nil
                didBootstrap = false
                if phase != .connected { phase = .launching }
                return
            }
            if !persist, Self.isTransientNetwork(error) {
                // 开机时网不好(电梯里、刚解锁还没连上):钥匙是好的,别把她踢回登录页。
                // 留在聊天里,SSE 自己每 3 秒重试,连上那一下 setStreamConnection 会补历史。
                client = nextClient
                historyNeedsReload = true
                phase = .connected
                startStream(using: nextClient)
                startIncrementalSync(using: nextClient)
                startHeartbeat()
                return
            }
            client = nil
            phase = .signedOut
            errorMessage = error.localizedDescription
        }
    }

    private func loadHistory(showLoadingState: Bool = true) async {
        guard let client else { return }
        if showLoadingState { isLoadingHistory = true }
        defer { if showLoadingState { isLoadingHistory = false } }

        let sessionID = activeSessionID
        do {
            // 只要最新一屏。以前是从第 0 条往后翻完整个库(2 万多条)再只显示最后 120 条。
            let page = try await client.recentHistory(limit: Self.initialHistoryWindow, sessionID: sessionID)
            guard sessionID == activeSessionID else { return }
            let historyMaxID = applyHistoryWindow(page.messages, requestedCount: Self.initialHistoryWindow)
            writeHistoryCache(page.raw, sessionID: sessionID)
            historyNeedsReload = false
            if UIApplication.shared.applicationState == .active {
                markNativeNotificationCursor(historyMaxID)
            }
        } catch {
            // 半路断掉的这一趟没有写进 messages——记下来,回前台或 SSE 重连时补。
            historyNeedsReload = true
            guard !Self.isCancellation(error), !Self.isTransientNetwork(error) else { return }
            errorMessage = "聊天记录加载失败：\(error.localizedDescription)"
        }
    }

    private func visibleHistoryMessages(_ batch: [ChatMessage]) -> [ChatMessage] {
        batch.filter {
            !$0.meta.hidden && !locallyHiddenMessageIDs.contains($0.id) && messageBelongsToActiveSession($0)
        }.map(normalizingMissedCallState)
    }

    /// 把服务器(或本地缓存)给的最新窗口铺进聊天。返回窗口里最大的 id。
    @discardableResult
    private func applyHistoryWindow(_ batch: [ChatMessage], requestedCount: Int) -> Int {
        historyArchive = Dictionary(visibleHistoryMessages(batch).map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
            .values.sorted(by: Self.messageComesBefore)
        let historyMaxID = historyArchive.map(\.id).max() ?? 0
        var merged = Dictionary(historyArchive.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
        // Preserve SSE messages that arrived after the history snapshot, plus any
        // optimistic outgoing message still waiting for its permanent server id.
        for message in messages where (message.id < 0 || message.id > historyMaxID) && messageBelongsToActiveSession(message) {
            merged[message.id] = message
        }
        messages = merged.values.sorted(by: Self.messageComesBefore)
        restoreBundledMessagesFromHistory()
        canLoadOlderHistory = batch.count >= requestedCount
        return historyMaxID
    }

    // MARK: 本地聊天缓存——冷启动先摆上次那屏,不等网络

    private static func historyCacheURL(sessionID: String) -> URL? {
        guard let base = try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let safeName = Data(sessionID.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
        return base
            .appendingPathComponent("TidalEchoHistory", isDirectory: true)
            .appendingPathComponent("\(safeName).json")
    }

    private func writeHistoryCache(_ raw: Data, sessionID: String) {
        guard let url = Self.historyCacheURL(sessionID: sessionID) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? raw.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func readHistoryCache(sessionID: String) -> [ChatMessage]? {
        guard let url = Self.historyCacheURL(sessionID: sessionID),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? APIClient.decodeHistory(data)
    }

    private func removeHistoryCaches() {
        guard let file = Self.historyCacheURL(sessionID: Self.legacySessionID) else { return }
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    private func restoreBundledMessagesFromHistory() {
        guard !bundledMessageParts.contains(where: { $0.messageID == nil }) else { return }
        guard let bundleID = historyArchive.last(where: {
            $0.author == .human && $0.meta.replyDeferred && $0.meta.replyBundleID != nil
        })?.meta.replyBundleID else {
            bundledMessageParts = []
            replyBundleID = nil
            return
        }
        bundledMessageParts = historyArchive.compactMap { message in
            guard message.author == .human,
                  message.meta.replyDeferred,
                  message.meta.replyBundleID == bundleID else { return nil }
            return BundledMessagePart(
                text: message.text,
                attachments: message.meta.attachments,
                messageID: message.id
            )
        }
        replyBundleID = bundledMessageParts.isEmpty ? nil : bundleID
    }

    private func loadInitialSessions(using client: APIClient) async {
        do {
            let response = try await client.sessions()
            applySessionsResponse(response, chooseServerActiveWhenNeeded: true)
        } catch {
            sessions = []
            activeSessionID = Self.legacySessionID
        }
    }

    private func applySessionsResponse(_ response: SessionsResponse, chooseServerActiveWhenNeeded: Bool) {
        sessions = response.sessions
        let validIDs = Set(response.sessions.map(\.id))
        let saved = UserDefaults.standard.string(forKey: Keys.activeSessionID) ?? activeSessionID
        if saved == Self.legacySessionID || validIDs.contains(saved) {
            activeSessionID = saved
        } else if chooseServerActiveWhenNeeded,
                  let serverActive = response.activeSession,
                  validIDs.contains(serverActive) {
            activeSessionID = serverActive
        } else {
            activeSessionID = Self.legacySessionID
        }
        UserDefaults.standard.set(activeSessionID, forKey: Keys.activeSessionID)
    }

    private func normalizedSessionID(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return Self.legacySessionID }
        return id
    }

    private func messageBelongsToActiveSession(_ message: ChatMessage) -> Bool {
        let messageSession = normalizedSessionID(message.meta.apiSession)
        return messageSession == activeSessionID
    }

    private func startStream(using client: APIClient) {
        stream.start(
            request: client.streamRequest(),
            onEvent: { [weak self] data in
                await self?.receiveStreamEvent(data)
            },
            onConnection: { [weak self] connected in
                await self?.setStreamConnection(connected)
            }
        )
    }

    private func waitForStreamConnection() async {
        for _ in 0..<25 {
            if isStreamConnected { return }
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
            } catch {
                return
            }
        }
    }

    private func catchUp(using client: APIClient) async {
        guard !isCatchingUp else { return }
        let visibleHistoryCursor = messages.map(\.id).filter { $0 > 0 }.max() ?? 0
        var cursor = max(
            visibleHistoryCursor,
            UserDefaults.standard.integer(forKey: Keys.lastNativeNotificationID)
        )
        // While the initial history request is still walking old pages, wait until
        // either it finds a cursor or a newly sent message gives us one.
        guard cursor > 0 || !isLoadingHistory else { return }
        isCatchingUp = true
        defer { isCatchingUp = false }
        do {
            for _ in 0..<20 {
                let batch = try await client.history(since: cursor, limit: 500)
                guard !batch.isEmpty else { break }
                batch.filter { !$0.meta.hidden }.forEach { upsert($0) }
                guard let last = batch.last else { break }
                cursor = max(cursor, last.id)
                if batch.count < 500 { break }
            }
        } catch {
            // SSE is already active; a transient catch-up failure can recover on refresh.
        }
    }

    private func requireClient() throws -> APIClient {
        guard let client else { throw APIError.invalidResponse }
        return client
    }

    private func setAppearanceImage(_ image: UIImage?, kind: AppearanceImageKind) {
        switch kind {
        case .background: backgroundImage = image
        case .aiAvatar: aiAvatarImage = image
        case .humanAvatar: humanAvatarImage = image
        }
    }

    private static func appearanceImageURL(_ kind: AppearanceImageKind) throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("TidalEcho", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent(kind.filename)
    }

    private static func loadAppearanceImage(_ kind: AppearanceImageKind) -> UIImage? {
        guard let url = try? appearanceImageURL(kind),
              let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    private static func resizedImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let largest = max(image.size.width, image.size.height)
        guard largest > maxDimension else { return image }
        let scale = maxDimension / largest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }

    private static func hexString(_ color: Color) -> String? {
        let resolved = UIColor(color)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        return String(format: "#%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255))
    }

    private func startIncrementalSync(using client: APIClient) {
        incrementalSyncTask?.cancel()
        incrementalSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 1_200_000_000)
                } catch {
                    return
                }
                guard let self, self.phase == .connected else { return }
                // This is deliberately incremental (`since=<latest id>`), so the
                // response is normally empty and cheap. It covers iOS/network stacks
                // that report an open SSE connection but delay delivery of its chunks.
                await self.catchUp(using: client)
            }
        }
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let client = self.client { try? await client.ping() }
                do {
                    try await Task.sleep(nanoseconds: 25_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private func setStreamConnection(_ connected: Bool) {
        isStreamConnected = connected
        // 之前那趟历史因为网络抖了没拉成:线一通就补上,不用等她切前后台
        if connected, historyNeedsReload, phase == .connected, !isLoadingHistory {
            Task { [weak self] in
                guard let self else { return }
                await self.loadHistory(showLoadingState: self.messages.isEmpty)
            }
        }
    }

    private func updateTypingState(_ active: Bool) {
        guard !active || Date() >= typingSuppressedUntil else { return }
        isTyping = active
        typingTimeoutTask?.cancel()
        typingTimeoutTask = nil
        guard active else { return }
        // Match the PWA safeguard: a dropped "typing: false" frame must not
        // leave the header stuck indefinitely.
        typingTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 120_000_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.isTyping = false
            self?.typingTimeoutTask = nil
        }
    }

    private func finishTypingAfterAIActivity() {
        // A queued `typing: true` frame can arrive just after the final reply.
        // Briefly reject that stale frame instead of flashing typing again.
        typingSuppressedUntil = Date().addingTimeInterval(2)
        updateTypingState(false)
    }

    private func queueStreamDelta(_ envelope: StreamEnvelope, kind: StreamDraftKind) {
        guard let streamID = envelope.streamID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !streamID.isEmpty else { return }
        if envelope.done == true {
            finishStream(kind: kind, streamID: streamID)
            return
        }

        let key = streamDraftKey(kind: kind, streamID: streamID)
        switch kind {
        case .thinking:
            if let previous = activeThinkingStreamID, previous != streamID {
                streamingDraftTexts.removeValue(forKey: streamDraftKey(kind: .thinking, streamID: previous))
                streamingThinking = ""
            }
            activeThinkingStreamID = streamID
        case .reply:
            if let previous = activeReplyStreamID, previous != streamID {
                streamingDraftTexts.removeValue(forKey: streamDraftKey(kind: .reply, streamID: previous))
                streamingReply = ""
            }
            activeReplyStreamID = streamID
        }

        let current = streamingDraftTexts[key] ?? ""
        streamingDraftTexts[key] = Self.appendingStreamText(envelope.text ?? "", to: current)
        scheduleStreamFlush()
    }

    private func scheduleStreamFlush() {
        guard streamFlushTask == nil else { return }
        streamFlushTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.streamFlushIntervalNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.flushStreamingDrafts()
        }
    }

    private func flushStreamingDrafts() {
        streamFlushTask = nil
        if let streamID = activeThinkingStreamID {
            let next = streamingDraftTexts[streamDraftKey(kind: .thinking, streamID: streamID)] ?? ""
            if streamingThinking != next { streamingThinking = next }
        }
        if let streamID = activeReplyStreamID {
            let next = streamingDraftTexts[streamDraftKey(kind: .reply, streamID: streamID)] ?? ""
            if streamingReply != next { streamingReply = next }
        }
    }

    private func finishStream(kind: StreamDraftKind, streamID: String?) {
        let trimmedID = streamID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedID = trimmedID?.isEmpty == false ? trimmedID : nil
        switch kind {
        case .thinking:
            guard normalizedID == nil || normalizedID == activeThinkingStreamID else {
                if let normalizedID, !normalizedID.isEmpty {
                    streamingDraftTexts.removeValue(forKey: streamDraftKey(kind: .thinking, streamID: normalizedID))
                }
                return
            }
            if let activeThinkingStreamID {
                streamingDraftTexts.removeValue(forKey: streamDraftKey(kind: .thinking, streamID: activeThinkingStreamID))
            }
            activeThinkingStreamID = nil
            streamingThinking = ""
        case .reply:
            guard normalizedID == nil || normalizedID == activeReplyStreamID else {
                if let normalizedID, !normalizedID.isEmpty {
                    streamingDraftTexts.removeValue(forKey: streamDraftKey(kind: .reply, streamID: normalizedID))
                }
                return
            }
            if let activeReplyStreamID {
                streamingDraftTexts.removeValue(forKey: streamDraftKey(kind: .reply, streamID: activeReplyStreamID))
            }
            activeReplyStreamID = nil
            streamingReply = ""
        }
    }

    private func resetStreamingDrafts() {
        streamFlushTask?.cancel()
        streamFlushTask = nil
        streamingDraftTexts.removeAll()
        activeThinkingStreamID = nil
        activeReplyStreamID = nil
        streamingThinking = ""
        streamingReply = ""
    }

    private func streamDraftKey(kind: StreamDraftKind, streamID: String) -> String {
        "\(kind.rawValue):\(streamID)"
    }

    private static func appendingStreamText(_ addition: String, to current: String) -> String {
        guard !addition.isEmpty else { return current }
        guard !current.isEmpty else { return addition }
        if addition.hasPrefix(current) { return addition }
        if current.hasSuffix(addition) { return current }

        let maximumOverlap = min(current.count, addition.count)
        if maximumOverlap > 0 {
            for length in stride(from: maximumOverlap, through: 1, by: -1) {
                if current.suffix(length) == addition.prefix(length) {
                    return current + String(addition.dropFirst(length))
                }
            }
        }
        return current + addition
    }

    private func receiveStreamEvent(_ data: Data) {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(StreamEnvelope.self, from: data),
           let type = envelope.type {
            switch type {
            case "clawd_state":
                if let nextState = try? decoder.decode(ClawdPetState.self, from: data) {
                    clawdPetState = nextState
                }
                return
            case "typing":
                updateTypingState(envelope.active ?? false)
                return
            case "post":
                if let post = envelope.post, post.author == .ai {
                    currentAIPostIDs.insert(post.id)
                    if UserDefaults.standard.object(forKey: Keys.seenAIPostIDs) != nil {
                        let seen = Set((UserDefaults.standard.array(forKey: Keys.seenAIPostIDs) as? [Int]) ?? [])
                        momentsUnreadCount = currentAIPostIDs.subtracting(seen).count
                    }
                }
                return
            case "reaction":
                finishTypingAfterAIActivity()
                if let id = envelope.id {
                    updateReactions(messageID: id, reactions: envelope.reactions ?? [:], haptic: true)
                }
                return
            case "timer":
                if let id = envelope.id, let timer = envelope.timer {
                    updateTimer(messageID: id, timer: timer)
                }
                return
            case "ask":
                if let id = envelope.id, let ask = envelope.ask {
                    updateAsk(messageID: id, ask: ask)
                }
                return
            case "peek":
                if let id = envelope.id, let peek = envelope.peek {
                    if !peek.isOpen, peekManualPickerID == id { peekManualPickerID = nil }
                    updatePeek(messageID: id, peek: peek)
                }
                return
            case "star":
                if let id = envelope.id,
                   let index = messages.firstIndex(where: { $0.id == id }) {
                    messages[index].meta.starred = envelope.starred
                }
                if let id = envelope.id,
                   let index = historyArchive.firstIndex(where: { $0.id == id }) {
                    historyArchive[index].meta.starred = envelope.starred
                }
                return
            case "book_annotation":
                if let bookID = envelope.bookID, let annotation = envelope.annotation {
                    incomingBookAnnotation = BookAnnotationEvent(bookID: bookID, annotation: annotation)
                }
                return
            case "remove":
                if let id = envelope.id {
                    messages.removeAll { $0.id == id }
                    historyArchive.removeAll { $0.id == id }
                }
                return
            case "thinking_delta":
                guard normalizedSessionID(envelope.apiSession) == activeSessionID else { return }
                queueStreamDelta(envelope, kind: .thinking)
                updateTypingState(false)
                return
            case "reply_delta":
                guard normalizedSessionID(envelope.apiSession) == activeSessionID else { return }
                queueStreamDelta(envelope, kind: .reply)
                updateTypingState(false)
                return
            default:
                break
            }
        }

        guard let message = try? decoder.decode(ChatMessage.self, from: data),
              !message.meta.hidden else { return }
        upsert(message)
        if message.author == .ai && messageBelongsToActiveSession(message) {
            finishTypingAfterAIActivity()
            if message.kind == "thinking" {
                finishStream(kind: .thinking, streamID: message.meta.streamID)
            }
            if message.kind == "reply" {
                finishStream(kind: .reply, streamID: message.meta.streamID)
            }
        }
    }

    private func updateAsk(messageID: Int, ask: MessageAsk) {
        if let index = messages.firstIndex(where: { $0.id == messageID }) {
            messages[index].meta.ask = ask
        }
        if let index = historyArchive.firstIndex(where: { $0.id == messageID }) {
            historyArchive[index].meta.ask = ask
        }
    }

    private func updatePeek(messageID: Int, peek: MessagePeek) {
        if let index = messages.firstIndex(where: { $0.id == messageID }) {
            messages[index].meta.peek = peek
        }
        if let index = historyArchive.firstIndex(where: { $0.id == messageID }) {
            historyArchive[index].meta.peek = peek
        }
    }

    /// 服务器的 peek 帧路上可能慢一步，按下去的那一刻卡片得先动起来。
    private func markPeekStatus(messageID: Int, _ status: String) {
        if let index = messages.firstIndex(where: { $0.id == messageID }),
           var peek = messages[index].meta.peek {
            peek.status = status
            messages[index].meta.peek = peek
        }
        if let index = historyArchive.firstIndex(where: { $0.id == messageID }),
           var peek = historyArchive[index].meta.peek {
            peek.status = status
            historyArchive[index].meta.peek = peek
        }
    }

    private func updateGiftUnread(with pages: [GiftPage]) {
        let defaults = UserDefaults.standard
        currentGiftTokens = Set(pages.map(Self.giftToken))
        guard defaults.object(forKey: Keys.seenGiftTokens) != nil else {
            defaults.set(Array(currentGiftTokens), forKey: Keys.seenGiftTokens)
            giftUnreadCount = 0
            return
        }
        let seen = Set(defaults.stringArray(forKey: Keys.seenGiftTokens) ?? [])
        giftUnreadCount = currentGiftTokens.subtracting(seen).count
    }

    private func updateMomentUnread(with posts: [MomentPost]) {
        let defaults = UserDefaults.standard
        currentAIPostIDs = Set(posts.filter { $0.author == .ai }.map(\.id))
        guard defaults.object(forKey: Keys.seenAIPostIDs) != nil else {
            defaults.set(Array(currentAIPostIDs), forKey: Keys.seenAIPostIDs)
            momentsUnreadCount = 0
            return
        }
        let seen = Set((defaults.array(forKey: Keys.seenAIPostIDs) as? [Int]) ?? [])
        momentsUnreadCount = currentAIPostIDs.subtracting(seen).count
    }

    private static func giftToken(_ page: GiftPage) -> String {
        "\(page.file)#\(page.modified)"
    }

    private static func greetingSlot(for date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 0..<5: return "smallhours"
        case 5..<8: return "dawn"
        case 8..<11: return "morning"
        case 11..<14: return "noon"
        case 14..<18: return "afternoon"
        case 18..<21: return "evening"
        default: return "night"
        }
    }

    private func upsert(_ incomingMessage: ChatMessage, allowsNativeArrival: Bool = true) {
        let message = normalizingMissedCallState(incomingMessage)
        if message.author == .ai && message.kind == "call" {
            incomingCallSessions[message.id] = normalizedSessionID(message.meta.apiSession)
            if message.meta.callStatus == "missed" || message.meta.callStatus == "ended" {
                NativeCallCoordinator.shared.expireIncoming(messageID: message.id)
            }
        }
        guard !locallyHiddenMessageIDs.contains(message.id) else { return }
        let wasKnown = messages.contains(where: { $0.id == message.id })
        let belongsToActiveSession = messageBelongsToActiveSession(message)
        if belongsToActiveSession {
            if let archiveIndex = historyArchive.firstIndex(where: { $0.id == message.id }) {
                historyArchive[archiveIndex] = message
            } else if message.id > 0 {
                historyArchive.append(message)
                historyArchive.sort(by: Self.messageComesBefore)
            }
        }
        guard belongsToActiveSession else {
            if allowsNativeArrival { handleNativeArrival(message, wasKnown: false) }
            return
        }
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else {
            messages.append(message)
            messages.sort(by: Self.messageComesBefore)
        }
        if allowsNativeArrival { handleNativeArrival(message, wasKnown: wasKnown) }
    }

    private func normalizingMissedCallState(_ incomingMessage: ChatMessage) -> ChatMessage {
        var message = incomingMessage
        if message.meta.callStatus == "missed" {
            missedCallMessageIDs.insert(message.id)
        } else if missedCallMessageIDs.contains(message.id) {
            message.meta.callStatus = "missed"
        }
        return message
    }

    private func handleNativeArrival(_ message: ChatMessage, wasKnown: Bool) {
        guard !wasKnown else { return }
        let lastSeenID = UserDefaults.standard.integer(forKey: Keys.lastNativeNotificationID)
        guard message.id > lastSeenID else { return }
        if message.author == .ai {
            if isFreshIncomingCall(message) {
                NativeCallCoordinator.shared.reportIncoming(messageID: message.id, text: message.text)
            } else if message.kind == "reply", UIApplication.shared.applicationState != .active {
                if message.meta.peek?.status == "pending" {
                    NativeNotificationCenter.shared.scheduleScreenPeek(message)
                } else {
                    NativeNotificationCenter.shared.scheduleMessage(message)
                }
            }
        }
        markNativeNotificationCursor(message.id)
    }

    private func isFreshIncomingCall(_ message: ChatMessage) -> Bool {
        guard message.author == .ai,
              message.kind == "call",
              message.meta.callStatus == nil || message.meta.callStatus == "ringing" else { return false }
        let formatter = ISO8601DateFormatter()
        let date: Date?
        if let parsed = formatter.date(from: message.timestamp) {
            date = parsed
        } else {
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            date = formatter.date(from: message.timestamp)
        }
        guard let date else { return false }
        let age = Date().timeIntervalSince(date)
        return age >= -30 && age <= 120
    }

    private func updateReactions(messageID: Int, reactions: [String: String], haptic: Bool = false) {
        var shouldPulse = false
        if let index = messages.firstIndex(where: { $0.id == messageID }) {
            shouldPulse = haptic && messages[index].author == .human
                && messages[index].meta.reactions["ai"] != reactions["ai"]
                && reactions["ai"] != nil
            messages[index].meta.reactions = reactions
        }
        if let index = historyArchive.firstIndex(where: { $0.id == messageID }) {
            historyArchive[index].meta.reactions = reactions
        }
        if shouldPulse {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    private func updateTimer(messageID: Int, timer: MessageTimer) {
        if let index = messages.firstIndex(where: { $0.id == messageID }) {
            messages[index].meta.timer = timer
        }
        if let index = historyArchive.firstIndex(where: { $0.id == messageID }) {
            historyArchive[index].meta.timer = timer
        }
    }

    private func markNativeNotificationCursor(_ id: Int) {
        guard id > 0 else { return }
        let current = UserDefaults.standard.integer(forKey: Keys.lastNativeNotificationID)
        if id > current { UserDefaults.standard.set(id, forKey: Keys.lastNativeNotificationID) }
    }

    private static func messageComesBefore(_ lhs: ChatMessage, _ rhs: ChatMessage) -> Bool {
        if lhs.id < 0 { return false }
        if rhs.id < 0 { return true }
        let leftAnchor = lhs.meta.sortAfter ?? lhs.id
        let rightAnchor = rhs.meta.sortAfter ?? rhs.id
        if leftAnchor == rightAnchor { return lhs.id < rhs.id }
        return leftAnchor < rightAnchor
    }
}
