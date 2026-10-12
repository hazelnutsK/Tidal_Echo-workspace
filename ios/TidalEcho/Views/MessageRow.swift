import SwiftUI
import UIKit
import QuickLook
import Photos

private enum CallLifecycleEvent: Equatable {
    case started
    case ended
    case missed

    var icon: String {
        switch self {
        case .started: return "phone"
        case .ended: return "phone.down"
        case .missed: return "phone.down.fill"
        }
    }

    var title: String {
        switch self {
        case .started: return "语音通话开启"
        case .ended: return "语音通话结束"
        case .missed: return "未接来电"
        }
    }
}

private struct CallLifecycleEventRow: View {
    let event: CallLifecycleEvent
    let palette: EchoPalette
    let fontScale: Double

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: event.icon)
            Text(event.title)
        }
        .font(.system(size: CGFloat(13 * fontScale), weight: .medium))
        .foregroundStyle(event == .missed ? Color.red : palette.secondaryText)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }
}

private enum IncomingCallCardState: Equatable {
    case ringing
    case missed
    case ended

    var icon: String {
        switch self {
        case .ringing: return "phone.fill"
        case .missed: return "phone.down.fill"
        case .ended: return "phone.down"
        }
    }

    var color: Color {
        switch self {
        case .ringing: return .green
        case .missed: return .red
        case .ended: return .gray
        }
    }

    func subtitle(_ fallback: String) -> String {
        switch self {
        case .ringing: return fallback
        case .missed: return "未接听"
        case .ended: return "通话已结束"
        }
    }

    func accessibilityLabel(peerName: String) -> String {
        switch self {
        case .ringing: return "\(peerName)来电，接听"
        case .missed: return "\(peerName)未接来电"
        case .ended: return "\(peerName)通话已结束"
        }
    }
}

struct MessageRow: View {
    let message: ChatMessage
    let palette: EchoPalette
    let chatFont: EchoChatFont
    let fontScale: Double
    let showsAIAvatar: Bool
    let showsHumanAvatar: Bool
    let aiAvatarImage: UIImage?
    let humanAvatarImage: UIImage?
    let showsAIBubble: Bool
    let aiBubbleColor: Color
    let humanBubbleColor: Color
    let aiBubbleTextColor: Color
    let humanBubbleTextColor: Color
    let bubbleOpacity: Double
    let bubbleRadius: Double
    let bubbleWidthScale: Double
    let bubbleBorderWidth: Double
    let bubbleStyle: EchoBubbleStyle
    let bubbleShapeStyle: EchoBubbleShapeStyle
    let liquidGlass: LiquidGlassSettings
    let chatWeight: Double
    let peerName: String
    let showsTimestamp: Bool
    let apiUsageText: String?
    let isGroupStart: Bool
    let showsAvatarHeader: Bool
    let isTail: Bool
    let isGroupedWithPrevious: Bool
    let isPaper: Bool
    let isMist: Bool
    let isNest: Bool
    /// Last bubble of an AI burst. Short-chat mode splits one reply across
    /// several bubbles; the action row belongs under the last one only.
    let isNestGroupTail: Bool
    let showsNestDisclaimer: Bool
    let isIncomingCallActive: Bool
    let onToggleStar: () -> Void
    let onSpeak: () -> Void
    let onCopy: () -> Void
    let onEdit: () -> Void
    let onRegenerate: () -> Void
    let onHide: () -> Void
    let onReact: (String) -> Void
    let onTranslateThinking: () async throws -> String
    let onCompleteTimer: () -> Void
    let onOpenAsk: () -> Void
    /// 程序化点不开系统广播面板时，这张共享卡要露出真的那颗按钮让她手点。
    let peekNeedsManualPicker: Bool
    let onAcceptPeek: () async -> Void
    let onDeclinePeek: () async -> Void
    let onAnswerCall: () -> Void
    let attachmentRequest: (Attachment) -> URLRequest?

    var body: some View {
        Group {
            if let event = callLifecycleEvent {
                CallLifecycleEventRow(event: event, palette: palette, fontScale: fontScale)
            } else if message.kind == "thinking" || message.kind == "act" {
                ProcessRow(
                    message: message,
                    palette: palette,
                    chatFont: chatFont,
                    fontScale: fontScale,
                    chatWeight: chatWeight,
                    isPaper: isPaper,
                    isMist: isMist,
                    isNest: isNest,
                    showsAIAvatar: showsAIAvatar,
                    aiAvatarImage: aiAvatarImage,
                    bubbleWidthScale: bubbleWidthScale,
                    usesUpperTailAvatarLayout: usesUpperTailAvatarLayout,
                    showsAvatarHeader: showsAvatarHeader,
                    onTranslate: onTranslateThinking
                )
            } else if message.kind == "call" {
                if message.author == .ai {
                    if incomingCallCardState == .ringing {
                        Button(action: onAnswerCall) {
                            incomingCallCard(state: .ringing)
                        }
                        .buttonStyle(.plain)
                    } else {
                        incomingCallCard(state: incomingCallCardState)
                    }
                } else {
                    Text(message.text)
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                }
            } else {
                bubble
            }
        }
        .padding(.top, isGroupedWithPrevious ? compactGroupTopPadding : 0)
    }

    private var callLifecycleEvent: CallLifecycleEvent? {
        guard message.kind == "call" else { return nil }
        if message.text.contains("[call_start]") {
            return .started
        }
        if message.text.contains("[call_end]") {
            return .ended
        }
        if message.text.contains("[call_missed]") {
            return .missed
        }
        return nil
    }

    private var incomingCallCardState: IncomingCallCardState {
        if message.meta.callStatus == "missed" { return .missed }
        return isIncomingCallActive ? .ringing : .ended
    }

    private func incomingCallCard(state: IncomingCallCardState) -> some View {
        HStack(spacing: 12) {
            Image(systemName: state.icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(state.color, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(state == .missed ? "\(peerName)未接来电" : "\(peerName)来电")
                    .font(.subheadline.weight(.semibold))
                Text(state.subtitle(message.text))
                    .font(.caption)
                    .lineLimit(2)
            }
            .foregroundStyle(state == .missed ? Color.red : palette.text)
            Spacer()
            if state == .ringing {
                Text("接听")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palette.accent)
            }
        }
        .padding(12)
        .background(palette.composer.opacity(0.86), in: RoundedRectangle(cornerRadius: 17))
        .padding(.horizontal, 28)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(state.accessibilityLabel(peerName: peerName))
    }

    private var bubble: some View {
        VStack(alignment: message.author == .human ? .trailing : .leading, spacing: 6) {
            if usesUpperTailAvatarLayout && showsAvatarHeader {
                upperTailAvatarHeader
            }

            bubbleContentRow
        }
        .frame(maxWidth: .infinity)
        .contextMenu { messageActions }
    }

    private var bubbleContentRow: some View {
        HStack(alignment: bubbleRowAlignment, spacing: 8) {
            if message.author == .human { Spacer(minLength: 56) }

            if message.author == .ai && showsAIAvatar && !usesUpperTailAvatarLayout {
                AvatarBadge(image: aiAvatarImage, fallback: "sparkle", palette: palette)
            }

            VStack(alignment: message.author == .human ? .trailing : .leading, spacing: 6) {
                // 我发的图不套气泡：单独一张贴在文字上面，文字自己占一个气泡。
                // （她 2026-09-04 定的：图和字合在一个大气泡里太闷。）
                if !photosOutsideBubble.isEmpty {
                    photoBlock(photosOutsideBubble)
                        .frame(maxWidth: resolvedBubbleMaxWidth, alignment: .leading)
                }

                if hasBubbleContent {
                    VStack(alignment: .leading, spacing: 9) {
                        if !photosInsideBubble.isEmpty {
                            photoBlock(photosInsideBubble)
                        }

                        ForEach(nonImageAttachments) { attachment in
                            AttachmentView(
                                attachment: attachment,
                                request: attachmentRequest(attachment),
                                palette: palette
                            )
                        }

                        if !displayedMessageText.isEmpty {
                            MarkdownMessageText(
                                source: displayedMessageText,
                                palette: palette,
                                textColor: resolvedBubbleTextColor,
                                chatFont: chatFont,
                                fontScale: fontScale,
                                chatWeight: chatWeight
                            )
                        }

                        if let card = message.meta.xhs {
                            XHSNoteCard(
                                card: card,
                                palette: palette,
                                fontScale: fontScale,
                                request: attachmentRequest
                            )
                        }

                        if let timer = message.meta.timer {
                            MessageTimerCard(
                                timer: timer,
                                palette: palette,
                                onDone: onCompleteTimer
                            )
                        }

                        if let ask = message.meta.ask {
                            MessageAskChip(ask: ask, palette: palette, onOpen: onOpenAsk)
                        }

                        if let peek = message.meta.peek {
                            MessagePeekCard(
                                peek: peek,
                                palette: palette,
                                needsManualPicker: peekNeedsManualPicker,
                                onAccept: onAcceptPeek,
                                onDecline: onDeclinePeek
                            )
                        }

                        if !message.meta.album.isEmpty {
                            MessageAlbumChip(entries: message.meta.album, palette: palette)
                        }
                    }
                    .foregroundStyle(resolvedBubbleTextColor)
                    .padding(
                        .horizontal,
                        message.author == .ai && !showsAIBubble
                            ? (isNest ? 0 : 2)
                            : bubbleHorizontalPadding
                    )
                    .padding(.vertical, bubbleVerticalPadding)
                    .background { bubbleBackground }
                    .overlay {
                        if bubbleBorderWidth > 0 && (message.author == .human || showsAIBubble) {
                            if bubbleStyle == .liquid {
                                RoundedRectangle(cornerRadius: CGFloat(bubbleRadius), style: .continuous)
                                    .stroke(palette.hairline, lineWidth: CGFloat(bubbleBorderWidth))
                            } else {
                                bubbleShape
                                    .stroke(palette.hairline, lineWidth: CGFloat(bubbleBorderWidth))
                            }
                        }
                    }
                    // Constrain wrapping without painting the background across the
                    // whole max-width frame. Short messages keep their intrinsic width.
                    .frame(
                        maxWidth: message.author == .ai && !showsAIBubble
                            ? .infinity
                            : resolvedBubbleMaxWidth,
                        alignment: message.author == .human ? .trailing : .leading
                    )
                }

                if let reaction = displayedReaction, !reaction.isEmpty {
                    Text(reaction)
                        .font(.system(size: 17))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.thinMaterial, in: Capsule())
                        .overlay(Capsule().stroke(palette.hairline))
                        .padding(.top, -7)
                        .transition(.scale.combined(with: .opacity))
                }

                if shouldShowMetaLine {
                    HStack(spacing: 5) {
                        if message.meta.edited && message.delivery == .sent {
                            Text("已编辑")
                        }
                        if message.author == .human {
                            switch message.delivery {
                            case .sending:
                                SendingClock()
                            case .failed:
                                Label("未送达", systemImage: "exclamationmark.circle.fill")
                                    .foregroundStyle(Color.red)
                            case .sent:
                                if showsTimestamp {
                                    Text(Self.formatTime(message.timestamp))
                                }
                            }
                        } else if let apiUsageText {
                            Text("\(Self.formatTime(message.timestamp)) · \(apiUsageText)")
                                .monospacedDigit()
                                .fixedSize(horizontal: false, vertical: true)
                        } else if showsTimestamp && !isNest {
                            Text(Self.formatTime(message.timestamp))
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(palette.secondaryText)
                    .padding(.horizontal, 3)
                }

                if isNest,
                   isNestGroupTail,
                   message.author == .ai,
                   message.kind == "reply",
                   message.id > 0,
                   !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    nestInlineActions
                    if showsNestDisclaimer {
                        nestDisclaimer
                    }
                }
            }

            if message.author == .human && showsHumanAvatar && !usesUpperTailAvatarLayout {
                AvatarBadge(image: humanAvatarImage, fallback: "person.fill", palette: palette)
            }

            if message.author == .ai && showsAIBubble {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var upperTailAvatarHeader: some View {
        HStack(spacing: 0) {
            if message.author == .human { Spacer(minLength: 0) }
            AvatarBadge(
                image: message.author == .human ? humanAvatarImage : aiAvatarImage,
                fallback: message.author == .human ? "person.fill" : "sparkle",
                palette: palette,
                size: 36,
                showsShadow: true
            )
            if message.author == .ai { Spacer(minLength: 0) }
        }
        .padding(.horizontal, 2)
    }

    private var nestInlineActions: some View {
        // ChatNest sets these ~28pt apart centre to centre; at 14pt glyphs that
        // is a 14pt gap, not the 20 this started with.
        HStack(spacing: 14) {
            nestActionButton("doc.on.doc", label: "复制", action: onCopy)
            nestActionButton("play", label: "朗读", action: onSpeak)
            nestActionButton(
                message.meta.starred == nil ? "star" : "star.fill",
                label: message.meta.starred == nil ? "收藏" : "取消收藏",
                isSelected: message.meta.starred != nil,
                action: onToggleStar
            )
            nestActionButton(
                myReaction == "❤️" ? "heart.fill" : "heart",
                label: myReaction == "❤️" ? "收回爱心" : "爱心回应",
                isSelected: myReaction == "❤️"
            ) { onReact(myReaction == "❤️" ? "" : "❤️") }
            HStack(spacing: 6) {
                nestActionButton("arrow.clockwise", label: "重新生成", action: onRegenerate)
                if apiUsageText == nil {
                    Text(Self.formatTime(message.timestamp))
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(palette.secondaryText.opacity(0.62))
                }
            }
        }
        .font(.system(size: 14, weight: .regular))
        .foregroundStyle(palette.secondaryText.opacity(0.84))
        .padding(.horizontal, 3)
        .padding(.top, 1)
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var nestDisclaimer: some View {
        HStack(alignment: .center, spacing: 10) {
            ClaudeBrandMark(
                size: 26,
                motion: .idle,
                color: palette.accent
            )
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 0) {
                Text("Altair is yours.")
                Text("Please double-check your heartbeat.")
            }
            .multilineTextAlignment(.trailing)
        }
        .font(.system(size: 13, weight: .regular))
        .foregroundStyle(palette.text)
        .padding(.horizontal, 3)
        .padding(.top, 16)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Altair is yours. Please double-check your heartbeat.")
    }

    private func nestActionButton(
        _ icon: String,
        label: String,
        isSelected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .foregroundStyle(isSelected ? palette.accent : palette.secondaryText.opacity(0.84))
        }
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        if message.author == .human || showsAIBubble {
            let color = message.author == .human ? humanBubbleColor : aiBubbleColor
            if bubbleStyle == .liquid {
                LiquidGlassBubbleBackground(
                    tint: color,
                    tintOpacity: bubbleOpacity,
                    radius: CGFloat(bubbleRadius),
                    settings: liquidGlass
                )
            } else {
                let shape = bubbleShape
                if bubbleStyle == .frosted {
                    FrostedGlassBubbleBackground(
                        shape: shape,
                        tint: color,
                        tintOpacity: bubbleOpacity
                    )
                } else if isNest {
                    // ChatNest's bubble is a flat tinted plate: no lift, no rim.
                    shape.fill(color.opacity(bubbleOpacity))
                } else {
                    shape
                        .fill(color.opacity(bubbleOpacity))
                        .shadow(color: Color.black.opacity(0.045 * bubbleOpacity), radius: 4.5, y: 2)
                }
            }
        }
    }

    private var bubbleShape: EchoMessageBubbleShape {
        EchoMessageBubbleShape(
            style: bubbleShapeStyle,
            author: message.author,
            radius: CGFloat(bubbleRadius),
            isGroupStart: isGroupStart,
            inflation: effectiveBubbleInflation,
            // ChatNest has no tail: every corner keeps the full radius.
            isTail: isNest ? false : isTail
        )
    }

    private var resolvedBubbleTextColor: Color {
        message.author == .ai ? aiBubbleTextColor : humanBubbleTextColor
    }

    private var resolvedBubbleMaxWidth: CGFloat {
        let scale = CGFloat(bubbleWidthScale)
        if message.author == .ai {
            // Above 100%, grow in screen-friendly point increments so 120% and
            // 130% remain visibly distinct instead of both hitting the old spacer.
            return scale <= 1 ? 280 * scale : 280 + ((scale - 1) * 140)
        }
        return 280 * min(scale, 1.2)
    }

    private var usesUpperCornerShape: Bool {
        bubbleShapeStyle == .upperTail
            && (bubbleStyle == .classic || bubbleStyle == .frosted)
    }

    private var usesUpperTailAvatarLayout: Bool {
        // Keep every other avatar/bubble combination unchanged. The detached
        // group header is only the paired-avatar treatment for upper corners.
        usesUpperCornerShape && showsAIAvatar && showsHumanAvatar
    }

    private var bubbleRowAlignment: VerticalAlignment {
        usesUpperCornerShape ? .top : .bottom
    }

    private var compactGroupTopPadding: CGFloat {
        guard bubbleStyle == .classic || bubbleStyle == .frosted else { return 0 }
        switch bubbleShapeStyle {
        case .telegram: return -6 // 9pt stack spacing becomes 3pt.
        case .upperTail: return -4 // 9pt stack spacing becomes 5pt.
        case .standard, .jelly, .neat: return 0
        }
    }

    private var smoothSpec: SmoothBubbleSpec? {
        bubbleStyle == .classic || bubbleStyle == .frosted ? bubbleShapeStyle.smoothSpec : nil
    }

    private var usesTelegramShape: Bool {
        bubbleShapeStyle == .telegram
            && (bubbleStyle == .classic || bubbleStyle == .frosted)
    }

    private var carriesBubble: Bool { message.author == .human || showsAIBubble }

    /// Measured off ChatNest: ~10pt of padding inside a bubble, and bodiless AI
    /// text almost flush, so consecutive segments read as one reply's paragraphs
    /// instead of a stack of cards.
    private var bubbleHorizontalPadding: CGFloat {
        if carriesBubble, let smoothSpec { return smoothSpec.horizontalPadding }
        if isNest { return 10 }
        return usesTelegramShape ? 10 : 13
    }

    private var bubbleVerticalPadding: CGFloat {
        if carriesBubble, let smoothSpec { return smoothSpec.verticalPadding }
        let base: CGFloat = isNest ? (carriesBubble ? 10 : 2) : (usesTelegramShape ? 8 : 9)
        return base + (carriesBubble ? PWAChatBubbleShape.inflationPadding(effectiveBubbleInflation) : 0)
    }

    private var effectiveBubbleInflation: CGFloat {
        bubbleStyle == .classic && bubbleShapeStyle == .standard ? PWAChatBubbleShape.defaultInflation : 0
    }

    private var displayedMessageText: String {
        guard message.kind == "voice" else { return message.text }
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["🎙️", "🎤", "🎙"] where text.hasPrefix(prefix) {
            return String(text.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private var displayedReaction: String? {
        message.meta.reactions[message.author == .human ? "ai" : "human"]
    }

    /// 小红书笔记的配图归预览卡管，从普通附件里摘掉（不然图会出现两次）。
    private var ownAttachments: [Attachment] {
        message.meta.attachments.filter { !$0.isXHS }
    }

    private var imageAttachments: [Attachment] {
        ownAttachments.filter(\.isImage)
    }

    private var nonImageAttachments: [Attachment] {
        ownAttachments.filter { !$0.isImage }
    }

    /// 我发的图走气泡外那条路；她自己发的图保持原样留在气泡里。
    private var photosOutsideBubble: [Attachment] {
        message.author == .ai ? imageAttachments : []
    }

    private var photosInsideBubble: [Attachment] {
        message.author == .ai ? [] : imageAttachments
    }

    /// 气泡里还剩东西吗——纯图消息就不该再画一个空气泡出来。
    private var hasBubbleContent: Bool {
        !displayedMessageText.isEmpty
            || !photosInsideBubble.isEmpty
            || !nonImageAttachments.isEmpty
            || message.meta.xhs != nil
            || message.meta.timer != nil
            || message.meta.ask != nil
            || message.meta.peek != nil
            || !message.meta.album.isEmpty
    }

    @ViewBuilder
    private func photoBlock(_ photos: [Attachment]) -> some View {
        if photos.count > 1 {
            PhotoStackAttachmentView(
                attachments: photos,
                request: attachmentRequest,
                palette: palette
            )
        } else if let image = photos.first {
            AttachmentView(
                attachment: image,
                request: attachmentRequest(image),
                palette: palette
            )
        }
    }

    private var myReaction: String? {
        message.meta.reactions["human"]
    }

    private var shouldShowMetaLine: Bool {
        if apiUsageText != nil { return true }
        if showsTimestamp || message.meta.edited { return true }
        guard message.author == .human else { return false }
        switch message.delivery {
        case .sending, .failed: return true
        case .sent: return false
        }
    }

    @ViewBuilder
    private var messageActions: some View {
        if !message.text.isEmpty {
            Button(action: onCopy) { Label("复制", systemImage: "doc.on.doc") }
        }
        if message.id > 0 {
            if message.author == .ai {
                Menu {
                    ForEach(["❤️", "😘", "😂", "🥺", "🔥", "👀"], id: \.self) { emoji in
                        Button(emoji) { onReact(emoji) }
                    }
                    if myReaction != nil {
                        Divider()
                        Button("收回回应", role: .destructive) { onReact("") }
                    }
                } label: {
                    Label("表情回应", systemImage: "face.smiling")
                }
            }
            Button(action: onToggleStar) {
                Label(message.meta.starred == nil ? "收藏" : "取消收藏",
                      systemImage: message.meta.starred == nil ? "star" : "star.slash")
            }
        }
        if message.author == .ai && !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Button(action: onSpeak) { Label("朗读", systemImage: "speaker.wave.2") }
        }
        if message.id > 0 && message.author == .human && (message.kind == "user" || message.kind == "voice") {
            Button(action: onEdit) { Label("编辑", systemImage: "pencil") }
        }
        if message.id > 0 && message.author == .ai && message.kind == "reply" {
            Button(action: onRegenerate) { Label("重新生成", systemImage: "arrow.clockwise") }
        }
        Button(role: .destructive, action: onHide) {
            Label("在本机隐藏", systemImage: "eye.slash")
        }
    }

    private static func formatTime(_ raw: String) -> String {
        EchoDateCache.bubbleTimeLabel(raw)
    }
}

struct MarkdownMessageText: View {
    let source: String
    let palette: EchoPalette
    let textColor: Color
    let chatFont: EchoChatFont
    let fontScale: Double
    let chatWeight: Double

    var body: some View {
        Text(attributedText)
            .lineSpacing(PWAChatMetrics.lineSpacing(
                font: chatFont,
                size: PWAChatMetrics.bubbleFontSize(for: chatFont) * fontScale
            ))
            .textSelection(.enabled)
    }

    private var attributedText: AttributedString {
        // Parsing Markdown and walking its runs is the single most expensive
        // thing a bubble does, and SwiftUI re-evaluates this body on any
        // ancestor change. Memoise per (text, styling) so scrolling back over
        // an already-seen bubble costs a dictionary lookup.
        let key = MarkdownStyleKey(
            source: source,
            chatFont: chatFont,
            fontScale: fontScale,
            chatWeight: chatWeight,
            textColor: textColor,
            codeBackground: palette.composer
        )
        if let cached = MarkdownRenderCache.shared.value(for: key) { return cached }
        let rendered = renderAttributedText()
        MarkdownRenderCache.shared.store(rendered, for: key)
        return rendered
    }

    private func renderAttributedText() -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            // SwiftUI Text does not lay out Markdown block presentation intents;
            // `.full` therefore collapsed the overflow paragraphs in short-chat's
            // fifth bubble. Preserve whitespace while still parsing inline markup.
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        var value = (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
        let size = PWAChatMetrics.bubbleFontSize(for: chatFont) * fontScale
        value.font = chatFont.font(size: size, numericWeight: chatWeight)
        value.foregroundColor = textColor

        let runs = value.runs.map { ($0.range, $0.inlinePresentationIntent) }
        for (range, intent) in runs {
            guard let intent else { continue }
            var font = chatFont.font(
                size: size,
                numericWeight: intent.contains(.stronglyEmphasized) ? 700 : chatWeight
            )
            if intent.contains(.emphasized) { font = font.italic() }
            if intent.contains(.code) {
                font = .system(size: CGFloat(size * 0.92), weight: .regular, design: .monospaced)
                value[range].backgroundColor = palette.composer.opacity(0.72)
            }
            value[range].font = font
            if intent.contains(.strikethrough) {
                value[range].strikethroughStyle = .single
            }
        }
        return value
    }
}

private struct MessageAlbumChip: View {
    let entries: [MessageAlbumEntry]
    let palette: EchoPalette

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(palette.accent)
                .frame(width: 30, height: 30)
                .background(palette.accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(entries.count > 1 ? "收进相册 · \(entries.count) 张" : "收进相册")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(palette.accent)
                Text(displayTitle)
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: "checkmark")
                .font(.caption2.weight(.bold))
                .foregroundStyle(palette.secondaryText.opacity(0.72))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(palette.composer.opacity(0.72), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(palette.hairline, lineWidth: 0.6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entries.count > 1 ? "已收进相册 \(entries.count) 张照片" : "已收进相册，\(displayTitle)")
    }

    private var displayTitle: String {
        let title = entries.first?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? (entries.count > 1 ? "这些照片" : "这张照片") : title
    }
}

/// 小红书预览卡：她丢来一条链接，relay 把那篇笔记读回来了（backend/xhs.py）。
/// 抓的那两三秒里先立一张骨架，抓完原地换成真卡；点一下去小红书看原文。
/// 笔记配图挂在卡上（MessageRow 已把它们从普通附件里摘掉），不再单独铺一排。
private struct XHSNoteCard: View {
    let card: XHSCard
    let palette: EchoPalette
    let fontScale: Double
    let request: (Attachment) -> URLRequest?

    @Environment(\.openURL) private var openURL
    @State private var pulse = false

    private let cardWidth: CGFloat = 252
    private let radius: CGFloat = 15
    private var coverHeight: CGFloat { cardWidth * 0.625 }
    private var brand: Color { Color(hex: 0xFF3C5A) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cover
            VStack(alignment: .leading, spacing: 5) {
                if card.isLoading {
                    skeletonLine(width: cardWidth - 22)
                    skeletonLine(width: (cardWidth - 22) * 0.58)
                } else {
                    Text(displayTitle)
                        .font(.system(size: CGFloat(13.5 * fontScale), weight: .semibold))
                        .foregroundStyle(palette.text)
                        .lineLimit(2)
                    if let desc = displayDesc {
                        Text(desc)
                            .font(.system(size: CGFloat(12 * fontScale)))
                            .foregroundStyle(palette.secondaryText)
                            .lineLimit(3)
                    }
                }
                footer
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 11)
            .padding(.top, 9)
            .padding(.bottom, 10)
        }
        .frame(width: cardWidth)
        .background(palette.composer.opacity(0.72), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(brand.opacity(0.24), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .onTapGesture {
            if let link = card.link { openURL(link) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(card.isLoading ? "正在读取小红书笔记" : "小红书笔记：\(displayTitle)")
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder private var cover: some View {
        if card.isLoading {
            Rectangle()
                .fill(palette.hairline.opacity(0.55))
                .frame(width: cardWidth, height: coverHeight)
                .opacity(pulse ? 0.5 : 1)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
                }
        } else if let first = card.images.first {
            ZStack(alignment: .bottomTrailing) {
                AuthenticatedImageView(
                    request: request(Attachment(url: first, name: "小红书配图", kind: "image")),
                    palette: palette,
                    contentMode: .fill,
                    allowsPreview: false   // 点卡片是去看原文，别被图片预览截胡
                )
                .frame(width: cardWidth, height: coverHeight)
                .clipped()
                if totalImages > 1 {
                    Text("🖼 \(totalImages)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.45), in: Capsule())
                        .padding(8)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text("小红书")
                .font(.system(size: CGFloat(11 * fontScale), weight: .semibold))
                .foregroundStyle(brand)
            if card.isLoading {
                Text("正在读这篇笔记…")
                    .font(.system(size: CGFloat(11 * fontScale)))
                    .foregroundStyle(palette.secondaryText)
            } else if !card.isReady {
                Text("点开看原文")
                    .font(.system(size: CGFloat(11 * fontScale)))
                    .foregroundStyle(palette.secondaryText)
            } else {
                if let who = trimmed(card.author) {
                    Text(who)
                        .font(.system(size: CGFloat(11 * fontScale)))
                        .foregroundStyle(palette.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let stats = statsLine {
                    Text(stats)
                        .font(.system(size: CGFloat(11 * fontScale)))
                        .foregroundStyle(palette.secondaryText.opacity(0.85))
                        .fixedSize()
                }
            }
        }
        .padding(.top, 3)
    }

    private func skeletonLine(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(palette.hairline.opacity(0.55))
            .frame(width: width, height: 11)
            .opacity(pulse ? 0.5 : 1)
    }

    private var totalImages: Int { max(card.imageCount ?? card.images.count, card.images.count) }

    private var displayTitle: String {
        guard card.isReady else { return "这篇笔记没读到" }
        return trimmed(card.title) ?? "无标题笔记"
    }

    private var displayDesc: String? {
        guard card.isReady else { return nil }
        return trimmed(card.desc)
    }

    private var statsLine: String? {
        var parts: [String] = []
        if let liked = card.liked, liked > 0 { parts.append("♡ " + compact(liked)) }
        if let commented = card.commented, commented > 0 { parts.append("💬 " + compact(commented)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func trimmed(_ value: String?) -> String? {
        let text = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func compact(_ n: Int) -> String {
        guard n >= 10000 else { return "\(n)" }
        let value = Double(n) / 10000
        let text = n >= 100000 ? String(format: "%.0f", value) : String(format: "%.1f", value)
        return text.replacingOccurrences(of: ".0", with: "") + "万"
    }
}

private struct MessageAskChip: View {
    let ask: MessageAsk
    let palette: EchoPalette
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 9) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(palette.accent)
                Text(chipText)
                    .font(.system(size: 13.5, weight: .regular))
                    .foregroundStyle(ask.answer == nil ? palette.text : palette.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(ask.answer == nil ? "回答" : "看看")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ask.answer == nil ? palette.accent : palette.secondaryText)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 40)
            .background(palette.composer.opacity(0.76), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(palette.hairline, lineWidth: 0.6)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(ask.answer == nil ? "回答问题：\(ask.question)" : "查看已回答的问题：\(ask.question)")
    }

    private var chipText: String {
        if let answer = ask.answer { return "你答：\(answer.text)" }
        return ask.question
    }
}

/// 「给你看一眼」：我发起的屏幕共享请求，她按了确认才会有系统面板。
/// 画面不会变成她的气泡——回来的那张图夹在我随后那条消息里。
private struct MessagePeekCard: View {
    let peek: MessagePeek
    let palette: EchoPalette
    let needsManualPicker: Bool
    let onAccept: () async -> Void
    let onDecline: () async -> Void
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(peek.isOpen ? palette.text : palette.secondaryText)
                    if !peek.note.isEmpty && peek.status != "delivered" {
                        Text(peek.note)
                            .font(.system(size: 12))
                            .foregroundStyle(palette.secondaryText)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                if busy { ProgressView().controlSize(.small) }
            }

            if peek.status == "pending" {
                HStack(spacing: 8) {
                    Button {
                        run(onAccept)
                    } label: {
                        Text("给你看")
                            .foregroundStyle(palette.onAccent)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(palette.accent)

                    Button {
                        run(onDecline)
                    } label: {
                        Text("现在不行")
                            .foregroundStyle(palette.text)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(palette.secondaryText)
                }
                .font(.system(size: 13, weight: .semibold))
                .disabled(busy)
            } else if peek.status == "accepted" && needsManualPicker {
                HStack(spacing: 10) {
                    Text("点这颗按钮，再选 Tidal Echo")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.secondaryText)
                    Spacer(minLength: 4)
                    BroadcastPickerButton()
                        .frame(width: 42, height: 42)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel("打开系统屏幕共享")
                }
            }
        }
        .padding(11)
        .background(
            palette.composer.opacity(0.76),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(palette.hairline, lineWidth: 0.6)
        )
        .onChange(of: peek.status) { _, _ in busy = false }
    }

    private func run(_ action: @escaping () async -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            await action()
            busy = false
        }
    }

    private var icon: String {
        switch peek.status {
        case "accepted": return "record.circle"
        case "delivered": return "checkmark.circle.fill"
        case "declined": return "hand.raised.fill"
        case "expired": return "clock.badge.xmark"
        default: return "eye"
        }
    }

    private var tint: Color {
        switch peek.status {
        case "delivered": return .green
        case "declined", "expired": return palette.secondaryText
        default: return palette.accent
        }
    }

    private var title: String {
        switch peek.status {
        case "accepted":
            return needsManualPicker ? "还差一下：开系统广播" : "在系统面板上点「开始直播」"
        case "delivered": return "他看到了"
        case "declined": return "你说了现在不行"
        case "expired":
            return peek.reason == "frame_never_arrived" ? "画面没送到" : "这张卡过期了"
        default: return "他想看一眼你的屏幕"
        }
    }
}

private struct SendingClock: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotation = 0.0

    var body: some View {
        Image(systemName: "clock")
            .rotationEffect(.degrees(rotation))
            .onAppear {
                guard !reduceMotion else { return }
                rotation = 360
            }
            .animation(
                reduceMotion ? nil : .linear(duration: 1.15).repeatForever(autoreverses: false),
                value: rotation
            )
            .accessibilityLabel("发送中")
    }
}

/// CSS-like independent corner radii. PWA gives the last bubble in a same-author
/// five-minute group a 5px corner toward the avatar; the other corners use the
/// user-selected radius (14px by default on iPhone).
struct PWAChatBubbleShape: Shape {
    let radius: CGFloat
    let bottomLeftRadius: CGFloat
    let bottomRightRadius: CGFloat
    var inflation: CGFloat = 0

    /// The slider is gone; she settled on 3% for the default classic bubble.
    static let defaultInflation: CGFloat = 0.03

    static func inflationPadding(_ inflation: CGFloat) -> CGFloat {
        inflation.isFinite ? 12 * min(max(inflation, 0), 1) : 0
    }

    func path(in rect: CGRect) -> Path {
        if inflation > 0 { return inflatedPath(in: rect) }
        let limit = min(rect.width, rect.height) / 2
        let topLeft = min(max(0, radius), limit)
        let topRight = topLeft
        let bottomRight = min(max(0, bottomRightRadius), limit)
        let bottomLeft = min(max(0, bottomLeftRadius), limit)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + topLeft, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - topRight, y: rect.minY))
        path.addArc(
            center: CGPoint(x: rect.maxX - topRight, y: rect.minY + topRight),
            radius: topRight,
            startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRight))
        path.addArc(
            center: CGPoint(x: rect.maxX - bottomRight, y: rect.maxY - bottomRight),
            radius: bottomRight,
            startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY - bottomLeft),
            radius: bottomLeft,
            startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topLeft))
        path.addArc(
            center: CGPoint(x: rect.minX + topLeft, y: rect.minY + topLeft),
            radius: topLeft,
            startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false
        )
        path.closeSubpath()
        return path
    }

    private func inflatedPath(in bounds: CGRect) -> Path {
        // Reserve the bow in layout, keeping the original text rectangle inside
        // the silhouette. Limit curvature on tiny bubbles and large radii.
        let padding = min(Self.inflationPadding(inflation), max(0, bounds.height / 2 - 1))
        let rect = bounds.insetBy(dx: 0, dy: padding)
        let limit = max(0, min(rect.width, rect.height) / 2)
        let r = min(max(0, radius), limit)
        let bl = min(max(0, bottomLeftRadius), limit)
        let br = min(max(0, bottomRightRadius), limit)
        let topSpan = max(0, rect.width - 2 * r)
        let bottomSpan = max(0, rect.width - bl - br)
        let bow = min(padding, min(topSpan, bottomSpan) * 0.2)
        let topSlope = topSpan > 0 ? 4 * bow / topSpan : 0
        let bottomSlope = bottomSpan > 0 ? 4 * bow / bottomSpan : 0
        let k: CGFloat = 0.5522847498
        let x0 = rect.minX, x1 = rect.maxX
        let y0 = rect.minY, y1 = rect.maxY
        var path = Path()
        path.move(to: CGPoint(x: x0 + r, y: y0))
        path.addCurve(
            to: CGPoint(x: x1 - r, y: y0),
            control1: CGPoint(x: x0 + r + topSpan / 3, y: y0 - 4 * bow / 3),
            control2: CGPoint(x: x1 - r - topSpan / 3, y: y0 - 4 * bow / 3)
        )
        // Corner tangents follow the bowed edges, avoiding a kink at each join.
        path.addCurve(
            to: CGPoint(x: x1, y: y0 + r),
            control1: CGPoint(x: x1 - r + k * r, y: y0 + k * r * topSlope),
            control2: CGPoint(x: x1, y: y0 + r - k * r)
        )
        path.addLine(to: CGPoint(x: x1, y: y1 - br))
        path.addCurve(
            to: CGPoint(x: x1 - br, y: y1),
            control1: CGPoint(x: x1, y: y1 - br + k * br),
            control2: CGPoint(x: x1 - br + k * br, y: y1 - k * br * bottomSlope)
        )
        path.addCurve(
            to: CGPoint(x: x0 + bl, y: y1),
            control1: CGPoint(x: x1 - br - bottomSpan / 3, y: y1 + 4 * bow / 3),
            control2: CGPoint(x: x0 + bl + bottomSpan / 3, y: y1 + 4 * bow / 3)
        )
        path.addCurve(
            to: CGPoint(x: x0, y: y1 - bl),
            control1: CGPoint(x: x0 + bl - k * bl, y: y1 - k * bl * bottomSlope),
            control2: CGPoint(x: x0, y: y1 - bl + k * bl)
        )
        path.addLine(to: CGPoint(x: x0, y: y0 + r))
        path.addCurve(
            to: CGPoint(x: x0 + r, y: y0),
            control1: CGPoint(x: x0, y: y0 + r - k * r),
            control2: CGPoint(x: x0 + r - k * r, y: y0 + k * r * topSlope)
        )
        path.closeSubpath()
        return path
    }
}

/// Material and silhouette are separate settings: classic/frosted bubbles can
/// opt into Telegram-like grouping while liquid glass keeps its rounded shape.
private struct EchoMessageBubbleShape: Shape {
    let style: EchoBubbleShapeStyle
    let author: MessageAuthor
    let radius: CGFloat
    let isGroupStart: Bool
    let inflation: CGFloat
    let isTail: Bool

    func path(in rect: CGRect) -> Path {
        switch style {
        case .telegram:
            return TelegramBubbleShape(
                author: author,
                radius: radius,
                isGroupStart: isGroupStart,
                isTail: isTail
            ).path(in: rect)
        case .upperTail:
            return UpperCornerBubbleShape(
                author: author,
                radius: radius
            ).path(in: rect)
        case .standard:
            return PWAChatBubbleShape(
                radius: radius,
                bottomLeftRadius: author == .ai && isTail ? 5 : radius,
                bottomRightRadius: author == .human && isTail ? 5 : radius,
                inflation: inflation
            ).path(in: rect)
        case .jelly, .neat:
            guard let spec = style.smoothSpec else { return Path(rect) }
            return SmoothCornerBubbleShape(radius: spec.radius, smoothing: spec.smoothing).path(in: rect)
        }
    }
}

/// Four equal corners with Figma-style corner smoothing: each circular arc is
/// eased into its edges by a cubic, so curvature ramps up instead of jumping.
/// The two sides of a corner are smoothed independently. When one edge is too
/// short (a one-line bubble's height), only that side gives up smoothing; the
/// radius itself never shrinks, so high smoothing doesn't turn the bubble boxy.
struct SmoothCornerBubbleShape: Shape {
    let radius: CGFloat
    let smoothing: CGFloat

    private struct Half {
        let extent: CGFloat
        let angle: CGFloat
        let p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint
    }

    private struct Corner {
        let radius: CGFloat
        let entry: Half
        let exit: Half
    }

    // Local frame of the top-right corner, entering along the top edge:
    // u <= 0 runs toward the corner, v grows downward, arc centre at (-R, R).
    private static func half(radius r: CGFloat, smoothing s: CGFloat) -> Half {
        let angle = CGFloat.pi / 4 * s
        let extent = (1 + s) * r
        let arcStart = CGPoint(x: -r + r * sin(angle), y: r - r * cos(angle))
        let c = r * tan(angle / 2) * cos(angle)
        let b = max(0, (arcStart.x + extent - c) / 3)
        return Half(
            extent: extent,
            angle: angle,
            p0: CGPoint(x: -extent, y: 0),
            p1: CGPoint(x: -extent + 2 * b, y: 0),
            p2: CGPoint(x: -extent + 3 * b, y: 0),
            p3: arcStart
        )
    }

    private func corner(entryRoom: CGFloat, exitRoom: CGFloat) -> Corner? {
        let r = min(max(0, radius), entryRoom, exitRoom)
        guard r > 0.01 else { return nil }
        let s = min(max(0, smoothing), 1)
        return Corner(
            radius: r,
            entry: Self.half(radius: r, smoothing: min(s, max(0, entryRoom / r - 1))),
            exit: Self.half(radius: r, smoothing: min(s, max(0, exitRoom / r - 1)))
        )
    }

    /// Draws one corner, already reached at its entry point, through `map`
    /// (a rotation/reflection taking the local frame to the real corner).
    private func draw(_ c: Corner, into path: inout Path, map: (CGPoint) -> CGPoint) {
        let r = c.radius
        path.addCurve(to: map(c.entry.p3), control1: map(c.entry.p1), control2: map(c.entry.p2))

        // Circular arc from -90°+entry to -exit, as a single cubic (span <= 90°).
        let a0 = -CGFloat.pi / 2 + c.entry.angle
        let a1 = -c.exit.angle
        if a1 - a0 > 0.0001 {
            let k = 4 / 3 * tan((a1 - a0) / 4) * r
            let start = CGPoint(x: -r + r * cos(a0), y: r + r * sin(a0))
            let end = CGPoint(x: -r + r * cos(a1), y: r + r * sin(a1))
            path.addCurve(
                to: map(end),
                control1: map(CGPoint(x: start.x - k * sin(a0), y: start.y + k * cos(a0))),
                control2: map(CGPoint(x: end.x + k * sin(a1), y: end.y - k * cos(a1)))
            )
        }

        // The exit half is the entry construction mirrored across the diagonal,
        // (u, v) -> (-v, -u), and walked backwards.
        path.addCurve(
            to: map(CGPoint(x: -c.exit.p0.y, y: -c.exit.p0.x)),
            control1: map(CGPoint(x: -c.exit.p2.y, y: -c.exit.p2.x)),
            control2: map(CGPoint(x: -c.exit.p1.y, y: -c.exit.p1.x))
        )
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let x0 = rect.minX, y0 = rect.minY
        let topRight = corner(entryRoom: w / 2, exitRoom: h / 2)
        let bottomRight = corner(entryRoom: h / 2, exitRoom: w / 2)
        let bottomLeft = corner(entryRoom: w / 2, exitRoom: h / 2)
        let topLeft = corner(entryRoom: h / 2, exitRoom: w / 2)
        let entry = { (c: Corner?) in c?.entry.extent ?? 0 }
        let exit = { (c: Corner?) in c?.exit.extent ?? 0 }

        var path = Path()
        path.move(to: CGPoint(x: x0 + exit(topLeft), y: y0))
        path.addLine(to: CGPoint(x: x0 + w - entry(topRight), y: y0))
        if let topRight {
            draw(topRight, into: &path) { CGPoint(x: x0 + w + $0.x, y: y0 + $0.y) }
        }
        path.addLine(to: CGPoint(x: x0 + w, y: y0 + h - entry(bottomRight)))
        if let bottomRight {
            draw(bottomRight, into: &path) { CGPoint(x: x0 + w - $0.y, y: y0 + h + $0.x) }
        }
        path.addLine(to: CGPoint(x: x0 + entry(bottomLeft), y: y0 + h))
        if let bottomLeft {
            draw(bottomLeft, into: &path) { CGPoint(x: x0 - $0.x, y: y0 + h - $0.y) }
        }
        path.addLine(to: CGPoint(x: x0, y: y0 + entry(topLeft)))
        if let topLeft {
            draw(topLeft, into: &path) { CGPoint(x: x0 + $0.y, y: y0 - $0.x) }
        }
        path.closeSubpath()
        return path
    }
}

/// A flush, nearly-square top corner inspired by the supplied reference.
/// Incoming bubbles pin the upper-left corner and outgoing bubbles mirror it
/// at upper-right. Every bubble keeps the softened pin for a consistent rhythm.
private struct UpperCornerBubbleShape: Shape {
    let author: MessageAuthor
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let limit = min(rect.width, rect.height) / 2
        let full = min(max(0, radius), limit)
        let pinned = min(CGFloat(6), full)
        let topLeft = author == .ai ? pinned : full
        let topRight = author == .human ? pinned : full

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + topLeft, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - topRight, y: rect.minY))
        path.addArc(
            center: CGPoint(x: rect.maxX - topRight, y: rect.minY + topRight),
            radius: topRight,
            startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - full))
        path.addArc(
            center: CGPoint(x: rect.maxX - full, y: rect.maxY - full),
            radius: full,
            startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX + full, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.minX + full, y: rect.maxY - full),
            radius: full,
            startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topLeft))
        path.addArc(
            center: CGPoint(x: rect.minX + topLeft, y: rect.minY + topLeft),
            radius: topLeft,
            startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

private struct TelegramBubbleShape: Shape {
    let author: MessageAuthor
    let radius: CGFloat
    let isGroupStart: Bool
    let isTail: Bool

    func path(in rect: CGRect) -> Path {
        // Keep the rounded body on the same alignment line for every row.
        // The tail grows outward instead of reserving space inside the bubble.
        // Both sides share one tail: short, level with the baseline, resolving
        // into a clean cusp. The outgoing side is an exact mirror of it, so the
        // two columns read as the same bubble facing opposite directions.
        let tailWidth: CGFloat = 7
        let tailShoulder: CGFloat = 9
        let body = rect
        let limit = min(body.width, body.height) / 2
        let full = min(max(0, radius), limit)
        let joined = min(max(CGFloat(7), full * 0.42), min(CGFloat(10), limit))
        let topLeft = author == .ai ? (isGroupStart ? full : joined) : full
        let topRight = author == .human ? (isGroupStart ? full : joined) : full
        let bottomLeft = author == .ai ? joined : full
        let bottomRight = author == .human ? joined : full

        var path = Path()
        path.move(to: CGPoint(x: body.minX + topLeft, y: body.minY))
        path.addLine(to: CGPoint(x: body.maxX - topRight, y: body.minY))
        path.addArc(
            center: CGPoint(x: body.maxX - topRight, y: body.minY + topRight),
            radius: topRight,
            startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false
        )

        if author == .human && isTail {
            // Mirror of the incoming tail below, traversed in reverse: this
            // edge runs down the right side into the baseline, the other runs
            // along the baseline out to the left, so the control points swap
            // order as well as sign.
            path.addLine(to: CGPoint(x: body.maxX, y: body.maxY - tailShoulder))
            path.addCurve(
                to: CGPoint(x: rect.maxX + tailWidth, y: rect.maxY - 0.5),
                control1: CGPoint(x: body.maxX, y: body.maxY - 5.5),
                control2: CGPoint(x: rect.maxX + 4, y: rect.maxY - 0.75)
            )
            path.addCurve(
                to: CGPoint(x: body.maxX - tailShoulder, y: body.maxY),
                control1: CGPoint(x: rect.maxX + 1.5, y: rect.maxY - 2.25),
                control2: CGPoint(x: body.maxX - 5, y: body.maxY)
            )
        } else {
            path.addLine(to: CGPoint(x: body.maxX, y: body.maxY - bottomRight))
            path.addArc(
                center: CGPoint(x: body.maxX - bottomRight, y: body.maxY - bottomRight),
                radius: bottomRight,
                startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false
            )
        }

        if author == .ai && isTail {
            // Keep the incoming tail short and level with the baseline. The
            // first control point preserves the bottom edge's horizontal
            // tangent; the shallow inset then resolves into a clean cusp.
            path.addLine(to: CGPoint(x: body.minX + tailShoulder, y: body.maxY))
            path.addCurve(
                to: CGPoint(x: rect.minX - tailWidth, y: rect.maxY - 0.5),
                control1: CGPoint(x: body.minX + 5, y: body.maxY),
                control2: CGPoint(x: rect.minX - 1.5, y: rect.maxY - 2.25)
            )
            path.addCurve(
                to: CGPoint(x: body.minX, y: body.maxY - tailShoulder),
                control1: CGPoint(x: rect.minX - 4, y: rect.maxY - 0.75),
                control2: CGPoint(x: body.minX, y: body.maxY - 5.5)
            )
        } else {
            path.addLine(to: CGPoint(x: body.minX + bottomLeft, y: body.maxY))
            path.addArc(
                center: CGPoint(x: body.minX + bottomLeft, y: body.maxY - bottomLeft),
                radius: bottomLeft,
                startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false
            )
        }

        path.addLine(to: CGPoint(x: body.minX, y: body.minY + topLeft))
        path.addArc(
            center: CGPoint(x: body.minX + topLeft, y: body.minY + topLeft),
            radius: topLeft,
            startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false
        )
        path.closeSubpath()
        return path
    }
}

private struct MessageTimerCard: View {
    let timer: MessageTimer
    let palette: EchoPalette
    let onDone: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = secondsRemaining(at: context.date)
            HStack(spacing: 10) {
                Image(systemName: timer.status == "done" ? "checkmark.circle.fill" : "timer")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(timer.status == "done" ? Color.green : palette.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(timer.label)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                    if timer.status == "running" && remaining > 0 {
                        Text(Self.durationText(remaining))
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(palette.accent)
                    } else if timer.status == "done" {
                        Text("✓ 搞定").font(.caption).foregroundStyle(Color.green)
                    } else {
                        Text("时间到").font(.caption).foregroundStyle(Color.red.opacity(0.82))
                    }
                }
                Spacer(minLength: 8)
                if timer.status == "running" && remaining > 0 {
                    Button(action: onDone) {
                        Text("搞定了").foregroundStyle(palette.onAccent)
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .tint(palette.accent)
                }
            }
            .padding(11)
            .background(palette.composer.opacity(0.62), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(palette.hairline))
        }
    }

    private func secondsRemaining(at date: Date) -> Int {
        guard let end = Self.parseDate(timer.endsAt) else { return 0 }
        return max(0, Int(end.timeIntervalSince(date).rounded()))
    }

    private static func parseDate(_ raw: String) -> Date? {
        EchoDateCache.date(from: raw)
    }

    private static func durationText(_ total: Int) -> String {
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }
}

private struct ProcessRow: View {
    let message: ChatMessage
    let palette: EchoPalette
    let chatFont: EchoChatFont
    let fontScale: Double
    let chatWeight: Double
    let isPaper: Bool
    let isMist: Bool
    let isNest: Bool
    let showsAIAvatar: Bool
    let aiAvatarImage: UIImage?
    let bubbleWidthScale: Double
    let usesUpperTailAvatarLayout: Bool
    let showsAvatarHeader: Bool
    let onTranslate: () async throws -> String
    @State private var expanded = false
    @State private var showingProcessSheet = false
    @State private var showingTranslation = false
    @State private var loadedTranslation: String?
    @State private var isTranslating = false
    @State private var translationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                guard canExpand else { return }
                if usesSystemSheet {
                    showingProcessSheet = true
                } else {
                    withAnimation(isHarbor ? .spring(response: 0.34, dampingFraction: 0.86) : .easeOut(duration: 0.16)) {
                        expanded.toggle()
                    }
                }
            } label: {
                if isThinking && usesUpperTailAvatarLayout {
                    upperTailThinkingTrigger
                } else if isNest {
                    nestTrigger
                } else if isMist {
                    mistTrigger
                } else if isHarbor {
                    harborTrigger
                } else {
                    legacyTrigger
                }
            }
            .buttonStyle(.plain)

            recallHint

            if expanded && !usesSystemSheet {
                if isHarbor {
                    harborProcessCard
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    processDetail
                        .transition(.opacity)
                }
            }
        }
        .frame(maxWidth: CGFloat(280 * bubbleWidthScale), alignment: .leading)
        .padding(.leading, showsAIAvatar && !usesUpperTailAvatarLayout ? 35 : 0)
        .padding(.trailing, 44)
        .sheet(isPresented: $showingProcessSheet) {
            processSheet
        }
        .alert("翻译没有成功", isPresented: Binding(
            get: { translationError != nil },
            set: { if !$0 { translationError = nil } }
        )) {
            Button("好", role: .cancel) { translationError = nil }
        } message: {
            Text(translationError ?? "请稍后再试")
        }
    }

    private var isThinking: Bool { message.kind == "thinking" }
    private var canExpand: Bool { isThinking ? !message.text.isEmpty : !message.meta.steps.isEmpty }

    /// 「这轮我想起了东西」——浮现本身是隐形的（旧记忆只垫在他眼前），
    /// 这一行是她唯一能看见的痕迹。收起状态也在，不用展开才看得到。
    @ViewBuilder
    private var recallHint: some View {
        if isThinking, let count = message.meta.recalled, count > 0 {
            Text("✧ 浮现 \(count) 条旧记忆")
                .font(chatFont.font(size: 11 * fontScale, weight: .regular))
                .foregroundStyle(palette.secondaryText.opacity(0.7))
                .padding(.top, -3)
        }
    }
    private var usesSystemSheet: Bool { isMist || isNest }
    private var isHarbor: Bool { !isPaper && !isMist && !isNest }
    private var translatedThinking: String? {
        let text = loadedTranslation ?? message.meta.translations["zh-Hans"]
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
    private var displayedThinking: String {
        showingTranslation ? (translatedThinking ?? message.text) : message.text
    }
    private var offersTranslation: Bool {
        guard isThinking, message.id > 0 else { return false }
        if translatedThinking != nil { return true }
        var latinLetters = 0
        var hanCharacters = 0
        for scalar in message.text.unicodeScalars {
            switch scalar.value {
            case 0x41...0x5A, 0x61...0x7A:
                latinLetters += 1
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF:
                hanCharacters += 1
            default:
                break
            }
        }
        return (hanCharacters == 0 && latinLetters >= 4)
            || (latinLetters >= 16 && latinLetters > max(8, hanCharacters * 2))
    }
    private var processFontSize: Double {
        PWAChatMetrics.thinkingFontSize(for: chatFont) * fontScale * processFontMultiplier
    }

    private var processFontMultiplier: Double {
        if isNest { return 1.24 }
        return isMist ? 1.16 : 1
    }

    /// Nest reads the sheet as a document, not as an aside: full ink, no wash.
    private var sheetTextColor: Color {
        isNest ? palette.text : palette.text.opacity(0.84)
    }

    private var upperTailThinkingTrigger: some View {
        HStack(spacing: 9) {
            if showsAvatarHeader {
                AvatarBadge(
                    image: aiAvatarImage,
                    fallback: "sparkle",
                    palette: palette,
                    size: 36,
                    showsShadow: true
                )
            }
            if isMist {
                upperTailThinkingDisclosure
                    .offset(y: 2)
            }
            Text(upperTailThinkingTitle)
                .lineLimit(1)
                .offset(y: 2)
            if !isMist {
                upperTailThinkingDisclosure
                    .offset(y: 2)
            }
        }
        .font(chatFont.font(
            size: (isNest ? 13 : 12.5) * fontScale,
            weight: isNest ? .regular : .medium
        ))
        .foregroundStyle(palette.secondaryText)
        .padding(.vertical, 2)
    }

    private var upperTailThinkingTitle: String {
        if isNest { return nestThinkingTitle }
        return isPaper ? "THINKING" : "Thinking"
    }

    @ViewBuilder
    private var upperTailThinkingDisclosure: some View {
        if isPaper {
            Image(systemName: "play.fill")
                .font(.system(size: 7.5, weight: .bold))
                .rotationEffect(.degrees(expanded ? 90 : 0))
        } else if isHarbor {
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .rotationEffect(.degrees(expanded ? 180 : 0))
        } else {
            Image(systemName: "chevron.right")
                .font(.system(size: isNest ? 10 : 8, weight: .semibold))
        }
    }

    private var mistTrigger: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
            Text(isThinking ? "Thinking" : "Action")
        }
        .font(chatFont.font(size: 12.5 * fontScale, weight: .medium))
        .foregroundStyle(palette.secondaryText)
        .padding(.vertical, 2)
    }

    private var nestTrigger: some View {
        HStack(spacing: 8) {
            if isThinking {
                NestThinkingClock(size: 14)
            } else {
                ClaudeBrandMark(
                    size: 14,
                    motion: .tool,
                    color: palette.secondaryText
                )
            }
            Text(isThinking ? nestThinkingTitle : "查看工具调用")
                .lineLimit(1)
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
        }
        .font(chatFont.font(size: 13 * fontScale, weight: .regular))
        .foregroundStyle(palette.secondaryText)
        .padding(.vertical, 3)
    }

    private var nestThinkingTitle: String {
        let flattened = message.text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "#>*_`- "))
        guard !flattened.isEmpty else { return "思考中…" }

        let sentenceStops = Set<Character>(["。", "！", "？", ".", "!", "?"])
        let firstSentence = flattened.prefix { !sentenceStops.contains($0) }
        let source = firstSentence.isEmpty ? flattened[...] : firstSentence
        let snippet = String(source.prefix(24)).trimmingCharacters(in: .whitespacesAndNewlines)
        return snippet.isEmpty ? "思考中…" : "\(snippet)…"
    }

    private var harborTrigger: some View {
        HStack(spacing: 6) {
            Image(systemName: isThinking ? "heart.fill" : "wrench")
                .font(.system(size: isThinking ? 11.5 : 11, weight: .medium))
            Text(isThinking ? "Thinking" : "Action")
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .rotationEffect(.degrees(expanded ? 180 : 0))
        }
        .font(chatFont.font(size: 12.5 * fontScale, weight: .medium))
        .foregroundStyle(palette.secondaryText)
        .padding(.vertical, 2)
    }

    private var legacyTrigger: some View {
        HStack(spacing: 7) {
            if isThinking {
                Text("THINKING")
                Image(systemName: "play.fill")
                    .font(.system(size: 7.5, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            } else {
                Image(systemName: "wrench")
                    .font(.system(size: 11, weight: .medium))
                Text("Action")
            }
        }
        .font(chatFont.font(size: 12.5 * fontScale, weight: .medium))
        .foregroundStyle(palette.secondaryText)
        .padding(.horizontal, isPaper ? 0 : 11)
        .padding(.vertical, isPaper ? 2 : 4)
        .background {
            if !isPaper {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(Capsule().stroke(palette.hairline, lineWidth: 0.5))
            }
        }
    }

    @ViewBuilder
    private func processContent(textColor: Color) -> some View {
        if isThinking {
            SelectableThinkingText(
                text: displayedThinking,
                font: chatFont.uiFont(size: processFontSize, numericWeight: chatWeight),
                textColor: textColor,
                selectionColor: palette.accent,
                lineSpacing: PWAChatMetrics.lineSpacing(
                    font: chatFont,
                    size: processFontSize
                ),
                inlineActionTitle: thinkingLanguageActionTitle,
                inlineActionEnabled: !isTranslating,
                onInlineAction: {
                    toggleThinkingLanguage()
                }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(message.meta.steps.enumerated()), id: \.offset) { _, step in
                    ToolStepPreview(
                        step: step,
                        palette: palette,
                        chatFont: chatFont,
                        fontSize: processFontSize,
                        chatWeight: chatWeight
                    )
                }
            }
        }
    }

    private var harborProcessCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(isThinking ? "Thought process" : "Action")
                    .font(chatFont.font(size: 12.5 * fontScale, weight: .medium))
                    .foregroundStyle(palette.text.opacity(0.88))
                Spacer(minLength: 12)
                Image(systemName: isThinking ? "heart.fill" : "wrench")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.secondaryText)
            }
            Divider().overlay(palette.hairline)
            processContent(textColor: palette.secondaryText)
                .foregroundStyle(palette.secondaryText)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(palette.hairline, lineWidth: 0.6)
        )
        .shadow(color: Color.black.opacity(0.055), radius: 10, y: 5)
    }

    private var processSheet: some View {
        NavigationStack {
            ScrollView {
                processContent(textColor: sheetTextColor)
                    .foregroundStyle(sheetTextColor)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background((isNest ? palette.backgroundTop : Color.white).ignoresSafeArea())
            .navigationTitle(isThinking ? "Thought process" : "Action")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingProcessSheet = false } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
        .presentationBackground(.regularMaterial)
        .presentationContentInteraction(.scrolls)
    }

    @ViewBuilder
    private var processDetail: some View {
        processContent(textColor: palette.secondaryText)
            .foregroundStyle(palette.secondaryText)
            .italic(isPaper)
            .padding(.leading, isPaper ? 15 : 12)
            .padding(.trailing, isPaper ? 2 : 12)
            .padding(.vertical, isPaper ? 2 : 10)
            .background {
                if !isPaper {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.hairline))
                }
            }
            .overlay(alignment: .leading) {
                if isPaper {
                    Rectangle()
                        .fill(Color(hex: 0xD6D4CE))
                        .frame(width: 1.5)
                }
            }
    }

    private var thinkingLanguageActionTitle: String? {
        guard offersTranslation else { return nil }
        if isTranslating { return "翻译中…" }
        return showingTranslation ? "看原文" : "译为中文"
    }

    private func toggleThinkingLanguage() {
        guard offersTranslation, !isTranslating else { return }
        if translatedThinking != nil {
            withAnimation(.easeInOut(duration: 0.15)) {
                showingTranslation.toggle()
            }
            return
        }
        isTranslating = true
        translationError = nil
        Task {
            defer { isTranslating = false }
            do {
                loadedTranslation = try await onTranslate()
                withAnimation(.easeInOut(duration: 0.15)) {
                    showingTranslation = true
                }
            } catch is CancellationError {
                return
            } catch {
                translationError = error.localizedDescription
            }
        }
    }
}

/// SwiftUI `Text` can collapse to a whole-view Copy/Share menu inside the
/// expandable process card. A non-editable `UITextView` keeps native insertion
/// points and draggable selection handles while sizing like ordinary text.
private struct SelectableThinkingText: UIViewRepresentable {
    let text: String
    let font: UIFont
    let textColor: Color
    let selectionColor: Color
    let lineSpacing: CGFloat
    let inlineActionTitle: String?
    let inlineActionEnabled: Bool
    let onInlineAction: () -> Void

    private static let inlineActionURL = URL(string: "tidalecho://thinking-translation")!

    func makeCoordinator() -> Coordinator {
        Coordinator(onInlineAction: onInlineAction)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.isEditable = false
        textView.isSelectable = true
        textView.isScrollEnabled = false
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainer.lineBreakMode = .byWordWrapping
        textView.linkTextAttributes = [:]
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentHuggingPriority(.required, for: .vertical)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.onInlineAction = onInlineAction
        let attributedText = makeAttributedText()
        if !textView.attributedText.isEqual(to: attributedText) {
            textView.attributedText = attributedText
        }
        textView.tintColor = UIColor(selectionColor)
        textView.accessibilityLabel = [text, inlineActionTitle]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UITextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let fittingSize = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        return CGSize(width: width, height: ceil(fittingSize.height))
    }

    private func makeAttributedText() -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = lineSpacing

        let traits = font.fontDescriptor.symbolicTraits.union(.traitItalic)
        let italicDescriptor = font.fontDescriptor.withSymbolicTraits(traits)
        let renderedFont = italicDescriptor.map { UIFont(descriptor: $0, size: font.pointSize) } ?? font
        var attributes: [NSAttributedString.Key: Any] = [
            .font: renderedFont,
            .foregroundColor: UIColor(textColor),
            .paragraphStyle: paragraphStyle
        ]
        if italicDescriptor == nil {
            attributes[.obliqueness] = 0.14
        }
        var body = text
        if inlineActionTitle != nil {
            while let last = body.last, last.isWhitespace {
                body.removeLast()
            }
        }
        let result = NSMutableAttributedString(string: body, attributes: attributes)
        if let inlineActionTitle {
            result.append(NSAttributedString(string: "\u{00A0}", attributes: attributes))
            result.append(makeInlineAction(title: inlineActionTitle))
        }
        return result
    }

    private func makeInlineAction(title: String) -> NSAttributedString {
        let actionFont = UIFont.systemFont(ofSize: max(10.5, font.pointSize * 0.82), weight: .medium)
        let horizontalPadding: CGFloat = 7
        let height = max(19, ceil(actionFont.lineHeight + 4))
        let textSize = (title as NSString).size(withAttributes: [.font: actionFont])
        let size = CGSize(width: ceil(textSize.width + horizontalPadding * 2), height: height)
        let tint = UIColor(selectionColor)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { _ in
            let rect = CGRect(origin: .zero, size: size)
            tint.withAlphaComponent(inlineActionEnabled ? 0.12 : 0.07).setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: height / 2).fill()
            (title as NSString).draw(
                at: CGPoint(
                    x: horizontalPadding,
                    y: floor((height - textSize.height) / 2)
                ),
                withAttributes: [
                    .font: actionFont,
                    .foregroundColor: inlineActionEnabled ? tint : tint.withAlphaComponent(0.55)
                ]
            )
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(
            x: 0,
            y: (font.capHeight - height) / 2,
            width: size.width,
            height: size.height
        )
        let action = NSMutableAttributedString(attachment: attachment)
        if inlineActionEnabled {
            action.addAttribute(
                .link,
                value: Self.inlineActionURL,
                range: NSRange(location: 0, length: action.length)
            )
        }
        return action
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var onInlineAction: () -> Void

        init(onInlineAction: @escaping () -> Void) {
            self.onInlineAction = onInlineAction
        }

        func textView(
            _ textView: UITextView,
            shouldInteractWith URL: URL,
            in characterRange: NSRange,
            interaction: UITextItemInteraction
        ) -> Bool {
            guard URL == SelectableThinkingText.inlineActionURL else { return true }
            onInlineAction()
            return false
        }
    }
}

private struct ToolStepPreview: View {
    let step: ToolStep
    let palette: EchoPalette
    let chatFont: EchoChatFont
    let fontSize: Double
    let chatWeight: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            previewLine("tool", step.tool, monospaced: false, limit: 1)
            previewLine("cmd", step.cmd, monospaced: true, limit: 5)
            previewLine("result", step.result, monospaced: true, limit: 4)
        }
        .font(chatFont.font(size: fontSize, numericWeight: chatWeight))
    }

    @ViewBuilder
    private func previewLine(_ key: String, _ value: String?, monospaced: Bool, limit: Int) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .top, spacing: 3) {
                Text("\(key):")
                    .foregroundStyle(palette.secondaryText.opacity(0.76))
                Text(value)
                    .font(
                        monospaced
                            ? .system(size: CGFloat(fontSize), design: .monospaced)
                            : chatFont.font(size: fontSize, numericWeight: chatWeight)
                    )
                    .foregroundStyle(palette.text.opacity(0.78))
                    .lineLimit(limit)
                    .textSelection(.enabled)
            }
        }
    }
}

struct StreamingProcessRow: View {
    let title: String
    let text: String
    let palette: EchoPalette
    let isPaper: Bool
    let isMist: Bool
    let isNest: Bool
    let showsAIAvatar: Bool
    let aiAvatarImage: UIImage?
    let usesUpperTailAvatarLayout: Bool
    let showsAvatarHeader: Bool
    let chatFont: EchoChatFont
    let fontScale: Double
    let chatWeight: Double

    var body: some View {
        if usesUpperTailAvatarLayout {
            VStack(alignment: .leading, spacing: 7) {
                if showsAvatarHeader {
                    HStack(spacing: 9) {
                        AvatarBadge(
                            image: aiAvatarImage,
                            fallback: "sparkle",
                            palette: palette,
                            size: 36,
                            showsShadow: true
                        )
                        Text("Thinking…")
                            .font(chatFont.font(size: 12.5 * fontScale, weight: .medium))
                            .offset(y: 2)
                    }
                }
                streamingText
                    .lineLimit(2)
            }
            .foregroundStyle(palette.secondaryText)
            .frame(maxWidth: 280, alignment: .leading)
            .padding(.trailing, 44)
            .transition(.opacity)
        } else if isNest {
            HStack(alignment: .top, spacing: 8) {
                ClaudeBrandMark(size: 15, motion: .thinking, color: palette.secondaryText)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Thinking…")
                        .font(chatFont.font(size: 12.5 * fontScale, weight: .medium))
                    streamingText
                        .lineLimit(2)
                }
            }
            .foregroundStyle(palette.secondaryText)
            .frame(maxWidth: 300, alignment: .leading)
            .padding(.leading, showsAIAvatar ? 35 : 0)
            .padding(.trailing, 28)
            .transition(.opacity)
        } else if isHarbor {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(chatFont.font(size: 12.5 * fontScale, weight: .medium))
                    Spacer(minLength: 12)
                    Image(systemName: "heart.fill")
                        .font(.system(size: 11, weight: .medium))
                }
                Divider().overlay(palette.hairline)
                streamingText
            }
            .foregroundStyle(palette.secondaryText)
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(palette.hairline, lineWidth: 0.6)
            )
            .shadow(color: Color.black.opacity(0.055), radius: 10, y: 5)
            .frame(maxWidth: 280, alignment: .leading)
            .padding(.leading, showsAIAvatar ? 35 : 0)
            .padding(.trailing, 44)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if isMist {
            VStack(alignment: .leading, spacing: 7) {
                Text("Thinking…")
                    .font(chatFont.font(size: 12.5 * fontScale, weight: .medium))
                streamingText
                    .lineLimit(2)
            }
            .foregroundStyle(palette.secondaryText)
            .frame(maxWidth: 280, alignment: .leading)
            .padding(.leading, showsAIAvatar ? 35 : 0)
            .padding(.trailing, 44)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Text("THINKING")
                    Image(systemName: "play.fill")
                        .font(.system(size: 7.5, weight: .bold))
                        .rotationEffect(.degrees(90))
                }
                .font(chatFont.font(size: 12.5 * fontScale, weight: .medium))
                .padding(.horizontal, isPaper ? 0 : 11)
                .padding(.vertical, isPaper ? 2 : 4)
                .background {
                    if !isPaper {
                        Capsule().fill(.ultraThinMaterial)
                            .overlay(Capsule().stroke(palette.hairline, lineWidth: 0.5))
                    }
                }

                streamingText
                    .padding(.leading, isPaper ? 15 : 12)
                    .padding(.trailing, isPaper ? 2 : 12)
                    .padding(.vertical, isPaper ? 2 : 10)
                    .background {
                        if !isPaper {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(.ultraThinMaterial)
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.hairline))
                        }
                    }
                    .overlay(alignment: .leading) {
                        if isPaper {
                            Rectangle().fill(Color(hex: 0xD6D4CE)).frame(width: 1.5)
                        }
                    }
            }
            .foregroundStyle(palette.secondaryText)
            .frame(maxWidth: 280, alignment: .leading)
            .padding(.leading, showsAIAvatar ? 35 : 0)
            .padding(.trailing, 44)
        }
    }

    private var streamingText: some View {
        Text(text)
            .font(chatFont.font(
                size: PWAChatMetrics.thinkingFontSize(for: chatFont) * fontScale * (isMist ? 1.07 : 1),
                numericWeight: chatWeight
            ).italic())
            .lineLimit(4)
            .lineSpacing(PWAChatMetrics.lineSpacing(
                font: chatFont,
                size: PWAChatMetrics.thinkingFontSize(for: chatFont) * fontScale
            ))
            .textSelection(.enabled)
    }

    private var isHarbor: Bool { !isPaper && !isMist && !isNest }
}

struct StreamingReplyRow: View {
    let text: String
    let palette: EchoPalette
    let chatFont: EchoChatFont
    let fontScale: Double
    let showsAIAvatar: Bool
    let aiAvatarImage: UIImage?
    let showsAIBubble: Bool
    let aiBubbleColor: Color
    let aiBubbleTextColor: Color
    let bubbleOpacity: Double
    let bubbleRadius: Double
    let bubbleWidthScale: Double
    let bubbleBorderWidth: Double
    let bubbleStyle: EchoBubbleStyle
    let bubbleShapeStyle: EchoBubbleShapeStyle
    let liquidGlass: LiquidGlassSettings
    let chatWeight: Double
    let isTail: Bool
    let isNest: Bool
    let usesUpperTailAvatarLayout: Bool
    let showsAvatarHeader: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if usesUpperTailAvatarLayout && showsAvatarHeader {
                AvatarBadge(
                    image: aiAvatarImage,
                    fallback: "sparkle",
                    palette: palette,
                    size: 36,
                    showsShadow: true
                )
            }
            HStack(alignment: usesUpperCornerShape ? .top : .bottom, spacing: 8) {
                if showsAIAvatar && !usesUpperTailAvatarLayout {
                    AvatarBadge(image: aiAvatarImage, fallback: "sparkle", palette: palette)
                }
                Text(text)
                    .font(chatFont.font(
                        size: PWAChatMetrics.bubbleFontSize(for: chatFont) * fontScale,
                        numericWeight: chatWeight
                    ))
                    .lineSpacing(PWAChatMetrics.lineSpacing(
                        font: chatFont,
                        size: PWAChatMetrics.bubbleFontSize(for: chatFont) * fontScale
                    ))
                    .foregroundStyle(aiBubbleTextColor)
                    .padding(.horizontal, showsAIBubble ? bubbleHorizontalPadding : (isNest ? 0 : 2))
                    .padding(.vertical, bubbleVerticalPadding)
                    .background {
                        if showsAIBubble {
                            if bubbleStyle == .liquid {
                                LiquidGlassBubbleBackground(
                                    tint: aiBubbleColor,
                                    tintOpacity: bubbleOpacity,
                                    radius: CGFloat(bubbleRadius),
                                    settings: liquidGlass
                                )
                            } else {
                                let shape = streamingBubbleShape
                                if bubbleStyle == .frosted {
                                    FrostedGlassBubbleBackground(
                                        shape: shape,
                                        tint: aiBubbleColor,
                                        tintOpacity: bubbleOpacity
                                    )
                                } else {
                                    shape
                                        .fill(aiBubbleColor.opacity(bubbleOpacity))
                                        .shadow(color: Color.black.opacity(0.045 * bubbleOpacity), radius: 4.5, y: 2)
                                }
                            }
                        }
                    }
                    .overlay {
                        if showsAIBubble && bubbleBorderWidth > 0 {
                            if bubbleStyle == .liquid {
                                RoundedRectangle(cornerRadius: CGFloat(bubbleRadius), style: .continuous)
                                    .stroke(palette.hairline, lineWidth: CGFloat(bubbleBorderWidth))
                            } else {
                                streamingBubbleShape
                                    .stroke(palette.hairline, lineWidth: CGFloat(bubbleBorderWidth))
                            }
                        }
                    }
                    .frame(
                        maxWidth: showsAIBubble ? streamingBubbleMaxWidth : .infinity,
                        alignment: .leading
                    )
                if showsAIBubble { Spacer(minLength: 0) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var streamingBubbleMaxWidth: CGFloat {
        let scale = CGFloat(bubbleWidthScale)
        return scale <= 1 ? 280 * scale : 280 + ((scale - 1) * 140)
    }

    private var streamingBubbleShape: EchoMessageBubbleShape {
        EchoMessageBubbleShape(
            style: bubbleShapeStyle,
            author: .ai,
            radius: CGFloat(bubbleRadius),
            isGroupStart: true,
            inflation: effectiveBubbleInflation,
            isTail: isTail
        )
    }

    private var usesTelegramShape: Bool {
        bubbleShapeStyle == .telegram && (bubbleStyle == .classic || bubbleStyle == .frosted)
    }

    private var usesUpperCornerShape: Bool {
        bubbleShapeStyle == .upperTail && (bubbleStyle == .classic || bubbleStyle == .frosted)
    }

    private var smoothSpec: SmoothBubbleSpec? {
        bubbleStyle == .classic || bubbleStyle == .frosted ? bubbleShapeStyle.smoothSpec : nil
    }

    private var bubbleHorizontalPadding: CGFloat {
        if showsAIBubble, let smoothSpec { return smoothSpec.horizontalPadding }
        if isNest { return 10 }
        return usesTelegramShape ? 10 : 13
    }

    private var bubbleVerticalPadding: CGFloat {
        if showsAIBubble, let smoothSpec { return smoothSpec.verticalPadding }
        let base: CGFloat = isNest ? (showsAIBubble ? 10 : 2) : (usesTelegramShape ? 8 : 9)
        return base + (showsAIBubble ? PWAChatBubbleShape.inflationPadding(effectiveBubbleInflation) : 0)
    }

    private var effectiveBubbleInflation: CGFloat {
        bubbleStyle == .classic && bubbleShapeStyle == .standard ? PWAChatBubbleShape.defaultInflation : 0
    }
}

/// Rebuilt to match Operit's chat bubbles (`ui/theme/LiquidGlass.kt`), whose
/// surface is a bare backdrop — `vibrancy()` then `blur(28.dp)`, no refraction,
/// since the bubbles pass `enableLens = false` — under a light tint wash and a
/// thin, bright, slightly softened rim.
///
/// `.thinMaterial` cannot reach that look: a system material paints its own
/// gray/white veil over the sample, which is what makes an iOS "frosted" panel
/// read as milky plastic instead of glass. Sampling the backdrop directly and
/// applying every layer above it explicitly is the whole difference.
/// Keeping the caller's Shape preserves Telegram tails.
private struct FrostedGlassBubbleBackground<BubbleShape: Shape>: View {
    let shape: BubbleShape
    let tint: Color
    let tintOpacity: Double

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let isLight = colorScheme == .light
        let clampedTint = max(0, min(1, tintOpacity))
        // Operit tints the surface at 0.16 (light) / 0.23 (dark) plus a 0.10
        // overlay boost. Past that the wash starts hiding the backdrop and the
        // glass turns back into translucent plastic.
        let surfaceTintOpacity = min(
            isLight ? 0.26 : 0.33,
            (isLight ? 0.07 : 0.11) + clampedTint * (isLight ? 0.19 : 0.22)
        )

        Group {
            if reduceTransparency {
                shape.fill(tint.opacity(isLight ? 0.30 : 0.38))
            } else {
                // A Shape fill happily paints outside the view's bounds, but a
                // UIKit backdrop only samples its own frame — and the Telegram
                // tail is drawn past the edge on purpose. Oversizing the blur
                // keeps the tail from coming out hollow; `clipShape` still cuts
                // to the real path, which may itself extend past the bounds.
                Color.clear
                    .overlay {
                        VariableBackdropBlur(
                            radius: 26,
                            mask: .solid,
                            saturation: 1.7,
                            // One live backdrop per bubble is only affordable
                            // in a scrolling list at 1x. At the screen's own 3x
                            // this drops frames, and a 26pt blur has no detail
                            // left to lose by being sampled coarsely.
                            resolutionScale: 1
                        )
                        .padding(-14)
                    }
                    .clipShape(shape)
            }
        }
        .overlay(shape.fill(tint.opacity(surfaceTintOpacity)))
        .overlay {
            // A faint directional gloss. Operit's fallback washes flat white
            // over the surface; angling it keeps the bubble from looking like a
            // sticker without implying a light source the rim contradicts.
            shape.fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(isLight ? 0.10 : 0.055),
                        Color.white.opacity(isLight ? 0.02 : 0.01),
                        Color.clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        .overlay {
            // Operit's Highlight is 0.28dp wide but blurred at 2.4x that and
            // drawn at alpha 0.62: a thin bright edge that fades inward rather
            // than a drawn outline. Clipping after the blur discards the outer
            // half, so the rim lands at roughly half this line width and the
            // shape stays crisp. No dark side — the Compose highlight has none,
            // and a black lower edge is what made this read as a drawn border.
            shape
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isLight ? 0.62 : 0.50),
                            Color.white.opacity(isLight ? 0.26 : 0.20),
                            Color.white.opacity(isLight ? 0.10 : 0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.9
                )
                .blur(radius: 0.7)
                .clipShape(shape)
        }
        .shadow(
            color: Color.black.opacity(isLight ? 0.10 : 0.18),
            radius: 12,
            y: 3
        )
    }
}

private struct AvatarBadge: View {
    let image: UIImage?
    let fallback: String
    let palette: EchoPalette
    var size: CGFloat = 30
    var showsShadow = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: fallback)
                    .font(.system(size: size * 0.43, weight: .light))
                    .foregroundStyle(palette.accent)
            }
        }
        .frame(width: size, height: size)
        .background(image == nil ? palette.aiBubble : Color.clear, in: Circle())
        .clipShape(Circle())
        .overlay {
            if showsShadow {
                Circle()
                    .stroke(Color.white.opacity(0.28), lineWidth: 0.65)
            }
        }
        .shadow(
            color: showsShadow ? Color.black.opacity(0.13) : Color.clear,
            radius: showsShadow ? 4.5 : 0,
            y: showsShadow ? 2 : 0
        )
        .accessibilityHidden(true)
    }
}

struct TypingRow: View {
    let palette: EchoPalette
    let showsAIAvatar: Bool
    let aiAvatarImage: UIImage?
    let isNest: Bool
    let usesUpperTailAvatarLayout: Bool
    let showsAvatarHeader: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if usesUpperTailAvatarLayout && showsAvatarHeader {
                AvatarBadge(
                    image: aiAvatarImage,
                    fallback: "sparkle",
                    palette: palette,
                    size: 36,
                    showsShadow: true
                )
            }
            HStack(spacing: 8) {
                if !usesUpperTailAvatarLayout {
                    if isNest {
                        ClaudeBrandMark(size: 16, motion: .writing, color: palette.accent)
                    } else if showsAIAvatar {
                        AvatarBadge(image: aiAvatarImage, fallback: "sparkle", palette: palette)
                    }
                }
                JumpingDots(color: palette.secondaryText)
                    .padding(.horizontal, isNest ? 2 : 14)
                    .frame(height: 35)
                Spacer()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("AI 正在输入")
    }
}

/// A staggered three-dot wave shared by transient chat activity indicators.
/// Timeline-driven motion keeps the dots phase-locked after list recycling.
private struct JumpingDots: View {
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    let jump = jumpAmount(for: index, at: context.date)
                    Circle()
                        .fill(color)
                        .frame(width: 5, height: 5)
                        .scaleEffect(0.88 + jump * 0.16)
                        .offset(y: -4 * jump)
                        .opacity(0.42 + Double(jump) * 0.58)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func jumpAmount(for index: Int, at date: Date) -> CGFloat {
        guard !reduceMotion else { return 0 }
        let cycle = 1.05
        let stagger = 0.14 * Double(index)
        var elapsed = (date.timeIntervalSinceReferenceDate - stagger)
            .truncatingRemainder(dividingBy: cycle)
        if elapsed < 0 { elapsed += cycle }
        let phase = elapsed / cycle
        guard phase < 0.44 else { return 0 }
        return CGFloat(sin((phase / 0.44) * .pi))
    }
}

private struct AttachmentView: View {
    let attachment: Attachment
    let request: URLRequest?
    let palette: EchoPalette

    var body: some View {
        if attachment.isImage {
            AuthenticatedImageView(
                request: request,
                palette: palette,
                previewCornerRadius: 18
            )
                .frame(maxWidth: 260, minHeight: 120, maxHeight: 330)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else if attachment.isAudio {
            VoiceAttachmentView(attachment: attachment, request: request, palette: palette)
        } else {
            AuthenticatedFileView(attachment: attachment, request: request, palette: palette)
        }
    }
}

private struct PreviewFile: Identifiable {
    let id = UUID()
    let url: URL
}

private struct AuthenticatedFileView: View {
    let attachment: Attachment
    let request: URLRequest?
    let palette: EchoPalette
    @State private var preview: PreviewFile?
    @State private var isLoading = false

    var body: some View {
        Button {
            guard !isLoading, let request else { return }
            isLoading = true
            Task {
                defer { isLoading = false }
                do {
                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        throw URLError(.badServerResponse)
                    }
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TidalEchoPreviews", isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let safeName = attachment.name.replacingOccurrences(of: "/", with: "-")
                    let url = folder.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(safeName)")
                    try data.write(to: url, options: .atomic)
                    preview = PreviewFile(url: url)
                } catch {
                    // The parent message remains readable even when this attachment cannot be downloaded.
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(palette.accent)
                    .frame(width: 34, height: 34)
                    .background(palette.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(2)
                    if let size = attachment.size {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                            .font(.caption2)
                            .foregroundStyle(palette.secondaryText)
                    }
                }
                Spacer(minLength: 6)
                if isLoading { ProgressView().controlSize(.small) }
                else { Image(systemName: "eye").foregroundStyle(palette.secondaryText) }
            }
            .foregroundStyle(palette.text)
            .padding(10)
            .background(palette.composer.opacity(0.72), in: RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .sheet(item: $preview) { item in
            QuickLookPreview(url: item.url)
                .ignoresSafeArea()
        }
    }
}

private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

struct VoiceAttachmentView: View {
    let attachment: Attachment
    let request: URLRequest?
    let palette: EchoPalette
    @ObservedObject private var playback = VoicePlaybackCenter.shared
    @State private var scrubProgress: Double?

    private var isCurrent: Bool { playback.currentID == attachment.id }
    private var displayedProgress: Double {
        scrubProgress ?? (isCurrent ? playback.progress : 0)
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                guard let request else { return }
                Task { await playback.toggle(id: attachment.id, request: request) }
            } label: {
                ZStack {
                    Circle().fill(palette.accent.opacity(0.15))
                    if isCurrent && playback.isLoading {
                        ProgressView().controlSize(.small).tint(palette.accent)
                    } else {
                        Image(systemName: isCurrent && playback.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(palette.accent)
                    }
                }
                .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCurrent && playback.isPlaying ? "暂停语音" : "播放语音")

            VoiceWaveform(
                progress: displayedProgress,
                isPlaying: isCurrent && playback.isPlaying && scrubProgress == nil,
                palette: palette
            )
            .frame(width: 86, height: 28)
            .contentShape(Rectangle())
            .gesture(waveformDragGesture)
            .accessibilityElement()
            .accessibilityLabel("语音播放进度")
            .accessibilityValue("百分之 \(Int(displayedProgress * 100))")
            .accessibilityAdjustableAction { direction in
                guard isCurrent else { return }
                let delta: Double
                switch direction {
                case .increment: delta = 0.05
                case .decrement: delta = -0.05
                @unknown default: return
                }
                playback.seek(id: attachment.id, toProgress: playback.progress + delta)
            }

            Text(playbackLabel)
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .lineLimit(1)
                .frame(minWidth: 30, maxWidth: 92, alignment: .trailing)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(palette.composer.opacity(0.72), in: Capsule())
    }

    private var waveformDragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let next = waveformProgress(at: value.location.x)
                scrubProgress = next
                if isCurrent {
                    playback.seek(id: attachment.id, toProgress: next)
                }
            }
            .onEnded { value in
                let next = waveformProgress(at: value.location.x)
                if isCurrent {
                    playback.seek(id: attachment.id, toProgress: next)
                    scrubProgress = nil
                } else if let request {
                    Task { @MainActor in
                        await playback.toggle(id: attachment.id, request: request)
                        playback.seek(id: attachment.id, toProgress: next)
                        scrubProgress = nil
                    }
                } else {
                    scrubProgress = nil
                }
            }
    }

    private func waveformProgress(at x: CGFloat) -> Double {
        Double(min(86, max(0, x)) / 86)
    }

    private func voiceTime(_ value: TimeInterval) -> String {
        let total = max(0, Int(value.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var playbackLabel: String {
        if let scrubProgress, isCurrent, playback.duration > 0 {
            return voiceTime(playback.duration * scrubProgress)
        }
        if isCurrent && playback.duration > 0 { return voiceTime(playback.duration) }
        if attachment.voice == true || attachment.name.lowercased().contains("voice") { return "语音" }
        return attachment.name
    }
}

private struct VoiceWaveform: View {
    let progress: Double
    let isPlaying: Bool
    let palette: EchoPalette

    private let barHeights: [CGFloat] = [
        8, 15, 21, 13, 18, 10, 16, 22, 12, 19, 9,
        17, 14, 20, 11, 18, 13, 21, 10, 16, 12, 8
    ]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: !isPlaying)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(barHeights.indices, id: \.self) { index in
                    let threshold = (Double(index) + 0.5) / Double(barHeights.count)
                    Capsule()
                        .fill(threshold <= progress ? palette.accent : palette.secondaryText.opacity(0.32))
                        .frame(width: 2.2, height: animatedHeight(at: index, phase: phase))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private func animatedHeight(at index: Int, phase: TimeInterval) -> CGFloat {
        guard isPlaying else { return barHeights[index] }
        let wave = sin(phase * 5.2 + Double(index) * 0.78)
        return max(6, barHeights[index] + CGFloat(wave) * 2.4)
    }
}

@MainActor
private final class AuthenticatedImageLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var failed = false

    func load(_ request: URLRequest?) async {
        guard let request else { failed = true; return }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let image = UIImage(data: data) else {
                failed = true
                return
            }
            self.image = image
            failed = false
        } catch {
            failed = true
        }
    }
}

struct AuthenticatedImageView: View {
    let request: URLRequest?
    let palette: EchoPalette
    var contentMode: ContentMode = .fit
    var allowsPreview = true
    var previewCornerRadius: CGFloat = 0
    @StateObject private var loader = AuthenticatedImageLoader()
    @State private var previewImage: ImagePreviewItem?

    init(
        request: URLRequest?,
        palette: EchoPalette,
        contentMode: ContentMode = .fit,
        allowsPreview: Bool = true,
        previewCornerRadius: CGFloat = 0
    ) {
        self.request = request
        self.palette = palette
        self.contentMode = contentMode
        self.allowsPreview = allowsPreview
        self.previewCornerRadius = previewCornerRadius
    }

    var body: some View {
        Group {
            if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .scaleEffect(imageOverscan)
                    .clipShape(RoundedRectangle(cornerRadius: previewCornerRadius, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: previewCornerRadius, style: .continuous))
                    .onTapGesture {
                        guard allowsPreview else { return }
                        previewImage = ImagePreviewItem(image: image)
                    }
                    .accessibilityElement()
                    .accessibilityLabel("打开图片预览")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction {
                        guard allowsPreview else { return }
                        previewImage = ImagePreviewItem(image: image)
                    }
            } else if loader.failed {
                Label("图片加载失败", systemImage: "photo.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ProgressView()
                    .tint(palette.accent)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .background(palette.composer.opacity(0.45))
        .task(id: request?.url?.absoluteString) { await loader.load(request) }
        .fullScreenCover(item: $previewImage) { item in
            FullScreenImagePreview(image: item.image)
        }
    }

    private var imageOverscan: CGFloat {
        switch contentMode {
        case .fit: return 1
        case .fill: return 1.04
        @unknown default: return 1
        }
    }

}

struct LiquidGlassBubbleBackground: View {
    let tint: Color
    let tintOpacity: Double
    let radius: CGFloat
    let settings: LiquidGlassSettings
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { geometry in
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            let strength = clamped(settings.strength / 100)
            let dispersion = clamped(settings.dispersion)
            let rim = clamped(settings.rimWidth)
            let visualThickness = clamped((settings.size - 80) / 180)
            let glassTintOpacity = clamped(0.018 + tintOpacity * (0.065 + strength * 0.045))
            let washOpacity = clamped(tintOpacity * (0.012 + strength * 0.04 + visualThickness * 0.018))
            let rimLine = CGFloat(0.32 + rim * 1.45 + visualThickness * 0.24)
            let dispersionShift = CGFloat(dispersion * 1.35)
            let usesStableLongBubble = geometry.size.height > 2000

            if reduceTransparency || usesStableLongBubble {
                // Very tall native Glass surfaces are tiled by the compositor
                // and can flash gray blocks while scrolling. A static translucent
                // surface is more important than live refraction for long essays.
                ZStack {
                    shape.fill(tint.opacity(clamped(0.13 + tintOpacity * 0.24)))
                    shape.fill(Color.white.opacity(reduceTransparency ? 0.17 : 0.065))
                }
                .overlay {
                    shape.stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.16 + rim * 0.10),
                                Color.white.opacity(0.035),
                                Color.black.opacity(0.025)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: rimLine
                    )
                }
            } else {
                ZStack {
                    // One native glass surface per bubble. The system owns all
                    // backdrop refraction, blur, lighting and motion response.
                    shape
                        .fill(Color.white.opacity(0.001))
                        .glassEffect(
                            .clear
                                .tint(tint.opacity(glassTintOpacity))
                                .interactive(false),
                            in: shape
                        )

                    // A flat tint wash changes visual thickness without asking
                    // the compositor to sample or blur the backdrop a second time.
                    shape.fill(tint.opacity(washOpacity))

                    if dispersion > 0.001 {
                        // Lightweight rim-only approximation. True RGB backdrop
                        // displacement remains reserved for an explicit enhanced
                        // renderer with a captured background texture.
                        shape
                            .stroke(
                                LinearGradient(
                                    colors: [.clear, Color.red.opacity(0.26), Color.pink.opacity(0.10), .clear],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: rimLine
                            )
                            .offset(x: dispersionShift, y: dispersionShift * 0.28)
                            .opacity(dispersion * 0.46)

                        shape
                            .stroke(
                                LinearGradient(
                                    colors: [.clear, Color.cyan.opacity(0.28), Color.blue.opacity(0.09), .clear],
                                    startPoint: .bottomTrailing,
                                    endPoint: .topLeading
                                ),
                                lineWidth: rimLine
                            )
                            .offset(x: -dispersionShift, y: -dispersionShift * 0.28)
                            .opacity(dispersion * 0.46)
                    }
                }
                .clipShape(shape)
                .overlay {
                    shape.stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.10 + rim * 0.13 + visualThickness * 0.04),
                                Color.white.opacity(0.025),
                                Color.black.opacity(0.018 + strength * 0.018)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: rimLine
                    )
                }
                .shadow(
                    color: Color.black.opacity(0.018 + strength * 0.018),
                    radius: 2.2,
                    y: 1.2
                )
            }
        }
    }

    private func clamped(_ value: Double) -> Double {
        max(0, min(1, value))
    }
}

private struct ImagePreviewItem: Identifiable {
    let id = UUID()
    let image: UIImage
}

private struct FullScreenImagePreview: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var scale = 1.0
    @State private var settledScale = 1.0
    @State private var isSaving = false
    @State private var didSave = false
    @State private var saveErrorMessage: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            scale = min(max(settledScale * value, 1), 5)
                        }
                        .onEnded { _ in
                            settledScale = scale
                        }
                )
                .onTapGesture(count: 2) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        scale = scale > 1 ? 1 : 2
                        settledScale = scale
                    }
                }

            VStack {
                HStack {
                    Button(action: saveImage) {
                        Group {
                            if isSaving {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.system(size: 15, weight: .semibold))
                            }
                        }
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.black.opacity(0.58), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isSaving)
                    .accessibilityLabel(isSaving ? "正在保存图片" : "保存图片")

                    Spacer()

                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.black.opacity(0.58), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭图片预览")
                }
                .padding(.top, 12)
                .padding(.horizontal, 14)

                Spacer()

                if didSave {
                    Label("已保存到照片", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Color.black.opacity(0.62), in: Capsule())
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .statusBarHidden()
        .alert("图片没有保存", isPresented: Binding(
            get: { saveErrorMessage != nil },
            set: { if !$0 { saveErrorMessage = nil } }
        )) {
            Button("好", role: .cancel) { saveErrorMessage = nil }
        } message: {
            Text(saveErrorMessage ?? "请稍后再试")
        }
    }

    private func saveImage() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                isSaving = false
                saveErrorMessage = "请在系统设置中允许 Tidal Echo 添加照片。"
                return
            }

            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }
                isSaving = false
                withAnimation(.easeOut(duration: 0.18)) { didSave = true }
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                withAnimation(.easeIn(duration: 0.18)) { didSave = false }
            } catch {
                isSaving = false
                saveErrorMessage = error.localizedDescription
            }
        }
    }
}

/// ChatNest marks a thinking step with a clock whose upper-left arc dissolves
/// into three dots. No SF Symbol carries that break, so it is drawn by hand and
/// inherits whatever foreground style the row is using.
private struct NestThinkingClock: View {
    var size: CGFloat = 14
    var lineWidth: CGFloat = 1.3

    var body: some View {
        ZStack {
            // 300° of ring, starting at 11 o'clock and running clockwise.
            Circle()
                .trim(from: 0, to: 0.833)
                .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(240))

            // The missing 60° comes back as three dots.
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .frame(width: lineWidth * 1.2, height: lineWidth * 1.2)
                    .offset(y: -(size - lineWidth) / 2)
                    .rotationEffect(.degrees(-75 + Double(index) * 18))
            }

            NestClockHands()
                .stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
    }
}

private struct NestClockHands: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        path.move(to: CGPoint(x: center.x, y: center.y - radius * 0.55))
        path.addLine(to: center)
        path.addLine(to: CGPoint(x: center.x + radius * 0.44, y: center.y + radius * 0.3))
        return path
    }
}
