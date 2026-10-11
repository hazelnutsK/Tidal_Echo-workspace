import Foundation
import SwiftUI

/*
 Native SwiftUI adaptation of the PhotoStack interaction model.
 Required Notice: PhotoStack by Wren036 (https://github.com/Wren036/PhotoStack)
 License: PolyForm Noncommercial 1.0.0
 */
struct PhotoStackAttachmentView: View {
    let attachments: [Attachment]
    let request: (Attachment) -> URLRequest?
    let palette: EchoPalette

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var currentIndex = 0
    @State private var dragDirection = 0
    @State private var dragProgress: CGFloat = 0
    @State private var isHorizontalDrag = false
    @State private var isSettling = false
    @State private var suppressesPreview = false
    @State private var gestureSequence = 0

    init(
        attachments: [Attachment],
        request: @escaping (Attachment) -> URLRequest?,
        palette: EchoPalette
    ) {
        self.attachments = attachments
        self.request = request
        self.palette = palette
    }

    private enum Metrics {
        static let cardWidth: CGFloat = 142
        static let cardHeight: CGFloat = 190
        static let stageWidth: CGFloat = 196
        static let stageHeight: CGFloat = 210
        static let peek: CGFloat = 15
        static let peekStep: CGFloat = 12
        static let rotationStep = 2.2
        static let scaleStep: CGFloat = 0.08
        static let peakRotation = 8.0
        static let edgeTravel: CGFloat = 24
        static let pageTravel: CGFloat = 192
    }

    var body: some View {
        ZStack {
            ForEach(attachments.indices, id: \.self) { index in
                let attachment = attachments[index]
                let pose = pose(for: index)
                AuthenticatedImageView(
                    request: request(attachment),
                    palette: palette,
                    contentMode: .fill,
                    allowsPreview: !suppressesPreview
                )
                .frame(width: Metrics.cardWidth, height: Metrics.cardHeight)
                .clipped()
                .background(Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(Color.white.opacity(0.58), lineWidth: 0.7)
                }
                .shadow(color: Color.black.opacity(0.16), radius: 8, y: 4)
                .offset(x: pose.offsetX)
                .rotationEffect(.degrees(pose.rotation))
                .scaleEffect(pose.scale)
                .opacity(pose.opacity)
                .zIndex(pose.zIndex)
                .allowsHitTesting(index == currentIndex && !isHorizontalDrag && !isSettling)
                .accessibilityHidden(index != currentIndex)
            }
        }
        .frame(width: Metrics.stageWidth, height: Metrics.stageHeight)
        .contentShape(Rectangle())
        .simultaneousGesture(pagingGesture)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("照片堆")
        .accessibilityValue("第 \(currentIndex + 1) 张，共 \(attachments.count) 张")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                settle(direction: -1, advance: currentIndex < attachments.count - 1, from: 0)
            case .decrement:
                settle(direction: 1, advance: currentIndex > 0, from: 0)
            @unknown default:
                break
            }
        }
        .onChange(of: attachments.count) { _, count in
            currentIndex = min(currentIndex, max(0, count - 1))
        }
    }

    private var pagingGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                guard !isSettling else { return }
                let dx = value.translation.width
                let dy = value.translation.height
                if !isHorizontalDrag {
                    guard abs(dx) > 8, abs(dx) > abs(dy) else { return }
                    isHorizontalDrag = true
                    gestureSequence += 1
                    suppressesPreview = true
                }

                dragDirection = dx < 0 ? -1 : 1
                dragProgress = min(1, abs(dx) / Metrics.pageTravel)
            }
            .onEnded { value in
                guard isHorizontalDrag else {
                    resetDragState()
                    return
                }

                let dx = value.translation.width
                let predicted = value.predictedEndTranslation.width
                let direction = dx < 0 ? -1 : 1
                let canAdvance = direction < 0
                    ? currentIndex < attachments.count - 1
                    : currentIndex > 0
                let projectedFling = abs(dx) > 10
                    && dx.sign == predicted.sign
                    && abs(predicted) > max(72, abs(dx) * 1.35)
                settle(
                    direction: direction,
                    advance: canAdvance && (dragProgress > 0.5 || projectedFling),
                    from: dragProgress
                )
            }
    }

    private func settle(direction: Int, advance: Bool, from progress: CGFloat) {
        guard !isSettling else { return }
        isHorizontalDrag = false
        isSettling = true
        dragDirection = direction

        if advance {
            let duration = reduceMotion ? 0.01 : max(0.14, Double(1 - progress) * 0.34)
            withAnimation(reduceMotion ? nil : .easeOut(duration: duration)) {
                dragProgress = 1
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    currentIndex = direction < 0
                        ? min(currentIndex + 1, attachments.count - 1)
                        : max(currentIndex - 1, 0)
                    dragProgress = 0
                    dragDirection = 0
                    isSettling = false
                }
                releasePreviewSuppression()
            }
        } else {
            let duration = reduceMotion ? 0.01 : 0.24
            withAnimation(reduceMotion ? nil : .spring(response: duration, dampingFraction: 0.82)) {
                dragProgress = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                dragDirection = 0
                isSettling = false
                releasePreviewSuppression()
            }
        }
    }

    private func releasePreviewSuppression() {
        guard suppressesPreview else { return }
        let sequence = gestureSequence
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            guard sequence == gestureSequence, !isHorizontalDrag, !isSettling else { return }
            suppressesPreview = false
        }
    }

    private func resetDragState() {
        isHorizontalDrag = false
        dragDirection = 0
        dragProgress = 0
    }

    private func pose(for index: Int) -> PhotoStackPose {
        var result = restingPose(for: index, current: currentIndex)
        guard dragDirection != 0, dragProgress > 0 else { return result }

        let direction = dragDirection
        let directionValue = CGFloat(direction)
        let progress = dragProgress
        let lastIndex = attachments.count - 1
        let isEdgeDrag = (direction < 0 && currentIndex >= lastIndex)
            || (direction > 0 && currentIndex <= 0)

        if isEdgeDrag {
            if index == currentIndex {
                result.offsetX = directionValue * Metrics.edgeTravel * progress
                result.rotation = Double(direction) * 2.5 * Double(progress)
                result.zIndex = 110
            } else if index == currentIndex + direction {
                result.offsetX = directionValue * (Metrics.peek + 8 * progress)
                result.rotation = Double(direction) * Metrics.rotationStep
                result.scale = 1 - Metrics.scaleStep
            } else if index == currentIndex + direction * 2 {
                result.offsetX = directionValue * (Metrics.peek + Metrics.peekStep + 5 * progress)
                result.rotation = Double(direction) * Metrics.rotationStep * 2
                result.scale = 1 - Metrics.scaleStep * 2
            }
            return result
        }

        let peakX = Metrics.cardWidth * 0.52
        let currentOffset: CGFloat
        let currentRotation: Double
        let currentScale: CGFloat
        if progress <= 0.5 {
            let phase = progress / 0.5
            currentOffset = directionValue * peakX * phase
            currentRotation = Double(direction) * Metrics.peakRotation * Double(phase)
            currentScale = 1
        } else {
            let phase = (progress - 0.5) / 0.5
            currentOffset = directionValue * (peakX - (peakX - Metrics.peek) * phase)
            currentRotation = Double(direction) * (
                Metrics.peakRotation - (Metrics.peakRotation - Metrics.rotationStep) * Double(phase)
            )
            currentScale = 1 - Metrics.scaleStep * phase
        }

        if index == currentIndex {
            result.offsetX = currentOffset
            result.rotation = currentRotation
            result.scale = currentScale
            result.zIndex = progress < 0.5 ? 110 : 102
            return result
        }

        let newTop = currentIndex - direction
        if index == newTop {
            result.offsetX = -directionValue * Metrics.peek * (1 - progress)
            result.rotation = -Double(direction) * Metrics.rotationStep * Double(1 - progress)
            result.scale = 1 - Metrics.scaleStep + Metrics.scaleStep * progress
            result.opacity = 1
            result.zIndex = 105
            return result
        }

        let secondIncoming = currentIndex - direction * 2
        let secondPhase = max(0, (progress - 0.5) / 0.5)
        if index == secondIncoming {
            let depths = visibleDepths(at: currentIndex)
            let borrowedAtBoundary = direction < 0 ? depths.right >= 2 : depths.left >= 2
            if borrowedAtBoundary {
                result.offsetX = -directionValue * (
                    Metrics.peek + Metrics.peekStep * (1 - progress)
                )
                result.rotation = -Double(direction) * (
                    Metrics.rotationStep * 2 - Metrics.rotationStep * Double(progress)
                )
                result.scale = 1 - Metrics.scaleStep * 2 + Metrics.scaleStep * progress
                result.opacity = 1
            } else {
                let newTopOffset = -directionValue * Metrics.peek * (1 - progress)
                result.offsetX = newTopOffset * (1 - secondPhase)
                    + (-directionValue * Metrics.peek) * secondPhase
                result.rotation = -Double(direction) * (
                    Metrics.rotationStep * 2 - Metrics.rotationStep * Double(secondPhase)
                )
                result.scale = 1 - Metrics.scaleStep * 2.5 + Metrics.scaleStep * 1.5 * secondPhase
                result.opacity = Double(
                    min(1, secondPhase / 0.18) * 0.55 + 0.45 * secondPhase
                )
            }
            result.zIndex = direction < 0 ? 98 : 38
            return result
        }

        let outgoingPeek = currentIndex + direction
        if index == outgoingPeek {
            let newCurrent = direction < 0
                ? min(currentIndex + 1, lastIndex)
                : max(currentIndex - 1, 0)
            let newDepths = visibleDepths(at: newCurrent)
            let staysVisible = index < newCurrent
                ? newCurrent - index <= newDepths.left
                : index - newCurrent <= newDepths.right
            if staysVisible {
                result.offsetX = directionValue * (Metrics.peek + Metrics.peekStep * progress)
                result.rotation = Double(direction) * (
                    Metrics.rotationStep + Metrics.rotationStep * Double(progress)
                )
                result.scale = 1 - Metrics.scaleStep - Metrics.scaleStep * progress
            } else {
                let eased = 1 - (1 - secondPhase) * (1 - secondPhase)
                let fade = min(1, secondPhase / 0.18) * 0.55 + 0.45 * secondPhase
                result.offsetX = directionValue * Metrics.peek * (1 - eased) + currentOffset * eased
                result.rotation = Double(direction) * Metrics.rotationStep
                result.scale = 1 - Metrics.scaleStep - Metrics.scaleStep * 1.5 * secondPhase
                result.opacity = Double(1 - fade)
            }
        }

        return result
    }

    private func restingPose(for index: Int, current: Int) -> PhotoStackPose {
        let depths = visibleDepths(at: current)
        if index < current {
            let depth = current - index
            return PhotoStackPose(
                offsetX: -Metrics.peek - CGFloat(depth - 1) * Metrics.peekStep,
                rotation: -Metrics.rotationStep * Double(depth),
                scale: 1 - Metrics.scaleStep * CGFloat(depth),
                opacity: depth <= depths.left ? 1 : 0,
                zIndex: Double(40 - depth)
            )
        }
        if index == current {
            return PhotoStackPose(offsetX: 0, rotation: 0, scale: 1, opacity: 1, zIndex: 100)
        }

        let depth = index - current
        return PhotoStackPose(
            offsetX: Metrics.peek + CGFloat(depth - 1) * Metrics.peekStep,
            rotation: Metrics.rotationStep * Double(depth),
            scale: 1 - Metrics.scaleStep * CGFloat(depth),
            opacity: depth <= depths.right ? 1 : 0,
            zIndex: Double(100 - depth)
        )
    }

    private func visibleDepths(at index: Int) -> (left: Int, right: Int) {
        let availableLeft = index
        let availableRight = attachments.count - 1 - index
        var left = min(availableLeft, 1)
        var right = min(availableRight, 1)
        if left + right < 2 {
            left = min(availableLeft, 2 - right)
            right = min(availableRight, 2 - left)
        }
        return (left, right)
    }
}

private struct PhotoStackPose {
    var offsetX: CGFloat
    var rotation: Double
    var scale: CGFloat
    var opacity: Double
    var zIndex: Double
}
