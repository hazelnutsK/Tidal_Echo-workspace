import Photos
import SwiftUI
import UIKit

/// 多选消息时盖在输入栏上的那一条：收藏、分享卡片、取消。
struct MessageSelectionBar: View {
    let count: Int
    let allStarred: Bool
    let isWorking: Bool
    let palette: EchoPalette
    let onStar: () -> Void
    let onShare: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button("取消", action: onCancel)
                .foregroundStyle(palette.text)
                .frame(minWidth: 44, minHeight: 44)

            Spacer(minLength: 4)
            Group {
                if isWorking {
                    ProgressView().controlSize(.small)
                } else {
                    Text(count == 0 ? "点消息来选择" : "已选 \(count) 条")
                }
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(palette.secondaryText)
            Spacer(minLength: 4)

            Button(action: onStar) {
                Label(allStarred ? "取消收藏" : "收藏", systemImage: allStarred ? "star.slash" : "star")
            }
            .frame(minHeight: 44)
            .disabled(count == 0 || isWorking)

            Button(action: onShare) {
                Label("卡片", systemImage: "square.and.arrow.up")
            }
            .frame(minHeight: 44)
            .disabled(count == 0 || isWorking)
        }
        .labelStyle(.titleAndIcon)
        .font(.subheadline)
        .tint(palette.accent)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(alignment: .top) { Rectangle().fill(palette.hairline).frame(height: 0.5) }
                .ignoresSafeArea(.container, edges: .bottom)
        }
    }
}

/// How the exported card looks: taken from the current appearance when it is made.
struct MessageShareStyle {
    let palette: EchoPalette
    let aiFont: EchoChatFont
    let humanFont: EchoChatFont
    let aiScale: Double
    let humanScale: Double
    let weight: Double
    let aiBubble: Color
    let humanBubble: Color
    let aiText: Color
    let humanText: Color
    let aiOpacity: Double
    let humanOpacity: Double
    let radius: CGFloat
    let aiAvatar: UIImage?
    let humanAvatar: UIImage?
    let aiName: String
    let humanName: String
}

/// 导出的那张卡片。只画静态的东西：文字、已经下载好的图、头像，
/// 卡片、按钮这类交互元素都换成一行字。
struct MessageShareCard: View {
    static let width: CGFloat = 390

    let messages: [ChatMessage]
    let images: [String: UIImage]
    let style: MessageShareStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 18)

            VStack(spacing: 6) {
                ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                    let startsGroup = index == 0 || messages[index - 1].author != message.author
                    row(message, startsGroup: startsGroup)
                        .padding(.top, startsGroup && index > 0 ? 10 : 0)
                }
            }

            footer
                .padding(.top, 22)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 24)
        .frame(width: Self.width)
        .background(style.palette.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(style.humanName) & \(style.aiName)")
                .font(.system(size: 17, weight: .semibold, design: .serif))
                .foregroundStyle(style.palette.text)
            Text(dateRange)
                .font(.system(size: 12))
                .foregroundStyle(style.palette.secondaryText)
        }
    }

    private var footer: some View {
        HStack {
            Rectangle().fill(style.palette.hairline).frame(height: 0.5)
            Text("Tidal Echo")
                .font(.system(size: 10.5, weight: .medium, design: .serif))
                .tracking(1.4)
                .foregroundStyle(style.palette.secondaryText)
                .fixedSize()
            Rectangle().fill(style.palette.hairline).frame(height: 0.5)
        }
    }

    private var dateRange: String {
        let dates = messages.compactMap { EchoDateCache.date(from: $0.timestamp) }
        guard let first = dates.min(), let last = dates.max() else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = EchoDateCache.shanghaiTimeZone
        formatter.dateFormat = "yyyy年M月d日"
        let start = formatter.string(from: first)
        let end = formatter.string(from: last)
        return start == end ? start : "\(start) – \(end)"
    }

    @ViewBuilder
    private func row(_ message: ChatMessage, startsGroup: Bool) -> some View {
        let isHuman = message.author == .human
        HStack(alignment: .top, spacing: 8) {
            if isHuman { Spacer(minLength: 48) } else { avatar(for: message, visible: startsGroup) }
            bubble(message, isHuman: isHuman)
            if isHuman { avatar(for: message, visible: startsGroup) } else { Spacer(minLength: 48) }
        }
    }

    @ViewBuilder
    private func avatar(for message: ChatMessage, visible: Bool) -> some View {
        let isHuman = message.author == .human
        let image = isHuman ? style.humanAvatar : style.aiAvatar
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Text(isHuman ? "L" : "A")
                    .font(.system(size: 13, weight: .semibold, design: .serif))
                    .foregroundStyle(style.palette.secondaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(style.palette.composer)
            }
        }
        .frame(width: 30, height: 30)
        .clipShape(Circle())
        .opacity(visible ? 1 : 0)
    }

    @ViewBuilder
    private func bubble(_ message: ChatMessage, isHuman: Bool) -> some View {
        let photos = message.meta.attachments.filter { $0.isImage && $0.xhs != true }
        let others = message.meta.attachments.filter { !$0.isImage && $0.voice != true }
        let text = displayText(message)
        VStack(alignment: isHuman ? .trailing : .leading, spacing: 6) {
            ForEach(photos) { attachment in
                if let image = images[attachment.id] {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 220, maxHeight: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    placeholder("图片")
                }
            }
            ForEach(others) { attachment in
                placeholder("附件 · \(attachment.name)")
            }
            if !text.isEmpty {
                MarkdownMessageText(
                    source: text,
                    palette: style.palette,
                    textColor: isHuman ? style.humanText : style.aiText,
                    chatFont: isHuman ? style.humanFont : style.aiFont,
                    fontScale: isHuman ? style.humanScale : style.aiScale,
                    chatWeight: style.weight
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    (isHuman ? style.humanBubble : style.aiBubble)
                        .opacity(isHuman ? style.humanOpacity : style.aiOpacity),
                    in: RoundedRectangle(cornerRadius: style.radius, style: .continuous)
                )
            }
        }
    }

    private func placeholder(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 12))
            .foregroundStyle(style.palette.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(style.palette.composer.opacity(0.8), in: Capsule())
    }

    private func displayText(_ message: ChatMessage) -> String {
        var text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.kind == "voice" {
            for prefix in ["🎙️", "🎤", "🎙"] where text.hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return text.isEmpty ? "语音" : "语音 · \(text)"
        }
        return text
    }

    @MainActor
    static func render(messages: [ChatMessage], images: [String: UIImage], style: MessageShareStyle) -> UIImage? {
        let renderer = ImageRenderer(content: MessageShareCard(messages: messages, images: images, style: style))
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        // Long selections stay under a sane bitmap size.
        renderer.scale = messages.count > 24 ? 2 : 3
        return renderer.uiImage
    }
}

struct ShareCardImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// 卡片做好以后的预览：可以存进相册，也可以直接走系统分享。
struct MessageShareSheet: View {
    let card: ShareCardImage
    let palette: EchoPalette
    @Environment(\.dismiss) private var dismiss
    @State private var isSaving = false
    @State private var didSave = false
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                Image(uiImage: card.image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
                    .padding(20)
            }
            .background(palette.composer.opacity(0.5).ignoresSafeArea())
            .navigationTitle("分享卡片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button(action: save) {
                        Label(didSave ? "已保存" : "存到相册",
                              systemImage: didSave ? "checkmark" : "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSaving)

                    ShareLink(
                        item: Image(uiImage: card.image),
                        preview: SharePreview("聊天卡片", image: Image(uiImage: card.image))
                    ) {
                        Label("分享", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
                .tint(palette.accent)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.bar)
            }
            .alert("没存上", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("好", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
        }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                saveError = "请在系统设置中允许 Tidal Echo 添加照片。"
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: card.image)
                }
                withAnimation(.easeOut(duration: 0.18)) { didSave = true }
            } catch {
                saveError = error.localizedDescription
            }
        }
    }
}
