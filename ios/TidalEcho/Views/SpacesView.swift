import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

struct SpacesView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var desire: DesireState?
    @State private var desireEnabled = false
    @State private var libidoMultiplier = 1.0
    @State private var isLoadingDesire = true
    @State private var desireError: String?
    @State private var isSavingDesire = false

    private var palette: EchoPalette { model.theme.palette }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("我们的空间")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                        Text("把聊天以外的那些小东西，也好好收在一起。")
                            .font(.subheadline)
                            .foregroundStyle(palette.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        SpaceLink(title: "收藏", subtitle: "舍不得丢的对话", icon: "bookmark.fill", color: .orange, unreadCount: 0) {
                            StarsView(model: model)
                        }
                        SpaceLink(title: "相册", subtitle: "Altair 收藏的照片", icon: "photo.on.rectangle.angled", color: .cyan, unreadCount: 0) {
                            AlbumView(model: model)
                        }
                        SpaceLink(title: "礼物室", subtitle: "小克做的页面", icon: "gift.fill", color: .pink, unreadCount: model.giftUnreadCount) {
                            GiftsView(model: model)
                        }
                        SpaceLink(title: "Moments", subtitle: "动态与日志", icon: "sparkles", color: .purple, unreadCount: model.momentsUnreadCount) {
                            MomentsView(model: model)
                        }
                        SpaceLink(title: "日历", subtitle: "日程与纪念日", icon: "calendar", color: .green, unreadCount: 0) {
                            EchoCalendarView(model: model)
                        }
                        SpaceLink(title: "书房", subtitle: "一起读的书", icon: "books.vertical.fill", color: .brown, unreadCount: 0) {
                            BookshelfView(model: model)
                        }
                    }

                    VStack(alignment: .leading, spacing: 9) {
                        Text("他的内心")
                            .font(.caption.weight(.semibold))
                            .tracking(1.2)
                            .foregroundStyle(palette.secondaryText)

                        SpaceLink(title: "他的记忆", subtitle: "Altair 记住的那些事", icon: "brain.head.profile", color: .indigo, unreadCount: 0) {
                            MemoryVaultView(model: model)
                        }

                        DesireCard(
                            state: desire,
                            enabled: $desireEnabled,
                            libidoMultiplier: $libidoMultiplier,
                            isLoading: isLoadingDesire,
                            isSaving: isSavingDesire,
                            errorText: desireError,
                            palette: palette,
                            onToggle: { enabled in
                                Task { await saveDesire(enabled: enabled) }
                            },
                            onLibidoCommit: {
                                Task { await saveDesire(libidoMultiplier: libidoMultiplier) }
                            }
                        )
                    }
                }
                .padding(18)
            }
            .background(palette.background.ignoresSafeArea())
            .foregroundStyle(palette.text)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .foregroundStyle(palette.accent)
                }
            }
            .refreshable { await refreshSpace() }
            .task { await refreshSpace() }
        }
        .tint(palette.accent)
    }

    @MainActor
    private func refreshSpace() async {
        await model.refreshSpaceUnreadCounts()
        await loadDesire()
    }

    @MainActor
    private func loadDesire() async {
        isLoadingDesire = true
        defer { isLoadingDesire = false }
        do {
            applyDesire(try await model.desireState())
            desireError = nil
        } catch {
            desireError = "内心读取失败"
        }
    }

    @MainActor
    private func saveDesire(enabled: Bool? = nil, libidoMultiplier: Double? = nil) async {
        isSavingDesire = true
        defer { isSavingDesire = false }
        do {
            applyDesire(try await model.updateDesire(enabled: enabled, libidoMultiplier: libidoMultiplier))
            desireError = nil
        } catch {
            desireError = "这次没有保存成功"
            await loadDesire()
        }
    }

    private func applyDesire(_ state: DesireState) {
        desire = state
        desireEnabled = state.activity.enabled
        libidoMultiplier = state.activity.libidoMultiplier
    }
}

private struct SpaceLink<Destination: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let unreadCount: Int
    let destination: () -> Destination

    var body: some View {
        NavigationLink(destination: destination) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 46, height: 46)
                    .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 142, alignment: .leading)
            .padding(15)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if unreadCount > 0 {
                    Text(unreadCount > 99 ? "99+" : "\(unreadCount)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, unreadCount > 9 ? 6 : 0)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(Color.red, in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.85), lineWidth: 1.5))
                        .shadow(color: Color.red.opacity(0.24), radius: 4, y: 2)
                        .padding(10)
                        .accessibilityLabel("\(unreadCount) 条未读")
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct DesireCard: View {
    let state: DesireState?
    @Binding var enabled: Bool
    @Binding var libidoMultiplier: Double
    let isLoading: Bool
    let isSaving: Bool
    let errorText: String?
    let palette: EchoPalette
    let onToggle: (Bool) -> Void
    let onLibidoCommit: () -> Void

    private let order = ["attachment", "libido", "reflection", "curiosity", "social", "duty", "stress", "fatigue"]
    private let names = [
        "attachment": "想她", "curiosity": "好奇", "reflection": "沉淀", "duty": "记挂",
        "social": "看人群", "libido": "贴贴", "stress": "压力", "fatigue": "疲惫"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            if let state {
                (Text("此刻最想：") + Text(state.intent.reason.isEmpty ? "…" : state.intent.reason).fontWeight(.medium))
                    .font(.system(size: 13))
                    .foregroundStyle(palette.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.aiBubble.opacity(0.64), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(spacing: 8) {
                    ForEach(order, id: \.self) { key in
                        DesireDriveRow(
                            name: names[key] ?? key,
                            value: state.drive[key] ?? 0,
                            isGate: key == "stress" || key == "fatigue",
                            isLeading: key == state.intent.driveKey,
                            palette: palette
                        )
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    if state.thoughts.isEmpty {
                        Label("念头池还空着，等他自己长", systemImage: "sparkle")
                            .foregroundStyle(palette.secondaryText)
                    } else {
                        ForEach(Array(state.thoughts.prefix(8))) { thought in
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Text(thought.kind == "fixation" ? "✦" : "✧")
                                    .foregroundStyle(palette.accent)
                                Text(thought.text)
                                    .foregroundStyle(palette.text)
                                Spacer(minLength: 4)
                                Text(String(format: "%.2f · %@", thought.strength, names[thought.drive] ?? thought.drive))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(palette.secondaryText)
                            }
                            .font(.system(size: 12.5))
                        }
                    }
                }

                Divider().overlay(palette.hairline)

                Toggle("主动找她", isOn: Binding(
                    get: { enabled },
                    set: { value in
                        enabled = value
                        onToggle(value)
                    }
                ))
                .font(.system(size: 12.5, weight: .medium))
                .disabled(isSaving)

                HStack(spacing: 10) {
                    Text("贴贴权重")
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.secondaryText)
                    Slider(value: $libidoMultiplier, in: 0...1.5, step: 0.1) { editing in
                        if !editing { onLibidoCommit() }
                    }
                    .disabled(isSaving)
                    Text(libidoMultiplier, format: .number.precision(.fractionLength(1)))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(palette.secondaryText)
                        .frame(width: 24)
                }

                HStack(spacing: 7) {
                    if isSaving { ProgressView().controlSize(.mini) }
                    Text(activityStatus(state.activity))
                        .font(.caption2)
                        .foregroundStyle(palette.secondaryText)
                }
            } else if isLoading {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("正在听一听…")
                }
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
                .frame(maxWidth: .infinity, minHeight: 80)
            }

            if let errorText {
                Text(errorText)
                    .font(.caption2)
                    .foregroundStyle(.red.opacity(0.82))
            }
        }
        .tint(palette.accent)
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(palette.hairline))
    }

    private func activityStatus(_ activity: DesireActivity) -> String {
        let delivery: String
        if activity.bodyTarget == "loop" {
            delivery = "API 身体接管中"
        } else if activity.bodyTarget == "codex" {
            delivery = activity.bodyOnline ? "Codex 身体在线" : "等待 Codex 桥接上线"
        } else {
            delivery = activity.bodyOnline ? "桌面身体在线" : "等待桌面身体上线"
        }
        let cooldown = activity.cooldownLeftSeconds > 0 ? " · 冷却 \((activity.cooldownLeftSeconds + 59) / 60)min" : ""
        return "今日 \(activity.today)/\(activity.dailyCap)\(cooldown) · \(delivery)"
    }
}

private struct DesireDriveRow: View {
    let name: String
    let value: Double
    let isGate: Bool
    let isLeading: Bool
    let palette: EchoPalette

    var body: some View {
        HStack(spacing: 9) {
            Text(name)
                .font(.system(size: 11.5, weight: isLeading ? .semibold : .regular))
                .foregroundStyle(isLeading ? palette.text : palette.secondaryText)
                .frame(width: 48, alignment: .trailing)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.hairline.opacity(0.72))
                    Capsule()
                        .fill(isGate ? Color(hex: 0xA37E66) : palette.accent)
                        .frame(width: geometry.size.width * max(0, min(1, value)))
                }
            }
            .frame(height: 6)
            Text(value, format: .number.precision(.fractionLength(2)))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(palette.secondaryText)
                .frame(width: 30, alignment: .trailing)
        }
    }
}

private struct SpaceEmptyState: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 70)
        .padding(.horizontal, 30)
    }
}

// MARK: - 收藏

private struct StarsView: View {
    @ObservedObject var model: AppModel
    @State private var messages: [ChatMessage] = []
    @State private var isLoading = true
    @State private var errorText: String?

    private var palette: EchoPalette { model.theme.palette }

    var body: some View {
        Group {
            if isLoading && messages.isEmpty {
                ProgressView("正在翻收藏夹…")
            } else if messages.isEmpty {
                SpaceEmptyState(icon: "bookmark", title: "还没有收藏", text: "回到聊天页，长按一条气泡就可以收藏。")
            } else {
                List {
                    ForEach(messages) { message in
                        VStack(alignment: .leading, spacing: 9) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(message.author == .human ? "小雪" : "Altair")
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                Text(shortTimestamp(message.timestamp))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if !message.text.isEmpty {
                                MarkdownMessageText(
                                    source: message.text,
                                    palette: palette,
                                    textColor: palette.text,
                                    chatFont: model.chatFont,
                                    fontScale: model.fontScale,
                                    chatWeight: model.chatWeight
                                )
                            }
                            ForEach(message.meta.attachments.filter(\.isImage)) { attachment in
                                if let request = model.authenticatedRequest(path: attachment.url) {
                                    SpaceRemoteImage(request: request)
                                        .frame(maxHeight: 260)
                                        .clipShape(RoundedRectangle(cornerRadius: 14))
                                }
                            }
                            ForEach(message.meta.attachments.filter(\.isAudio)) { attachment in
                                VoiceAttachmentView(
                                    attachment: attachment,
                                    request: model.authenticatedRequest(path: attachment.url),
                                    palette: model.theme.palette
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.vertical, 7)
                        .swipeActions {
                            Button(role: .destructive) {
                                Task { await unstar(message) }
                            } label: {
                                Label("取消收藏", systemImage: "bookmark.slash")
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("收藏")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .overlay(alignment: .bottom) {
            if let errorText { SpaceErrorBanner(text: errorText) }
        }
    }

    @MainActor
    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            messages = try await model.spaceStars()
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    @MainActor
    private func unstar(_ message: ChatMessage) async {
        do {
            try await model.setStar(messageID: message.id, on: false)
            messages.removeAll { $0.id == message.id }
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - 相册

private struct AlbumView: View {
    @ObservedObject var model: AppModel
    @State private var photos: [AlbumPhoto] = []
    @State private var selectedPhoto: AlbumPhoto?
    @State private var isLoading = true
    @State private var errorText: String?

    private var palette: EchoPalette { model.theme.palette }
    private var groupedPhotos: [(day: String, photos: [AlbumPhoto])] {
        var groups: [(day: String, photos: [AlbumPhoto])] = []
        for photo in photos {
            let day = albumDayLabel(photo.timestamp)
            if groups.last?.day == day {
                groups[groups.count - 1].photos.append(photo)
            } else {
                groups.append((day, [photo]))
            }
        }
        return groups
    }

    var body: some View {
        Group {
            if isLoading && photos.isEmpty {
                ProgressView("正在整理相册…")
            } else if photos.isEmpty {
                SpaceEmptyState(
                    icon: "photo",
                    title: "相册还是空的",
                    text: "这里放 Altair 自己想留下来的照片。看到值得收的，他会把它放进来。"
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(groupedPhotos.enumerated()), id: \.offset) { _, group in
                            Text(group.day)
                                .font(.caption)
                                .tracking(0.8)
                                .foregroundStyle(palette.secondaryText)
                                .padding(.top, 5)

                            ForEach(group.photos) { photo in
                                Button { selectedPhoto = photo } label: {
                                    VStack(alignment: .leading, spacing: 0) {
                                        if let request = model.authenticatedRequest(path: photo.url) {
                                            SpaceRemoteImage(request: request, contentMode: .fill)
                                                .frame(height: 280)
                                                .frame(maxWidth: .infinity)
                                                .clipped()
                                        }
                                        if !photo.title.isEmpty || !photo.note.isEmpty {
                                            VStack(alignment: .leading, spacing: 7) {
                                                if !photo.title.isEmpty {
                                                    Text(photo.title)
                                                        .font(.headline)
                                                        .foregroundStyle(palette.text)
                                                }
                                                if !photo.note.isEmpty {
                                                    Text(photo.note)
                                                        .font(.subheadline)
                                                        .foregroundStyle(palette.secondaryText)
                                                        .fixedSize(horizontal: false, vertical: true)
                                                }
                                                if !photo.keptAt.isEmpty {
                                                    Text("收于 \(albumDayLabel(photo.keptAt))")
                                                        .font(.caption2)
                                                        .foregroundStyle(palette.secondaryText.opacity(0.72))
                                                }
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(14)
                                        }
                                    }
                                    .background(palette.composer.opacity(0.88))
                                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .stroke(palette.hairline, lineWidth: 0.7)
                                    }
                                    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            }
        }
        .navigationTitle("相册")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .sheet(item: $selectedPhoto) { photo in
            AlbumLightbox(model: model, photo: photo)
        }
        .overlay(alignment: .bottom) {
            if let errorText { SpaceErrorBanner(text: errorText) }
        }
    }

    @MainActor
    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            photos = try await model.spaceAlbum()
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private struct AlbumLightbox: View {
    @ObservedObject var model: AppModel
    let photo: AlbumPhoto
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let request = model.authenticatedRequest(path: photo.url) {
                    SpaceRemoteImage(request: request, contentMode: .fit)
                        .padding(.vertical)
                }
                if !photo.title.isEmpty || !photo.note.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        if !photo.title.isEmpty { Text(photo.title).font(.headline) }
                        if !photo.note.isEmpty { Text(photo.note).font(.subheadline) }
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding()
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }.foregroundStyle(.white)
                }
                ToolbarItem(placement: .principal) {
                    Text(shortTimestamp(photo.timestamp)).font(.caption).foregroundStyle(.white.opacity(0.8))
                }
            }
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }
}

private func albumDayLabel(_ value: String) -> String {
    let raw = String(value.prefix(10))
    let parser = DateFormatter()
    parser.locale = Locale(identifier: "en_US_POSIX")
    parser.dateFormat = "yyyy-MM-dd"
    guard let date = parser.date(from: raw) else { return raw }
    let output = DateFormatter()
    output.locale = Locale(identifier: "zh_CN")
    output.dateFormat = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: Date())
        ? "M 月 d 日"
        : "yyyy 年 M 月 d 日"
    return output.string(from: date)
}

// MARK: - 礼物室

private struct GiftsView: View {
    @ObservedObject var model: AppModel
    @State private var pages: [GiftPage] = []
    @State private var isLoading = true
    @State private var errorText: String?

    var body: some View {
        Group {
            if isLoading && pages.isEmpty {
                ProgressView("正在打开礼物室…")
            } else if pages.isEmpty {
                SpaceEmptyState(icon: "gift", title: "礼物室还是空的", text: "以后小克做给你的网页礼物，会出现在这里。")
            } else {
                List(pages) { page in
                    if let url = model.giftPageURL(file: page.file) {
                        NavigationLink {
                            GiftPageView(title: page.title, url: url)
                        } label: {
                            HStack(spacing: 13) {
                                Image(systemName: "gift.fill")
                                    .foregroundStyle(.pink)
                                    .frame(width: 36, height: 36)
                                    .background(Color.pink.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(page.title).font(.headline).lineLimit(2)
                                    Text(page.modified).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 5)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("礼物室")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .overlay(alignment: .bottom) {
            if let errorText { SpaceErrorBanner(text: errorText) }
        }
    }

    @MainActor
    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            pages = try await model.spaceGiftPages()
            model.markGiftPagesRead(pages)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private struct GiftPageView: View {
    let title: String
    let url: URL

    var body: some View {
        GiftWebView(url: url)
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

private struct GiftWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        return view
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard webView.url != url else { return }
        webView.load(URLRequest(url: url))
    }
}

// MARK: - Moments

private struct MomentsView: View {
    @ObservedObject var model: AppModel
    @State private var kind: MomentKind = .moment
    @State private var posts: [MomentPost] = []
    @State private var hasMore = false
    @State private var isLoading = true
    @State private var showingComposer = false
    @State private var errorText: String?

    private let journalColumns = [
        GridItem(.flexible(minimum: 130), spacing: 12),
        GridItem(.flexible(minimum: 130), spacing: 12)
    ]

    var body: some View {
        VStack(spacing: 0) {
            Picker("类型", selection: $kind) {
                Text("动态").tag(MomentKind.moment)
                Text("日志").tag(MomentKind.journal)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if isLoading && posts.isEmpty {
                Spacer()
                ProgressView("正在看看最近发生了什么…")
                Spacer()
            } else if posts.isEmpty {
                Spacer()
                SpaceEmptyState(icon: "sparkles", title: kind == .moment ? "还没有动态" : "还没有日志", text: "右上角的加号可以写下第一条。")
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if kind == .journal {
                            LazyVGrid(columns: journalColumns, alignment: .leading, spacing: 12) {
                                ForEach(posts) { post in
                                    NavigationLink {
                                        JournalDetailView(
                                            model: model,
                                            initialPost: post,
                                            onUpdate: replacePost,
                                            onDeleted: { postID in
                                                posts.removeAll { $0.id == postID }
                                            }
                                        )
                                    } label: {
                                        JournalPreviewCard(
                                            post: post,
                                            palette: model.theme.palette
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        } else {
                            ForEach(posts) { post in
                                MomentCard(
                                    model: model,
                                    post: post,
                                    onLike: { Task { await toggleLike(post) } },
                                    onComment: { text, replyTo in await addComment(post, text: text, replyTo: replyTo) },
                                    onDelete: { Task { await delete(post) } }
                                )
                            }
                        }
                        if hasMore {
                            Button {
                                Task { await load(reset: false) }
                            } label: {
                                if isLoading { ProgressView() } else { Text("加载更早的内容") }
                            }
                            .padding()
                            .disabled(isLoading)
                        }
                    }
                    .padding(14)
                }
                .refreshable { await load(reset: true) }
            }
        }
        .navigationTitle("Moments")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.markAllMomentsRead() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingComposer = true } label: { Image(systemName: "plus") }
            }
        }
        .task(id: kind) { await load(reset: true) }
        .sheet(isPresented: $showingComposer) {
            MomentComposer(model: model, kind: kind) { post in
                posts.insert(post, at: 0)
            }
        }
        .overlay(alignment: .bottom) {
            if let errorText { SpaceErrorBanner(text: errorText) }
        }
    }

    @MainActor
    private func load(reset: Bool) async {
        if isLoading && !reset { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let before = reset ? nil : posts.last?.id
            let response = try await model.spaceMoments(kind: kind, before: before)
            posts = reset ? response.posts : posts + response.posts.filter { newPost in
                !posts.contains(where: { $0.id == newPost.id })
            }
            if reset { model.markMomentPostsRead(response.posts) }
            hasMore = response.hasMore
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    @MainActor
    private func toggleLike(_ post: MomentPost) async {
        do {
            let likes = try await model.likeMoment(id: post.id, on: post.meta.likes["human"] == nil)
            if let index = posts.firstIndex(where: { $0.id == post.id }) {
                posts[index].meta.likes = likes
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    @MainActor
    private func addComment(_ post: MomentPost, text: String, replyTo: MessageAuthor?) async -> Bool {
        do {
            let comment = try await model.commentMoment(id: post.id, text: text, replyTo: replyTo)
            if let index = posts.firstIndex(where: { $0.id == post.id }) {
                posts[index].meta.comments.append(comment)
            }
            return true
        } catch {
            errorText = error.localizedDescription
            return false
        }
    }

    @MainActor
    private func delete(_ post: MomentPost) async {
        do {
            try await model.deleteMoment(id: post.id)
            posts.removeAll { $0.id == post.id }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func replacePost(_ updatedPost: MomentPost) {
        guard let index = posts.firstIndex(where: { $0.id == updatedPost.id }) else { return }
        posts[index] = updatedPost
    }
}

private struct JournalContent {
    let title: String
    let body: String

    init(_ source: String) {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard let titleIndex = lines.firstIndex(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            title = "未命名日志"
            body = ""
            return
        }

        title = Self.cleanTitle(lines[titleIndex])
        body = lines.dropFirst(titleIndex + 1)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanTitle(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutHeading = String(trimmed.drop(while: { $0 == "#" }))
            .trimmingCharacters(in: .whitespaces)
        return withoutHeading.isEmpty ? trimmed : withoutHeading
    }
}

private struct JournalPreviewCard: View {
    let post: MomentPost
    let palette: EchoPalette

    private var content: JournalContent { JournalContent(post.text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            JournalDropCapPreview(text: content.body, palette: palette)

            Spacer(minLength: 8)

            Rectangle()
                .fill(palette.hairline)
                .frame(height: 0.7)

            Text(content.title)
                .font(.system(size: 14, weight: .semibold, design: .serif))
                .foregroundStyle(palette.text)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("写于 \(shortTimestamp(post.timestamp))")
                .font(.system(size: 10.5, weight: .regular))
                .foregroundStyle(palette.secondaryText)
                .lineLimit(1)
        }
        .padding(13)
        .frame(maxWidth: .infinity, minHeight: 218, alignment: .topLeading)
        .background(palette.composer.opacity(0.88), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(palette.hairline, lineWidth: 0.7)
        }
        .shadow(color: Color.black.opacity(0.045), radius: 8, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(content.title)，写于 \(shortTimestamp(post.timestamp))")
        .accessibilityHint("打开阅读全文")
    }
}

private struct JournalDropCapPreview: View {
    let text: String
    let palette: EchoPalette

    private var cleanText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        if let first = cleanText.first {
            (
                Text(String(first))
                    .font(.system(size: 38, weight: .medium, design: .serif))
                    .baselineOffset(-7)
                + Text(String(cleanText.dropFirst()))
                    .font(.system(size: 13, weight: .regular, design: .serif))
            )
            .foregroundStyle(palette.text)
            .lineSpacing(3)
            .lineLimit(6)
            .multilineTextAlignment(.leading)
        } else {
            Text("尚未写下正文")
                .font(.system(size: 13, design: .serif))
                .foregroundStyle(palette.secondaryText)
        }
    }
}

private struct JournalDetailView: View {
    @ObservedObject var model: AppModel
    @State private var post: MomentPost
    let onUpdate: (MomentPost) -> Void
    let onDeleted: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var errorText: String?

    init(
        model: AppModel,
        initialPost: MomentPost,
        onUpdate: @escaping (MomentPost) -> Void,
        onDeleted: @escaping (Int) -> Void
    ) {
        self.model = model
        _post = State(initialValue: initialPost)
        self.onUpdate = onUpdate
        self.onDeleted = onDeleted
    }

    private var palette: EchoPalette { model.theme.palette }
    private var content: JournalContent { JournalContent(post.text) }

    var body: some View {
        ScrollView {
            MomentCard(
                model: model,
                post: post,
                presentsJournalAsArticle: true,
                onLike: { Task { await toggleLike() } },
                onComment: addComment,
                onDelete: { Task { await deletePost() } }
            )
            .padding(16)
        }
        .background(palette.background.ignoresSafeArea())
        .foregroundStyle(palette.text)
        .navigationTitle(content.title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if let errorText { SpaceErrorBanner(text: errorText) }
        }
    }

    @MainActor
    private func toggleLike() async {
        do {
            post.meta.likes = try await model.likeMoment(
                id: post.id,
                on: post.meta.likes["human"] == nil
            )
            onUpdate(post)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    @MainActor
    private func addComment(_ text: String, _ replyTo: MessageAuthor?) async -> Bool {
        do {
            let newComment = try await model.commentMoment(id: post.id, text: text, replyTo: replyTo)
            post.meta.comments.append(newComment)
            onUpdate(post)
            errorText = nil
            return true
        } catch {
            errorText = error.localizedDescription
            return false
        }
    }

    @MainActor
    private func deletePost() async {
        do {
            try await model.deleteMoment(id: post.id)
            onDeleted(post.id)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private struct MomentCard: View {
    @ObservedObject var model: AppModel
    let post: MomentPost
    var presentsJournalAsArticle = false
    let onLike: () -> Void
    let onComment: (String, MessageAuthor?) async -> Bool
    let onDelete: () -> Void
    @State private var comment = ""
    @State private var replyingTo: MessageAuthor?
    @State private var isSendingComment = false

    private var isLiked: Bool { post.meta.likes["human"] != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                MomentAvatar(
                    image: post.author == .human ? model.humanAvatarImage : model.aiAvatarImage,
                    fallback: post.author == .human ? "person.fill" : "sparkles"
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(authorName(post.author)).font(.headline)
                    Text(shortTimestamp(post.timestamp)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if post.author == .human {
                    Menu {
                        Button(role: .destructive, action: onDelete) {
                            Label("删除", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis").foregroundStyle(.secondary).padding(8)
                    }
                }
            }

            if !post.text.isEmpty {
                if post.kind == .journal && presentsJournalAsArticle {
                    let content = JournalContent(post.text)
                    VStack(alignment: .leading, spacing: 16) {
                        Text(content.title)
                            .font(.system(size: 28, weight: .bold, design: .serif))
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if !content.body.isEmpty {
                            Text(content.body)
                                .font(.body.leading(.loose))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .textSelection(.enabled)
                } else {
                    Text(post.text)
                        .font(post.kind == .journal ? .body.leading(.loose) : .body)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }

            ForEach(post.meta.attachments.filter(\.isImage)) { attachment in
                if let request = model.authenticatedRequest(path: attachment.url) {
                    SpaceRemoteImage(request: request)
                        .frame(maxHeight: 330)
                        .clipShape(RoundedRectangle(cornerRadius: 15))
                }
            }

            HStack(spacing: 20) {
                Button(action: onLike) {
                    Label(post.meta.likes.isEmpty ? "喜欢" : "\(post.meta.likes.count)", systemImage: isLiked ? "heart.fill" : "heart")
                        .foregroundStyle(isLiked ? .pink : .secondary)
                }
                Button { replyingTo = nil } label: {
                    Label(post.meta.comments.isEmpty ? "评论" : "\(post.meta.comments.count)", systemImage: "bubble.left")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline.weight(.medium))

            if !post.meta.comments.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(post.meta.comments) { item in
                        Button {
                            replyingTo = item.author
                        } label: {
                            (Text(authorName(item.author))
                                .fontWeight(.semibold)
                             + Text(item.replyTo == nil ? "：" : " 回复 \(authorName(item.replyTo!))：")
                             + Text(item.text))
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }

            HStack(spacing: 8) {
                TextField(replyingTo == nil ? "写评论…" : "回复 \(authorName(replyingTo!))…", text: $comment)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.send)
                    .onSubmit { sendComment() }
                Button(action: sendComment) {
                    if isSendingComment {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                }
                .disabled(comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSendingComment)
            }
        }
        .padding(15)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func sendComment() {
        let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSendingComment else { return }
        isSendingComment = true
        Task {
            let sent = await onComment(text, replyingTo)
            await MainActor.run {
                if sent {
                    comment = ""
                    replyingTo = nil
                }
                isSendingComment = false
            }
        }
    }

    private func authorName(_ author: MessageAuthor) -> String {
        author == .human ? "小雪" : "Altair"
    }
}

private struct MomentAvatar: View {
    let image: UIImage?
    let fallback: String

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: fallback)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 36, height: 36)
        .background(Color.secondary.opacity(0.10))
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.45), lineWidth: 0.6))
    }
}

private struct MomentComposer: View {
    @ObservedObject var model: AppModel
    let kind: MomentKind
    let onCreated: (MomentPost) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var selections: [PhotosPickerItem] = []
    @State private var previews: [UIImage] = []
    @State private var attachments: [Attachment] = []
    @State private var isWorking = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: kind == .journal ? 220 : 130)
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text(kind == .moment ? "此刻想说什么？" : "慢慢写下今天吧…")
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                }
                Section("图片") {
                    PhotosPicker(selection: $selections, maxSelectionCount: 9, matching: .images) {
                        Label("选择照片", systemImage: "photo.on.rectangle")
                    }
                    if !previews.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(previews.enumerated()), id: \.offset) { _, image in
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 76, height: 76)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                            }
                        }
                    }
                }
                if let errorText {
                    Section { Text(errorText).foregroundStyle(.red).font(.footnote) }
                }
            }
            .navigationTitle(kind == .moment ? "新动态" : "新日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("发布") { Task { await publish() } }
                        .disabled(isWorking || (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty && selections.isEmpty))
                }
            }
            .overlay {
                if isWorking {
                    ZStack {
                        Color.black.opacity(0.12).ignoresSafeArea()
                        ProgressView("正在发布…").padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
            .onChange(of: selections) { items in
                Task { await prepare(items) }
            }
        }
    }

    @MainActor
    private func prepare(_ items: [PhotosPickerItem]) async {
        isWorking = true
        defer { isWorking = false }
        var newPreviews: [UIImage] = []
        var newAttachments: [Attachment] = []
        do {
            for (index, item) in items.enumerated() {
                guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else { continue }
                let type = item.supportedContentTypes.first ?? .jpeg
                let mime = type.preferredMIMEType ?? "image/jpeg"
                let ext = type.preferredFilenameExtension ?? "jpg"
                let attachment = try await model.uploadMomentImage(data: data, name: "moment-\(index + 1).\(ext)", mime: mime)
                newPreviews.append(image)
                newAttachments.append(attachment)
            }
            previews = newPreviews
            attachments = newAttachments
            errorText = nil
        } catch {
            errorText = "图片上传失败：\(error.localizedDescription)"
        }
    }

    @MainActor
    private func publish() async {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty || !attachments.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let post = try await model.createMoment(kind: kind, text: cleanText, attachments: attachments)
            onCreated(post)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - 日历

struct EchoCalendarView: View {
    @ObservedObject var model: AppModel
    @State private var selectedDate = Date()
    @State private var response: CalendarMonthResponse?
    @State private var isLoading = true
    @State private var showingCreate = false
    @State private var errorText: String?

    private var selectedKey: String { dateKey(selectedDate) }
    private var dayEvents: [CalendarEvent] { response?.events.filter { $0.date == selectedKey } ?? [] }
    private var holiday: String? { response?.holidays[selectedKey] }
    private var palette: EchoPalette { model.theme.palette }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                DatePicker("日期", selection: $selectedDate, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .padding(10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(dayTitle(selectedDate)).font(.title3.bold())
                            if let holiday { Text(holiday).font(.subheadline).foregroundStyle(palette.accent) }
                        }
                        Spacer()
                        Button { showingCreate = true } label: {
                            Label("添加", systemImage: "plus").font(.subheadline.weight(.semibold))
                        }
                    }

                    if isLoading && response == nil {
                        ProgressView().frame(maxWidth: .infinity).padding()
                    } else if dayEvents.isEmpty {
                        Text("这一天还没有安排。")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 18)
                    } else {
                        ForEach(dayEvents) { event in
                            CalendarEventRow(event: event, palette: palette) {
                                Task { await delete(event) }
                            }
                            if event.id != dayEvents.last?.id { Divider() }
                        }
                    }
                }
                .padding(16)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
            }
            .padding(14)
        }
        .navigationTitle("日历")
        .navigationBarTitleDisplayMode(.inline)
        .tint(palette.accent)
        .task { await loadMonth() }
        .onChange(of: monthKey(selectedDate)) { _ in Task { await loadMonth() } }
        .refreshable { await loadMonth() }
        .sheet(isPresented: $showingCreate) {
            CalendarComposer(model: model, date: selectedDate) { _ in
                Task { await loadMonth() }
            }
        }
        .overlay(alignment: .bottom) {
            if let errorText { SpaceErrorBanner(text: errorText) }
        }
    }

    @MainActor
    private func loadMonth() async {
        isLoading = true
        defer { isLoading = false }
        let values = Calendar.current.dateComponents([.year, .month], from: selectedDate)
        do {
            response = try await model.spaceCalendar(year: values.year ?? 2026, month: values.month ?? 1)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    @MainActor
    private func delete(_ event: CalendarEvent) async {
        do {
            try await model.deleteCalendarEvent(id: event.id)
            await loadMonth()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private struct CalendarEventRow: View {
    let event: CalendarEvent
    let palette: EchoPalette
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: event.kind == "anniversary" ? "heart.fill" : "calendar.badge.clock")
                .foregroundStyle(palette.accent)
                .frame(width: 30, height: 30)
                .background(palette.accent.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(event.title).font(.headline)
                HStack(spacing: 7) {
                    if !event.time.isEmpty { Text(event.time) }
                    if event.kind == "anniversary", let days = event.daysSince { Text("第 \(days) 天") }
                    if !event.visible { Label("仅自己", systemImage: "eye.slash") }
                    if event.remind { Image(systemName: "bell.fill") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if event.author == .human {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash").foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

private struct CalendarComposer: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var nativeEvents = NativeEventStore.shared
    let date: Date
    let onCreated: (CalendarEvent) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var eventDate: Date
    @State private var eventTime = Date()
    @State private var isAllDay = true
    @State private var isAnniversary = false
    @State private var isVisible = true
    @State private var shouldRemind = false
    @State private var isSaving = false
    @State private var isRequestingSystemAccess = false
    @State private var errorText: String?
    @AppStorage("tidalEcho.calendar.syncToSystemCalendar") private var syncToSystemCalendar = false
    @AppStorage("tidalEcho.calendar.addToSystemReminders") private var addToSystemReminders = false

    init(model: AppModel, date: Date, onCreated: @escaping (CalendarEvent) -> Void) {
        self.model = model
        self.date = date
        self.onCreated = onCreated
        _eventDate = State(initialValue: date)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("内容") {
                    TextField("要记住什么？", text: $title)
                    Toggle("纪念日", isOn: $isAnniversary)
                }
                Section("时间") {
                    DatePicker("日期", selection: $eventDate, displayedComponents: .date)
                    Toggle("全天", isOn: $isAllDay)
                    if !isAllDay {
                        DatePicker("时间", selection: $eventTime, displayedComponents: .hourAndMinute)
                    }
                }
                Section("分享与提醒") {
                    Toggle("让小克也能看到", isOn: $isVisible)
                    Toggle("提醒我", isOn: $shouldRemind)
                }
                Section {
                    Toggle("同时加入 iOS 日历", isOn: $syncToSystemCalendar)
                    Toggle("同时加入提醒事项", isOn: $addToSystemReminders)
                } header: {
                    Text("系统 App")
                } footer: {
                    Text("系统副本由你单独控制；Tidal Echo 不会读取已有日历内容。")
                }
                if isAnniversary {
                    Section { Text("纪念日会默认每年重复，并显示已经一起走过的天数。") }.font(.footnote).foregroundStyle(.secondary)
                }
                if let errorText { Section { Text(errorText).foregroundStyle(.red) } }
            }
            .navigationTitle("添加日程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await save() } }
                        .disabled(
                            title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || isSaving
                                || isRequestingSystemAccess
                        )
                }
            }
        }
        .tint(model.theme.palette.accent)
        .onChange(of: syncToSystemCalendar) { _, enabled in
            guard enabled else { return }
            Task { await ensureCalendarAccess() }
        }
        .onChange(of: addToSystemReminders) { _, enabled in
            guard enabled else { return }
            Task { await ensureReminderAccess() }
        }
    }

    @MainActor
    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let payload = CalendarCreatePayload(
            date: dateKey(eventDate),
            time: isAllDay ? "" : timeKey(eventTime),
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: isAnniversary ? "anniversary" : "event",
            visible: isVisible,
            remind: shouldRemind
        )
        do {
            let event = try await model.createCalendarEvent(payload)
            let nativeDraft = NativeScheduleDraft(
                title: payload.title,
                date: eventDate,
                time: eventTime,
                isAllDay: isAllDay,
                isAnniversary: isAnniversary,
                shouldRemind: shouldRemind
            )
            var nativeFailures: [String] = []
            if syncToSystemCalendar {
                do {
                    try nativeEvents.addCalendarEvent(nativeDraft)
                } catch {
                    nativeFailures.append("系统日历：\(error.localizedDescription)")
                }
            }
            if addToSystemReminders {
                do {
                    try nativeEvents.addReminder(nativeDraft)
                } catch {
                    nativeFailures.append("提醒事项：\(error.localizedDescription)")
                }
            }
            onCreated(event)
            dismiss()
            if !nativeFailures.isEmpty {
                model.errorMessage = "日程已保存到 Tidal Echo，但系统副本没有全部写入。\n" + nativeFailures.joined(separator: "\n")
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    @MainActor
    private func ensureCalendarAccess() async {
        isRequestingSystemAccess = true
        defer { isRequestingSystemAccess = false }
        guard await nativeEvents.requestCalendarAccess() else {
            syncToSystemCalendar = false
            errorText = "没有获得系统日历写入权限，可在系统设置里重新允许。"
            return
        }
        errorText = nil
    }

    @MainActor
    private func ensureReminderAccess() async {
        isRequestingSystemAccess = true
        defer { isRequestingSystemAccess = false }
        guard await nativeEvents.requestReminderAccess() else {
            addToSystemReminders = false
            errorText = "没有获得提醒事项权限，可在系统设置里重新允许。"
            return
        }
        errorText = nil
    }
}

// MARK: - Shared helpers

private struct SpaceRemoteImage: View {
    let request: URLRequest
    var contentMode: ContentMode = .fit
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.08)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if failed {
                Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .task(id: request.url) {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let loaded = UIImage(data: data) else {
                    failed = true
                    return
                }
                image = loaded
            } catch {
                failed = true
            }
        }
    }
}

private struct SpaceErrorBanner: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.red.opacity(0.9), in: Capsule())
            .padding(.bottom, 12)
            .padding(.horizontal)
    }
}

private func shortTimestamp(_ value: String) -> String {
    guard let date = serverDate(from: value) else {
        return value.replacingOccurrences(of: "T", with: " ").prefix(16).description
    }

    let zone = TimeZone(identifier: "Asia/Shanghai") ?? .current
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone

    let output = DateFormatter()
    output.calendar = calendar
    output.locale = Locale(identifier: "zh_Hans_CN")
    output.timeZone = zone
    output.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: Date())
        ? "M月d日 HH:mm"
        : "yyyy年M月d日 HH:mm"
    return output.string(from: date)
}

private func serverDate(from value: String) -> Date? {
    let precise = ISO8601DateFormatter()
    precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = precise.date(from: value) { return date }

    let standard = ISO8601DateFormatter()
    if let date = standard.date(from: value) { return date }

    let parser = DateFormatter()
    parser.calendar = Calendar(identifier: .gregorian)
    parser.locale = Locale(identifier: "en_US_POSIX")
    parser.timeZone = TimeZone(secondsFromGMT: 0)
    for format in [
        "yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
        "yyyy-MM-dd'T'HH:mm:ss.SSS",
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd HH:mm:ss"
    ] {
        parser.dateFormat = format
        if let date = parser.date(from: value) { return date }
    }
    return nil
}

private func dateKey(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

private func timeKey(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}

private func monthKey(_ date: Date) -> String {
    let values = Calendar.current.dateComponents([.year, .month], from: date)
    return "\(values.year ?? 0)-\(values.month ?? 0)"
}

private func dayTitle(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_Hans_CN")
    formatter.dateFormat = "M月d日 EEEE"
    return formatter.string(from: date)
}
