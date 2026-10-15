import SwiftUI

/// Telegram 式输入栏：左边回形针，中间胶囊输入框，右边录音。
/// 一打字，录音按钮被推出去，它的玻璃融进输入框，发送键从框里冒出来，表情键让到它左边。
/// 尺寸照 Telegram iOS 26 截图量的（390pt 宽）：按钮 40、框高 40、间距 7、框内发送键 40×32 的扁胶囊。
struct TelegramComposerBar: View {
    @Binding var text: String
    let focus: FocusState<Bool>.Binding
    let palette: EchoPalette
    let font: Font
    let isDark: Bool
    let isOnline: Bool
    let sessionLabel: String
    let uploading: Bool
    let isRecording: Bool
    let voiceDisabled: Bool
    let isSending: Bool
    /// Text or attachments in the draft: the send key replaces the mic.
    let showsSend: Bool
    let sendIcon: String
    let sendLabel: String
    let sendHint: String
    /// Messages staged for one combined reply; shown as a light send key with a count.
    let pendingBundleCount: Int
    let onAttachments: () -> Void
    let onFaces: () -> Void
    let onSessions: () -> Void
    let onVoice: () -> Void
    let onSend: () -> Void
    let onReleaseBundle: () -> Void

    @Namespace private var glassSpace

    static let controlSize: CGFloat = 40
    static let spacing: CGFloat = 7
    private static let sendSize = CGSize(width: 40, height: 32)

    var body: some View {
        GlassEffectContainer(spacing: Self.spacing) {
            HStack(alignment: .bottom, spacing: Self.spacing) {
                circleButton("paperclip", label: "添加附件", action: onAttachments)
                    .disabled(uploading)
                    .modifier(PinnedGlass(shape: Circle(), id: "attach", space: glassSpace, isDark: isDark))
                    .accessibilityIdentifier("chat.add")

                field
                    .modifier(PinnedGlass(
                        shape: RoundedRectangle(cornerRadius: Self.controlSize / 2, style: .continuous),
                        id: "field", space: glassSpace, isDark: isDark
                    ))

                if !showsSend {
                    circleButton(isRecording ? "stop.fill" : "mic",
                                 label: isRecording ? "停止录音" : "录语音",
                                 tint: isRecording ? .white : nil,
                                 action: onVoice)
                        .disabled(voiceDisabled)
                        .modifier(PinnedGlass(
                            shape: Circle(), id: "mic", space: glassSpace,
                            isDark: isDark, recording: isRecording
                        ))
                        // The glass has its own transition: left on the default matched
                        // geometry it found no partner, shrank to a dot and sat at the
                        // right edge until the spring settled. It fades with the icon instead.
                        .glassEffectTransition(.materialize)
                        // Pushed out to the right as the field grows into its place.
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.4).combined(with: .opacity),
                            removal: .scale(scale: 0.5).combined(with: .opacity).combined(with: .offset(x: 22))
                                .animation(.easeOut(duration: 0.16))
                        ))
                }
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.68), value: showsSend)
        .animation(.spring(response: 0.34, dampingFraction: 0.68), value: pendingBundleCount)
        .animation(.easeOut(duration: 0.18), value: isRecording)
    }

    private var field: some View {
        HStack(alignment: .bottom, spacing: 0) {
            Button(action: onSessions) {
                Circle()
                    .fill(isOnline ? Color.green : palette.secondaryText.opacity(0.65))
                    .frame(width: 7, height: 7)
                    .frame(width: 26, height: Self.controlSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 4)
            .accessibilityLabel("切换对话窗口，当前 \(sessionLabel)，\(isOnline ? "在线" : "离线")")
            .accessibilityIdentifier("chat.sessionStatus")

            TextField("Message", text: $text,
                      prompt: Text("Message").foregroundStyle(palette.secondaryText),
                      axis: .vertical)
                .lineLimit(1...5)
                .font(font)
                .foregroundStyle(palette.text)
                .tint(palette.accent)
                .focused(focus)
                .padding(.vertical, 9.5)
                .frame(maxWidth: .infinity, minHeight: Self.controlSize, alignment: .leading)
                .accessibilityIdentifier("chat.draft")

            Button(action: onFaces) {
                Image(systemName: "face.smiling")
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(palette.secondaryText)
                    .frame(width: 38, height: Self.controlSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("打开表情抽屉")

            if showsSend {
                Button(action: onSend) {
                    Group {
                        if isSending {
                            ProgressView().controlSize(.small).tint(palette.background)
                        } else {
                            Image(systemName: sendIcon)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(palette.background)
                        }
                    }
                    .frame(width: Self.sendSize.width, height: Self.sendSize.height)
                    .background(palette.text, in: Capsule())
                    .padding(.trailing, 4)
                    .frame(height: Self.controlSize)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isSending)
                .accessibilityLabel(sendLabel)
                .accessibilityHint(sendHint)
                .accessibilityIdentifier("chat.send")
                // Pops up from inside the field with a little overshoot.
                .transition(.scale(scale: 0.15).combined(with: .opacity))
            } else if pendingBundleCount > 0 {
                Button(action: onReleaseBundle) {
                    Image(systemName: "paperplane")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.text.opacity(0.8))
                        .frame(width: Self.sendSize.width, height: Self.sendSize.height)
                        .background(palette.text.opacity(0.09), in: Capsule())
                        .overlay(alignment: .topTrailing) {
                            Text("\(pendingBundleCount)")
                                .font(.system(size: 10, weight: .bold).monospacedDigit())
                                .foregroundStyle(Color.white)
                                .padding(.horizontal, 4.5)
                                .frame(minWidth: 16, minHeight: 16)
                                .background(palette.accent, in: Capsule())
                                .offset(x: 4, y: -4)
                        }
                        .padding(.trailing, 4)
                        .frame(height: Self.controlSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("让 AI 统一回复上面的 \(pendingBundleCount) 条消息")
                .transition(.scale(scale: 0.15).combined(with: .opacity))
            }
        }
        .padding(.trailing, showsSend || pendingBundleCount > 0 ? 0 : 4)
    }

    private func circleButton(
        _ icon: String,
        label: String,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(tint ?? palette.text)
                .frame(width: Self.controlSize, height: Self.controlSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// The glass goes on the control itself, so its icon and text render above the
/// glass; put behind a control, the container drew the glass on top and refracted them.
/// Regular glass darkens over dark wallpaper, and the icons use the theme's fixed ink,
/// so a translucent base between glass and content keeps the light frosted look.
private struct PinnedGlass<S: Shape>: ViewModifier {
    let shape: S
    let id: String
    let space: Namespace.ID
    let isDark: Bool
    var recording = false

    func body(content: Content) -> some View {
        content
            .background(base, in: shape)
            .glassEffect(.regular.interactive(), in: shape)
            .glassEffectID(id, in: space)
    }

    private var base: Color {
        if recording { return Color.red.opacity(0.8) }
        return isDark ? Color.black.opacity(0.28) : Color.white.opacity(0.42)
    }
}
