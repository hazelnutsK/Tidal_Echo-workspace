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

enum EchoChatFont: String, CaseIterable, Hashable, Identifiable {
    case system
    case serif
    case wenKai
    case anthropicSerif
    case rounded
    case monospaced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "黑体"
        case .serif: return "宋体"
        case .wenKai: return "霞鹜文楷"
        case .anthropicSerif: return "Anthropic"
        case .rounded: return "圆体"
        case .monospaced: return "等宽"
        }
    }

    var design: Font.Design {
        switch self {
        case .system: return .default
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
        }
    }

    func font(size: Double, numericWeight: Double) -> Font {
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
        }
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
        }
    }
}

enum PWAChatMetrics {
    // Keep the requested slightly-open rhythm. Only 黑体 adopts the PWA's
    // resolved iPhone sizes; the App's existing 宋体/圆体/等宽 sizing stays put.
    static let lineHeightRatio = 1.64
    static let mobileBubbleFontSize = 14.0
    static let nativeBubbleFontSize = 16.0

    static func bubbleFontSize(for font: EchoChatFont) -> Double {
        font == .system ? mobileBubbleFontSize : nativeBubbleFontSize
    }

    static func thinkingFontSize(for font: EchoChatFont) -> Double {
        font == .system ? 12 : 14
    }

    static func composerFontSize(for font: EchoChatFont) -> Double {
        font == .system ? 15 : 16
    }

    static func lineSpacing(font: EchoChatFont, size: Double) -> CGFloat {
        let targetLineHeight: CGFloat
        if font == .system {
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
