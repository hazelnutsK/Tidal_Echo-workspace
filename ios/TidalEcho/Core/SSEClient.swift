import Foundation

final class SSEClient {
    private var task: Task<Void, Never>?

    func start(
        request: URLRequest,
        onEvent: @escaping @Sendable (Data) async -> Void,
        onConnection: @escaping @Sendable (Bool) async -> Void
    ) {
        stop()
        task = Task {
            while !Task.isCancelled {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    guard let http = response as? HTTPURLResponse,
                          (200..<300).contains(http.statusCode) else {
                        throw APIError.invalidResponse
                    }
                    await onConnection(true)

                    var parser = SSEEventParser()
                    for try await byte in bytes {
                        if Task.isCancelled { return }
                        if let data = parser.append(byte) {
                            await onEvent(data)
                        }
                    }
                } catch {
                    if Task.isCancelled { return }
                }

                await onConnection(false)
                do {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}
