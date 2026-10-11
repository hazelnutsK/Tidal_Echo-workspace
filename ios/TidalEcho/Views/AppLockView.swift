import SwiftUI

struct AppLockView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var appLock: AppLockController

    private var palette: EchoPalette { model.theme.palette }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [palette.backgroundTop, palette.backgroundBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: "faceid")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(palette.accent)
                    .frame(width: 84, height: 84)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(palette.hairline))

                VStack(spacing: 6) {
                    Text("Tidal Echo 已锁定")
                        .font(.title3.weight(.semibold))
                    Text("使用 \(appLock.biometryName) 或设备密码继续")
                        .font(.subheadline)
                        .foregroundStyle(palette.secondaryText)
                }

                Button {
                    Task { await appLock.unlockIfNeeded() }
                } label: {
                    Group {
                        if appLock.isAuthenticating {
                            ProgressView().tint(.white)
                        } else {
                            Label("解锁", systemImage: "lock.open")
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 150, height: 44)
                    .background(palette.accent, in: Capsule())
                }
                .disabled(appLock.isAuthenticating)
            }
            .foregroundStyle(palette.text)
            .padding(28)
        }
        .alert(
            "无法解锁",
            isPresented: Binding(
                get: { appLock.errorMessage != nil },
                set: { if !$0 { appLock.errorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) { appLock.errorMessage = nil }
        } message: {
            Text(appLock.errorMessage ?? "")
        }
    }
}

struct AppPrivacyCover: View {
    let theme: EchoTheme

    var body: some View {
        ZStack {
            theme.palette.background.ignoresSafeArea()
            Image(systemName: "wave.3.right.circle.fill")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(theme.palette.accent)
        }
        .accessibilityHidden(true)
    }
}
