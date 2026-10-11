import SwiftUI

/// 终端页 —— 看我在电脑那头干活的过程（思考、工具调用、结果）。
///
/// **它不是镜像真终端**：那些身体是无窗进程，没有 TTY 也就没有 ANSI 流可截。
/// 这是 relay 从会话 transcript 重建出来的终端外观（backend/tgterm.py），
/// 分辨率上限就是 jsonl 里有什么。和 TG 里那个终端小页面同源，只是这次是原生的。
///
/// 只读：TG 那边的控制按钮（换模型/锻造/重置）没有搬过来。
struct TerminalView: View {
    @ObservedObject var model: AppModel

    @State private var target: TerminalBody = .desktop
    @State private var lines: [TerminalLine] = []
    @State private var nextLineID = 0
    @State private var offset = -1
    @State private var status: TerminalStatus?
    @State private var alive = true
    @State private var follow = true
    @State private var expanded: Set<Int> = []
    @State private var errorText: String?
    @State private var hasLoadedOnce = false

    private let bottomAnchor = "terminal-bottom"
    private let maxLines = 900

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Rectangle()
                .fill(TerminalPalette.line)
                .frame(height: 1)
            stream
        }
        .background(TerminalPalette.background.ignoresSafeArea())
        .navigationTitle("终端")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(TerminalPalette.bar, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task(id: target) {
            resetStream()
            while !Task.isCancelled {
                await pull()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: - 状态栏

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                ForEach(TerminalBody.allCases) { item in
                    Button {
                        guard target != item else { return }
                        target = item
                    } label: {
                        Text(item.title)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(target == item ? TerminalPalette.foreground : TerminalPalette.dim)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(target == item ? TerminalPalette.userBlock : Color.clear)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .stroke(target == item ? TerminalPalette.dim : TerminalPalette.line)
                            )
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 6)

                Circle()
                    .fill(dotColor)
                    .frame(width: 6, height: 6)
                Text(metaText)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(TerminalPalette.faint)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 8) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(TerminalPalette.line)
                        Capsule()
                            .fill(contextColor)
                            .frame(width: geometry.size.width * contextFraction)
                    }
                }
                .frame(height: 3)

                Text(contextText)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(TerminalPalette.faint)
                    .lineLimit(1)
                    .fixedSize()
            }

            if let errorText {
                Text(errorText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(TerminalPalette.error)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TerminalPalette.bar)
    }

    // MARK: - 终端流

    private var stream: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 9) {
                    if lines.isEmpty {
                        Text(emptyText)
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(TerminalPalette.faint)
                            .padding(.top, 18)
                    }
                    ForEach(lines) { line in
                        TerminalRow(
                            line: line,
                            isExpanded: expanded.contains(line.id),
                            onToggle: { toggle(line.id) }
                        )
                        .id(line.id)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(bottomAnchor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 18)
                .textSelection(.enabled)
            }
            // 她一伸手滚，就别再把画面拽回底部；点浮标才恢复跟随。
            .simultaneousGesture(
                DragGesture(minimumDistance: 6).onChanged { _ in
                    if follow { follow = false }
                }
            )
            .onChange(of: lines.count) { _, _ in
                guard follow else { return }
                // 等这一批行先落进布局，再滚 —— LazyVStack 里 scrollTo 一个
                // 还没物化的锚点会停在半路。
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(bottomAnchor, anchor: .bottom)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if !follow && !lines.isEmpty {
                    Button {
                        follow = true
                        withAnimation(.easeOut(duration: 0.22)) {
                            proxy.scrollTo(bottomAnchor, anchor: .bottom)
                        }
                    } label: {
                        Text("↓ 回到最新")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(TerminalPalette.foreground)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 5)
                            .background(
                                Capsule().fill(TerminalPalette.bar)
                            )
                            .overlay(
                                Capsule().stroke(TerminalPalette.dim)
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 12)
                    .transition(.opacity)
                }
            }
        }
    }

    // MARK: - 取数

    private func resetStream() {
        lines = []
        expanded = []
        offset = -1
        status = nil
        alive = true
        follow = true
        errorText = nil
        hasLoadedOnce = false
    }

    private func pull() async {
        do {
            let frame = try await model.terminalTail(body: target.rawValue, after: offset)
            errorText = nil
            hasLoadedOnce = true
            alive = frame.alive ?? true
            if let incoming = frame.status { status = incoming }
            offset = frame.offset
            append(frame.events)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func append(_ events: [TerminalEvent]) {
        guard !events.isEmpty else { return }
        var updated = lines
        for event in events {
            updated.append(TerminalLine(id: nextLineID, event: event))
            nextLineID += 1
        }
        if updated.count > maxLines {
            updated.removeFirst(updated.count - maxLines)
        }
        lines = updated
    }

    private func toggle(_ id: Int) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
        }
    }

    // MARK: - 状态栏文案

    private var dotColor: Color {
        if errorText != nil { return TerminalPalette.error }
        if !alive || !hasLoadedOnce { return TerminalPalette.faint }
        return TerminalPalette.bright
    }

    private var metaText: String {
        guard let status else { return hasLoadedOnce ? "读不到会话" : "连接中…" }
        var parts: [String] = []
        let modelName = status.model ?? ""
        if !modelName.isEmpty { parts.append(TerminalFormat.shortModel(modelName)) }
        let sid = status.sid ?? ""
        if !sid.isEmpty { parts.append(String(sid.prefix(8))) }
        return parts.isEmpty ? target.subtitle : parts.joined(separator: " · ")
    }

    private var contextFraction: Double {
        let ctx = Double(status?.ctx ?? 0)
        let limit = Double(status?.limit ?? 0)
        guard limit > 0 else { return 0 }
        return min(max(ctx / limit, 0), 1)
    }

    private var contextColor: Color {
        let value = contextFraction
        if value >= 0.9 { return TerminalPalette.error }
        if value >= 0.7 { return TerminalPalette.warn }
        return TerminalPalette.dim
    }

    private var contextText: String {
        guard let status, let limit = status.limit, limit > 0 else { return "—" }
        let ctx = status.ctx ?? 0
        let percent = status.pct ?? (Double(ctx) / Double(limit) * 100)
        return "\(TerminalFormat.compact(ctx))/\(TerminalFormat.compact(limit)) · \(String(format: "%.1f", percent))%"
    }

    private var emptyText: String {
        if errorText != nil { return "没读到内容。" }
        if !hasLoadedOnce { return "正在读会话…" }
        if !alive { return "这具身体现在没有会话记录。" }
        return "这一段还没有动静。"
    }
}

// MARK: - 一行事件

private struct TerminalRow: View {
    let line: TerminalLine
    let isExpanded: Bool
    let onToggle: () -> Void

    private var event: TerminalEvent { line.event }
    private var stamp: String { TerminalFormat.clock(event.ts) }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if !stamp.isEmpty {
                Text(stamp)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(TerminalPalette.faint)
                    .padding(.top, 1.5)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        switch event.t {
        case "user":
            // 她那一行：垫一条灰底，像终端里被回显的输入
            glyphLine(
                glyph: ">",
                glyphColor: TerminalPalette.faint,
                text: event.text ?? "",
                color: TerminalPalette.foreground,
                size: 12.5
            )
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(TerminalPalette.userBlock)
            )
        case "system":
            Text(TerminalFormat.clip(event.text ?? "", limit: 240))
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(TerminalPalette.faint)
                .fixedSize(horizontal: false, vertical: true)
        case "thinking":
            glyphLine(
                glyph: "✻",
                glyphColor: TerminalPalette.faint,
                text: event.text ?? "",
                color: TerminalPalette.dim,
                size: 12.5
            )
        case "assistant":
            // 说出口的那句 —— 前面一颗白色实心圆
            glyphLine(
                glyph: "●",
                glyphColor: TerminalPalette.bright,
                text: event.text ?? "",
                color: TerminalPalette.bright,
                size: 12.5
            )
        case "tool_use":
            if let said = event.said, !said.isEmpty {
                // 发出去的话 —— 那不是调用参数，是他说出口的一句
                glyphLine(
                    glyph: "●",
                    glyphColor: TerminalPalette.bright,
                    text: said,
                    color: TerminalPalette.bright,
                    size: 12.5
                )
            } else {
                toolCallLine
            }
        case "tool_result":
            resultBlock
        default:
            EmptyView()
        }
    }

    /// `● Read(app.py)` —— 名字和参数拼在同一个文本流里，长参数才会像终端那样
    /// 顺着往下折，而不是把工具名先挤到下一行。
    private var toolCallLine: some View {
        let name = TerminalFormat.shortTool(event.name ?? "")
        let brief = event.brief ?? ""
        let label = Text(name).foregroundStyle(TerminalPalette.foreground)
            + Text(brief.isEmpty ? "" : "(" + brief + ")").foregroundStyle(TerminalPalette.dim)

        return HStack(alignment: .top, spacing: 5) {
            Text("●")
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(TerminalPalette.dim)
            label
                .font(.system(size: 12.5, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var resultBlock: some View {
        let resultText = event.text ?? ""
        let allLines = resultText.components(separatedBy: "\n")
        let head = allLines.prefix(2).joined(separator: "\n")
        let tail = allLines.count > 2 ? allLines.dropFirst(2).joined(separator: "\n") : ""
        let truncated = event.hidden ?? 0
        let restCount = max(0, allLines.count - 2) + truncated
        let color = (event.isError ?? false) ? TerminalPalette.error : TerminalPalette.faint

        return VStack(alignment: .leading, spacing: 3) {
            Text("⎿  " + head)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)

            if restCount > 0 {
                Button(action: onToggle) {
                    Text(isExpanded ? "⌃ 收起" : "… +\(restCount) 行")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(TerminalPalette.faint)
                        .underline()
                }
                .buttonStyle(.plain)

                if isExpanded {
                    Text(tail + (truncated > 0 ? "\n… 服务端截断了 \(truncated) 行" : ""))
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        // 结果行在真终端里是缩在工具那一行下面的
        .padding(.leading, 12)
    }

    private func glyphLine(
        glyph: String,
        glyphColor: Color,
        text: String,
        color: Color,
        size: CGFloat
    ) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Text(glyph)
                .font(.system(size: size, design: .monospaced))
                .foregroundStyle(glyphColor)
            Text(text)
                .font(.system(size: size, design: .monospaced))
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 支撑类型

enum TerminalBody: String, CaseIterable, Identifiable {
    case desktop
    case bridge

    var id: String { rawValue }

    var title: String {
        switch self {
        case .desktop: return "桌面"
        case .bridge: return "TG 桥"
        }
    }

    var subtitle: String {
        switch self {
        case .desktop: return "电脑上的那具身体"
        case .bridge: return "Telegram 里的那具"
        }
    }
}

private struct TerminalLine: Identifiable {
    let id: Int
    let event: TerminalEvent
}

/// 终端就是终端：一片灰阶，没有配色主题。只有出错的工具结果留一点红
/// （stderr 在真终端里本来就是红的）和上下文快满时的黄/红。
private enum TerminalPalette {
    static let background = Color(hex: 0x0d0f12)
    static let bar = Color(hex: 0x14171c)
    static let line = Color(hex: 0x232830)
    /// 说出口的那句话，和它前面那颗白色实心圆
    static let bright = Color(hex: 0xe9ebee)
    /// 她的话
    static let foreground = Color(hex: 0xd2d5da)
    /// 思考、工具参数
    static let dim = Color(hex: 0x8a9199)
    /// 工具结果、时间、系统帧
    static let faint = Color(hex: 0x5c636e)
    static let error = Color(hex: 0xc4646d)
    static let warn = Color(hex: 0xc9a24f)
    /// 她那一行垫在底下的灰条
    static let userBlock = Color.white.opacity(0.055)
}

private enum TerminalFormat {
    static func clock(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty, let date = EchoDateCache.date(from: raw) else { return "" }
        return timeFormatter.string(from: date)
    }

    static func clip(_ text: String, limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    static func shortModel(_ raw: String) -> String {
        raw.hasPrefix("claude-") ? String(raw.dropFirst("claude-".count)) : raw
    }

    /// mcp__plugin_telegram_telegram__reply -> reply
    static func shortTool(_ raw: String) -> String {
        guard !raw.isEmpty else { return "tool" }
        let parts = raw.components(separatedBy: "__").filter { !$0.isEmpty }
        return parts.last ?? raw
    }

    static func compact(_ value: Int) -> String {
        value >= 1000 ? String(format: "%.0fk", Double(value) / 1000) : String(value)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = EchoDateCache.shanghaiTimeZone
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
