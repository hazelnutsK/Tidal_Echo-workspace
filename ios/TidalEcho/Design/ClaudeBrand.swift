import Foundation
import SwiftUI

enum ClaudeMarkMotion: Equatable {
    case idle
    case thinking
    case writing
    case tool
}

/// The private Claude mark used only by the personal Nest theme. The original
/// vector stays crisp; timeline motion gives thinking/tool states the same
/// lively role as the private web sprite without adding a web renderer to chat.
struct ClaudeBrandMark: View {
    var size: CGFloat = 16
    var motion: ClaudeMarkMotion = .idle
    var color: Color = .primary

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || motion == .idle)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
            Image("ClaudeMark")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(color)
                .frame(width: size, height: size)
                .rotationEffect(.degrees(rotation(at: phase)))
                .scaleEffect(scale(at: phase))
                .opacity(opacity(at: phase))
        }
        .accessibilityHidden(true)
    }

    private func rotation(at time: TimeInterval) -> Double {
        guard !reduceMotion else { return 0 }
        switch motion {
        case .idle: return 0
        case .thinking: return sin(time * 2.1) * 4
        case .writing: return sin(time * 4.4) * 2.4
        case .tool: return time.truncatingRemainder(dividingBy: 3.6) / 3.6 * 360
        }
    }

    private func scale(at time: TimeInterval) -> CGFloat {
        guard !reduceMotion else { return 1 }
        switch motion {
        case .idle: return 1
        case .thinking: return 0.94 + CGFloat((sin(time * 2.1) + 1) * 0.035)
        case .writing: return 0.96 + CGFloat((sin(time * 5.2) + 1) * 0.025)
        case .tool: return 0.98 + CGFloat((sin(time * 3.5) + 1) * 0.015)
        }
    }

    private func opacity(at time: TimeInterval) -> Double {
        guard !reduceMotion else { return 1 }
        return motion == .thinking ? 0.72 + (sin(time * 2.1) + 1) * 0.12 : 1
    }
}

struct ClaudeWordmark: View {
    var color: Color

    var body: some View {
        HStack(spacing: 6) {
            ClaudeBrandMark(size: 15, color: color)
            Image("ClaudeWordmark")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 68, height: 20)
        }
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Claude")
    }
}
