import SwiftUI
import AppKit
import EventKit
import UserNotifications
import Security
import ServiceManagement

struct Coordinate: Codable {
    var lat: Double
    var lon: Double
}

@MainActor final class DailyModel: ObservableObject {
    static let shared = DailyModel()
    @Published var temperature: Double?
    @Published var weatherDescription = "조회 전"
    @Published var tripMinutes: Int?
    @Published var tripName = "출근"
    @Published var routeUpdated: Date?
    @Published var weatherUpdated: Date?
    @Published var errorMessage = ""
    @Published var events: [EKEvent] = []
    @Published var panelVisible = true

    @AppStorage("homeLat") var homeLat = ""
    @AppStorage("homeLon") var homeLon = ""
    @AppStorage("workLat") var workLat = ""
    @AppStorage("workLon") var workLon = ""
    @AppStorage("weatherLat") var weatherLat = "37.5665"
    @AppStorage("weatherLon") var weatherLon = "126.9780"
    @AppStorage("departureHour") var departureHour = 14
    @AppStorage("alertThreshold") var alertThreshold = 45
    @AppStorage("notificationsOn") var notificationsOn = true
    @AppStorage("openAtLogin") var openAtLogin = false
    @AppStorage("calendarFilter") var calendarFilter = "" // optional calendar title
    private let eventStore = EKEventStore()
    private var refreshing = false
    private var lastTrafficAlert: Date = .distantPast
    private var notifiedEventIDs: Set<String> = []

    private init() {}
    var activeTripIsReturn: Bool { Calendar.current.component(.hour, from: Date()) >= departureHour }
    var weatherSymbol: String {
        switch weatherDescription {
        case "맑음": return "sun.max.fill"
        case "흐림", "구름": return "cloud.fill"
        case "비": return "cloud.rain.fill"
        case "눈": return "cloud.snow.fill"
        default: return "cloud.sun.fill"
        }
    }
    var menuLabel: String { "\(temperature.map { "\(Int($0.rounded()))°" } ?? "--°") · \(tripMinutes.map { "\($0)분" } ?? "--분")" }
    var eta: Date? { tripMinutes.map { Date().addingTimeInterval(TimeInterval($0 * 60)) } }

    func startup() async {
        await requestCalendarPermission()
        if notificationsOn {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
        await refresh()
    }
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        async let weatherResult: Void = loadWeather()
        async let routeResult: Void = loadRoute()
        await weatherResult
        await routeResult
        loadEvents()
        checkEventAlerts()
    }
    private func loadWeather() async {
        guard let lat = Double(weatherLat), let lon = Double(weatherLon), (-90...90).contains(lat), (-180...180).contains(lon) else { return }
        guard var parts = URLComponents(string: "https://api.open-meteo.com/v1/forecast") else { return }
        parts.queryItems = [URLQueryItem(name: "latitude", value: String(lat)), URLQueryItem(name: "longitude", value: String(lon)), URLQueryItem(name: "current", value: "temperature_2m,weather_code"), URLQueryItem(name: "timezone", value: "Asia/Seoul")]
        guard let url = parts.url else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let value = try JSONDecoder().decode(WeatherResponse.self, from: data)
            temperature = value.current.temperature_2m
            weatherDescription = Self.weatherText(value.current.weather_code)
            weatherUpdated = Date()
        } catch { errorMessage = "날씨 조회 실패: \(error.localizedDescription)" }
    }
    private static func weatherText(_ code: Int) -> String {
        switch code {
        case 0: return "맑음"
        case 1...3: return "구름"
        case 45, 48: return "흐림"
        case 51...67, 80...82, 95...99: return "비"
        case 71...77, 85, 86: return "눈"
        default: return "흐림"
        }
    }
    private func loadRoute() async {
        tripName = activeTripIsReturn ? "퇴근 · 회사 → 집" : "출근 · 집 → 회사"
        guard let home = location(lat: homeLat, lon: homeLon), let work = location(lat: workLat, lon: workLon) else {
            tripMinutes = nil
            errorMessage = "설정에서 집과 회사 좌표를 입력하세요."
            return
        }
        guard let key = Keychain.get("tmap-key"), !key.isEmpty else {
            tripMinutes = nil
            errorMessage = "설정에서 TMAP API 키를 저장하세요."
            return
        }
        let start = activeTripIsReturn ? work : home
        let end = activeTripIsReturn ? home : work
        guard let url = URL(string: "https://apis.openapi.sk.com/tmap/routes?version=1") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "appKey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        let body: [String: Any] = ["startX": String(start.lon), "startY": String(start.lat), "endX": String(end.lon), "endY": String(end.lat), "reqCoordType": "WGS84GEO", "resCoordType": "WGS84GEO", "searchOption": "0", "trafficInfo": "Y"]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let status = (response as? HTTPURLResponse)?.statusCode, (200...299).contains(status) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw NSError(domain: "TMAP", code: status, userInfo: [NSLocalizedDescriptionKey: "TMAP HTTP \(status). API 키/이용권/좌표를 확인하세요."])
            }
            let route = try JSONDecoder().decode(TMapResponse.self, from: data)
            guard let seconds = route.features.compactMap({ $0.properties?.totalTime }).first, seconds > 0 else {
                throw NSError(domain: "TMAP", code: 0, userInfo: [NSLocalizedDescriptionKey: "TMAP 응답에 totalTime이 없습니다."])
            }
            tripMinutes = Int(ceil(Double(seconds) / 60))
            routeUpdated = Date()
            errorMessage = ""
            if notificationsOn && tripMinutes! >= alertThreshold && Date().timeIntervalSince(lastTrafficAlert) > 3600 {
                lastTrafficAlert = Date()
                sendNotification(title: "출퇴근 지연", body: "\(tripName) 예상시간이 \(tripMinutes!)분입니다.")
            }
        } catch {
            errorMessage = "경로 조회 실패: \(error.localizedDescription)"
            // Clear stale value rather than presenting a previous route as live.
            tripMinutes = nil
        }
    }
    private func location(lat: String, lon: String) -> Coordinate? {
        guard let a = Double(lat), let b = Double(lon), (-90...90).contains(a), (-180...180).contains(b) else { return nil }
        return Coordinate(lat: a, lon: b)
    }
    private func requestCalendarPermission() async {
        if #available(macOS 14.0, *) {
            _ = try? await eventStore.requestFullAccessToEvents()
        } else {
            _ = await withCheckedContinuation { continuation in
                eventStore.requestAccess(to: .event) { granted, _ in continuation.resume(returning: granted) }
            }
        }
    }
    private func loadEvents() {
        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        var calendars = eventStore.calendars(for: .event)
        if !calendarFilter.trimmingCharacters(in: .whitespaces).isEmpty {
            calendars = calendars.filter { $0.title.localizedCaseInsensitiveContains(calendarFilter) }
        }
        let predicate = eventStore.predicateForEvents(withStart: Calendar.current.startOfDay(for: now), end: end, calendars: calendars)
        events = eventStore.events(matching: predicate).filter { !$0.isAllDay && $0.endDate > now }.sorted { $0.startDate < $1.startDate }.prefix(3).map { $0 }
    }
    private func checkEventAlerts() {
        guard notificationsOn else { return }
        for event in events {
            let until = event.startDate.timeIntervalSinceNow
            guard (0...600).contains(until), let id = event.eventIdentifier, !notifiedEventIDs.contains(id) else { continue }
            notifiedEventIDs.insert(id)
            sendNotification(title: "곧 시작하는 일정", body: "\(event.title ?? "일정") · \(event.startDate.formatted(date: .omitted, time: .shortened))")
        }
    }
    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title; content.body = body; content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
    func configureLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            openAtLogin = enabled
        } catch { errorMessage = "로그인 항목 설정 실패: \(error.localizedDescription)" }
    }
}

private struct WeatherResponse: Decodable { let current: WeatherCurrent }
private struct WeatherCurrent: Decodable { let temperature_2m: Double; let weather_code: Int }
private struct TMapResponse: Decodable { let features: [RouteFeature] }
private struct RouteFeature: Decodable { let properties: RouteProperties? }
private struct RouteProperties: Decodable { let totalTime: Int? }

enum Keychain {
    static let service = "com.sodalab.SODADaily"
    static func set(_ value: String, for key: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
    static func get(_ key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

struct DailyCard: View {
    @ObservedObject var model: DailyModel
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 18) {
            HStack {
                Text("SODA DAILY").font(.system(size: 11, weight: .bold, design: .rounded)).tracking(2).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "circle.grid.2x2.fill").foregroundStyle(Color(red: 0.22, green: 0.73, blue: 0.65))
            }
            Divider()
            HStack(alignment: .center) {
                Image(systemName: model.weatherSymbol).font(.system(size: 32)).foregroundStyle(.orange)
                VStack(alignment: .leading) {
                    Text(model.temperature.map { "\(Int($0.rounded()))°C" } ?? "--°C").font(.system(size: 32, weight: .semibold, design: .rounded))
                    Text(model.weatherDescription).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("날씨").font(.caption2).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Label(model.tripName, systemImage: "car.side.fill").font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline) {
                    Text(model.tripMinutes.map { "\($0)분" } ?? "--분").font(.system(size: 31, weight: .semibold, design: .rounded))
                    Spacer()
                    if let eta = model.eta { Text("예상 도착 \(eta.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(.secondary) }
                }
                Text(model.routeUpdated.map { "조회: \($0.formatted(date: .omitted, time: .shortened))" } ?? "TMAP 설정 필요").font(.caption2).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 9) {
                Label("오늘 일정", systemImage: "calendar").font(.caption).foregroundStyle(.secondary)
                if model.events.isEmpty { Text("표시할 일정이 없습니다").font(.callout).foregroundStyle(.secondary) }
                ForEach(model.events, id: \.eventIdentifier) { event in
                    HStack(alignment: .top, spacing: 10) {
                        Text(event.startDate.formatted(date: .omitted, time: .shortened)).font(.caption).monospacedDigit().frame(width: 65, alignment: .leading).foregroundStyle(.secondary)
                        Text(event.title ?? "일정").font(.callout).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
            }
            if !model.errorMessage.isEmpty { Text(model.errorMessage).font(.caption2).foregroundStyle(.orange).lineLimit(3) }
            HStack {
                Text(Date().formatted(date: .abbreviated, time: .omitted)).font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("새로 고침")
            }
        }
        .padding(20)
        .frame(width: compact ? 320 : 355)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.15)))
    }
}

final class FloatingPanel: NSPanel {
    init(model: DailyModel) {
        let rect = NSRect(x: 0, y: 0, width: 355, height: 460)
        super.init(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.isFloatingPanel = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isMovableByWindowBackground = true
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
        let hosting = NSHostingView(rootView: DailyCard(model: model))
        self.contentView = hosting
        // Fit the window to the card so the transparent area around it doesn't swallow clicks.
        setContentSize(hosting.fittingSize)
        if let visible = NSScreen.main?.visibleFrame {
            setFrameTopLeftPoint(NSPoint(x: visible.maxX - frame.width - 20, y: visible.maxY - 20))
        } else { center() }
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor final class PanelController: ObservableObject {
    static let shared = PanelController()
    private var panel: FloatingPanel?
    func show() {
        if panel == nil { panel = FloatingPanel(model: .shared) }
        panel?.orderFrontRegardless()
        DailyModel.shared.panelVisible = true
    }
    func hide() { panel?.orderOut(nil); DailyModel.shared.panelVisible = false }
    func toggle() { DailyModel.shared.panelVisible ? hide() : show() }
}

struct SettingsView: View {
    @ObservedObject var model = DailyModel.shared
    @State private var apiKey = ""
    var body: some View {
        Form {
            Section("TMAP API") {
                SecureField("발급한 appKey", text: $apiKey)
                Button("API 키 Keychain에 저장") { Keychain.set(apiKey, for: "tmap-key"); apiKey = "" }
            }
            Section("집 좌표 (WGS84)") {
                TextField("위도 (예: 37.5)", text: $model.homeLat)
                TextField("경도 (예: 126.9)", text: $model.homeLon)
            }
            Section("회사 좌표 (WGS84)") {
                TextField("위도", text: $model.workLat)
                TextField("경도", text: $model.workLon)
            }
            Section("날씨 위치") {
                TextField("위도", text: $model.weatherLat)
                TextField("경도", text: $model.weatherLon)
            }
            Section("동작") {
                Stepper("\(model.departureHour)시부터 퇴근 경로 표시", value: $model.departureHour, in: 0...23)
                Toggle("알림 켜기", isOn: $model.notificationsOn)
                Stepper("경로 \(model.alertThreshold)분 이상이면 알림", value: $model.alertThreshold, in: 10...180, step: 5)
                TextField("캘린더 이름 포함 필터 (비우면 전체)", text: $model.calendarFilter)
                Toggle("로그인 시 자동 실행", isOn: Binding(get: { model.openAtLogin }, set: { model.configureLogin($0) }))
            }
            HStack {
                Button("지금 새로고침") { Task { await model.refresh() } }
                Button("패널 표시/숨김") { PanelController.shared.toggle() }
            }
            Text("Google 일정은 macOS 시스템 설정 > 인터넷 계정에서 Google 계정의 캘린더 동기화를 켜면 읽을 수 있습니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(minWidth: 470, minHeight: 610)
    }
}

// LSUIElement apps never become active on their own, so the Settings window would open behind other apps.
struct OpenSettingsButton: View {
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Button("설정...") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
    }
}

@main struct SODADailyApp: App {
    @StateObject private var model = DailyModel.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        MenuBarExtra {
            DailyCard(model: model, compact: true)
            Divider()
            Button(model.panelVisible ? "바탕화면 패널 숨기기" : "바탕화면 패널 표시") { PanelController.shared.toggle() }
            OpenSettingsButton()
            Button("종료") { NSApplication.shared.terminate(nil) }
        } label: {
            Label(model.menuLabel, systemImage: "car.side")
        }
        .menuBarExtraStyle(.window)
        Settings { SettingsView() }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var timer: Timer?
    func applicationDidFinishLaunching(_ notification: Notification) {
        PanelController.shared.show()
        Task { await DailyModel.shared.startup() }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in await DailyModel.shared.refresh() }
        }
    }
    func applicationWillTerminate(_ notification: Notification) { timer?.invalidate() }
}
