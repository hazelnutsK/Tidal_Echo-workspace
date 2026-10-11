@preconcurrency import AVFoundation
@preconcurrency import CallKit
import Foundation
import UIKit
@preconcurrency import UserNotifications

struct IncomingCallInvite: Identifiable, Equatable {
    let id: Int
    let uuid: UUID
    let text: String
}

@MainActor
final class NativeCallCoordinator: NSObject, ObservableObject, CXProviderDelegate {
    static let shared = NativeCallCoordinator()

    @Published private(set) var acceptedInvite: IncomingCallInvite?
    @Published private(set) var ringingInvite: IncomingCallInvite?
    @Published private(set) var lastCallKitError: String?
    @Published private(set) var shouldPlayInAppRingtone = false

    var onDeclineIncomingCall: ((Int) async -> Void)?

    private let provider: CXProvider
    private let controller = CXCallController()
    private var invites: [UUID: IncomingCallInvite] = [:]
    private var activeUUID: UUID?
    private var callKitManagedUUIDs: Set<UUID> = []
    private var isCallKitAudioSessionActive = false
    private var isWaitingForAudioHandoff = false
    private var audioHandoffWaiters: [CheckedContinuation<Void, Never>] = []
    private var audioHandoffTimeoutTask: Task<Void, Never>?
    private var reportedDeclineMessageIDs: Set<Int> = []

    override init() {
        let configuration = CXProviderConfiguration(localizedName: "Tidal Echo")
        configuration.supportsVideo = false
        configuration.maximumCallsPerCallGroup = 1
        configuration.maximumCallGroups = 1
        configuration.includesCallsInRecents = false
        configuration.supportedHandleTypes = [.generic]
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    func reportIncoming(messageID: Int, text: String) {
        guard ringingInvite == nil, acceptedInvite == nil, activeUUID == nil else { return }
        let invite = IncomingCallInvite(id: messageID, uuid: UUID(), text: text)
        invites[invite.uuid] = invite
        callKitManagedUUIDs.insert(invite.uuid)
        ringingInvite = invite
        activeUUID = invite.uuid
        shouldPlayInAppRingtone = false

        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: "Altair")
        update.localizedCallerName = "Altair"
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        provider.reportNewIncomingCall(with: invite.uuid, update: update) { error in
            Task { @MainActor in
                if let error {
                    self.callKitManagedUUIDs.remove(invite.uuid)
                    self.lastCallKitError = error.localizedDescription
                    let isForeground = UIApplication.shared.applicationState == .active
                    self.shouldPlayInAppRingtone = isForeground
                    if !isForeground {
                        NativeNotificationCenter.shared.scheduleIncomingCall(invite)
                    }
                } else {
                    self.lastCallKitError = nil
                    self.shouldPlayInAppRingtone = false
                }
            }
        }
    }

    func acceptRingingCall() {
        guard let invite = ringingInvite else { return }
        ringingInvite = nil
        acceptedInvite = invite
        activeUUID = invite.uuid
        shouldPlayInAppRingtone = false
        let transaction = CXTransaction(action: CXAnswerCallAction(call: invite.uuid))
        controller.request(transaction) { _ in }
    }

    func declineRingingCall() {
        guard let invite = ringingInvite else { return }
        reportDeclineIfNeeded(messageID: invite.id)
        ringingInvite = nil
        acceptedInvite = nil
        shouldPlayInAppRingtone = false
        endSystemCall(uuid: invite.uuid)
        activeUUID = nil
    }

    func acceptFromNotification(messageID: Int, text: String) {
        let invite = ringingInvite?.id == messageID
            ? ringingInvite!
            : IncomingCallInvite(id: messageID, uuid: UUID(), text: text)
        invites[invite.uuid] = invite
        ringingInvite = nil
        acceptedInvite = invite
        activeUUID = invite.uuid
        shouldPlayInAppRingtone = false
    }

    func declineFromNotification(messageID: Int) {
        reportDeclineIfNeeded(messageID: messageID)
        if ringingInvite?.id == messageID { ringingInvite = nil }
        if acceptedInvite?.id == messageID { acceptedInvite = nil }
        shouldPlayInAppRingtone = false
        if let activeUUID { endSystemCall(uuid: activeUUID) }
        activeUUID = nil
    }

    func expireIncoming(messageID: Int) {
        guard let invite = ringingInvite, invite.id == messageID else { return }
        provider.reportCall(with: invite.uuid, endedAt: Date(), reason: .unanswered)
        callKitManagedUUIDs.remove(invite.uuid)
        invites.removeValue(forKey: invite.uuid)
        ringingInvite = nil
        activeUUID = nil
        shouldPlayInAppRingtone = false
    }

    func consumeAcceptedInvite() {
        acceptedInvite = nil
    }

    func transitionToInAppCall() async {
        let callKitUUID = activeUUID.flatMap { uuid in
            callKitManagedUUIDs.contains(uuid) ? uuid : nil
        }
        if let callKitUUID {
            beginAudioHandoff()
            provider.reportCall(with: callKitUUID, endedAt: Date(), reason: .answeredElsewhere)
            callKitManagedUUIDs.remove(callKitUUID)
            invites.removeValue(forKey: callKitUUID)
        }
        activeUUID = nil
        ringingInvite = nil
        acceptedInvite = nil
        shouldPlayInAppRingtone = false
        if callKitUUID != nil {
            await waitForAudioHandoff()
        }
    }

    func finishCurrentCall() {
        guard let activeUUID else { return }
        endSystemCall(uuid: activeUUID)
        self.activeUUID = nil
        ringingInvite = nil
        acceptedInvite = nil
        shouldPlayInAppRingtone = false
    }

    private func endSystemCall(uuid: UUID) {
        let transaction = CXTransaction(action: CXEndCallAction(call: uuid))
        controller.request(transaction) { _ in }
    }

    private func reportDeclineIfNeeded(messageID: Int) {
        guard reportedDeclineMessageIDs.insert(messageID).inserted else { return }
        Task { [weak self] in
            await self?.onDeclineIncomingCall?(messageID)
        }
    }

    private func beginAudioHandoff() {
        audioHandoffTimeoutTask?.cancel()
        isWaitingForAudioHandoff = true
        audioHandoffTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            if self?.isCallKitAudioSessionActive == true {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
            }
            self?.completeAudioHandoff()
        }
    }

    private func waitForAudioHandoff() async {
        guard isWaitingForAudioHandoff else { return }
        await withCheckedContinuation { continuation in
            if isWaitingForAudioHandoff {
                audioHandoffWaiters.append(continuation)
            } else {
                continuation.resume()
            }
        }
    }

    private func completeAudioHandoff() {
        guard isWaitingForAudioHandoff else { return }
        isWaitingForAudioHandoff = false
        audioHandoffTimeoutTask?.cancel()
        audioHandoffTimeoutTask = nil
        let waiters = audioHandoffWaiters
        audioHandoffWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor [weak self] in
            self?.callKitManagedUUIDs.removeAll()
            self?.isCallKitAudioSessionActive = false
            self?.completeAudioHandoff()
            self?.activeUUID = nil
            self?.ringingInvite = nil
            self?.acceptedInvite = nil
            self?.shouldPlayInAppRingtone = false
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor [weak self] in
            guard let self else { action.fail(); return }
            if let invite = self.invites[action.callUUID] {
                self.ringingInvite = nil
                self.acceptedInvite = invite
                self.activeUUID = action.callUUID
                self.shouldPlayInAppRingtone = false
                action.fulfill()
            } else {
                action.fail()
            }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor [weak self] in
            guard let self else { action.fail(); return }
            if let invite = self.invites[action.callUUID],
               self.acceptedInvite?.uuid != action.callUUID {
                self.reportDeclineIfNeeded(messageID: invite.id)
            }
            self.invites.removeValue(forKey: action.callUUID)
            self.callKitManagedUUIDs.remove(action.callUUID)
            if self.activeUUID == action.callUUID { self.activeUUID = nil }
            self.ringingInvite = nil
            self.acceptedInvite = nil
            self.shouldPlayInAppRingtone = false
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        Task { @MainActor [weak self] in
            self?.isCallKitAudioSessionActive = true
        }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        Task { @MainActor [weak self] in
            self?.isCallKitAudioSessionActive = false
            self?.completeAudioHandoff()
        }
    }
}

@MainActor
final class NativeNotificationCenter: ObservableObject {
    static let shared = NativeNotificationCenter()

    static let messageCategory = "TIDAL_MESSAGE"
    static let callCategory = "TIDAL_CALL"
    static let answerAction = "TIDAL_ANSWER"
    static let declineAction = "TIDAL_DECLINE"

    @Published private(set) var authorizationText = "未开启"
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "tidalEcho.nativeNotifications") }
    }

    var fetchHandler: (() async -> Bool)?

    private init() {
        enabled = UserDefaults.standard.bool(forKey: "tidalEcho.nativeNotifications")
        Self.registerCategories()
        Task { await refreshAuthorizationStatus() }
    }

    func requestAuthorization() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
            enabled = granted
            await refreshAuthorizationStatus()
            return granted
        } catch {
            enabled = false
            authorizationText = "请求失败"
            return false
        }
    }

    func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            authorizationText = enabled ? "已开启" : "已暂停"
        case .denied:
            authorizationText = "系统已拒绝"
            enabled = false
        case .notDetermined:
            authorizationText = "未开启"
        @unknown default:
            authorizationText = "未知"
        }
    }

    func scheduleMessage(_ message: ChatMessage) {
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Altair"
        let clean = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        content.body = clean.isEmpty ? "给你发来一条消息" : String(clean.prefix(140))
        content.sound = .default
        content.categoryIdentifier = Self.messageCategory
        content.userInfo = ["type": "message", "message_id": message.id]
        let request = UNNotificationRequest(identifier: "tidal-message-\(message.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// 「他想看一眼你的屏幕」——共享申请跟普通消息长得不一样，
    /// 锁屏上一眼就能认出来是要她按一下的事。
    func scheduleScreenPeek(_ message: ChatMessage) {
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Altair想看一眼你的屏幕"
        let note = (message.meta.peek?.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = note.isEmpty ? fallback : note
        content.body = body.isEmpty ? "打开看看要不要给他看" : String(body.prefix(140))
        content.sound = .default
        content.categoryIdentifier = Self.messageCategory
        content.userInfo = ["type": "peek", "message_id": message.id]
        let request = UNNotificationRequest(
            identifier: "tidal-peek-\(message.id)", content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func scheduleIncomingCall(_ invite: IncomingCallInvite) {
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Altair来电"
        content.body = invite.text
        content.sound = .defaultRingtone
        content.categoryIdentifier = Self.callCategory
        content.userInfo = ["type": "call", "message_id": invite.id, "text": invite.text]
        let request = UNNotificationRequest(identifier: "tidal-call-\(invite.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func scheduleTest() {
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Altair"
        content.body = "原生通知已经准备好了。"
        content.sound = .default
        content.categoryIdentifier = Self.messageCategory
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "tidal-test", content: content, trigger: trigger)
        )
    }

    func handle(response: UNNotificationResponse) {
        let info = response.notification.request.content.userInfo
        guard (info["type"] as? String) == "call" else { return }
        let messageID = info["message_id"] as? Int ?? 0
        let text = info["text"] as? String ?? "Altair想和你语音通话。"
        if response.actionIdentifier == Self.declineAction {
            NativeCallCoordinator.shared.declineFromNotification(messageID: messageID)
        } else {
            NativeCallCoordinator.shared.acceptFromNotification(messageID: messageID, text: text)
        }
    }

    static func registerCategories() {
        let answer = UNNotificationAction(identifier: answerAction, title: "接听", options: [.foreground])
        let decline = UNNotificationAction(identifier: declineAction, title: "拒绝", options: [.destructive])
        let call = UNNotificationCategory(
            identifier: callCategory,
            actions: [answer, decline],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        let message = UNNotificationCategory(identifier: messageCategory, actions: [], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([call, message])
    }
}

final class NativeAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        NativeNotificationCenter.registerCategories()
        application.setMinimumBackgroundFetchInterval(UIApplication.backgroundFetchIntervalMinimum)
        return true
    }

    func application(
        _ application: UIApplication,
        performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        Task { @MainActor in
            guard let handler = NativeNotificationCenter.shared.fetchHandler else {
                completionHandler(.noData)
                return
            }
            completionHandler(await handler() ? .newData : .noData)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            NativeNotificationCenter.shared.handle(response: response)
            completionHandler()
        }
    }
}
