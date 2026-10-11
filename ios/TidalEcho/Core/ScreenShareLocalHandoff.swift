import Foundation
import Network
import UIKit

struct ScreenShareLocalHandoffResult: Hashable {
    let isReady: Bool
    let diagnostic: String?
}

private final class ScreenShareListenerReadiness: @unchecked Sendable {
    let signal = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private var didFinish = false
    private var ready = false
    private var message: String?

    func markReady() {
        finish(isReady: true, diagnostic: nil)
    }

    func markWaiting(_ error: NWError) {
        lock.lock()
        if !didFinish { message = "等待本机端口：\(error)" }
        lock.unlock()
    }

    func markFailed(_ error: NWError) {
        finish(isReady: false, diagnostic: "监听本机端口失败：\(error)")
    }

    func snapshot() -> (isReady: Bool, diagnostic: String?) {
        lock.lock()
        defer { lock.unlock() }
        return (ready, message)
    }

    private func finish(isReady: Bool, diagnostic: String?) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        ready = isReady
        message = diagnostic
        lock.unlock()
        signal.signal()
    }
}

@MainActor
enum ScreenShareLocalHandoff {
    static let port = NWEndpoint.Port(rawValue: 49_271)!

    private static let queue = DispatchQueue(label: "TidalEcho.ScreenShareHandoff")
    private static var listener: NWListener?
    private static var payload = Data()
    private static var expirationTask: Task<Void, Never>?
    private static var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    static func publish(_ text: String, expiresIn: Int) -> ScreenShareLocalHandoffResult {
        stop()
        guard let data = text.data(using: .utf8) else {
            return .init(isReady: false, diagnostic: "票据无法编码为 UTF-8")
        }

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
            let newListener = try NWListener(using: parameters)
            let readiness = ScreenShareListenerReadiness()

            payload = data
            listener = newListener
            newListener.newConnectionHandler = { connection in
                Task { @MainActor in serve(connection) }
            }
            newListener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    readiness.markReady()
                case .waiting(let error):
                    readiness.markWaiting(error)
                case .failed(let error):
                    readiness.markFailed(error)
                default:
                    break
                }
            }
            newListener.start(queue: queue)

            let didSignal = readiness.signal.wait(timeout: .now() + 5) == .success
            let status = readiness.snapshot()
            guard didSignal, status.isReady else {
                let failure = status.diagnostic ?? "等待本机监听器就绪超时（5 秒）"
                print("[screen-share] \(failure)")
                stop()
                return .init(isReady: false, diagnostic: failure)
            }

            backgroundTask = UIApplication.shared.beginBackgroundTask(
                withName: "TidalEcho.ScreenShareHandoff"
            ) {
                Task { @MainActor in stop() }
            }
            let lifetime = max(30, min(expiresIn, 600))
            expirationTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(lifetime) * 1_000_000_000)
                guard !Task.isCancelled else { return }
                stop()
            }
            return .init(isReady: true, diagnostic: nil)
        } catch {
            let failure = "创建本机监听器失败：\(error)"
            print("[screen-share] \(failure)")
            stop()
            return .init(isReady: false, diagnostic: failure)
        }
    }

    static func stop() {
        expirationTask?.cancel()
        expirationTask = nil
        listener?.cancel()
        listener = nil
        payload = Data()
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    private static func serve(_ connection: NWConnection) {
        guard case let .hostPort(host, _) = connection.endpoint,
              ["127.0.0.1", "::1"].contains(String(describing: host)),
              !payload.isEmpty else {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        connection.send(
            content: payload,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { _ in
                connection.cancel()
                Task { @MainActor in stop() }
            }
        )
    }
}
