import SwiftUI
import UIKit

/// 章节正文。用 UITextView 而不是 SwiftUI 的 Text，是因为共读要的东西 SwiftUI 给不了：
/// 选中区间的字符偏移、选择菜单里塞自己的动作、以及"视口顶部现在是第几个字"。
/// 注意正文里不掺任何额外文字（章节标题在顶栏），否则偏移会整体错位，
/// 划线会挪位、furthest 会失真。
struct ReaderTextView: UIViewRepresentable {
    let text: String
    let charCount: Int
    let annotations: [BookAnnotation]
    let fontSize: Double
    let fontWeight: Double
    /// 行距倍数（相对字号）
    let lineSpacing: Double
    /// 左右页边留白
    let margin: Double
    let textColor: UIColor
    let herHighlight: UIColor
    let aiHighlight: UIColor
    let scrollToOffset: Int?
    let onVisibleOffset: (Int) -> Void
    let onMark: (Int, Int, String) -> Void
    let onAnnotate: (Int, Int, String) -> Void
    let onTapAnnotations: ([BookAnnotation]) -> Void

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.alwaysBounceVertical = true
        view.showsVerticalScrollIndicator = true
        view.delegate = context.coordinator
        view.contentInsetAdjustmentBehavior = .never

        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)

        context.coordinator.textView = view
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        view.textContainerInset = UIEdgeInsets(
            top: 14, left: CGFloat(margin), bottom: 90, right: CGFloat(margin)
        )

        // 排版签名（正文/字号/行距）变了才重建；只是多了一条划线的话，
        // 走下面的属性增量——重新赋 attributedText 会让 TextKit 重排后把
        // 滚动位置甩到别处（她一划线页面就跳到底，就是这么来的）。
        let layoutSignature = "\(text.hashValue)#\(fontSize)#\(fontWeight)#\(lineSpacing)#\(textColor)"
        let markSignature = annotations
            .map { "\($0.id):\($0.startOff)-\($0.endOff):\($0.author):\($0.hasNote)" }
            .joined(separator: ",")

        if coordinator.layoutSignature != layoutSignature {
            let sameText = coordinator.renderedText == text
            let keepOffset = sameText ? view.contentOffset.y : 0
            coordinator.layoutSignature = layoutSignature
            coordinator.markSignature = markSignature
            coordinator.renderedText = text
            view.attributedText = attributedChapter()
            if sameText {
                // 排版换了尺寸，位置要等布局落定再钉回去
                DispatchQueue.main.async {
                    let maxY = max(0, view.contentSize.height - view.bounds.height)
                    view.setContentOffset(CGPoint(x: 0, y: min(keepOffset, maxY)), animated: false)
                }
            }
        } else if coordinator.markSignature != markSignature {
            coordinator.markSignature = markSignature
            applyMarks(to: view.textStorage, replacingExisting: true)
        }

        if let target = scrollToOffset, coordinator.appliedScrollTarget != target {
            coordinator.appliedScrollTarget = target
            DispatchQueue.main.async { coordinator.scroll(to: target) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    // MARK: - 排版

    private var readerFont: UIFont {
        ReaderSongtiFont.uiFont(size: CGFloat(fontSize), weight: fontWeight)
    }

    private func attributedChapter() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = CGFloat(fontSize * lineSpacing)
        // EPUB chapters already contain paragraph breaks. Adding another half
        // line after every paragraph doubled that gap and made the page look
        // like separate cards rather than continuous book text.
        paragraph.paragraphSpacing = 0
        paragraph.firstLineHeadIndent = CGFloat(fontSize) * 2
        paragraph.alignment = .justified

        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: readerFont,
                .foregroundColor: textColor,
                .paragraphStyle: paragraph
            ]
        )
        applyMarks(to: attributed, replacingExisting: false)
        return attributed
    }

    /// 划线只是几个属性的事，别去动文本本身。
    private func applyMarks(to storage: NSMutableAttributedString, replacingExisting: Bool) {
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        if replacingExisting {
            storage.removeAttribute(.backgroundColor, range: full)
            storage.removeAttribute(.underlineStyle, range: full)
            storage.removeAttribute(.underlineColor, range: full)
        }
        // 她的先上色，小克的压在上面：他留的话本来就该更显眼一点
        for annotation in annotations.sorted(by: { !$0.isAI && $1.isAI }) {
            let start = ScalarOffset.toUTF16(text, annotation.startOff)
            let end = ScalarOffset.toUTF16(text, annotation.endOff)
            guard end > start, start >= 0, end <= storage.length else { continue }
            let range = NSRange(location: start, length: end - start)
            storage.addAttribute(
                .backgroundColor,
                value: annotation.isAI ? aiHighlight : herHighlight,
                range: range
            )
            if annotation.hasNote {
                storage.addAttributes([
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: annotation.isAI ? aiHighlight.withAlphaComponent(0.9) : herHighlight.withAlphaComponent(0.9)
                ], range: range)
            }
        }
        storage.endEditing()
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: ReaderTextView
        weak var textView: UITextView?
        var layoutSignature = ""
        var markSignature = ""
        var renderedText = ""
        var appliedScrollTarget: Int?

        init(parent: ReaderTextView) {
            self.parent = parent
        }

        // MARK: 视口顶部现在读到哪

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard let view = textView else { return }
            parent.onVisibleOffset(currentOffset(in: view))
        }

        private func currentOffset(in view: UITextView) -> Int {
            // 滚到底就是这一章读完了，直接报满。不然 furthest 永远差一屏，
            // chapter-done 就永远不会触发。
            if view.contentOffset.y + view.bounds.height >= view.contentSize.height - 8 {
                return parent.charCount
            }
            let point = CGPoint(
                x: view.textContainerInset.left + 2,
                y: view.contentOffset.y + view.textContainerInset.top + 2
            )
            guard let position = view.closestPosition(to: point) else { return 0 }
            let utf16Offset = view.offset(from: view.beginningOfDocument, to: position)
            return min(parent.charCount, ScalarOffset.fromUTF16(parent.text, utf16Offset))
        }

        func scroll(to scalarOffset: Int) {
            guard let view = textView, scalarOffset > 0 else {
                textView?.setContentOffset(.zero, animated: false)
                return
            }
            view.layoutIfNeeded()
            let utf16Offset = ScalarOffset.toUTF16(parent.text, scalarOffset)
            guard let position = view.position(from: view.beginningOfDocument, offset: utf16Offset) else { return }
            let rect = view.caretRect(for: position)
            guard rect.origin.y.isFinite else { return }
            let maxY = max(0, view.contentSize.height - view.bounds.height + view.textContainerInset.bottom)
            view.setContentOffset(CGPoint(x: 0, y: min(max(0, rect.minY - 10), maxY)), animated: false)
        }

        // MARK: 选中之后能做什么

        func textView(
            _ textView: UITextView,
            editMenuForTextIn range: NSRange,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            guard range.length > 0 else { return UIMenu(children: suggestedActions) }
            let text = parent.text
            let start = ScalarOffset.fromUTF16(text, range.location)
            let end = ScalarOffset.fromUTF16(text, range.location + range.length)
            guard end > start else { return UIMenu(children: suggestedActions) }
            let quote = ScalarOffset.substring(text, from: start, to: end)

            // 划完就退出选择态：选区留着，后面任何一次重新布局都可能被系统
            // 当成"要把插入点滚进视野"，把她读的位置带走。
            let leaveSelection = { [weak textView] in
                textView?.selectedTextRange = nil
                textView?.resignFirstResponder()
            }
            let mark = UIAction(title: "划线", image: UIImage(systemName: "highlighter")) { [weak self] _ in
                guard let self else { return }
                leaveSelection()
                self.parent.onMark(start, end, quote)
            }
            let annotate = UIAction(title: "写批注", image: UIImage(systemName: "square.and.pencil")) { [weak self] _ in
                guard let self else { return }
                leaveSelection()
                self.parent.onAnnotate(start, end, quote)
            }
            return UIMenu(children: [mark, annotate] + suggestedActions)
        }

        // MARK: 点已有划线 → 看这处说过的话

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = textView, view.selectedTextRange?.isEmpty ?? true else { return }
            let point = recognizer.location(in: view)
            guard let position = view.closestPosition(to: point) else { return }
            let utf16Offset = view.offset(from: view.beginningOfDocument, to: position)
            let offset = ScalarOffset.fromUTF16(parent.text, utf16Offset)
            let hits = parent.annotations.filter { $0.startOff <= offset && $0.endOff > offset }
            guard let first = hits.first else { return }
            // 同一句被划过好几次：整组一起看
            let group = parent.annotations.filter { $0.endOff > first.startOff && $0.startOff < first.endOff }
            parent.onTapAnnotations(group)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

/// Songti SC is a four-face family rather than a variable font. Asking its
/// regular descriptor for an arbitrary weight leaves the glyphs unchanged on
/// iOS, so map the slider to the actual installed faces instead.
enum ReaderSongtiFont {
    static func face(for weight: Double) -> String {
        switch weight {
        case ..<375: return "STSongti-SC-Light"
        case ..<525: return "STSongti-SC-Regular"
        case ..<650: return "STSongti-SC-Bold"
        default: return "STSongti-SC-Black"
        }
    }

    static func uiFont(size: CGFloat, weight: Double) -> UIFont {
        UIFont(name: face(for: weight), size: size)
            ?? UIFont(name: "Songti SC", size: size)
            ?? UIFont.systemFont(ofSize: size)
    }

    static func font(size: Double, weight: Double) -> Font {
        .custom(face(for: weight), fixedSize: CGFloat(size))
    }
}
