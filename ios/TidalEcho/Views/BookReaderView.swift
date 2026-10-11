import SwiftUI
import UIKit

/// 阅读页。位置 (章, 章内字符偏移) 节流上报给 relay：cur 跟着她走，furthest 只涨不落——
/// 小克能看见的书文就切在 furthest 上，所以这里报得准不准，直接决定他会不会剧透自己。
struct BookReaderView: View {
    @ObservedObject var model: AppModel
    let book: Book

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("tidalEcho.readerFontSize") private var readerFontSize = 18.0
    @AppStorage("tidalEcho.readerLineSpacing") private var readerLineSpacing = 0.62
    @AppStorage("tidalEcho.readerMargin") private var readerMargin = 18.0
    @AppStorage("tidalEcho.readerNoteFontSize") private var readerNoteFontSize = 16.0
    @AppStorage("tidalEcho.readerFontWeight") private var readerFontWeight = 400.0
    @AppStorage("tidalEcho.readerDarkMode") private var readerDarkMode = false

    @State private var showingReaderSettings = false
    @State private var chapter: BookChapter?
    @State private var annotations: [BookAnnotation] = []
    @State private var percent: Double
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var sheetContext: BookSheetContext?
    @State private var restoreOffset: Int?
    /// 视口位置每帧都在动，塞进 @State 会让整页跟着滚动重算——用一个引用类型接着，
    /// 由 5 秒一次的 tick 去读。
    @State private var tracker = ReaderProgressTracker()
    @State private var reportedOffset = -1
    @State private var reportedAt = Date.distantPast
    @State private var flashText: String?
    @State private var flashRef: BookRef?
    @State private var hasUnreadChat = false
    @State private var lastSeenMessageID = 0
    @State private var footerShowsPercent = false

    private let reportInterval: TimeInterval = 30
    private let reportChars = 500

    init(model: AppModel, book: Book) {
        self.model = model
        self.book = book
        _percent = State(initialValue: book.percent)
    }

    private var readerBackground: Color { readerDarkMode ? .black : Color(hex: 0xEEEDED) }
    private var readerText: Color { readerDarkMode ? .white : .black }
    private var readerSecondaryText: Color { readerText.opacity(0.56) }
    private var readerAccent: Color { readerDarkMode ? .white : .black }

    var body: some View {
        ZStack(alignment: .top) {
            readerBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Divider().opacity(0.4)

                if let chapter {
                    ReaderTextView(
                        text: chapter.text,
                        charCount: chapter.charCount,
                        annotations: annotations,
                        fontSize: readerFontSize,
                        fontWeight: readerFontWeight,
                        lineSpacing: readerLineSpacing,
                        margin: readerMargin,
                        textColor: UIColor(readerText),
                        herHighlight: UIColor(readerAccent.opacity(0.18)),
                        aiHighlight: UIColor(Color.orange.opacity(0.26)),
                        scrollToOffset: restoreOffset,
                        onVisibleOffset: { offset in tracker.offset = offset },
                        onMark: { start, end, quote in
                            Task { await saveAnnotation(start: start, end: end, quote: quote, note: "") }
                        },
                        onAnnotate: { start, end, quote in
                            sheetContext = BookSheetContext(
                                selection: BookSelection(start: start, end: end, quote: quote),
                                group: [],
                                composing: true
                            )
                        },
                        onTapAnnotations: { group in
                            guard let first = group.first else { return }
                            sheetContext = BookSheetContext(
                                selection: BookSelection(start: first.startOff, end: first.endOff, quote: first.quote),
                                group: group,
                                composing: false
                            )
                        }
                    )
                    .id(chapter.chapterIdx)
                } else if isLoading {
                    Spacer()
                    ProgressView()
                    Spacer()
                } else {
                    Spacer()
                    Text("这一章没打开")
                        .font(.custom("Songti SC", size: 16))
                        .foregroundStyle(readerSecondaryText)
                    Spacer()
                }

                footer
            }
        }
        .overlay(alignment: .bottom) {
            if let flashText {
                Button {
                    openFlash()
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Altair")
                            .font(.custom("Songti SC", size: 13).weight(.semibold))
                            .foregroundStyle(readerAccent)
                        Text(flashText)
                            .font(.custom("Songti SC", size: 14))
                            .foregroundStyle(readerText)
                            .lineLimit(3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(13)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 74)
                }
                .buttonStyle(.plain)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let errorText {
                BookBanner(text: errorText, tone: .error).padding(.bottom, 60)
            }
        }
        .sheet(item: $sheetContext) { context in
            BookAnnotationSheet(
                model: model,
                book: book,
                chapterIdx: chapter?.chapterIdx ?? 0,
                chapterTitle: chapter?.title ?? book.title,
                context: context,
                onAnnotationSaved: { annotation in
                    if !annotations.contains(where: { $0.id == annotation.id }) {
                        annotations.append(annotation)
                    }
                },
                onAnnotationDeleted: { id in
                    annotations.removeAll { $0.id == id }
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingReaderSettings) {
            ReaderSettingsSheet(
                fontSize: $readerFontSize,
                fontWeight: $readerFontWeight,
                lineSpacing: $readerLineSpacing,
                margin: $readerMargin,
                noteFontSize: $readerNoteFontSize,
                darkMode: $readerDarkMode
            )
            .presentationDetents([.height(520)])
            .presentationDragIndicator(.visible)
        }
        .task {
            lastSeenMessageID = model.messages.last?.id ?? 0
            await loadChapter(index: book.curChapter, restoreTo: book.curOffset)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { break }
                await report(force: false)
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active { Task { await report(force: true) } }
        }
        .onChange(of: model.messages.last?.id ?? 0) { _ in noticeIncomingChat() }
        .onChange(of: model.incomingBookAnnotation) { _ in absorbAIAnnotation() }
        .statusBarHidden(false)
        .preferredColorScheme(readerDarkMode ? .dark : .light)
    }

    // MARK: - 顶栏 / 底栏

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                Task {
                    await report(force: true)
                    dismiss()
                }
            } label: {
                Image(systemName: "chevron.left").font(.body.weight(.semibold))
            }

            Text(book.title)
                .font(.custom("Songti SC", size: 16).weight(.semibold))
                .lineLimit(1)

            Spacer(minLength: 6)

            Button { showingReaderSettings = true } label: {
                Image(systemName: "gearshape")
            }

            Button {
                hasUnreadChat = false
                flashText = nil
                sheetContext = BookSheetContext(selection: nil, group: [], composing: false)
            } label: {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .overlay(alignment: .topTrailing) {
                        if hasUnreadChat {
                            Circle().fill(Color.red).frame(width: 7, height: 7).offset(x: 4, y: -3)
                        }
                    }
            }
        }
        .font(.custom("Songti SC", size: 16))
        .foregroundStyle(readerText)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                Task { await goChapter(-1) }
            } label: {
                Label("上一章", systemImage: "chevron.left")
                    .font(.custom("Songti SC", size: 14))
            }
            .disabled((chapter?.chapterIdx ?? 0) <= 0)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button { footerShowsPercent.toggle() } label: {
                Text(footerProgressText)
                    .font(.custom("Songti SC", size: 13))
                    .monospacedDigit()
                    .foregroundStyle(readerSecondaryText)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)

            Button {
                Task { await goChapter(1) }
            } label: {
                Label("下一章", systemImage: "chevron.right")
                    .labelStyle(.titleAndIcon)
                    .font(.custom("Songti SC", size: 14))
            }
            .disabled(chapter.map { $0.chapterIdx >= $0.totalChapters - 1 } ?? true)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .tint(readerAccent)
        .padding(.horizontal, 22)
        .padding(.vertical, 11)
        .background(.ultraThinMaterial)
    }

    private var footerProgressText: String {
        guard let chapter else { return "—" }
        if footerShowsPercent { return "\(Int(percent.rounded()))%" }
        return "第\(chineseNumber(chapter.chapterIdx + 1))章·共\(chineseNumber(chapter.totalChapters))章"
    }

    private func chineseNumber(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    // MARK: - 章节

    @MainActor
    private func loadChapter(index: Int, restoreTo offset: Int?) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await model.bookChapter(bookID: book.id, index: index)
            chapter = loaded
            annotations = loaded.annotations
            restoreOffset = offset
            tracker.offset = offset ?? 0
            reportedOffset = offset ?? 0
            reportedAt = Date()
            errorText = nil
        } catch {
            errorText = "这一章没打开：\(error.localizedDescription)"
        }
    }

    @MainActor
    private func goChapter(_ delta: Int) async {
        guard let current = chapter else { return }
        let next = current.chapterIdx + delta
        guard next >= 0, next < current.totalChapters else { return }
        await report(force: true)                       // 走之前把这一章的位置钉住
        await loadChapter(index: next, restoreTo: 0)
        reportedOffset = -1
        await report(force: true)                       // 翻页立刻报：上一章因此被判定读完
    }

    // MARK: - 进度上报

    @MainActor
    private func report(force: Bool) async {
        guard let chapter else { return }
        let offset = tracker.offset
        if !force,
           abs(offset - reportedOffset) < reportChars,
           Date().timeIntervalSince(reportedAt) < reportInterval {
            return
        }
        reportedOffset = offset
        reportedAt = Date()
        do {
            let response = try await model.reportBookProgress(
                bookID: book.id, chapter: chapter.chapterIdx, offset: offset
            )
            percent = response.percent
        } catch {
            // 上报失败不打扰她读书，下一次 tick 会补上
        }
    }

    // MARK: - 划线

    @MainActor
    private func saveAnnotation(start: Int, end: Int, quote: String, note: String) async {
        guard let chapter else { return }
        do {
            let annotation = try await model.annotateBook(
                bookID: book.id,
                chapterIdx: chapter.chapterIdx,
                start: start,
                end: end,
                quote: quote,
                note: note
            )
            annotations.append(annotation)
        } catch {
            errorText = "没存上：\(error.localizedDescription)"
        }
    }

    // MARK: - 他在聊天里说话 / 在页边留字

    private func noticeIncomingChat() {
        guard let latest = model.messages.last,
              latest.author == .ai,
              latest.kind == "reply",
              latest.id > lastSeenMessageID else { return }
        lastSeenMessageID = latest.id
        hasUnreadChat = true
        flashRef = latest.meta.bookRef
        flashText = String(latest.text.prefix(140))
        let shown = flashText
        Task {
            try? await Task.sleep(nanoseconds: 9_000_000_000)
            if flashText == shown { flashText = nil }
        }
    }

    private func openFlash() {
        flashText = nil
        hasUnreadChat = false
        // 这条挂在某句划线上 → 直接开那句的卡片
        if let annID = flashRef?.annID,
           let hit = annotations.first(where: { $0.id == annID }) {
            let group = annotations.filter { $0.endOff > hit.startOff && $0.startOff < hit.endOff }
            restoreOffset = hit.startOff
            sheetContext = BookSheetContext(
                selection: BookSelection(start: hit.startOff, end: hit.endOff, quote: hit.quote),
                group: group,
                composing: false
            )
        } else {
            sheetContext = BookSheetContext(selection: nil, group: [], composing: false)
        }
    }

    private func absorbAIAnnotation() {
        guard let event = model.incomingBookAnnotation,
              event.bookID == book.id,
              let chapter,
              event.annotation.chapterIdx == chapter.chapterIdx,
              !annotations.contains(where: { $0.id == event.annotation.id }) else { return }
        annotations.append(event.annotation)
    }
}

// MARK: - 版式

/// 读多久舒服，只有她自己知道——四根拉条都存在本机，换书换章都还在。
private struct ReaderSettingsSheet: View {
    @Binding var fontSize: Double
    @Binding var fontWeight: Double
    @Binding var lineSpacing: Double
    @Binding var margin: Double
    @Binding var noteFontSize: Double
    @Binding var darkMode: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Picker("阅读模式", selection: $darkMode) {
                    Text("日间").tag(false)
                    Text("夜间").tag(true)
                }
                .pickerStyle(.segmented)

                slider(
                    title: "正文字号",
                    value: $fontSize,
                    range: 14...28,
                    step: 1,
                    caption: "\(Int(fontSize))"
                )
                slider(
                    title: "正文字重",
                    value: $fontWeight,
                    range: 300...700,
                    step: 25,
                    caption: "\(Int(fontWeight))"
                )
                slider(
                    title: "行间距",
                    value: $lineSpacing,
                    range: 0.2...1.4,
                    step: 0.02,
                    caption: String(format: "%.2f 倍", lineSpacing)
                )
                slider(
                    title: "页边留白",
                    value: $margin,
                    range: 8...52,
                    step: 2,
                    caption: "\(Int(margin))"
                )
                slider(
                    title: "批注与回复字号",
                    value: $noteFontSize,
                    range: 13...24,
                    step: 1,
                    caption: "\(Int(noteFontSize))"
                )

                Text("这一句是用当前正文字号排的，看着累就再调。")
                    .font(ReaderSongtiFont.font(size: fontSize, weight: fontWeight))
                    .foregroundStyle(Color.black.opacity(0.58))
                    .lineSpacing(fontSize * lineSpacing)
                    .padding(.horizontal, max(0, margin - 14))
                    .padding(.top, 2)

                Spacer(minLength: 0)
            }
            .padding(20)
            .background(Color(hex: 0xEEEDED).ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("版式")
                        .font(.custom("Songti SC", size: 16).weight(.semibold))
                        .foregroundStyle(Color.black)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("好") { dismiss() }
                        .font(.custom("Songti SC", size: 16))
                        .foregroundStyle(Color.black)
                }
            }
        }
        .tint(.black)
        .preferredColorScheme(.light)
    }

    private func slider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        caption: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.custom("Songti SC", size: 15)).foregroundStyle(Color.black)
                Spacer()
                Text(caption)
                    .font(.custom("Songti SC", size: 13))
                    .monospacedDigit()
                    .foregroundStyle(Color.black.opacity(0.55))
            }
            Slider(value: value, in: range, step: step)
                .tint(.black)
        }
    }
}

// MARK: - 选中与卡片上下文

struct BookSelection: Hashable {
    let start: Int
    let end: Int
    let quote: String
}

/// 滚动位置的落脚点：它不参与 SwiftUI 的比较与刷新，只是被 tick 读一眼。
/// 读写都发生在主线程（UITextView 的 delegate 与视图的 tick）。
final class ReaderProgressTracker {
    var offset = 0
}

struct BookSheetContext: Identifiable {
    let id = UUID()
    let selection: BookSelection?
    let group: [BookAnnotation]
    /// true = 刚划完线要写批注（写的是留在页边的字）；
    /// false = 点开已有划线或整本书的对话（写的是发进聊天流的话）
    let composing: Bool
}
