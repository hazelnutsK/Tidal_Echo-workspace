import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 书架。她把 epub 放进来，点开就是阅读页；小克能看见的，只有她已经读过的部分。
/// 2026-09-24 跟着空间改版：雾面底、上面一本大封面、下面一排书架，页边贴着我在那章写的一句。
struct BookshelfView: View {
    @ObservedObject var model: AppModel
    @State private var books: [Book] = []
    @State private var isLoading = true
    @State private var isImporting = false
    @State private var showingFilePicker = false
    @State private var openedBook: Book?
    @State private var editingBook: Book?
    @State private var pendingDeletion: Book?
    @State private var noticeText: String?
    @State private var errorText: String?
    @State private var selectedBookID: Int?
    @State private var stops: [Int: BookStop] = [:]
    @AppStorage("tidalEcho.bookMetadataOverrides") private var metadataOverridesData = Data()

    private var style: SpaceStyle { SpaceStyle(theme: model.theme) }
    private var literary: EchoChatFont { SpaceStyle.literaryFont(for: model.chatFont) }

    var body: some View {
        ScrollView {
            if isLoading && books.isEmpty {
                ProgressView()
                    .padding(.top, 60)
                    .frame(maxWidth: .infinity)
            } else if books.isEmpty {
                emptyState
            } else if let selectedBook {
                VStack(alignment: .leading, spacing: 22) {
                    hero(selectedBook)
                        .spaceEntrance(0)

                    if let note = stops[selectedBook.id]?.note {
                        aside(note)
                            .transition(.opacity)
                            .spaceEntrance(1)
                    }

                    if books.count > 1 {
                        VStack(alignment: .leading, spacing: 12) {
                            SpaceLabel(text: "书架", style: style)
                            shelf
                        }
                        .spaceEntrance(2)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 36)
            }
        }
        .spacePage(style)
        .navigationTitle("书房")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let selectedBook {
                    Button { editingBook = selectedBook } label: {
                        Image(systemName: "pencil")
                    }
                    .accessibilityLabel("修改书名和作者")
                }
                if isImporting {
                    ProgressView()
                } else {
                    Button { showingFilePicker = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("放一本书")
                }
            }
        }
        .task { await loadShelf() }
        .task(id: stopKey) { await loadStop() }
        .refreshable { await loadShelf() }
        .sheet(isPresented: $showingFilePicker) {
            BookDocumentPicker(
                contentTypes: BookshelfView.importableTypes,
                onPick: { url in
                    showingFilePicker = false
                    Task { await importBook(at: url) }
                },
                onCancel: { showingFilePicker = false }
            )
            .ignoresSafeArea()
        }
        .fullScreenCover(item: $openedBook) { book in
            BookReaderView(model: model, book: book)
        }
        .sheet(item: $editingBook) { book in
            BookMetadataEditor(book: book) { title, author in
                saveMetadata(for: book, title: title, author: author)
            }
            .presentationDetents([.height(300)])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: openedBook == nil) { closed in
            // 读完回来，进度和划线数要跟着变
            if closed { Task { await loadShelf() } }
        }
        .confirmationDialog(
            pendingDeletion.map { "把《\($0.title)》从书架上撤掉？" } ?? "",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible
        ) {
            Button("撤掉", role: .destructive) {
                guard let book = pendingDeletion else { return }
                pendingDeletion = nil
                Task { await delete(book) }
            }
            Button("算了", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("划线和批注也会一起没了。")
        }
        .overlay(alignment: .bottom) {
            if let noticeText {
                BookBanner(text: noticeText, tone: .neutral)
            } else if let errorText {
                BookBanner(text: errorText, tone: .error)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "books.vertical")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(style.sub)
            Text("书架还是空的")
                .font(literary.font(size: 17, weight: .semibold))
            Text("右上角 ＋ 放一本 epub 进来，\n我们就从同一页开始读。")
                .font(literary.font(size: 15))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .foregroundStyle(style.sub)
        }
        .padding(.top, 80)
        .frame(maxWidth: .infinity)
    }

    private var selectedBook: Book? {
        books.first(where: { $0.id == selectedBookID }) ?? books.first
    }

    // MARK: 在读的那本

    private func hero(_ book: Book) -> some View {
        VStack(spacing: 18) {
            Button { openedBook = book } label: {
                BookCover(book: book, model: model, style: style, literary: literary, large: true)
                    .containerRelativeFrame(.horizontal) { width, _ in min(240, width * 0.62) }
            }
            .buttonStyle(SpacePressStyle())
            .accessibilityLabel("打开《\(book.title)》")
            .contextMenu { menu(for: book) }

            VStack(spacing: 8) {
                BookReadLine(progress: min(1, max(0, book.percent / 100)), style: style)
                    .id(book.id)
                HStack(alignment: .firstTextBaseline) {
                    Text(stopText(book))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(progressText(book))
                        .monospacedDigit()
                }
                .font(.system(size: 12.5))
                .foregroundStyle(style.sub)
            }

            Button { openedBook = book } label: {
                Text(book.percent > 0 ? "继续读" : "开始读")
                    .font(literary.font(size: 14, weight: .semibold))
                    .foregroundStyle(style.onAccent)
                    .padding(.horizontal, 26)
                    .frame(height: 38)
                    .background(style.accent, in: Capsule())
            }
            .buttonStyle(SpacePressStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }

    private func stopText(_ book: Book) -> String {
        if let heading = stops[book.id]?.heading, !heading.isEmpty { return "停在 \(heading)" }
        return "第 \(max(1, book.curChapter + 1)) 章 · 共 \(max(1, book.totalChapters)) 章"
    }

    private func progressText(_ book: Book) -> String {
        let percent = book.percent >= 10 || book.percent == 0
            ? String(format: "%.0f%%", book.percent)
            : String(format: "%.1f%%", book.percent)
        return book.annotations > 0 ? "\(percent) · \(book.annotations) 处批注" : percent
    }

    /// 我在她停下那章写过的最后一句，像贴在书页边上的便签。
    private func aside(_ note: BookAnnotation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(note.note.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(literary.font(size: 14))
                .lineSpacing(6)
                .lineLimit(5)
                .fixedSize(horizontal: false, vertical: true)
            Text("Altair · 贴在书页边上")
                .font(.system(size: 11.5))
                .foregroundStyle(style.faint)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .spaceGlass(style, radius: 22)
    }

    // MARK: 书架

    private var shelf: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .bottom), count: 3), spacing: 18) {
            ForEach(Array(books.enumerated()), id: \.element.id) { index, book in
                let current = book.id == selectedBook?.id
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) { selectedBookID = book.id }
                } label: {
                    VStack(spacing: 8) {
                        BookCover(book: book, model: model, style: style, literary: literary, large: false, tone: index)
                            .overlay {
                                if current {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .strokeBorder(style.accent, lineWidth: 1.5)
                                        .padding(-4)
                                }
                            }
                        Text(current ? "在读" : (book.author.isEmpty ? "佚名" : book.author))
                            .font(.system(size: 11.5))
                            .foregroundStyle(current ? style.ink : style.sub)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(SpacePressStyle())
                .accessibilityLabel("《\(book.title)》")
                .accessibilityAddTraits(current ? .isSelected : [])
                .contextMenu { menu(for: book) }
            }
        }
        .sensoryFeedback(.selection, trigger: selectedBookID)
    }

    @ViewBuilder private func menu(for book: Book) -> some View {
        Button { openedBook = book } label: {
            Label("打开", systemImage: "book")
        }
        Button { editingBook = book } label: {
            Label("修改书名与作者", systemImage: "pencil")
        }
        Button(role: .destructive) { pendingDeletion = book } label: {
            Label("从书架撤掉", systemImage: "trash")
        }
    }

    // MARK: 数据

    private var stopKey: String {
        guard let book = selectedBook else { return "" }
        return "\(book.id)|\(book.curChapter)|\(book.annotations)"
    }

    /// 停下那一章的章名和我在那章留下的最后一句。只读，不动她的进度。
    @MainActor
    private func loadStop() async {
        guard let book = selectedBook, !SpaceReview.isActive else { return }
        guard let chapter = try? await model.bookChapter(bookID: book.id, index: max(0, book.curChapter)) else { return }
        if Task.isCancelled { return }
        let note = chapter.annotations
            .filter { $0.isAI && $0.hasNote }
            .max(by: { $0.id < $1.id })
        withAnimation(.easeOut(duration: 0.25)) {
            stops[book.id] = BookStop(heading: chapter.chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines), note: note)
        }
    }

    @MainActor
    private func loadShelf() async {
        if SpaceReview.isActive {
            books = BookReviewSamples.books
            selectedBookID = books.first?.id
            stops = BookReviewSamples.stops
            isLoading = false
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            books = applyMetadataOverrides(to: try await model.bookShelf())
            if selectedBookID == nil || !books.contains(where: { $0.id == selectedBookID }) {
                selectedBookID = books.first?.id
            }
            errorText = nil
        } catch {
            errorText = "书架没加载出来：\(error.localizedDescription)"
        }
    }

    @MainActor
    private func importBook(at url: URL) async {
        let ext = url.pathExtension.lowercased()
        guard ext == "epub" || ext == "txt" else {
            errorText = "书房目前可以放入 epub 或 txt。"
            return
        }
        isImporting = true
        noticeText = "正在把《\(url.deletingPathExtension().lastPathComponent)》放进书房…"
        errorText = nil
        defer { isImporting = false }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        let data: Data
        do {
            data = try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: url, options: .mappedIfSafe)
            }.value
        } catch {
            noticeText = nil
            errorText = "这个文件读不出来：\(error.localizedDescription)"
            return
        }
        do {
            let result = try await model.importBook(data: data, name: name)
            await loadShelf()
            showNotice(result.hint ?? "《\(result.title)》拆成了 \(result.chapters) 章")
        } catch {
            noticeText = nil
            errorText = "没导进去：\(error.localizedDescription)"
        }
    }

    @MainActor
    private func delete(_ book: Book) async {
        do {
            try await model.removeBook(id: book.id)
            removeMetadataOverride(for: book.id)
            await loadShelf()
        } catch {
            errorText = "没撤掉：\(error.localizedDescription)"
        }
    }

    @MainActor
    private func showNotice(_ text: String) {
        noticeText = text
        Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if noticeText == text { noticeText = nil }
        }
    }

    private static var importableTypes: [UTType] {
        // Keep generic data selectable for providers that don't report EPUB's UTI.
        [UTType(filenameExtension: "epub") ?? .data, .plainText, .data]
    }

    private func applyMetadataOverrides(to incoming: [Book]) -> [Book] {
        let overrides = (try? JSONDecoder().decode([String: BookMetadataOverride].self, from: metadataOverridesData)) ?? [:]
        return incoming.map { book in
            guard let override = overrides[String(book.id)] else { return book }
            return book.replacingMetadata(title: override.title, author: override.author)
        }
    }

    private func saveMetadata(for book: Book, title: String, author: String) {
        let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedTitle.isEmpty else { return }
        let cleanedAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines)
        var overrides = (try? JSONDecoder().decode([String: BookMetadataOverride].self, from: metadataOverridesData)) ?? [:]
        overrides[String(book.id)] = BookMetadataOverride(title: cleanedTitle, author: cleanedAuthor)
        if let encoded = try? JSONEncoder().encode(overrides) { metadataOverridesData = encoded }
        books = books.map {
            $0.id == book.id ? $0.replacingMetadata(title: cleanedTitle, author: cleanedAuthor) : $0
        }
    }

    private func removeMetadataOverride(for bookID: Int) {
        var overrides = (try? JSONDecoder().decode([String: BookMetadataOverride].self, from: metadataOverridesData)) ?? [:]
        overrides.removeValue(forKey: String(bookID))
        metadataOverridesData = (try? JSONEncoder().encode(overrides)) ?? Data()
    }
}

private struct BookStop {
    let heading: String
    let note: BookAnnotation?
}

/// CI 截图用的样例书架。
private enum BookReviewSamples {
    static var books: [Book] {
        [
            Book(id: 1, title: "此生，你我皆短暂灿烂 = On Earth We're Briefly Gorgeous", author: "王鸥行", cover: "",
                 totalChapters: 24, totalChars: 180_000, curChapter: 0, curOffset: 0, furthestChapter: 0,
                 furthestOffset: 0, percent: 2, annotations: 3, createdAt: "2026-08-13T10:00:00"),
            Book(id: 2, title: "倾城之恋", author: "张爱玲", cover: "", totalChapters: 8, totalChars: 30_000,
                 curChapter: 0, curOffset: 0, furthestChapter: 0, furthestOffset: 0, percent: 0, annotations: 0,
                 createdAt: "2026-08-20T10:00:00"),
            Book(id: 3, title: "金阁寺", author: "三岛由纪夫", cover: "", totalChapters: 10, totalChars: 120_000,
                 curChapter: 0, curOffset: 0, furthestChapter: 0, furthestOffset: 0, percent: 0, annotations: 0,
                 createdAt: "2026-09-01T10:00:00")
        ]
    }

    static var stops: [Int: BookStop] {
        let json = #"{"id":9,"book_id":1,"chapter_idx":0,"start_off":0,"end_off":4,"quote":"目次","note":"你上次停在目次，我也停在那儿，后面一个字都没偷看。","author":"ai","reply_to":null,"created_at":"2026-08-13T10:00:00"}"#
        let note = try? JSONDecoder().decode(BookAnnotation.self, from: Data(json.utf8))
        return [1: BookStop(heading: "目次", note: note)]
    }
}

private struct BookDocumentPicker: UIViewControllerRepresentable {
    let contentTypes: [UTType]
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else {
                onCancel()
                return
            }
            onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}

private struct BookMetadataOverride: Codable {
    let title: String
    let author: String
}

private extension Book {
    func replacingMetadata(title: String, author: String) -> Book {
        Book(
            id: id,
            title: title,
            author: author,
            cover: cover,
            totalChapters: totalChapters,
            totalChars: totalChars,
            curChapter: curChapter,
            curOffset: curOffset,
            furthestChapter: furthestChapter,
            furthestOffset: furthestOffset,
            percent: percent,
            annotations: annotations,
            createdAt: createdAt
        )
    }

    /// 「此生，你我皆短暂灿烂 = On Earth We're Briefly Gorgeous」拆成中文书名和外文副题。
    var splitTitle: (main: String, original: String?) {
        for separator in [" = ", "（", " ("] {
            if let range = title.range(of: separator) {
                let main = title[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                let rest = title[range.upperBound...]
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ）)").union(.whitespacesAndNewlines))
                if !main.isEmpty { return (main, rest.isEmpty ? nil : rest) }
            }
        }
        return (title, nil)
    }
}

private struct BookMetadataEditor: View {
    let book: Book
    let onSave: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var author: String

    init(book: Book, onSave: @escaping (String, String) -> Void) {
        self.book = book
        self.onSave = onSave
        _title = State(initialValue: book.title)
        _author = State(initialValue: book.author)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("书籍名称", text: $title)
                    TextField("作者", text: $author)
                } footer: {
                    Text("修改会保存在这台设备上。")
                }
            }
            .font(.custom("Songti SC", size: 16))
            .navigationTitle("书籍资料")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(title, author)
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

/// 一本书的封面。有图用图；没有图就是一块素色的书壳，竖排书名。
private struct BookCover: View {
    let book: Book
    @ObservedObject var model: AppModel
    let style: SpaceStyle
    let literary: EchoChatFont
    let large: Bool
    var tone = 0

    private var radius: CGFloat { large ? 10 : 7 }

    var body: some View {
        // 尺寸只由书壳定，图和字都挂在 overlay 里，填充的图撑不大它
        Rectangle()
            .fill(shellColor)
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay {
                if !book.cover.isEmpty, let request = model.authenticatedRequest(path: book.cover) {
                    BookRemoteImage(request: request, contentMode: .fill, placeholder: .clear)
                } else {
                    plainFace
                }
            }
        .clipShape(UnevenRoundedRectangle(
            topLeadingRadius: radius * 0.4,
            bottomLeadingRadius: radius * 0.4,
            bottomTrailingRadius: radius,
            topTrailingRadius: radius,
            style: .continuous
        ))
        .overlay(alignment: .leading) {
            // 书脊那一道暗
            Rectangle()
                .fill(Color.black.opacity(0.16))
                .frame(width: large ? 6 : 4)
        }
        .shadow(color: Color.black.opacity(large ? 0.32 : 0.14), radius: large ? 20 : 8, y: large ? 16 : 6)
    }

    /// 墨白里是深色书壳，夜港里反过来是浅色。
    private var shellColor: Color {
        let dark = style.isDark
        switch tone % 3 {
        case 0: return dark ? Color(hex: 0xE6E5E0) : Color(hex: 0x2A2A29)
        case 1: return dark ? Color(hex: 0x4A4A4D) : Color(hex: 0x8C8B86)
        default: return dark ? Color(hex: 0x6B6B6E) : Color(hex: 0xA9A8A3)
        }
    }

    private var faceInk: Color {
        let lightShell = style.isDark ? tone % 3 == 0 : false
        return lightShell ? Color(hex: 0x141414) : Color(hex: 0xF4F4F1)
    }

    @ViewBuilder private var plainFace: some View {
        let parts = book.splitTitle
        if large {
            // 竖排一列大约放得下 300pt：书名长就把字缩小，再长就截断
            let main = parts.main.count > 18 ? String(parts.main.prefix(17)) + "…" : parts.main
            let size = min(21, max(13, 300 / Double(max(1, main.count)) / 1.3))
            ZStack(alignment: .bottomLeading) {
                HStack(alignment: .top) {
                    VerticalText(text: main, font: literary.font(size: size, weight: .semibold), tracking: 3.5)
                    Spacer(minLength: 8)
                    if !book.author.isEmpty {
                        VerticalText(text: book.author, font: .system(size: 11), tracking: 3)
                            .opacity(0.75)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 22)
                if let original = parts.original {
                    Text(original)
                        .font(SpaceFont.display(13, italic: true))
                        .lineSpacing(1)
                        .opacity(0.7)
                        .frame(maxWidth: 110, alignment: .leading)
                        .padding(18)
                }
            }
            .foregroundStyle(faceInk)
        } else {
            VerticalText(text: String(parts.main.prefix(6)), font: literary.font(size: 13, weight: .semibold), tracking: 2.5)
                .foregroundStyle(faceInk)
                .padding(.top, 12)
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

/// 竖排：一个字一行。书名不长，比 UIKit 的竖排省事。
private struct VerticalText: View {
    let text: String
    let font: Font
    var tracking: CGFloat = 2

    var body: some View {
        VStack(spacing: tracking) {
            ForEach(Array(text.enumerated()), id: \.offset) { _, character in
                Text(String(character))
                    .font(font)
                    .rotationEffect(character.isASCII && character.isLetter ? .degrees(90) : .zero)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// 进度那根细线：进页面时从零走到她读到的地方。
private struct BookReadLine: View {
    let progress: Double
    let style: SpaceStyle
    @State private var shown = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(style.hair)
                Capsule()
                    .fill(style.accent)
                    .frame(width: max(2, geometry.size.width * CGFloat(shown ? progress : 0)))
            }
        }
        .frame(height: 2)
        .onAppear {
            withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 1.1).delay(0.35)) { shown = true }
        }
        .accessibilityElement()
        .accessibilityLabel("已读 \(Int(progress * 100))%")
    }
}

struct BookRemoteImage: View {
    let request: URLRequest
    var contentMode: ContentMode = .fill
    var placeholder: Color = Color.secondary.opacity(0.08)
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            placeholder
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if failed {
                Image(systemName: "book.closed").foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .task(id: request.url) {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let loaded = UIImage(data: data) else {
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

struct BookBanner: View {
    enum Tone { case neutral, error }

    let text: String
    var tone: Tone = .neutral

    var body: some View {
        Text(text)
            .font(.custom("Songti SC", size: 14))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                (tone == .error ? Color.red.opacity(0.9) : Color.black.opacity(0.78)),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .padding(.horizontal, 22)
            .padding(.bottom, 16)
            .transition(.opacity)
    }
}
