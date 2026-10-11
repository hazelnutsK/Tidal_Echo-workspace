import SwiftUI

/// Identity of a rendered bubble: the same text rendered with the same styling
/// always produces the same `AttributedString`.
struct MarkdownStyleKey: Hashable {
    let source: String
    let chatFont: EchoChatFont
    let fontScale: Double
    let chatWeight: Double
    let textColor: Color
    let codeBackground: Color
}

/// Memoises Markdown-parsed bubble text.
///
/// `AttributedString(markdown:)` plus the run walk that applies bold/italic/code
/// styling runs in the hundreds of microseconds for a long reply, and SwiftUI
/// re-evaluates a bubble's body whenever anything upstream changes — so it was
/// being paid over and over while scrolling. Backed by `NSCache` so the entries
/// are evicted under memory pressure rather than growing without bound.
final class MarkdownRenderCache {
    static let shared = MarkdownRenderCache()

    private let storage = NSCache<NSNumber, Box>()

    private final class Box {
        let key: MarkdownStyleKey
        let value: AttributedString

        init(key: MarkdownStyleKey, value: AttributedString) {
            self.key = key
            self.value = value
        }
    }

    private init() {
        storage.countLimit = 600
    }

    func value(for key: MarkdownStyleKey) -> AttributedString? {
        guard let box = storage.object(forKey: NSNumber(value: key.hashValue)) else { return nil }
        // Guard against the (astronomically unlikely) hash collision so a
        // bubble can never render someone else's text.
        return box.key == key ? box.value : nil
    }

    func store(_ value: AttributedString, for key: MarkdownStyleKey) {
        storage.setObject(Box(key: key, value: value), forKey: NSNumber(value: key.hashValue))
    }
}
