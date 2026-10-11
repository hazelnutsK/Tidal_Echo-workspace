import SwiftUI
import WebKit

struct ClawdPetOverlay: View {
    @ObservedObject var model: AppModel
    let bottomInset: CGFloat

    @AppStorage("tidalEcho.clawdPetPositionX") private var savedX = -1.0
    @AppStorage("tidalEcho.clawdPetPositionY") private var savedY = -1.0
    @GestureState private var dragTranslation = CGSize.zero
    @State private var isTipVisible = false
    @State private var tipTask: Task<Void, Never>?

    private let petSize: CGFloat = 120
    private let edgeInset: CGFloat = 4

    var body: some View {
        GeometryReader { geometry in
            let restingPosition = restingPosition(in: geometry.size)
            let visiblePosition = clamped(
                CGPoint(
                    x: restingPosition.x + dragTranslation.width,
                    y: restingPosition.y + dragTranslation.height
                ),
                in: geometry.size
            )
            let tipWidth = min(220, max(140, geometry.size.width * 0.6))
            let tipCenterX = min(
                max(visiblePosition.x, tipWidth / 2 + 8),
                geometry.size.width - tipWidth / 2 - 8
            )
            let tipOffsetY = visiblePosition.y < petSize / 2 + 52
                ? petSize * 0.48
                : -petSize * 0.48

            ZStack {
                if isTipVisible {
                    Text(model.clawdPetState.statusText)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(width: tipWidth)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .offset(x: tipCenterX - visiblePosition.x, y: tipOffsetY)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .allowsHitTesting(false)
                }

                ClawdAnimatedGIFView(
                    url: model.clawdPetGIFURL(),
                    renderKey: model.clawdPetState.state
                )
                .frame(width: petSize, height: petSize)
                .allowsHitTesting(false)
            }
            .frame(width: petSize, height: petSize)
            .contentShape(Rectangle())
            .position(visiblePosition)
            .gesture(
                DragGesture(minimumDistance: 6)
                    .updating($dragTranslation) { value, translation, _ in
                        translation = value.translation
                    }
                    .onEnded { value in
                        let destination = clamped(
                            CGPoint(
                                x: restingPosition.x + value.translation.width,
                                y: restingPosition.y + value.translation.height
                            ),
                            in: geometry.size
                        )
                        savedX = destination.x
                        savedY = destination.y
                    }
            )
            .onTapGesture { showTip() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("小螃蟹，\(model.clawdPetState.statusText)")
            .accessibilityHint("可以拖动；轻点查看状态")
        }
        .animation(.easeOut(duration: 0.18), value: isTipVisible)
        .onDisappear { tipTask?.cancel() }
    }

    private func restingPosition(in size: CGSize) -> CGPoint {
        let fallback = CGPoint(
            x: size.width - petSize / 2 - 12,
            y: size.height - bottomInset - petSize / 2
        )
        guard savedX >= 0, savedY >= 0 else { return clamped(fallback, in: size) }
        return clamped(CGPoint(x: savedX, y: savedY), in: size)
    }

    private func clamped(_ point: CGPoint, in size: CGSize) -> CGPoint {
        let half = petSize / 2
        return CGPoint(
            x: min(max(point.x, half + edgeInset), max(half + edgeInset, size.width - half - edgeInset)),
            y: min(max(point.y, half + edgeInset), max(half + edgeInset, size.height - half - edgeInset))
        )
    }

    private func showTip() {
        tipTask?.cancel()
        withAnimation { isTipVisible = true }
        tipTask = Task {
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled else { return }
            withAnimation { isTipVisible = false }
        }
    }
}

private struct ClawdAnimatedGIFView: UIViewRepresentable {
    let url: URL?
    let renderKey: String

    final class Coordinator {
        var renderKey = ""
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isUserInteractionEnabled = false
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.renderKey != renderKey else { return }
        context.coordinator.renderKey = renderKey
        guard let url else {
            webView.loadHTMLString("", baseURL: nil)
            return
        }
        let source = url.absoluteString.replacingOccurrences(of: "&", with: "&amp;")
        let html = """
        <!doctype html>
        <html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
        <style>
        html,body{margin:0;width:100%;height:100%;overflow:hidden;background:transparent}
        img{display:block;width:100%;height:100%;object-fit:contain;image-rendering:pixelated}
        </style></head><body><img src="\(source)" alt=""></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }
}
