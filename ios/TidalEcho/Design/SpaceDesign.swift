import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

// MARK: - 我们的空间：共用的雾面、玻璃、字、月份时间轴
//
// 2026-09-24 她定的方向：简约留白 + 毛玻璃。默认墨白的雾，夜港是黑白夜色里一点微光；
// 底图可以自己换（主页顶上清楚、往下糊成雾，其余页面铺糊掉的那层）。

enum SpaceReview {
    /// CI 截图用：不连 relay，页面直接吃样例数据。
    static var isActive: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--space-ui-review")
        #else
        return false
        #endif
    }
}

struct SpaceStyle {
    let theme: EchoTheme
    let palette: EchoPalette

    init(theme: EchoTheme) {
        self.theme = theme
        palette = theme.palette
    }

    var isDark: Bool { theme == .harbor }
    var ink: Color { palette.text }
    var sub: Color { isDark ? Color.white.opacity(0.56) : palette.secondaryText }
    var faint: Color { isDark ? Color.white.opacity(0.34) : palette.secondaryText.opacity(0.62) }
    var hair: Color { isDark ? Color.white.opacity(0.09) : Color.black.opacity(0.09) }
    var accent: Color { palette.accent }
    var onAccent: Color { palette.onAccent }
    var heart: Color { palette.accent }

    var glassTint: Color { isDark ? Color(hex: 0x1E1E20).opacity(0.46) : Color.white.opacity(0.34) }
    var glassStrong: Color { isDark ? Color(hex: 0x2A2A2D).opacity(0.82) : Color.white.opacity(0.74) }
    /// 卡片玻璃的染色：只给一点点，底图的颜色和轮廓要透得过来。
    var cardTint: Color { isDark ? Color.black.opacity(0.16) : Color.white.opacity(0.05) }
    /// 光从左上打过来：左上角亮一层，往右下淡掉。
    var sheen: Color { isDark ? Color.white.opacity(0.05) : Color.white.opacity(0.22) }
    var edge: Color { isDark ? Color.white.opacity(0.08) : Color.white.opacity(0.78) }
    var glow: Color { isDark ? Color.white.opacity(0.75) : Color.black.opacity(0.28) }
    var veilTop: Color { isDark ? Color.black.opacity(0.15) : Color(hex: 0xF3F3F1).opacity(0) }
    var veil: Color { isDark ? Color.black.opacity(0.32) : Color(hex: 0xF3F3F1).opacity(0.12) }
    /// 详情页（朋友圈、收藏、相册、记忆……）一整页都是字：底图糊得更开，雾也厚一点，字才压得住。
    var detailVeil: Color { isDark ? Color.black.opacity(0.5) : Color(hex: 0xF3F3F1).opacity(0.34) }

    var base: Color {
        switch theme {
        case .mist: return Color(hex: 0xEDEDEB)
        case .harbor: return Color(hex: 0x070707)
        case .paper: return Color(hex: 0xF7F6F2)
        case .nest: return Color(hex: 0xF4F3EF)
        }
    }

    /// 四团雾，位置固定（左上、右中、左下、右下）。
    var fog: [Color] {
        switch theme {
        case .mist: return [Color(hex: 0xD3D4D7), Color(hex: 0xFAF9F6), Color(hex: 0xC4C5C9), Color(hex: 0xE6E4DF)]
        case .harbor: return [Color(hex: 0x1C1C1F), Color(hex: 0x0F0F10), Color(hex: 0x27272A), Color(hex: 0x141415)]
        case .paper: return [Color(hex: 0xE6DFD4), Color(hex: 0xFBFAF6), Color(hex: 0xDCD3C6), Color(hex: 0xEFEAE1)]
        case .nest: return [Color(hex: 0xE4E2DC), Color(hex: 0xFBFBF9), Color(hex: 0xD9D6CE), Color(hex: 0xECEAE4)]
        }
    }

    /// 右上角那一点微光：夜港里是雾中的灯，墨白里是亮一点的天。
    var haze: Color { isDark ? Color.white.opacity(0.075) : Color.white.opacity(0.55) }

    /// 读的字（日志、收藏、记忆正文）：她选了宋体/文楷/Anthropic 就跟着她，否则用宋体。
    static func literaryFont(for chatFont: EchoChatFont) -> EchoChatFont {
        [.serif, .wenKai, .anthropicSerif].contains(chatFont) ? chatFont : .serif
    }
}

enum SpaceFont {
    /// 数字和拉丁字：系统衬线（New York），和中文宋体搭。
    static func display(_ size: CGFloat, italic: Bool = false) -> Font {
        let font = Font.system(size: size, weight: .regular, design: .serif)
        return italic ? font.italic() : font
    }

    static func label(_ size: CGFloat = 11) -> Font {
        .system(size: size, weight: .regular)
    }
}

// MARK: - 底图

@MainActor
final class SpaceWallpaper: ObservableObject {
    static let shared = SpaceWallpaper()

    @Published private(set) var image: UIImage?
    /// 主页用：轻轻化开。
    @Published private(set) var blurred: UIImage?
    /// 详情页用：糊得很开，只剩颜色。
    @Published private(set) var soft: UIImage?

    private init() {
        guard !SpaceReview.isActive else { return }
        load()
    }

    private static var directory: URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("TidalEcho", isDirectory: true)
    }

    private static var imageURL: URL? { directory?.appendingPathComponent("space-wallpaper.jpg") }
    /// 糊的程度改过就换个名字，手机上旧的那张会重新生成。
    private static var blurURL: URL? { directory?.appendingPathComponent("space-wallpaper-blur-v3.jpg") }
    private static var softURL: URL? { directory?.appendingPathComponent("space-wallpaper-soft.jpg") }
    private static let legacyBlurNames = ["space-wallpaper-blur.jpg", "space-wallpaper-blur-v2.jpg"]
    private static let lightRadius: Double = 5
    private static let softRadius: Double = 20

    private func load() {
        guard let url = Self.imageURL,
              let data = try? Data(contentsOf: url),
              let loaded = UIImage(data: data) else { return }
        image = loaded
        for name in Self.legacyBlurNames {
            if let legacy = Self.directory?.appendingPathComponent(name) {
                try? FileManager.default.removeItem(at: legacy)
            }
        }
        let cachedBlur = Self.blurURL.flatMap { try? Data(contentsOf: $0) }.flatMap(UIImage.init(data:))
        let cachedSoft = Self.softURL.flatMap { try? Data(contentsOf: $0) }.flatMap(UIImage.init(data:))
        if let cachedBlur, let cachedSoft {
            blurred = cachedBlur
            soft = cachedSoft
        } else {
            Task { await self.regenerateBlur(from: loaded) }
        }
    }

    func set(data: Data) async throws {
        guard let source = UIImage(data: data) else { throw APIError.invalidResponse }
        let upright = Self.redrawn(source, maxDimension: 1600)
        guard let jpeg = upright.jpegData(compressionQuality: 0.86),
              let directory = Self.directory,
              let url = Self.imageURL else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try jpeg.write(to: url, options: .atomic)
        withAnimation(.easeInOut(duration: 0.45)) { image = upright }
        await regenerateBlur(from: upright)
    }

    func clear() {
        if let url = Self.imageURL { try? FileManager.default.removeItem(at: url) }
        if let url = Self.blurURL { try? FileManager.default.removeItem(at: url) }
        if let url = Self.softURL { try? FileManager.default.removeItem(at: url) }
        withAnimation(.easeInOut(duration: 0.45)) {
            image = nil
            blurred = nil
            soft = nil
        }
    }

    #if DEBUG
    func installForReview(_ picture: UIImage) {
        image = picture
        blurred = Self.makeBlur(picture, radius: Self.lightRadius)
        soft = Self.makeBlur(picture, radius: Self.softRadius)
    }
    #endif

    private func regenerateBlur(from source: UIImage) async {
        let lightRadius = Self.lightRadius
        let softRadius = Self.softRadius
        let (light, heavy) = await Task.detached(priority: .userInitiated) {
            (Self.makeBlur(source, radius: lightRadius), Self.makeBlur(source, radius: softRadius))
        }.value
        withAnimation(.easeInOut(duration: 0.45)) {
            blurred = light
            soft = heavy
        }
        for (picture, url) in [(light, Self.blurURL), (heavy, Self.softURL)] {
            if let picture, let url, let data = picture.jpegData(compressionQuality: 0.8) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// 预先糊好一张小图，滚动时不用实时模糊。只化开一点，轮廓还认得出来——卡片的玻璃会再化一层。
    nonisolated static func makeBlur(_ source: UIImage, radius: Double) -> UIImage? {
        let small = redrawn(source, maxDimension: 720)
        guard let cgImage = small.cgImage else { return nil }
        let input = CIImage(cgImage: cgImage)
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = input.clampedToExtent()
        filter.radius = Float(radius)
        guard let output = filter.outputImage?.cropped(to: input.extent) else { return nil }
        let context = CIContext(options: nil)
        guard let rendered = context.createCGImage(output, from: input.extent) else { return nil }
        return UIImage(cgImage: rendered)
    }

    /// 重画一遍：顺便把 EXIF 方向摆正，cgImage 才是正的。
    nonisolated static func redrawn(_ source: UIImage, maxDimension: CGFloat) -> UIImage {
        let largest = max(source.size.width, source.size.height)
        let scale = largest > maxDimension ? maxDimension / largest : 1
        let size = CGSize(width: max(1, source.size.width * scale), height: max(1, source.size.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            source.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

struct SpaceBackdrop: View {
    let style: SpaceStyle
    var showsSharpTop = false
    @ObservedObject private var wallpaper = SpaceWallpaper.shared

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                style.base
                fogLayer
                // 主页铺轻轻化开的那张，详情页铺糊得很开的那张；还没生成好就先实时糊一下顶着。
                let prepared = showsSharpTop ? wallpaper.blurred : (wallpaper.soft ?? wallpaper.blurred)
                if let backdrop = prepared ?? wallpaper.image {
                    Image(uiImage: backdrop)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .blur(radius: prepared == nil ? (showsSharpTop ? 10 : 30) : 0)
                        .clipped()
                        .transition(.opacity)
                    if showsSharpTop, let sharp = wallpaper.image {
                        Image(uiImage: sharp)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                            .mask(
                                LinearGradient(
                                    stops: [
                                        .init(color: .black, location: 0),
                                        .init(color: .black, location: 0.22),
                                        .init(color: .clear, location: 0.55)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .transition(.opacity)
                    }
                    if showsSharpTop {
                        LinearGradient(
                            stops: [
                                .init(color: style.veilTop, location: 0),
                                .init(color: style.veil, location: 0.4),
                                .init(color: style.veil, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    } else {
                        style.detailVeil
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var fogLayer: some View {
        let fog = style.fog
        return ZStack {
            EllipticalGradient(colors: [style.haze, .clear], center: UnitPoint(x: 0.82, y: 0.13), startRadiusFraction: 0, endRadiusFraction: 0.2)
            EllipticalGradient(colors: [fog[0], fog[0].opacity(0)], center: UnitPoint(x: 0.12, y: 0.08), startRadiusFraction: 0, endRadiusFraction: 0.6)
            EllipticalGradient(colors: [fog[1], fog[1].opacity(0)], center: UnitPoint(x: 0.92, y: 0.32), startRadiusFraction: 0, endRadiusFraction: 0.55)
            EllipticalGradient(colors: [fog[2], fog[2].opacity(0)], center: UnitPoint(x: 0.2, y: 0.78), startRadiusFraction: 0, endRadiusFraction: 0.7)
            EllipticalGradient(colors: [fog[3], fog[3].opacity(0)], center: UnitPoint(x: 0.85, y: 0.95), startRadiusFraction: 0, endRadiusFraction: 0.5)
        }
    }
}

// MARK: - 玻璃

// 09-25 她嫌雾面玻璃太白、底图透不过来：卡片改成系统液态玻璃，底图的轮廓和颜色透过来、
// 又被化开；上面只薄薄染一层白，再从左上打一道光。strong 的小浮条（时间轴气泡）还是厚一点。
struct SpaceGlass: ViewModifier {
    let style: SpaceStyle
    var radius: CGFloat = 22
    var strong = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                ZStack {
                    shape
                        .fill(Color.white.opacity(0.001))
                        .glassEffect(.regular.tint(strong ? style.glassStrong : style.cardTint), in: shape)
                    shape.fill(
                        LinearGradient(
                            colors: [style.sheen, style.sheen.opacity(0)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                }
            }
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [style.edge, style.edge.opacity(0.2)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.6
                )
            )
    }
}

extension View {
    func spaceGlass(_ style: SpaceStyle, radius: CGFloat = 22, strong: Bool = false) -> some View {
        modifier(SpaceGlass(style: style, radius: radius, strong: strong))
    }

    /// 空间里每一页的底：雾（或她的底图）+ 统一的字色和强调色。
    func spacePage(_ style: SpaceStyle, sharpTop: Bool = false) -> some View {
        self
            .scrollContentBackground(.hidden)
            .background { SpaceBackdrop(style: style, showsSharpTop: sharpTop) }
            .foregroundStyle(style.ink)
            .tint(style.accent)
    }

    func spaceReveal<Key: Hashable>(_ key: Key, delay: Double = 0, alignment: Alignment = .topLeading) -> some View {
        modifier(SpaceReveal(key: key, delay: delay, alignment: alignment))
    }

    /// 进页面时一块一块浮上来。只给页面上固定的那几块用，列表行别用。
    func spaceEntrance(_ index: Int) -> some View {
        modifier(SpaceEntrance(index: index))
    }
}

/// 等数据回来才换上的内容：旧的化开淡出，新的从一层模糊里浮出来，不是一下蹦出来。
/// 叠在 ZStack 里，新旧交替时不会把上下的东西挤一跳；delay 让几块格子错开一点。
struct SpaceReveal<Key: Hashable>: ViewModifier {
    let key: Key
    var delay: Double = 0
    var alignment: Alignment = .topLeading
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        ZStack(alignment: alignment) {
            content
                .id(key)
                .transition(
                    (reduceMotion ? AnyTransition.opacity : AnyTransition(.blurReplace))
                        .animation(.smooth(duration: 0.6).delay(delay))
                )
        }
    }
}

struct SpaceEntrance: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 10)
            .onAppear {
                guard !shown else { return }
                if reduceMotion {
                    shown = true
                } else {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.86).delay(Double(min(index, 10)) * 0.04)) {
                        shown = true
                    }
                }
            }
    }
}

struct SpacePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .animation(.easeOut(duration: 0.18), value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

struct SpaceLabel: View {
    let text: String
    let style: SpaceStyle

    var body: some View {
        Text(text)
            .font(SpaceFont.label())
            .tracking(1.8)
            .foregroundStyle(style.sub)
    }
}

struct SpaceHairline: View {
    let style: SpaceStyle

    var body: some View {
        Rectangle().fill(style.hair).frame(height: 0.5)
    }
}

// MARK: - 月份与时间轴

struct SpaceMonth: Hashable, Identifiable {
    let year: Int
    let month: Int

    var key: String { String(format: "%04d-%02d", year, month) }
    var id: String { key }
    var number: String { String(format: "%02d", month) }
    var title: String { Self.names[max(0, min(12, month))] }
    var headerID: String { "\(key)|header" }

    func rowID(_ local: String) -> String { "\(key)|\(local)" }

    static let names = ["", "一月", "二月", "三月", "四月", "五月", "六月", "七月", "八月", "九月", "十月", "十一月", "十二月"]

    static var beijing: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar
    }

    init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    init(date: Date) {
        let values = Self.beijing.dateComponents([.year, .month], from: date)
        year = values.year ?? 2026
        month = values.month ?? 1
    }

    static func monthKey(ofRowID id: String?) -> String? {
        guard let id, let first = id.split(separator: "|").first else { return nil }
        return String(first)
    }
}

struct SpaceMonthHeader: View {
    let month: SpaceMonth
    let style: SpaceStyle
    var showsYear = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(month.number)
                .font(SpaceFont.display(30))
            Text(showsYear ? "\(month.title) · \(String(month.year))" : month.title)
                .font(SpaceFont.label(12))
                .tracking(2)
                .foregroundStyle(style.sub)
            Spacer(minLength: 0)
        }
        .padding(.top, 14)
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) { SpaceHairline(style: style) }
        .accessibilityAddTraits(.isHeader)
    }
}

/// 右边那条细线：按住上下拖，按月份跳。平时半透明，一滚动才亮。
struct SpaceTimelineRail: View {
    let months: [SpaceMonth]
    let activeKey: String?
    let style: SpaceStyle
    let isScrolling: Bool
    let onJump: (SpaceMonth) -> Void

    @State private var dragIndex: Int?
    @State private var dragY: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let height = max(1, geometry.size.height)
            ZStack(alignment: .trailing) {
                Rectangle()
                    .fill(style.hair)
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
                    .padding(.trailing, 12)
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(Array(months.enumerated()), id: \.element.id) { index, month in
                        if index > 0 { Spacer(minLength: 4) }
                        tick(month, active: month.key == currentKey)
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .frame(width: geometry.size.width, height: height)
            .overlay(alignment: .topTrailing) {
                if let dragIndex, months.indices.contains(dragIndex) {
                    bubble(months[dragIndex])
                        .fixedSize()
                        .offset(x: -48, y: min(max(0, dragY - 18), height - 36))
                        .transition(.opacity.combined(with: .offset(x: 8)))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let y = min(max(0, value.location.y), height - 0.5)
                        dragY = y
                        let index = min(months.count - 1, max(0, Int(y / height * CGFloat(months.count))))
                        if index != dragIndex {
                            withAnimation(.easeOut(duration: 0.15)) { dragIndex = index }
                            onJump(months[index])
                        }
                    }
                    .onEnded { _ in
                        withAnimation(.easeOut(duration: 0.25).delay(0.35)) { dragIndex = nil }
                    }
            )
        }
        .frame(width: 44)
        .opacity(dragIndex != nil || isScrolling ? 1 : 0.5)
        .animation(.easeOut(duration: 0.3), value: isScrolling)
        .sensoryFeedback(.selection, trigger: dragIndex)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("按月份跳转")
        .accessibilityAdjustableAction { direction in
            guard !months.isEmpty else { return }
            let current = months.firstIndex(where: { $0.key == currentKey }) ?? 0
            let next = direction == .increment ? min(months.count - 1, current + 1) : max(0, current - 1)
            onJump(months[next])
        }
    }

    private var currentKey: String? {
        if let dragIndex, months.indices.contains(dragIndex) { return months[dragIndex].key }
        return activeKey ?? months.first?.key
    }

    private func tick(_ month: SpaceMonth, active: Bool) -> some View {
        HStack(spacing: 6) {
            Text(month.number)
                .font(SpaceFont.display(13))
                .foregroundStyle(active ? style.ink : style.faint)
            ZStack {
                Rectangle()
                    .fill(style.faint)
                    .frame(width: 7, height: 1)
                    .opacity(active ? 0 : 1)
                Circle()
                    .fill(style.accent)
                    .frame(width: 7, height: 7)
                    .opacity(active ? 1 : 0)
            }
            .frame(width: 8)
            .padding(.trailing, 8)
        }
        .animation(.easeOut(duration: 0.2), value: active)
    }

    private func bubble(_ month: SpaceMonth) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(month.number).font(SpaceFont.display(17))
            Text("\(month.title) · \(String(month.year))").font(.system(size: 13))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .spaceGlass(style, radius: 999, strong: true)
    }
}

// MARK: - 飘起来的心

struct FloatingHeartsBurst: View {
    let color: Color
    private let seeds: [Seed]
    @State private var launched = false

    private struct Seed {
        let dx: CGFloat
        let dy: CGFloat
        let scale: CGFloat
        let rotation: Double
        let delay: Double
        let duration: Double
    }

    init(color: Color) {
        self.color = color
        seeds = (0..<6).map { index in
            Seed(
                dx: CGFloat.random(in: -22...22),
                dy: -CGFloat.random(in: 60...115),
                scale: CGFloat.random(in: 0.55...1.15),
                rotation: Double.random(in: -25...25),
                delay: Double(index) * 0.07 + Double.random(in: 0...0.04),
                duration: Double.random(in: 0.9...1.3)
            )
        }
    }

    var body: some View {
        ZStack {
            ForEach(0..<seeds.count, id: \.self) { index in
                let seed = seeds[index]
                Image(systemName: "heart.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(color)
                    .scaleEffect(launched ? seed.scale : 0.3)
                    .rotationEffect(.degrees(launched ? seed.rotation : 0))
                    .offset(x: launched ? seed.dx : 0, y: launched ? seed.dy : 0)
                    .animation(.easeOut(duration: seed.duration).delay(seed.delay), value: launched)
                    .opacity(launched ? 0 : 1)
                    .animation(.easeIn(duration: seed.duration).delay(seed.delay), value: launched)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { launched = true }
    }
}

/// 点赞的那颗心：点一下弹一下，头顶飘出一串小心。
struct SpaceLikeButton: View {
    let isLiked: Bool
    let count: Int
    let style: SpaceStyle
    let action: () -> Void

    @State private var bursts: [Int] = []
    @State private var nextBurst = 0
    @State private var bounce = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            if !isLiked {
                bounce.toggle()
                if !reduceMotion {
                    let id = nextBurst
                    nextBurst += 1
                    bursts.append(id)
                    Task {
                        try? await Task.sleep(for: .seconds(1.8))
                        bursts.removeAll { $0 == id }
                    }
                }
            }
            action()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isLiked ? "heart.fill" : "heart")
                    .font(.system(size: 15))
                    .symbolEffect(.bounce, value: bounce)
                    .overlay {
                        ForEach(bursts, id: \.self) { _ in
                            FloatingHeartsBurst(color: style.heart)
                        }
                    }
                Text(count > 0 ? "\(count)" : "喜欢")
                    .font(.system(size: 12.5))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(count)))
            }
            .foregroundStyle(isLiked ? style.heart : style.sub)
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .light), trigger: bounce)
        .accessibilityLabel(isLiked ? "取消喜欢" : "喜欢")
    }
}
