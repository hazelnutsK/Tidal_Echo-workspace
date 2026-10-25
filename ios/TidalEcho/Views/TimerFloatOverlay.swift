import SwiftUI

/// 倒计时卡在跑的时候，屏幕上浮着一颗小药丸：剩余时间 + 事项。
/// 拖到哪儿停哪儿（位置记住），轻点滚回那张卡，长按可以直接搞定或先收起。
struct TimerFloatOverlay: View {
    let timer: MessageTimer
    let palette: EchoPalette
    let topInset: CGFloat
    let bottomInset: CGFloat
    let onOpen: () -> Void
    let onDone: () -> Void
    let onDismiss: () -> Void

    @AppStorage("tidalEcho.timerFloatPositionX") private var savedX = -1.0
    @AppStorage("tidalEcho.timerFloatPositionY") private var savedY = -1.0
    @GestureState private var dragTranslation = CGSize.zero

    private let pillSize = CGSize(width: 124, height: 46)
    private let edgeInset: CGFloat = 8

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

            TimelineView(.periodic(from: .now, by: 1)) { context in
                pill(remaining: timer.secondsRemaining(at: context.date))
            }
            .frame(width: pillSize.width, height: pillSize.height)
            .contentShape(Capsule())
            .contextMenu {
                Button(action: onDone) { Label("搞定了", systemImage: "checkmark.circle") }
                Button(action: onOpen) { Label("看那张卡", systemImage: "arrow.turn.down.left") }
                Button(action: onDismiss) { Label("先收起", systemImage: "eye.slash") }
            }
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
            .onTapGesture(perform: onOpen)
            .accessibilityElement(children: .combine)
            .accessibilityHint("可以拖动；轻点跳到倒计时卡")
        }
    }

    private func pill(remaining: Int) -> some View {
        let isUp = remaining <= 0
        return HStack(spacing: 8) {
            Image(systemName: isUp ? "bell.fill" : "timer")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isUp ? Color.red.opacity(0.85) : palette.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(isUp ? "时间到" : MessageTimer.durationText(remaining))
                    .font(.system(size: 16, weight: .semibold).monospacedDigit())
                    .foregroundStyle(isUp ? Color.red.opacity(0.85) : palette.text)
                Text(timer.label)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 13)
        .padding(.trailing, 10)
        .frame(width: pillSize.width, height: pillSize.height)
        .glassEffect(.regular, in: Capsule())
        .overlay(Capsule().stroke(palette.hairline, lineWidth: 0.5))
        .shadow(color: Color.black.opacity(0.12), radius: 8, y: 3)
    }

    private func restingPosition(in size: CGSize) -> CGPoint {
        let fallback = CGPoint(
            x: size.width - pillSize.width / 2 - 12,
            y: topInset + pillSize.height / 2 + 10
        )
        guard savedX >= 0, savedY >= 0 else { return clamped(fallback, in: size) }
        return clamped(CGPoint(x: savedX, y: savedY), in: size)
    }

    private func clamped(_ point: CGPoint, in size: CGSize) -> CGPoint {
        let halfWidth = pillSize.width / 2
        let halfHeight = pillSize.height / 2
        let minY = topInset + halfHeight
        let maxY = max(minY, size.height - bottomInset - halfHeight)
        return CGPoint(
            x: min(max(point.x, halfWidth + edgeInset), max(halfWidth + edgeInset, size.width - halfWidth - edgeInset)),
            y: min(max(point.y, minY), maxY)
        )
    }
}
