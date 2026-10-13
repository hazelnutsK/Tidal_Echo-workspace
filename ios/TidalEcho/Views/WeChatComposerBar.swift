import SwiftUI

/// One compact row inside the full-width dock supplied by ComposerView.
struct WeChatComposerBar: View {
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
    let canSend: Bool
    let sendIcon: String
    let sendLabel: String
    let sendHint: String
    let onAttachments: () -> Void
    let onFaces: () -> Void
    let onSessions: () -> Void
    let onVoice: () -> Void
    let onSend: () -> Void

    private var sendColor: Color {
        isDark ? Color(hex: 0xABC0D8) : Color(hex: 0x526A85)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            control("plus", label: "添加附件", action: onAttachments)
                .disabled(uploading)
                .accessibilityIdentifier("chat.add")

            HStack(alignment: .bottom, spacing: 0) {
                TextField("说点什么…", text: $text,
                          prompt: Text("说点什么…").foregroundStyle(palette.secondaryText),
                          axis: .vertical)
                    .lineLimit(1...4)
                    .font(font)
                    .foregroundStyle(palette.text)
                    .tint(sendColor)
                    .focused(focus)
                    .padding(.leading, 12)
                    .padding(.vertical, 10)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("chat.draft")

                Button(action: onSessions) {
                    Circle()
                        .fill(isOnline ? Color.green : palette.secondaryText.opacity(0.65))
                        .frame(width: 7, height: 7)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("切换对话窗口，当前 \(sessionLabel)，\(isOnline ? "在线" : "离线")")
                .accessibilityIdentifier("chat.sessionStatus")
            }
            .frame(maxWidth: .infinity)
            // 输入框做成嵌在玻璃里的一道浅槽：上沿略暗、下沿受光，
            // 而不是一片半透明实心底加一圈均匀白边贴在上面。
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isDark ? Color.white.opacity(0.06) : palette.composer.opacity(0.30))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.black.opacity(isDark ? 0.32 : 0.07),
                                Color.white.opacity(isDark ? 0.10 : 0.65)
                            ],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 0.6
                    )
                    .allowsHitTesting(false)
            }
            .layoutPriority(1)

            control("face.smiling", label: "打开表情抽屉", action: onFaces)

            control(isRecording ? "stop.fill" : "mic",
                    label: isRecording ? "停止录音" : "录语音",
                    active: isRecording, action: onVoice)
                .disabled(voiceDisabled)

            Button(action: onSend) {
                Group {
                    if isSending {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: sendIcon)
                            .font(.system(size: 17, weight: .semibold))
                    }
                }
                .foregroundStyle(isDark ? Color.black : Color.white)
                .tint(isDark ? Color.black : Color.white)
                .frame(width: 34, height: 34)
                .background(sendColor.opacity(canSend || isSending ? 1 : 0.40), in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel(sendLabel)
            .accessibilityHint(sendHint)
            .accessibilityIdentifier("chat.send")
        }
    }

    private func control(
        _ icon: String,
        label: String,
        active: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(active ? Color.white : palette.text.opacity(0.82))
                .frame(width: 34, height: 34)
                .background {
                    // 平时不垫底片，图标直接落在磨砂上；只有录音时亮红圈。
                    if active { Circle().fill(Color.red.opacity(0.82)) }
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
