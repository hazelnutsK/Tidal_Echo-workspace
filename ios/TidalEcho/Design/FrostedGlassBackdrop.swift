import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// The chat wallpaper, blurred once, that every frosted bubble shows a slice of.
///
/// The old frosted bubble gave each message its own live backdrop blur, and the
/// liquid one its own system Glass: every visible bubble re-sampled and
/// re-blurred the screen on every scroll frame. Behind a chat bubble there is
/// only ever the wallpaper, so the frost can be computed once here and each
/// bubble just shows the matching window of it — the approach Telegram uses for
/// wallpaper-backed bubbles. Scrolling then only moves an image.
struct FrostedBackdrop: Equatable {
    let image: UIImage
    /// Where the wallpaper sits in global coordinates; slices align to it.
    let frame: CGRect
    /// Mean perceived luminance of the blurred wallpaper, 0...1.
    let luminance: Double

    static func == (lhs: FrostedBackdrop, rhs: FrostedBackdrop) -> Bool {
        lhs.image === rhs.image && lhs.frame == rhs.frame && lhs.luminance == rhs.luminance
    }
}

private struct FrostedBackdropKey: EnvironmentKey {
    static let defaultValue: FrostedBackdrop? = nil
}

extension EnvironmentValues {
    var frostedBackdrop: FrostedBackdrop? {
        get { self[FrostedBackdropKey.self] }
        set { self[FrostedBackdropKey.self] = newValue }
    }
}

enum FrostedBackdropRenderer {
    /// Everything the chat background is drawn from. A change to any of it
    /// re-renders the frost; nothing else does.
    struct Input: Hashable {
        var wallpaper: ObjectIdentifier?
        var originX: Double
        var originY: Double
        var width: Double
        var height: Double
        var backgroundTop: [Double]
        var backgroundBottom: [Double]
        var wallpaperOpacity: Double
        var wallpaperBlur: Double

        var frame: CGRect { CGRect(x: originX, y: originY, width: width, height: height) }
    }

    /// Strong enough that text reads over any photo, light enough that the
    /// wallpaper's colors still show through as shapes rather than one mean.
    static let frostRadius: Double = 30
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func input(
        wallpaper: UIImage?,
        frame: CGRect,
        palette: EchoPalette,
        colorScheme: ColorScheme,
        wallpaperOpacity: Double,
        wallpaperBlur: Double
    ) -> Input? {
        guard frame.width >= 1, frame.height >= 1 else { return nil }
        return Input(
            wallpaper: wallpaper.map { ObjectIdentifier($0) },
            originX: frame.minX,
            originY: frame.minY,
            width: frame.width,
            height: frame.height,
            backgroundTop: rgba(palette.backgroundTop, colorScheme: colorScheme),
            backgroundBottom: rgba(palette.backgroundBottom, colorScheme: colorScheme),
            wallpaperOpacity: wallpaperOpacity,
            wallpaperBlur: wallpaperBlur
        )
    }

    /// Composites the chat background exactly as ChatView draws it, then
    /// frosts it. Sampled at 1x: a 30pt blur has no detail left for 3x to keep.
    static func render(wallpaper: UIImage?, input: Input) -> FrostedBackdrop? {
        let size = CGSize(width: input.width, height: input.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let top = input.backgroundTop, bottom = input.backgroundBottom
        let base = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            // palette.background: top color at the top-leading corner, bottom
            // color at the bottom-trailing one.
            let colors = [
                UIColor(red: top[0], green: top[1], blue: top[2], alpha: 1).cgColor,
                UIColor(red: bottom[0], green: bottom[1], blue: bottom[2], alpha: 1).cgColor
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
                ctx.cgContext.drawLinearGradient(
                    gradient,
                    start: .zero,
                    end: CGPoint(x: size.width, y: size.height),
                    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                )
            }
            if let wallpaper, wallpaper.size.width > 0, wallpaper.size.height > 0 {
                let zoom = CGFloat(1 + input.wallpaperBlur / 260)
                let fill = max(size.width / wallpaper.size.width, size.height / wallpaper.size.height) * zoom
                let drawn = CGSize(width: wallpaper.size.width * fill, height: wallpaper.size.height * fill)
                let rect = CGRect(
                    x: (size.width - drawn.width) / 2,
                    y: (size.height - drawn.height) / 2,
                    width: drawn.width,
                    height: drawn.height
                )
                wallpaper.draw(in: rect, blendMode: .normal, alpha: CGFloat(input.wallpaperOpacity))
            }
        }
        guard let cgBase = base.cgImage else { return nil }

        let source = CIImage(cgImage: cgBase)
        // The wallpaper's own blur and the frost stack like two Gaussians.
        let radius = (input.wallpaperBlur * input.wallpaperBlur + frostRadius * frostRadius).squareRoot()
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = source.clampedToExtent()
        blur.radius = Float(radius)
        // A blur averages colors toward gray; lifting saturation afterwards is
        // what keeps frost looking like tinted glass instead of fog.
        let vivid = CIFilter.colorControls()
        vivid.inputImage = blur.outputImage
        vivid.saturation = 1.45
        guard let frosted = vivid.outputImage?.cropped(to: source.extent),
              let cgFrosted = context.createCGImage(frosted, from: source.extent)
        else { return nil }

        return FrostedBackdrop(
            image: UIImage(cgImage: cgFrosted, scale: 1, orientation: .up),
            frame: input.frame,
            luminance: averageLuminance(of: frosted) ?? 0.5
        )
    }

    private static func averageLuminance(of image: CIImage) -> Double? {
        let average = CIFilter.areaAverage()
        average.inputImage = image
        average.extent = image.extent
        guard let output = average.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )
        return FrostRecipe.luminance(Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
    }

    static func rgba(_ color: Color, colorScheme: ColorScheme) -> [Double] {
        let traits = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).resolvedColor(with: traits).getRed(&r, green: &g, blue: &b, alpha: &a)
        return [Double(r), Double(g), Double(b), Double(a)]
    }
}

/// How much veil and tint go over the frost.
///
/// The old bubbles laid a fixed thin wash over whatever the wallpaper was, so a
/// mid-tone photo came out as mid-gray glass that neither black nor white text
/// sat comfortably on. Here the veil follows the text: dark text gets a milky
/// white frost lifted until it is light enough, light text gets a smoky one
/// pressed until it is dark enough, measured against the actual wallpaper.
struct FrostRecipe {
    let veil: Color
    let veilOpacity: Double
    let tintOpacity: Double
    let isLightGlass: Bool

    init(textColor: Color, colorScheme: ColorScheme, backdropLuminance: Double, tintOpacity: Double) {
        let text = FrostedBackdropRenderer.rgba(textColor, colorScheme: colorScheme)
        let textLuminance = Self.luminance(text[0], text[1], text[2])
        let tint = max(0, min(1, tintOpacity))
        // The opacity slider now means how much of the bubble color colors the
        // glass. Even at 100% it stops short of solid, or it would not be glass.
        self.tintOpacity = tint * 0.42
        isLightGlass = textLuminance < 0.5
        let base = max(0.001, min(0.999, backdropLuminance))
        let needed: Double
        if isLightGlass {
            veil = .white
            needed = min(0.74, max(0.20, (0.86 - base) / (1 - base)))
        } else {
            veil = .black
            needed = min(0.64, max(0.16, 1 - 0.24 / base))
        }
        // The tint covers part of the frost itself, so less veil is needed.
        veilOpacity = needed * (1 - self.tintOpacity * 0.8)
    }

    static func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        0.299 * r + 0.587 * g + 0.114 * b
    }
}

/// A frosted bubble in any of the bubble silhouettes, Telegram tails included.
struct FrostedGlassBubbleBackground<BubbleShape: Shape>: View {
    let shape: BubbleShape
    let tint: Color
    let tintOpacity: Double
    let textColor: Color

    @Environment(\.frostedBackdrop) private var backdrop
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let recipe = FrostRecipe(
            textColor: textColor,
            colorScheme: colorScheme,
            backdropLuminance: backdrop?.luminance ?? (colorScheme == .dark ? 0.22 : 0.72),
            tintOpacity: tintOpacity
        )
        ZStack {
            if reduceTransparency {
                shape.fill(recipe.isLightGlass ? Color.white.opacity(0.92) : Color.black.opacity(0.82))
            } else if let backdrop {
                wallpaperSlice(backdrop)
            } else {
                // Off the chat screen (settings previews) there is no shared
                // backdrop; one live blur there costs nothing.
                Color.clear.overlay {
                    VariableBackdropBlur(radius: 26, mask: .solid, saturation: 1.6, resolutionScale: 1)
                        .padding(-14)
                }
            }
            shape.fill(recipe.veil.opacity(reduceTransparency ? 0 : recipe.veilOpacity))
            shape.fill(tint.opacity(recipe.tintOpacity))
            // A faint gloss from the top corner keeps the surface from reading
            // as a flat sticker.
            shape.fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(recipe.isLightGlass ? 0.16 : 0.07),
                        Color.white.opacity(0)
                    ],
                    startPoint: .topLeading,
                    endPoint: .center
                )
            )
            // Thin bright rim. Clipping cuts the stroke's outer half off, so it
            // lands at about 0.6pt — an edge catching light, not a drawn border.
            shape.stroke(
                LinearGradient(
                    colors: recipe.isLightGlass
                        ? [Color.white.opacity(0.85), Color.white.opacity(0.35), Color.white.opacity(0.55)]
                        : [Color.white.opacity(0.30), Color.white.opacity(0.08), Color.white.opacity(0.16)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1.2
            )
        }
        // One clip for every layer; no blur and no shadow, so nothing here
        // needs an offscreen pass while the list scrolls.
        .clipShape(shape)
        .allowsHitTesting(false)
    }

    private func wallpaperSlice(_ backdrop: FrostedBackdrop) -> some View {
        let origin = backdrop.frame.origin
        return Color.clear.overlay(alignment: .topLeading) {
            Image(uiImage: backdrop.image)
                .resizable()
                .interpolation(.medium)
                .frame(width: backdrop.frame.width, height: backdrop.frame.height)
                // Offsetting inside visualEffect follows scrolling on the
                // render side without invalidating the bubble's body.
                .visualEffect { content, proxy in
                    let placed = proxy.frame(in: .global)
                    return content.offset(x: origin.x - placed.minX, y: origin.y - placed.minY)
                }
        }
    }
}
