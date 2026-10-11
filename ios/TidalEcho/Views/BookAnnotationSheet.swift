import SwiftUI

/// 页边的卡片，两副面孔：
/// composing = true  → 刚划完线，写的是留在这一句旁边的批注（她写了字，小克会被叫醒）
/// composing = false → 点开已有划线或整本书的对话，写的是发进主聊天流的话，
///                     带书签，小克的回复会自动浮回这一页
struct BookAnnotationSheet: View {
    @ObservedObject var model: AppModel
    let book: Book
    let chapterIdx: Int
    let chapterTitle: String
    let context: BookSheetContext
    let onAnnotationSaved: (BookAnnotation) -> Void
    let onAnnotationDeleted: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("tidalEcho.readerNoteFontSize") private var noteFontSize = 16.0
    @AppStorage("tidalEcho.readerDarkMode") private var readerDarkMode = false
    @State private var group: [BookAnnotation]
    @State private var thread: [ChatMessage]?
    @State private var draft = ""
    @State private var isSubmitting = false
    @State private var errorText: String?
    @State private var pendingDeletion: BookAnnotation?
    @FocusState private var isDraftFocused: Bool

    init(
        model: AppModel,
        book: Book,
        chapterIdx: Int,
        chapterTitle: String,
        context: BookSheetContext,
        onAnnotationSaved: @escaping (BookAnnotation) -> Void,
        onAnnotationDeleted: @escaping (Int) -> Void
    ) {
        self.model = model
        self.book = book
        self.chapterIdx = chapterIdx
        self.chapterTitle = chapterTitle
        self.context = context
        self.onAnnotationSaved = onAnnotationSaved
        self.onAnnotationDeleted = onAnnotationDeleted
        _group = State(initialValue: context.group)
    }

    private var colors: ReaderBookColors { ReaderBookColors(isDark: readerDarkMode) }
    private var annotationIDs: [Int] { group.map(\.id) }
    /// 新消息挂在她最早那条划线上（没有就挂整本书）
    private var anchorAnnotationID: Int? {
        group.first(where: { !$0.isAI })?.id ?? group.first?.id
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if let quote = context.selection?.quote, !quote.isEmpty {
                            Text(quote)
                                .font(.custom("Songti SC", size: noteFontSize))
                                .foregroundStyle(colors.text)
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(colors.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(alignment: .leading) {
                                    Rectangle().fill(colors.accent.opacity(0.55)).frame(width: 3)
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }

                        ForEach(rootAnnotations) { annotation in
                            AnnotationRow(
                                annotation: annotation,
                                colors: colors,
                                fontSize: noteFontSize,
                                isReply: false
                            ) {
                                pendingDeletion = annotation
                            }
                            ForEach(replies(of: annotation)) { reply in
                                AnnotationRow(
                                    annotation: reply,
                                    colors: colors,
                                    fontSize: noteFontSize,
                                    isReply: true
                                ) {
                                    pendingDeletion = reply
                                }
                            }
                        }

                        if !context.composing {
                            Text("就着这句话说的")
                                .font(.custom("Songti SC", size: 13))
                                .foregroundStyle(colors.secondaryText)
                                .padding(.top, 2)

                            if thread == nil {
                                HStack {
                                    ProgressView()
                                    Text("正在拿…")
                                        .font(.custom("Songti SC", size: 14))
                                        .foregroundStyle(colors.secondaryText)
                                }
                            } else if thread?.isEmpty == true {
                                Text("还没说过话。在下面说一句，他会收到。")
                                    .font(.custom("Songti SC", size: 14))
                                    .foregroundStyle(colors.secondaryText)
                            } else {
                                ForEach(thread ?? []) { message in
                                    ThreadRow(message: message, colors: colors, fontSize: noteFontSize)
                                }
                            }
                        }
                    }
                    .padding(16)
                }

                composer
            }
            .background(colors.background.ignoresSafeArea())
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(context.composing ? "写在页边" : (context.selection?.quote.isEmpty == false ? "这一句" : "《\(book.title)》"))
                        .font(.custom("Songti SC", size: 16).weight(.semibold))
                        .foregroundStyle(colors.text)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .font(.custom("Songti SC", size: 16))
                        .foregroundStyle(colors.accent)
                }
            }
            .overlay(alignment: .bottom) {
                if let errorText { BookBanner(text: errorText, tone: .error).padding(.bottom, 66) }
            }
        }
        .tint(colors.accent)
        .preferredColorScheme(readerDarkMode ? .dark : .light)
        .task {
            if context.composing {
                isDraftFocused = true
            } else {
                await loadThread()
            }
        }
        .onChange(of: model.messages.last?.id ?? 0) { _ in
            guard !context.composing else { return }
            Task { await loadThread() }
        }
        .confirmationDialog(
            "把这条划线撤掉？",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("撤掉", role: .destructive) {
                guard let annotation = pendingDeletion else { return }
                pendingDeletion = nil
                Task { await delete(annotation) }
            }
            Button("算了", role: .cancel) { pendingDeletion = nil }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(
                context.composing ? "写在这句话旁边…" : "说点什么…",
                text: $draft,
                axis: .vertical
            )
            .lineLimit(1...5)
            .font(.custom("Songti SC", size: noteFontSize))
            .foregroundStyle(colors.text)
            .textFieldStyle(.plain)
            .focused($isDraftFocused)
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(colors.composer, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            Button {
                Task { await submit() }
            } label: {
                if isSubmitting {
                    ProgressView()
                } else {
                    Image(systemName: context.composing ? "pencil.and.scribble" : "paperplane.fill")
                        .font(.body.weight(.semibold))
                }
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
            .frame(width: 38, height: 38)
            .background(colors.accent.opacity(0.16), in: Circle())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    /// 纯划线（没写字）也要列出来——不然她想撤掉一条只划了线的，卡片上根本没有它。
    private var rootAnnotations: [BookAnnotation] {
        group.filter { annotation in
            annotation.replyTo == nil || !group.contains { $0.id == annotation.replyTo }
        }
    }

    private func replies(of annotation: BookAnnotation) -> [BookAnnotation] {
        group.filter { $0.replyTo == annotation.id }
    }

    @MainActor
    private func loadThread() async {
        do {
            thread = try await model.bookThread(bookID: book.id, annotationIDs: annotationIDs)
        } catch {
            thread = []
        }
    }

    @MainActor
    private func submit() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        isSubmitting = true
        defer { isSubmitting = false }

        if context.composing {
            guard let selection = context.selection else { return }
            do {
                let annotation = try await model.annotateBook(
                    bookID: book.id,
                    chapterIdx: chapterIdx,
                    start: selection.start,
                    end: selection.end,
                    quote: selection.quote,
                    note: text
                )
                onAnnotationSaved(annotation)
                draft = ""
                dismiss()
            } catch {
                errorText = "没存上：\(error.localizedDescription)"
            }
            return
        }

        let reference = BookRef(
            bookID: book.id,
            chapterIdx: chapterIdx,
            annID: anchorAnnotationID,
            quote: String((context.selection?.quote ?? "").prefix(200)),
            title: chapterTitle
        )
        do {
            try await model.sendFromBook(text: text, bookRef: reference)
            draft = ""
            await loadThread()
        } catch {
            errorText = "没发出去：\(error.localizedDescription)"
        }
    }

    @MainActor
    private func delete(_ annotation: BookAnnotation) async {
        do {
            try await model.deleteBookAnnotation(id: annotation.id)
            group.removeAll { $0.id == annotation.id }
            onAnnotationDeleted(annotation.id)
            // 这一处的划线都撤光了，卡片也就没什么可停留的了
            if group.isEmpty { dismiss() }
        } catch {
            errorText = "没撤掉：\(error.localizedDescription)"
        }
    }
}

private struct AnnotationRow: View {
    let annotation: BookAnnotation
    let colors: ReaderBookColors
    let fontSize: Double
    let isReply: Bool
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Text(annotation.isAI ? "Altair" : "我")
                .font(.custom("Songti SC", size: max(11, fontSize - 4)).weight(.semibold))
                .foregroundStyle(annotation.isAI ? Color.orange : colors.accent)
                .frame(width: 46, alignment: .leading)

            if annotation.hasNote {
                Text(annotation.note)
                    .font(.custom("Songti SC", size: fontSize))
                    .foregroundStyle(colors.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("只划了线")
                    .font(.custom("Songti SC", size: max(12, fontSize - 3)))
                    .italic()
                    .foregroundStyle(colors.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !annotation.isAI {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: max(13, fontSize - 3)))
                        .foregroundStyle(colors.secondaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, isReply ? 20 : 0)
    }
}

private struct ThreadRow: View {
    let message: ChatMessage
    let colors: ReaderBookColors
    let fontSize: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(message.author == .ai ? "Altair" : "我") · \(shortTime(message.timestamp))")
                .font(.custom("Songti SC", size: max(11, fontSize - 5)))
                .foregroundStyle(colors.secondaryText)
            Text(message.text)
                .font(.custom("Songti SC", size: fontSize))
                .foregroundStyle(colors.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    (message.author == .ai ? colors.aiBubble : colors.humanBubble),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
        }
    }

    private func shortTime(_ value: String) -> String {
        let trimmed = value.replacingOccurrences(of: "T", with: " ")
        guard trimmed.count >= 16 else { return trimmed }
        return String(trimmed.prefix(16).suffix(11))
    }
}

private struct ReaderBookColors {
    let isDark: Bool

    var background: Color { isDark ? .black : Color(hex: 0xEEEDED) }
    var text: Color { isDark ? .white : .black }
    var secondaryText: Color { text.opacity(0.56) }
    var accent: Color { isDark ? .white : .black }
    var composer: Color { isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.06) }
    var aiBubble: Color { isDark ? Color.white.opacity(0.10) : Color.white.opacity(0.72) }
    var humanBubble: Color { isDark ? Color.white.opacity(0.16) : Color.black.opacity(0.08) }
}
