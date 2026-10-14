@preconcurrency import AVFoundation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct SettingsPageBackground: View {
    let theme: EchoTheme
    let palette: EchoPalette

    @ViewBuilder
    var body: some View {
        if theme == .mist {
            Color.white
        } else {
            palette.background
        }
    }
}

private func settingsRowBackground(theme: EchoTheme, palette: EchoPalette) -> Color {
    theme == .mist ? Color.white : palette.composer.opacity(0.72)
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    let onSearch: () -> Void
    let onCall: () -> Void
    @State private var anniversary: AnniversarySummary?
    @State private var greeting: String?
    @Environment(\.dismiss) private var dismiss

    private var palette: EchoPalette { model.theme.palette }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        NavigationStack {
            ZStack {
                palette.background.ignoresSafeArea()
                if let image = model.backgroundImage {
                    GeometryReader { geometry in
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                            .opacity(model.backgroundOpacity * 0.46)
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                }

                ScrollView {
                    VStack(spacing: 18) {
                        VStack(spacing: 7) {
                            if let greeting, !greeting.isEmpty {
                                Text(greeting)
                                    .font(.system(size: 13))
                                    .foregroundStyle(palette.text.opacity(0.82))
                                    .multilineTextAlignment(.center)
                                    .lineSpacing(3)
                                    .transition(.opacity)
                            }
                            Text("A PLACE FOR EVERY ECHO")
                                .font(.system(size: 11.5, weight: .medium))
                                .tracking(2.1)
                                .foregroundStyle(palette.secondaryText)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 5)

                        GeometryReader { geometry in
                            let unit = (geometry.size.width - 20) / 3
                            HStack(spacing: 10) {
                                NavigationLink {
                                    EchoCalendarView(model: model)
                                } label: {
                                    AnniversaryWideCard(summary: anniversary, palette: palette)
                                }
                                .frame(width: unit * 2 + 10)

                                Button { leaveHub(for: onSearch) } label: {
                                    HubTile(icon: "magnifyingglass", title: "搜索", subtitle: "全局消息", palette: palette, isMist: model.theme == .mist)
                                }
                                .frame(width: unit)
                            }
                            .buttonStyle(.plain)
                        }
                        .frame(height: 104)

                        LazyVGrid(columns: columns, spacing: 10) {
                            HubNavigationTile(icon: "paintpalette", title: "外观与聊天", subtitle: model.theme.title, palette: palette, isMist: model.theme == .mist) {
                                AppearanceSettingsView(model: model)
                            }
                            HubNavigationTile(icon: "brain.head.profile", title: "模型与连接", subtitle: "身体与 Relay", palette: palette, isMist: model.theme == .mist) {
                                ModelSettingsView(model: model)
                            }
                            HubNavigationTile(icon: "gauge.with.dots.needle.50percent", title: "会话与上下文", subtitle: "窗口与切换", palette: palette, isMist: model.theme == .mist) {
                                ContextSettingsView(model: model)
                            }
                            Button { leaveHub(for: onCall) } label: {
                                HubTile(icon: "phone.fill", title: "语音通话", subtitle: "打给 Altair", palette: palette, isMist: model.theme == .mist)
                            }
                            HubNavigationTile(icon: "chart.bar", title: "Claude 额度", subtitle: "限额与用量", palette: palette, isMist: model.theme == .mist) {
                                ClaudeQuotaView(model: model)
                            }
                            HubNavigationTile(icon: "gauge.with.dots.needle.50percent", title: "Codex 额度", subtitle: "本机账号限额", palette: palette, isMist: model.theme == .mist) {
                                CodexQuotaView(model: model)
                            }
                            HubNavigationTile(icon: "bell.badge", title: "通知与后台", subtitle: "提醒与音频", palette: palette, isMist: model.theme == .mist) {
                                NotificationSettingsView(model: model)
                            }
                            HubNavigationTile(icon: "faceid", title: "隐私与系统", subtitle: "Face ID 与权限", palette: palette, isMist: model.theme == .mist) {
                                PrivacySystemSettingsView(model: model)
                            }
                            HubNavigationTile(icon: "rectangle.inset.filled.and.person.filled", title: "屏幕共享", subtitle: "只给我看一眼", palette: palette, isMist: model.theme == .mist) {
                                ScreenShareSettingsView(model: model)
                            }
                        }
                        .buttonStyle(.plain)

                        VStack(spacing: 11) {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Relay")
                                        .font(.caption.weight(.semibold))
                                    Text(model.savedServerAddress)
                                        .font(.caption2)
                                        .foregroundStyle(palette.secondaryText)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Circle()
                                    .fill(model.isStreamConnected ? Color.green : palette.secondaryText)
                                    .frame(width: 7, height: 7)
                            }
                            Divider().overlay(palette.hairline)
                            HStack {
                                Button("重新加载") { Task { await model.refresh() } }
                                Spacer()
                                Button("退出并清除密钥", role: .destructive) {
                                    dismiss()
                                    model.logout()
                                }
                            }
                            .font(.caption.weight(.medium))
                        }
                        .foregroundStyle(palette.text)
                        .padding(14)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 20).stroke(palette.hairline))
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .preferredColorScheme(model.theme.preferredColorScheme)
        .task { anniversary = try? await model.relationshipAnniversary() }
        .task { greeting = await model.greetingForCurrentTime() }
    }

    private func leaveHub(for action: @escaping () -> Void) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { action() }
    }
}

private struct AnniversaryWideCard: View {
    let summary: AnniversarySummary?
    let palette: EchoPalette

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: "heart")
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(palette.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("在一起")
                    .font(.system(size: 13, weight: .semibold))
                Text(summary.map { "\($0.daysSince) 天" } ?? "尚未设置")
                    .font(.system(size: summary == nil ? 18 : 26, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Text(startText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(palette.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(palette.text)
        .padding(.horizontal, 17)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(palette.hairline))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var startText: String {
        guard let raw = summary?.startDate else { return "从日历添加" }
        let input = DateFormatter()
        input.locale = Locale(identifier: "en_US_POSIX")
        input.dateFormat = "yyyy-MM-dd"
        guard let date = input.date(from: raw) else { return "从 \(raw) 起" }
        let output = DateFormatter()
        output.locale = Locale(identifier: "zh_CN")
        output.dateFormat = "从 M月d日起"
        return output.string(from: date)
    }
}

private struct HubNavigationTile<Destination: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    let palette: EchoPalette
    let isMist: Bool
    let destination: Destination

    init(
        icon: String,
        title: String,
        subtitle: String,
        palette: EchoPalette,
        isMist: Bool,
        @ViewBuilder destination: () -> Destination
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.palette = palette
        self.isMist = isMist
        self.destination = destination()
    }

    var body: some View {
        NavigationLink(destination: destination) {
            HubTile(icon: icon, title: title, subtitle: subtitle, palette: palette, isMist: isMist)
        }
    }
}

private struct HubTile: View {
    let icon: String
    let title: String
    let subtitle: String
    let palette: EchoPalette
    let isMist: Bool

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(palette.accent)
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(palette.text)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text(subtitle)
                .font(.system(size: 9.5))
                .foregroundStyle(palette.secondaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 104)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(isMist ? 0.64 : 1)
        }
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(palette.hairline))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct NotificationSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var notifications = NativeNotificationCenter.shared
    private var palette: EchoPalette { model.theme.palette }

    var body: some View {
        List {
            Section("原生通知") {
                Toggle("允许消息提醒", isOn: Binding(
                    get: { notifications.enabled },
                    set: { value in
                        if value {
                            Task { _ = await notifications.requestAuthorization() }
                        } else {
                            notifications.enabled = false
                            Task { await notifications.refreshAuthorizationStatus() }
                        }
                    }
                ))
                LabeledContent("权限状态", value: notifications.authorizationText)
                    .foregroundStyle(palette.secondaryText)
                Button("发送测试通知") { notifications.scheduleTest() }
                    .disabled(!notifications.enabled)
                if notifications.authorizationText == "系统已拒绝" {
                    Button("打开系统设置") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    }
                }
            }

            Section("后台能力") {
                Label("语音条播放可在锁屏后继续", systemImage: "waveform")
                Label("通话期间保持麦克风和音频会话", systemImage: "phone.fill")
                Label("系统会择机后台刷新新消息", systemImage: "arrow.clockwise")
            }

            Section {
                Text("当前个人 P12 没有 APNs/PushKit 权限：App 被系统彻底结束后，无法保证立即收到原生通知或系统来电。以后换成开发者账号和带推送权限的描述文件，可以直接在这一层接入真正的远程推送。")
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryText)
            }
        }
        .tint(palette.accent)
        .scrollContentBackground(.hidden)
        .background(SettingsPageBackground(theme: model.theme, palette: palette).ignoresSafeArea())
        .listRowBackground(settingsRowBackground(theme: model.theme, palette: palette))
        .navigationTitle("通知与后台")
        .navigationBarTitleDisplayMode(.inline)
        .task { await notifications.refreshAuthorizationStatus() }
    }
}

private struct PrivacySystemSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var appLock = AppLockController.shared
    @ObservedObject private var nativeEvents = NativeEventStore.shared
    @State private var isChangingLock = false
    @State private var isRequestingPermission = false
    @State private var errorText: String?

    private var palette: EchoPalette { model.theme.palette }

    var body: some View {
        List {
            Section {
                Toggle("使用 \(appLock.biometryName) 锁定 App", isOn: Binding(
                    get: { appLock.isEnabled },
                    set: { enabled in
                        Task { await changeAppLock(enabled) }
                    }
                ))
                .disabled(
                    isChangingLock
                        || (!appLock.isBiometryAvailable && !appLock.isEnabled)
                )
                LabeledContent("状态", value: appLock.statusText)
                    .foregroundStyle(palette.secondaryText)
            } header: {
                Text("App 锁")
            } footer: {
                Text("开启后，冷启动和每次从后台回来都需要验证；关闭时也会先确认身份。解锁允许设备密码兜底。")
            }

            Section("系统日历与提醒事项") {
                PermissionStatusRow(
                    title: "iOS 日历",
                    subtitle: "仅添加，不读取已有日程",
                    icon: "calendar.badge.plus",
                    status: nativeEvents.calendarStatusText,
                    palette: palette
                )
                Button(nativeEvents.canWriteEvents ? "日历权限已就绪" : "允许添加到系统日历") {
                    Task { await requestCalendarAccess() }
                }
                .disabled(nativeEvents.canWriteEvents || isRequestingPermission)

                PermissionStatusRow(
                    title: "提醒事项",
                    subtitle: "把选中的日程建立为提醒",
                    icon: "checklist",
                    status: nativeEvents.reminderStatusText,
                    palette: palette
                )
                Button(nativeEvents.canWriteReminders ? "提醒事项权限已就绪" : "允许添加到提醒事项") {
                    Task { await requestReminderAccess() }
                }
                .disabled(nativeEvents.canWriteReminders || isRequestingPermission)
            }

            Section {
                PermissionStatusRow(
                    title: "相机",
                    subtitle: "从聊天输入栏的 + 菜单拍照",
                    icon: "camera",
                    status: cameraStatusText,
                    palette: palette
                )
                if hasDeniedPermission {
                    Button("打开系统设置") {
                        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(url)
                    }
                }
            } header: {
                Text("相机")
            } footer: {
                Text("相机权限只会在你第一次点“相机”时请求。拍下的照片先作为待发送附件，不会自动发出。")
            }
        }
        .tint(palette.accent)
        .scrollContentBackground(.hidden)
        .background(SettingsPageBackground(theme: model.theme, palette: palette).ignoresSafeArea())
        .listRowBackground(settingsRowBackground(theme: model.theme, palette: palette))
        .navigationTitle("隐私与系统")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            appLock.refreshBiometryName()
            nativeEvents.refreshAuthorizationStatus()
        }
        .alert(
            "系统权限",
            isPresented: Binding(
                get: { errorText != nil || appLock.errorMessage != nil },
                set: {
                    if !$0 {
                        errorText = nil
                        appLock.errorMessage = nil
                    }
                }
            )
        ) {
            if hasDeniedPermission {
                Button("打开系统设置") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
            }
            Button("好", role: .cancel) {
                errorText = nil
                appLock.errorMessage = nil
            }
        } message: {
            Text(errorText ?? appLock.errorMessage ?? "")
        }
    }

    private var cameraStatusText: String {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined: return "使用时询问"
        case .restricted: return "受系统限制"
        case .denied: return "系统已拒绝"
        case .authorized: return "已允许"
        @unknown default: return "未知"
        }
    }

    private var hasDeniedPermission: Bool {
        cameraStatusText == "系统已拒绝"
            || nativeEvents.calendarStatusText == "系统已拒绝"
            || nativeEvents.reminderStatusText == "系统已拒绝"
    }

    @MainActor
    private func changeAppLock(_ enabled: Bool) async {
        isChangingLock = true
        defer { isChangingLock = false }
        _ = await appLock.setEnabled(enabled)
    }

    @MainActor
    private func requestCalendarAccess() async {
        isRequestingPermission = true
        defer { isRequestingPermission = false }
        if !(await nativeEvents.requestCalendarAccess()) {
            errorText = "没有获得系统日历写入权限。"
        }
    }

    @MainActor
    private func requestReminderAccess() async {
        isRequestingPermission = true
        defer { isRequestingPermission = false }
        if !(await nativeEvents.requestReminderAccess()) {
            errorText = "没有获得提醒事项权限。"
        }
    }
}

private struct PermissionStatusRow: View {
    let title: String
    let subtitle: String
    let icon: String
    let status: String
    let palette: EchoPalette

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(palette.accent)
                .frame(width: 30, height: 30)
                .background(palette.accent.opacity(0.11), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
            }
            Spacer()
            Text(status)
                .font(.caption)
                .foregroundStyle(palette.secondaryText)
        }
    }
}

private struct SettingsRouteLabel: View {
    let icon: String
    let title: String
    let subtitle: String
    let badge: String?
    let palette: EchoPalette

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(palette.accent)
                .frame(width: 38, height: 38)
                .background(palette.aiBubble, in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).foregroundStyle(palette.text)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
            }
            Spacer()
            if let badge {
                Text(badge)
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct AppearanceSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var backgroundItem: PhotosPickerItem?
    @State private var aiAvatarItem: PhotosPickerItem?
    @State private var humanAvatarItem: PhotosPickerItem?
    @State private var imageError: String?
    @State private var showingFontImporter = false
    @State private var isImportingFont = false
    @State private var fontError: String?
    @State private var pendingFontDeletion: ImportedChatFont?
    @State private var namingAppearance = false
    @State private var appearanceName = ""
    @State private var pendingAppearance: SavedAppearance?
    @State private var appearanceError: String?
    private var palette: EchoPalette { model.theme.palette }

    var body: some View {
        List {
            Section("昵称备注") {
                TextField("小克", text: $model.peerRemark)
                    .textInputAutocapitalization(.never)
                Text("只改变这台设备上的显示名称。")
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryText)
            }

            Section("主题") {
                ForEach(EchoTheme.allCases) { theme in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { model.applyTheme(theme) }
                    } label: {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(theme.palette.background)
                                .frame(width: 34, height: 34)
                                .overlay(Circle().stroke(theme.palette.hairline))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(theme.title).foregroundStyle(palette.text)
                                Text(theme.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(palette.secondaryText)
                            }
                            Spacer()
                            if model.theme == theme {
                                Image(systemName: "checkmark").foregroundStyle(palette.accent)
                            }
                        }
                    }
                }
            }

            Section {
                ForEach(model.savedAppearances) { saved in
                    Button { pendingAppearance = saved } label: {
                        SavedAppearanceRow(model: model, saved: saved, palette: palette)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { model.deleteSavedAppearance(saved) } label: {
                            Label("删除", systemImage: "trash")
                        }
                        Button {
                            do { try model.saveCurrentAppearance(named: saved.name, replacing: saved) }
                            catch { appearanceError = error.localizedDescription }
                        } label: {
                            Label("用现在的覆盖", systemImage: "square.and.arrow.down")
                        }
                        .tint(palette.accent)
                    }
                }
                Button {
                    appearanceName = "我的主题 \(model.savedAppearances.count + 1)"
                    namingAppearance = true
                } label: {
                    Label("把现在的样子存成主题", systemImage: "plus.circle")
                }
            } header: {
                Text("我的主题")
            } footer: {
                Text("会存下主题、气泡、字体、颜色和壁纸，头像不变。点一下套用；左滑可以删除，或者用现在的样子覆盖它。")
            }

            Section("聊天布局") {
                Picker("布局", selection: $model.chatLayoutStyle) {
                    ForEach(ChatLayoutStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                Text("仿 iMessage：顶部头像切换窗口，底部加号打开附件与表情包。")
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryText)
            }

            Section("输入栏") {
                Picker("样式", selection: $model.composerStyle) {
                    ForEach(ComposerStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                Text(model.composerStyle.note)
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryText)
            }

            Section("文字") {
                Picker("聊天字体", selection: $model.chatFont) {
                    ForEach(model.availableChatFonts) { font in
                        Text(model.chatFontTitle(font)).tag(font)
                    }
                }
                if model.chatFont.glyphLanguage != nil {
                    Text("只切换聊天里的汉字字形，界面保留简体中文，消息按原文保存和发送。")
                        .font(.footnote)
                        .foregroundStyle(palette.secondaryText)
                }

                Button { showingFontImporter = true } label: {
                    HStack {
                        Label("导入字体", systemImage: "square.and.arrow.down")
                        Spacer()
                        if isImportingFont { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(isImportingFont)
                Text("从“文件”选择 TTF、OTF 或 TTC 字体，导入后会自动选用。")
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryText)

                ForEach(model.importedChatFonts) { font in
                    HStack {
                        Text(font.displayName)
                            .font(font.chatFont.font(size: 16, numericWeight: 400))
                            .foregroundStyle(palette.text)
                            .lineLimit(1)
                        Spacer()
                        Button(role: .destructive) { pendingFontDeletion = font } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("删除字体 \(font.displayName)")
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("小雪，今天的花很好看。")
                    if model.chatFont.glyphLanguage != nil {
                        Text("骨、直、令、返、雨、花、雪")
                    }
                    Text("Tidal Echo · 0123456789")
                }
                .font(model.chatFont.font(size: 17 * model.fontScale, numericWeight: model.chatWeight))
                .foregroundStyle(palette.text)
                .padding(.vertical, 5)

                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("字体大小")
                        Spacer()
                        Text("\(Int((model.fontScale * 100).rounded()))%")
                            .foregroundStyle(palette.secondaryText)
                    }
                    Slider(value: $model.fontScale, in: 0.85...1.35, step: 0.05)
                        .tint(palette.accent)
                }

                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("聊天字重")
                        Spacer()
                        Text("\(Int(model.chatWeight))")
                            .foregroundStyle(palette.secondaryText)
                    }
                    Slider(value: $model.chatWeight, in: 300...800, step: 20)
                        .tint(palette.accent)
                    if model.chatFont == .system {
                        Text(EchoChatFont.weightDiagnostic(model.chatWeight))
                            .font(.caption2)
                            .foregroundStyle(palette.secondaryText)
                    } else if model.chatFont == .wenKai {
                        Text(EchoChatFont.wenKaiWeightDiagnostic(model.chatWeight))
                            .font(.caption2)
                            .foregroundStyle(palette.secondaryText)
                    } else if case .imported(let name) = model.chatFont {
                        Text(Self.importedWeightNote(EchoChatFont.importedWeightSupport(name: name)))
                            .font(.caption2)
                            .foregroundStyle(palette.secondaryText)
                    }
                }

                Picker("我的气泡字体", selection: $model.humanChatFont) {
                    Text("跟聊天字体一样").tag(EchoChatFont?.none)
                    ForEach(model.availableChatFonts) { font in
                        Text(model.chatFontTitle(font)).tag(EchoChatFont?.some(font))
                    }
                }

                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("我的气泡字号")
                        Spacer()
                        Text("\(Int((model.humanFontScale * 100).rounded()))%")
                            .foregroundStyle(palette.secondaryText)
                    }
                    Slider(value: $model.humanFontScale, in: 0.85...1.35, step: 0.05)
                        .tint(palette.accent)
                    Text("上面的“字体大小”管 AI 的气泡和界面里其他文字，这个只管我的气泡。")
                        .font(.caption2)
                        .foregroundStyle(palette.secondaryText)
                }

                Text("这是我发的消息。")
                    .font(model.resolvedHumanChatFont.font(
                        size: 17 * model.humanFontScale, numericWeight: model.chatWeight
                    ))
                    .foregroundStyle(palette.text)
                    .padding(.vertical, 5)
            }

            Section("AI 回复时机") {
                Picker("AI 回复时机", selection: $model.aiReplyTiming) {
                    ForEach(AIReplyTiming.allCases) { timing in
                        Text(timing.title).tag(timing)
                    }
                }
                .pickerStyle(.segmented)

                Text(model.aiReplyTiming == .immediate
                    ? "每次点击发送后，AI 会马上收到消息。"
                    : "每条消息会立刻成为独立气泡；输入框为空时再点一次发送，AI 才会统一收到并回复。")
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryText)

                if !model.bundledMessageParts.isEmpty {
                    Label(
                        "已有 \(model.bundledMessageParts.count) 条消息等待 AI 统一回复",
                        systemImage: "tray.full.fill"
                    )
                }
            }

            bubbleSettingsSection

            Section("聊天背景") {
                if let image = model.backgroundImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(1 + model.backgroundBlur / 260)
                        .blur(radius: model.backgroundBlur)
                        .frame(height: 128)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                HStack {
                    PhotosPicker(selection: $backgroundItem, matching: .images) {
                        Label(model.backgroundImage == nil ? "选择图片" : "更换图片", systemImage: "photo")
                    }
                    Spacer()
                    if model.backgroundImage != nil {
                        Button("移除", role: .destructive) {
                            model.removeAppearanceImage(.background)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("背景透明度")
                        Spacer()
                        Text("\(Int(model.backgroundOpacity * 100))%")
                            .foregroundStyle(palette.secondaryText)
                    }
                    Slider(value: $model.backgroundOpacity, in: 0.05...1, step: 0.05)
                        .tint(palette.accent)
                }
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("背景模糊度")
                        Spacer()
                        Text("\(Int(model.backgroundBlur.rounded()))")
                            .foregroundStyle(palette.secondaryText)
                    }
                    Slider(value: $model.backgroundBlur, in: 0...24, step: 1)
                        .tint(palette.accent)
                }
            }

            Section("双方头像") {
                Toggle("显示 AI 头像", isOn: $model.showsAIAvatar)
                Toggle("显示我的头像", isOn: $model.showsHumanAvatar)
                avatarPickerRow(
                    title: "AI 头像",
                    image: model.aiAvatarImage,
                    selection: $aiAvatarItem,
                    kind: .aiAvatar
                )
                avatarPickerRow(
                    title: "我的头像",
                    image: model.humanAvatarImage,
                    selection: $humanAvatarItem,
                    kind: .humanAvatar
                )
            }

            Section("聊天挂件") {
                Toggle("显示小螃蟹", isOn: $model.showsClawdPet)
                Text("它会跟着桌面身体的状态切换动作。可以在聊天页拖到喜欢的位置，点一下会告诉你他正在做什么。")
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryText)
            }

        }
        .tint(palette.accent)
        .scrollContentBackground(.hidden)
        .background(SettingsPageBackground(theme: model.theme, palette: palette).ignoresSafeArea())
        .listRowBackground(settingsRowBackground(theme: model.theme, palette: palette))
        .navigationTitle("外观与聊天")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingFontImporter) {
            FilesDocumentPicker(
                contentTypes: [.font] + ["ttf", "otf", "ttc"].compactMap { UTType(filenameExtension: $0) },
                onPick: { url in
                    showingFontImporter = false
                    isImportingFont = true
                    Task {
                        defer {
                            isImportingFont = false
                            // asCopy 给的是沙盒临时副本，导入时已另存一份，这份用完就删。
                            try? FileManager.default.removeItem(at: url)
                        }
                        do { try await model.importChatFont(from: url) }
                        catch { fontError = error.localizedDescription }
                    }
                },
                onCancel: { showingFontImporter = false }
            )
            .ignoresSafeArea()
        }
        .alert("字体导入失败", isPresented: Binding(
            get: { fontError != nil },
            set: { if !$0 { fontError = nil } }
        )) {
            Button("好", role: .cancel) { fontError = nil }
        } message: { Text(fontError ?? "") }
        .confirmationDialog(
            "删除字体「\(pendingFontDeletion?.displayName ?? "")」？",
            isPresented: Binding(
                get: { pendingFontDeletion != nil },
                set: { if !$0 { pendingFontDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                guard let font = pendingFontDeletion else { return }
                pendingFontDeletion = nil
                Task {
                    do { try await model.deleteImportedChatFont(font) }
                    catch { fontError = error.localizedDescription }
                }
            }
            Button("取消", role: .cancel) { pendingFontDeletion = nil }
        } message: {
            Text("正在用它的地方会换回默认字体。TTC 文件里的其他字体会一起删掉。")
        }
        .alert("存成主题", isPresented: $namingAppearance) {
            TextField("名字", text: $appearanceName)
            Button("存") {
                let name = appearanceName.trimmingCharacters(in: .whitespacesAndNewlines)
                do { try model.saveCurrentAppearance(named: name.isEmpty ? "我的主题" : name) }
                catch { appearanceError = error.localizedDescription }
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog(
            "换成「\(pendingAppearance?.name ?? "")」？",
            isPresented: Binding(
                get: { pendingAppearance != nil },
                set: { if !$0 { pendingAppearance = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("换") {
                guard let saved = pendingAppearance else { return }
                pendingAppearance = nil
                withAnimation(.easeInOut(duration: 0.2)) { model.applySavedAppearance(saved) }
            }
            Button("取消", role: .cancel) { pendingAppearance = nil }
        } message: {
            Text("现在的样子没存的话会被替换掉。")
        }
        .alert("主题没存上", isPresented: Binding(
            get: { appearanceError != nil },
            set: { if !$0 { appearanceError = nil } }
        )) {
            Button("好", role: .cancel) { appearanceError = nil }
        } message: { Text(appearanceError ?? "") }
        .onChange(of: backgroundItem) { item in loadPhoto(item, kind: .background) }
        .onChange(of: aiAvatarItem) { item in loadPhoto(item, kind: .aiAvatar) }
        .onChange(of: humanAvatarItem) { item in loadPhoto(item, kind: .humanAvatar) }
        .alert("图片保存失败", isPresented: Binding(
            get: { imageError != nil },
            set: { if !$0 { imageError = nil } }
        )) {
            Button("好", role: .cancel) { imageError = nil }
        } message: { Text(imageError ?? "") }
    }

    @ViewBuilder
    private var bubbleSettingsSection: some View {
        Section("消息气泡") {
            Toggle("显示 AI 气泡框", isOn: $model.showsAIBubble)

            Picker("气泡样式", selection: $model.bubbleStyle) {
                ForEach(EchoBubbleStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.segmented)

            if model.bubbleStyle != .liquid {
                Picker("气泡形状", selection: $model.bubbleShapeStyle) {
                    ForEach(EchoBubbleShapeStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)
            }

            if model.bubbleStyle != .liquid, let spec = model.bubbleShapeStyle.smoothSpec {
                VStack(spacing: 12) {
                    smoothPreviewBubble("角给你看清楚", spec: spec, isHuman: false)
                    smoothPreviewBubble("就这个", spec: spec, isHuman: true)
                }
                .padding(.vertical, 7)
            }

            if model.bubbleStyle == .liquid {
                VStack(spacing: 12) {
                    HStack {
                        Text("好，就在这里慢慢调")
                            .font(model.chatFont.font(
                                size: PWAChatMetrics.bubbleFontSize(for: model.chatFont) * model.fontScale,
                                numericWeight: model.chatWeight
                            ))
                            .padding(.horizontal, previewPadding.horizontal)
                            .padding(.vertical, previewPadding.vertical)
                            .foregroundStyle(model.resolvedAIBubbleTextColor(default: palette.text))
                            .background {
                                LiquidGlassBubbleBackground(
                                    tint: model.resolvedAIBubbleColor(default: palette.aiBubble),
                                    tintOpacity: model.aiBubbleOpacity,
                                    radius: CGFloat(model.bubbleRadius),
                                    settings: model.liquidGlassSettings
                                )
                            }
                        Spacer(minLength: 24)
                    }
                    HStack {
                        Spacer(minLength: 24)
                        Text("气泡再透一点")
                            .font(model.chatFont.font(
                                size: PWAChatMetrics.bubbleFontSize(for: model.chatFont) * model.fontScale,
                                numericWeight: model.chatWeight
                            ))
                            .padding(.horizontal, previewPadding.horizontal)
                            .padding(.vertical, previewPadding.vertical)
                            .foregroundStyle(model.resolvedHumanBubbleTextColor(default: palette.text))
                            .background {
                                LiquidGlassBubbleBackground(
                                    tint: model.resolvedHumanBubbleColor(default: palette.humanBubble),
                                    tintOpacity: model.humanBubbleOpacity,
                                    radius: CGFloat(model.bubbleRadius),
                                    settings: model.liquidGlassSettings
                                )
                            }
                    }
                }
                .padding(.vertical, 7)
            }

            ColorPicker("AI 气泡颜色", selection: Binding(
                get: { model.resolvedAIBubbleColor(default: palette.aiBubble) },
                set: { model.setAIBubbleColor($0) }
            ), supportsOpacity: false)

            ColorPicker("我的气泡颜色", selection: Binding(
                get: { model.resolvedHumanBubbleColor(default: palette.humanBubble) },
                set: { model.setHumanBubbleColor($0) }
            ), supportsOpacity: false)

            ColorPicker("AI 气泡字体颜色", selection: Binding(
                get: { model.resolvedAIBubbleTextColor(default: palette.text) },
                set: { model.setAIBubbleTextColor($0) }
            ), supportsOpacity: false)

            ColorPicker("我的气泡字体颜色", selection: Binding(
                get: { model.resolvedHumanBubbleTextColor(default: palette.text) },
                set: { model.setHumanBubbleTextColor($0) }
            ), supportsOpacity: false)

            ColorPicker("思考与工具标题颜色", selection: Binding(
                get: { model.customProcessTitleColor ?? palette.secondaryText },
                set: { model.setProcessTitleColor($0) }
            ), supportsOpacity: false)

            Picker("思考与工具标题字体", selection: $model.processTitleFont) {
                Text("跟聊天字体一样").tag(EchoChatFont?.none)
                ForEach(model.availableChatFonts) { font in
                    Text(model.chatFontTitle(font)).tag(EchoChatFont?.some(font))
                }
            }

            Toggle("标题旁的展开小箭头", isOn: $model.showsProcessDisclosure)

            HStack(spacing: 6) {
                if model.showsProcessDisclosure {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                }
                Text("Thinking")
                    .font((model.processTitleFont ?? model.chatFont).font(size: 13 * model.fontScale, weight: .medium))
            }
            .foregroundStyle(model.customProcessTitleColor ?? palette.secondaryText)
            .padding(.vertical, 3)

            ColorPicker("时间戳颜色", selection: Binding(
                get: { model.customTimestampColor ?? palette.secondaryText },
                set: { model.setTimestampColor($0) }
            ), supportsOpacity: false)

            settingSlider(
                title: "AI 气泡透明度",
                valueText: "\(Int((model.aiBubbleOpacity * 100).rounded()))%",
                value: $model.aiBubbleOpacity,
                range: 0...1,
                step: 0.05
            )
            settingSlider(
                title: "我的气泡透明度",
                valueText: "\(Int((model.humanBubbleOpacity * 100).rounded()))%",
                value: $model.humanBubbleOpacity,
                range: 0...1,
                step: 0.05
            )
            // 软糖/利落 carry their own fixed radius, so the slider would do nothing there.
            if model.bubbleStyle == .liquid || model.bubbleShapeStyle.smoothSpec == nil {
                settingSlider(
                    title: "气泡圆角",
                    valueText: "\(Int(model.bubbleRadius.rounded()))",
                    value: $model.bubbleRadius,
                    range: 4...26,
                    step: 1
                )
            }
            settingSlider(
                title: "气泡宽度",
                valueText: "\(Int(model.bubbleWidthScale * 100))%",
                value: $model.bubbleWidthScale,
                range: 0.6...1.5,
                step: 0.05,
                note: "超过 120% 时只继续放宽 AI 气泡"
            )

            VStack(spacing: 10) {
                paddingPreviewBubble("这样字离边近一点", isHuman: false)
                paddingPreviewBubble("再松一点", isHuman: true)
            }
            .padding(.vertical, 6)
            settingSlider(
                title: "气泡左右内边距",
                valueText: Self.paddingOffsetText(model.bubblePaddingX),
                value: $model.bubblePaddingX,
                range: -6...12,
                step: 1
            )
            settingSlider(
                title: "气泡上下内边距",
                valueText: Self.paddingOffsetText(model.bubblePaddingY),
                value: $model.bubblePaddingY,
                range: -6...12,
                step: 1,
                note: "在当前主题和形状原有的边距上加减。"
            )
            settingSlider(
                title: "边框粗细",
                valueText: String(format: "%.1f", model.bubbleBorderWidth),
                value: $model.bubbleBorderWidth,
                range: 0...2,
                step: 0.25
            )

            if model.bubbleStyle == .liquid {
                VStack(alignment: .leading, spacing: 5) {
                    Label("原生 Glass：背景折射、模糊、光照与动态反馈", systemImage: "checkmark.circle")
                    Label("SwiftUI 轻量层：边缘色散、Fresnel 宽度与视觉厚度", systemImage: "slider.horizontal.3")
                    Label("需背景纹理 + Metal：真实扭曲、RGB 位移、放大与手动模糊", systemImage: "cpu")
                    Text("当前未启用 CABackdropLayer；每个消息气泡只创建一个原生 Glass。")
                        .padding(.top, 2)
                }
                .font(.caption)
                .foregroundStyle(palette.secondaryText)

                settingSlider(
                    title: "扭曲 strength",
                    valueText: String(format: "%.1f", model.liquidGlassStrength),
                    value: $model.liquidGlassStrength,
                    range: 0...100,
                    step: 1,
                    note: "原生模式下调节颜色厚度；真实折射强度需要背景纹理。"
                )
                settingSlider(
                    title: "色散 dispersion",
                    valueText: String(format: "%.2f", model.liquidGlassDispersion),
                    value: $model.liquidGlassDispersion,
                    range: 0...1,
                    step: 0.01,
                    note: "当前是轻量边缘色散；真实 RGB 位移需要 Metal 与背景纹理。"
                )
                settingSlider(
                    title: "过渡 rimWidth",
                    valueText: String(format: "%.2f", model.liquidGlassRimWidth),
                    value: $model.liquidGlassRimWidth,
                    range: 0...1,
                    step: 0.01,
                    note: "SwiftUI 调节 Fresnel 边缘宽度，不重复采样背景。"
                )
                settingSlider(
                    title: "放大 magnify",
                    valueText: "需增强玻璃",
                    value: $model.liquidGlassMagnify,
                    range: 0...1,
                    step: 0.01,
                    note: "必须取得气泡后方纹理；纯原生模式暂不执行。",
                    isEnabled: false
                )
                settingSlider(
                    title: "背景模糊 blur",
                    valueText: "原生接管",
                    value: $model.liquidGlassBlur,
                    range: 0...1,
                    step: 0.01,
                    note: "由 iOS 26 Glass 自动处理；连续手动模糊需要背景纹理。",
                    isEnabled: false
                )
                settingSlider(
                    title: "光学尺度 size",
                    valueText: String(format: "%.0f", model.liquidGlassSize),
                    value: $model.liquidGlassSize,
                    range: 80...260,
                    step: 1,
                    note: "SwiftUI 调节视觉厚度与边缘尺度。"
                )
            }

            Button("恢复主题配色") { model.resetBubbleColors() }
            Button("恢复外观默认值") {
                model.composerStyle = .original
                model.chatFont = .system
                model.fontScale = 1
                model.humanChatFont = nil
                model.humanFontScale = 1
                model.processTitleFont = nil
                model.showsProcessDisclosure = true
                model.showsAIAvatar = true
                model.showsHumanAvatar = false
                model.showsAIBubble = true
                model.aiBubbleOpacity = 1
                model.humanBubbleOpacity = 1
                model.bubbleRadius = 14
                model.bubbleWidthScale = 1
                model.bubblePaddingX = 0
                model.bubblePaddingY = 0
                model.bubbleBorderWidth = 0
                model.bubbleStyle = .classic
                model.bubbleShapeStyle = .standard
                model.liquidGlassStrength = 56.8
                model.liquidGlassDispersion = 0.39
                model.liquidGlassRimWidth = 0.28
                model.liquidGlassMagnify = 0
                model.liquidGlassBlur = 0.94
                model.liquidGlassSize = 174
                model.chatWeight = 400
                model.backgroundOpacity = 1
                model.resetBubbleColors()
            }
        }
    }

    @ViewBuilder
    private func smoothPreviewBubble(_ text: String, spec: SmoothBubbleSpec, isHuman: Bool) -> some View {
        let shape = SmoothCornerBubbleShape(radius: spec.radius, smoothing: spec.smoothing)
        HStack {
            if isHuman { Spacer(minLength: 24) }
            Text(text)
                .font(model.chatFont.font(
                    size: PWAChatMetrics.bubbleFontSize(for: model.chatFont) * model.fontScale,
                    numericWeight: model.chatWeight
                ))
                .foregroundStyle(isHuman
                    ? model.resolvedHumanBubbleTextColor(default: palette.text)
                    : model.resolvedAIBubbleTextColor(default: palette.text))
                .padding(.horizontal, previewPadding.horizontal)
                .padding(.vertical, previewPadding.vertical)
                .background {
                    shape.fill((isHuman
                        ? model.resolvedHumanBubbleColor(default: palette.humanBubble)
                        : model.resolvedAIBubbleColor(default: palette.aiBubble)).opacity(
                            isHuman ? model.humanBubbleOpacity : model.aiBubbleOpacity
                        ))
                }
                .overlay {
                    shape.stroke(palette.hairline, lineWidth: CGFloat(model.bubbleBorderWidth))
                }
            if !isHuman { Spacer(minLength: 24) }
        }
    }

    private var previewPadding: (horizontal: CGFloat, vertical: CGFloat) {
        ChatBubbleInsets.padding(
            bubbleStyle: model.bubbleStyle, shapeStyle: model.bubbleShapeStyle,
            isNest: model.theme == .nest, carriesBubble: true, offset: model.bubblePaddingOffset
        )
    }

    private static func paddingOffsetText(_ value: Double) -> String {
        let points = Int(value.rounded())
        return points == 0 ? "默认" : (points > 0 ? "+\(points)" : "\(points)")
    }

    /// 只为看边距：形状跟着当前的平滑角/圆角走，液态玻璃用同一个玻璃底。
    @ViewBuilder
    private func paddingPreviewBubble(_ text: String, isHuman: Bool) -> some View {
        let fill = (isHuman
            ? model.resolvedHumanBubbleColor(default: palette.humanBubble)
            : model.resolvedAIBubbleColor(default: palette.aiBubble))
        let opacity = isHuman ? model.humanBubbleOpacity : model.aiBubbleOpacity
        let spec = model.bubbleStyle == .liquid ? nil : model.bubbleShapeStyle.smoothSpec
        let shape: AnyShape = spec.map { AnyShape(SmoothCornerBubbleShape(radius: $0.radius, smoothing: $0.smoothing)) }
            ?? AnyShape(RoundedRectangle(cornerRadius: CGFloat(model.bubbleRadius), style: .continuous))
        HStack {
            if isHuman { Spacer(minLength: 24) }
            Text(text)
                .font(model.chatFont.font(
                    size: PWAChatMetrics.bubbleFontSize(for: model.chatFont) * model.fontScale,
                    numericWeight: model.chatWeight
                ))
                .foregroundStyle(isHuman
                    ? model.resolvedHumanBubbleTextColor(default: palette.text)
                    : model.resolvedAIBubbleTextColor(default: palette.text))
                .padding(.horizontal, previewPadding.horizontal)
                .padding(.vertical, previewPadding.vertical)
                .background {
                    if model.bubbleStyle == .liquid {
                        LiquidGlassBubbleBackground(
                            tint: fill, tintOpacity: opacity,
                            radius: CGFloat(model.bubbleRadius),
                            settings: model.liquidGlassSettings
                        )
                    } else {
                        shape.fill(fill.opacity(opacity))
                    }
                }
                .overlay {
                    if model.bubbleStyle != .liquid && model.bubbleBorderWidth > 0 {
                        shape.stroke(palette.hairline, lineWidth: CGFloat(model.bubbleBorderWidth))
                    }
                }
                .animation(.easeOut(duration: 0.15), value: model.bubblePaddingOffset)
            if !isHuman { Spacer(minLength: 24) }
        }
    }

    private static func importedWeightNote(_ support: EchoChatFont.ImportedWeightSupport) -> String {
        switch support {
        case .variable:
            return "可变字体，粗细可以连续调。"
        case .faces(let count):
            return "这个字体导入了 \(count) 档字重，滑块会换到最接近的那一档；400 是你选中的那一档。"
        case .single:
            return "这个字体文件只有一种字重，所以调不动。把同一字体的其他字重文件（Light、Medium、Bold 等）也导进来，滑块就能在它们之间换。"
        }
    }

    @ViewBuilder
    private func settingSlider(
        title: String,
        valueText: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        note: String? = nil,
        isEnabled: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                Spacer()
                Text(valueText).foregroundStyle(palette.secondaryText)
            }
            Slider(value: value, in: range, step: step)
                .tint(palette.accent)
                .disabled(!isEnabled)
            if let note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(palette.secondaryText)
            }
        }
    }

    @ViewBuilder
    private func avatarPickerRow(
        title: String,
        image: UIImage?,
        selection: Binding<PhotosPickerItem?>,
        kind: AppModel.AppearanceImageKind
    ) -> some View {
        HStack(spacing: 12) {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: kind == .humanAvatar ? "person.fill" : "sparkle")
                        .foregroundStyle(palette.accent)
                }
            }
            .frame(width: 42, height: 42)
            .background(palette.aiBubble)
            .clipShape(Circle())

            Text(title)
            Spacer()
            PhotosPicker(selection: selection, matching: .images) {
                Text(image == nil ? "选择" : "更换")
            }
            if image != nil {
                Button("移除", role: .destructive) { model.removeAppearanceImage(kind) }
                    .font(.caption)
            }
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem?, kind: AppModel.AppearanceImageKind) {
        guard let item else { return }
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw APIError.invalidResponse
                }
                try model.saveAppearanceImage(data: data, kind: kind)
            } catch {
                imageError = error.localizedDescription
            }
            switch kind {
            case .background: backgroundItem = nil
            case .aiAvatar: aiAvatarItem = nil
            case .humanAvatar: humanAvatarItem = nil
            }
        }
    }
}

private struct ModelChoice: Identifiable {
    let title: String
    let desktopID: String
    let directAPIID: String
    let openRouterID: String
    var id: String { title }
}

private struct ModelSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var brain: BrainTarget = .desktop
    @State private var currentModelID = ""
    @State private var loopURL = ""
    @State private var loopChainCount = 1
    @State private var isBusy = false
    @State private var errorText: String?
    @State private var notice: String?
    @State private var pendingDesktopChoice: ModelChoice?

    private var palette: EchoPalette { model.theme.palette }
    private let choices = [
        ModelChoice(title: "Opus 4.6", desktopID: "claude-opus-4-6", directAPIID: "[按量]claude-opus-4-6-thinking", openRouterID: "anthropic/claude-opus-4.6"),
        ModelChoice(title: "Opus 4.7", desktopID: "claude-opus-4-7", directAPIID: "[按量]claude-opus-4-7-thinking", openRouterID: "anthropic/claude-opus-4.7"),
        ModelChoice(title: "Opus 4.8", desktopID: "claude-opus-4-8", directAPIID: "[按量]claude-opus-4-8-thinking", openRouterID: "anthropic/claude-opus-4.8"),
        ModelChoice(title: "Opus 5", desktopID: "claude-opus-5[1m]", directAPIID: "", openRouterID: "anthropic/claude-opus-5"),
        ModelChoice(title: "Opus 5.5", desktopID: "claude-opus-5-5[1m]", directAPIID: "", openRouterID: "anthropic/claude-opus-5.5"),
        ModelChoice(title: "Fable 5", desktopID: "claude-fable-5[1m]", directAPIID: "[按量]claude-fable-5-thinking", openRouterID: "anthropic/claude-fable-5")
    ]

    var body: some View {
        List {
            Section("联系身体") {
                Picker("当前身体", selection: Binding(
                    get: { brain },
                    set: { target in Task { await switchBrain(to: target) } }
                )) {
                    ForEach(BrainTarget.allCases) { target in
                        Text(target.title).tag(target)
                    }
                }
                .pickerStyle(.segmented)

                Text(bodyDescription)
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
            }

            Section("模型选择") {
                if brain == .codex {
                    Text("Codex 跟随本机配置；可在 bridge 环境里用 CODEX_MODEL / CODEX_EFFORT 覆盖。")
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                } else {
                    if brain == .desktop {
                        Button {
                            pendingDesktopChoice = ModelChoice(title: "默认模型", desktopID: "", directAPIID: "", openRouterID: "")
                        } label: {
                            modelRow(title: "默认模型", id: "")
                        }
                    }

                    ForEach(choices.filter { brain == .desktop || !$0.directAPIID.isEmpty }) { choice in
                        Button {
                            if brain == .desktop {
                                pendingDesktopChoice = choice
                            } else {
                                Task { await saveAPIModel(choice) }
                            }
                        } label: {
                            modelRow(title: choice.title, id: modelID(for: choice))
                        }
                    }
                }

                if isBusy { ProgressView().tint(palette.accent) }
                if let notice {
                    Text(notice).font(.caption).foregroundStyle(palette.secondaryText)
                }
            }

            Section("连接") {
                LabeledContent("Relay", value: model.savedServerAddress)
                    .font(.footnote)
                if brain == .codex {
                    LabeledContent("Codex", value: "本机 app-server")
                        .font(.footnote)
                }
                if brain == .loop, !loopURL.isEmpty {
                    LabeledContent("API", value: loopURL)
                        .font(.footnote)
                }
                Button("刷新模型状态") { Task { await load() } }
            }

            Section("额度与 API") {
                NavigationLink("Claude 额度") {
                    ClaudeQuotaView(model: model)
                }
                NavigationLink("Codex 额度") {
                    CodexQuotaView(model: model)
                }
                NavigationLink("API 接口与用量") {
                    APIControlView(model: model)
                }
            }
        }
        .tint(palette.accent)
        .scrollContentBackground(.hidden)
        .background(SettingsPageBackground(theme: model.theme, palette: palette).ignoresSafeArea())
        .listRowBackground(settingsRowBackground(theme: model.theme, palette: palette))
        .navigationTitle("模型与连接")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .alert("Desktop 模型切换", isPresented: Binding(
            get: { pendingDesktopChoice != nil },
            set: { if !$0 { pendingDesktopChoice = nil } }
        )) {
            Button("取消", role: .cancel) { pendingDesktopChoice = nil }
            Button("切换并 Swap", role: .destructive) {
                guard let choice = pendingDesktopChoice else { return }
                pendingDesktopChoice = nil
                Task { await saveDesktopModel(choice) }
            }
        } message: {
            Text("会重启 Desktop 会话，最近对话将交接到新窗口，期间可能断开几十秒。")
        }
        .alert("模型设置失败", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("好", role: .cancel) { errorText = nil }
        } message: { Text(errorText ?? "") }
    }

    private var bodyDescription: String {
        switch brain {
        case .desktop: return "Claude Code channel 正在接收消息。"
        case .codex: return "本机 Codex app-server 正在接收消息。"
        case .loop: return "服务器 API loop 正在接收消息。"
        }
    }

    @ViewBuilder
    private func modelRow(title: String, id: String) -> some View {
        HStack {
            Text(title).foregroundStyle(palette.text)
            Spacer()
            if currentModelID == id {
                Image(systemName: "checkmark").foregroundStyle(palette.accent)
            }
        }
    }

    private func modelID(for choice: ModelChoice) -> String {
        if brain == .desktop { return choice.desktopID }
        if brain == .codex { return "" }
        return loopURL.contains("openrouter.ai") ? choice.openRouterID : choice.directAPIID
    }

    private func load() async {
        isBusy = true
        defer { isBusy = false }
        do {
            brain = try await model.settingsBrain()
            try await loadCurrentModel()
            switch brain {
            case .desktop: notice = "Desktop 切换模型会自动 Swap。"
            case .codex: notice = "Codex 使用本机 app-server 配置。"
            case .loop: notice = "API 模型切换后立即生效。"
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func loadCurrentModel() async throws {
        if brain == .desktop {
            currentModelID = try await model.settingsDesktopModel().model
        } else if brain == .loop {
            let config = try await model.settingsLoopConfig()
            loopChainCount = max(1, config.mainChain.count)
            loopURL = config.mainChain.first?.url ?? ""
            currentModelID = config.mainChain.first?.model ?? ""
        } else {
            currentModelID = ""
            loopURL = ""
            loopChainCount = 1
        }
    }

    private func switchBrain(to target: BrainTarget) async {
        guard target != brain else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            brain = try await model.updateSettingsBrain(target)
            try await loadCurrentModel()
            notice = "已切到 \(brain.title)。"
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func saveAPIModel(_ choice: ModelChoice) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let id = modelID(for: choice)
            let config = try await model.updateLoopModel(id, chainCount: loopChainCount)
            loopURL = config.mainChain.first?.url ?? loopURL
            currentModelID = config.mainChain.first?.model ?? id
            notice = "API 模型已切到 \(choice.title)。"
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func saveDesktopModel(_ choice: ModelChoice) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let response = try await model.updateDesktopModel(choice.desktopID)
            currentModelID = response.model
            notice = response.applied == true
                ? "Desktop 正在切换，稍等它带着交接回来。"
                : (response.note ?? "已保存，下次重启生效。")
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private struct QuotaWindow: Identifiable {
    let key: String
    let utilization: Double
    let resetsAt: String
    var id: String { key }

    var title: String {
        switch key {
        case "five_hour": return "5 小时窗口"
        case "seven_day": return "本周（全模型）"
        case "seven_day_opus": return "本周 Opus"
        case "seven_day_sonnet": return "本周 Sonnet"
        case "seven_day_oauth_apps": return "本周 OAuth 应用"
        case "extra_usage": return "超额用量"
        default:
            if key.localizedCaseInsensitiveContains("fable") { return "本周 Fable" }
            if key.localizedCaseInsensitiveContains("opus") { return "本周 Opus" }
            return key.replacingOccurrences(of: "_", with: " ")
        }
    }

    var percent: Double {
        let normalized = utilization > 0 && utilization <= 1 ? utilization * 100 : utilization
        return min(max(normalized, 0), 100)
    }
}

private struct ClaudeQuotaView: View {
    @ObservedObject var model: AppModel
    @State private var windows: [QuotaWindow] = []
    @State private var isLoading = false
    @State private var errorText: String?
    private var palette: EchoPalette { model.theme.palette }

    var body: some View {
        List {
            if isLoading && windows.isEmpty {
                ProgressView("读取 Claude 账号额度…").tint(palette.accent)
            }
            ForEach(windows) { window in
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text(window.title)
                        Spacer()
                        Text("\(Int(window.percent.rounded()))%")
                            .font(.headline.monospacedDigit())
                    }
                    ProgressView(value: window.percent, total: 100)
                        .tint(window.percent >= 90 ? .red : (window.percent >= 70 ? .orange : palette.accent))
                    if !window.resetsAt.isEmpty {
                        QuotaResetCountdown(resetsAt: window.resetsAt, palette: palette)
                    }
                }
                .padding(.vertical, 4)
            }
            if !isLoading && windows.isEmpty {
                Text("没有解析出可显示的额度窗口。")
                    .foregroundStyle(palette.secondaryText)
            }
            Button("刷新额度") { Task { await load() } }
        }
        .scrollContentBackground(.hidden)
        .background(SettingsPageBackground(theme: model.theme, palette: palette).ignoresSafeArea())
        .listRowBackground(settingsRowBackground(theme: model.theme, palette: palette))
        .navigationTitle("Claude 额度")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .alert("额度读取失败", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("好", role: .cancel) { errorText = nil }
        } message: { Text(errorText ?? "") }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            var rows: [QuotaWindow] = []
            collectQuota(model: try await model.settingsQuota().raw, into: &rows)
            windows = rows
                .filter { !($0.key.localizedCaseInsensitiveContains("extra") && $0.percent == 0) }
                .sorted { quotaRank($0.key) < quotaRank($1.key) }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func collectQuota(model value: JSONValue, into rows: inout [QuotaWindow]) {
        switch value {
        case .object(let object):
            if case .number(let utilization)? = object["utilization"] {
                let reset: String
                if case .string(let value)? = object["resets_at"] { reset = value }
                else if case .string(let value)? = object["resetsAt"] { reset = value }
                else { reset = "" }
                rows.append(QuotaWindow(key: "unknown", utilization: utilization, resetsAt: reset))
                return
            }
            for (key, child) in object {
                if case .object(let detail) = child,
                   case .number(let utilization)? = detail["utilization"] {
                    let reset: String
                    if case .string(let value)? = detail["resets_at"] { reset = value }
                    else if case .string(let value)? = detail["resetsAt"] { reset = value }
                    else { reset = "" }
                    rows.append(QuotaWindow(key: key, utilization: utilization, resetsAt: reset))
                } else {
                    collectQuota(model: child, into: &rows)
                }
            }
        case .array(let values):
            values.forEach { collectQuota(model: $0, into: &rows) }
        default:
            break
        }
    }

    private func quotaRank(_ key: String) -> Int {
        ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet", "seven_day_oauth_apps", "extra_usage"]
            .firstIndex(of: key) ?? 99
    }

}

private struct CodexQuotaWindow: Identifiable {
    let id: String
    let title: String
    let percent: Double
    let resetsAt: String
}

private struct CodexQuotaView: View {
    @ObservedObject var model: AppModel
    @State private var windows: [CodexQuotaWindow] = []
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var statusText = "等待本机 Codex bridge 上报额度"
    @State private var resetCredits = 0
    private var palette: EchoPalette { model.theme.palette }

    var body: some View {
        List {
            if isLoading && windows.isEmpty {
                ProgressView("读取 Codex 账号额度…").tint(palette.accent)
            }
            ForEach(windows) { window in
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text(window.title)
                        Spacer()
                        Text("\(Int(window.percent.rounded()))%")
                            .font(.headline.monospacedDigit())
                    }
                    ProgressView(value: window.percent, total: 100)
                        .tint(window.percent >= 90 ? .red : (window.percent >= 70 ? .orange : palette.accent))
                    if !window.resetsAt.isEmpty {
                        QuotaResetCountdown(resetsAt: window.resetsAt, palette: palette)
                    }
                }
                .padding(.vertical, 4)
            }
            if !isLoading && windows.isEmpty {
                Text(statusText).foregroundStyle(palette.secondaryText)
            } else if !statusText.isEmpty {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
            }
            if resetCredits > 0 {
                LabeledContent("可用额度重置", value: "\(resetCredits) 次")
            }
            Button("刷新额度") { Task { await load() } }
        }
        .scrollContentBackground(.hidden)
        .background(SettingsPageBackground(theme: model.theme, palette: palette).ignoresSafeArea())
        .listRowBackground(settingsRowBackground(theme: model.theme, palette: palette))
        .navigationTitle("Codex 额度")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .alert("额度读取失败", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("好", role: .cancel) { errorText = nil }
        } message: { Text(errorText ?? "") }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await model.settingsCodexQuota()
            guard response.ok, let raw = response.raw else {
                windows = []
                resetCredits = 0
                statusText = "等待本机 Codex bridge 上报额度"
                return
            }
            windows = parseWindows(raw)
            resetCredits = parseResetCredits(raw)
            let age = max(0, Int((response.ageSeconds ?? 0).rounded()))
            let fresh = age < 90 ? "刚刚更新" : "\(max(1, age / 60)) 分钟前更新"
            statusText = response.online == false ? "bridge 可能已离线 · \(fresh)" : fresh
            if windows.isEmpty { statusText = "没有解析出可显示的 Codex 额度窗口" }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func parseWindows(_ value: JSONValue) -> [CodexQuotaWindow] {
        guard case .object(let root) = value else { return [] }
        var buckets: [(String, [String: JSONValue])] = []
        if let byID = object(root["rateLimitsByLimitId"] ?? root["rate_limits_by_limit_id"]) {
            for (key, value) in byID {
                if let bucket = object(value) { buckets.append((key, bucket)) }
            }
        }
        if buckets.isEmpty,
           let bucket = object(root["rateLimits"] ?? root["rate_limits"]) {
            buckets.append((string(bucket["limitId"] ?? bucket["limit_id"]) ?? "codex", bucket))
        }
        let names = Set(buckets.map { string($0.1["limitName"] ?? $0.1["limit_name"]) ?? $0.0 })
        var rows: [CodexQuotaWindow] = []
        for (bucketID, bucket) in buckets {
            let bucketName = string(bucket["limitName"] ?? bucket["limit_name"]) ?? bucketID
            for kind in ["primary", "secondary"] {
                guard let detail = object(bucket[kind]),
                      let used = number(detail["usedPercent"] ?? detail["used_percent"]) else { continue }
                let minutes = Int(number(detail["windowDurationMins"] ?? detail["window_duration_mins"]) ?? 0)
                let windowName = durationLabel(minutes)
                let title = names.count > 1 ? "\(bucketName) · \(windowName)" : windowName
                let resetSeconds = number(detail["resetsAt"] ?? detail["resets_at"]) ?? 0
                let reset = resetSeconds > 0
                    ? ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: resetSeconds))
                    : ""
                rows.append(CodexQuotaWindow(
                    id: "\(bucketID)-\(kind)",
                    title: title,
                    percent: min(max(used, 0), 100),
                    resetsAt: reset
                ))
            }
        }
        return rows.sorted { lhs, rhs in
            if lhs.title == rhs.title { return lhs.id < rhs.id }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    private func parseResetCredits(_ value: JSONValue) -> Int {
        guard case .object(let root) = value,
              let credits = object(root["rateLimitResetCredits"] ?? root["rate_limit_reset_credits"]) else { return 0 }
        return Int(number(credits["availableCount"] ?? credits["available_count"]) ?? 0)
    }

    private func object(_ value: JSONValue?) -> [String: JSONValue]? {
        guard case .object(let object)? = value else { return nil }
        return object
    }

    private func number(_ value: JSONValue?) -> Double? {
        guard case .number(let number)? = value else { return nil }
        return number
    }

    private func string(_ value: JSONValue?) -> String? {
        guard case .string(let string)? = value, !string.isEmpty else { return nil }
        return string
    }

    private func durationLabel(_ minutes: Int) -> String {
        guard minutes > 0 else { return "额度窗口" }
        if minutes.isMultiple(of: 1_440) { return "\(minutes / 1_440) 天窗口" }
        if minutes.isMultiple(of: 60) { return "\(minutes / 60) 小时窗口" }
        return "\(minutes) 分钟窗口"
    }
}

private struct QuotaResetCountdown: View {
    let resetsAt: String
    let palette: EchoPalette

    private var resetDate: Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: resetsAt) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: resetsAt)
    }

    var body: some View {
        if let resetDate {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(countdownText(to: resetDate, from: context.date))
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                    .monospacedDigit()
            }
        }
    }

    private func countdownText(to resetDate: Date, from now: Date) -> String {
        let seconds = max(0, Int(resetDate.timeIntervalSince(now)))
        guard seconds > 0 else { return "额度即将刷新" }
        let totalMinutes = max(1, Int(ceil(Double(seconds) / 60)))
        let days = totalMinutes / 1_440
        let hours = (totalMinutes % 1_440) / 60
        let minutes = totalMinutes % 60
        if days > 0 {
            return "距离额度刷新还有 \(days) 天 \(hours) 小时"
        }
        if hours > 0 {
            return "距离额度刷新还有 \(hours) 小时 \(minutes) 分"
        }
        return "距离额度刷新还有 \(minutes) 分钟"
    }
}

private struct APIControlView: View {
    @ObservedObject var model: AppModel
    @State private var presets: [APIPreset] = []
    @State private var stats: APIUsageStats?
    @State private var isLoading = false
    @State private var errorText: String?
    @State private var pendingPreset: APIPreset?
    @State private var showingAddPreset = false
    @State private var showingRecent = false
    @State private var effort = "high"
    @State private var effortLevels = ["low", "medium", "high", "xhigh", "max"]
    /// 服务器上那一档。load 回填和切换失败回滚都会改 effort，靠它把 onChange 里那些
    /// 不是她点出来的变化挡掉，免得白发一次请求。
    @State private var serverEffort = "high"
    @State private var effortNote = ""
    private var palette: EchoPalette { model.theme.palette }

    var body: some View {
        List {
            Section {
                Toggle("消息旁显示 API 用量", isOn: $model.showsAPIMessageUsage)
            } header: {
                Text("聊天显示")
            } footer: {
                Text("在每条 API 回复的时间后显示缓存命中率与美元花费。优先使用接口报价，估算费用标记为 ≈；没有数据时显示 —。")
            }

            Section("API 接口") {
                ForEach(presets) { preset in
                    Button { if !preset.active { pendingPreset = preset } } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(preset.name).foregroundStyle(palette.text)
                                Text(preset.url).font(.caption).foregroundStyle(palette.secondaryText).lineLimit(1)
                                Text("\(preset.model) · \(preset.keyMasked)")
                                    .font(.caption2)
                                    .foregroundStyle(palette.secondaryText)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if preset.active {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(palette.accent)
                            }
                        }
                    }
                    .swipeActions {
                        if presets.count > 1 {
                            Button("删除", role: .destructive) { Task { await deletePreset(preset) } }
                        }
                    }
                }
                Button { showingAddPreset = true } label: {
                    Label("添加 API 接口", systemImage: "plus")
                }
            }

            Section {
                Picker("思考力度", selection: $effort) {
                    ForEach(effortLevels, id: \.self) { level in
                        Text(level).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(isLoading)
                .onChange(of: effort) { value in applyEffort(value) }

                if !effortNote.isEmpty {
                    Text(effortNote)
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                }
            } header: {
                Text("思考力度")
            } footer: {
                Text("只管 API 身体。越高想得越细、越慢越贵，low 基本不思考。xhigh 是 Opus 4.7 以上才有的档。换档会让缓存重写一次，下一句贵一点。")
            }

            if let stats {
                Section("API 用量") {
                    metric("消息数", value: "\(stats.messages)")
                    metric("缓存命中率", value: "\(Int((stats.cacheHitRate * 100).rounded()))%")
                    metric("输入（全价）", value: tokenText(stats.total.input))
                    metric("输出", value: tokenText(stats.total.output))
                    metric("缓存命中", value: tokenText(stats.total.cacheRead))
                    metric("缓存写入", value: tokenText(stats.total.cacheWrite))
                    metric("累计花费", value: String(format: "$%.2f", stats.totalCostUSD))
                    metric("每条均价", value: String(format: "$%.4f", stats.average.costUSD ?? 0))
                    Text("心跳 \(stats.keepalive.beats) 次 ≈ \(String(format: "$%.3f", stats.keepalive.costUSD)) · 缓存 \(stats.cacheTTL) · \(billingNote(stats))")
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                }

                Section {
                    DisclosureGroup("最近用量明细", isExpanded: $showingRecent) {
                        ForEach(stats.recent) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Circle()
                                        .fill(cacheStateColor(entry))
                                        .frame(width: 7, height: 7)
                                    Text(entry.model ?? "未知模型").lineLimit(1)
                                    Spacer()
                                    Text(cacheHitText(entry))
                                        .font(.caption.weight(.semibold).monospacedDigit())
                                        .foregroundStyle(cacheStateColor(entry))
                                    Text(String(format: entry.billed ? "$%.4f" : "$%.4f≈", entry.costUSD))
                                        .monospacedDigit()
                                }
                                Text("读 \(tokenText(entry.cacheRead)) · 写 \(tokenText(entry.cacheWrite)) · 入 \(tokenText(entry.input)) · 出 \(tokenText(entry.output))")
                                    .font(.caption2)
                                    .foregroundStyle(palette.secondaryText)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
            }

            if isLoading { ProgressView().tint(palette.accent) }
            Button("刷新接口与用量") { Task { await load() } }
        }
        .tint(palette.accent)
        .scrollContentBackground(.hidden)
        .background(SettingsPageBackground(theme: model.theme, palette: palette).ignoresSafeArea())
        .listRowBackground(settingsRowBackground(theme: model.theme, palette: palette))
        .navigationTitle("API 接口与用量")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(isPresented: $showingAddPreset) {
            AddAPIPresetView(model: model, existing: presets) { config in
                presets = config.apiPresets
                stats = try? await model.settingsAPIUsage()
            }
        }
        .confirmationDialog("切换 API 接口？", isPresented: Binding(
            get: { pendingPreset != nil },
            set: { if !$0 { pendingPreset = nil } }
        ), titleVisibility: .visible) {
            Button("切换") {
                guard let preset = pendingPreset else { return }
                pendingPreset = nil
                Task { await activate(preset) }
            }
            Button("取消", role: .cancel) { pendingPreset = nil }
        } message: {
            Text(pendingPreset.map { "\($0.name)\n\($0.url)\n\($0.model)" } ?? "")
        }
        .alert("API 面板错误", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("好", role: .cancel) { errorText = nil }
        } message: { Text(errorText ?? "") }
    }

    private func metric(_ title: String, value: String) -> some View {
        LabeledContent(title, value: value)
    }

    /// OpenRouter 每条响应都报它实际扣的钱，用实数；不报价的中转才落到本地价目表估算。
    private func billingNote(_ stats: APIUsageStats) -> String {
        stats.billedRows > 0 ? "\(stats.billedRows)/\(stats.messages) 条按上游实报" : "全部为本地估算"
    }

    private func tokenText(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.2fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000) }
        return String(value)
    }

    private func cacheHitText(_ entry: APIUsageEntry) -> String {
        guard let rate = entry.cacheHitRate else { return "命中 —" }
        return "命中 \(Int((rate * 100).rounded()))%"
    }

    private func cacheStateColor(_ entry: APIUsageEntry) -> Color {
        if entry.cacheRead > 0 { return .green }
        if entry.cacheWrite > 0 { return .orange }
        return .red
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let config = try await model.settingsLoopConfig()
            presets = config.apiPresets
            applyConfigEffort(config)
        } catch {
            errorText = "接口列表：\(error.localizedDescription)"
        }
        do {
            stats = try await model.settingsAPIUsage()
        } catch {
            if errorText == nil { errorText = "用量统计：\(error.localizedDescription)" }
        }
    }

    private func activate(_ preset: APIPreset) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let config = try await model.activateAPIPreset(preset.index)
            presets = config.apiPresets
            applyConfigEffort(config)
        }
        catch { errorText = error.localizedDescription }
    }

    private func applyConfigEffort(_ config: LoopConfigResponse) {
        if !config.effortLevels.isEmpty { effortLevels = config.effortLevels }
        serverEffort = config.effort
        effort = config.effort
        effortNote = ""
    }

    private func applyEffort(_ value: String) {
        guard value != serverEffort else { return }   // 回填/回滚引起的变化，不是她点的
        effortNote = "切到 \(value)…"
        Task {
            do {
                let config = try await model.setLoopEffort(value)
                serverEffort = config.effort
                if config.effort != value { effort = config.effort }
                effortNote = "已切到 \(config.effort)，下一句开始生效"
            } catch {
                effort = serverEffort
                effortNote = ""
                errorText = "思考力度：\(error.localizedDescription)"
            }
        }
    }

    private func deletePreset(_ preset: APIPreset) async {
        let remaining = presets.filter { $0.id != preset.id }.map {
            APIPresetInput(name: $0.name, url: $0.url, key: "", model: $0.model)
        }
        do { presets = try await model.replaceAPIPresets(remaining).apiPresets }
        catch { errorText = error.localizedDescription }
    }
}

private struct AddAPIPresetView: View {
    @ObservedObject var model: AppModel
    let existing: [APIPreset]
    let onSaved: (LoopConfigResponse) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var key = ""
    @State private var modelID = ""
    @State private var isSaving = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("接口信息") {
                    TextField("名称，例如 OpenRouter", text: $name)
                    TextField("https://…/v1", text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API Key", text: $key)
                    TextField("模型 ID", text: $modelID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section {
                    Text("Key 只提交给你自己的 relay/api_loop；保存后原生 App 只会收到掩码。")
                        .font(.caption)
                }
            }
            .tint(model.theme.palette.accent)
            .scrollContentBackground(.hidden)
            .background(SettingsPageBackground(theme: model.theme, palette: model.theme.palette).ignoresSafeArea())
            .listRowBackground(settingsRowBackground(theme: model.theme, palette: model.theme.palette))
            .navigationTitle("添加 API 接口")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isSaving { ProgressView() }
                    else { Button("保存") { Task { await save() } }.disabled(!canSave) }
                }
            }
            .alert("保存失败", isPresented: Binding(
                get: { errorText != nil },
                set: { if !$0 { errorText = nil } }
            )) {
                Button("好", role: .cancel) { errorText = nil }
            } message: { Text(errorText ?? "") }
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && URL(string: url)?.scheme?.lowercased() == "https"
            && !key.isEmpty && !modelID.isEmpty
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let rows = existing.map {
            APIPresetInput(name: $0.name, url: $0.url, key: "", model: $0.model)
        } + [APIPresetInput(name: name, url: url, key: key, model: modelID)]
        do {
            let config = try await model.replaceAPIPresets(rows)
            await onSaved(config)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private enum ContextCommand: String, Identifiable {
    case reset
    case swap
    case resume
    var id: String { rawValue }
    var title: String {
        switch self {
        case .reset: return "Reset 新窗口"
        case .swap: return "Swap 过隧道"
        case .resume: return "Resume 接回窗口"
        }
    }
    var explanation: String {
        switch self {
        case .reset: return "会重启 Desktop，开一个不带交接的全新窗口。"
        case .swap: return "他会先写好交接便签和滚动摘要，再带着最近的原文和思考重启 Desktop，前后大约一到四分钟。"
        case .resume: return "会重启 Desktop，并接回 pending 会话。"
        }
    }
}

private struct ContextSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var status: ContextStatus?
    @State private var triggerK = 200.0
    @State private var autoSwap = false
    @State private var isBusy = false
    @State private var errorText: String?
    @State private var notice: String?
    @State private var pendingCommand: ContextCommand?
    @State private var chatMode: ChatMode = .long
    @State private var stripsShortChatTerminalPeriods = false
    @State private var keepaliveStatus: DesktopKeepaliveStatus?
    @State private var keepaliveOn = false
    @State private var isKeepaliveBusy = false
    @State private var forgeRounds = 60.0
    @State private var forgePreview: ForgePreview?

    private var palette: EchoPalette { model.theme.palette }
    private var usageK: Double { Double(status?.usageTokens ?? 0) / 1000 }
    private var progress: Double { min(max(usageK / max(triggerK, 1), 0), 1) }

    var body: some View {
        List {
            Section("当前上下文") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("\(Int(usageK.rounded()))k")
                            .font(.title3.weight(.semibold))
                        Spacer()
                        Text("阈值 \(Int(triggerK))k")
                            .font(.caption)
                            .foregroundStyle(palette.secondaryText)
                    }
                    ProgressView(value: progress).tint(palette.accent)
                }
                if let sid = status?.activeSID, !sid.isEmpty {
                    LabeledContent("Active SID", value: shortSID(sid))
                        .font(.footnote)
                }
                if let pending = status?.pending?.newSID {
                    LabeledContent("Pending SID", value: shortSID(pending))
                        .font(.footnote)
                }
                if let phase = status?.forgePhase, !phase.isEmpty {
                    Text("正在过隧道…")
                        .font(.footnote)
                        .foregroundStyle(palette.secondaryText)
                }
                Button("刷新状态") { Task { await load() } }
            }

            Section("自动管理") {
                Toggle("自动 Swap", isOn: Binding(
                    get: { autoSwap },
                    set: { value in
                        autoSwap = value
                        Task { await saveAutoSwap(value) }
                    }
                ))
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("触发阈值")
                        Spacer()
                        Text("\(Int(triggerK))k")
                            .foregroundStyle(palette.secondaryText)
                    }
                    Slider(value: $triggerK, in: 80...500, step: 20)
                        .tint(palette.accent)
                    Button("保存阈值") { Task { await saveThreshold() } }
                }
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("过隧道保留")
                        Spacer()
                        Text("\(Int(forgeRounds)) 轮")
                            .foregroundStyle(palette.secondaryText)
                    }
                    Slider(value: $forgeRounds, in: 10...500, step: 10, onEditingChanged: { editing in
                        if !editing { Task { await saveForgeRounds() } }
                    })
                    .tint(palette.accent)
                    Text(forgePreviewText)
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                }
                .task(id: Int(forgeRounds)) {
                    // task(id:) 换值就取消上一个——拖动时天然防抖
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    guard !Task.isCancelled else { return }
                    forgePreview = try? await model.settingsForgeStatus(previewRounds: Int(forgeRounds)).preview
                }
                Text("仅影响 Desktop。到达触发线后自动过隧道：他先写便签和滚动摘要，再带着最近这么多轮原文和思考重开。一轮=你发的一条消息。")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)

                Toggle("缓存保活", isOn: Binding(
                    get: { keepaliveOn },
                    set: { enabled in
                        keepaliveOn = enabled
                        Task { await saveKeepalive(enabled) }
                    }
                ))
                .disabled(isKeepaliveBusy)
                Text(keepaliveStatusText)
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
            }

            Section("聊天节奏") {
                Picker("回复方式", selection: Binding(
                    get: { chatMode },
                    set: { mode in
                        chatMode = mode
                        Task { await saveChatMode(mode) }
                    }
                )) {
                    ForEach(ChatMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text(chatMode == .short
                     ? "回复会按全部非空段落拆成多条气泡连发。"
                     : "一整段回复显示为一条气泡。")
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                Toggle("去掉短聊段尾句号", isOn: Binding(
                    get: { stripsShortChatTerminalPeriods },
                    set: { enabled in
                        stripsShortChatTerminalPeriods = enabled
                        Task { await saveTerminalPeriodStyle(enabled) }
                    }
                ))
                .disabled(isBusy)
                Text(terminalPeriodStyleHelp)
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
            }

            Section("会话操作") {
                Button("Swap · 过隧道") { pendingCommand = .swap }
                Button("Reset · 全新窗口", role: .destructive) { pendingCommand = .reset }
                if status?.pending?.newSID != nil {
                    Button("Resume · 接回 Pending") { pendingCommand = .resume }
                }
                if isBusy { ProgressView().tint(palette.accent) }
                if let notice {
                    Text(notice).font(.caption).foregroundStyle(palette.secondaryText)
                }
            }
        }
        .tint(palette.accent)
        .scrollContentBackground(.hidden)
        .background(SettingsPageBackground(theme: model.theme, palette: palette).ignoresSafeArea())
        .listRowBackground(settingsRowBackground(theme: model.theme, palette: palette))
        .navigationTitle("会话与上下文")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .confirmationDialog(
            pendingCommand?.title ?? "会话操作",
            isPresented: Binding(
                get: { pendingCommand != nil },
                set: { if !$0 { pendingCommand = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("确认执行", role: .destructive) {
                guard let command = pendingCommand else { return }
                pendingCommand = nil
                Task { await run(command) }
            }
            Button("取消", role: .cancel) { pendingCommand = nil }
        } message: {
            Text(pendingCommand?.explanation ?? "")
        }
        .alert("上下文操作失败", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("好", role: .cancel) { errorText = nil }
        } message: { Text(errorText ?? "") }
    }

    private func shortSID(_ sid: String) -> String {
        sid.count > 12 ? String(sid.prefix(9)) + "…" : sid
    }

    private func load() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let next = try await model.settingsContextStatus()
            status = next
            triggerK = Double(next.triggerK)
            autoSwap = next.auto
            if let rounds = next.forgeRounds { forgeRounds = Double(rounds) }
            if let settings = try? await model.settingsChatMode() {
                chatMode = settings.mode
                stripsShortChatTerminalPeriods = settings.stripTerminalPeriods
            }
            if let nextKeepalive = try? await model.settingsDesktopKeepalive() {
                applyKeepalive(nextKeepalive)
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private var forgePreviewText: String {
        guard let p = forgePreview else { return "—" }
        var text = "≈\(Int((Double(p.estTokens) / 1000).rounded()))k · 共 \(p.roundsTotal) 轮"
        if let first = p.firstMsg, !first.isEmpty {
            text += " · 从「\(first.prefix(18))」开始"
        }
        return text
    }

    private func saveForgeRounds() async {
        do {
            let next = try await model.updateContextThreshold(forgeRounds: Int(forgeRounds))
            if let rounds = next.forgeRounds { forgeRounds = Double(rounds) }
            notice = "过隧道保留 \(Int(forgeRounds)) 轮。"
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func saveThreshold() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let next = try await model.updateContextThreshold(triggerK: Int(triggerK))
            triggerK = Double(next.triggerK)
            autoSwap = next.auto
            notice = "上下文阈值已保存。"
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func saveAutoSwap(_ value: Bool) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let next = try await model.updateContextThreshold(auto: value)
            triggerK = Double(next.triggerK)
            autoSwap = next.auto
            notice = next.auto ? "自动 Swap 已开启。" : "自动 Swap 已关闭。"
        } catch {
            autoSwap.toggle()
            errorText = error.localizedDescription
        }
    }

    private func saveKeepalive(_ enabled: Bool) async {
        isKeepaliveBusy = true
        defer { isKeepaliveBusy = false }
        do {
            let next = try await model.updateDesktopKeepalive(enabled)
            applyKeepalive(next)
            notice = next.config.keepalive
                ? "缓存保活已开启，一小时内不让缓存凉。"
                : "缓存保活已关闭。"
        } catch {
            keepaliveOn = !enabled
            errorText = error.localizedDescription
        }
    }

    private func applyKeepalive(_ next: DesktopKeepaliveStatus) {
        keepaliveStatus = next
        keepaliveOn = next.config.keepalive
    }

    private var keepaliveStatusText: String {
        guard let keepaliveStatus else {
            return "Desktop 会话闲置 50–58 分钟会随机续一次；你超过 10 小时没说话便停止保活。"
        }
        if keepaliveStatus.brain != "desktop" {
            return "当前为 API 身体，自带心跳；这个开关只影响 Desktop。"
        }
        var details: [String] = []
        if keepaliveStatus.today > 0 {
            details.append("今日 \(keepaliveStatus.today) 次")
        }
        if keepaliveStatus.config.keepalive, let time = keepaliveClock(keepaliveStatus.nextAt) {
            details.append("下次约 \(time)")
        } else if let time = keepaliveClock(keepaliveStatus.lastFireAt) {
            details.append("上次 \(time)")
        }
        if !details.isEmpty { return details.joined(separator: " · ") }
        return keepaliveStatus.config.keepalive
            ? "等上一轮说完后开始计时；闲置 50–58 分钟随机续一次。"
            : "已关闭；Desktop 缓存会按服务端原本的时间自然过期。"
    }

    private func keepaliveClock(_ raw: String?) -> String? {
        guard let raw, let separator = raw.firstIndex(of: "T") else { return nil }
        let clock = raw[raw.index(after: separator)...].prefix(5)
        return clock.count == 5 ? String(clock) : nil
    }

    private func saveChatMode(_ mode: ChatMode) async {
        isBusy = true
        defer { isBusy = false }
        do {
            chatMode = try await model.updateChatMode(mode)
            notice = chatMode == .short ? "短聊已开启。" : "长聊已开启。"
        } catch {
            chatMode = mode == .short ? .long : .short
            errorText = error.localizedDescription
        }
    }

    private var terminalPeriodStyleHelp: String {
        if chatMode != .short {
            return stripsShortChatTerminalPeriods
                ? "设置已保留，切换到短聊后才生效。"
                : "只在短聊时生效；问号、感叹号和省略号都会保留。"
        }
        return stripsShortChatTerminalPeriods
            ? "每段末尾的句号会省略，其他语气标点保持不变。"
            : "开启后只省略每段末尾的句号。"
    }

    private func saveTerminalPeriodStyle(_ enabled: Bool) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let settings = try await model.updateShortChatStripTerminalPeriods(enabled, mode: chatMode)
            chatMode = settings.mode
            stripsShortChatTerminalPeriods = settings.stripTerminalPeriods
            notice = settings.stripTerminalPeriods ? "短聊句号样式已开启。" : "短聊句号样式已关闭。"
        } catch {
            stripsShortChatTerminalPeriods.toggle()
            errorText = error.localizedDescription
        }
    }

    private func run(_ command: ContextCommand) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let sid = command == .resume ? status?.pending?.newSID : nil
            let rounds = command == .swap ? Int(forgeRounds) : nil
            _ = try await model.performContextAction(command.rawValue, sid: sid, rounds: rounds)
            notice = command == .swap ? "过隧道中：他在写交接便签…" : "\(command.title) 已触发。"
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let next = try await model.settingsContextStatus()
            status = next
            triggerK = Double(next.triggerK)
            autoSwap = next.auto
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private struct SavedAppearanceRow: View {
    @ObservedObject var model: AppModel
    let saved: SavedAppearance
    let palette: EchoPalette
    @State private var thumbnail: UIImage?

    var body: some View {
        let v = saved.values
        let theme = EchoTheme(rawValue: v.theme) ?? .mist
        HStack(spacing: 12) {
            ZStack {
                theme.palette.background
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                }
                VStack(spacing: 3) {
                    swatch(v.aiBubbleColorHex, fallback: theme.palette.aiBubble)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    swatch(v.humanBubbleColorHex, fallback: theme.palette.humanBubble)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(5)
            }
            .frame(width: 40, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(palette.hairline))

            VStack(alignment: .leading, spacing: 2) {
                Text(saved.name).foregroundStyle(palette.text)
                Text(theme.title + (saved.hasBackground ? " · 带壁纸" : ""))
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
            }
            Spacer()
        }
        .task(id: saved) {
            thumbnail = await model.savedAppearanceBackground(saved)?
                .byPreparingThumbnail(ofSize: CGSize(width: 120, height: 144))
        }
    }

    private func swatch(_ hex: String, fallback: Color) -> some View {
        Capsule()
            .fill(Color(hexString: hex) ?? fallback)
            .frame(width: 18, height: 9)
            .overlay(Capsule().stroke(Color.black.opacity(0.08), lineWidth: 0.5))
    }
}
