import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 书架。她把 epub 放进来，点开就是阅读页；小克能看见的，只有她已经读过的部分。
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
    @AppStorage("tidalEcho.bookMetadataOverrides") private var metadataOverridesData = Data()

    private var palette: EchoPalette { model.theme.palette }

    var body: some View {
        ScrollView {
            if isLoading && books.isEmpty {
                ProgressView().padding(.top, 60)
            } else if books.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    bookCarousel
                    pageDots
                        .padding(.top, 15)

                    if let selectedBook {
                        Text(selectedBook.title)
                            .font(.custom("Songti SC", size: 23).weight(.semibold))
                            .foregroundStyle(palette.text)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28)
                            .padding(.top, 17)

                        Text(selectedBook.author.isEmpty ? "佚名" : selectedBook.author)
                            .font(.custom("Songti SC", size: 14))
                            .foregroundStyle(palette.secondaryText)
                            .lineLimit(1)
                            .padding(.top, 7)

                        BookProgressCard(book: selectedBook, palette: palette) {
                            openedBook = selectedBook
                        }
                        .padding(.horizontal, 22)
                        .padding(.top, 32)
                    }
                }
                .padding(.bottom, 30)
            }
        }
        .background {
            if model.theme == .mist {
                Color.white.ignoresSafeArea()
            } else {
                palette.background.ignoresSafeArea()
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("书房")
                    .font(.custom("Songti SC", size: 17).weight(.semibold))
                    .foregroundStyle(palette.text)
            }
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
                }
            }
        }
        .tint(palette.accent)
        .task { await loadShelf() }
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
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(palette.accent.opacity(0.7))
            Text("书架还是空的")
                .font(.custom("Songti SC", size: 17).weight(.semibold))
            Text("右上角 ＋ 放一本 epub 进来，\n我们就从同一页开始读。")
                .font(.custom("Songti SC", size: 15))
                .multilineTextAlignment(.center)
                .foregroundStyle(palette.secondaryText)
        }
        .padding(.top, 80)
        .frame(maxWidth: .infinity)
    }

    private var selectedBook: Book? {
        books.first(where: { $0.id == selectedBookID }) ?? books.first
    }

    private var bookCarousel: some View {
        GeometryReader { geometry in
            let coverWidth = min(geometry.size.width * 0.64, 270)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 22) {
                    ForEach(books) { book in
                        Button { openedBook = book } label: {
                            BookCoverPage(book: book, model: model, palette: palette)
                                .frame(width: coverWidth)
                        }
                        .buttonStyle(.plain)
                        .id(book.id)
                        .contextMenu {
                            Button { editingBook = book } label: {
                                Label("修改书名与作者", systemImage: "pencil")
                            }
                            Button(role: .destructive) { pendingDeletion = book } label: {
                                Label("从书架撤掉", systemImage: "trash")
                            }
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, max(22, (geometry.size.width - coverWidth) / 2), for: .scrollContent)
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
            .scrollPosition(id: $selectedBookID)
        }
        .frame(height: 350)
        .padding(.top, 18)
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(books) { book in
                Capsule(style: .continuous)
                    .fill(book.id == selectedBook?.id ? palette.text.opacity(0.74) : palette.secondaryText.opacity(0.24))
                    .frame(width: book.id == selectedBook?.id ? 18 : 5, height: 5)
                    .animation(.easeOut(duration: 0.18), value: selectedBookID)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("第 \((books.firstIndex(where: { $0.id == selectedBook?.id }) ?? 0) + 1) 本，共 \(books.count) 本")
    }

    @MainActor
    private func loadShelf() async {
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

private struct BookCoverPage: View {
    let book: Book
    @ObservedObject var model: AppModel
    let palette: EchoPalette

    var body: some View {
        ZStack {
            if !book.cover.isEmpty, let request = model.authenticatedRequest(path: book.cover) {
                BookRemoteImage(request: request, contentMode: .fit)
                    .background(Color.white.opacity(0.76))
            } else {
                ZStack {
                    LinearGradient(
                        colors: [palette.accent.opacity(0.24), palette.backgroundTop.opacity(0.94)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    VStack(spacing: 16) {
                        Image(systemName: "book.closed")
                            .font(.system(size: 27, weight: .light))
                            .foregroundStyle(palette.secondaryText)
                        Text(book.title)
                            .font(.custom("Songti SC", size: 20).weight(.semibold))
                            .foregroundStyle(palette.text)
                            .multilineTextAlignment(.center)
                            .lineLimit(5)
                    }
                    .padding(24)
                }
            }
        }
        .frame(height: 338)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.56), lineWidth: 0.7))
        .shadow(color: Color.black.opacity(0.13), radius: 17, y: 9)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityLabel("打开《\(book.title)》")
    }
}

private struct BookProgressCard: View {
    let book: Book
    let palette: EchoPalette
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 15) {
            HStack(alignment: .firstTextBaseline) {
                Text(chapterText)
                    .font(.custom("Songti SC", size: 15).weight(.semibold))
                    .foregroundStyle(palette.text)
                Spacer()
                Text("已读 \(percentText)")
                    .font(.custom("Songti SC", size: 13))
                    .foregroundStyle(palette.secondaryText)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.secondaryText.opacity(0.13))
                    Capsule()
                        .fill(palette.text.opacity(0.62))
                        .frame(width: geometry.size.width * CGFloat(progress))
                }
            }
            .frame(height: 4)

            HStack {
                Text("共读 · \(book.annotations) 处批注")
                    .font(.custom("Songti SC", size: 13))
                    .foregroundStyle(palette.secondaryText)
                Spacer()
                Button(action: onContinue) {
                    Text(book.percent > 0 ? "继续阅读" : "开始阅读")
                        .font(.custom("Songti SC", size: 14).weight(.semibold))
                        .foregroundStyle(palette.background)
                        .padding(.horizontal, 22)
                        .frame(height: 42)
                        .background(palette.text.opacity(0.82), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .background(
            palette.composer.opacity(0.72),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.42), lineWidth: 0.7)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 16, y: 7)
    }

    private var progress: Double {
        min(1, max(0, book.percent / 100))
    }

    private var percentText: String {
        String(format: "%.1f%%", book.percent)
    }

    private var chapterText: String {
        "第 \(max(1, book.curChapter + 1)) 章 · 共 \(max(1, book.totalChapters)) 章"
    }
}

struct BookRemoteImage: View {
    let request: URLRequest
    var contentMode: ContentMode = .fill
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
