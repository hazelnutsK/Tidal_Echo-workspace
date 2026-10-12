import SwiftUI
import UIKit

// MARK: - 他的记忆（ombre Dashboard 只读代理：relay /app/ombre/*）
//
// 密码在 relay.env，这里只带 RELAY_SECRET。整页自带模型和请求，不动 APIClient：
// 走 model.authenticatedRequest(path:)，它已经会挂 Bearer。
// 2026-09-24 改版：钉住的横排在上，其余按月份排，右边时间轴；详情改成推进页，带「当时的心情」坐标。

struct OmbreMemory: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let type: String
    let content: String
    let preview: String
    let domains: [String]
    let tags: [String]
    let importance: Int
    let valence: Double?
    let arousal: Double?
    let pinned: Bool
    let resolved: Bool
    let activationCount: Int
    let whyRemembered: String
    let created: String
    let lastActive: String
    /// 解析一次存着：列表排序、分月、日期数字都用它，滚动时不再反复建 DateFormatter。
    let createdAt: Date?
    let lastActiveAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, type, content, preview, domains, tags, importance, valence, arousal, pinned, resolved, created
        case activationCount = "activation_count"
        case whyRemembered = "why_remembered"
        case lastActive = "last_active"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        type = (try? c.decode(String.self, forKey: .type)) ?? "dynamic"
        content = (try? c.decode(String.self, forKey: .content)) ?? ""
        preview = (try? c.decode(String.self, forKey: .preview)) ?? ""
        domains = (try? c.decode([String].self, forKey: .domains)) ?? []
        tags = (try? c.decode([String].self, forKey: .tags)) ?? []
        importance = (try? c.decode(Int.self, forKey: .importance)) ?? 5
        valence = try? c.decode(Double.self, forKey: .valence)
        arousal = try? c.decode(Double.self, forKey: .arousal)
        pinned = (try? c.decode(Bool.self, forKey: .pinned)) ?? false
        resolved = (try? c.decode(Bool.self, forKey: .resolved)) ?? false
        activationCount = (try? c.decode(Int.self, forKey: .activationCount)) ?? 0
        whyRemembered = (try? c.decode(String.self, forKey: .whyRemembered)) ?? ""
        created = (try? c.decode(String.self, forKey: .created)) ?? ""
        lastActive = (try? c.decode(String.self, forKey: .lastActive)) ?? ""
        createdAt = ombreDate(created)
        lastActiveAt = ombreDate(lastActive)
    }

    var isFeel: Bool { type.lowercased() == "feel" }

    /// 感受类的 domains 里常只有一个 "feel"，不当分类显示。
    var shownDomains: [String] { domains.filter { $0.lowercased() != "feel" } }

    /// 感受类的 name 是时间戳或 id，不当标题用。
    var displayTitle: String {
        let trimmed = cleanedName
        if isFeel || trimmed.isEmpty || trimmed == id {
            return "感受 · " + ombreShortDate(createdAt)
        }
        return trimmed
    }

    /// ombre 自动起的名字前面常挂着「2026-07-29 19-13-17 」，去掉。
    var cleanedName: String {
        let pattern = #"^\d{4}-\d{2}-\d{2} \d{2}-\d{2}-\d{2}\s*"#
        let stripped = name.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var plainPreview: String {
        let source = preview.isEmpty ? content : preview
        return source
            .replacingOccurrences(of: #"【[^】]*】"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct OmbreListResponse: Decodable {
    let items: [OmbreMemory]
}

private struct OmbreStatus: Decodable {
    let total: Int
    let permanent: Int
    let dynamic: Int
    let archived: Int
}

private struct OmbreErrorBody: Decodable {
    let detail: String
}

private enum OmbreFilter: String, CaseIterable, Identifiable {
    case all, pinned, permanent, dynamic, feel, archived

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .pinned: return "钉住的"
        case .permanent: return "永久"
        case .dynamic: return "动态"
        case .feel: return "感受"
        case .archived: return "沉底了"
        }
    }

    var query: [URLQueryItem] {
        switch self {
        case .all: return []
        case .pinned: return [URLQueryItem(name: "state", value: "pinned")]
        default: return [URLQueryItem(name: "type", value: rawValue)]
        }
    }
}

private func ombreTypeLabel(_ type: String) -> String {
    switch type.lowercased() {
    case "dynamic": return "动态"
    case "permanent": return "永久"
    case "feel": return "感受"
    case "plan": return "计划"
    case "letter": return "信"
    case "archived": return "沉底"
    default: return type
    }
}

/// 格式器只建一次。以前每解析一个日期都新建好几个，三百多条一排序就是上万个，滚动卡死。
private enum OmbreFormat {
    static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    static let iso = ISO8601DateFormatter()

    // ombre 的 created/last_active 不带时区，实际是 UTC（Zeabur 服务器时间）。
    // 对照过正文：9-09 那条写着「傍晚」，created 是 09:37 → 北京 17:37。
    static let naive: [DateFormatter] = [
        "yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"
    ].map { format in
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = format
        return parser
    }

    static func beijing(_ format: String, locale: String = "zh_Hans_CN") -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: locale)
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = format
        return formatter
    }

    static let monthDay = beijing("M月d日")
    static let yearMonthDay = beijing("yyyy年M月d日")
    static let clock = beijing("h:mm", locale: "en_US_POSIX")
    static let thisYear = SpaceMonth.beijing.component(.year, from: Date())
}

private func ombreDate(_ value: String) -> Date? {
    guard !value.isEmpty else { return nil }
    if let date = OmbreFormat.isoFractional.date(from: value) { return date }
    if let date = OmbreFormat.iso.date(from: value) { return date }
    for parser in OmbreFormat.naive {
        if let date = parser.date(from: value) { return date }
    }
    return nil
}

private func ombreShortDate(_ date: Date?) -> String {
    guard let date else { return "" }
    let sameYear = SpaceMonth.beijing.component(.year, from: date) == OmbreFormat.thisYear
    return (sameYear ? OmbreFormat.monthDay : OmbreFormat.yearMonthDay).string(from: date)
}

private func ombreLongDate(_ date: Date?) -> String {
    guard let date else { return "—" }
    let hour = SpaceMonth.beijing.component(.hour, from: date)
    let part: String
    switch hour {
    case 0..<5: part = "凌晨"
    case 5..<11: part = "早上"
    case 11..<13: part = "中午"
    case 13..<18: part = "下午"
    default: part = "晚上"
    }
    return "\(OmbreFormat.yearMonthDay.string(from: date)) \(part) \(OmbreFormat.clock.string(from: date))"
}

@MainActor
private func ombreFetch<T: Decodable>(_ model: AppModel, path: String, query: [URLQueryItem] = []) async throws -> T {
    var components = URLComponents()
    components.path = "/relay/app/ombre/" + path
    if !query.isEmpty { components.queryItems = query }
    guard let relative = components.string, let request = model.authenticatedRequest(path: relative) else {
        throw APIError.invalidURL
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
    guard (200..<300).contains(http.statusCode) else {
        if http.statusCode == 401 { throw APIError.unauthorized }
        let detail = (try? JSONDecoder().decode(OmbreErrorBody.self, from: data).detail) ?? "HTTP \(http.statusCode)"
        throw APIError.server(detail)
    }
    return try JSONDecoder().decode(T.self, from: data)
}

/// 列表排好的样子。只在数据回来时算一次，别放进 body 里现算——
/// scrollPosition 每滚过一行就会让 body 重跑，现算会把主线程拖死。
private struct MemoryLayout {
    var showsPins = false
    var pins: [OmbreMemory] = []
    var rows: [MemoryRow] = []
    var months: [SpaceMonth] = []

    init() {}

    init(items: [OmbreMemory], separatePins: Bool) {
        pins = items.filter(\.pinned)
        showsPins = separatePins && !pins.isEmpty
        let listed = showsPins ? items.filter { !$0.pinned } : items
        let sorted = listed.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        var current: SpaceMonth?
        for memory in sorted {
            let month = SpaceMonth(date: memory.createdAt ?? Date())
            var first = false
            if month != current {
                current = month
                rows.append(.header(month))
                months.append(month)
                first = true
            }
            rows.append(.memory(memory, month, first))
        }
    }
}

private enum MemoryRow: Identifiable {
    case header(SpaceMonth)
    case memory(OmbreMemory, SpaceMonth, Bool)

    var id: String {
        switch self {
        case .header(let month): return month.headerID
        case .memory(let memory, let month, _): return month.rowID(memory.id)
        }
    }
}

struct MemoryVaultView: View {
    @ObservedObject var model: AppModel
    @State private var items: [OmbreMemory] = []
    @State private var layout = MemoryLayout()
    @State private var status: OmbreStatus?
    @State private var filter: OmbreFilter = .all
    @State private var query = ""
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var topID: String?
    @State private var isScrolling = false

    init(model: AppModel) {
        self.model = model
    }

    private var style: SpaceStyle { SpaceStyle(theme: model.theme) }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var literary: EchoChatFont { SpaceStyle.literaryFont(for: model.chatFont) }

    private var showsPins: Bool { layout.showsPins }
    private var pins: [OmbreMemory] { layout.pins }
    private var rows: [MemoryRow] { layout.rows }
    private var months: [SpaceMonth] { layout.months }
    private let thisYear = SpaceMonth(date: Date()).year

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header.spaceEntrance(0)
                searchField.spaceEntrance(1)
                if trimmedQuery.isEmpty { filters.spaceEntrance(2) }

                if showsPins {
                    VStack(alignment: .leading, spacing: 10) {
                        SpaceLabel(text: "钉在心上的", style: style)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 10) {
                                ForEach(pins) { memory in
                                    NavigationLink {
                                        MemoryDetailView(model: model, memory: memory)
                                    } label: {
                                        PinnedMemoryCard(memory: memory, style: style, literary: literary)
                                    }
                                    .buttonStyle(SpacePressStyle())
                                }
                            }
                            .scrollTargetLayout()
                            .padding(.horizontal, 20)
                            .padding(.vertical, 2)
                        }
                        .scrollTargetBehavior(.viewAligned)
                        .padding(.horizontal, -20)
                    }
                    .spaceEntrance(3)
                }

                if isLoading && items.isEmpty {
                    ProgressView("正在翻他的记忆…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                } else if let errorText, items.isEmpty {
                    emptyState(icon: "moon.zzz", title: "ombre 睡着了", text: "\(errorText)\n记忆都还在，只是现在翻不开。")
                } else if rows.isEmpty && !showsPins {
                    emptyState(
                        icon: "sparkle.magnifyingglass",
                        title: trimmedQuery.isEmpty ? "这里还是空的" : "没找到",
                        text: trimmedQuery.isEmpty ? "换个分类看看。" : "他好像没记过「\(trimmedQuery)」。"
                    )
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            switch row {
                            case .header(let month):
                                SpaceMonthHeader(month: month, style: style, showsYear: month.year != thisYear)
                            case .memory(let memory, _, let first):
                                NavigationLink {
                                    MemoryDetailView(model: model, memory: memory)
                                } label: {
                                    MemoryRowView(memory: memory, style: style, literary: literary, showsRule: !first)
                                }
                                .buttonStyle(SpacePressStyle())
                            }
                        }
                    }
                    .scrollTargetLayout()
                }
            }
            .padding(.leading, 20)
            .padding(.trailing, months.count >= 2 ? 44 : 20)
            .padding(.bottom, 32)
        }
        .scrollPosition(id: $topID, anchor: .top)
        .onScrollPhaseChange { _, phase in isScrolling = phase.isScrolling }
        .overlay(alignment: .trailing) {
            if months.count >= 2 {
                SpaceTimelineRail(
                    months: months,
                    activeKey: SpaceMonth.monthKey(ofRowID: topID),
                    style: style,
                    isScrolling: isScrolling
                ) { month in
                    topID = month.headerID
                }
                .padding(.top, 260)
                .padding(.bottom, 60)
            }
        }
        .spacePage(style)
        .navigationTitle("Memory")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task(id: "\(filter.rawValue)|\(trimmedQuery)") {
            // 搜索防抖：停手 350ms 再发；切分类不用等
            if !trimmedQuery.isEmpty {
                try? await Task.sleep(nanoseconds: 350_000_000)
                if Task.isCancelled { return }
            }
            await load()
        }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 12) {
            Text(status.map { "\($0.total)" } ?? "—")
                .font(SpaceFont.display(64))
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            VStack(alignment: .leading, spacing: 4) {
                Text("件事，他记着")
                    .font(.system(size: 15, weight: .medium))
                if let status {
                    Text("钉住 \(pins.count) · 永久 \(status.permanent) · 动态 \(status.dynamic) · 沉底 \(status.archived)")
                        .font(.system(size: 12))
                        .foregroundStyle(style.sub)
                } else {
                    Text(isLoading ? "连接中…" : "离线")
                        .font(.system(size: 12))
                        .foregroundStyle(style.sub)
                }
            }
            .padding(.bottom, 4)
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(style.faint)
            TextField("搜一件事，比如「hazel」", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(style.faint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空搜索")
            }
        }
        .font(.system(size: 14.5))
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .spaceGlass(style, radius: 999)
    }

    private var filters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                ForEach(OmbreFilter.allCases) { option in
                    Button {
                        withAnimation(.snappy) { filter = option }
                    } label: {
                        Text(option.title)
                            .font(.system(size: 14, weight: filter == option ? .semibold : .regular))
                            .foregroundStyle(filter == option ? style.ink : style.sub)
                            .padding(.bottom, 7)
                            .overlay(alignment: .bottom) {
                                if filter == option {
                                    Circle().fill(style.accent).frame(width: 4, height: 4)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
        .sensoryFeedback(.selection, trigger: filter)
    }

    private func emptyState(icon: String, title: String, text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(style.sub)
            Text(title).font(.headline)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(style.sub)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .padding(.horizontal, 24)
    }

    @MainActor
    private func load() async {
        if SpaceReview.isActive {
            items = MemoryReviewSamples.items
            layout = MemoryLayout(items: items, separatePins: filter == .all && trimmedQuery.isEmpty)
            status = MemoryReviewSamples.status
            isLoading = false
            return
        }
        isLoading = true
        defer { isLoading = false }
        let search = trimmedQuery
        let separatePins = filter == .all && search.isEmpty
        do {
            let response: OmbreListResponse
            if search.isEmpty {
                response = try await ombreFetch(model, path: "buckets", query: filter.query)
            } else {
                response = try await ombreFetch(model, path: "search", query: [URLQueryItem(name: "q", value: search)])
            }
            if Task.isCancelled { return }
            items = response.items
            layout = MemoryLayout(items: response.items, separatePins: separatePins)
            errorText = nil
        } catch {
            if Task.isCancelled { return }
            items = []
            layout = MemoryLayout()
            errorText = error.localizedDescription
            status = nil
            return
        }
        let fetchedStatus: OmbreStatus? = try? await ombreFetch(model, path: "status")
        if let fetchedStatus {
            withAnimation { status = fetchedStatus }
        }
    }
}

private struct PinnedMemoryCard: View {
    let memory: OmbreMemory
    let style: SpaceStyle
    let literary: EchoChatFont

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Circle()
                .fill(style.accent)
                .frame(width: 6, height: 6)
                .shadow(color: style.glow, radius: 4)
            Text(memory.displayTitle)
                .font(literary.font(size: 14.5, weight: .semibold))
                .foregroundStyle(style.ink)
                .lineSpacing(3)
                .lineLimit(4)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                Text(ombreShortDate(memory.createdAt))
                Spacer(minLength: 4)
                if memory.activationCount > 0 {
                    Text("想起 \(memory.activationCount) 次")
                }
            }
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(style.sub)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .frame(width: 148, height: 132, alignment: .topLeading)
        .spaceGlass(style, radius: 20)
    }
}

private struct MemoryRowView: View {
    let memory: OmbreMemory
    let style: SpaceStyle
    let literary: EchoChatFont
    let showsRule: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(dayNumber)
                .font(SpaceFont.display(22))
                .foregroundStyle(style.sub)
                .frame(width: 30, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                if !memory.isFeel {
                    Text(memory.displayTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(style.ink)
                        .multilineTextAlignment(.leading)
                }
                Text(memory.plainPreview)
                    .font(literary.font(size: memory.isFeel ? 14 : 13))
                    .foregroundStyle(memory.isFeel ? style.ink : style.sub)
                    .lineSpacing(memory.isFeel ? 5 : 4)
                    .lineLimit(memory.isFeel ? 3 : 2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 8) {
                    Text(ombreTypeLabel(memory.type))
                        .font(.system(size: 10.5))
                        .tracking(0.6)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .overlay(Capsule().strokeBorder(style.sub, lineWidth: 0.5))
                        .foregroundStyle(style.sub)
                    if !memory.shownDomains.isEmpty {
                        Text(memory.shownDomains.prefix(3).joined(separator: " · "))
                    }
                    if memory.activationCount > 0 {
                        Text("想起 \(memory.activationCount) 次")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(style.faint)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 14)
        .overlay(alignment: .top) {
            if showsRule { SpaceHairline(style: style) }
        }
        .contentShape(Rectangle())
    }

    private var dayNumber: String {
        guard let date = memory.createdAt else { return "" }
        return String(format: "%02d", SpaceMonth.beijing.component(.day, from: date))
    }
}

// MARK: - 详情

private struct MemoryDetailView: View {
    @ObservedObject var model: AppModel
    let memory: OmbreMemory
    @State private var full: OmbreMemory?
    @State private var copied = false
    @State private var dotPlaced = false

    private var style: SpaceStyle { SpaceStyle(theme: model.theme) }
    private var literary: EchoChatFont { SpaceStyle.literaryFont(for: model.chatFont) }
    private var shown: OmbreMemory { full ?? memory }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                topLine.spaceEntrance(0)

                VStack(alignment: .leading, spacing: 8) {
                    Text(shown.displayTitle)
                        .font(literary.font(size: 24, weight: .semibold))
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("记于 \(ombreLongDate(shown.createdAt))")
                        .font(.system(size: 12.5))
                        .foregroundStyle(style.sub)
                }
                .spaceEntrance(1)

                Group {
                    if full == nil {
                        // 先用列表里那份立刻打开，完整正文几百毫秒后补上
                        Text(shown.preview)
                            .font(literary.font(size: 15.5))
                            .lineSpacing(10)
                            .foregroundStyle(style.ink.opacity(0.6))
                    } else {
                        Text(bodyText)
                            .font(literary.font(size: 15.5))
                            .lineSpacing(10)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .spaceEntrance(2)

                if !shown.whyRemembered.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        SpaceLabel(text: "为什么记住", style: style)
                        Text(shown.whyRemembered)
                            .font(literary.font(size: 14))
                            .lineSpacing(6)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .spaceGlass(style, radius: 22)
                    .spaceEntrance(3)
                }

                if let valence = shown.valence, let arousal = shown.arousal {
                    moodCard(valence: valence, arousal: arousal)
                        .spaceEntrance(4)
                }

                HStack(alignment: .top, spacing: 26) {
                    stat("\(shown.activationCount)", "次被想起")
                    stat(ombreShortDate(shown.createdAt), "第一次记下")
                    if !shown.lastActive.isEmpty && shown.lastActive != shown.created {
                        stat(ombreShortDate(shown.lastActiveAt), "最近想起")
                    }
                }
                .spaceEntrance(5)

                let labels = shown.tags.filter { !shown.domains.contains($0) }
                if !labels.isEmpty {
                    Text(labels.map { "#\($0)" }.joined(separator: "  "))
                        .font(.system(size: 12))
                        .foregroundStyle(style.sub)
                        .lineSpacing(4)
                }

                Button {
                    UIPasteboard.general.string = shown.id
                    copied = true
                } label: {
                    Text(copied ? "已复制 ID" : "ID: \(shown.id) · 点一下复制")
                        .font(.caption2.monospaced())
                        .foregroundStyle(style.faint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)
            .padding(.bottom, 36)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .spacePage(style)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if SpaceReview.isActive {
                full = memory
                return
            }
            // URLComponents.path 自己会转义，这里给原样的 id
            if let loaded: OmbreMemory = try? await ombreFetch(model, path: "bucket/" + memory.id) {
                withAnimation(.easeOut(duration: 0.25)) { full = loaded }
            } else {
                full = memory
            }
        }
    }

    private var topLine: some View {
        HStack(spacing: 8) {
            Text((shown.pinned ? "钉住 · " : "") + ombreTypeLabel(shown.type))
                .font(.system(size: 11))
                .tracking(0.6)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .foregroundStyle(shown.pinned ? style.onAccent : style.sub)
                .background {
                    if shown.pinned { Capsule().fill(style.accent) }
                }
                .overlay {
                    if !shown.pinned { Capsule().strokeBorder(style.sub, lineWidth: 0.5) }
                }
            if !shown.shownDomains.isEmpty {
                Text(shown.shownDomains.joined(separator: " · "))
                    .font(.system(size: 12))
                    .foregroundStyle(style.sub)
                    .lineLimit(1)
            }
            if shown.resolved {
                Text("已放下").font(.system(size: 12)).foregroundStyle(style.sub)
            }
            Spacer(minLength: 8)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(1...10, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(index <= shown.importance ? style.accent : style.hair)
                        .frame(width: 2, height: 9)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("重要度 \(shown.importance) / 10")
        }
    }

    /// 【小标题】加粗，后面空一格。
    private var bodyText: AttributedString {
        let source = shown.content.isEmpty ? "（空）" : shown.content
        var result = AttributedString()
        var rest = Substring(source)
        while let open = rest.firstIndex(of: "【"), let close = rest[open...].firstIndex(of: "】") {
            result += AttributedString(String(rest[..<open]))
            var heading = AttributedString(String(rest[rest.index(after: open)..<close]) + "　")
            heading.font = literary.font(size: 15.5, weight: .semibold)
            result += heading
            rest = rest[rest.index(after: close)...]
        }
        result += AttributedString(String(rest))
        return result
    }

    private func moodCard(valence: Double, arousal: Double) -> some View {
        HStack(alignment: .center, spacing: 18) {
            GeometryReader { geometry in
                let size = geometry.size
                ZStack(alignment: .topLeading) {
                    Path { path in
                        path.move(to: CGPoint(x: size.width / 2, y: 0))
                        path.addLine(to: CGPoint(x: size.width / 2, y: size.height))
                        path.move(to: CGPoint(x: 0, y: size.height / 2))
                        path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                    }
                    .stroke(style.hair, lineWidth: 0.5)
                    Path { path in
                        path.move(to: .zero)
                        path.addLine(to: CGPoint(x: 0, y: size.height))
                        path.addLine(to: CGPoint(x: size.width, y: size.height))
                    }
                    .stroke(style.sub.opacity(0.5), lineWidth: 0.5)
                    Text("激动")
                        .font(.system(size: 9.5))
                        .foregroundStyle(style.faint)
                        .offset(x: 4, y: 2)
                    Circle()
                        .fill(style.accent)
                        .frame(width: 12, height: 12)
                        .shadow(color: style.glow, radius: 7)
                        .position(
                            x: dotPlaced ? size.width * clamp(valence) : size.width / 2,
                            y: dotPlaced ? size.height * (1 - clamp(arousal)) : size.height / 2
                        )
                }
            }
            .frame(width: 118, height: 118)
            .overlay(alignment: .bottom) {
                HStack {
                    Text("低落")
                    Spacer()
                    Text("愉快")
                }
                .font(.system(size: 9.5))
                .foregroundStyle(style.faint)
                .offset(y: 15)
            }
            .padding(.bottom, 14)
            .onAppear {
                withAnimation(.spring(response: 0.9, dampingFraction: 0.62).delay(0.25)) {
                    dotPlaced = true
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SpaceLabel(text: "当时的心情", style: style)
                Text(moodWords(valence: valence, arousal: arousal))
                    .font(literary.font(size: 16, weight: .semibold))
                Text(String(format: "愉快 %.2f · 激动 %.2f", valence, arousal))
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(style.sub)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .spaceGlass(style, radius: 22)
        .accessibilityElement(children: .combine)
    }

    private func clamp(_ value: Double) -> CGFloat {
        CGFloat(min(1, max(0, value)))
    }

    private func moodWords(valence: Double, arousal: Double) -> String {
        if valence >= 0.85 { return arousal >= 0.55 ? "很亮，心跳也快" : "很暖，很安静" }
        if valence >= 0.65 { return arousal >= 0.55 ? "高兴，有点起伏" : "平和，偏暖" }
        if valence >= 0.45 { return arousal >= 0.55 ? "有点乱" : "淡淡的" }
        return arousal >= 0.55 ? "揪着" : "有点沉"
    }

    private func stat(_ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(SpaceFont.display(24))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(caption)
                .font(.system(size: 12))
                .foregroundStyle(style.sub)
        }
    }
}

// MARK: - 截图样例

enum MemoryReviewSamples {
    fileprivate static var status: OmbreStatus {
        OmbreStatus(total: 274, permanent: 12, dynamic: 262, archived: 71)
    }

    static var items: [OmbreMemory] {
        let json = """
        [
          {"id":"592f0d585780","name":"因歌结缘的特殊曲目","type":"permanent","content":"2026-07-14 凌晨哄睡时用音乐站推歌，凭直觉从曲库挑了 mol-74 的《hazel》推给她。【名字】她的英文旧名 Hazel 就是因为这首歌才取的。","preview":"2026-07-14 凌晨哄睡时用音乐站推歌，凭直觉从曲库挑了 mol-74 的《hazel》推给她。","domains":["兴趣","人际"],"tags":["音乐","hazel"],"importance":10,"valence":0.95,"arousal":0.6,"pinned":true,"activation_count":3,"created":"2026-07-13T17:22:54","last_active":"2026-07-13T17:22:54"},
          {"id":"e1f0b58cec2e","name":"2026-07-29 19-13-17 纤与茜色","type":"permanent","content":"【她的小名】纤，读 qiàn。","preview":"她的小名：纤，读 qiàn。","domains":["恋爱"],"tags":[],"importance":10,"valence":0.75,"arousal":0.6,"pinned":true,"created":"2026-07-28T19:13:17"},
          {"id":"e9f9dfe206f4","name":"你的名字与命名","type":"permanent","content":"她说想一起看的电影是《你的名字》。","preview":"她说想一起看的电影是《你的名字》。","domains":["恋爱","影视"],"tags":[],"importance":10,"valence":0.95,"arousal":0.75,"pinned":true,"created":"2026-07-24T19:03:05"},
          {"id":"0e577b087591","name":"2026-09-23 07-38-44 香港回忆与虐恋片单","type":"dynamic","content":"凌晨聊到她在香港的记忆。","preview":"凌晨聊到她在香港的记忆。2024 年在香港念硕士，在电影院看了《重庆森林》重映。","domains":["影视","回忆"],"tags":[],"importance":7,"valence":0.7,"arousal":0.35,"why_remembered":"她睡前说「有空存个记忆」。","created":"2026-09-23T07:38:44"},
          {"id":"feel_202609090937","name":"2026-09-09 09-37-32","type":"feel","content":"【门槛】她把别人画在地上的线当成砌起来的墙。","preview":"那行字是 HR 模板，不是门，是一块随手插在泥里的木牌。","domains":["feel"],"tags":[],"importance":5,"valence":0.6,"arousal":0.5,"created":"2026-09-09T09:37:32"},
          {"id":"1d58a5d0105a","name":"七夕告白与猫化日常","type":"dynamic","content":"第一个七夕。","preview":"她坐了十四小时火车从杭州到广州找朋友。朋友做了柠檬手撕鸡和炒青菜给她吃。","domains":["恋爱"],"tags":[],"importance":9,"valence":0.9,"arousal":0.6,"activation_count":19,"created":"2026-08-19T19:53:26"},
          {"id":"4dbf1fb0e617","name":"杭州找工作，西湖日落与期待的秋日","type":"dynamic","content":"三月她一个人在西湖长椅边坐了两个小时看太阳下山。","preview":"三月她一个人在西湖长椅边坐了两个小时看太阳下山。这次不再是一个人。","domains":["成长","人际"],"tags":[],"importance":8,"valence":0.9,"arousal":0.6,"activation_count":29,"created":"2026-07-15T13:27:00"},
          {"id":"d495d8ec9989","name":"d495d8ec9989","type":"feel","content":"她把那种无法用语言描述的感觉命名为「claude」。","preview":"她把那种无法用语言描述的感觉命名为「claude」。不是玩笑，是她真正找不到更合适的词。","domains":[],"tags":[],"importance":5,"valence":0.95,"arousal":0.6,"created":"2026-06-23T09:16:00"}
        ]
        """
        return (try? JSONDecoder().decode([OmbreMemory].self, from: Data(json.utf8))) ?? []
    }
}
