import Combine
import Foundation
import LocalAuthentication

@MainActor
final class AppLockController: ObservableObject {
    static let shared = AppLockController()

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isUnlocked: Bool
    @Published private(set) var isAuthenticating = false
    @Published private(set) var biometryName = "Face ID"
    @Published var errorMessage: String?

    private static let preferenceKey = "tidalEcho.faceIDLockEnabled"

    private init() {
        let enabled = UserDefaults.standard.bool(forKey: Self.preferenceKey)
        isEnabled = enabled
        isUnlocked = !enabled
        refreshBiometryName()
    }

    var isBiometryAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    var statusText: String {
        if isEnabled { return "已开启" }
        if isBiometryAvailable { return "未开启" }
        return "此设备尚未设置生物识别"
    }

    func setEnabled(_ enabled: Bool) async -> Bool {
        guard enabled != isEnabled else { return true }

        let policy: LAPolicy = enabled
            ? .deviceOwnerAuthenticationWithBiometrics
            : .deviceOwnerAuthentication
        let reason = enabled
            ? "验证身份后开启 Tidal Echo App 锁"
            : "验证身份后关闭 Tidal Echo App 锁"

        guard await authenticate(policy: policy, reason: reason) else { return false }
        isEnabled = enabled
        isUnlocked = true
        UserDefaults.standard.set(enabled, forKey: Self.preferenceKey)
        return true
    }

    func unlockIfNeeded() async {
        guard isEnabled, !isUnlocked, !isAuthenticating else { return }
        if await authenticate(
            policy: .deviceOwnerAuthentication,
            reason: "解锁 Tidal Echo"
        ) {
            isUnlocked = true
        }
    }

    func lockForBackground() {
        guard isEnabled else { return }
        isUnlocked = false
    }

    func refreshBiometryName() {
        let context = LAContext()
        var error: NSError?
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        switch context.biometryType {
        case .faceID:
            biometryName = "Face ID"
        case .touchID:
            biometryName = "Touch ID"
        case .opticID:
            biometryName = "Optic ID"
        case .none:
            biometryName = "生物识别"
        @unknown default:
            biometryName = "生物识别"
        }
    }

    private func authenticate(policy: LAPolicy, reason: String) async -> Bool {
        guard !isAuthenticating else { return false }
        let context = LAContext()
        context.localizedCancelTitle = "取消"
        var availabilityError: NSError?
        guard context.canEvaluatePolicy(policy, error: &availabilityError) else {
            errorMessage = authenticationMessage(for: availabilityError)
            return false
        }

        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            let success = try await context.evaluatePolicy(policy, localizedReason: reason)
            if !success { errorMessage = "没有完成身份验证。" }
            return success
        } catch {
            let nsError = error as NSError
            if nsError.code != LAError.userCancel.rawValue,
               nsError.code != LAError.systemCancel.rawValue,
               nsError.code != LAError.appCancel.rawValue {
                errorMessage = authenticationMessage(for: nsError)
            }
            return false
        }
    }

    private func authenticationMessage(for error: NSError?) -> String {
        guard let error else { return "当前无法进行身份验证。" }
        guard let code = LAError.Code(rawValue: error.code) else {
            return error.localizedDescription
        }
        switch code {
        case .biometryNotEnrolled:
            return "请先在系统设置中录入 Face ID 或 Touch ID。"
        case .biometryNotAvailable:
            return "此设备当前无法使用生物识别。"
        case .biometryLockout:
            return "生物识别暂时锁定，请使用设备密码解锁后再试。"
        case .passcodeNotSet:
            return "请先为设备设置锁屏密码。"
        default:
            return error.localizedDescription
        }
    }
}
