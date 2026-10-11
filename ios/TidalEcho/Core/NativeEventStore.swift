import Combine
import EventKit
import Foundation

struct NativeScheduleDraft {
    let title: String
    let date: Date
    let time: Date
    let isAllDay: Bool
    let isAnniversary: Bool
    let shouldRemind: Bool
}

@MainActor
final class NativeEventStore: ObservableObject {
    static let shared = NativeEventStore()

    @Published private(set) var calendarStatusText = "未请求"
    @Published private(set) var reminderStatusText = "未请求"

    private let store = EKEventStore()

    private init() {
        refreshAuthorizationStatus()
    }

    var canWriteEvents: Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .authorized, .writeOnly, .fullAccess:
            return true
        default:
            return false
        }
    }

    var canWriteReminders: Bool {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .authorized, .fullAccess:
            return true
        default:
            return false
        }
    }

    func refreshAuthorizationStatus() {
        calendarStatusText = Self.statusText(
            EKEventStore.authorizationStatus(for: .event),
            writeOnlyIsEnough: true
        )
        reminderStatusText = Self.statusText(
            EKEventStore.authorizationStatus(for: .reminder),
            writeOnlyIsEnough: false
        )
    }

    func requestCalendarAccess() async -> Bool {
        if canWriteEvents { return true }
        do {
            let granted = try await store.requestWriteOnlyAccessToEvents()
            refreshAuthorizationStatus()
            return granted
        } catch {
            refreshAuthorizationStatus()
            return false
        }
    }

    func requestReminderAccess() async -> Bool {
        if canWriteReminders { return true }
        do {
            let granted = try await store.requestFullAccessToReminders()
            refreshAuthorizationStatus()
            return granted
        } catch {
            refreshAuthorizationStatus()
            return false
        }
    }

    func addCalendarEvent(_ draft: NativeScheduleDraft) throws {
        guard canWriteEvents else { throw NativeEventStoreError.calendarPermission }
        guard let calendar = store.defaultCalendarForNewEvents else {
            throw NativeEventStoreError.noDefaultCalendar
        }

        let event = EKEvent(eventStore: store)
        event.title = draft.title
        event.calendar = calendar
        event.isAllDay = draft.isAllDay
        let start = startDate(for: draft)
        event.startDate = start
        event.endDate = draft.isAllDay
            ? Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
            : start.addingTimeInterval(3_600)
        event.notes = "由 Tidal Echo 创建"

        if draft.isAnniversary {
            event.recurrenceRules = [EKRecurrenceRule(
                recurrenceWith: .yearly,
                interval: 1,
                end: nil
            )]
        }
        if draft.shouldRemind {
            event.addAlarm(EKAlarm(relativeOffset: draft.isAllDay ? -32_400 : -900))
        }
        try store.save(event, span: .thisEvent, commit: true)
    }

    func addReminder(_ draft: NativeScheduleDraft) throws {
        guard canWriteReminders else { throw NativeEventStoreError.reminderPermission }
        guard let calendar = store.defaultCalendarForNewReminders() else {
            throw NativeEventStoreError.noDefaultReminderList
        }

        let reminder = EKReminder(eventStore: store)
        reminder.title = draft.title
        reminder.calendar = calendar
        reminder.notes = "由 Tidal Echo 创建"
        let dueDate = startDate(for: draft)
        let components: Set<Calendar.Component> = draft.isAllDay
            ? [.year, .month, .day]
            : [.year, .month, .day, .hour, .minute]
        var due = Calendar.current.dateComponents(components, from: dueDate)
        due.timeZone = Calendar.current.timeZone
        reminder.dueDateComponents = due
        if !draft.isAllDay {
            reminder.addAlarm(EKAlarm(absoluteDate: dueDate))
        }
        if draft.isAnniversary {
            reminder.addRecurrenceRule(EKRecurrenceRule(
                recurrenceWith: .yearly,
                interval: 1,
                end: nil
            ))
        }
        try store.save(reminder, commit: true)
    }

    private func startDate(for draft: NativeScheduleDraft) -> Date {
        let calendar = Calendar.current
        if draft.isAllDay { return calendar.startOfDay(for: draft.date) }
        let clock = calendar.dateComponents([.hour, .minute], from: draft.time)
        return calendar.date(
            bySettingHour: clock.hour ?? 9,
            minute: clock.minute ?? 0,
            second: 0,
            of: draft.date
        ) ?? draft.date
    }

    private static func statusText(_ status: EKAuthorizationStatus, writeOnlyIsEnough: Bool) -> String {
        switch status {
        case .notDetermined:
            return "未请求"
        case .restricted:
            return "受系统限制"
        case .denied:
            return "系统已拒绝"
        case .authorized, .fullAccess:
            return "已允许"
        case .writeOnly:
            return writeOnlyIsEnough ? "已允许添加" : "仅允许添加"
        @unknown default:
            return "未知"
        }
    }
}

enum NativeEventStoreError: LocalizedError {
    case calendarPermission
    case reminderPermission
    case noDefaultCalendar
    case noDefaultReminderList

    var errorDescription: String? {
        switch self {
        case .calendarPermission:
            return "没有系统日历写入权限。"
        case .reminderPermission:
            return "没有提醒事项权限。"
        case .noDefaultCalendar:
            return "系统没有可写入的默认日历。"
        case .noDefaultReminderList:
            return "系统没有可写入的默认提醒事项列表。"
        }
    }
}
