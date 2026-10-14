import Foundation

/// 她存下来的一套外观：主题、气泡、字体、颜色和壁纸。
/// 头像不在里面，换主题时头像保持不变。
struct SavedAppearance: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var createdAt: Date
    /// Changes on every save, so a list row knows to reload an overwritten wallpaper.
    var updatedAt: Date?
    var hasBackground: Bool
    var values: Values

    /// Raw values only, so an unknown or deleted option falls back instead of failing to decode.
    /// Fields added after the first version must be optional.
    struct Values: Codable, Hashable {
        var theme: String
        var chatLayoutStyle: String
        var composerStyle: String
        var chatFont: String
        var humanChatFont: String?
        var journalFont: String?
        var processTitleFont: String?
        var showsProcessDisclosure: Bool?
        var fontScale: Double
        var humanFontScale: Double
        var chatWeight: Double
        var showsAIAvatar: Bool
        var showsHumanAvatar: Bool
        var showsAIBubble: Bool
        var aiBubbleOpacity: Double
        var humanBubbleOpacity: Double
        var bubbleRadius: Double
        var bubbleWidthScale: Double
        var bubblePaddingX: Double
        var bubblePaddingY: Double
        var bubbleBorderWidth: Double
        var bubbleStyle: String
        var bubbleShapeStyle: String
        var liquidGlassStrength: Double
        var liquidGlassDispersion: Double
        var liquidGlassRimWidth: Double
        var liquidGlassMagnify: Double
        var liquidGlassBlur: Double
        var liquidGlassSize: Double
        var aiBubbleColorHex: String
        var humanBubbleColorHex: String
        var aiBubbleTextColorHex: String
        var humanBubbleTextColorHex: String
        var processTitleColorHex: String
        var timestampColorHex: String
        var backgroundOpacity: Double
        var backgroundBlur: Double
    }
}

enum SavedAppearanceStore {
    private static let defaultsKey = "tidalEcho.savedAppearances"

    static func load() -> [SavedAppearance] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let list = try? JSONDecoder().decode([SavedAppearance].self, from: data) else { return [] }
        return list
    }

    static func save(_ list: [SavedAppearance]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    static func backgroundURL(for id: UUID) throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("TidalEcho/SavedAppearances", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(id.uuidString).jpg")
    }
}
