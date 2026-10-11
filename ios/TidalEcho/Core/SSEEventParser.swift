import Foundation

/// Incremental SSE framing. Foundation's `AsyncBytes.lines` can omit the empty
/// lines that delimit events, so consume the original bytes instead.
struct SSEEventParser {
    private var lineBytes: [UInt8] = []
    private var dataLines: [String] = []
    private var skipsLineFeed = false
    private var isFirstLine = true

    mutating func append(_ byte: UInt8) -> Data? {
        if skipsLineFeed {
            skipsLineFeed = false
            if byte == 0x0A { return nil }
        }

        switch byte {
        case 0x0D:
            skipsLineFeed = true
            return finishLine()
        case 0x0A:
            return finishLine()
        default:
            lineBytes.append(byte)
            return nil
        }
    }

    private mutating func finishLine() -> Data? {
        var line = String(decoding: lineBytes, as: UTF8.self)
        lineBytes.removeAll(keepingCapacity: true)
        if isFirstLine {
            isFirstLine = false
            if line.hasPrefix("\u{FEFF}") { line.removeFirst() }
        }

        if line.isEmpty {
            guard !dataLines.isEmpty else { return nil }
            let data = Data(dataLines.joined(separator: "\n").utf8)
            dataLines.removeAll(keepingCapacity: true)
            return data
        }

        // Comments and fields such as event/id/retry do not contain JSON data.
        let separator = line.firstIndex(of: ":") ?? line.endIndex
        guard line[..<separator] == "data" else { return nil }
        var value = separator == line.endIndex ? "" : String(line[line.index(after: separator)...])
        // SSE removes exactly one optional space, preserving payload whitespace.
        if value.first == " " { value.removeFirst() }
        dataLines.append(value)
        return nil
    }
}
