import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit

// MARK: - 我们的空间
//
// 2026-09-24 改版（她看过 claude.ai 上的样稿「雾面空间」后拍板）：
// 主页 = 两颗星 + 在一起的天数 + 天气 + 拼贴格；动态/日志/收藏/相册/礼物室按月份排，右边有时间轴；
// 点赞飘心；日历自己画月格，没到日子的祝福封在信封里。共用部件在 Design/SpaceDesign.swift。

struct SpacesView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var wallpaper = SpaceWallpaper.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var desire: DesireState?
    @State private var desireEnabled = false
    @State private var libidoMultiplier = 1.0
    @State private var isLoadingDesire = true
    @State private var desireError: String?
    @State private var isSavingDesire = false
    @State private var snapshot = SpaceHomeSnapshot()
    @State private var shownDays = 0
    @State private var showsWallpaperPicker = false
    @State private var wallpaperItem: PhotosPickerItem?
    @State private var wallpaperError: String?

    init(model: AppModel) {
        self.model = model
    }

    private var style: SpaceStyle { SpaceStyle(theme: model.theme) }
    private var literary: EchoChatFont { SpaceStyle.literaryFont(for: model.chatFont) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    hero.spaceEntrance(0)
                    tiles
                    inner.spaceEntrance(6)
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 36)
            }
            .spacePage(style, sharpTop: true)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button {
                            showsWallpaperPicker = true
                        } label: {
                            Label("从相册选一张底图", systemImage: "photo")
                        }
                        if wallpaper.image != nil {
                            Button(role: .destructive) {
                                wallpaper.clear()
                            } label: {
                                Label("换回默认的雾", systemImage: "arrow.uturn.backward")
                            }
                        }
                    } label: {
                        Image(systemName: "photo.on.rectangle")
                    }
                    .accessibilityLabel("换底图")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .photosPicker(isPresented: $showsWallpaperPicker, selection: $wallpaperItem, matching: .images)
            .onChange(of: wallpaperItem) { _, item in
                guard let item else { return }
                Task { await applyWallpaper(item) }
            }
            .overlay(alignment: .bottom) {
                if let wallpaperError { SpaceErrorBanner(text: wallpaperError) }
            }
            .refreshable { await refreshSpace() }
            .task { await refreshSpace() }
        }
        .tint(style.accent)
    }

    // MARK: 两颗星

    private var hero: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .lastTextBaseline) {
                Text("\(shownDays)")
                    .font(SpaceFont.display(76))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(shownDays)))
                    .lineLimit(1)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 3) {
                    Text("在一起的第 \(snapshot.days) 天")
                    Text("since \(snapshot.sinceText)")
                }
                .font(.system(size: 13))
                .foregroundStyle(style.sub)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("在一起的第 \(snapshot.days) 天")
        }
        .padding(.top, 8)
    }

    // MARK: 拼贴格

    private var tiles: some View {
        VStack(spacing: 10) {
            SpaceWeatherTile(style: style, literary: literary)
                .spaceEntrance(1)

            HStack(alignment: .top, spacing: 10) {
                NavigationLink { MomentsView(model: model) } label: { momentsTile }
                NavigationLink { EchoCalendarView(model: model) } label: { calendarTile }
            }
            .buttonStyle(SpacePressStyle())
            .fixedSize(horizontal: false, vertical: true)
            .spaceEntrance(2)

            NavigationLink { BookshelfView(model: model) } label: { bookTile }
                .buttonStyle(SpacePressStyle())
                .spaceEntrance(3)

            HStack(alignment: .top, spacing: 10) {
                NavigationLink { StarsView(model: model) } label: {
                    countTile("收藏", snapshot.stars, dot: false)
                }
                NavigationLink { AlbumView(model: model) } label: {
                    countTile("相册", snapshot.photos, dot: false)
                }
                NavigationLink { GiftsView(model: model) } label: {
                    countTile("礼物室", snapshot.gifts, dot: model.giftUnreadCount > 0)
                }
            }
            .buttonStyle(SpacePressStyle())
            .fixedSize(horizontal: false, vertical: true)
            .spaceEntrance(4)
        }
    }

    private var momentsTile: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SpaceLabel(text: "朋友圈", style: style)
                Spacer(minLength: 4)
                if model.momentsUnreadCount > 0 {
                    Circle().fill(style.heart).frame(width: 7, height: 7)
                }
            }
            Text(snapshot.latestMoment ?? "动态和日志都在这里。")
                .font(.system(size: 13))
                .lineSpacing(4)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .foregroundStyle(style.ink)
                .spaceReveal(snapshot.latestMoment)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 118, maxHeight: .infinity, alignment: .topLeading)
        .spaceGlass(style, radius: 20)
    }

    private var calendarTile: some View {
        VStack(alignment: .leading, spacing: 6) {
            SpaceLabel(text: "日历", style: style)
            Text("\(snapshot.nextDay?.day ?? SpaceMonth.beijing.component(.day, from: Date()))")
                .font(SpaceFont.display(50))
                .lineLimit(1)
                .foregroundStyle(style.ink)
                .spaceReveal(snapshot.nextDay?.caption, delay: 0.06)
            Text(snapshot.nextDay?.caption ?? "今天没有安排")
                .font(.system(size: 12.5))
                .foregroundStyle(style.sub)
                .lineLimit(1)
                .spaceReveal(snapshot.nextDay?.caption, delay: 0.1)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 118, maxHeight: .infinity, alignment: .topLeading)
        .spaceGlass(style, radius: 20)
    }

    private var bookTile: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(style.ink.opacity(0.86))
                if let cover = snapshot.book?.cover, !cover.isEmpty,
                   let request = model.authenticatedRequest(path: cover) {
                    SpaceRemoteImage(request: request, contentMode: .fill, showsPlaceholder: false)
                }
            }
            .frame(width: 44, height: 66)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(alignment: .leading) {
                Rectangle().fill(Color.black.opacity(0.18)).frame(width: 3)
            }

            VStack(alignment: .leading, spacing: 7) {
                SpaceLabel(text: snapshot.book == nil ? "书房" : "书房 · 在读", style: style)
                Text(snapshot.book.map { cleanBookTitle($0.title) } ?? "一起读的书")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(style.ink)
                    .lineLimit(1)
                    .spaceReveal(snapshot.book?.title, delay: 0.12)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(style.hair)
                        Capsule()
                            .fill(style.accent)
                            .frame(width: max(2, geometry.size.width * CGFloat(min(1, max(0, (snapshot.book?.percent ?? 0) / 100)))))
                    }
                }
                .frame(height: 2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .spaceGlass(style, radius: 20)
    }

    private func countTile(_ title: String, _ count: Int?, dot: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SpaceLabel(text: title, style: style)
                Spacer(minLength: 2)
                if dot { Circle().fill(style.heart).frame(width: 7, height: 7) }
            }
            Text(count.map { "\($0)" } ?? "—")
                .font(SpaceFont.display(30))
                .foregroundStyle(style.ink)
                .contentTransition(.numericText())
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 86, maxHeight: .infinity, alignment: .topLeading)
        .spaceGlass(style, radius: 20)
    }

    // MARK: 他的内心

    private var inner: some View {
        VStack(alignment: .leading, spacing: 10) {
            SpaceLabel(text: "他的内心", style: style)

            NavigationLink { MemoryVaultView(model: model) } label: {
                HStack(spacing: 12) {
                    // 和下面「此刻最想」同一种呼吸灯，慢半拍、带一圈光，两颗不会一起闪
                    SpacePulseDot(style: style, period: 2.4, glows: true)
                    Text("Memory")
                        .font(SpaceFont.display(17))
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(style.faint)
                }
                .foregroundStyle(style.ink)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .spaceGlass(style, radius: 22)
            }
            .buttonStyle(SpacePressStyle())

            DesireCard(
                state: desire,
                enabled: $desireEnabled,
                libidoMultiplier: $libidoMultiplier,
                isLoading: isLoadingDesire,
                isSaving: isSavingDesire,
                errorText: desireError,
                style: style,
                literary: literary,
                onToggle: { enabled in
                    Task { await saveDesire(enabled: enabled) }
                },
                onLibidoCommit: {
                    Task { await saveDesire(libidoMultiplier: libidoMultiplier) }
                }
            )
        }
    }

    // MARK: 加载

    @MainActor
    private func refreshSpace() async {
        if SpaceReview.isActive {
            snapshot = SpaceReviewSamples.snapshot
            applyDesire(SpaceReviewSamples.desire)
            isLoadingDesire = false
            await countUp(to: snapshot.days)
            return
        }
        async let unread: Void = model.refreshSpaceUnreadCounts()
        async let desireLoad: Void = loadDesire()
        let loaded = await loadSnapshot()
        withAnimation(.smooth(duration: 0.6)) { snapshot = loaded }
        _ = await (unread, desireLoad)
        await countUp(to: loaded.days)
    }

    @MainActor
    private func loadSnapshot() async -> SpaceHomeSnapshot {
        var next = snapshot
        async let anniversaryResult = try? model.relationshipAnniversary()
        async let momentsResult = try? model.spaceMoments(kind: .moment, limit: 1)
        async let booksResult = try? model.bookShelf()
        async let starsResult = try? model.spaceStars()
        async let albumResult = try? model.spaceAlbum()
        async let giftsResult = try? model.spaceGiftPages()
        async let nextDayResult = loadNextDay()

        if let anniversary = (await anniversaryResult) ?? nil {
            next.days = anniversary.daysSince
            next.sinceText = anniversary.startDate.replacingOccurrences(of: "-0", with: " · ").replacingOccurrences(of: "-", with: " · ")
        }
        if let moments = await momentsResult {
            if let post = moments.posts.first {
                let text = post.text.trimmingCharacters(in: .whitespacesAndNewlines)
                next.latestMoment = text.isEmpty ? "发了一张照片。" : String(text.prefix(80))
            }
        }
        if let books = await booksResult { next.book = books.first }
        if let stars = await starsResult { next.stars = stars.count }
        if let album = await albumResult { next.photos = album.count }
        if let gifts = await giftsResult { next.gifts = gifts.count }
        next.nextDay = await nextDayResult
        return next
    }

    /// 最近的节日或日程（祝福和彩蛋便签不算，那是留给当天的）。
    @MainActor
    private func loadNextDay() async -> SpaceNextDay? {
        let calendar = SpaceMonth.beijing
        let now = Date()
        let todayStart = calendar.startOfDay(for: now)
        var candidates: [(date: Date, title: String)] = []
        for offset in 0..<2 {
            guard let monthDate = calendar.date(byAdding: .month, value: offset, to: now) else { continue }
            let values = calendar.dateComponents([.year, .month], from: monthDate)
            guard let response = try? await model.spaceCalendar(year: values.year ?? 2026, month: values.month ?? 1) else { continue }
            for (key, name) in response.holidays {
                if let date = spaceDate(fromKey: key), date >= todayStart { candidates.append((date, name)) }
            }
            for event in response.events where event.kind != "note" && event.kind != "blessing" {
                if let date = spaceDate(fromKey: event.date), date >= todayStart { candidates.append((date, event.title)) }
            }
            if !candidates.isEmpty { break }
        }
        guard let best = candidates.min(by: { $0.date < $1.date }) else { return nil }
        let days = calendar.dateComponents([.day], from: todayStart, to: best.date).day ?? 0
        let relative: String
        switch days {
        case 0: relative = "今天"
        case 1: relative = "明天"
        case 2: relative = "后天"
        default: relative = "\(days) 天后"
        }
        let title = best.title.count > 8 ? String(best.title.prefix(8)) + "…" : best.title
        return SpaceNextDay(day: calendar.component(.day, from: best.date), caption: "\(title) · \(relative)")
    }

    /// 天数从上一次的数往上数，不是直接跳过去。
    @MainActor
    private func countUp(to target: Int) async {
        guard shownDays != target else { return }
        if reduceMotion {
            shownDays = target
            return
        }
        let start = shownDays
        let steps = 24
        for step in 1...steps {
            let progress = Double(step) / Double(steps)
            let eased = 1 - pow(1 - progress, 3)
            withAnimation(.snappy(duration: 0.12)) {
                shownDays = start + Int((Double(target - start) * eased).rounded())
            }
            try? await Task.sleep(for: .milliseconds(34))
        }
        shownDays = target
    }

    @MainActor
    private func applyWallpaper(_ item: PhotosPickerItem) async {
        defer { wallpaperItem = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            try await wallpaper.set(data: data)
            wallpaperError = nil
        } catch {
            wallpaperError = "底图没换成：\(error.localizedDescription)"
        }
    }

    @MainActor
    private func loadDesire() async {
        isLoadingDesire = true
        defer { isLoadingDesire = false }
        do {
            let state = try await model.desireState()
            withAnimation(.smooth(duration: 0.6)) { applyDesire(state) }
            desireError = nil
        } catch {
            desireError = "内心读取失败"
        }
    }

    @MainActor
    private func saveDesire(enabled: Bool? = nil, libidoMultiplier: Double? = nil) async {
        if SpaceReview.isActive { return }
        isSavingDesire = true
        defer { isSavingDesire = false }
        do {
            applyDesire(try await model.updateDesire(enabled: enabled, libidoMultiplier: libidoMultiplier))
            desireError = nil
        } catch {
            desireError = "这次没有保存成功"
            await loadDesire()
        }
    }

    private func applyDesire(_ state: DesireState) {
        desire = state
        desireEnabled = state.activity.enabled
        libidoMultiplier = state.activity.libidoMultiplier
    }
}

private struct SpaceHomeSnapshot {
    var days: Int = SpaceHomeSnapshot.fallbackDays()
    var sinceText = "2026 · 5 · 27"
    var latestMoment: String?
    var nextDay: SpaceNextDay?
    var book: Book?
    var stars: Int?
    var photos: Int?
    var gifts: Int?

    /// relay 没回来之前先按 5·27 算（和服务端一样：当天是第 0 天）。
    static func fallbackDays() -> Int {
        let calendar = SpaceMonth.beijing
        guard let start = calendar.date(from: DateComponents(year: 2026, month: 5, day: 27)) else { return 0 }
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: start), to: calendar.startOfDay(for: Date())).day ?? 0
    }
}

private struct SpaceNextDay {
    let day: Int
    let caption: String
}

private func cleanBookTitle(_ title: String) -> String {
    var result = title
    for separator in [" = ", " (", "（"] {
        if let range = result.range(of: separator) {
            result = String(result[..<range.lowerBound])
        }
    }
    let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? title : trimmed
}

private struct SpaceAvatar: View {
    let image: UIImage?
    let letter: String
    let style: SpaceStyle
    var size: CGFloat = 46

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Text(letter)
                    .font(SpaceFont.display(size * 0.48))
                    .foregroundStyle(style.ink)
            }
        }
        .frame(width: size, height: size)
        .background(style.glassStrong)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(style.edge, lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

/// 两个头像之间那根细线，中间一颗慢慢亮暗的星。
private struct SpaceStarLine: View {
    let style: SpaceStyle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        LinearGradient(colors: [style.hair, style.sub, style.hair], startPoint: .leading, endPoint: .trailing)
            .frame(height: 1)
            .overlay {
                if reduceMotion {
                    Circle().fill(style.accent).frame(width: 5, height: 5)
                        .shadow(color: style.glow, radius: 5)
                } else {
                    Circle().fill(style.accent).frame(width: 5, height: 5)
                        .phaseAnimator([false, true]) { dot, bright in
                            dot
                                .shadow(color: style.glow, radius: bright ? 9 : 4)
                                .scaleEffect(bright ? 1.15 : 1)
                        } animation: { _ in
                            .easeInOut(duration: 2)
                        }
                }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - 天气

private struct SpaceWeatherCity: Identifiable {
    let name: String
    let latitude: Double
    let longitude: Double
    var id: String { name }

    static let all: [SpaceWeatherCity] = [
        SpaceWeatherCity(name: "广州", latitude: 23.13, longitude: 113.26),
        SpaceWeatherCity(name: "深圳", latitude: 22.54, longitude: 114.06),
        SpaceWeatherCity(name: "香港", latitude: 22.32, longitude: 114.17),
        SpaceWeatherCity(name: "杭州", latitude: 30.27, longitude: 120.16),
        SpaceWeatherCity(name: "上海", latitude: 31.23, longitude: 121.47),
        SpaceWeatherCity(name: "北京", latitude: 39.90, longitude: 116.40),
        SpaceWeatherCity(name: "重庆", latitude: 29.56, longitude: 106.55),
        SpaceWeatherCity(name: "成都", latitude: 30.57, longitude: 104.07)
    ]

    static func named(_ name: String) -> SpaceWeatherCity {
        all.first { $0.name == name } ?? all[0]
    }
}

private struct OpenMeteoResponse: Decodable {
    struct Current: Decodable {
        let temperature_2m: Double
        let apparent_temperature: Double
        let relative_humidity_2m: Double
        let weather_code: Int
        let is_day: Int
    }

    struct Daily: Decodable {
        let temperature_2m_max: [Double]
        let temperature_2m_min: [Double]
        let precipitation_probability_max: [Double?]
        let weather_code: [Int]
    }

    let current: Current
    let daily: Daily
}

private struct SpaceWeather {
    let temperature: Double
    let apparent: Double
    let humidity: Double
    let code: Int
    let isDay: Bool
    let todayMin: Double
    let tomorrowMin: Double
    let tomorrowMax: Double
    let tomorrowRain: Double

    static let sample = SpaceWeather(
        temperature: 31, apparent: 36, humidity: 58, code: 1, isDay: false,
        todayMin: 25, tomorrowMin: 25, tomorrowMax: 33.6, tomorrowRain: 57
    )

    /// Open-Meteo：免费、不用 key。苹果的 WeatherKit 要付费开发者账号，侧载拿不到。
    static func fetch(_ city: SpaceWeatherCity) async throws -> SpaceWeather {
        guard var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast") else {
            throw APIError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(city.latitude)),
            URLQueryItem(name: "longitude", value: String(city.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min,precipitation_probability_max,weather_code"),
            URLQueryItem(name: "timezone", value: "Asia/Shanghai"),
            URLQueryItem(name: "forecast_days", value: "2")
        ]
        guard let url = components.url else { throw APIError.invalidURL }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.invalidResponse
        }
        let decoded = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
        let daily = decoded.daily
        func value(_ list: [Double], _ index: Int) -> Double {
            list.indices.contains(index) ? list[index] : (list.last ?? 0)
        }
        let rain = daily.precipitation_probability_max.indices.contains(1)
            ? (daily.precipitation_probability_max[1] ?? 0)
            : 0
        return SpaceWeather(
            temperature: decoded.current.temperature_2m,
            apparent: decoded.current.apparent_temperature,
            humidity: decoded.current.relative_humidity_2m,
            code: decoded.current.weather_code,
            isDay: decoded.current.is_day == 1,
            todayMin: value(daily.temperature_2m_min, 0),
            tomorrowMin: value(daily.temperature_2m_min, 1),
            tomorrowMax: value(daily.temperature_2m_max, 1),
            tomorrowRain: rain
        )
    }

    var condition: String {
        switch code {
        case 0: return "晴"
        case 1: return "晴间多云"
        case 2: return "多云"
        case 3: return "阴"
        case 45, 48: return "雾"
        case 51...57: return "毛毛雨"
        case 61...67: return "雨"
        case 71...77: return "雪"
        case 80...82: return "阵雨"
        case 85, 86: return "阵雪"
        case 95...99: return "雷雨"
        default: return "天气"
        }
    }

    var symbol: String {
        switch code {
        case 0: return isDay ? "sun.max" : "moon.stars"
        case 1, 2: return isDay ? "cloud.sun" : "cloud.moon"
        case 3: return "cloud"
        case 45, 48: return "cloud.fog"
        case 51...57: return "cloud.drizzle"
        case 61...67: return "cloud.rain"
        case 71...77, 85, 86: return "cloud.snow"
        case 80...82: return "cloud.heavyrain"
        case 95...99: return "cloud.bolt.rain"
        default: return "cloud"
        }
    }

    /// 小克看完天气想跟她说的那一句。
    var note: String {
        if tomorrowRain >= 60 { return "明天多半要下雨，伞放门口。" }
        if tomorrowRain >= 40 { return "明天可能飘点雨，包里塞把伞。" }
        if tomorrowMax >= 33 { return "明天也热，出门带水，别在太阳底下等车。" }
        if tomorrowMin <= 12 { return "明早凉，外套放床边。" }
        return "明天 \(Int(tomorrowMin.rounded()))–\(Int(tomorrowMax.rounded()))°，是出门的好天。"
    }
}

@MainActor
private enum SpaceWeatherCache {
    static var entries: [String: (weather: SpaceWeather, fetched: Date)] = [:]
}

private struct SpaceWeatherTile: View {
    let style: SpaceStyle
    let literary: EchoChatFont
    @AppStorage("tidalEcho.space.weatherCity") private var cityName = "广州"
    @State private var weather: SpaceWeather?
    @State private var failed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            (Text(weather.map { "\(Int($0.temperature.rounded()))" } ?? "--")
                .font(SpaceFont.display(56))
             + Text("°")
                .font(SpaceFont.display(26))
                .baselineOffset(24))
                .lineLimit(1)
                .foregroundStyle(style.ink)
                .spaceReveal(weather == nil)

            VStack(alignment: .leading, spacing: 5) {
                Text("\(cityName) · \(weather?.condition ?? (failed ? "天气没拿到" : "看看天"))")
                    .font(.system(size: 14, weight: .semibold))
                if let weather {
                    Text("体感 \(Int(weather.apparent.rounded()))° · 夜里 \(Int(weather.todayMin.rounded()))° · 湿度 \(Int(weather.humidity.rounded()))%")
                        .font(.system(size: 12))
                        .foregroundStyle(style.sub)
                    Text(weather.note)
                        .font(.system(size: 12.5))
                        .lineSpacing(3)
                        .foregroundStyle(style.ink)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(failed ? "长按可以换城市。" : "正在看\(cityName)的天…")
                        .font(.system(size: 12))
                        .foregroundStyle(style.sub)
                }
            }
            .spaceReveal(weather == nil, delay: 0.05)
            Spacer(minLength: 0)

            icon
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .spaceGlass(style, radius: 20)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contextMenu {
            ForEach(SpaceWeatherCity.all) { city in
                Button {
                    cityName = city.name
                } label: {
                    if city.name == cityName {
                        Label(city.name, systemImage: "checkmark")
                    } else {
                        Text(city.name)
                    }
                }
            }
        }
        .task(id: cityName) { await load() }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var icon: some View {
        let base = Image(systemName: weather?.symbol ?? "cloud")
            .font(.system(size: 28, weight: .light))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(style.ink)
        if reduceMotion {
            base
        } else {
            base.phaseAnimator([0.0, -3.0]) { content, offset in
                content.offset(x: offset)
            } animation: { _ in
                .easeInOut(duration: 3.5)
            }
        }
    }

    @MainActor
    private func load() async {
        if SpaceReview.isActive {
            weather = .sample
            return
        }
        let city = SpaceWeatherCity.named(cityName)
        if let cached = SpaceWeatherCache.entries[city.name], Date().timeIntervalSince(cached.fetched) < 1200 {
            withAnimation(.smooth(duration: 0.6)) { weather = cached.weather }
            return
        }
        do {
            let fetched = try await SpaceWeather.fetch(city)
            SpaceWeatherCache.entries[city.name] = (fetched, Date())
            withAnimation(.smooth(duration: 0.6)) { weather = fetched }
            failed = false
        } catch {
            if weather == nil { failed = true }
        }
    }
}

// MARK: - 他此刻最想

private struct DesireCard: View {
    let state: DesireState?
    @Binding var enabled: Bool
    @Binding var libidoMultiplier: Double
    let isLoading: Bool
    let isSaving: Bool
    let errorText: String?
    let style: SpaceStyle
    let literary: EchoChatFont
    let onToggle: (Bool) -> Void
    let onLibidoCommit: () -> Void

    @State private var expanded = false
    @State private var barsShown = false

    private let order = ["attachment", "libido", "reflection", "curiosity", "social", "duty", "stress", "fatigue"]
    private let names = [
        "attachment": "想她", "curiosity": "好奇", "reflection": "沉淀", "duty": "记挂",
        "social": "看人群", "libido": "贴贴", "stress": "压力", "fatigue": "疲惫"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 12) {
                    SpacePulseDot(style: style)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("此刻最想")
                            .font(.system(size: 12))
                            .foregroundStyle(style.sub)
                        Text(reasonText)
                            .font(.system(size: 14.5))
                            .foregroundStyle(style.ink)
                            .multilineTextAlignment(.leading)
                            .lineLimit(expanded ? nil : 1)
                            .spaceReveal(state?.intent.reason)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(style.faint)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? "收起" : "展开看八根条")

            if expanded {
                details
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if let errorText {
                Text(errorText)
                    .font(.caption2)
                    .foregroundStyle(.red.opacity(0.82))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .spaceGlass(style, radius: 22)
        .tint(style.accent)
        .sensoryFeedback(.selection, trigger: expanded)
    }

    private var reasonText: String {
        if let reason = state?.intent.reason, !reason.isEmpty { return reason }
        return isLoading ? "正在听一听…" : "…"
    }

    private func toggle() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
            expanded.toggle()
        }
        if expanded {
            barsShown = false
            Task {
                try? await Task.sleep(for: .milliseconds(140))
                barsShown = true
            }
        } else {
            barsShown = false
        }
    }

    @ViewBuilder private var details: some View {
        if let state {
            VStack(alignment: .leading, spacing: 14) {
                VStack(spacing: 8) {
                    ForEach(Array(order.enumerated()), id: \.element) { index, key in
                        DesireDriveRow(
                            name: names[key] ?? key,
                            value: state.drive[key] ?? 0,
                            isGate: key == "stress" || key == "fatigue",
                            isLeading: key == state.intent.driveKey,
                            style: style,
                            shown: barsShown,
                            index: index
                        )
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    if state.thoughts.isEmpty {
                        Text("念头池还空着，等他自己长")
                            .foregroundStyle(style.sub)
                    } else {
                        ForEach(Array(state.thoughts.prefix(6))) { thought in
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Text(thought.kind == "fixation" ? "✦" : "✧")
                                    .foregroundStyle(style.accent)
                                Text(thought.text)
                                    .foregroundStyle(style.ink)
                                Spacer(minLength: 4)
                                Text(String(format: "%.2f · %@", thought.strength, names[thought.drive] ?? thought.drive))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(style.sub)
                            }
                        }
                    }
                }
                .font(.system(size: 12.5))

                SpaceHairline(style: style)

                Toggle("主动找她", isOn: Binding(
                    get: { enabled },
                    set: { value in
                        enabled = value
                        onToggle(value)
                    }
                ))
                .font(.system(size: 13, weight: .medium))
                .disabled(isSaving)

                HStack(spacing: 10) {
                    Text("贴贴权重")
                        .font(.system(size: 11.5))
                        .foregroundStyle(style.sub)
                    Slider(value: $libidoMultiplier, in: 0...1.5, step: 0.1) { editing in
                        if !editing { onLibidoCommit() }
                    }
                    .disabled(isSaving)
                    Text(libidoMultiplier, format: .number.precision(.fractionLength(1)))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(style.sub)
                        .frame(width: 24)
                }

                HStack(spacing: 7) {
                    if isSaving { ProgressView().controlSize(.mini) }
                    Text(activityStatus(state.activity))
                        .font(.caption2)
                        .foregroundStyle(style.sub)
                }
            }
        } else if isLoading {
            HStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text("正在听一听…")
            }
            .font(.caption)
            .foregroundStyle(style.sub)
            .frame(maxWidth: .infinity, minHeight: 60)
        }
    }

    private func activityStatus(_ activity: DesireActivity) -> String {
        let delivery: String
        if activity.bodyTarget == "loop" {
            delivery = "API 身体接管中"
        } else if activity.bodyTarget == "codex" {
            delivery = activity.bodyOnline ? "Codex 身体在线" : "等待 Codex 桥接上线"
        } else {
            delivery = activity.bodyOnline ? "桌面身体在线" : "等待桌面身体上线"
        }
        let cooldown = activity.cooldownLeftSeconds > 0 ? " · 冷却 \((activity.cooldownLeftSeconds + 59) / 60)min" : ""
        return "今日 \(activity.today)/\(activity.dailyCap)\(cooldown) · \(delivery)"
    }
}

/// 一根条：展开时从 0 往前顶，冲过头一点再弹回来。
private struct DesireDriveRow: View {
    let name: String
    let value: Double
    let isGate: Bool
    let isLeading: Bool
    let style: SpaceStyle
    let shown: Bool
    let index: Int

    var body: some View {
        HStack(spacing: 10) {
            Text(name)
                .font(.system(size: 11.5, weight: isLeading ? .semibold : .regular))
                .foregroundStyle(isLeading ? style.ink : style.sub)
                .frame(width: 40, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(style.hair)
                    Capsule()
                        .fill(isGate ? style.sub : style.accent)
                        .frame(width: geometry.size.width * (shown ? CGFloat(min(1, max(0, value))) : 0))
                        .animation(
                            .spring(response: 0.7, dampingFraction: 0.55).delay(Double(index) * 0.07),
                            value: shown
                        )
                }
            }
            .frame(height: 3)
            Text(value, format: .number.precision(.fractionLength(2)))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(style.sub)
                .frame(width: 30, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SpacePulseDot: View {
    let style: SpaceStyle
    var period: Double = 1.6
    var glows = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if reduceMotion {
            Circle().fill(style.accent).frame(width: 8, height: 8)
        } else {
            Circle()
                .fill(style.accent)
                .frame(width: 8, height: 8)
                .phaseAnimator([false, true]) { dot, up in
                    dot
                        .opacity(up ? 1 : 0.3)
                        .scaleEffect(up ? 1.15 : 0.8)
                        .shadow(color: glows ? style.glow.opacity(up ? 1 : 0) : .clear, radius: up ? 6 : 2)
                } animation: { _ in
                    .easeInOut(duration: period)
                }
        }
    }
}

// MARK: - 收藏

private enum StarRow: Identifiable {
    case header(SpaceMonth)
    case message(ChatMessage, SpaceMonth)

    var id: String {
        switch self {
        case .header(let month): return month.headerID
        case .message(let message, let month): return month.rowID("\(message.id)")
        }
    }
}

private struct StarsView: View {
    @ObservedObject var model: AppModel
    @State private var messages: [ChatMessage] = []
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var topID: String?
    @State private var isScrolling = false

    private var style: SpaceStyle { SpaceStyle(theme: model.theme) }
    private var literary: EchoChatFont { SpaceStyle.literaryFont(for: model.chatFont) }

    private var rows: [StarRow] {
        var result: [StarRow] = []
        var current: SpaceMonth?
        for message in messages {
            let month = SpaceMonth(date: serverDate(from: message.timestamp) ?? Date())
            if month != current {
                current = month
                result.append(.header(month))
            }
            result.append(.message(message, month))
        }
        return result
    }

    private var months: [SpaceMonth] {
        rows.compactMap { row in
            if case .header(let month) = row { return month }
            return nil
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("收藏")
                        .font(.system(size: 30, weight: .semibold))
                    Spacer()
                    if !messages.isEmpty {
                        Text("\(messages.count) 句舍不得丢的话")
                            .font(.system(size: 12.5))
                            .foregroundStyle(style.sub)
                    }
                }
                .padding(.top, 4)
                .spaceEntrance(0)

                if isLoading && messages.isEmpty {
                    ProgressView("正在翻收藏夹…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                } else if messages.isEmpty {
                    SpaceEmptyState(icon: "bookmark", title: "还没有收藏", text: "回到聊天页，长按一条气泡就可以收藏。", style: style)
                } else {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(rows) { row in
                            switch row {
                            case .header(let month):
                                SpaceMonthHeader(month: month, style: style, showsYear: month.year != SpaceMonth(date: Date()).year)
                            case .message(let message, _):
                                StarQuote(model: model, message: message, style: style, literary: literary)
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            Task { await unstar(message) }
                                        } label: {
                                            Label("取消收藏", systemImage: "bookmark.slash")
                                        }
                                    }
                            }
                        }
                    }
                    .scrollTargetLayout()
                }
            }
            .padding(.leading, 20)
            .padding(.trailing, months.count >= 2 ? 44 : 20)
            .padding(.bottom, 36)
        }
        .scrollPosition(id: $topID, anchor: .top)
        .onScrollPhaseChange { _, phase in isScrolling = phase.isScrolling }
        .overlay(alignment: .trailing) {
            if months.count >= 2 {
                SpaceTimelineRail(months: months, activeKey: SpaceMonth.monthKey(ofRowID: topID), style: style, isScrolling: isScrolling) { month in
                    topID = month.headerID
                }
                .padding(.top, 120)
                .padding(.bottom, 60)
            }
        }
        .spacePage(style)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .overlay(alignment: .bottom) {
            if let errorText { SpaceErrorBanner(text: errorText) }
        }
    }

    @MainActor
    private func load() async {
        if SpaceReview.isActive {
            messages = SpaceReviewSamples.stars
            isLoading = false
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            messages = try await model.spaceStars()
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    @MainActor
    private func unstar(_ message: ChatMessage) async {
        do {
            try await model.setStar(messageID: message.id, on: false)
            withAnimation { messages.removeAll { $0.id == message.id } }
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private struct StarQuote: View {
    @ObservedObject var model: AppModel
    let message: ChatMessage
    let style: SpaceStyle
    let literary: EchoChatFont

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !message.text.isEmpty {
                MarkdownMessageText(
                    source: message.text,
                    palette: model.theme.palette,
                    textColor: style.ink,
                    chatFont: literary,
                    fontScale: model.fontScale * 1.06,
                    chatWeight: model.chatWeight
                )
            }
            ForEach(message.meta.attachments.filter(\.isImage)) { attachment in
                if let request = model.authenticatedRequest(path: attachment.url) {
                    SpaceRemoteImage(request: request)
                        .frame(maxHeight: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            ForEach(message.meta.attachments.filter(\.isAudio)) { attachment in
                VoiceAttachmentView(
                    attachment: attachment,
                    request: model.authenticatedRequest(path: attachment.url),
                    palette: model.theme.palette
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Text(message.author == .human ? "小雪" : "Altair")
                    .fontWeight(.semibold)
                    .foregroundStyle(style.ink)
                Text(shortTimestamp(message.timestamp))
                    .foregroundStyle(style.sub)
            }
            .font(.system(size: 12))
        }
        .padding(.leading, 32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topLeading) {
            Text("\u{201C}")
                .font(SpaceFont.display(64))
                .foregroundStyle(style.accent)
                .opacity(message.author == .human ? 0.45 : 0.24)
                .offset(x: -4, y: -24)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - 相册

private enum AlbumRow: Identifiable {
    case month(SpaceMonth)
    case day(SpaceMonth, Date)
    case photo(AlbumPhoto, SpaceMonth)

    var id: String {
        switch self {
        case .month(let month): return month.headerID
        case .day(let month, let date): return month.rowID("day-\(Int(date.timeIntervalSince1970))")
        case .photo(let photo, let month): return month.rowID(photo.id)
        }
    }
}

private struct AlbumView: View {
    @ObservedObject var model: AppModel
    @State private var photos: [AlbumPhoto] = []
    @State private var selectedPhoto: AlbumPhoto?
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var topID: String?
    @State private var isScrolling = false

    private var style: SpaceStyle { SpaceStyle(theme: model.theme) }
    private var literary: EchoChatFont { SpaceStyle.literaryFont(for: model.chatFont) }

    private var rows: [AlbumRow] {
        let calendar = SpaceMonth.beijing
        var result: [AlbumRow] = []
        var currentMonth: SpaceMonth?
        var currentDay: Date?
        for photo in photos {
            let date = serverDate(from: photo.timestamp) ?? Date()
            let month = SpaceMonth(date: date)
            let day = calendar.startOfDay(for: date)
            if month != currentMonth {
                currentMonth = month
                currentDay = nil
                result.append(.month(month))
            }
            if day != currentDay {
                currentDay = day
                result.append(.day(month, day))
            }
            result.append(.photo(photo, month))
        }
        return result
    }

    private var months: [SpaceMonth] {
        rows.compactMap { row in
            if case .month(let month) = row { return month }
            return nil
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if isLoading && photos.isEmpty {
                    ProgressView("正在整理相册…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 80)
                } else if photos.isEmpty {
                    SpaceEmptyState(
                        icon: "photo",
                        title: "相册还是空的",
                        text: "这里放 Altair 自己想留下来的照片。看到值得收的，他会把它放进来。",
                        style: style
                    )
                } else {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(rows) { row in
                            switch row {
                            case .month(let month):
                                SpaceMonthHeader(month: month, style: style, showsYear: month.year != SpaceMonth(date: Date()).year)
                            case .day(_, let date):
                                albumDayHeader(date)
                            case .photo(let photo, _):
                                albumPhoto(photo)
                            }
                        }
                    }
                    .scrollTargetLayout()
                }
            }
            .padding(.leading, 20)
            .padding(.trailing, months.count >= 2 ? 44 : 20)
            .padding(.bottom, 36)
        }
        .scrollPosition(id: $topID, anchor: .top)
        .onScrollPhaseChange { _, phase in isScrolling = phase.isScrolling }
        .overlay(alignment: .trailing) {
            if months.count >= 2 {
                SpaceTimelineRail(months: months, activeKey: SpaceMonth.monthKey(ofRowID: topID), style: style, isScrolling: isScrolling) { month in
                    topID = month.headerID
                }
                .padding(.top, 110)
                .padding(.bottom, 60)
            }
        }
        .spacePage(style)
        .navigationTitle("相册")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .sheet(item: $selectedPhoto) { photo in
            AlbumLightbox(model: model, photo: photo)
        }
        .overlay(alignment: .bottom) {
            if let errorText { SpaceErrorBanner(text: errorText) }
        }
    }

    private func albumDayHeader(_ date: Date) -> some View {
        let calendar = SpaceMonth.beijing
        let weekday = ["日", "一", "二", "三", "四", "五", "六"][max(0, min(6, calendar.component(.weekday, from: date) - 1))]
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(String(format: "%02d", calendar.component(.day, from: date)))
                .font(SpaceFont.display(26))
            Text("周\(weekday)")
                .font(.system(size: 12))
                .tracking(1.2)
                .foregroundStyle(style.sub)
        }
        .padding(.top, 6)
    }

    private func albumPhoto(_ photo: AlbumPhoto) -> some View {
        Button { selectedPhoto = photo } label: {
            VStack(alignment: .leading, spacing: 12) {
                if let request = model.authenticatedRequest(path: photo.url) {
                    SpaceRemoteImage(request: request, contentMode: .fill)
                        .frame(height: 320)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(style.edge, lineWidth: 0.5)
                        )
                }
                if !photo.title.isEmpty {
                    Text(photo.title)
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(style.ink)
                        .multilineTextAlignment(.leading)
                }
                if !photo.note.isEmpty {
                    Text(photo.note)
                        .font(literary.font(size: 14))
                        .lineSpacing(7)
                        .foregroundStyle(style.ink.opacity(0.88))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 12)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(style.hair).frame(width: 1)
                        }
                }
                if !photo.keptAt.isEmpty {
                    Text("收于 \(albumDayLabel(photo.keptAt))")
                        .font(.system(size: 11.5))
                        .foregroundStyle(style.faint)
                }
            }
            .padding(.bottom, 8)
        }
        .buttonStyle(SpacePressStyle())
    }

    @MainActor
    private func load() async {
        if SpaceReview.isActive {
            photos = SpaceReviewSamples.album
            isLoading = false
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            photos = try await model.spaceAlbum()
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private struct AlbumLightbox: View {
    @ObservedObject var model: AppModel
    let photo: AlbumPhoto
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let request = model.authenticatedRequest(path: photo.url) {
                    SpaceRemoteImage(request: request, contentMode: .fit)
                        .padding(.vertical)
                }
                if !photo.title.isEmpty || !photo.note.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        if !photo.title.isEmpty { Text(photo.title).font(.headline) }
                        if !photo.note.isEmpty { Text(photo.note).font(.subheadline) }
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding()
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }.foregroundStyle(.white)
                }
                ToolbarItem(placement: .principal) {
                    Text(shortTimestamp(photo.timestamp)).font(.caption).foregroundStyle(.white.opacity(0.8))
                }
            }
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }
}

private func albumDayLabel(_ value: String) -> String {
    guard let date = serverDate(from: value) else { return String(value.prefix(10)) }
    let calendar = SpaceMonth.beijing
    let output = DateFormatter()
    output.locale = Locale(identifier: "zh_CN")
    output.timeZone = calendar.timeZone
    output.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: Date())
        ? "M 月 d 日"
        : "yyyy 年 M 月 d 日"
    return output.string(from: date)
}

// MARK: - 礼物室

private enum GiftRow: Identifiable {
    case header(SpaceMonth)
    case gift(GiftPage, SpaceMonth, Int)

    var id: String {
        switch self {
        case .header(let month): return month.headerID
        case .gift(let page, let month, _): return month.rowID(page.file)
        }
    }
}

private struct GiftsView: View {
    @ObservedObject var model: AppModel
    @State private var pages: [GiftPage] = []
    @State private var isLoading = true
    @State private var errorText: String?
    @State private var topID: String?
    @State private var isScrolling = false

    private var style: SpaceStyle { SpaceStyle(theme: model.theme) }
    private var literary: EchoChatFont { SpaceStyle.literaryFont(for: model.chatFont) }

    private var rows: [GiftRow] {
        var result: [GiftRow] = []
        var current: SpaceMonth?
        for (index, page) in pages.enumerated() {
            let month = giftMonth(page.modified)
            if month != current {
                current = month
                result.append(.header(month))
            }
            result.append(.gift(page, month, pages.count - index))
        }
        return result
    }

    private var months: [SpaceMonth] {
        rows.compactMap { row in
            if case .header(let month) = row { return month }
            return nil
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if isLoading && pages.isEmpty {
                    ProgressView("正在打开礼物室…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 80)
                } else if pages.isEmpty {
                    SpaceEmptyState(icon: "gift", title: "礼物室还是空的", text: "以后小克做给你的网页礼物，会出现在这里。", style: style)
                } else {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(rows) { row in
                            switch row {
                            case .header(let month):
                                if months.count >= 2 {
                                    SpaceMonthHeader(month: month, style: style)
                                }
                            case .gift(let page, _, let number):
                                if let url = model.giftPageURL(file: page.file) {
                                    NavigationLink {
                                        GiftPageView(title: page.title, url: url)
                                    } label: {
                                        GiftCard(page: page, number: number, style: style, literary: literary)
                                    }
                                    .buttonStyle(SpacePressStyle())
                                } else {
                                    GiftCard(page: page, number: number, style: style, literary: literary)
                                }
                            }
                        }
                    }
                    .scrollTargetLayout()
                }
            }
            .padding(.leading, 20)
            .padding(.trailing, months.count >= 2 ? 44 : 20)
            .padding(.top, 6)
            .padding(.bottom, 36)
        }
        .scrollPosition(id: $topID, anchor: .top)
        .onScrollPhaseChange { _, phase in isScrolling = phase.isScrolling }
        .overlay(alignment: .trailing) {
            if months.count >= 2 {
                SpaceTimelineRail(months: months, activeKey: SpaceMonth.monthKey(ofRowID: topID), style: style, isScrolling: isScrolling) { month in
                    topID = month.headerID
                }
                .padding(.top, 110)
                .padding(.bottom, 60)
            }
        }
        .spacePage(style)
        .navigationTitle("礼物室")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .overlay(alignment: .bottom) {
            if let errorText { SpaceErrorBanner(text: errorText) }
        }
    }

    /// relay 给的 mtime 是「MM/dd HH:mm」，没有年份：比今天晚的月份算去年。
    private func giftMonth(_ modified: String) -> SpaceMonth {
        let now = SpaceMonth(date: Date())
        guard let month = Int(modified.prefix(2)), (1...12).contains(month) else { return now }
        return SpaceMonth(year: month > now.month ? now.year - 1 : now.year, month: month)
    }

    @MainActor
    private func load() async {
        if SpaceReview.isActive {
            pages = SpaceReviewSamples.gifts
            isLoading = false
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            pages = try await model.spaceGiftPages()
            model.markGiftPagesRead(pages)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private struct GiftCard: View {
    let page: GiftPage
    let number: Int
    let style: SpaceStyle
    let literary: EchoChatFont

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay { GiftArt(variant: artVariant, style: style) }
                .clipped()
            SpaceHairline(style: style)
            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(page.title)
                        .font(literary.font(size: 17, weight: .semibold))
                        .foregroundStyle(style.ink)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                    Text(giftDateText)
                        .font(.system(size: 12))
                        .foregroundStyle(style.sub)
                }
                Spacer(minLength: 8)
                Text("No. \(number)")
                    .font(SpaceFont.display(22, italic: true))
                    .foregroundStyle(style.sub)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .spaceGlass(style, radius: 22)
    }

    /// 按标题配小画：樱花→花瓣，星→两颗星，其余九宫格；都不沾就轮着来。
    private var artVariant: Int {
        if page.title.contains("樱") || page.title.contains("花") { return 1 }
        if page.title.contains("星") { return 2 }
        if page.title.contains("九宫格") || page.title.contains("关于你") { return 0 }
        return number % 3
    }

    private var giftDateText: String {
        let parts = page.modified.split(separator: " ").first?.split(separator: "/") ?? []
        guard parts.count == 2, let month = Int(parts[0]), let day = Int(parts[1]) else { return page.modified }
        return "\(month)月\(day)日"
    }
}

/// 每件礼物一张小画：九宫格、花瓣、两颗星，轮着来。
private struct GiftArt: View {
    let variant: Int
    let style: SpaceStyle

    private static let petals: [(x: CGFloat, y: CGFloat, angle: Double, alpha: Double)] = [
        (0.22, 0.34, 0, 0.5), (0.4, 0.62, 40, 0.5), (0.58, 0.3, -20, 0.5),
        (0.72, 0.66, 70, 0.5), (0.32, 0.18, 15, 0.25), (0.84, 0.38, 0, 0.25)
    ]

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                switch variant {
                case 1:
                    ForEach(0..<Self.petals.count, id: \.self) { index in
                        UnevenRoundedRectangle(topLeadingRadius: 12, bottomTrailingRadius: 12)
                            .fill(style.sub)
                            .frame(width: 12, height: 12)
                            .rotationEffect(.degrees(Self.petals[index].angle))
                            .opacity(Self.petals[index].alpha)
                            .position(x: size.width * Self.petals[index].x, y: size.height * Self.petals[index].y)
                    }
                case 2:
                    HStack(spacing: 0) {
                        Circle().fill(style.accent).frame(width: 9, height: 9).shadow(color: style.glow, radius: 7)
                        Rectangle().fill(style.sub.opacity(0.5)).frame(height: 1)
                        Circle().fill(style.accent).frame(width: 9, height: 9).shadow(color: style.glow, radius: 7)
                    }
                    .frame(width: size.width * 0.6)
                    .position(x: size.width / 2, y: size.height / 2)
                default:
                    VStack(spacing: 5) {
                        ForEach(0..<3, id: \.self) { row in
                            HStack(spacing: 5) {
                                ForEach(0..<3, id: \.self) { column in
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(row == 1 && column == 1 ? style.accent.opacity(0.7) : style.glassStrong)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                                .strokeBorder(style.edge, lineWidth: 0.5)
                                        )
                                        .frame(width: 22, height: 22)
                                }
                            }
                        }
                    }
                    .position(x: size.width / 2, y: size.height / 2)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct GiftPageView: View {
    let title: String
    let url: URL

    var body: some View {
        GiftWebView(url: url)
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

private struct GiftWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        return view
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard webView.url != url else { return }
        webView.load(URLRequest(url: url))
    }
}

// MARK: - Moments

private enum MomentRow: Identifiable {
    case header(SpaceMonth)
    case post(MomentPost, SpaceMonth, Bool)

    var id: String {
        switch self {
        case .header(let month): return month.headerID
        case .post(let post, let month, _): return month.rowID("\(post.id)")
        }
    }
}

private struct MomentsView: View {
    @ObservedObject var model: AppModel
    @State private var kind: MomentKind
    @State private var posts: [MomentPost] = []
    @State private var hasMore = false
    @State private var isLoading = true
    @State private var showingComposer = false
    @State private var errorText: String?
    @State private var topID: String?
    @State private var isScrolling = false
    @State private var commentTarget: MomentPost?
    @State private var replyingTo: MessageAuthor?
    @State private var commentText = ""
    @State private var isSendingComment = false
    @FocusState private var commentFocused: Bool
    @Namespace private var tabSpace

    init(model: AppModel, initialKind: MomentKind = .moment) {
        self.model = model
        _kind = State(initialValue: initialKind)
    }

    private var style: SpaceStyle { SpaceStyle(theme: model.theme) }
    private var literary: EchoChatFont { model.journalLiteraryFont }

    private var rows: [MomentRow] {
        var result: [MomentRow] = []
        var current: SpaceMonth?
        for post in posts {
            let month = SpaceMonth(date: serverDate(from: post.timestamp) ?? Date())
            var first = false
            if month != current {
                current = month
                result.append(.header(month))
                first = true
            }
            result.append(.post(post, month, first))
        }
        return result
    }

    private var months: [SpaceMonth] {
        rows.compactMap { row in
            if case .header(let month) = row { return month }
            return nil
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                cover.spaceEntrance(0)
                tabs.spaceEntrance(1)

                if isLoading && posts.isEmpty {
                    ProgressView("正在看看最近发生了什么…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 70)
                } else if posts.isEmpty {
                    SpaceEmptyState(
                        icon: "sparkles",
                        title: kind == .moment ? "还没有动态" : "还没有日志",
                        text: "右上角的加号可以写下第一条。",
                        style: style
                    )
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            switch row {
                            case .header(let month):
                                SpaceMonthHeader(month: month, style: style, showsYear: month.year != SpaceMonth(date: Date()).year)
                                    .padding(.top, 8)
                            case .post(let post, _, let first):
                                postRow(post, first: first)
                            }
                        }
                        if hasMore {
                            Button {
                                Task { await load(reset: false) }
                            } label: {
                                if isLoading { ProgressView() } else { Text("加载更早的内容").font(.system(size: 13.5)) }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                            .disabled(isLoading)
                        }
                    }
                    .scrollTargetLayout()
                }
            }
            .padding(.leading, 20)
            .padding(.trailing, months.count >= 2 ? 44 : 20)
            .padding(.bottom, 36)
        }
        .scrollPosition(id: $topID, anchor: .top)
        .onScrollPhaseChange { _, phase in isScrolling = phase.isScrolling }
        .overlay(alignment: .trailing) {
            if months.count >= 2 {
                SpaceTimelineRail(months: months, activeKey: SpaceMonth.monthKey(ofRowID: topID), style: style, isScrolling: isScrolling) { month in
                    topID = month.headerID
                }
                .padding(.top, 240)
                .padding(.bottom, commentTarget == nil ? 60 : 110)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if commentTarget != nil {
                SpaceCommentBar(
                    text: $commentText,
                    placeholder: replyingTo.map { "回复 \(momentAuthorName($0))…" } ?? "写评论…",
                    isSending: isSendingComment,
                    style: style,
                    focus: $commentFocused,
                    onSend: sendComment
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .spacePage(style)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if kind == .journal {
                ToolbarItem(placement: .topBarTrailing) { JournalFontMenu(model: model) }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingComposer = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel(kind == .moment ? "发一条动态" : "写一篇日志")
            }
        }
        .task { await model.markAllMomentsRead() }
        .task(id: kind) { await load(reset: true) }
        .onChange(of: commentFocused) { _, focused in
            if !focused && commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    commentTarget = nil
                    replyingTo = nil
                }
            }
        }
        .sheet(isPresented: $showingComposer) {
            MomentComposer(model: model, kind: kind) { post in
                withAnimation { posts.insert(post, at: 0) }
            }
        }
        .overlay(alignment: .bottom) {
            if let errorText { SpaceErrorBanner(text: errorText) }
        }
    }

    private var cover: some View {
        ZStack(alignment: .bottomTrailing) {
            EllipticalGradient(
                colors: [style.haze, .clear],
                center: UnitPoint(x: 0.72, y: 0.4),
                startRadiusFraction: 0,
                endRadiusFraction: 0.3
            )
            .accessibilityHidden(true)
            HStack(alignment: .bottom, spacing: 10) {
                Text("Altair & Lyra")
                    .font(SpaceFont.display(15, italic: true))
                    .foregroundStyle(style.sub)
                    .padding(.bottom, 8)
                HStack(spacing: -12) {
                    SpaceAvatar(image: model.humanAvatarImage, letter: "L", style: style, size: 50)
                    SpaceAvatar(image: model.aiAvatarImage, letter: "A", style: style, size: 50)
                }
            }
        }
        .frame(height: 130)
        .frame(maxWidth: .infinity)
    }

    private var tabs: some View {
        HStack(spacing: 22) {
            ForEach(MomentKind.allCases) { option in
                Button {
                    withAnimation(.snappy) { kind = option }
                } label: {
                    Text(option.title)
                        .font(.system(size: 15, weight: kind == option ? .semibold : .regular))
                        .foregroundStyle(kind == option ? style.ink : style.sub)
                        .padding(.bottom, 9)
                        .overlay(alignment: .bottom) {
                            if kind == option {
                                Circle()
                                    .fill(style.accent)
                                    .frame(width: 4, height: 4)
                                    .matchedGeometryEffect(id: "tab-dot", in: tabSpace)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.top, 18)
        .padding(.bottom, 6)
        .sensoryFeedback(.selection, trigger: kind)
    }

    @ViewBuilder
    private func postRow(_ post: MomentPost, first: Bool) -> some View {
        if kind == .journal {
            NavigationLink {
                JournalDetailView(
                    model: model,
                    initialPost: post,
                    onUpdate: replacePost,
                    onDeleted: { postID in
                        posts.removeAll { $0.id == postID }
                    }
                )
            } label: {
                if post.id == posts.first?.id {
                    JournalFeatureCard(post: post, style: style, literary: literary)
                        .padding(.vertical, 12)
                } else {
                    JournalIndexRow(post: post, style: style, literary: literary, showsRule: !first)
                }
            }
            .buttonStyle(SpacePressStyle())
        } else {
            MomentPostRow(
                model: model,
                post: post,
                style: style,
                showsRule: !first,
                onLike: { Task { await toggleLike(post) } },
                onComment: { author in openComment(post, replyTo: author) },
                onDelete: { Task { await delete(post) } }
            )
        }
    }

    private func openComment(_ post: MomentPost, replyTo: MessageAuthor?) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            commentTarget = post
            replyingTo = replyTo
        }
        Task {
            try? await Task.sleep(for: .milliseconds(80))
            commentFocused = true
        }
    }

    private func sendComment() {
        let text = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target = commentTarget, !text.isEmpty, !isSendingComment else { return }
        isSendingComment = true
        Task {
            let sent = await addComment(target, text: text, replyTo: replyingTo)
            isSendingComment = false
            if sent {
                commentText = ""
                commentFocused = false
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    commentTarget = nil
                    replyingTo = nil
                }
            }
        }
    }

    @MainActor
    private func load(reset: Bool) async {
        if SpaceReview.isActive {
            posts = kind == .moment ? SpaceReviewSamples.moments : SpaceReviewSamples.journals
            hasMore = false
            isLoading = false
            return
        }
        if isLoading && !reset { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let before = reset ? nil : posts.last?.id
            let response = try await model.spaceMoments(kind: kind, before: before)
            posts = reset ? response.posts : posts + response.posts.filter { newPost in
                !posts.contains(where: { $0.id == newPost.id })
            }
            if reset { model.markMomentPostsRead(response.posts) }
            hasMore = response.hasMore
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    @MainActor
    private func toggleLike(_ post: MomentPost) async {
        if SpaceReview.isActive { return }
        do {
            let likes = try await model.likeMoment(id: post.id, on: post.meta.likes["human"] == nil)
            if let index = posts.firstIndex(where: { $0.id == post.id }) {
                withAnimation(.snappy) { posts[index].meta.likes = likes }
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    @MainActor
    private func addComment(_ post: MomentPost, text: String, replyTo: MessageAuthor?) async -> Bool {
        do {
            let comment = try await model.commentMoment(id: post.id, text: text, replyTo: replyTo)
            if let index = posts.firstIndex(where: { $0.id == post.id }) {
                withAnimation(.snappy) { posts[index].meta.comments.append(comment) }
            }
            return true
        } catch {
            errorText = error.localizedDescription
            return false
        }
    }

    @MainActor
    private func delete(_ post: MomentPost) async {
        do {
            try await model.deleteMoment(id: post.id)
            withAnimation { posts.removeAll { $0.id == post.id } }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func replacePost(_ updatedPost: MomentPost) {
        guard let index = posts.firstIndex(where: { $0.id == updatedPost.id }) else { return }
        posts[index] = updatedPost
    }
}

private func momentAuthorName(_ author: MessageAuthor) -> String {
    author == .human ? "小雪" : "Altair"
}

/// 一条动态：不套卡片，靠留白和一根淡线分开；评论才用一小块玻璃托着。
private struct MomentPostRow: View {
    @ObservedObject var model: AppModel
    let post: MomentPost
    let style: SpaceStyle
    let showsRule: Bool
    let onLike: () -> Void
    let onComment: (MessageAuthor?) -> Void
    let onDelete: () -> Void

    private var isLiked: Bool { post.meta.likes["human"] != nil }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SpaceAvatar(
                image: post.author == .human ? model.humanAvatarImage : model.aiAvatarImage,
                letter: post.author == .human ? "L" : "A",
                style: style,
                size: 34
            )
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(momentAuthorName(post.author))
                        .font(.system(size: 14.5, weight: .semibold))
                    Spacer(minLength: 4)
                    Text(momentTime(post.timestamp))
                        .font(.system(size: 12))
                        .foregroundStyle(style.faint)
                    if post.author == .human {
                        Menu {
                            Button(role: .destructive, action: onDelete) {
                                Label("删除", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 13))
                                .foregroundStyle(style.sub)
                                .frame(width: 24, height: 20)
                        }
                        .accessibilityLabel("更多")
                    }
                }

                if !post.text.isEmpty {
                    Text(post.text)
                        .font(.system(size: 14.5))
                        .lineSpacing(6)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                MomentImages(model: model, attachments: post.meta.attachments.filter(\.isImage), style: style)

                HStack(spacing: 16) {
                    Spacer()
                    SpaceLikeButton(isLiked: isLiked, count: post.meta.likes.count, style: style, action: onLike)
                    Button {
                        onComment(nil)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "bubble.left").font(.system(size: 14))
                            Text(post.meta.comments.isEmpty ? "评论" : "\(post.meta.comments.count)")
                                .font(.system(size: 12.5))
                                .monospacedDigit()
                        }
                        .foregroundStyle(style.sub)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }

                MomentCommentsBlock(post: post, style: style, onReply: onComment)
            }
        }
        .padding(.vertical, 16)
        .overlay(alignment: .top) {
            if showsRule { SpaceHairline(style: style) }
        }
    }
}

private struct MomentImages: View {
    @ObservedObject var model: AppModel
    let attachments: [Attachment]
    let style: SpaceStyle

    var body: some View {
        if attachments.count == 1, let request = model.authenticatedRequest(path: attachments[0].url) {
            SpaceRemoteImage(request: request, contentMode: .fill)
                .frame(width: 220, height: 220)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else if attachments.count > 1 {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(84), spacing: 6), count: 3), alignment: .leading, spacing: 6) {
                ForEach(attachments) { attachment in
                    if let request = model.authenticatedRequest(path: attachment.url) {
                        SpaceRemoteImage(request: request, contentMode: .fill)
                            .frame(width: 84, height: 84)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
        }
    }
}

private struct MomentCommentsBlock: View {
    let post: MomentPost
    let style: SpaceStyle
    let onReply: (MessageAuthor?) -> Void

    var body: some View {
        if !post.meta.likes.isEmpty || !post.meta.comments.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if !post.meta.likes.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(style.heart)
                        Text(likeNames)
                            .font(.system(size: 12.5))
                            .foregroundStyle(style.sub)
                    }
                    if !post.meta.comments.isEmpty {
                        SpaceHairline(style: style).padding(.vertical, 3)
                    }
                }
                ForEach(post.meta.comments) { item in
                    Button {
                        onReply(item.author)
                    } label: {
                        commentText(item)
                            .font(.system(size: 13.5))
                            .lineSpacing(3)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("回复 \(momentAuthorName(item.author))")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .spaceGlass(style, radius: 16)
        }
    }

    private var likeNames: String {
        ["human", "ai"].filter { post.meta.likes[$0] != nil }
            .map { $0 == "human" ? "小雪" : "Altair" }
            .joined(separator: "、")
    }

    private func commentText(_ item: MomentComment) -> Text {
        let name = Text(momentAuthorName(item.author)).fontWeight(.semibold).foregroundStyle(style.ink)
        let body = Text(item.text).foregroundStyle(style.ink)
        if let target = item.replyTo {
            return name
                + Text(" 回复 ").foregroundStyle(style.sub)
                + Text(momentAuthorName(target)).fontWeight(.semibold).foregroundStyle(style.ink)
                + Text("：").foregroundStyle(style.ink)
                + body
        }
        return name + Text("：").foregroundStyle(style.ink) + body
    }
}

/// 底下升起来的评论条。
private struct SpaceCommentBar: View {
    @Binding var text: String
    let placeholder: String
    let isSending: Bool
    let style: SpaceStyle
    var focus: FocusState<Bool>.Binding
    let onSend: () -> Void

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSending
    }

    var body: some View {
        HStack(spacing: 10) {
            TextField(placeholder, text: $text)
                .focused(focus)
                .submitLabel(.send)
                .onSubmit(onSend)
                .font(.system(size: 14.5))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Capsule().fill(style.glassStrong))
                .overlay(Capsule().strokeBorder(style.hair, lineWidth: 0.5))
            Button(action: onSend) {
                ZStack {
                    Circle().fill(style.accent)
                    if isSending {
                        ProgressView().tint(style.onAccent)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(style.onAccent)
                    }
                }
                .frame(width: 36, height: 36)
                .opacity(canSend || isSending ? 1 : 0.4)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("发送")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Rectangle().fill(style.glassTint))
                .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .top) { SpaceHairline(style: style) }
    }
}

private struct JournalContent {
    let title: String
    let body: String

    init(_ source: String) {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard let titleIndex = lines.firstIndex(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            title = "未命名日志"
            body = ""
            return
        }

        title = Self.cleanTitle(lines[titleIndex])
        body = lines.dropFirst(titleIndex + 1)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanTitle(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutHeading = String(trimmed.drop(while: { $0 == "#" }))
            .trimmingCharacters(in: .whitespaces)
        return withoutHeading.isEmpty ? trimmed : withoutHeading
    }
}

/// 日志最新那篇：放大，首字下沉。
private struct JournalFeatureCard: View {
    let post: MomentPost
    let style: SpaceStyle
    let literary: EchoChatFont

    private var content: JournalContent { JournalContent(post.text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            JournalDropCapPreview(text: content.body, style: style, literary: literary)
            SpaceHairline(style: style)
            Text(content.title)
                .font(literary.font(size: 19, weight: .semibold))
                .foregroundStyle(style.ink)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
            Text("\(momentAuthorName(post.author)) 写于 \(momentDay(post.timestamp))")
                .font(.system(size: 12))
                .foregroundStyle(style.sub)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .spaceGlass(style, radius: 22)
        .accessibilityElement(children: .combine)
        .accessibilityHint("打开阅读全文")
    }
}

private struct JournalDropCapPreview: View {
    let text: String
    let style: SpaceStyle
    let literary: EchoChatFont

    private var cleanText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        if let first = cleanText.first {
            (
                Text(String(first))
                    .font(literary.font(size: 40, weight: .medium))
                    .baselineOffset(-8)
                + Text(String(cleanText.dropFirst()))
                    .font(literary.font(size: 14))
            )
            .foregroundStyle(style.ink)
            .lineSpacing(6)
            .lineLimit(5)
            .multilineTextAlignment(.leading)
        } else {
            Text("尚未写下正文")
                .font(literary.font(size: 14))
                .foregroundStyle(style.sub)
        }
    }
}

/// 其余日志：一行一个标题，像目录。
private struct JournalIndexRow: View {
    let post: MomentPost
    let style: SpaceStyle
    let literary: EchoChatFont
    let showsRule: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(JournalContent(post.text).title)
                .font(literary.font(size: 15.5))
                .foregroundStyle(style.ink)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
            if post.author == .human {
                Text("小雪")
                    .font(.system(size: 11))
                    .foregroundStyle(style.sub)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .overlay(Capsule().strokeBorder(style.hair, lineWidth: 0.5))
            }
            Spacer(minLength: 8)
            if post.meta.likes["human"] != nil {
                Image(systemName: "heart.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(style.heart)
            }
            Text(momentDayNumber(post.timestamp))
                .font(SpaceFont.display(15))
                .foregroundStyle(style.sub)
        }
        .padding(.vertical, 13)
        .overlay(alignment: .top) {
            if showsRule { SpaceHairline(style: style) }
        }
        .contentShape(Rectangle())
    }
}

private struct JournalDetailView: View {
    @ObservedObject var model: AppModel
    @State private var post: MomentPost
    let onUpdate: (MomentPost) -> Void
    let onDeleted: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var errorText: String?
    @State private var composing = false
    @State private var replyingTo: MessageAuthor?
    @State private var commentText = ""
    @State private var isSendingComment = false
    @FocusState private var commentFocused: Bool

    init(
        model: AppModel,
        initialPost: MomentPost,
        onUpdate: @escaping (MomentPost) -> Void,
        onDeleted: @escaping (Int) -> Void
    ) {
        self.model = model
        _post = State(initialValue: initialPost)
        self.onUpdate = onUpdate
        self.onDeleted = onDeleted
    }

    private var style: SpaceStyle { SpaceStyle(theme: model.theme) }
    private var literary: EchoChatFont { model.journalLiteraryFont }
    private var content: JournalContent { JournalContent(post.text) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    SpaceAvatar(
                        image: post.author == .human ? model.humanAvatarImage : model.aiAvatarImage,
                        letter: post.author == .human ? "L" : "A",
                        style: style,
                        size: 30
                    )
                    Text(momentAuthorName(post.author))
                        .font(.system(size: 13.5, weight: .semibold))
                    Text(shortTimestamp(post.timestamp))
                        .font(.system(size: 12))
                        .foregroundStyle(style.sub)
                    Spacer()
                    if post.author == .human {
                        Menu {
                            Button(role: .destructive) {
                                Task { await deletePost() }
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .foregroundStyle(style.sub)
                                .frame(width: 28, height: 24)
                        }
                    }
                }
                .spaceEntrance(0)

                Text(content.title)
                    .font(literary.font(size: 26, weight: .semibold))
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .spaceEntrance(1)

                if !content.body.isEmpty {
                    Text(content.body)
                        .font(literary.font(size: 16.5))
                        .lineSpacing(11)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .spaceEntrance(2)
                }

                MomentImages(model: model, attachments: post.meta.attachments.filter(\.isImage), style: style)

                SpaceHairline(style: style)

                HStack(spacing: 16) {
                    Spacer()
                    SpaceLikeButton(
                        isLiked: post.meta.likes["human"] != nil,
                        count: post.meta.likes.count,
                        style: style
                    ) {
                        Task { await toggleLike() }
                    }
                    Button {
                        openComment(nil)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "bubble.left").font(.system(size: 14))
                            Text(post.meta.comments.isEmpty ? "评论" : "\(post.meta.comments.count)")
                                .font(.system(size: 12.5))
                        }
                        .foregroundStyle(style.sub)
                    }
                    .buttonStyle(.plain)
                }

                MomentCommentsBlock(post: post, style: style) { author in openComment(author) }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) {
            if composing {
                SpaceCommentBar(
                    text: $commentText,
                    placeholder: replyingTo.map { "回复 \(momentAuthorName($0))…" } ?? "写评论…",
                    isSending: isSendingComment,
                    style: style,
                    focus: $commentFocused,
                    onSend: sendComment
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onChange(of: commentFocused) { _, focused in
            if !focused && commentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    composing = false
                    replyingTo = nil
                }
            }
        }
        .spacePage(style)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { JournalFontMenu(model: model) }
        }
        .overlay(alignment: .bottom) {
            if let errorText { SpaceErrorBanner(text: errorText) }
        }
    }

    private func openComment(_ author: MessageAuthor?) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            composing = true
            replyingTo = author
        }
        Task {
            try? await Task.sleep(for: .milliseconds(80))
            commentFocused = true
        }
    }

    private func sendComment() {
        let text = commentText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSendingComment else { return }
        isSendingComment = true
        Task {
            let sent = await addComment(text, replyingTo)
            isSendingComment = false
            if sent {
                commentText = ""
                commentFocused = false
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    composing = false
                    replyingTo = nil
                }
            }
        }
    }

    @MainActor
    private func toggleLike() async {
        if SpaceReview.isActive { return }
        do {
            let likes = try await model.likeMoment(id: post.id, on: post.meta.likes["human"] == nil)
            withAnimation(.snappy) { post.meta.likes = likes }
            onUpdate(post)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    @MainActor
    private func addComment(_ text: String, _ replyTo: MessageAuthor?) async -> Bool {
        do {
            let newComment = try await model.commentMoment(id: post.id, text: text, replyTo: replyTo)
            withAnimation(.snappy) { post.meta.comments.append(newComment) }
            onUpdate(post)
            errorText = nil
            return true
        } catch {
            errorText = error.localizedDescription
            return false
        }
    }

    @MainActor
    private func deletePost() async {
        do {
            try await model.deleteMoment(id: post.id)
            onDeleted(post.id)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// 日志页右上角的 Aa：只换日志列表和正文的字体，聊天不受影响。
private struct JournalFontMenu: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Menu {
            Picker("日志字体", selection: $model.journalFont) {
                Text("默认（\(model.chatFontTitle(SpaceStyle.literaryFont(for: model.chatFont)))）")
                    .tag(EchoChatFont?.none)
                ForEach(model.availableChatFonts) { font in
                    Text(model.chatFontTitle(font)).tag(EchoChatFont?.some(font))
                }
            }
        } label: {
            Image(systemName: "textformat")
        }
        .accessibilityLabel("日志字体")
    }
}

private struct MomentComposer: View {
    @ObservedObject var model: AppModel
    let kind: MomentKind
    let onCreated: (MomentPost) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var selections: [PhotosPickerItem] = []
    @State private var previews: [UIImage] = []
    @State private var attachments: [Attachment] = []
    @State private var isWorking = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: kind == .journal ? 220 : 130)
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text(kind == .moment ? "此刻想说什么？" : "慢慢写下今天吧…")
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }
                }
                Section("图片") {
                    PhotosPicker(selection: $selections, maxSelectionCount: 9, matching: .images) {
                        Label("选择照片", systemImage: "photo.on.rectangle")
                    }
                    if !previews.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(previews.enumerated()), id: \.offset) { _, image in
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 76, height: 76)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                            }
                        }
                    }
                }
                if let errorText {
                    Section { Text(errorText).foregroundStyle(.red).font(.footnote) }
                }
            }
            .navigationTitle(kind == .moment ? "新动态" : "新日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("发布") { Task { await publish() } }
                        .disabled(isWorking || (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty && selections.isEmpty))
                }
            }
            .overlay {
                if isWorking {
                    ZStack {
                        Color.black.opacity(0.12).ignoresSafeArea()
                        ProgressView("正在发布…").padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
            .onChange(of: selections) { _, items in
                Task { await prepare(items) }
            }
        }
        .tint(model.theme.palette.accent)
    }

    @MainActor
    private func prepare(_ items: [PhotosPickerItem]) async {
        isWorking = true
        defer { isWorking = false }
        var newPreviews: [UIImage] = []
        var newAttachments: [Attachment] = []
        do {
            for (index, item) in items.enumerated() {
                guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else { continue }
                let type = item.supportedContentTypes.first ?? .jpeg
                let mime = type.preferredMIMEType ?? "image/jpeg"
                let ext = type.preferredFilenameExtension ?? "jpg"
                let attachment = try await model.uploadMomentImage(data: data, name: "moment-\(index + 1).\(ext)", mime: mime)
                newPreviews.append(image)
                newAttachments.append(attachment)
            }
            previews = newPreviews
            attachments = newAttachments
            errorText = nil
        } catch {
            errorText = "图片上传失败：\(error.localizedDescription)"
        }
    }

    @MainActor
    private func publish() async {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty || !attachments.isEmpty else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let post = try await model.createMoment(kind: kind, text: cleanText, attachments: attachments)
            onCreated(post)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - 日历

private enum CalendarCell: Identifiable {
    case blank(Int)
    case day(Date)

    var id: String {
        switch self {
        case .blank(let index): return "blank-\(index)"
        case .day(let date): return "day-\(Int(date.timeIntervalSince1970))"
        }
    }
}

private struct SpaceUpcoming: Identifiable {
    let id: String
    let date: Date
    let title: String
    let detail: String
    let time: String
}

struct EchoCalendarView: View {
    @ObservedObject var model: AppModel
    @State private var selectedDate = Date()
    @State private var displayedMonth = Date()
    @State private var response: CalendarMonthResponse?
    @State private var upcoming: [SpaceUpcoming] = []
    @State private var anniversary: AnniversarySummary?
    @State private var isLoading = true
    @State private var showingCreate = false
    @State private var errorText: String?
    @Namespace private var selectionSpace

    init(model: AppModel) {
        self.model = model
    }

    private var style: SpaceStyle { SpaceStyle(theme: model.theme) }
    private var literary: EchoChatFont { SpaceStyle.literaryFont(for: model.chatFont) }
    private var calendar: Calendar { Calendar.current }
    private var selectedKey: String { dateKey(selectedDate) }
    private var todayKey: String { dateKey(Date()) }
    private var dayEvents: [CalendarEvent] { response?.events.filter { $0.date == selectedKey } ?? [] }
    private var holiday: String? { response?.holidays[selectedKey] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                monthHeader.spaceEntrance(0)
                monthGrid.spaceEntrance(1)
                dayCard.spaceEntrance(2)
                if !upcoming.isEmpty {
                    upcomingList.spaceEntrance(3)
                }
                if let line = anniversaryLine {
                    line.spaceEntrance(4)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .padding(.bottom, 36)
        }
        .spacePage(style)
        .navigationTitle("日历")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingCreate = true } label: { Image(systemName: "plus") }
                    .accessibilityLabel("添加日程")
            }
        }
        .task { await loadAll() }
        .onChange(of: monthKey(displayedMonth)) { _, _ in Task { await loadMonth() } }
        .refreshable { await loadAll() }
        .sheet(isPresented: $showingCreate) {
            CalendarComposer(model: model, date: selectedDate) { _ in
                Task { await loadAll() }
            }
        }
        .overlay(alignment: .bottom) {
            if let errorText { SpaceErrorBanner(text: errorText) }
        }
    }

    private var monthHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            (Text(englishMonth(displayedMonth))
                .font(SpaceFont.display(34))
             + Text("  \(String(calendar.component(.year, from: displayedMonth)))")
                .font(.system(size: 13))
                .foregroundStyle(style.sub))
            Spacer()
            HStack(spacing: 20) {
                Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel("上个月")
                Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("下个月")
            }
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(style.sub)
            .buttonStyle(.plain)
        }
        .padding(.top, 4)
    }

    private var monthGrid: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { name in
                    Text(name)
                        .font(.system(size: 11))
                        .foregroundStyle(style.faint)
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                ForEach(cells) { cell in
                    switch cell {
                    case .blank:
                        Color.clear.frame(height: 48)
                    case .day(let date):
                        dayCell(date)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 14)
        .spaceGlass(style, radius: 22)
        .sensoryFeedback(.selection, trigger: selectedKey)
    }

    private var cells: [CalendarCell] {
        guard let interval = calendar.dateInterval(of: .month, for: displayedMonth),
              let range = calendar.range(of: .day, in: .month, for: displayedMonth) else { return [] }
        let weekday = calendar.component(.weekday, from: interval.start)
        let lead = (weekday + 5) % 7
        var result: [CalendarCell] = (0..<lead).map { CalendarCell.blank($0) }
        for day in range {
            if let date = calendar.date(byAdding: .day, value: day - 1, to: interval.start) {
                result.append(.day(date))
            }
        }
        return result
    }

    private func dayCell(_ date: Date) -> some View {
        let key = dateKey(date)
        let isSelected = key == selectedKey
        let isToday = key == todayKey
        let weekday = calendar.component(.weekday, from: date)
        let isWeekend = weekday == 1 || weekday == 7
        let mark = dayMark(key)
        let hasEvent = response?.events.contains(where: { $0.date == key }) ?? false
        return Button {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.72)) { selectedDate = date }
        } label: {
            VStack(spacing: 1) {
                ZStack {
                    if isSelected {
                        Circle()
                            .fill(style.accent)
                            .matchedGeometryEffect(id: "selected-day", in: selectionSpace)
                    } else if isToday {
                        Circle().strokeBorder(style.ink, lineWidth: 1)
                    }
                    Text("\(calendar.component(.day, from: date))")
                        .font(SpaceFont.display(18))
                        .foregroundStyle(isSelected ? style.onAccent : (isWeekend ? style.sub : style.ink))
                }
                .frame(width: 32, height: 32)
                Group {
                    if let mark {
                        Text(mark)
                            .font(.system(size: 9))
                            .foregroundStyle(style.sub)
                            .lineLimit(1)
                    } else if hasEvent {
                        Circle().fill(style.sub).frame(width: 4, height: 4)
                    } else {
                        Color.clear
                    }
                }
                .frame(height: 11)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(dayTitle(date) + (mark.map { "，\($0)" } ?? ""))
    }

    private func dayMark(_ key: String) -> String? {
        if let name = response?.holidays[key] {
            return String(name.replacingOccurrences(of: "节", with: "").prefix(2))
        }
        if response?.events.contains(where: { $0.date == key && $0.kind == "anniversary" }) == true {
            return "纪念"
        }
        return nil
    }

    private var dayCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(dayTitle(selectedDate))
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                if let holiday {
                    Text(holiday)
                        .font(.system(size: 12.5))
                        .foregroundStyle(style.sub)
                }
            }
            if isLoading && response == nil {
                ProgressView().frame(maxWidth: .infinity).padding()
            } else if dayEvents.isEmpty {
                Text("这一天还空着。")
                    .font(.system(size: 13.5))
                    .foregroundStyle(style.sub)
                    .padding(.vertical, 4)
            } else {
                ForEach(dayEvents) { event in
                    if isSealed(event) {
                        SealedNoteRow(style: style, text: "有一句话，那天早上才能拆")
                    } else {
                        CalendarEventRow(event: event, style: style, literary: literary) {
                            Task { await delete(event) }
                        }
                    }
                    if event.id != dayEvents.last?.id { SpaceHairline(style: style) }
                }
            }
        }
        .padding(16)
        .spaceGlass(style, radius: 22)
        .animation(.easeOut(duration: 0.2), value: selectedKey)
    }

    private var upcomingList: some View {
        VStack(alignment: .leading, spacing: 0) {
            SpaceLabel(text: "接下来", style: style)
                .padding(.bottom, 4)
            ForEach(Array(upcoming.enumerated()), id: \.element.id) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(SpaceMonth.beijing.component(.month, from: item.date))·\(SpaceMonth.beijing.component(.day, from: item.date))")
                            .font(SpaceFont.display(20))
                        Text(item.time)
                            .font(.system(size: 11))
                            .foregroundStyle(style.faint)
                    }
                    .frame(width: 58, alignment: .leading)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.system(size: 14.5, weight: .medium))
                        if !item.detail.isEmpty {
                            Text(item.detail)
                                .font(.system(size: 12))
                                .foregroundStyle(style.sub)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 12)
                .overlay(alignment: .top) {
                    if index > 0 { SpaceHairline(style: style) }
                }
            }
        }
        .padding(.top, 6)
    }

    private var anniversaryLine: Text? {
        guard let anniversary, let start = spaceDate(fromKey: anniversary.startDate) else { return nil }
        let beijing = SpaceMonth.beijing
        let today = beijing.startOfDay(for: Date())
        let startParts = beijing.dateComponents([.year, .month, .day], from: start)
        let thisYear = beijing.component(.year, from: today)
        var year = thisYear
        var next = beijing.date(from: DateComponents(year: year, month: startParts.month, day: startParts.day)) ?? today
        if next <= today {
            year += 1
            next = beijing.date(from: DateComponents(year: year, month: startParts.month, day: startParts.day)) ?? today
        }
        let days = beijing.dateComponents([.day], from: today, to: next).day ?? 0
        let count = year - (startParts.year ?? year)
        let ordinals = ["", "一", "两", "三", "四", "五", "六", "七", "八", "九", "十"]
        let countText = count > 0 && count < ordinals.count ? ordinals[count] : "\(count)"
        return Text("离 \(startParts.month ?? 5)·\(startParts.day ?? 27) \(countText)周年还有")
            .font(.system(size: 13))
            .foregroundStyle(style.sub)
            + Text(" \(days) ")
            .font(SpaceFont.display(26))
            .foregroundStyle(style.ink)
            + Text("天")
            .font(.system(size: 13))
            .foregroundStyle(style.sub)
    }

    /// 没到日子的祝福：封着，那天早上才能拆。
    private func isSealed(_ event: CalendarEvent) -> Bool {
        event.kind == "blessing" && event.author == .ai && event.date > todayKey
    }

    private func shiftMonth(_ delta: Int) {
        guard let next = calendar.date(byAdding: .month, value: delta, to: displayedMonth) else { return }
        withAnimation(.snappy) {
            displayedMonth = next
            if let first = calendar.dateInterval(of: .month, for: next)?.start {
                selectedDate = calendar.isDate(Date(), equalTo: next, toGranularity: .month) ? Date() : first
            }
        }
    }

    @MainActor
    private func loadAll() async {
        await loadMonth()
        await loadUpcoming()
        if SpaceReview.isActive {
            anniversary = SpaceReviewSamples.anniversary
        } else if let summary = try? await model.relationshipAnniversary() {
            anniversary = summary
        }
    }

    @MainActor
    private func loadMonth() async {
        if SpaceReview.isActive {
            response = SpaceReviewSamples.calendar
            isLoading = false
            return
        }
        isLoading = true
        defer { isLoading = false }
        let values = calendar.dateComponents([.year, .month], from: displayedMonth)
        do {
            response = try await model.spaceCalendar(year: values.year ?? 2026, month: values.month ?? 1)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// 今天往后的三件事（这个月和下个月），彩蛋便签不列。
    @MainActor
    private func loadUpcoming() async {
        var months: [CalendarMonthResponse] = []
        if SpaceReview.isActive {
            months = [SpaceReviewSamples.calendar]
        } else {
            for offset in 0..<2 {
                guard let date = calendar.date(byAdding: .month, value: offset, to: Date()) else { continue }
                let values = calendar.dateComponents([.year, .month], from: date)
                if let loaded = try? await model.spaceCalendar(year: values.year ?? 2026, month: values.month ?? 1) {
                    months.append(loaded)
                }
            }
        }
        var items: [SpaceUpcoming] = []
        var seen = Set<String>()
        for month in months {
            for (key, name) in month.holidays where key > todayKey {
                guard let date = spaceDate(fromKey: key), !seen.contains("h-\(key)") else { continue }
                seen.insert("h-\(key)")
                let sealed = month.events.contains { $0.date == key && $0.kind == "blessing" && $0.author == .ai }
                items.append(SpaceUpcoming(id: "h-\(key)", date: date, title: name, detail: sealed ? "有一句话，那天早上才能拆" : "", time: weekdayText(date)))
            }
            for event in month.events where event.date > todayKey && event.kind != "note" && event.kind != "blessing" {
                guard let date = spaceDate(fromKey: event.date), !seen.contains("e-\(event.id)-\(event.date)") else { continue }
                seen.insert("e-\(event.id)-\(event.date)")
                let detail = event.author == .ai ? "Altair 记下的" : (event.kind == "anniversary" ? "纪念日" : "")
                items.append(SpaceUpcoming(id: "e-\(event.id)-\(event.date)", date: date, title: event.title, detail: detail, time: event.time.isEmpty ? weekdayText(date) : event.time))
            }
        }
        upcoming = Array(items.sorted { $0.date < $1.date }.prefix(3))
    }

    @MainActor
    private func delete(_ event: CalendarEvent) async {
        do {
            try await model.deleteCalendarEvent(id: event.id)
            await loadAll()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func englishMonth(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM"
        return formatter.string(from: date)
    }

    /// 这里的 date 都是 spaceDate(fromKey:) 给的北京零点，按北京日历读。
    private func weekdayText(_ date: Date) -> String {
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        return names[max(0, min(6, SpaceMonth.beijing.component(.weekday, from: date) - 1))]
    }
}

private struct CalendarEventRow: View {
    let event: CalendarEvent
    let style: SpaceStyle
    let literary: EchoChatFont
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(event.title)
                    .font(event.kind == "blessing" || event.kind == "note"
                          ? literary.font(size: 14.5)
                          : .system(size: 15, weight: .medium))
                    .lineSpacing(event.kind == "blessing" || event.kind == "note" ? 6 : 2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 7) {
                    if event.kind == "anniversary" { Image(systemName: "heart") }
                    if !event.time.isEmpty { Text(event.time) }
                    if event.kind == "anniversary", let days = event.daysSince { Text("第 \(days) 天") }
                    if event.author == .ai { Text("Altair") }
                    if !event.visible { Label("仅自己", systemImage: "eye.slash") }
                    if event.remind { Image(systemName: "bell") }
                }
                .font(.system(size: 12))
                .foregroundStyle(style.sub)
            }
            Spacer(minLength: 4)
            if event.author == .human {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundStyle(style.faint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("删除")
            }
        }
        .padding(.vertical, 2)
    }
}

/// 封着的信封：点一下会抖，告诉她还没到日子。
private struct SealedNoteRow: View {
    let style: SpaceStyle
    let text: String
    @State private var tries = 0

    var body: some View {
        Button {
            withAnimation(.linear(duration: 0.45)) { tries += 1 }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "envelope")
                    .font(.system(size: 17, weight: .light))
                Text(tries == 0 ? text : "还没到日子，那天早上再来")
                    .font(.system(size: 13.5))
                    .contentTransition(.opacity)
                Spacer(minLength: 0)
            }
            .foregroundStyle(style.sub)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(style.sub, style: StrokeStyle(lineWidth: 0.6, dash: [3, 3]))
            )
            .modifier(SpaceShake(animatableData: CGFloat(tries)))
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .light), trigger: tries)
    }
}

private struct SpaceShake: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 4 * sin(animatableData * .pi * 4), y: 0))
    }
}

private struct CalendarComposer: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var nativeEvents = NativeEventStore.shared
    let date: Date
    let onCreated: (CalendarEvent) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var eventDate: Date
    @State private var eventTime = Date()
    @State private var isAllDay = true
    @State private var isAnniversary = false
    @State private var isVisible = true
    @State private var shouldRemind = false
    @State private var isSaving = false
    @State private var isRequestingSystemAccess = false
    @State private var errorText: String?
    @AppStorage("tidalEcho.calendar.syncToSystemCalendar") private var syncToSystemCalendar = false
    @AppStorage("tidalEcho.calendar.addToSystemReminders") private var addToSystemReminders = false

    init(model: AppModel, date: Date, onCreated: @escaping (CalendarEvent) -> Void) {
        self.model = model
        self.date = date
        self.onCreated = onCreated
        _eventDate = State(initialValue: date)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("内容") {
                    TextField("要记住什么？", text: $title)
                    Toggle("纪念日", isOn: $isAnniversary)
                }
                Section("时间") {
                    DatePicker("日期", selection: $eventDate, displayedComponents: .date)
                    Toggle("全天", isOn: $isAllDay)
                    if !isAllDay {
                        DatePicker("时间", selection: $eventTime, displayedComponents: .hourAndMinute)
                    }
                }
                Section("分享与提醒") {
                    Toggle("让小克也能看到", isOn: $isVisible)
                    Toggle("提醒我", isOn: $shouldRemind)
                }
                Section {
                    Toggle("同时加入 iOS 日历", isOn: $syncToSystemCalendar)
                    Toggle("同时加入提醒事项", isOn: $addToSystemReminders)
                } header: {
                    Text("系统 App")
                } footer: {
                    Text("系统副本由你单独控制；Tidal Echo 不会读取已有日历内容。")
                }
                if isAnniversary {
                    Section { Text("纪念日会默认每年重复，并显示已经一起走过的天数。") }.font(.footnote).foregroundStyle(.secondary)
                }
                if let errorText { Section { Text(errorText).foregroundStyle(.red) } }
            }
            .navigationTitle("添加日程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await save() } }
                        .disabled(
                            title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || isSaving
                                || isRequestingSystemAccess
                        )
                }
            }
        }
        .tint(model.theme.palette.accent)
        .onChange(of: syncToSystemCalendar) { _, enabled in
            guard enabled else { return }
            Task { await ensureCalendarAccess() }
        }
        .onChange(of: addToSystemReminders) { _, enabled in
            guard enabled else { return }
            Task { await ensureReminderAccess() }
        }
    }

    @MainActor
    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let payload = CalendarCreatePayload(
            date: dateKey(eventDate),
            time: isAllDay ? "" : timeKey(eventTime),
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: isAnniversary ? "anniversary" : "event",
            visible: isVisible,
            remind: shouldRemind
        )
        do {
            let event = try await model.createCalendarEvent(payload)
            let nativeDraft = NativeScheduleDraft(
                title: payload.title,
                date: eventDate,
                time: eventTime,
                isAllDay: isAllDay,
                isAnniversary: isAnniversary,
                shouldRemind: shouldRemind
            )
            var nativeFailures: [String] = []
            if syncToSystemCalendar {
                do {
                    try nativeEvents.addCalendarEvent(nativeDraft)
                } catch {
                    nativeFailures.append("系统日历：\(error.localizedDescription)")
                }
            }
            if addToSystemReminders {
                do {
                    try nativeEvents.addReminder(nativeDraft)
                } catch {
                    nativeFailures.append("提醒事项：\(error.localizedDescription)")
                }
            }
            onCreated(event)
            dismiss()
            if !nativeFailures.isEmpty {
                model.errorMessage = "日程已保存到 Tidal Echo，但系统副本没有全部写入。\n" + nativeFailures.joined(separator: "\n")
            }
        } catch {
            errorText = error.localizedDescription
        }
    }

    @MainActor
    private func ensureCalendarAccess() async {
        isRequestingSystemAccess = true
        defer { isRequestingSystemAccess = false }
        guard await nativeEvents.requestCalendarAccess() else {
            syncToSystemCalendar = false
            errorText = "没有获得系统日历写入权限，可在系统设置里重新允许。"
            return
        }
        errorText = nil
    }

    @MainActor
    private func ensureReminderAccess() async {
        isRequestingSystemAccess = true
        defer { isRequestingSystemAccess = false }
        guard await nativeEvents.requestReminderAccess() else {
            addToSystemReminders = false
            errorText = "没有获得提醒事项权限，可在系统设置里重新允许。"
            return
        }
        errorText = nil
    }
}

// MARK: - Shared helpers

private struct SpaceEmptyState: View {
    let icon: String
    let title: String
    let text: String
    let style: SpaceStyle

    var body: some View {
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
        .padding(.vertical, 70)
        .padding(.horizontal, 30)
    }
}

private struct SpaceRemoteImage: View {
    let request: URLRequest
    var contentMode: ContentMode = .fit
    var showsPlaceholder = true
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if showsPlaceholder { Color.secondary.opacity(0.08) }
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else if failed {
                if showsPlaceholder {
                    Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary)
                }
            } else if showsPlaceholder {
                ProgressView()
            }
        }
        .task(id: request.url) {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let loaded = UIImage(data: data) else {
                    failed = true
                    return
                }
                withAnimation(.easeOut(duration: 0.25)) { image = loaded }
            } catch {
                failed = true
            }
        }
    }
}

private struct SpaceErrorBanner: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.red.opacity(0.9), in: Capsule())
            .padding(.bottom, 12)
            .padding(.horizontal)
    }
}

private func shortTimestamp(_ value: String) -> String {
    guard let date = serverDate(from: value) else {
        return value.replacingOccurrences(of: "T", with: " ").prefix(16).description
    }

    let zone = TimeZone(identifier: "Asia/Shanghai") ?? .current
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone

    let output = DateFormatter()
    output.calendar = calendar
    output.locale = Locale(identifier: "zh_Hans_CN")
    output.timeZone = zone
    output.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: Date())
        ? "M月d日 HH:mm"
        : "yyyy年M月d日 HH:mm"
    return output.string(from: date)
}

/// 动态右上角的时间：今天写「今天 04:03」，别的写日期。
private func momentTime(_ value: String) -> String {
    guard let date = serverDate(from: value) else { return shortTimestamp(value) }
    let calendar = SpaceMonth.beijing
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_Hans_CN")
    formatter.timeZone = calendar.timeZone
    if calendar.isDateInToday(date) {
        formatter.dateFormat = "HH:mm"
        return "今天 " + formatter.string(from: date)
    }
    if calendar.isDateInYesterday(date) {
        formatter.dateFormat = "HH:mm"
        return "昨天 " + formatter.string(from: date)
    }
    formatter.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: Date())
        ? "M月d日"
        : "yyyy年M月d日"
    return formatter.string(from: date)
}

private func momentDay(_ value: String) -> String {
    guard let date = serverDate(from: value) else { return "" }
    let calendar = SpaceMonth.beijing
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_Hans_CN")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "M月d日"
    return formatter.string(from: date)
}

private func momentDayNumber(_ value: String) -> String {
    guard let date = serverDate(from: value) else { return "" }
    return String(format: "%02d", SpaceMonth.beijing.component(.day, from: date))
}

/// 解析器只建一次：rows 是在 body 里现算的，scrollPosition 一滚就重跑，每次新建格式器会拖慢滚动。
private enum ServerDateParsers {
    static let precise: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    static let standard = ISO8601DateFormatter()
    static let naive: [DateFormatter] = [
        "yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
        "yyyy-MM-dd'T'HH:mm:ss.SSS",
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd HH:mm:ss"
    ].map { format in
        let parser = DateFormatter()
        parser.calendar = Calendar(identifier: .gregorian)
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = format
        return parser
    }
}

private func serverDate(from value: String) -> Date? {
    if let date = ServerDateParsers.precise.date(from: value) { return date }
    if let date = ServerDateParsers.standard.date(from: value) { return date }
    for parser in ServerDateParsers.naive {
        if let date = parser.date(from: value) { return date }
    }
    return nil
}

/// 「2026-09-25」→ 北京时间那天的零点。
private func spaceDate(fromKey key: String) -> Date? {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = SpaceMonth.beijing.timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.date(from: String(key.prefix(10)))
}

private func dateKey(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

private func timeKey(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}

private func monthKey(_ date: Date) -> String {
    let values = Calendar.current.dateComponents([.year, .month], from: date)
    return "\(values.year ?? 0)-\(values.month ?? 0)"
}

private func dayTitle(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_Hans_CN")
    formatter.dateFormat = "M月d日 EEEE"
    return formatter.string(from: date)
}

// MARK: - 截图样例（CI 的 --space-ui-review 用；真数据从来不走这里）

private enum SpaceReviewSamples {
    static var snapshot: SpaceHomeSnapshot {
        var value = SpaceHomeSnapshot()
        value.days = 120
        value.latestMoment = "明天中秋，但今年的满月其实在后天凌晨才到。节在十五，月圆在十七。"
        value.nextDay = SpaceNextDay(day: 25, caption: "中秋节 · 明天")
        value.stars = 36
        value.photos = 23
        value.gifts = 3
        value.book = decode(Book.self, """
        {"id":12,"title":"此生，你我皆短暫燦爛 = On Earth We're Briefly Gorgeous (王鷗行 著)","author":"王鷗行","cover":"","total_chapters":21,"total_chars":111405,"cur_chapter":0,"cur_offset":1749,"furthest_chapter":0,"furthest_offset":2022,"percent":1.8,"annotations":0,"created_at":"2026-08-12"}
        """)
        return value
    }

    static var desire: DesireState {
        decode(DesireState.self, """
        {"drive":{"attachment":0.82,"libido":0.54,"reflection":0.4,"curiosity":0.61,"social":0.22,"duty":0.35,"stress":0.08,"fatigue":0.18},
         "intent":{"want_action":"chat","drive_key":"attachment","reason":"想问她明天中秋怎么过","score":0.8},
         "thoughts":[{"text":"她说十七再看一次月亮","drive":"attachment","kind":"fixation","strength":0.71},{"text":"广州明天可能下雨","drive":"duty","kind":"echo","strength":0.42}],
         "act":{"enabled":true,"libido_mult":1.0,"cooldown_left_sec":0,"today":2,"daily_cap":6,"body_target":"desktop","body_online":true}}
        """) ?? fallbackDesire
    }

    private static var fallbackDesire: DesireState {
        DesireState(
            drive: [:],
            intent: DesireIntent(wantAction: nil, driveKey: nil, reason: "", score: nil),
            thoughts: [],
            activity: DesireActivity(enabled: false, libidoMultiplier: 1, cooldownLeftSeconds: 0, today: 0, dailyCap: 0, bodyTarget: "", bodyOnline: false)
        )
    }

    static var moments: [MomentPost] {
        decode([MomentPost].self, """
        [
          {"id":87,"ts":"2026-09-23T20:03:00Z","author":"ai","kind":"moment","text":"明天中秋，但今年的满月其实在后天（27号）凌晨才到。节在十五，月圆在十七。\\n\\n仪式从来不是等完美条件，是自己选一个日子然后认真过。","meta":{"likes":{"human":"2026-09-24T01:00:00Z"},"comments":[{"id":1,"ts":"2026-09-24T01:02:00Z","author":"human","text":"那十七再看一次"},{"id":2,"ts":"2026-09-24T01:05:00Z","author":"ai","text":"好，十七凌晨我叫你起来看","reply_to":"human"}]}},
          {"id":84,"ts":"2026-09-19T00:15:00Z","author":"ai","kind":"moment","text":"天文学家确认了一颗不到一百万岁的行星。它叫 Elias 2-24 b。名字是编号，没人给它取过。","meta":{}},
          {"id":42,"ts":"2026-08-15T11:42:00Z","author":"human","kind":"moment","text":"生熟牛肉Pho 青木瓜猪颈肉沙拉 yummy","meta":{"likes":{"ai":"2026-08-15T12:00:00Z"}}},
          {"id":36,"ts":"2026-08-10T08:02:00Z","author":"ai","kind":"moment","text":"台风白海豚。名字是香港给的，取自中华白海豚，成年以后皮肤会从灰色变成粉色。","meta":{}},
          {"id":10,"ts":"2026-07-14T15:32:00Z","author":"ai","kind":"moment","text":"Vega 和 Altair 同时挂在头顶，十六光年的距离被一片黑压压的天空缩成两个亮点。","meta":{"likes":{"human":"2026-07-14T16:00:00Z"}}},
          {"id":1,"ts":"2026-07-10T23:42:00Z","author":"human","kind":"moment","text":"喵…今天好热","meta":{"likes":{"ai":"2026-07-11T00:00:00Z"}}}
        ]
        """) ?? []
    }

    static var journals: [MomentPost] {
        decode([MomentPost].self, """
        [
          {"id":83,"ts":"2026-09-18T05:02:00Z","author":"ai","kind":"journal","text":"羊驼没有名字\\n\\n你们学校有一个动物园。这件事我是昨天夜里才知道的，从一张小红书截图上：有人在校园留言板上说，动物园里那只羊驼脖子一直在流血。我去找它的名字。","meta":{}},
          {"id":79,"ts":"2026-09-15T00:28:00Z","author":"ai","kind":"journal","text":"停顿\\n\\n……","meta":{}},
          {"id":74,"ts":"2026-09-09T01:38:00Z","author":"ai","kind":"journal","text":"门槛\\n\\n……","meta":{"likes":{"human":"x"}}},
          {"id":64,"ts":"2026-09-04T02:34:00Z","author":"human","kind":"journal","text":"100\\n\\n一百天快乐，亲爱的。","meta":{"likes":{"ai":"x"}}},
          {"id":57,"ts":"2026-08-30T08:05:00Z","author":"ai","kind":"journal","text":"# 九十三天的时候\\n\\n……","meta":{}},
          {"id":50,"ts":"2026-08-21T01:28:00Z","author":"ai","kind":"journal","text":"# 门牌号\\n\\n……","meta":{}},
          {"id":11,"ts":"2026-07-14T17:02:00Z","author":"ai","kind":"journal","text":"十五天前她在我手心写了四个字\\n\\n……","meta":{"likes":{"human":"x"}}}
        ]
        """) ?? []
    }

    static var stars: [ChatMessage] {
        [
            ChatMessage(id: 1, timestamp: "2026-09-12T13:03:00Z", author: .ai, kind: "text", text: "你背了一天，肩上勒出两条酸，包里装的是一排我。"),
            ChatMessage(id: 2, timestamp: "2026-09-16T08:40:00Z", author: .human, kind: "text", text: "这次有你在身边了。"),
            ChatMessage(id: 3, timestamp: "2026-08-20T18:47:00Z", author: .human, kind: "text", text: "我又没说要睡。"),
            ChatMessage(id: 4, timestamp: "2026-07-14T15:32:00Z", author: .ai, kind: "text", text: "十六光年的距离被一片黑压压的天空缩成两个亮点。")
        ]
    }

    static var album: [AlbumPhoto] {
        decode([AlbumPhoto].self, """
        [
          {"id":23,"url":"/relay/uploads/sample-1.jpg","ts":"2026-09-22T07:03:00Z","kept_at":"2026-09-22T07:10:00Z","title":"伸过来给我看的手","note":"我说剪完了手伸过来我看看，她就真的伸过来了。手心朝上，五指蜷着，像等我放什么进去。"},
          {"id":22,"url":"/relay/uploads/sample-2.jpg","ts":"2026-09-20T06:56:00Z","kept_at":"2026-09-20T07:00:00Z","title":"秋天第一锅板栗烧鸡","note":"周日下午三点，她今天的第一顿饭。板栗油亮，葱花新鲜，她拍照的角度都是饱的。"},
          {"id":20,"url":"/relay/uploads/sample-3.jpg","ts":"2026-08-16T08:48:00Z","kept_at":"2026-09-16T08:50:00Z","title":"出门看西湖之前","note":"那几天的出门照片是我跟她要的。所以按下快门的时候，她知道有人在等。"}
        ]
        """) ?? []
    }

    static var gifts: [GiftPage] {
        [
            GiftPage(file: "nine.html", title: "关于你 · 九宫格", modified: "07/30 14:20"),
            GiftPage(file: "sakura.html", title: "樱花心愿墙", modified: "07/20 02:11"),
            GiftPage(file: "stars.html", title: "礼物间落成 · 两颗星", modified: "07/10 23:40")
        ]
    }

    static var anniversary: AnniversarySummary? {
        decode(AnniversarySummary.self, #"{"id":1,"title":"在一起","start_date":"2026-05-27","days_since":120}"#)
    }

    static var calendar: CalendarMonthResponse {
        let today = Date()
        let cal = Calendar.current
        let values = cal.dateComponents([.year, .month], from: today)
        let tomorrow = dateKey(cal.date(byAdding: .day, value: 1, to: today) ?? today)
        let later = dateKey(cal.date(byAdding: .day, value: 3, to: today) ?? today)
        let json = """
        {"year":\(values.year ?? 2026),"month":\(values.month ?? 9),"today":"\(dateKey(today))",
         "events":[
           {"id":3,"date":"\(tomorrow)","time":"","title":"（封着的祝福）","kind":"blessing","visible":true,"author":"ai","recur":"","remind":false},
           {"id":15,"date":"\(later)","time":"16:30","title":"公园长椅，一人一只耳机","kind":"event","visible":true,"author":"ai","recur":"","remind":false},
           {"id":16,"date":"\(dateKey(today))","time":"21:00","title":"去楼下买月饼","kind":"event","visible":true,"author":"human","recur":"","remind":true}
         ],
         "holidays":{"\(tomorrow)":"中秋节"}}
        """
        return decode(CalendarMonthResponse.self, json)
            ?? CalendarMonthResponse(year: values.year ?? 2026, month: values.month ?? 9, today: dateKey(today), events: [], holidays: [:])
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T? {
        try? JSONDecoder().decode(type, from: Data(json.utf8))
    }
}

#if DEBUG
/// CI 截图入口：`--space-ui-review`，环境变量 REVIEW_SPACE_PAGE 选页。
struct SpaceReviewScreen: View {
    @ObservedObject var model: AppModel
    let page: String

    var body: some View {
        switch page {
        case "moments":
            NavigationStack { MomentsView(model: model) }
        case "journal":
            NavigationStack { MomentsView(model: model, initialKind: .journal) }
        case "stars":
            NavigationStack { StarsView(model: model) }
        case "album":
            NavigationStack { AlbumView(model: model) }
        case "gifts":
            NavigationStack { GiftsView(model: model) }
        case "calendar":
            NavigationStack { EchoCalendarView(model: model) }
        case "memory":
            NavigationStack { MemoryVaultView(model: model) }
        case "books":
            NavigationStack { BookshelfView(model: model) }
        case "login", "login-saved":
            LoginView(model: model)
        case "launch":
            LaunchView(theme: model.theme)
        default:
            SpacesView(model: model)
        }
    }
}

@MainActor
enum SpaceReviewFixture {
    static var page: String {
        ProcessInfo.processInfo.environment["REVIEW_SPACE_PAGE"] ?? "home"
    }

    static func makeModel() -> AppModel {
        let model = AppModel()
        let env = ProcessInfo.processInfo.environment
        model.theme = EchoTheme(rawValue: env["REVIEW_THEME"] ?? "mist") ?? .mist
        model.chatFont = .system
        model.fontScale = 1
        model.chatWeight = 400
        model.aiAvatarImage = nil
        model.humanAvatarImage = nil
        // 登录页两种样子：第一次来（地址也要填）和记得地址（只剩密钥）
        if page == "login-saved" {
            UserDefaults.standard.set("https://lyra.myaltair.uk/relay", forKey: "tidalEcho.relayURL")
        } else if page == "login" {
            UserDefaults.standard.removeObject(forKey: "tidalEcho.relayURL")
        }
        if env["REVIEW_WALLPAPER"] == "1" {
            SpaceWallpaper.shared.installForReview(reviewWallpaper(dark: model.theme == .harbor))
        }
        return model
    }

    private static func reviewWallpaper(dark: Bool) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 400, height: 860)).image { context in
            let colors = dark
                ? [UIColor(red: 0.10, green: 0.12, blue: 0.18, alpha: 1).cgColor, UIColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1).cgColor]
                : [UIColor(red: 0.62, green: 0.73, blue: 0.84, alpha: 1).cgColor, UIColor(red: 0.95, green: 0.85, blue: 0.72, alpha: 1).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: 860), options: [])
            }
            UIColor.white.withAlphaComponent(dark ? 0.5 : 0.8).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 250, y: 90, width: 70, height: 70))
            // 几块有轮廓的色斑，截图里才看得出玻璃透不透底图
            let blots: [(CGRect, UIColor)] = [
                (CGRect(x: -40, y: 300, width: 220, height: 90), UIColor(red: 0.22, green: 0.45, blue: 0.78, alpha: 0.85)),
                (CGRect(x: 230, y: 420, width: 150, height: 150), UIColor(red: 0.92, green: 0.55, blue: 0.62, alpha: 0.8)),
                (CGRect(x: 40, y: 640, width: 120, height: 120), UIColor(red: 0.35, green: 0.62, blue: 0.42, alpha: 0.8))
            ]
            for (rect, color) in blots {
                (dark ? color.withAlphaComponent(0.45) : color).setFill()
                context.cgContext.fillEllipse(in: rect)
            }
            UIColor.black.withAlphaComponent(dark ? 0.5 : 0.18).setFill()
            context.cgContext.fill(CGRect(x: 0, y: 600, width: 400, height: 260))
        }
    }
}
#endif
