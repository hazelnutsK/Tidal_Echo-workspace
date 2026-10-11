import Foundation

/// 书房：她在读的书、章节、划线批注。
/// 位置一律用 (chapter_idx, 章内字符偏移) 表示，偏移是 Python 那边的码点计数——
/// UITextView 用的是 UTF-16，两者之间的换算走 `ScalarOffset`。
struct Book: Decodable, Identifiable, Hashable {
    let id: Int
    let title: String
    let author: String
    let cover: String
    let totalChapters: Int
    let totalChars: Int
    let curChapter: Int
    let curOffset: Int
    let furthestChapter: Int
    let furthestOffset: Int
    let percent: Double
    let annotations: Int
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, title, author, cover, percent, annotations
        case totalChapters = "total_chapters"
        case totalChars = "total_chars"
        case curChapter = "cur_chapter"
        case curOffset = "cur_offset"
        case furthestChapter = "furthest_chapter"
        case furthestOffset = "furthest_offset"
        case createdAt = "created_at"
    }
}

struct BookListResponse: Decodable {
    let books: [Book]
}

struct BookAnnotation: Decodable, Identifiable, Hashable {
    let id: Int
    let bookID: Int
    let chapterIdx: Int
    let startOff: Int
    let endOff: Int
    let quote: String
    let note: String
    let author: String
    let replyTo: Int?
    let createdAt: String

    var isAI: Bool { author == "ai" }
    /// 纯划线（没写字）在页边不占一行，只有底色。
    var hasNote: Bool { !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    enum CodingKeys: String, CodingKey {
        case id, quote, note, author
        case bookID = "book_id"
        case chapterIdx = "chapter_idx"
        case startOff = "start_off"
        case endOff = "end_off"
        case replyTo = "reply_to"
        case createdAt = "created_at"
    }
}

struct BookChapter: Decodable {
    let bookID: Int
    let title: String
    let author: String
    let totalChapters: Int
    let totalChars: Int
    let chapterIdx: Int
    let chapterTitle: String
    let charCount: Int
    let charsBefore: Int
    let text: String
    let annotations: [BookAnnotation]
    let curChapter: Int
    let curOffset: Int

    var heading: String { chapterTitle.isEmpty ? "第 \(chapterIdx + 1) 章" : chapterTitle }

    enum CodingKeys: String, CodingKey {
        case title, author, text, annotations
        case bookID = "book_id"
        case totalChapters = "total_chapters"
        case totalChars = "total_chars"
        case chapterIdx = "chapter_idx"
        case chapterTitle = "chapter_title"
        case charCount = "char_count"
        case charsBefore = "chars_before"
        case curChapter = "cur_chapter"
        case curOffset = "cur_offset"
    }
}

struct BookProgressResponse: Decodable {
    let curChapter: Int
    let curOffset: Int
    let furthestChapter: Int
    let furthestOffset: Int
    let percent: Double
    let chapterDone: Int?

    enum CodingKeys: String, CodingKey {
        case percent
        case curChapter = "cur_chapter"
        case curOffset = "cur_offset"
        case furthestChapter = "furthest_chapter"
        case furthestOffset = "furthest_offset"
        case chapterDone = "chapter_done"
    }
}

struct BookImportResult: Decodable {
    let bookID: Int
    let title: String
    let chapters: Int
    let chars: Int
    let hint: String?

    enum CodingKeys: String, CodingKey {
        case title, chapters, chars, hint
        case bookID = "book_id"
    }
}

struct BookThreadResponse: Decodable {
    let messages: [ChatMessage]
}

/// 她从书页里说话时挂在消息上的书签。relay 会让小克的回复继承它，
/// 于是那句回复既在聊天里，也浮在她划的那一句旁边。
struct BookRef: Codable, Hashable {
    let bookID: Int
    let chapterIdx: Int
    let annID: Int?
    let quote: String
    let title: String

    enum CodingKeys: String, CodingKey {
        case quote, title
        case bookID = "book_id"
        case chapterIdx = "chapter_idx"
        case annID = "ann_id"
    }
}

/// AI 在页边留了一句话时 relay 广播的帧。
struct BookAnnotationEvent: Equatable {
    let token = UUID()
    let bookID: Int
    let annotation: BookAnnotation

    static func == (lhs: BookAnnotationEvent, rhs: BookAnnotationEvent) -> Bool {
        lhs.token == rhs.token
    }
}

/// 章内偏移的两套坐标：relay 存的是 Unicode 码点，UITextView 用的是 UTF-16。
/// 中文正文里两者相同，遇到 emoji / 生僻字的代理对才会分岔——真分岔时错一位
/// 就会把划线错开一个字，所以老老实实换算。
enum ScalarOffset {
    static func toUTF16(_ text: String, _ scalarOffset: Int) -> Int {
        let scalars = text.unicodeScalars
        guard scalarOffset > 0 else { return 0 }
        guard scalarOffset < scalars.count else { return text.utf16.count }
        let index = scalars.index(scalars.startIndex, offsetBy: scalarOffset)
        return text.utf16.distance(from: text.utf16.startIndex, to: index)
    }

    static func fromUTF16(_ text: String, _ utf16Offset: Int) -> Int {
        guard utf16Offset > 0 else { return 0 }
        guard utf16Offset < text.utf16.count else { return text.unicodeScalars.count }
        guard let index = String.Index(utf16Offset: utf16Offset, in: text).samePosition(in: text.unicodeScalars) else {
            // 落在代理对中间：退回到这个字的开头
            let clamped = String.Index(utf16Offset: max(0, utf16Offset - 1), in: text)
            return text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: clamped)
        }
        return text.unicodeScalars.distance(from: text.unicodeScalars.startIndex, to: index)
    }

    /// 按码点区间取子串（划线原文用）。
    static func substring(_ text: String, from start: Int, to end: Int) -> String {
        let scalars = text.unicodeScalars
        let count = scalars.count
        let lower = max(0, min(start, count))
        let upper = max(lower, min(end, count))
        let a = scalars.index(scalars.startIndex, offsetBy: lower)
        let b = scalars.index(scalars.startIndex, offsetBy: upper)
        return String(String.UnicodeScalarView(scalars[a..<b]))
    }
}
