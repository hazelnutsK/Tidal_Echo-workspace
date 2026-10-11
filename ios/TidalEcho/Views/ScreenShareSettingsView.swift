import ReplayKit
import SwiftUI

struct ScreenShareSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var model: AppModel
    @State private var preparation: ScreenSharePreparation?
    @State private var probeStatus: ScreenShareProbeStatus?
    @State private var isPreparing = false
    @State private var isCheckingProbe = false
    @State private var errorText: String?

    private var palette: EchoPalette { model.theme.palette }

    var body: some View {
        List {
            Section("给 Altair 看一眼") {
                Text("这不是持续录像。共享开始后会等你离开系统面板，再取一张压缩画面送进当前对话，然后自动结束。")

                Button {
                    Task { await prepare() }
                } label: {
                    HStack {
                        Label(
                            preparation == nil ? "准备一次共享" : "重新生成临时票据",
                            systemImage: "key.viewfinder"
                        )
                        Spacer()
                        if isPreparing { ProgressView() }
                    }
                }
                .disabled(isPreparing)

                if let preparation {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("临时票据已写入")
                                .font(.subheadline.weight(.semibold))
                            Text("约 \(max(1, preparation.expiresIn / 60)) 分钟内有效")
                                .font(.caption)
                                .foregroundStyle(palette.secondaryText)
                        }
                        Spacer()
                        BroadcastPickerButton()
                            .frame(width: 58, height: 58)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
                            .accessibilityLabel("打开系统屏幕共享")
                    }
                }
            }

            Section {
                if let preparation {
                    if preparation.localHandoffReady {
                        probeStatusLabel
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("无法开启本机票据通道", systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                            if let diagnostic = preparation.localHandoffDiagnostic {
                                Text(diagnostic)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(palette.secondaryText)
                                    .textSelection(.enabled)
                            }
                        }
                    }

                    Button {
                        Task { await checkProbe() }
                    } label: {
                        HStack {
                            Label("检查体检结果", systemImage: "stethoscope")
                            Spacer()
                            if isCheckingProbe { ProgressView() }
                        }
                    }
                    .disabled(isCheckingProbe)
                } else {
                    Text("点“准备一次共享”后，App 会短暂开启一个仅限本机的一次性票据通道。")
                        .foregroundStyle(palette.secondaryText)
                }
            } header: {
                Text("共享通道体检")
            } footer: {
                Text("不依赖 App Group 或长期 Relay 密钥；票据被扩展取走后，本机通道会立即关闭。")
            }

            Section("怎么用") {
                Label("先点“准备一次共享”", systemImage: "1.circle")
                Label("点右侧系统广播按钮，再选 Tidal Echo", systemImage: "2.circle")
                Label("倒计时后切到想给我看的页面，不需要配置页", systemImage: "3.circle")
            }

            Section("你始终看得见") {
                Label("共享期间系统会显示红色录制标记", systemImage: "record.circle")
                Label("只上传一张 JPEG，不采集麦克风或 App 音频", systemImage: "photo")
                Label("票据一次有效，不包含你的长期 Relay 密钥", systemImage: "lock.shield")
                Label("随时可从控制中心停止", systemImage: "xmark.circle")
            }
        }
        .tint(palette.accent)
        .scrollContentBackground(.hidden)
        .background(palette.background.ignoresSafeArea())
        .navigationTitle("屏幕共享")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, preparation != nil else { return }
            Task { await checkProbe(silent: true) }
        }
        .alert(
            "没有准备好",
            isPresented: Binding(
                get: { errorText != nil },
                set: { if !$0 { errorText = nil } }
            )
        ) {
            Button("好", role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
    }

    @MainActor
    private func prepare() async {
        isPreparing = true
        preparation = nil
        probeStatus = nil
        defer { isPreparing = false }
        do {
            let value = try await model.prepareScreenShare()
            preparation = value
            probeStatus = try? await model.screenShareProbeStatus(probeID: value.probeID)
        } catch is CancellationError {
            return
        } catch {
            errorText = error.localizedDescription
        }
    }

    @ViewBuilder
    private var probeStatusLabel: some View {
        switch probeStatus?.status {
        case "passed":
            Label("验证通过：主 App 与录屏扩展完成了一次性交接", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        case "failed":
            Label(probeFailureText, systemImage: "xmark.seal.fill")
                .foregroundStyle(.red)
        default:
            Label("本机通道已准备，等待录屏扩展取走票据", systemImage: "hourglass")
                .foregroundStyle(palette.secondaryText)
        }
    }

    private var probeFailureText: String {
        switch probeStatus?.reason {
        case "extension_could_not_read_group":
            return "验证失败：录屏扩展没有收到交接探针"
        case "marker_mismatch":
            return "验证失败：主 App 与扩展读到的暗号不同"
        case "main_app_did_not_supply_marker":
            return "验证失败：主 App 没有生成暗号"
        default:
            return "验证失败：本机票据交接没有完成"
        }
    }

    @MainActor
    private func checkProbe(silent: Bool = false) async {
        guard let preparation else { return }
        isCheckingProbe = true
        defer { isCheckingProbe = false }
        do {
            probeStatus = try await model.screenShareProbeStatus(probeID: preparation.probeID)
        } catch is CancellationError {
            return
        } catch {
            if !silent { errorText = error.localizedDescription }
        }
    }
}
