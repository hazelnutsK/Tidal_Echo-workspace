import CoreText
import SwiftUI
import UIKit

/// 开屏：一支笔把 Aquila 写出来，i 的点最后落成一颗爱心。
///
/// 写法是让粗笔沿笔顺走，再用 Sacramento 的字形把它裁出来——所以写出来的每一处
/// 弧度都是这支字体本身的，不是描边框。三笔：A 的主体、那道横杠、quila 一笔连到底。
///
/// 整幅画面是**时间的纯函数**（TimelineView + Canvas），没有 repeatForever、没有
/// delay 叠加，因此任何一帧都可复现，也不存在元素"等待出发"的静止帧。
struct LaunchView: View {
    let theme: EchoTheme

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale
    @State private var start = Date()
    @State private var subtitleVisible = false

    private var palette: EchoPalette { theme.palette }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                palette.background.ignoresSafeArea()

                if reduceMotion {
                    Canvas { context, size in
                        renderer(size: size).draw(into: context, t: Hand.staticFrame)
                    }
                } else {
                    TimelineView(.animation) { timeline in
                        Canvas { context, size in
                            renderer(size: size)
                                .draw(into: context, t: timeline.date.timeIntervalSince(start))
                        }
                    }
                }

                LaunchSubtitle(
                    tracking: subtitleVisible ? 3.4 : 6.2,
                    color: palette.secondaryText.opacity(0.82)
                )
                .opacity(subtitleVisible ? 1 : 0)
                .position(
                    x: geo.size.width / 2,
                    y: Hand.geometry(in: geo.size).subtitleY
                )
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tidal Echo 正在启动")
        .onAppear(perform: play)
    }

    private func renderer(size: CGSize) -> Handwriting {
        Handwriting(theme: theme, size: size, scale: displayScale, reduced: reduceMotion)
    }

    private func play() {
        guard !reduceMotion else {
            subtitleVisible = true
            return
        }
        // 领地遮罩要算一次（几十毫秒）。先备好再起表，免得第一笔从半路开始。
        if let screen = (UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first)?.screen.bounds.size {
            HandMasks.shared.warm(size: screen)
        }
        start = Date()
        withAnimation(.easeOut(duration: 0.44).delay(Hand.subtitle.lowerBound)) {
            subtitleVisible = true
        }
    }
}

// MARK: - 时间轴与几何常量

private enum Hand {
    /// 她 2026-09-05 在预览里定的：速度 1.05、笔迹 54、爱心 26、胭脂色。
    /// 下面的秒数已经按 1.05 折算过，不必再乘。
    static let strokeSpans: [ClosedRange<Double>] = [
        0.000...0.438,      // A 的主体：左下花体扫上去 → 顶点 → 右腿落下
        0.486...0.714,      // 那道横杠：左边小钩起笔，穿过 A 甩出去
        0.762...1.429       // quila：q 的碗与下垂环 → u → i → l 的高杆 → a 收笔
    ]
    static let heart = 1.476...1.714
    static let subtitle = 1.638...1.981

    static let pen: CGFloat = 54          // 笔尖宽度（300px 字号下）
    static let heartWidth: CGFloat = 26   // 原来那个点直径是 16
    static let fontSize: CGFloat = 104

    /// reduceMotion 用的静止帧：全部写完。
    static let staticFrame: Double = 9

    // 骨架与字形都以 300px 字号、原点=字体绘制点（ascender 线）为准。
    static let designSize: CGFloat = 300
    static let glyphTop: CGFloat = 61       // 字形最高的墨
    static let glyphMidY: CGFloat = 249.5   // 字形垂直中心
    static let dot = CGPoint(x: 524, y: 160)

    /// 三笔的骨架。取自 Sacramento 渲染出的 "Aquila"，一笔一条折线。
    static let strokes: [[CGPoint]] = [
        [(-17,252),(10,262),(53,271),(95,265),(127,247),(160,232),(193,217),
         (220,196),(247,173),(261,142),(272,86),
         (276,132),(280,182),(283,232),(285,288),(284,330)],
        [(49,141),(36,150),(30,167),(33,183),(47,200),(67,208),(97,209),(127,208),
         (160,206),(193,203),(227,201),(260,199),(290,196),(317,193)],
        [(377,215),(358,220),(340,230),(331,243),(329,257),(340,270),(353,277),
         (370,272),(383,262),
         (387,240),(388,270),(386,300),(384,340),(382,387),(384,415),(387,430),
         (378,428),(370,418),(367,395),(367,373),(375,345),(390,320),
         (398,285),(402,255),(403,233),
         (410,255),(420,272),(433,273),(447,262),(458,240),(467,220),
         (472,245),(482,265),(497,273),(510,262),(520,245),(525,230),
         (532,250),(543,268),(550,270),(563,262),(573,245),(578,233),
         (590,230),(600,180),(612,130),(617,90),(609,77),(601,95),(604,140),
         (610,200),(615,245),(618,262),
         (625,275),(637,273),
         (663,219),(652,228),(645,242),(652,262),(658,270),(672,274),(687,266),
         (698,248),(702,232),
         (706,250),(712,268),(720,272),(735,268),(750,255),(767,233)]
    ].map { $0.map { CGPoint($0) } }

    /// 每一笔的分段长度与总长，用来把进度换算成"写到哪"。
    static let metrics: [(lengths: [Double], total: Double)] = strokes.map { pts in
        var lengths: [Double] = []
        for i in 0..<(pts.count - 1) {
            lengths.append(Double(hypot(pts[i+1].x - pts[i].x, pts[i+1].y - pts[i].y)))
        }
        return (lengths, lengths.reduce(0, +))
    }

    struct Geometry {
        let origin: CGPoint     // 骨架/字形坐标系的原点（屏幕坐标）
        let scale: CGFloat
        let subtitleY: CGFloat

        func map(_ p: CGPoint) -> CGPoint {
            CGPoint(x: origin.x + p.x * scale, y: origin.y + p.y * scale)
        }
    }

    static func geometry(in size: CGSize) -> Geometry {
        let scale = fontSize / designSize
        // 字形横向居中，纵向落在屏幕 0.478 处——和原来星图的重心一致
        let midX = size.width / 2
        let midY = size.height * 0.478
        let origin = CGPoint(x: midX - 377 * scale, y: midY - glyphMidY * scale)
        return Geometry(
            origin: origin,
            scale: scale,
            subtitleY: origin.y + 438 * scale + 46
        )
    }
}

private extension CGPoint {
    init(_ pair: (Int, Int)) { self.init(x: CGFloat(pair.0), y: CGFloat(pair.1)) }
}

private func clamp01(_ x: Double) -> Double { x < 0 ? 0 : (x > 1 ? 1 : x) }
private func ramp(_ t: Double, _ range: ClosedRange<Double>) -> Double {
    clamp01((t - range.lowerBound) / (range.upperBound - range.lowerBound))
}
private func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
private func easeInOut(_ x: Double) -> Double {
    x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
}
/// 落定时带一下回弹——爱心掉进来那个劲儿全在这。
private func easeOutBack(_ x: Double) -> Double {
    1 + 2.15 * pow(x - 1, 3) + 1.35 * pow(x - 1, 2)
}

// MARK: - 字形与领地

/// 字形按"离哪一笔的骨架最近"分给三笔，每笔只能点亮自己名下的墨。
///
/// 没有这一步，A 的斜边（在 x≈160–250 处贴着横杠只隔 5–26pt）会被粗笔一路捎带
/// 写掉，第二笔上场时就只剩 A 外面那一小截可写了。收细笔尖治不了——斜边本身就是
/// A 最粗的主笔画。所以改成先分地盘。
private final class HandMasks {
    static let shared = HandMasks()

    private var cachedKey: String = ""
    private var cachedGlyph = Path()
    private var cachedTerritories: [CGImage] = []
    private let lock = NSLock()

    struct Assets {
        let glyph: Path
        let territories: [CGImage]
    }

    func warm(size: CGSize) { _ = assets(for: size) }

    func assets(for size: CGSize) -> Assets {
        let key = "\(Int(size.width))x\(Int(size.height))"
        lock.lock()
        defer { lock.unlock() }
        if key != cachedKey || cachedTerritories.count != Hand.strokes.count {
            let geo = Hand.geometry(in: size)
            cachedGlyph = Self.buildGlyphPath(geo: geo)
            cachedTerritories = Self.buildTerritories(size: size, geo: geo)
            cachedKey = key
        }
        return Assets(glyph: cachedGlyph, territories: cachedTerritories)
    }

    /// 用 Core Text 把 "Aquila" 取成矢量轮廓——比位图遮罩清爽，边缘也不会糊。
    private static func buildGlyphPath(geo: Hand.Geometry) -> Path {
        let font = CTFontCreateWithName("Sacramento-Regular" as CFString, Hand.fontSize, nil)
        let attributed = NSAttributedString(
            string: "Aquila",
            attributes: [kCTFontAttributeName as NSAttributedString.Key: font]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        // 骨架的原点是字体的绘制点（ascender 线），Core Text 却按基线落字。
        // 与其信 ascent 的某一种定义，不如量墨迹：字形最高的墨在骨架里是 y=61
        // （300px 字号），量出它到基线的距离，两个原点就对齐了。
        let inkBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let rise = inkBounds.maxY > 0 ? inkBounds.maxY : CTFontGetAscent(font)
        let baseline = geo.origin.y + Hand.glyphTop * geo.scale + rise
        let combined = CGMutablePath()

        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return Path() }
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRangeMake(0, count), &glyphs)
            CTRunGetPositions(run, CFRangeMake(0, count), &positions)

            // 这行只有一种字体，run 上的就是它，不必再从属性里取
            for i in 0..<count {
                guard let glyphPath = CTFontCreatePathForGlyph(font, glyphs[i], nil) else { continue }
                // 字形的 y 向上，屏幕的 y 向下：先翻转，再落到基线上
                let transform = CGAffineTransform(scaleX: 1, y: -1)
                    .concatenating(CGAffineTransform(
                        translationX: geo.origin.x + positions[i].x,
                        y: baseline - positions[i].y
                    ))
                combined.addPath(glyphPath, transform: transform)
            }
        }
        return Path(combined)
    }

    /// 逐像素最近邻：字形附近的每个点归给离它最近的那条骨架。
    /// 只在字形墨迹（外扩几点）上算，30k 像素 × 100 段，一次几十毫秒。
    private static func buildTerritories(size: CGSize, geo: Hand.Geometry) -> [CGImage] {
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        guard w > 0, h > 0 else { return [] }

        // 骨架映射到屏幕坐标
        let polys: [[CGPoint]] = Hand.strokes.map { $0.map(geo.map) }
        let boxes: [CGRect] = polys.map { pts in
            var box = CGRect(x: pts[0].x, y: pts[0].y, width: 0, height: 0)
            for p in pts { box = box.union(CGRect(x: p.x, y: p.y, width: 0, height: 0)) }
            return box
        }

        // 字形墨迹范围（骨架外扩一点，把抗锯齿的边缘像素也圈进来）
        var inkBox = boxes[0]
        for box in boxes { inkBox = inkBox.union(box) }
        inkBox = inkBox.insetBy(dx: -22, dy: -22)
        let x0 = max(0, Int(inkBox.minX)), x1 = min(w, Int(inkBox.maxX.rounded(.up)))
        let y0 = max(0, Int(inkBox.minY)), y1 = min(h, Int(inkBox.maxY.rounded(.up)))
        guard x0 < x1, y0 < y1 else { return [] }

        let count = w * h
        var buffers = [[UInt8]](repeating: [UInt8](repeating: 0, count: count), count: polys.count)

        for py in y0..<y1 {
            let fy = CGFloat(py) + 0.5
            for px in x0..<x1 {
                let fx = CGFloat(px) + 0.5
                var best = CGFloat.greatestFiniteMagnitude
                var owner = 0
                for (i, poly) in polys.enumerated() {
                    // 离这一笔的包围盒都比现有最优远，就不用逐段算了
                    let bx = max(boxes[i].minX - fx, 0, fx - boxes[i].maxX)
                    let by = max(boxes[i].minY - fy, 0, fy - boxes[i].maxY)
                    if hypot(bx, by) >= best { continue }
                    var d = CGFloat.greatestFiniteMagnitude
                    for k in 0..<(poly.count - 1) {
                        d = min(d, distance(fx, fy, poly[k], poly[k + 1]))
                        if d < 0.5 { break }
                    }
                    if d < best { best = d; owner = i }
                }
                buffers[owner][py * w + px] = 255
            }
        }

        return buffers.compactMap { buffer in
            var rgba = [UInt8](repeating: 0, count: count * 4)
            for idx in 0..<count where buffer[idx] != 0 {
                rgba[idx * 4 + 3] = buffer[idx]      // 只要 alpha，RGB 留黑
            }
            guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
            return CGImage(
                width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
            )
        }
    }

    private static func distance(_ x: CGFloat, _ y: CGFloat, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let abx = b.x - a.x, aby = b.y - a.y
        let len2 = abx * abx + aby * aby
        guard len2 > 1e-9 else { return hypot(x - a.x, y - a.y) }
        var t = ((x - a.x) * abx + (y - a.y) * aby) / len2
        t = t < 0 ? 0 : (t > 1 ? 1 : t)
        return hypot(x - (a.x + t * abx), y - (a.y + t * aby))
    }
}

// MARK: - 绘制

private struct Handwriting {
    let theme: EchoTheme
    let size: CGSize
    let scale: CGFloat
    let reduced: Bool

    private var palette: EchoPalette { theme.palette }
    private var isDark: Bool { theme == .harbor }
    private var rose: Color { isDark ? Color(hex: 0xE98BA6) : Color(hex: 0xC8455F) }

    func draw(into context: GraphicsContext, t: Double) {
        drawTexture(context)
        if isDark { drawSpecks(context, t: t) }

        let geo = Hand.geometry(in: size)
        let assets = HandMasks.shared.assets(for: size)
        guard !assets.territories.isEmpty else { return }
        let full = CGRect(origin: .zero, size: size)

        var tip: CGPoint?
        for i in Hand.strokes.indices {
            let p = reduced ? 1 : ramp(t, Hand.strokeSpans[i])
            guard p > 0 else { continue }
            let eased = easeInOut(p)

            var ctx = context
            ctx.clip(to: assets.glyph)                       // 字形：矢量,边缘干净
            ctx.clipToLayer { layer in                       // 领地：只点亮自己名下的墨
                layer.draw(Image(decorative: assets.territories[i], scale: 1), in: full)
            }
            let (path, end) = inkPath(i, upTo: eased, geo: geo)
            ctx.stroke(
                path,
                with: .color(palette.text),
                style: StrokeStyle(lineWidth: Hand.pen * geo.scale, lineCap: .round, lineJoin: .round)
            )
            if p < 1 { tip = end }
        }

        if let tip, !reduced { drawNib(context, at: tip) }
        drawHeart(context, t: t, geo: geo)
    }

    /// 沿骨架推进到 p，返回已经写出的那一段和笔尖所在
    private func inkPath(_ i: Int, upTo p: Double, geo: Hand.Geometry) -> (Path, CGPoint) {
        let pts = Hand.strokes[i]
        let (lengths, total) = Hand.metrics[i]
        var path = Path()
        path.move(to: geo.map(pts[0]))
        var last = geo.map(pts[0])
        guard p > 0 else { return (path, last) }

        let want = p * total
        var done = 0.0
        for k in 0..<lengths.count {
            if done + lengths[k] <= want {
                last = geo.map(pts[k + 1])
                path.addLine(to: last)
                done += lengths[k]
            } else {
                let f = CGFloat((want - done) / lengths[k])
                let cut = CGPoint(
                    x: pts[k].x + (pts[k + 1].x - pts[k].x) * f,
                    y: pts[k].y + (pts[k + 1].y - pts[k].y) * f
                )
                last = geo.map(cut)
                path.addLine(to: last)
                break
            }
        }
        return (path, last)
    }

    /// 笔尖那一点墨光
    private func drawNib(_ context: GraphicsContext, at point: CGPoint) {
        let r: CGFloat = 13
        context.fill(
            Path(ellipseIn: CGRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)),
            with: .radialGradient(
                Gradient(colors: [
                    palette.accent.opacity(isDark ? 0.34 : 0.20),
                    palette.accent.opacity(0)
                ]),
                center: point, startRadius: 0, endRadius: r
            )
        )
    }

    /// i 的点最后落下，换成一颗爱心
    private func drawHeart(_ context: GraphicsContext, t: Double, geo: Hand.Geometry) {
        let p = reduced ? 1 : ramp(t, Hand.heart)
        guard p > 0 else { return }
        let e = reduced ? 1 : easeOutBack(p)
        let center = geo.map(Hand.dot)
        let y = center.y - CGFloat(1 - e) * 30 * geo.scale
        let w = Hand.heartWidth * geo.scale * CGFloat(0.35 + 0.65 * e)
        let alpha = min(1, p * 2.6)

        let halo = w * 2.2
        context.fill(
            Path(ellipseIn: CGRect(x: center.x - halo, y: y - halo, width: halo * 2, height: halo * 2)),
            with: .radialGradient(
                Gradient(colors: [rose.opacity(0.22 * alpha), rose.opacity(0)]),
                center: CGPoint(x: center.x, y: y), startRadius: 0, endRadius: halo
            )
        )
        context.fill(heartPath(center: CGPoint(x: center.x, y: y), width: w),
                     with: .color(rose.opacity(alpha)))

        // 落定时一圈很淡的涟漪，接住原来 pulse 的位置
        let after = t - Hand.heart.upperBound
        if !reduced, after > 0, after < 0.9 {
            let r = CGFloat(easeOut(clamp01(after / 0.7))) * size.width * 0.30
            context.stroke(
                Path(ellipseIn: CGRect(x: center.x - r, y: y - r, width: r * 2, height: r * 2)),
                with: .color(palette.accent.opacity(0.16 * max(0, 1 - after / 0.8))),
                lineWidth: 0.7
            )
        }
    }

    private func heartPath(center c: CGPoint, width: CGFloat) -> Path {
        let r = width / 2, h = width * 0.9
        var path = Path()
        path.move(to: CGPoint(x: c.x, y: c.y + h * 0.42))
        path.addCurve(
            to: CGPoint(x: c.x, y: c.y - h * 0.20),
            control1: CGPoint(x: c.x - r * 1.38, y: c.y - h * 0.06),
            control2: CGPoint(x: c.x - r * 0.88, y: c.y - h * 0.66)
        )
        path.addCurve(
            to: CGPoint(x: c.x, y: c.y + h * 0.42),
            control1: CGPoint(x: c.x + r * 0.88, y: c.y - h * 0.66),
            control2: CGPoint(x: c.x + r * 1.38, y: c.y - h * 0.06)
        )
        path.closeSubpath()
        return path
    }

    // MARK: 背景

    /// graphite：极淡的竖纹，每 3pt 一条，合成一个 Path 一次 stroke 画完。
    private func drawTexture(_ context: GraphicsContext) {
        var path = Path()
        var x: Double = 0
        while x < Double(size.width) {
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: Double(size.height)))
            x += 3
        }
        context.stroke(
            path,
            with: .color(isDark ? Color.white.opacity(0.012) : Color.black.opacity(0.009)),
            lineWidth: 1
        )
    }

    private func drawSpecks(_ context: GraphicsContext, t: Double) {
        for s in Decor.specks {
            let x = s.x * Double(size.width)
            let y = s.y * Double(size.height)
            let a = s.opacity * (0.55 + 0.45 * sin(t * 1.4 + x))
            context.fill(
                Path(ellipseIn: CGRect(x: x - s.r, y: y - s.r, width: s.r * 2, height: s.r * 2)),
                with: .color(.white.opacity(a))
            )
        }
    }
}

// MARK: - 夜港的星点（固定种子，每次启动一致）

private struct Speck {
    let x, y, r, opacity: Double
}

private enum Decor {
    static let specks: [Speck] = {
        var n = Noise(31_415_926)
        return (0..<80).map { _ in
            Speck(x: n.next(), y: n.next() * 0.72, r: n.next() * 0.9 + 0.25,
                  opacity: 0.12 + n.next() * 0.45)
        }
    }()
}

private struct Noise {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / Double(UInt64(1) << 53)
    }
}

// MARK: - 副标题

/// `.tracking()` 本身不参与插值，套一层 Animatable 让字距真的收拢。
private struct LaunchSubtitle: View, Animatable {
    var tracking: CGFloat
    let color: Color

    var animatableData: CGFloat {
        get { tracking }
        set { tracking = newValue }
    }

    var body: some View {
        Text("FLYING HOME TO YOU")
            .font(.system(size: 10, weight: .regular))
            .tracking(tracking)
            .foregroundStyle(color)
    }
}
