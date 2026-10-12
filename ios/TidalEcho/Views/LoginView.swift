import SwiftUI

/// 登录：开屏写完的 Aquila 在原地停一拍，再往上浮，让出一块玻璃给她填密钥。
/// 底用空间页那套雾（她换过底图就是她的底图），门里门外是同一个世界。
struct LoginView: View {
    @ObservedObject var model: AppModel
    @State private var serverAddress = ""
    @State private var secret = ""
    @State private var revealsSecret = false
    @State private var editingAddress = false
    @State private var screen: CGSize = .zero
    @State private var settled = false
    @State private var shakes: CGFloat = 0
    @FocusState private var focus: Field?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 一行输入框的高度；只剩密钥一行时，玻璃的圆角正好是它的一半，整块成胶囊。
    private static let rowHeight: CGFloat = 46

    private enum Field: Hashable {
        case address
        case secret
    }

    private var style: SpaceStyle { SpaceStyle(theme: model.theme) }
    private var isConnecting: Bool { model.phase == .connecting }
    private var canSubmit: Bool {
        !isConnecting
            && !serverAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    /// 记得地址就收成一行小字，页面上只剩密钥要填。
    private var showsAddressField: Bool { editingAddress || model.savedServerAddress.isEmpty }

    private var savedHost: String {
        let raw = model.savedServerAddress
        return URL(string: raw)?.host() ?? raw
    }

    var body: some View {
        ZStack {
            SpaceBackdrop(style: style, showsSharpTop: true)

            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { focus = nil }

            signature

            form
                .ignoresSafeArea(.container)

            footer
                .ignoresSafeArea(.keyboard)
        }
        .foregroundStyle(style.ink)
        .tint(style.accent)
        .animation(.spring(response: 0.55, dampingFraction: 0.86), value: focus)
        .animation(.smooth(duration: 0.35), value: showsAddressField)
        .sensoryFeedback(.error, trigger: shakes)
        .onChange(of: model.phase) { old, new in
            // 连不上：玻璃摇一摇（错误原因照旧弹窗说）
            guard old == .connecting, new == .signedOut else { return }
            withAnimation(.linear(duration: 0.42)) { shakes += 1 }
        }
        .task {
            if serverAddress.isEmpty { serverAddress = model.savedServerAddress }
            guard !settled else { return }
            if reduceMotion {
                settled = true
                return
            }
            // 等开屏那层淡完（RootView 0.25s）再动，不然两枚签名会叠出重影
            try? await Task.sleep(for: .milliseconds(260))
            withAnimation(.spring(response: 0.95, dampingFraction: 0.88)) { settled = true }
        }
    }

    // MARK: 签名

    private struct Pose {
        let centerY: CGFloat
        let scale: CGFloat
    }

    /// 落定后的位置：平时在上面四分之一多一点；打字时再往上缩，给键盘腾地方。
    private func restPose(focused: Bool) -> Pose {
        focused
            ? Pose(centerY: screen.height * 0.17, scale: 0.62)
            : Pose(centerY: screen.height * 0.28, scale: 0.8)
    }

    private var pose: Pose {
        settled
            ? restPose(focused: focus != nil)
            : Pose(centerY: LaunchSignature.anchorY(in: screen), scale: 1)
    }

    /// 玻璃卡从签名底下开始（屏幕坐标）。按落定后的位置算，入场时卡片不跟着跳。
    private var formTop: CGFloat {
        let rest = restPose(focused: focus != nil)
        return rest.centerY + LaunchSignature.bottomDrop(in: screen) * rest.scale + 34
    }

    private var signature: some View {
        LaunchSignature(theme: model.theme)
            .scaleEffect(pose.scale, anchor: UnitPoint(x: 0.5, y: LaunchSignature.anchorFraction))
            .offset(y: pose.centerY - LaunchSignature.anchorY(in: screen))
            .ignoresSafeArea()
            // 签名的 Canvas 铺满整屏（含刘海和底部安全区），这里量到的却是安全区内的尺寸；
            // 把两头的 inset 加回来，签名和玻璃卡才在同一套坐标里——少了这一步，
            // 玻璃会压到 A 和 q 的下伸笔画上（09-27 CI 截图里抓到的）。
            .onGeometryChange(for: CGSize.self) { proxy in
                CGSize(
                    width: proxy.size.width,
                    height: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
                )
            } action: { screen = $0 }
            .allowsHitTesting(false)
    }

    // MARK: 表单

    private var form: some View {
        VStack(spacing: 12) {
            Color.clear.frame(height: max(0, formTop - 12))

            card
                .modifier(LoginShake(shakes: shakes))

            enterButton

            if !showsAddressField {
                addressNote
                    .transition(.opacity)
            }

            Spacer(minLength: 0)
        }
        // 她 09-27 要小一点、圆一点：两边多收进来，框和按钮都变成胶囊
        .padding(.horizontal, 48)
        .opacity(settled ? 1 : 0)
        .offset(y: settled ? 0 : 16)
    }

    private var card: some View {
        VStack(spacing: 0) {
            if showsAddressField {
                row("地址") {
                    TextField(
                        "https://你的域名/relay",
                        text: $serverAddress,
                        prompt: Text(verbatim: "https://你的域名/relay").foregroundColor(style.faint)
                    )
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .address)
                    .submitLabel(.next)
                    .onSubmit { focus = .secret }
                }
                .transition(.opacity)

                SpaceHairline(style: style)
                    .padding(.leading, 72)
                    .transition(.opacity)
            }

            row("密钥") {
                HStack(spacing: 10) {
                    secretField
                    if !secret.isEmpty {
                        Button {
                            revealsSecret.toggle()
                            refocusSecret()
                        } label: {
                            Image(systemName: revealsSecret ? "eye.slash" : "eye")
                                .font(.system(size: 14))
                                .foregroundStyle(style.faint)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(revealsSecret ? "藏起密钥" : "显示密钥")
                        .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: secret.isEmpty)
            }
        }
        .spaceGlass(style, radius: Self.rowHeight / 2)
    }

    @ViewBuilder private var secretField: some View {
        let prompt = Text(verbatim: "连接密钥").foregroundColor(style.faint)
        Group {
            if revealsSecret {
                TextField("连接密钥", text: $secret, prompt: prompt)
            } else {
                SecureField("连接密钥", text: $secret, prompt: prompt)
            }
        }
        .textContentType(.password)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .focused($focus, equals: .secret)
        .submitLabel(.go)
        .onSubmit(submit)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 16) {
            Text(label)
                .font(.system(size: 13))
                .tracking(1.5)
                .foregroundStyle(style.sub)
                .frame(width: 36, alignment: .leading)
            content()
                .font(.system(size: 15))
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .frame(height: Self.rowHeight)
    }

    private var enterButton: some View {
        let lit = canSubmit || isConnecting
        return Button(action: submit) {
            HStack(spacing: 9) {
                if isConnecting {
                    ProgressView()
                        .controlSize(.small)
                        .tint(style.base)
                }
                Text(isConnecting ? "在路上" : "回家")
                    .font(.system(size: 15, weight: .medium))
                    .tracking(3)
            }
            .foregroundStyle(lit ? style.base : style.faint)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(style.ink.opacity(lit ? 0.9 : 0.07), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(SpacePressStyle())
        .disabled(!canSubmit)
        .animation(.easeOut(duration: 0.22), value: lit)
    }

    private var addressNote: some View {
        Button {
            editingAddress = true
            Task {
                try? await Task.sleep(for: .milliseconds(120))
                focus = .address
            }
        } label: {
            HStack(spacing: 6) {
                Text(verbatim: "连到 \(savedHost)")
                    .foregroundStyle(style.faint)
                Text("换一个")
                    .foregroundStyle(style.sub)
            }
            .font(.system(size: 12))
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        VStack {
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: "lock")
                    .font(.system(size: 9.5))
                Text("密钥只留在这台 iPhone 的钥匙串里")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(style.faint)
            .padding(.bottom, 12)
        }
        .opacity(settled ? 1 : 0)
        .allowsHitTesting(false)
    }

    // MARK: 动作

    private func submit() {
        guard canSubmit else { return }
        focus = nil
        Task { await model.login(serverAddress: serverAddress, secret: secret) }
    }

    /// SecureField 和 TextField 互换时焦点会丢，换完再点回去。
    private func refocusSecret() {
        Task {
            try? await Task.sleep(for: .milliseconds(60))
            focus = .secret
        }
    }
}

/// 密钥不对：左右晃三下，像摇头。
private struct LoginShake: GeometryEffect {
    var shakes: CGFloat

    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let fade = 1 - (shakes - shakes.rounded(.down))
        let dx = 8 * sin(shakes * .pi * 6) * fade
        return ProjectionTransform(CGAffineTransform(translationX: dx, y: 0))
    }
}
