import SwiftUI

/// Floating controls only. The conversation keeps its own theme and wallpaper.
struct IMessageChatHeader: View {
    @ObservedObject var model: AppModel
    let metrics: IMessageLayoutMetrics
    let onSettings: () -> Void
    let onTerminal: () -> Void
    let onSpaces: () -> Void
    let onSessions: () -> Void

    var body: some View {
        Group {
            ZStack(alignment: .top) {
                HStack(alignment: .top, spacing: metrics.headerGap) {
                    control("slider.horizontal.3", label: "设置", action: onSettings)
                    Spacer(minLength: 0)
                    control("terminal", label: "终端", action: onTerminal)
                    control("square.grid.2x2", label: "空间", action: onSpaces)
                }

                Button(action: onSessions) {
                    Group {
                        if let image = model.aiAvatarImage {
                            Image(uiImage: image).resizable().scaledToFill()
                        } else {
                            Image("ClaudeMark").resizable().scaledToFit()
                                .padding(metrics.avatarDiameter * 0.2)
                                .background(model.theme.palette.backgroundTop)
                        }
                    }
                    .frame(width: metrics.avatarDiameter, height: metrics.avatarDiameter)
                    .clipShape(Circle())
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("切换对话窗口")
                .accessibilityIdentifier("chat.sessionAvatar")
                .overlay(alignment: .bottomTrailing) {
                    if model.isLoadingHistory {
                        ProgressView().controlSize(.mini)
                            .padding(4)
                            .background(.regularMaterial, in: Circle())
                            .allowsHitTesting(false)
                    }
                }
            }
            .frame(height: metrics.avatarDiameter, alignment: .top)
        }
        .padding(.horizontal, metrics.headerInset)
        .padding(.bottom, metrics.headerBottomPadding)
    }

    private func control(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: metrics.headerIconSize, weight: .regular))
                .foregroundStyle(model.theme.palette.text)
                .frame(width: metrics.headerButtonDiameter, height: metrics.headerButtonDiameter)
                .background {
                    IMessageGlassBackground(cornerRadius: metrics.headerButtonDiameter / 2)
                        .allowsHitTesting(false)
                }
                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Visual state is independent of whether a send is currently permitted.
/// In particular a pending batch must not turn an empty composer's microphone
/// into a send button, and an in-flight send must not turn text into a microphone.
enum IMessageComposerAction: Equatable {
    case voice, stopRecording, send, sending

    init(hasContent: Bool, isRecording: Bool, isSending: Bool) {
        if isRecording { self = .stopRecording }
        else if isSending { self = .sending }
        else if hasContent { self = .send }
        else { self = .voice }
    }
}

struct IMessageComposerBar: View {
    @Binding var text: String
    let focus: FocusState<Bool>.Binding
    let metrics: IMessageLayoutMetrics
    let palette: EchoPalette
    let font: Font
    let action: IMessageComposerAction
    let actionDisabled: Bool
    let sendLabel: String
    let sendHint: String
    let uploading: Bool
    let onAttachments: () -> Void
    let onFaces: () -> Void
    let onAction: () -> Void

    var body: some View {
        Group {
            HStack(alignment: .bottom, spacing: metrics.composerGap) {
                Menu {
                    Button(action: onAttachments) { Label("添加附件", systemImage: "paperclip") }
                        .disabled(uploading)
                    Button(action: onFaces) { Label("表情包", systemImage: "face.smiling") }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: metrics.plusFontSize, weight: .light))
                        .foregroundStyle(palette.text)
                        .frame(width: metrics.composerHeight, height: metrics.composerHeight)
                        .background {
                            IMessageGlassBackground(cornerRadius: metrics.composerHeight / 2)
                                .allowsHitTesting(false)
                        }
                        .overlay(Circle().strokeBorder(.white.opacity(0.45), lineWidth: 0.6))
                        .contentShape(Circle())
                }
                .menuOrder(.fixed)
                .buttonStyle(.plain)
                .accessibilityLabel("添加附件或表情包")
                .accessibilityIdentifier("chat.add")

                HStack(alignment: .bottom, spacing: 0) {
                    TextField("和Altair说话…", text: $text,
                              prompt: Text("和Altair说话…").foregroundStyle(palette.secondaryText),
                              axis: .vertical)
                        .lineLimit(1...4)
                        .font(font)
                        .foregroundStyle(palette.text)
                        .tint(palette.accent)
                        .focused(focus)
                        .padding(.leading, metrics.textInset)
                        .padding(.vertical, 5)
                        .frame(minHeight: metrics.composerHeight)
                        .accessibilityIdentifier("chat.draft")

                    Button(action: onAction) {
                        actionGlyph
                            .frame(width: metrics.actionWidth, height: metrics.composerHeight)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(actionDisabled)
                    .accessibilityLabel(actionLabel)
                    .accessibilityHint(action == .send ? sendHint : "")
                    .accessibilityIdentifier("chat.composerAction")
                    .padding(.trailing, metrics.actionInset)
                }
                .background {
                    IMessageGlassBackground(cornerRadius: metrics.composerHeight / 2)
                        .allowsHitTesting(false)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: metrics.composerHeight / 2)
                        .strokeBorder(.white.opacity(0.45), lineWidth: 0.6)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    @ViewBuilder private var actionGlyph: some View {
        switch action {
        case .voice:
            Image(systemName: "waveform")
                .font(.system(size: metrics.waveformFontSize, weight: .regular))
                .foregroundStyle(palette.text)
        case .stopRecording:
            Image(systemName: "stop.fill")
                .font(.system(size: metrics.waveformFontSize * 0.8))
                .foregroundStyle(.red)
        case .send:
            Image(systemName: "arrow.up")
                .font(.system(size: metrics.sendDiameter * 0.6, weight: .semibold))
                .foregroundStyle(palette.onAccent)
                .frame(width: metrics.sendDiameter, height: metrics.sendDiameter)
                .background(palette.accent, in: Circle())
        case .sending:
            ProgressView().controlSize(.small).tint(palette.accent)
        }
    }

    private var actionLabel: String {
        switch action {
        case .voice: return "录语音"
        case .stopRecording: return "停止录音"
        case .send: return sendLabel
        case .sending: return "正在发送"
        }
    }
}
