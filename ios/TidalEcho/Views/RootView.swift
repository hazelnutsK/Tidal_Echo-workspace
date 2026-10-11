import SwiftUI

struct RootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var appLock = AppLockController.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var launchPresentationComplete = false

    var body: some View {
        ZStack {
            if showsLaunchView {
                LaunchView(theme: model.theme)
                    .transition(.opacity)
            } else {
                Group {
                    switch model.phase {
                    case .launching:
                        LaunchView(theme: model.theme)
                    case .signedOut, .connecting:
                        LoginView(model: model)
                    case .connected:
                        if appLock.isEnabled && !appLock.isUnlocked {
                            AppLockView(model: model, appLock: appLock)
                        } else {
                            ChatView(model: model)
                        }
                    }
                }
                .transition(.opacity)
            }

            if appLock.isEnabled && scenePhase != .active && !showsLaunchView {
                AppPrivacyCover(theme: model.theme)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.34), value: showsLaunchView)
        .task {
            NativeNotificationCenter.shared.fetchHandler = { [weak model] in
                guard let model else { return false }
                return await model.backgroundRefreshForNotifications()
            }

            async let bootstrapTask: Void = model.bootstrap()
            // 手写开屏把 Aquila 写完、爱心落定、副标题收拢约 2.0s（她 2026-09-05 定的节奏）。
            // bootstrap 更慢时开屏自然停在写完的样子，不会有突兀的收尾。
            let minimumPresentation: Duration = reduceMotion ? .milliseconds(250) : .milliseconds(2150)
            try? await Task.sleep(for: minimumPresentation)
            launchPresentationComplete = true
            await bootstrapTask
            if model.phase == .connected {
                await appLock.unlockIfNeeded()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                appLock.lockForBackground()
            case .active:
                guard launchPresentationComplete else { return }
                if model.phase == .connected {
                    Task { await appLock.unlockIfNeeded() }
                }
                // iOS 冻过一次之后这边常是半死的（历史被掐断、轮询任务已退出），
                // 回到前台统一自愈一次，别让她只能划掉 App 重开
                Task { await model.resumeFromForeground() }
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .alert(
            "Tidal Echo",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var showsLaunchView: Bool {
        !launchPresentationComplete || model.phase == .launching
    }
}
