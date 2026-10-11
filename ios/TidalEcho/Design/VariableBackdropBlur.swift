import CoreImage.CIFilterBuiltins
import QuartzCore
import SwiftUI
import UIKit

enum VariableBlurMask: Equatable {
    case blurredTopClearBottom
    case clearTopBlurredBottom
    case solid
}

enum VariableBlurFalloff: Equatable {
    case linear
    /// Ease into the first few points of blur before building a denser fog.
    case gentle
}

/// A live backdrop blur adapted from jtrivedi/VariableBlurView and
/// nikstar/VariableBlur. `CAFilter` is private API, so this is intended for
/// the app's personal sideloaded build rather than App Store distribution.
struct VariableBackdropBlur: UIViewRepresentable {
    var radius: CGFloat = 18
    var mask: VariableBlurMask = .blurredTopClearBottom
    /// Distance from the blurred physical edge, normalized to 0...1.
    /// Blur is solid through `fadeFrom`, fades until `fadeTo`, and is fully
    /// clear for the rest of the view. Both endpoints stay inside the frame.
    var fadeFrom: CGFloat = 0
    var fadeTo: CGFloat = 1
    var falloff: VariableBlurFalloff = .linear
    /// Saturation applied to the backdrop *before* it is blurred, matching the
    /// Compose `vibrancy()` effect. 1 leaves colors untouched.
    var saturation: CGFloat = 1
    /// Pixel density the backdrop is sampled at, or nil for the screen's own
    /// scale. A blur is a low-frequency signal, so sampling a heavily blurred
    /// surface at 1x instead of 3x costs 9x fewer pixels for no visible loss —
    /// which is what makes a per-item backdrop affordable in a scrolling list.
    /// Keep full scale for lightly blurred surfaces, where downsampling shows.
    var resolutionScale: CGFloat?

    func makeUIView(context: Context) -> VariableBackdropUIView {
        VariableBackdropUIView(
            radius: radius,
            mask: mask,
            fadeFrom: fadeFrom,
            fadeTo: fadeTo,
            falloff: falloff,
            saturation: saturation,
            resolutionScale: resolutionScale
        )
    }

    func updateUIView(_ uiView: VariableBackdropUIView, context: Context) {
        uiView.update(
            radius: radius,
            mask: mask,
            fadeFrom: fadeFrom,
            fadeTo: fadeTo,
            falloff: falloff,
            saturation: saturation,
            resolutionScale: resolutionScale
        )
    }
}

final class VariableBackdropUIView: UIVisualEffectView {
    private static let imageContext = CIContext(options: [.cacheIntermediates: true])

    private var variableBlurFilter: NSObject?
    private var saturationFilter: NSObject?
    private var blurRadius: CGFloat
    private var blurMask: VariableBlurMask
    private var fadeFrom: CGFloat
    private var fadeTo: CGFloat
    private var falloff: VariableBlurFalloff
    private var cachedMaskImage: CGImage?
    private var saturation: CGFloat
    private var resolutionScale: CGFloat?

    init(
        radius: CGFloat,
        mask: VariableBlurMask,
        fadeFrom: CGFloat,
        fadeTo: CGFloat,
        falloff: VariableBlurFalloff = .linear,
        saturation: CGFloat = 1,
        resolutionScale: CGFloat? = nil
    ) {
        blurRadius = radius
        blurMask = mask
        self.fadeFrom = fadeFrom
        self.fadeTo = fadeTo
        self.falloff = falloff
        self.saturation = saturation
        self.resolutionScale = resolutionScale
        super.init(effect: UIBlurEffect(style: .regular))
        isUserInteractionEnabled = false
        installFilterIfPossible()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        radius: CGFloat,
        mask: VariableBlurMask,
        fadeFrom: CGFloat,
        fadeTo: CGFloat,
        falloff: VariableBlurFalloff,
        saturation: CGFloat,
        resolutionScale: CGFloat?
    ) {
        let saturationChanged = saturation != self.saturation
        let scaleChanged = resolutionScale != self.resolutionScale
        let maskChanged = mask != blurMask
            || fadeFrom != self.fadeFrom
            || fadeTo != self.fadeTo
            || falloff != self.falloff
        guard radius != blurRadius
            || maskChanged
            || saturationChanged
            || scaleChanged
        else { return }
        blurRadius = radius
        blurMask = mask
        self.fadeFrom = fadeFrom
        self.fadeTo = fadeTo
        self.falloff = falloff
        if maskChanged { cachedMaskImage = nil }
        self.saturation = saturation
        self.resolutionScale = resolutionScale
        if scaleChanged {
            applyBackdropScale()
        }
        // Crossing the 1.0 boundary adds or removes a filter, so the chain has
        // to be rebuilt rather than just re-valued.
        if saturationChanged {
            installFilterIfPossible()
        } else {
            applyFilterValues()
        }
    }

    private func applyBackdropScale() {
        guard let backdropLayer = subviews.first?.layer else { return }
        let fallback = window?.traitCollection.displayScale ?? traitCollection.displayScale
        backdropLayer.setValue(resolutionScale ?? fallback, forKey: "scale")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        installFilterIfPossible()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        applyBackdropScale()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        // Calling super here crashes on some iOS 16 builds after replacing the
        // visual-effect filters. Reinstalling in layoutSubviews is sufficient.
        installFilterIfPossible()
    }

    private func makeFilter(named name: String) -> NSObject? {
        let className = String("retliFAC".reversed())
        let selectorName = String(":epyThtiWretlif".reversed())
        guard
            let filterClass = NSClassFromString(className) as? NSObject.Type,
            let filter = filterClass
                .perform(NSSelectorFromString(selectorName), with: name)?
                .takeUnretainedValue() as? NSObject
        else { return nil }
        return filter
    }

    private func installFilterIfPossible() {
        guard let backdropLayer = subviews.first?.layer else { return }

        if variableBlurFilter == nil {
            variableBlurFilter = makeFilter(named: "variableBlur")
        }
        if saturationFilter == nil, saturation != 1 {
            saturationFilter = makeFilter(named: "colorSaturate")
        }

        applyFilterValues()
        // The backdrop subview can appear after init, so claim the sampling
        // scale here too rather than only on the window transition.
        applyBackdropScale()

        // Saturate before blurring, mirroring the Compose backdrop's
        // `vibrancy()` → `blur()` order: boosting afterwards would amplify the
        // averaged mush instead of the colors that fed it.
        var chain: [NSObject] = []
        if saturation != 1, let saturationFilter {
            chain.append(saturationFilter)
        }
        if let variableBlurFilter {
            chain.append(variableBlurFilter)
        }
        if !chain.isEmpty {
            backdropLayer.filters = chain
        }

        // Remove UIVisualEffectView's system gray/tint layers. Only the live
        // backdrop layer and our explicit SwiftUI tint remain visible.
        for subview in subviews.dropFirst() {
            subview.alpha = 0
        }
    }

    private func applyFilterValues() {
        saturationFilter?.setValue(saturation, forKey: "inputAmount")
        guard let variableBlurFilter else { return }
        variableBlurFilter.setValue(blurRadius, forKey: "inputRadius")
        if cachedMaskImage == nil { cachedMaskImage = makeMaskImage() }
        variableBlurFilter.setValue(cachedMaskImage, forKey: "inputMaskImage")
        variableBlurFilter.setValue(true, forKey: "inputNormalizeEdges")
    }

    private func makeMaskImage(width: CGFloat = 2, height: CGFloat = 512) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)

        if blurMask == .solid {
            return Self.imageContext.createCGImage(
                CIImage(color: CIColor.black).cropped(to: bounds),
                from: bounds
            )
        }

        let gradient = CIFilter.linearGradient()
        gradient.color0 = CIColor.black
        gradient.color1 = CIColor.clear
        let solidEnd = min(max(fadeFrom, 0), 1)
        let clearStart = min(max(fadeTo, solidEnd + 0.001), 1)

        // Core Image's origin is bottom-left. For a top blur, the black
        // (full-alpha) endpoint therefore has the larger y coordinate. For a
        // bottom blur the mapping is mirrored. Outside these two points the
        // gradient clamps to solid/clear, so the view boundary is already at
        // zero blur instead of cutting a still-active filter.
        switch blurMask {
        case .blurredTopClearBottom:
            gradient.point0 = CGPoint(x: 0, y: height * (1 - solidEnd))
            gradient.point1 = CGPoint(x: 0, y: height * (1 - clearStart))
        case .clearTopBlurredBottom:
            gradient.point0 = CGPoint(x: 0, y: height * solidEnd)
            gradient.point1 = CGPoint(x: 0, y: height * clearStart)
        case .solid:
            break
        }

        guard var output = gradient.outputImage else { return nil }
        if falloff == .gentle {
            // t is the linear mask alpha, increasing from the clear edge.
            // smoothstep(t)^2 keeps the low-radius entrance long and soft,
            // with zero slope at both ends. A linear 16pt ramp otherwise
            // erases small glyphs within just a few points of scrolling.
            let smooth = CIFilter.colorPolynomial()
            smooth.inputImage = output
            smooth.alphaCoefficients = CIVector(x: 0, y: 0, z: 3, w: -2)
            guard let smoothed = smooth.outputImage else { return nil }
            let ease = CIFilter.colorPolynomial()
            ease.inputImage = smoothed
            ease.alphaCoefficients = CIVector(x: 0, y: 0, z: 1, w: 0)
            guard let eased = ease.outputImage else { return nil }
            output = eased
        }
        return Self.imageContext.createCGImage(output, from: bounds)
    }
}
