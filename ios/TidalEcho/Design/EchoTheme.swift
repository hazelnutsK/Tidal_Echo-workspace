import CoreText
import SwiftUI
import UIKit

enum EchoTheme: String, CaseIterable, Hashable, Identifiable {
    case mist
    case paper
    case harbor
    case nest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mist: return "墨白"
        case .paper: return "纸白"
        case .harbor: return "夜港"
        case .nest: return "暖巢"
        }
    }

    var subtitle: String {
        switch self {
        case .mist: return "墨线、素纸与留白"
        case .paper: return "安静、克制的纸张质感"
        case .harbor: return "黑白夜色与雾中微光"
        case .nest: return "Claude 字体、暖白与原生浮层"
        }
    }

    var preferredColorScheme: ColorScheme {
        self == .harbor ? .dark : .light
    }

    var palette: EchoPalette {
        switch self {
        case .mist:
            return EchoPalette(
                backgroundTop: Color(hex: 0xEDEDED),
                backgroundBottom: Color(hex: 0xFAFAFA),
                text: Color(hex: 0x292929),
                secondaryText: Color.black.opacity(0.54),
                aiBubble: Color(hex: 0xEBEBEB).opacity(0.92),
                humanBubble: Color(hex: 0xC9CCD3).opacity(0.90),
                composer: Color.white.opacity(0.58),
                accent: Color.black,
                hairline: Color.black.opacity(0.13),
                onAccent: Color.white
            )
        case .paper:
            return EchoPalette(
                backgroundTop: Color(hex: 0xFAFAF8),
                backgroundBottom: Color(hex: 0xFAFAF8),
                text: Color(hex: 0x35342F),
                secondaryText: Color(hex: 0x77746B),
                aiBubble: Color(hex: 0xEEEBE4),
                humanBubble: Color(hex: 0xE2C2C5),
                composer: Color(hex: 0xF0EEE6).opacity(0.84),
                accent: Color(hex: 0x8C7466),
                hairline: Color(hex: 0xBDA896).opacity(0.28),
                onAccent: Color.white
            )
        case .harbor:
            return EchoPalette(
                backgroundTop: Color(hex: 0x080808),
                backgroundBottom: Color(hex: 0x000000),
                text: Color(hex: 0xF8F8F6),
                secondaryText: Color.white.opacity(0.76),
                aiBubble: Color(hex: 0x313131),
                humanBubble: Color(hex: 0x313131),
                composer: Color(hex: 0x171717),
                accent: Color.white,
                hairline: Color.white.opacity(0.16),
                onAccent: Color.black
            )
        case .nest:
            return EchoPalette(
                backgroundTop: Color(hex: 0xF7F7F5),
                backgroundBottom: Color(hex: 0xFBFBF9),
                text: Color(hex: 0x1F1E1D),
                secondaryText: Color(hex: 0x777671),
                aiBubble: Color.clear,
                humanBubble: Color(hex: 0xEFEFEB),
                composer: Color.white.opacity(0.74),
                accent: Color(hex: 0xDA7756),
                hairline: Color.black.opacity(0.085),
                onAccent: Color.white
            )
        }
    }
}

enum EchoChatFont: RawRepresentable, CaseIterable, Hashable, Identifiable {
    case system
    case japanese
    case hongKong
    case serif
    case wenKai
    case anthropicSerif
    case rounded
    case monospaced
    case imported(String)

    static let allCases: [EchoChatFont] = [.system, .japanese, .hongKong, .serif, .wenKai, .anthropicSerif, .rounded, .monospaced]

    var rawValue: String {
        switch self {
        case .system: return "system"
        case .japanese: return "japanese"
        case .hongKong: return "hongKong"
        case .serif: return "serif"
        case .wenKai: return "wenKai"
        case .anthropicSerif: return "anthropicSerif"
        case .rounded: return "rounded"
        case .monospaced: return "monospaced"
        case .imported(let name): return "imported:\(name)"
        }
    }

    init?(rawValue: String) {
        switch rawValue {
        case "system": self = .system
        case "japanese": self = .japanese
        case "hongKong": self = .hongKong
        case "serif": self = .serif
        case "wenKai": self = .wenKai
        case "anthropicSerif": self = .anthropicSerif
        case "rounded": self = .rounded
        case "monospaced": self = .monospaced
        default:
            guard rawValue.hasPrefix("imported:"), rawValue.count > "imported:".count else { return nil }
            self = .imported(String(rawValue.dropFirst("imported:".count)))
        }
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "黑体"
        case .japanese: return "日文字形"
        case .hongKong: return "繁体中文（香港）字形"
        case .serif: return "宋体"
        case .wenKai: return "霞鹜文楷"
        case .anthropicSerif: return "Anthropic"
        case .rounded: return "圆体"
        case .monospaced: return "等宽"
        case .imported(let name): return name
        }
    }

    var design: Font.Design {
        switch self {
        case .system, .japanese, .hongKong, .imported: return .default
        case .serif, .wenKai, .anthropicSerif: return .serif
        case .rounded: return .rounded
        case .monospaced: return .monospaced
        }
    }

    func font(size: Double, weight: Font.Weight = .regular) -> Font {
        switch self {
        case .system:
            // PWA 实测走的就是系统那份可变中文字体(PingFangUI)，这里跟着走系统字体，
            // 免得气泡(连续字重)跟别处(静态 PingFang SC)字形对不上。
            return .system(size: CGFloat(size), weight: weight, design: .default)
        case .japanese, .hongKong:
            return Font(uiFont(size: size, numericWeight: Self.numericWeight(for: weight)))
        case .serif:
            return .custom("Songti SC", size: CGFloat(size)).weight(weight)
        case .wenKai:
            let numericWeight: Double
            if weight == .ultraLight || weight == .thin || weight == .light {
                numericWeight = 300
            } else if weight == .regular {
                numericWeight = 400
            } else {
                numericWeight = 500
            }
            return Font(Self.wenKaiFont(size: CGFloat(size), numericWeight: numericWeight))
        case .anthropicSerif:
            return Font(Self.anthropicSerifFont(size: CGFloat(size), numericWeight: 400))
                .weight(weight)
        case .rounded, .monospaced:
            return .system(size: CGFloat(size), weight: weight, design: design)
        case .imported:
            // Route through the same face/axis selection as the numeric-weight path.
            return Font(uiFont(size: size, numericWeight: Self.numericWeight(of: weight)))
        }
    }

    private static func numericWeight(of weight: Font.Weight) -> Double {
        switch weight {
        case .ultraLight: return 100
        case .thin: return 200
        case .light: return 300
        case .medium: return 500
        case .semibold: return 600
        case .bold: return 700
        case .heavy: return 800
        case .black: return 900
        default: return 400
        }
    }

    func font(size: Double, numericWeight: Double) -> Font {
        if glyphLanguage != nil { return Font(uiFont(size: size, numericWeight: numericWeight)) }
        if case .imported = self { return Font(uiFont(size: size, numericWeight: numericWeight)) }
        if self == .anthropicSerif {
            return Font(Self.anthropicSerifFont(
                size: CGFloat(size),
                numericWeight: numericWeight
            ))
        }
        if self == .wenKai {
            return Font(Self.wenKaiFont(
                size: CGFloat(size),
                numericWeight: numericWeight
            ))
        }
        guard self == .system else {
            return font(size: size, weight: numericWeight.echoFontWeight)
        }
        // 万一哪天 PingFang 自己暴露了 wght 轴(现在拿不到)，优先用它，字形最贴。
        if let variable = Self.variableSans(size: CGFloat(size), weight: numericWeight) {
            return Font(variable)
        }
        // 实测(2026-08-15，PWA 墨量探针 8/8)：Safari 的中文是连续插值的，用的是系统
        // 那份可变 PingFangUI；而 UIFont(name:"PingFangSC-*") 拿到的静态 PingFang SC
        // 没有 wght 轴，只能在 4 档之间跳。系统字体的 UIFont.Weight 是 -1.0…1.0 的
        // 连续标度，传任意值即可插值——这才是和 PWA 对齐的路。
        return Font(UIFont.systemFont(ofSize: CGFloat(size),
                                      weight: Self.continuousWeight(numericWeight)))
    }

    /// UIKit counterpart used by native selectable text without changing the
    /// chat typography selected in settings.
    func uiFont(size: Double, numericWeight: Double) -> UIFont {
        let pointSize = CGFloat(size)
        let weight = Self.continuousWeight(numericWeight)

        switch self {
        case .system:
            return Self.variableSans(size: pointSize, weight: numericWeight)
                ?? UIFont.systemFont(ofSize: pointSize, weight: weight)
        case .japanese, .hongKong:
            return Self.regionalSystemFont(size: pointSize, numericWeight: numericWeight,
                                           language: glyphLanguage ?? "zh-Hans")
        case .serif:
            let base = UIFont(name: "Songti SC", size: pointSize)
                ?? UIFont.systemFont(ofSize: pointSize, weight: weight)
            let descriptor = base.fontDescriptor.addingAttributes([
                .traits: [UIFontDescriptor.TraitKey.weight: weight]
            ])
            return UIFont(descriptor: descriptor, size: pointSize)
        case .wenKai:
            return Self.wenKaiFont(size: pointSize, numericWeight: numericWeight)
        case .anthropicSerif:
            return Self.anthropicSerifFont(size: pointSize, numericWeight: numericWeight)
        case .rounded:
            let base = UIFont.systemFont(ofSize: pointSize, weight: weight)
            guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
            return UIFont(descriptor: descriptor, size: pointSize)
        case .monospaced:
            return UIFont.monospacedSystemFont(ofSize: pointSize, weight: weight)
        case .imported(let name):
            return Self.importedFont(name: name, size: pointSize, numericWeight: numericWeight)
        }
    }

    /// Used only for chat typography, never the app's UI locale or message text.
    var glyphLanguage: String? {
        switch self {
        case .japanese: return "ja"
        case .hongKong: return "zh-Hant-HK"
        default: return nil
        }
    }

    var usesSystemMetrics: Bool { self == .system || glyphLanguage != nil }

    private static func numericWeight(for weight: Font.Weight) -> Double {
        let weights: [(Font.Weight, Double)] = [
            (.ultraLight, 100), (.thin, 200), (.light, 300), (.regular, 400),
            (.medium, 500), (.semibold, 600), (.bold, 700), (.heavy, 800), (.black, 900)
        ]
        return weights.first(where: { $0.0 == weight })?.1 ?? 400
    }

    private static let regionalFontCache: NSCache<NSString, UIFont> = {
        let cache = NSCache<NSString, UIFont>()
        cache.countLimit = 96
        return cache
    }()

    private static func regionalSystemFont(size: CGFloat, numericWeight: Double, language: String) -> UIFont {
        let key = "\(language):\(size):\(numericWeight)" as NSString
        if let cached = regionalFontCache.object(forKey: key) { return cached }
        // A system UI font can apply its own CJK fallback before a supplied
        // cascade. Choose the regional CJK face itself so shared Han characters
        // use that region's outlines even while the app locale stays zh-Hans.
        let names: [String]
        if language == "ja" {
            names = numericWeight >= 550
                ? ["HiraginoSans-W6", "HiraKakuProN-W6", "HiraginoSans-W3"]
                : ["HiraginoSans-W3", "HiraKakuProN-W3", "HiraginoSans-W6"]
        } else {
            let face: String
            switch numericWeight {
            case ..<150: face = "Ultralight"
            case ..<250: face = "Thin"
            case ..<350: face = "Light"
            case ..<450: face = "Regular"
            case ..<550: face = "Medium"
            default: face = "Semibold"
            }
            names = ["PingFangHK-\(face)", "PingFangHK-Regular"]
        }
        // iOS supplies fallback fonts for Simplified Chinese characters absent
        // from the selected face, without converting or translating the text.
        let font = names.lazy.compactMap { UIFont(name: $0, size: size) }.first
            ?? UIFont.systemFont(ofSize: size, weight: continuousWeight(numericWeight))
        regionalFontCache.setObject(font, forKey: key)
        return font
    }

    /// CSS 字重(100…900) → UIFont.Weight 的连续标度，按系统命名字重分段线性插值。
    static func continuousWeight(_ css: Double) -> UIFont.Weight {
        let stops: [(css: Double, value: CGFloat)] = [
            (100, -0.80), (200, -0.60), (300, -0.40), (400, 0.00), (500, 0.23),
            (600, 0.30), (700, 0.40), (800, 0.56), (900, 0.62)
        ]
        let target = min(max(css, 100), 900)
        for index in 1..<stops.count {
            let lower = stops[index - 1]
            let upper = stops[index]
            if target <= upper.css {
                let span = upper.css - lower.css
                let ratio: CGFloat = span > 0 ? CGFloat((target - lower.css) / span) : CGFloat(0)
                return UIFont.Weight(rawValue: lower.value + (upper.value - lower.value) * ratio)
            }
        }
        return UIFont.Weight(rawValue: stops[stops.count - 1].value)
    }

    /// 'wght' 轴的四字符标识
    static let wghtAxisID: UInt32 = 0x77676874

    private static func importedFont(name: String, size: CGFloat, numericWeight: Double) -> UIFont {
        guard let base = UIFont(name: name, size: size) else {
            return UIFont.systemFont(ofSize: size, weight: continuousWeight(numericWeight))
        }
        if let axes = CTFontCopyVariationAxes(base as CTFont) as? [[String: Any]],
           let axis = axes.first(where: {
               ($0[kCTFontVariationAxisIdentifierKey as String] as? NSNumber)?.uint32Value == wghtAxisID
           }),
           let minimum = axis[kCTFontVariationAxisMinimumValueKey as String] as? NSNumber,
           let maximum = axis[kCTFontVariationAxisMaximumValueKey as String] as? NSNumber {
            let value = min(max(numericWeight, minimum.doubleValue), maximum.doubleValue)
            let descriptor = base.fontDescriptor.addingAttributes([
                UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [
                    NSNumber(value: wghtAxisID): NSNumber(value: value)
                ]
            ])
            return UIFont(descriptor: descriptor, size: size)
        }
        // Static font files keep their own outlines instead of synthesizing a
        // different face. When other weights of the same family are imported,
        // the slider moves from the chosen face (at 400) to the nearest real one.
        let faces = staticFaces(matching: base)
        guard faces.count > 1, let own = faces.first(where: { $0.name == base.fontName }) else { return base }
        let target = own.weight + (numericWeight - 400)
        guard let nearest = faces.min(by: { abs($0.weight - target) < abs($1.weight - target) }),
              nearest.name != base.fontName else { return base }
        return UIFont(name: nearest.name, size: size) ?? base
    }

    enum ImportedWeightSupport: Equatable {
        case variable
        case faces(Int)
        case single
    }

    static func importedWeightSupport(name: String) -> ImportedWeightSupport {
        guard let base = UIFont(name: name, size: 16) else { return .single }
        if let axes = CTFontCopyVariationAxes(base as CTFont) as? [[String: Any]],
           axes.contains(where: {
               ($0[kCTFontVariationAxisIdentifierKey as String] as? NSNumber)?.uint32Value == wghtAxisID
           }) {
            return .variable
        }
        let count = staticFaces(matching: base).count
        return count > 1 ? .faces(count) : .single
    }

    private struct StaticFace {
        let name: String
        let weight: Double
    }

    private static let staticFaceLock = NSLock()
    nonisolated(unsafe) private static var staticFaceCache: [String: [StaticFace]] = [:]

    /// Upright/italic and width must match, so a slider never jumps to an italic or condensed cut.
    private static func staticFaces(matching base: UIFont) -> [StaticFace] {
        let traits = base.fontDescriptor.symbolicTraits
        let key = "\(base.familyName)|\(traits.contains(.traitItalic))|\(traits.contains(.traitCondensed))|\(traits.contains(.traitExpanded))"
        staticFaceLock.lock()
        defer { staticFaceLock.unlock() }
        if let cached = staticFaceCache[key] { return cached }
        let faces = UIFont.fontNames(forFamilyName: base.familyName).compactMap { name -> StaticFace? in
            guard let font = UIFont(name: name, size: 16) else { return nil }
            let other = font.fontDescriptor.symbolicTraits
            guard other.contains(.traitItalic) == traits.contains(.traitItalic),
                  other.contains(.traitCondensed) == traits.contains(.traitCondensed),
                  other.contains(.traitExpanded) == traits.contains(.traitExpanded) else { return nil }
            return StaticFace(name: name, weight: weightClass(of: font))
        }
        staticFaceCache[key] = faces
        return faces
    }

    /// OS/2 usWeightClass (100…900) when the file has it, else the nearest CoreText weight trait.
    private static func weightClass(of font: UIFont) -> Double {
        if let table = CTFontCopyTable(font as CTFont, CTFontTableTag(kCTFontTableOS2), []) as Data?,
           table.count >= 6 {
            let value = Int(table[table.startIndex + 4]) << 8 | Int(table[table.startIndex + 5])
            if (1...1000).contains(value) { return Double(value) }
        }
        let traits = CTFontCopyTraits(font as CTFont) as NSDictionary
        let trait = (traits[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
        let steps: [(trait: Double, weight: Double)] = [
            (-0.8, 100), (-0.6, 200), (-0.4, 300), (0, 400), (0.23, 500),
            (0.3, 600), (0.4, 700), (0.56, 800), (0.62, 900)
        ]
        return steps.min(by: { abs($0.trait - trait) < abs($1.trait - trait) })?.weight ?? 400
    }

    /// A newly imported file may add faces to a family that was already looked up.
    static func invalidateImportedFaceCache() {
        staticFaceLock.lock()
        staticFaceCache.removeAll()
        staticFaceLock.unlock()
    }

    /// 霞鹜文楷随 App 打包的是三个常用字子集。滑块落在中间或更粗的数值时，
    /// 取距离最近的真实字重，避免系统伪粗体破坏文楷的笔画形态。
    private static func wenKaiFont(size: CGFloat, numericWeight: Double) -> UIFont {
        let postScriptName: String
        switch numericWeight {
        case ..<350:
            postScriptName = "LXGWWenKai-Light"
        case ..<450:
            postScriptName = "LXGWWenKai-Regular"
        default:
            postScriptName = "LXGWWenKai-Medium"
        }
        return UIFont(name: postScriptName, size: size)
            ?? UIFont(name: "Kaiti SC", size: size)
            ?? UIFont.systemFont(ofSize: size, weight: continuousWeight(numericWeight))
    }

    static func wenKaiWeightDiagnostic(_ current: Double) -> String {
        switch current {
        case ..<350: return "霞鹜文楷 Light · 300"
        case ..<450: return "霞鹜文楷 Regular · 400"
        default: return "霞鹜文楷 Medium · 500"
        }
    }

    /// The private Nest typeface is bundled as a TTF. Different exports have
    /// used slightly different PostScript names, so probe the known names and
    /// keep a native serif fallback for a damaged or missing personal asset.
    private static func anthropicSerifFont(size: CGFloat, numericWeight: Double) -> UIFont {
        let candidates = [
            "AnthropicSerifWebVariable-TextRegular",
            "AnthropicSerifVariable",
            "Anthropic Serif Web Text",
            "Anthropic Serif"
        ]
        let base = candidates.lazy.compactMap { UIFont(name: $0, size: size) }.first
            ?? UIFont.systemFont(ofSize: size).fontDescriptor.withDesign(.serif)
                .map { UIFont(descriptor: $0, size: size) }
            ?? UIFont.systemFont(ofSize: size)

        if let ids = variationAxisIDs(of: base), ids.contains(wghtAxisID) {
            let attribute = UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String)
            let descriptor = base.fontDescriptor.addingAttributes([
                attribute: [
                    NSNumber(value: wghtAxisID): NSNumber(value: min(max(numericWeight, 300), 800))
                ]
            ])
            return UIFont(descriptor: descriptor, size: size)
        }

        let descriptor = base.fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: continuousWeight(numericWeight)]
        ])
        return UIFont(descriptor: descriptor, size: size)
    }

    /// PingFang 的 wght 轴可用时，返回按 `weight` 连续插值的字体；否则 nil。
    static func variableSans(size: CGFloat, weight: Double) -> UIFont? {
        guard let base = UIFont(name: "PingFangSC-Regular", size: size) else { return nil }
        guard let ids = variationAxisIDs(of: base), ids.contains(wghtAxisID) else { return nil }
        let attribute = UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String)
        let descriptor = base.fontDescriptor.addingAttributes([
            attribute: [NSNumber(value: wghtAxisID): NSNumber(value: weight)]
        ])
        return UIFont(descriptor: descriptor, size: size)
    }

    private static func variationAxisIDs(of font: UIFont) -> [UInt32]? {
        guard let raw = CTFontCopyVariationAxes(font as CTFont) as NSArray? else { return nil }
        guard let axes = raw as? [[String: Any]], !axes.isEmpty else { return nil }
        let key = kCTFontVariationAxisIdentifierKey as String
        return axes.compactMap { ($0[key] as? NSNumber)?.uint32Value }
    }

    /// 设置页那行小字：一眼看出这台机上走的是哪条路，以及当前字重插值到了多少。
    static func weightDiagnostic(_ current: Double) -> String {
        if let base = UIFont(name: "PingFangSC-Regular", size: 14),
           let ids = variationAxisIDs(of: base), ids.contains(wghtAxisID) {
            return "PingFang 可变 wght ✓（\(ids.count) 轴）"
        }
        let value = Double(continuousWeight(current).rawValue)
        return String(format: "系统字体 · 连续插值 · %d→%.3f", Int(current), value)
    }

    /// SwiftUI's `lineSpacing` is added on top of the font's native line box.
    /// Exposing that native height lets chat rows match the PWA's CSS line-height
    /// instead of approximating it with a fixed extra amount.
    func nativeLineHeight(size: Double) -> CGFloat {
        let pointSize = CGFloat(size)
        switch self {
        case .system:
            // 渲染已改走系统字体，行高基准必须跟着换：否则 lineSpacing 会拿另一套字体的
            // 行盒去减，行距会莫名变松或变紧。总行高仍是 size × 1.64，视觉节奏不变。
            return UIFont.systemFont(ofSize: pointSize).lineHeight
        case .japanese, .hongKong:
            return uiFont(size: size, numericWeight: 400).lineHeight
        case .serif:
            return UIFont(name: "Songti SC", size: pointSize)?.lineHeight
                ?? UIFont.systemFont(ofSize: pointSize).lineHeight
        case .wenKai:
            return Self.wenKaiFont(size: pointSize, numericWeight: 400).lineHeight
        case .anthropicSerif:
            return Self.anthropicSerifFont(size: pointSize, numericWeight: 400).lineHeight
        case .rounded:
            let descriptor = UIFont.systemFont(ofSize: pointSize).fontDescriptor.withDesign(.rounded)
            return descriptor.map { UIFont(descriptor: $0, size: pointSize).lineHeight }
                ?? UIFont.systemFont(ofSize: pointSize).lineHeight
        case .monospaced:
            return UIFont.monospacedSystemFont(ofSize: pointSize, weight: .regular).lineHeight
        case .imported(let name):
            return Self.importedFont(name: name, size: pointSize, numericWeight: 400).lineHeight
        }
    }
}

enum PWAChatMetrics {
    // Keep the requested slightly-open rhythm. System fonts adopt the PWA's
    // resolved iPhone sizes; the App's existing 宋体/圆体/等宽 sizing stays put.
    static let lineHeightRatio = 1.64
    static let mobileBubbleFontSize = 14.0
    static let nativeBubbleFontSize = 16.0

    static func bubbleFontSize(for font: EchoChatFont) -> Double {
        font.usesSystemMetrics ? mobileBubbleFontSize : nativeBubbleFontSize
    }

    static func thinkingFontSize(for font: EchoChatFont) -> Double {
        font.usesSystemMetrics ? 12 : 14
    }

    static func composerFontSize(for font: EchoChatFont) -> Double {
        font.usesSystemMetrics ? 15 : 16
    }

    static func lineSpacing(font: EchoChatFont, size: Double) -> CGFloat {
        let targetLineHeight: CGFloat
        if font.usesSystemMetrics {
            targetLineHeight = CGFloat(size * lineHeightRatio)
        } else {
            let scale = size / nativeBubbleFontSize
            targetLineHeight = CGFloat(mobileBubbleFontSize * scale * lineHeightRatio)
        }
        return max(0, targetLineHeight - font.nativeLineHeight(size: size))
    }
}

struct EchoPalette {
    let backgroundTop: Color
    let backgroundBottom: Color
    let text: Color
    let secondaryText: Color
    let aiBubble: Color
    let humanBubble: Color
    let composer: Color
    let accent: Color
    let hairline: Color
    /// 实心强调按钮（borderedProminent）上那行字的颜色。气泡内容整体套了
    /// foregroundStyle(bubbleTextColor)，会一路盖到按钮标题上——墨白主题的
    /// accent 是纯黑，于是黑底灰字什么都看不见（她 2026-09-04 指出来的）。
    let onAccent: Color

    var background: LinearGradient {
        LinearGradient(
            colors: [backgroundTop, backgroundBottom],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: alpha
        )
    }

    init?(hexString: String) {
        let value = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 6, let hex = UInt(value, radix: 16) else { return nil }
        self.init(hex: hex)
    }
}

extension EnvironmentValues {
    /// 外观里自定义的思考/工具标题色和时间戳色，ChatView 统一注入；nil＝各处沿用主题色。
    @Entry var processTitleColor: Color? = nil
    @Entry var timestampColor: Color? = nil
    /// 思考/工具标题单独的字体（nil＝跟聊天字体），以及标题旁的展开小箭头要不要画。
    @Entry var processTitleFont: EchoChatFont? = nil
    @Entry var showsProcessDisclosure: Bool = true
    /// 外观里“气泡内边距”拉条：width＝左右、height＝上下，在各主题基准值上加减。
    @Entry var bubblePaddingOffset: CGSize = .zero
}

extension Double {
    var echoFontWeight: Font.Weight {
        switch self {
        case ..<350: return .light
        case ..<450: return .regular
        case ..<550: return .medium
        case ..<650: return .semibold
        case ..<750: return .bold
        default: return .heavy
        }
    }
}
