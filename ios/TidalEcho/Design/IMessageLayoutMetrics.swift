import Foundation

/// Measured from the supplied 591 × 1280 reference, in image pixels.
/// Scale from the actual chat viewport, never the global screen or the font size.
struct IMessageLayoutMetrics {
    let viewportWidth: CGFloat
    private var scale: CGFloat { viewportWidth / 591 }

    var composerInset: CGFloat { 42 * scale }
    var composerGap: CGFloat { 18 * scale }
    var composerHeight: CGFloat { 60 * scale }
    var composerFontSize: CGFloat { 26 * scale }
    var textInset: CGFloat { 24 * scale }
    var plusFontSize: CGFloat { 28 * scale }
    var waveformFontSize: CGFloat { 27 * scale }
    var actionWidth: CGFloat { 54 * scale }
    var actionInset: CGFloat { 5 * scale }
    var sendDiameter: CGFloat { 43 * scale }
    var headerInset: CGFloat { 24 * scale }
    var headerButtonDiameter: CGFloat { 66 * scale }
    var headerIconSize: CGFloat { 28 * scale }
    var headerGap: CGFloat { 14 * scale }
    var avatarDiameter: CGFloat { 90 * scale }
    var headerBottomPadding: CGFloat { 14 * scale }
    var headerHeight: CGFloat { avatarDiameter + headerBottomPadding }
}
