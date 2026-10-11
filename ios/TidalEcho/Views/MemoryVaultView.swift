import SwiftUI
import UIKit

// MARK: - 他的记忆（ombre Dashboard 只读代理：relay /app/ombre/*）
//
// 密码在 relay.env，这里只带 RELAY_SECRET。整页自带模型和请求，不动 APIClient：
// 走 model.authenticatedRequest(path:)，它已经会挂 Bearer。

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
    }

    var labels: [String] { Array((domains + tags).prefix(3)) }
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

private func ombreTypeColor(_ type: String) -> Color {
    switch type.lowercased() {
    case "permanent": return .orange
    case "feel": return .pink
    case "plan": return .green
    case "letter": return .purple
    case "archived": return .gray
    default: return .cyan
    }
}

private func ombreDate(_ value: String) -> Date? {
    guard !value.isEmpty else { return nil }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = iso.date(from: value) { return date }
    iso.formatOptions = [.withInternetDateTime]
    if let date = iso.date(from: value) { return date }

    // ombre 的 created/last_active 多数是不带时区的本地时间
    let parser = DateFormatter()
    parser.locale = Locale(identifier: "en_US_POSIX")
    parser.timeZone = TimeZone(identifier: "Asia/Shanghai")
    for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
        parser.dateFormat = format
        if let date = parser.date(from: value) { return date }
    }
    return nil
}

private func ombreShortDate(_ value: String) -> String {
    guard let date = ombreDate(value) else { return "" }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_Hans_CN")
    formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
    let sameYear = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: Date())
    formatter.dateFormat = sameYear ? "M月d日" : "yyyy年M月d日"
    return formatter.string(from: date)
}

private func ombreLongDate(_ value: String) -> String {
    guard let date = ombreDate(value) else { return "—" }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_Hans_CN")
    formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
    formatter.dateFormat = "yyyy年M月d日 HH:mm"
    return formatter.string(from: date)
}

private func importanceDots(_ value: Int) -> String {
    let n = max(0, min(10, value))
    return String(repeating: "●", count: n) + String(repeating: "○", count: 10 - n)
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

struct MemoryVaultView: View {
    @ObservedObject var model: AppModel
    @State private var items: [OmbreMemory] = []
    @State private var status: OmbreStatus?
    @State private var filter: OmbreFilter = .all
    @State private var query = ""
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var selected: OmbreMemory?

    private var palette: EchoPalette { model.theme.palette }
    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                header

                if trimmedQuery.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(OmbreFilter.allCases) { option in
                                Button { filter = option } label: {
                                    Text(option.title)
                                        .font(.subheadline.weight(filter == option ? .semibold : .regular))
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 7)
                                        .foregroundStyle(filter == option ? palette.onAccent : palette.text)
                                        .background(
                                            Capsule().fill(filter == option ? palette.accent : palette.composer.opacity(0.9))
                                        )
                                        .overlay(Capsule().stroke(palette.hairline, lineWidth: filter == option ? 0 : 0.7))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                if isLoading && items.isEmpty {
                    ProgressView("正在翻他的记忆…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                } else if let errorText, items.isEmpty {
                    emptyState(icon: "moon.zzz", title: "ombre 睡着了", text: "\(errorText)\n记忆都还在，只是现在翻不开。")
                } else if items.isEmpty {
                    emptyState(
                        icon: "sparkle.magnifyingglass",
                        title: trimmedQuery.isEmpty ? "这里还是空的" : "没找到",
                        text: trimmedQuery.isEmpty ? "换个分类看看。" : "他好像没记过「\(trimmedQuery)」。"
                    )
                } else {
                    ForEach(items) { memory in
                        Button { selected = memory } label: {
                            MemoryCard(memory: memory, palette: palette)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(palette.background.ignoresSafeArea())
        .foregroundStyle(palette.text)
        .navigationTitle("他的记忆")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜他记得的事")
        .refreshable { await load() }
        .task(id: "\(filter.rawValue)|\(trimmedQuery)") {
            // 搜索防抖：停手 350ms 再发；切分类不用等
            if !trimmedQuery.isEmpty {
                try? await Task.sleep(nanoseconds: 350_000_000)
                if Task.isCancelled { return }
            }
            await load()
        }
        .sheet(item: $selected) { memory in
            MemoryDetailSheet(model: model, memory: memory)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(status == nil ? Color.gray.opacity(0.5) : Color.green)
                .frame(width: 7, height: 7)
            if let status {
                Text("记着 \(status.total) 件事 · 永久 \(status.permanent) · 动态 \(status.dynamic) · 沉底 \(status.archived)")
            } else {
                Text(isLoading ? "连接中…" : "离线")
            }
        }
        .font(.caption)
        .foregroundStyle(palette.secondaryText)
        .padding(.top, 4)
    }

    private func emptyState(icon: String, title: String, text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(palette.secondaryText)
            Text(title).font(.headline)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(palette.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .padding(.horizontal, 24)
    }

    @MainActor
    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let search = trimmedQuery
        do {
            let response: OmbreListResponse
            if search.isEmpty {
                response = try await ombreFetch(model, path: "buckets", query: filter.query)
            } else {
                response = try await ombreFetch(model, path: "search", query: [URLQueryItem(name: "q", value: search)])
            }
            if Task.isCancelled { return }
            items = response.items
            errorText = nil
        } catch {
            if Task.isCancelled { return }
            items = []
            errorText = error.localizedDescription
            status = nil
            return
        }
        let fetchedStatus: OmbreStatus? = try? await ombreFetch(model, path: "status")
        if let fetchedStatus { status = fetchedStatus }
    }
}

private struct MemoryCard: View {
    let memory: OmbreMemory
    let palette: EchoPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(ombreTypeLabel(memory.type))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(ombreTypeColor(memory.type))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(ombreTypeColor(memory.type).opacity(0.13), in: Capsule())
                if memory.pinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if memory.resolved {
                    Image(systemName: "checkmark.seal")
                        .font(.caption2)
                        .foregroundStyle(palette.secondaryText)
                }
                Spacer(minLength: 0)
                Text(ombreShortDate(memory.lastActive.isEmpty ? memory.created : memory.lastActive))
                    .font(.caption2)
                    .foregroundStyle(palette.secondaryText)
            }

            Text(memory.name.isEmpty ? "未命名" : memory.name)
                .font(.headline)
                .foregroundStyle(palette.text)
                .multilineTextAlignment(.leading)

            if !memory.preview.isEmpty {
                Text(memory.preview)
                    .font(.subheadline)
                    .foregroundStyle(palette.secondaryText)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }

            HStack(spacing: 8) {
                Text(importanceDots(memory.importance))
                    .font(.system(size: 8))
                    .foregroundStyle(palette.accent.opacity(0.75))
                Spacer(minLength: 0)
                ForEach(memory.labels, id: \.self) { label in
                    Text(label)
                        .font(.caption2)
                        .lineLimit(1)
                        .foregroundStyle(palette.secondaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(palette.hairline.opacity(0.5), in: Capsule())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(palette.composer.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(palette.hairline, lineWidth: 0.7)
        }
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct MemoryDetailSheet: View {
    @ObservedObject var model: AppModel
    let memory: OmbreMemory
    @State private var full: OmbreMemory?
    @State private var copied = false

    private var palette: EchoPalette { model.theme.palette }
    private var shown: OmbreMemory { full ?? memory }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(shown.name.isEmpty ? "未命名" : shown.name)
                        .font(.title2.weight(.bold))
                    Text(
                        [ombreTypeLabel(shown.type), shown.pinned ? "钉住" : nil, shown.resolved ? "已放下" : nil]
                            .compactMap { $0 }
                            .joined(separator: " · ")
                    )
                    .font(.caption)
                    .foregroundStyle(palette.secondaryText)
                }

                if full == nil {
                    // 先用列表里那份立刻打开，完整正文几百毫秒后补上
                    Text(shown.preview)
                        .font(.body)
                        .foregroundStyle(palette.text.opacity(0.6))
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    Text(shown.content.isEmpty ? "（空）" : shown.content)
                        .font(.body)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                }

                if !shown.whyRemembered.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("为什么记住")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(palette.secondaryText)
                        Text(shown.whyRemembered)
                            .font(.subheadline)
                            .italic()
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.composer.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                VStack(spacing: 8) {
                    infoRow("被想起", "\(shown.activationCount) 次")
                    infoRow("写下于", ombreLongDate(shown.created))
                    infoRow("最近想起", ombreLongDate(shown.lastActive))
                    infoRow("重要度", importanceDots(shown.importance))
                    if let valence = shown.valence {
                        infoRow("情绪效价", String(format: "%.2f", valence))
                    }
                    if let arousal = shown.arousal {
                        infoRow("唤醒度", String(format: "%.2f", arousal))
                    }
                }
                .padding(12)
                .background(palette.composer.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                let labels = shown.domains + shown.tags
                if !labels.isEmpty {
                    Text(labels.map { "#\($0)" }.joined(separator: "  "))
                        .font(.caption)
                        .foregroundStyle(palette.secondaryText)
                }

                Button {
                    UIPasteboard.general.string = shown.id
                    copied = true
                } label: {
                    Text(copied ? "已复制 ID" : "ID: \(shown.id) · 点一下复制")
                        .font(.caption2.monospaced())
                        .foregroundStyle(palette.secondaryText.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(palette.background.ignoresSafeArea())
        .foregroundStyle(palette.text)
        .task {
            // URLComponents.path 自己会转义，这里给原样的 id
            if let loaded: OmbreMemory = try? await ombreFetch(model, path: "bucket/" + memory.id) {
                full = loaded
            } else {
                full = memory
            }
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(palette.secondaryText)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
        .font(.footnote)
    }
}
