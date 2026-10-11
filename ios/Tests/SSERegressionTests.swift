import Foundation

// The standalone test binary compiles the production SSE client without UIKit.
enum APIError: Error { case invalidResponse }

private actor EventRecorder {
    var events: [Data] = []
    func append(_ data: Data) { events.append(data) }
}

@main
struct SSERegressionTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    static func parse(_ text: String) -> [String] {
        var parser = SSEEventParser()
        return text.utf8.compactMap { parser.append($0) }
            .map { String(decoding: $0, as: UTF8.self) }
    }

    static func main() async throws {
        let delta = #"{"type":"reply_delta","stream_id":"api-test","text":"小雪，🌊","done":false,"api_session":"test"}"#
        let final = #"{"id":42,"author":"ai","kind":"reply","text":"小雪，🌊","meta":{"stream_id":"api-test","api_session":"test"}}"#

        for newline in ["\n", "\r\n", "\r"] {
            let wire = "retry: 3000\(newline): connected\(newline)\(newline)"
                + "data: \(delta)\(newline)\(newline)id: 42\(newline)data: \(final)\(newline)\(newline)"
            expect(parse(wire) == [delta, final], "Relay frames must stay separate for every SSE newline style")
        }
        print("PASS: LF, CRLF, CR relay frames and UTF-8")

        // Assert delivery at the delimiter, before any next frame or EOF exists.
        var parser = SSEEventParser()
        for byte in "data: \(delta)\n".utf8 {
            expect(parser.append(byte) == nil, "An incomplete event must not be delivered")
        }
        expect(parser.append(0x0A) == Data(delta.utf8), "A complete delta must dispatch immediately")
        print("PASS: first delta arrives before final reply or EOF")

        expect(parse("\u{FEFF}data: one\ndata:  two \ndata:\n\n") == ["one\n two \n"], "Preserve multiline data and whitespace")
        expect(parse(": heartbeat\n\nevent: ping\nid: 4\nretry: 3000\n\n\n").isEmpty, "Metadata-only blocks must not dispatch")
        expect(parse("data\n\ndata:\n\n") == ["", ""], "Empty data events are valid")
        expect(parse("data: unfinished\n").isEmpty, "EOF is not an event delimiter")
        expect(parse("data: a\u{2028}b\u{0085}c\n\n") == ["a\u{2028}b\u{0085}c"], "Unicode text separators are not SSE line endings")
        expect(parse("data: one\r\n\r\ndata: two\n\ndata: three\r\r") == ["one", "two", "three"], "Mixed delimiters must not duplicate events")
        print("PASS: BOM, multiline data, comments, whitespace, empty events and incomplete EOF")

        guard CommandLine.arguments.count > 1,
              let baseURL = URL(string: CommandLine.arguments[1]) else {
            fatalError("Supply the local SSE fixture URL")
        }
        let recorder = EventRecorder()
        let client = SSEClient()
        var request = URLRequest(url: baseURL.appendingPathComponent("stream"))
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        client.start(request: request, onEvent: { data in
            await recorder.append(data)
            // The server cannot send the final reply until this delta is received.
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["type"] as? String == "reply_delta" {
                _ = try? await URLSession.shared.data(from: baseURL.appendingPathComponent("ack"))
            }
        }, onConnection: { _ in })
        defer { client.stop() }
        for _ in 0..<100 {
            if await recorder.events.count >= 2 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let received = await recorder.events
        expect(received.count == 2, "SSEClient must deliver a delta while the HTTP response is still open")
        let first = try JSONSerialization.jsonObject(with: received[0]) as! [String: Any]
        let last = try JSONSerialization.jsonObject(with: received[1]) as! [String: Any]
        expect(first["type"] as? String == "reply_delta", "First network event must be the streaming delta")
        expect(first["text"] as? String == "小雪，🌊", "Split UTF-8 bytes must survive the HTTP stream")
        expect(last["id"] as? Int == 42, "Final network event must remain separate")
        print("PASS: production SSEClient delivers delta before final reply over an open HTTP connection")
    }
}
