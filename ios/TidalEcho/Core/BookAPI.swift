import Foundation

/// 书房走的都是她的端点（不 clamp）。小克那侧的 `/app/book/ai/*` 不在这里，
/// 手机端也不该碰——它只吐她读过的部分，是给另一个身体用的。
extension APIClient {
    func books() async throws -> [Book] {
        try await decodeBook(BookListResponse.self, from: bookRequest("app/book/list")).books
    }

    func uploadBook(data: Data, name: String) async throws -> BookImportResult {
        var components = URLComponents(url: bookEndpoint("app/book/upload"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "name", value: name)]
        guard let url = components?.url else { throw APIError.invalidURL }
        var req = bookRequest(url: url, method: "POST")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        // 拆书是同步的，一本长篇能跑上一阵子。
        req.timeoutInterval = 300
        return try await decodeBook(BookImportResult.self, from: req)
    }

    func deleteBook(id: Int) async throws {
        _ = try await bookData(for: bookRequest("app/book/\(id)", method: "DELETE"))
    }

    func bookChapter(bookID: Int, index: Int) async throws -> BookChapter {
        try await decodeBook(BookChapter.self, from: bookRequest("app/book/\(bookID)/chapter/\(max(0, index))"))
    }

    func reportBookProgress(bookID: Int, chapter: Int, offset: Int) async throws -> BookProgressResponse {
        var req = bookRequest("app/book/\(bookID)/progress", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(BookProgressPayload(curChapter: chapter, curOffset: offset))
        return try await decodeBook(BookProgressResponse.self, from: req)
    }

    func annotateBook(
        bookID: Int,
        chapterIdx: Int,
        start: Int,
        end: Int,
        quote: String,
        note: String
    ) async throws -> BookAnnotation {
        var req = bookRequest("app/book/\(bookID)/annotate", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(
            BookAnnotatePayload(chapterIdx: chapterIdx, startOff: start, endOff: end, quote: quote, note: note)
        )
        return try await decodeBook(BookAnnotation.self, from: req)
    }

    func deleteBookAnnotation(id: Int) async throws {
        _ = try await bookData(for: bookRequest("app/book/annotation/\(id)", method: "DELETE"))
    }

    /// 就着某一句话说过的话（她的 + 小克的）。annIDs 给一组：同一句被划过好几次时并起来看。
    func bookThread(bookID: Int, annotationIDs: [Int]) async throws -> [ChatMessage] {
        var components = URLComponents(url: bookEndpoint("app/book/thread"), resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "book_id", value: String(bookID))]
        if !annotationIDs.isEmpty {
            items.append(URLQueryItem(name: "ann_id", value: annotationIDs.map(String.init).joined(separator: ",")))
        }
        components?.queryItems = items
        guard let url = components?.url else { throw APIError.invalidURL }
        return try await decodeBook(BookThreadResponse.self, from: bookRequest(url: url)).messages
    }

    /// 从书页里说的话：进主聊天流，带书签，小克的回复会自动浮回这一页。
    func sendFromBook(text: String, bookRef: BookRef, sessionID: String?) async throws -> SendResponse {
        var req = bookRequest("app/send", method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(
            BookSendPayload(text: text, bookRef: bookRef, apiSession: sessionID)
        )
        return try await decodeBook(SendResponse.self, from: req)
    }

    // MARK: - 这几个是 APIClient 私有辅助的书房副本（同样的鉴权和错误映射）

    private func bookEndpoint(_ path: String) -> URL {
        path.split(separator: "/").reduce(baseURL) { partial, component in
            partial.appendingPathComponent(String(component))
        }
    }

    private func bookRequest(_ path: String, method: String = "GET") -> URLRequest {
        bookRequest(url: bookEndpoint(path), method: method)
    }

    private func bookRequest(url: URL, method: String = "GET") -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        req.setValue("TidalEcho-iOS/0.1", forHTTPHeaderField: "User-Agent")
        return req
    }

    private func bookData(for request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw APIError.unauthorized }
            let detail = (try? JSONDecoder().decode(BookErrorResponse.self, from: data).detail) ?? "HTTP \(http.statusCode)"
            throw APIError.server(detail)
        }
        return data
    }

    private func decodeBook<T: Decodable>(_ type: T.Type, from request: URLRequest) async throws -> T {
        try JSONDecoder().decode(type, from: try await bookData(for: request))
    }
}

private struct BookProgressPayload: Encodable {
    let curChapter: Int
    let curOffset: Int

    enum CodingKeys: String, CodingKey {
        case curChapter = "cur_chapter"
        case curOffset = "cur_offset"
    }
}

private struct BookAnnotatePayload: Encodable {
    let chapterIdx: Int
    let startOff: Int
    let endOff: Int
    let quote: String
    let note: String

    enum CodingKeys: String, CodingKey {
        case quote, note
        case chapterIdx = "chapter_idx"
        case startOff = "start_off"
        case endOff = "end_off"
    }
}

private struct BookSendPayload: Encodable {
    let text: String
    let bookRef: BookRef
    let apiSession: String?

    enum CodingKeys: String, CodingKey {
        case text
        case bookRef = "book_ref"
        case apiSession = "api_session"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encode(bookRef, forKey: .bookRef)
        try container.encodeIfPresent(apiSession, forKey: .apiSession)
    }
}

private struct BookErrorResponse: Decodable {
    let detail: String
}
