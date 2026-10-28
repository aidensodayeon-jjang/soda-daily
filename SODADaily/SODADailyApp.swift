import SwiftUI
import AppKit
import EventKit
import UserNotifications
import Security
import ServiceManagement
import MapKit

struct Coordinate: Codable {
    var lat: Double
    var lon: Double
}

struct SavedPlace: Identifiable, Codable, Equatable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var address: String
    var lat: Double
    var lon: Double
}

struct SearchCandidate: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let lat: Double
    let lon: Double
}

@MainActor final class DailyModel: ObservableObject {
    static let shared = DailyModel()
    @Published var temperature: Double?
    @Published var weatherDescription = "조회 전"
    @Published var todayMinTemp: Double?
    @Published var todayMaxTemp: Double?
    @Published var tomorrowMinTemp: Double?
    @Published var tomorrowMaxTemp: Double?
    @Published var tomorrowWeatherDescription = "조회 전"
    @Published var tripMinutes: Int?
    @Published var tripName = "경로"
    @Published var routeUpdated: Date?
    @Published var weatherUpdated: Date?
    @Published var errorMessage = ""
    @Published var events: [EKEvent] = []
    @Published var tomorrowEvents: [EKEvent] = []
    @Published var upcomingEvents: [EKEvent] = []
    @Published var selectedDayTab: Int = 0 // 0: 오늘, 1: 내일
    @Published var calendarNames: [String] = []
    @Published var hasGoogleCalendar = false
    @Published var calendarAuthorized = false
    @Published var panelVisible = true

    @Published var places: [SavedPlace] = [] {
        didSet { savePlaces() }
    }
    @AppStorage("startPlaceID") var startPlaceID = ""
    @AppStorage("endPlaceID") var endPlaceID = ""
    @AppStorage("autoSwapByTime") var autoSwapByTime = false
    @AppStorage("autoRefreshEnabled") var autoRefreshEnabled = true

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
    @AppStorage("calendarFilter") var calendarFilter = ""

    private let eventStore = EKEventStore()
    private var refreshing = false
    private var lastTrafficAlert: Date = .distantPast
    private var notifiedEventIDs: Set<String> = []

    private init() {
        loadPlaces()
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: eventStore, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.loadEvents()
            }
        }
    }

    private func loadPlaces() {
        if let data = UserDefaults.standard.data(forKey: "savedPlaces_v1"),
           let decoded = try? JSONDecoder().decode([SavedPlace].self, from: data),
           !decoded.isEmpty {
            places = decoded
        } else {
            var migrated: [SavedPlace] = []
            if let hLat = Double(homeLat), let hLon = Double(homeLon) {
                migrated.append(SavedPlace(name: "집", address: "\(hLat), \(hLon)", lat: hLat, lon: hLon))
            }
            if let wLat = Double(workLat), let wLon = Double(workLon) {
                migrated.append(SavedPlace(name: "회사", address: "\(wLat), \(wLon)", lat: wLat, lon: wLon))
            }
            places = migrated
        }
        ensureValidSelection()
    }

    private func savePlaces() {
        if let data = try? JSONEncoder().encode(places) {
            UserDefaults.standard.set(data, forKey: "savedPlaces_v1")
        }
        ensureValidSelection()
    }

    func ensureValidSelection() {
        guard !places.isEmpty else {
            startPlaceID = ""
            endPlaceID = ""
            return
        }
        if !places.contains(where: { $0.id == startPlaceID }) {
            startPlaceID = places.first?.id ?? ""
        }
        if !places.contains(where: { $0.id == endPlaceID }) || (places.count > 1 && endPlaceID == startPlaceID) {
            endPlaceID = places.first(where: { $0.id != startPlaceID })?.id ?? places.first?.id ?? ""
        }
    }

    func addPlace(name: String, address: String, lat: Double, lon: Double) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "장소 \(places.count + 1)" : name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let idx = places.firstIndex(where: { $0.name == cleanName }) {
            places[idx].address = address
            places[idx].lat = lat
            places[idx].lon = lon
        } else {
            let newPlace = SavedPlace(name: cleanName, address: address, lat: lat, lon: lon)
            places.append(newPlace)
        }
        if places.count == 1 {
            weatherLat = String(format: "%.6f", lat)
            weatherLon = String(format: "%.6f", lon)
        }
        ensureValidSelection()
        Task { await refresh() }
    }

    func removePlace(id: String) {
        places.removeAll { $0.id == id }
        ensureValidSelection()
        Task { await refresh() }
    }

    func swapStartAndEnd() {
        let tmp = startPlaceID
        startPlaceID = endPlaceID
        endPlaceID = tmp
        Task { await refresh() }
    }

    var currentStartPlace: SavedPlace? {
        places.first(where: { $0.id == startPlaceID }) ?? places.first
    }

    var currentEndPlace: SavedPlace? {
        places.first(where: { $0.id == endPlaceID }) ?? (places.count > 1 ? places[1] : places.first)
    }

    var weatherSymbol: String {
        Self.symbol(for: weatherDescription)
    }
    var tomorrowWeatherSymbol: String {
        Self.symbol(for: tomorrowWeatherDescription)
    }
    private static func symbol(for desc: String) -> String {
        switch desc {
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
        let lat = currentStartPlace?.lat ?? Double(weatherLat) ?? 37.5665
        let lon = currentStartPlace?.lon ?? Double(weatherLon) ?? 126.9780
        guard (-90...90).contains(lat), (-180...180).contains(lon) else { return }
        guard var parts = URLComponents(string: "https://api.open-meteo.com/v1/forecast") else { return }
        parts.queryItems = [
            URLQueryItem(name: "latitude", value: String(lat)),
            URLQueryItem(name: "longitude", value: String(lon)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "forecast_days", value: "2"),
            URLQueryItem(name: "timezone", value: "Asia/Seoul")
        ]
        guard let url = parts.url else { return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let value = try JSONDecoder().decode(WeatherResponse.self, from: data)
            temperature = value.current.temperature_2m
            weatherDescription = Self.weatherText(value.current.weather_code)
            if let daily = value.daily {
                if let mins = daily.temperature_2m_min, mins.count >= 1 { todayMinTemp = mins[0] }
                if let maxs = daily.temperature_2m_max, maxs.count >= 1 { todayMaxTemp = maxs[0] }
                if let mins = daily.temperature_2m_min, mins.count >= 2 { tomorrowMinTemp = mins[1] }
                if let maxs = daily.temperature_2m_max, maxs.count >= 2 { tomorrowMaxTemp = maxs[1] }
                if let codes = daily.weather_code, codes.count >= 2 {
                    tomorrowWeatherDescription = Self.weatherText(codes[1])
                }
            }
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
        guard places.count >= 2, let rawStart = currentStartPlace, let rawEnd = currentEndPlace else {
            tripName = "출발지 → 도착지"
            tripMinutes = nil
            errorMessage = "설정에서 장소(최소 2곳: 예 집, 회사 등)를 추가하세요."
            return
        }
        let shouldReverse = autoSwapByTime && Calendar.current.component(.hour, from: Date()) >= departureHour
        let start = shouldReverse ? rawEnd : rawStart
        let end = shouldReverse ? rawStart : rawEnd
        tripName = "\(start.name) → \(end.name)"

        guard let key = Keychain.get("tmap-key"), !key.isEmpty else {
            tripMinutes = nil
            errorMessage = "설정에서 TMAP API 키를 저장하세요."
            return
        }
        guard let url = URL(string: "https://apis.openapi.sk.com/tmap/routes?version=1") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "appKey")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        let body: [String: Any] = [
            "startX": String(start.lon),
            "startY": String(start.lat),
            "endX": String(end.lon),
            "endY": String(end.lat),
            "reqCoordType": "WGS84GEO",
            "resCoordType": "WGS84GEO",
            "searchOption": "0",
            "trafficInfo": "Y"
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let status = (response as? HTTPURLResponse)?.statusCode, (200...299).contains(status) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw NSError(domain: "TMAP", code: status, userInfo: [NSLocalizedDescriptionKey: "TMAP HTTP \(status). API 키/이용권을 확인하세요."])
            }
            let route = try JSONDecoder().decode(TMapResponse.self, from: data)
            guard let seconds = route.features.compactMap({ $0.properties?.totalTime }).first, seconds > 0 else {
                throw NSError(domain: "TMAP", code: 0, userInfo: [NSLocalizedDescriptionKey: "TMAP 응답에 소요시간 정보가 없습니다."])
            }
            tripMinutes = Int(ceil(Double(seconds) / 60))
            routeUpdated = Date()
            errorMessage = ""
            if notificationsOn && tripMinutes! >= alertThreshold && Date().timeIntervalSince(lastTrafficAlert) > 3600 {
                lastTrafficAlert = Date()
                sendNotification(title: "경로 정체 알림", body: "\(tripName) 예상시간이 \(tripMinutes!)분입니다.")
            }
        } catch {
            errorMessage = "경로 조회 실패: \(error.localizedDescription)"
            tripMinutes = nil
        }
    }

    private func requestCalendarPermission() async {
        let granted: Bool
        if #available(macOS 14.0, *) {
            granted = (try? await eventStore.requestFullAccessToEvents()) ?? false
        } else {
            granted = await withCheckedContinuation { continuation in
                eventStore.requestAccess(to: .event) { ok, _ in continuation.resume(returning: ok) }
            }
        }
        calendarAuthorized = granted
        eventStore.reset()
    }
    func loadEvents() {
        let status = EKEventStore.authorizationStatus(for: .event)
        if #available(macOS 14.0, *) {
            calendarAuthorized = (status == .fullAccess)
        } else {
            calendarAuthorized = (status == .authorized)
        }
        eventStore.refreshSourcesIfNecessary()
        let now = Date()
        let startOfToday = Calendar.current.startOfDay(for: now)
        let endOfToday = Calendar.current.date(byAdding: .day, value: 1, to: startOfToday)!
        let allCalendars = eventStore.calendars(for: .event)
        calendarNames = allCalendars.map { "\($0.title) (\($0.source.title))" }
        hasGoogleCalendar = allCalendars.contains {
            $0.source.title.localizedCaseInsensitiveContains("google") ||
            $0.source.title.localizedCaseInsensitiveContains("gmail") ||
            $0.title.localizedCaseInsensitiveContains("@") ||
            $0.source.sourceType == .calDAV
        }
        var calendars = allCalendars
        if !calendarFilter.trimmingCharacters(in: .whitespaces).isEmpty {
            calendars = calendars.filter {
                $0.title.localizedCaseInsensitiveContains(calendarFilter) ||
                $0.source.title.localizedCaseInsensitiveContains(calendarFilter)
            }
        }
        guard !calendars.isEmpty else {
            events = []
            tomorrowEvents = []
            upcomingEvents = []
            return
        }
        let predicate = eventStore.predicateForEvents(withStart: startOfToday, end: endOfToday, calendars: calendars)
        events = eventStore.events(matching: predicate)
            .sorted {
                if $0.isAllDay != $1.isAllDay { return $0.isAllDay && !$1.isAllDay }
                return $0.startDate < $1.startDate
            }
            .prefix(6)
            .map { $0 }

        let endOfTomorrow = Calendar.current.date(byAdding: .day, value: 1, to: endOfToday)!
        let tomorrowPredicate = eventStore.predicateForEvents(withStart: endOfToday, end: endOfTomorrow, calendars: calendars)
        tomorrowEvents = eventStore.events(matching: tomorrowPredicate)
            .sorted {
                if $0.isAllDay != $1.isAllDay { return $0.isAllDay && !$1.isAllDay }
                return $0.startDate < $1.startDate
            }
            .prefix(6)
            .map { $0 }

        let nextWeek = Calendar.current.date(byAdding: .day, value: 7, to: endOfToday)!
        let upcomingPredicate = eventStore.predicateForEvents(withStart: endOfToday, end: nextWeek, calendars: calendars)
        upcomingEvents = eventStore.events(matching: upcomingPredicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(3)
            .map { $0 }
    }
    func openInternetAccounts() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
    func openCalendarApp() {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        }
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

private struct WeatherResponse: Decodable {
    let current: WeatherCurrent
    let daily: WeatherDaily?
}
private struct WeatherCurrent: Decodable { let temperature_2m: Double; let weather_code: Int }
private struct WeatherDaily: Decodable {
    let weather_code: [Int]?
    let temperature_2m_max: [Double]?
    let temperature_2m_min: [Double]?
}
private struct TMapResponse: Decodable { let features: [RouteFeature] }
private struct RouteFeature: Decodable { let properties: RouteProperties? }
private struct RouteProperties: Decodable { let totalTime: Int? }

private struct TMapPOIResponse: Decodable {
    let searchPoiInfo: SearchPoiInfo?
    struct SearchPoiInfo: Decodable {
        let pois: Pois?
    }
    struct Pois: Decodable {
        let poi: [Poi]?
    }
    struct Poi: Decodable {
        let name: String?
        let upperAddrName: String?
        let middleAddrName: String?
        let lowerAddrName: String?
        let roadName: String?
        let firstBuildNo: String?
        let frontLat: String?
        let frontLon: String?
        let noorLat: String?
        let noorLon: String?
    }
}

private struct NominatimItem: Decodable {
    let display_name: String
    let lat: String
    let lon: String
}

enum Keychain {
    static func set(_ value: String, for key: String) {
        UserDefaults.standard.set(value, forKey: "store_\(key)")
    }
    static func get(_ key: String) -> String? {
        UserDefaults.standard.string(forKey: "store_\(key)")
    }
}

// AppKit native text field that forces window activation and first responder on click
final class ClickFocusingNSTextField: NSTextField {
    override func mouseDown(with event: NSEvent) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        self.window?.makeKeyAndOrderFront(nil)
        self.window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}

struct NativeTextField: NSViewRepresentable {
    var placeholder: String
    @Binding var text: String
    var onSubmit: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ClickFocusingNSTextField {
        let tf = ClickFocusingNSTextField()
        tf.placeholderString = placeholder
        tf.stringValue = text
        tf.isEditable = true
        tf.isSelectable = true
        tf.bezelStyle = .roundedBezel
        tf.font = .systemFont(ofSize: 13)
        tf.delegate = context.coordinator
        tf.lineBreakMode = .byTruncatingTail
        tf.cell?.isScrollable = true
        tf.cell?.wraps = false
        return tf
    }

    func updateNSView(_ nsView: ClickFocusingNSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.placeholderString = placeholder
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NativeTextField
        init(_ parent: NativeTextField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let tf = obj.object as? NSTextField else { return }
            parent.text = tf.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit?()
                return true
            }
            return false
        }
    }
}

struct DailyCard: View {
    @ObservedObject var model: DailyModel
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            HStack {
                Text("SODA DAILY").font(.system(size: 10, weight: .bold, design: .rounded)).tracking(1.5).foregroundStyle(.secondary)
                Spacer()
                Button {
                    SettingsWindowController.shared.show()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "gearshape.fill")
                        Text("설정")
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Divider()
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("오늘 · \(model.currentStartPlace?.name ?? "날씨")")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    HStack(alignment: .center, spacing: 7) {
                        Image(systemName: model.weatherSymbol)
                            .font(.system(size: 22))
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.temperature.map { "\(Int($0.rounded()))°C" } ?? "--°C")
                                .font(.system(size: 22, weight: .semibold, design: .rounded))
                            if let minT = model.todayMinTemp, let maxT = model.todayMaxTemp {
                                Text("\(model.weatherDescription) \(Int(minT.rounded()))°/\(Int(maxT.rounded()))°")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(model.weatherDescription)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Spacer(minLength: 4)
                Divider()
                    .frame(height: 36)
                Spacer(minLength: 4)
                VStack(alignment: .leading, spacing: 4) {
                    Text("내일 날씨")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    HStack(alignment: .center, spacing: 6) {
                        Image(systemName: model.tomorrowWeatherSymbol)
                            .font(.system(size: 19))
                            .foregroundStyle(.cyan)
                        VStack(alignment: .leading, spacing: 1) {
                            if let minT = model.tomorrowMinTemp, let maxT = model.tomorrowMaxTemp {
                                Text("\(Int(minT.rounded()))° / \(Int(maxT.rounded()))°C")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                            } else {
                                Text("--° / --°C")
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                            }
                            Text(model.tomorrowWeatherDescription)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                if model.places.count >= 2 {
                    HStack(alignment: .center, spacing: 6) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 5) {
                                Text("출발")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color.blue, in: RoundedRectangle(cornerRadius: 4))
                                Menu {
                                    ForEach(model.places) { place in
                                        Button(place.name) {
                                            model.startPlaceID = place.id
                                            if model.endPlaceID == place.id {
                                                model.endPlaceID = model.places.first(where: { $0.id != place.id })?.id ?? place.id
                                            }
                                            Task { await model.refresh() }
                                        }
                                    }
                                } label: {
                                    Text(model.currentStartPlace?.name ?? "선택")
                                        .font(.caption.weight(.semibold))
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                            }

                            HStack(spacing: 5) {
                                Text("도착")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color.teal, in: RoundedRectangle(cornerRadius: 4))
                                Menu {
                                    ForEach(model.places) { place in
                                        Button(place.name) {
                                            model.endPlaceID = place.id
                                            if model.startPlaceID == place.id {
                                                model.startPlaceID = model.places.first(where: { $0.id != place.id })?.id ?? place.id
                                            }
                                            Task { await model.refresh() }
                                        }
                                    }
                                } label: {
                                    Text(model.currentEndPlace?.name ?? "선택")
                                        .font(.caption.weight(.semibold))
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                            }
                        }

                        Spacer()

                        Button {
                            model.swapStartAndEnd()
                        } label: {
                            VStack(spacing: 2) {
                                Image(systemName: "arrow.up.arrow.down")
                                    .font(.system(size: 11, weight: .bold))
                                Text("전환")
                                    .font(.system(size: 9, weight: .medium))
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 5)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                        .help("출발지 ↔ 도착지 바꾸기")
                    }
                } else {
                    Label(model.tripName, systemImage: "car.side.fill").font(.caption).foregroundStyle(.secondary)
                }

                HStack(alignment: .firstTextBaseline) {
                    Text(model.tripMinutes.map { "\($0)분" } ?? "--분").font(.system(size: 26, weight: .semibold, design: .rounded))
                    Spacer()
                    if let eta = model.eta { Text("예상 도착 \(eta.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(.secondary) }
                }
                HStack(alignment: .center, spacing: 6) {
                    Button {
                        model.autoRefreshEnabled.toggle()
                        if model.autoRefreshEnabled {
                            Task { await model.refresh() }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(model.autoRefreshEnabled ? Color.green : Color.secondary.opacity(0.5))
                                .frame(width: 6, height: 6)
                            Text(model.autoRefreshEnabled ? "자동갱신 ON" : "자동갱신 OFF")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(model.autoRefreshEnabled ? .primary : .secondary)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            (model.autoRefreshEnabled ? Color.green.opacity(0.16) : Color.primary.opacity(0.08)),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                    .help("클릭하여 5분마다 자동 갱신 켜기/끄기")

                    if let updated = model.routeUpdated {
                        Text("\(updated.formatted(date: .omitted, time: .shortened)) 기준")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Button("TMAP/장소 설정...") {
                            SettingsWindowController.shared.show()
                        }
                        .font(.caption2)
                        .buttonStyle(.link)
                    }
                    Spacer(minLength: 0)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Button {
                        model.selectedDayTab = 0
                    } label: {
                        Text("오늘 일정 (\(model.events.count))")
                            .font(.system(size: 11, weight: model.selectedDayTab == 0 ? .bold : .medium))
                            .foregroundStyle(model.selectedDayTab == 0 ? .primary : .secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                model.selectedDayTab == 0 ? Color.primary.opacity(0.12) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                    }
                    .buttonStyle(.plain)

                    Button {
                        model.selectedDayTab = 1
                    } label: {
                        Text("내일 일정 (\(model.tomorrowEvents.count))")
                            .font(.system(size: 11, weight: model.selectedDayTab == 1 ? .bold : .medium))
                            .foregroundStyle(model.selectedDayTab == 1 ? .primary : .secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                model.selectedDayTab == 1 ? Color.primary.opacity(0.12) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                    }
                    .buttonStyle(.plain)

                    Spacer()
                }

                let activeEvents = model.selectedDayTab == 0 ? model.events : model.tomorrowEvents

                if !model.calendarAuthorized {
                    Text("캘린더 접근 권한을 허용해 주세요.").font(.caption).foregroundStyle(.orange)
                } else if activeEvents.isEmpty {
                    Text(model.selectedDayTab == 0 ? "오늘 등록된 일정이 없습니다" : "내일 등록된 일정이 없습니다")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if model.selectedDayTab == 0 && !model.hasGoogleCalendar {
                        HStack(spacing: 8) {
                            Button("Google 계정 연동...") { model.openInternetAccounts() }
                                .font(.caption2)
                                .buttonStyle(.link)
                            Button("캘린더 앱 열기") { model.openCalendarApp() }
                                .font(.caption2)
                                .buttonStyle(.link)
                        }
                    }
                }
                ForEach(activeEvents, id: \.eventIdentifier) { event in
                    let isPast = model.selectedDayTab == 0 && !event.isAllDay && event.endDate < Date()
                    HStack(alignment: .top, spacing: 6) {
                        Text(event.isAllDay ? "종일" : event.startDate.formatted(date: .omitted, time: .shortened))
                            .font(.caption2)
                            .monospacedDigit()
                            .frame(width: 52, alignment: .leading)
                            .foregroundStyle(.secondary)
                        Text(event.title ?? "일정")
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(isPast ? .secondary : .primary)
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
        .padding(16)
        .frame(width: compact ? 235 : 248)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            ZStack {
                GlassVisualEffectView(material: .popover, blendingMode: .behindWindow)
                    .opacity(0.68)
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.24),
                        Color.white.opacity(0.08),
                        Color.white.opacity(0.02)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.55),
                            Color.white.opacity(0.22),
                            Color.white.opacity(0.08)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .padding(compact ? 0 : 8)
    }
}

final class MovableVisualEffectView: NSVisualEffectView {
    override var mouseDownCanMoveWindow: Bool { true }
}

struct GlassVisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> MovableVisualEffectView {
        let view = MovableVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: MovableVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
    }
}

final class AutoSizingHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }

    override func layout() {
        super.layout()
        guard let window = self.window else { return }
        let target = self.fittingSize
        guard target.width > 0, target.height > 0 else { return }
        if abs(window.frame.width - target.width) > 1 || abs(window.frame.height - target.height) > 1 {
            let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
            window.setContentSize(target)
            window.setFrameTopLeftPoint(topLeft)
        }
    }
}

final class FloatingPanel: NSPanel {
    private var dragStartMouseLocation: NSPoint?
    private var dragStartWindowOrigin: NSPoint?
    private var isDraggingWindow = false

    init(model: DailyModel) {
        let rect = NSRect(x: 0, y: 0, width: 264, height: 420)
        super.init(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.isFloatingPanel = false
        self.hidesOnDeactivate = false
        self.level = .normal
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isMovable = true
        self.isMovableByWindowBackground = true
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
        let hosting = AutoSizingHostingView(rootView: DailyCard(model: model))
        hosting.sizingOptions = [.intrinsicContentSize]
        self.contentView = hosting
        setContentSize(hosting.fittingSize)
        if let savedX = UserDefaults.standard.object(forKey: "panelOriginX") as? Double,
           let savedY = UserDefaults.standard.object(forKey: "panelOriginY") as? Double {
            setFrameOrigin(NSPoint(x: savedX, y: savedY))
        } else if let visible = NSScreen.main?.visibleFrame {
            setFrameTopLeftPoint(NSPoint(x: visible.maxX - frame.width - 16, y: visible.maxY - 16))
        } else { center() }
    }
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            self.orderFrontRegardless()
            dragStartMouseLocation = NSEvent.mouseLocation
            dragStartWindowOrigin = self.frame.origin
            isDraggingWindow = false
            super.sendEvent(event)
        case .leftMouseDragged:
            if let startMouse = dragStartMouseLocation, let startOrigin = dragStartWindowOrigin {
                let currentMouse = NSEvent.mouseLocation
                let dx = currentMouse.x - startMouse.x
                let dy = currentMouse.y - startMouse.y
                if isDraggingWindow || hypot(dx, dy) > 3 {
                    isDraggingWindow = true
                    let newOrigin = NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy)
                    self.setFrameOrigin(newOrigin)
                    UserDefaults.standard.set(Double(newOrigin.x), forKey: "panelOriginX")
                    UserDefaults.standard.set(Double(newOrigin.y), forKey: "panelOriginY")
                    return
                }
            }
            super.sendEvent(event)
        case .leftMouseUp:
            let wasDragging = isDraggingWindow
            isDraggingWindow = false
            dragStartMouseLocation = nil
            dragStartWindowOrigin = nil
            if wasDragging { return }
            super.sendEvent(event)
        case .rightMouseDown:
            self.orderFrontRegardless()
            super.sendEvent(event)
        default:
            super.sendEvent(event)
        }
    }
    override var canBecomeKey: Bool { false }
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

final class FocusableSettingsWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var window: FocusableSettingsWindow?
    func show() {
        NSApp.setActivationPolicy(.regular)
        setupEditMenuIfNeeded()
        if window == nil {
            let vc = NSHostingController(rootView: SettingsView())
            let w = FocusableSettingsWindow(
                contentRect: NSRect(x: 0, y: 0, width: 580, height: 740),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            w.title = "SODA DAILY 설정"
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentViewController = vc
            w.setContentSize(NSSize(width: 580, height: 740))
            w.center()
            window = w
        }
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
    private func setupEditMenuIfNeeded() {
        guard NSApp.mainMenu == nil else { return }
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "편집")
        editMenu.addItem(withTitle: "실행 취소", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "다시 실행", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "잘라내기", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "복사하기", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "전체 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        NSApp.mainMenu = mainMenu
    }
}

struct SettingsView: View {
    @ObservedObject var model = DailyModel.shared
    @State private var apiKey = Keychain.get("tmap-key") ?? ""
    @State private var hasSavedKey = !(Keychain.get("tmap-key") ?? "").isEmpty
    @State private var keyMessage = ""

    @State private var placeName = "집"
    @State private var searchQuery = ""
    @State private var searchResults: [SearchCandidate] = []
    @State private var isSearching = false
    @State private var searchStatus = ""

    @State private var manualLat = ""
    @State private var manualLon = ""
    @State private var showManualCoords = false

    private let presetNames = ["집", "회사", "헬스장", "본가", "학교", "카페", "약속장소"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // 1. TMAP API Key Section
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("1. TMAP API 키 (appKey)", systemImage: "key.fill")
                            .font(.headline)
                        Spacer()
                        Text(hasSavedKey ? "저장됨 ✓" : "미설정 (입력 필요)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(hasSavedKey ? .green : .orange)
                    }

                    NativeTextField(placeholder: "여기에 TMAP appKey 입력 또는 Cmd+V 붙여넣기", text: $apiKey) {
                        saveKey(apiKey)
                    }
                    .frame(height: 26)

                    HStack(spacing: 8) {
                        Button("입력한 키 저장") {
                            saveKey(apiKey)
                        }
                        .buttonStyle(.borderedProminent)

                        Button("클립보드에서 바로 붙여넣기 + 저장") {
                            if let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !clip.isEmpty {
                                saveKey(clip)
                            } else {
                                keyMessage = "클립보드에 복사된 텍스트가 없습니다."
                            }
                        }

                        Button("SK Open API 키 발급 페이지") {
                            if let url = URL(string: "https://openapi.sk.com/") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                    if !keyMessage.isEmpty {
                        Text(keyMessage).font(.caption).foregroundStyle(.green)
                    }
                }
                .padding(14)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))

                // 2. Place Registration (Multiple places: Home, Work, Gym, etc.)
                VStack(alignment: .leading, spacing: 10) {
                    Label("2. 장소 검색 및 추가 (집, 회사, 헬스장 등 원하는 곳 모두 등록 가능)", systemImage: "mappin.and.ellipse")
                        .font(.headline)

                    HStack(spacing: 6) {
                        Text("장소 별칭:").font(.caption).foregroundStyle(.secondary)
                        ForEach(presetNames, id: \.self) { preset in
                            Button(preset) {
                                placeName = preset
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(placeName == preset ? .accentColor : .secondary)
                        }
                    }

                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("별칭 직접 입력").font(.caption2).foregroundStyle(.secondary)
                            NativeTextField(placeholder: "예: 집, 회사, 헬스장", text: $placeName)
                                .frame(width: 120, height: 26)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("주소 / 역 / 건물명 검색 (입력 후 엔터 또는 검색 버튼)").font(.caption2).foregroundStyle(.secondary)
                            NativeTextField(placeholder: "예: 강남역, 판교역, 테헤란로 152, 잠실 롯데월드", text: $searchQuery) {
                                Task { await performSearch() }
                            }
                            .frame(height: 26)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(" ").font(.caption2)
                            Button(isSearching ? "검색 중..." : "주소 검색") {
                                Task { await performSearch() }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isSearching)
                        }
                    }

                    if !searchStatus.isEmpty {
                        Text(searchStatus).font(.caption).foregroundStyle(.secondary)
                    }

                    if !searchResults.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("검색 결과 (원하는 위치의 [이 위치 등록]을 클릭하세요):")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            ForEach(searchResults) { item in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.title).font(.callout.weight(.medium))
                                        Text(item.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    Button("'\(placeName)'(으)로 등록") {
                                        model.addPlace(
                                            name: placeName,
                                            address: "\(item.title) (\(item.subtitle))",
                                            lat: item.lat,
                                            lon: item.lon
                                        )
                                        searchStatus = "✓ '\(placeName)' 등록 완료: \(item.title)"
                                        searchResults = []
                                        searchQuery = ""
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                }
                                .padding(8)
                                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }

                    DisclosureGroup("위도/경도로 직접 추가하기", isExpanded: $showManualCoords) {
                        HStack(spacing: 8) {
                            NativeTextField(placeholder: "위도 (예: 37.5665)", text: $manualLat)
                                .frame(height: 26)
                            NativeTextField(placeholder: "경도 (예: 126.9780)", text: $manualLon)
                                .frame(height: 26)
                            Button("직접 등록") {
                                if let lat = Double(manualLat.trimmingCharacters(in: .whitespaces)),
                                   let lon = Double(manualLon.trimmingCharacters(in: .whitespaces)) {
                                    model.addPlace(name: placeName, address: "\(lat), \(lon)", lat: lat, lon: lon)
                                    searchStatus = "✓ '\(placeName)' 좌표 직접 등록 완료"
                                    manualLat = ""
                                    manualLon = ""
                                } else {
                                    searchStatus = "올바른 위도/경도 숫자를 입력해 주세요."
                                }
                            }
                        }
                        .padding(.top, 6)
                    }
                    .font(.caption)
                }
                .padding(14)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))

                // 3. Saved Places & Route Selection
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("3. 등록된 장소 목록 (\(model.places.count)곳)", systemImage: "list.bullet.rectangle.portrait")
                            .font(.headline)
                        Spacer()
                        if model.places.count >= 2 {
                            Button("출발 ↔ 도착 바꾸기") {
                                model.swapStartAndEnd()
                            }
                            .controlSize(.small)
                        }
                    }

                    if model.places.isEmpty {
                        Text("아직 등록된 장소가 없습니다. 위에서 집, 회사, 헬스장 등을 검색해 등록해 보세요.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        if model.places.count >= 2 {
                            HStack(spacing: 12) {
                                Picker("출발지", selection: $model.startPlaceID) {
                                    ForEach(model.places) { place in
                                        Text(place.name).tag(place.id)
                                    }
                                }
                                .onChange(of: model.startPlaceID) { _, _ in
                                    Task { await model.refresh() }
                                }

                                Picker("도착지", selection: $model.endPlaceID) {
                                    ForEach(model.places) { place in
                                        Text(place.name).tag(place.id)
                                    }
                                }
                                .onChange(of: model.endPlaceID) { _, _ in
                                    Task { await model.refresh() }
                                }
                            }
                        }

                        ForEach(model.places) { place in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(place.name).font(.callout.weight(.semibold))
                                        if place.id == model.startPlaceID {
                                            Text("출발").font(.caption2.weight(.bold)).padding(.horizontal, 5).padding(.vertical, 1).background(.blue.opacity(0.2), in: Capsule())
                                        }
                                        if place.id == model.endPlaceID {
                                            Text("도착").font(.caption2.weight(.bold)).padding(.horizontal, 5).padding(.vertical, 1).background(.teal.opacity(0.2), in: Capsule())
                                        }
                                    }
                                    Text(place.address).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Button("출발로") {
                                    model.startPlaceID = place.id
                                    Task { await model.refresh() }
                                }
                                .controlSize(.small)
                                Button("도착으로") {
                                    model.endPlaceID = place.id
                                    Task { await model.refresh() }
                                }
                                .controlSize(.small)
                                Button(role: .destructive) {
                                    model.removePlace(id: place.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .controlSize(.small)
                            }
                            .padding(8)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .padding(14)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))

                // 4. Google Calendar & General Settings
                VStack(alignment: .leading, spacing: 10) {
                    Label("4. 캘린더 및 알림 설정", systemImage: "calendar")
                        .font(.headline)

                    HStack {
                        Text("연동된 캘린더: \(model.calendarNames.count)개 · 오늘 일정 \(model.events.count)건")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("인터넷 계정 설정") { model.openInternetAccounts() }.controlSize(.small)
                        Button("캘린더 앱 열기") { model.openCalendarApp() }.controlSize(.small)
                    }

                    HStack(spacing: 8) {
                        Text("캘린더 필터:").font(.caption)
                        NativeTextField(placeholder: "비워두면 전체 캘린더 표시", text: $model.calendarFilter) {
                            model.loadEvents()
                        }
                        .frame(height: 24)
                    }

                    Toggle("5분마다 자동 갱신 (날씨 · TMAP 경로 · 일정)", isOn: $model.autoRefreshEnabled)
                        .font(.callout)
                    Toggle("시간대별 출발↔도착 자동 전환 (\(model.departureHour)시 이후 반대 방향 표시)", isOn: $model.autoSwapByTime)
                        .font(.callout)
                    if model.autoSwapByTime {
                        Stepper("자동 전환 기준 시각: \(model.departureHour)시", value: $model.departureHour, in: 0...23)
                            .font(.caption)
                    }
                    Toggle("정체 및 일정 시작 10분 전 알림 켜기 (경로 \(model.alertThreshold)분 이상 지연 시)", isOn: $model.notificationsOn)
                        .font(.callout)
                    Toggle("맥 로그인 시 SODA DAILY 자동 실행", isOn: Binding(get: { model.openAtLogin }, set: { model.configureLogin($0) }))
                        .font(.callout)

                    HStack {
                        Button("지금 전체 새로고침") {
                            Task { await model.refresh() }
                        }
                        .buttonStyle(.borderedProminent)

                        Button("바탕화면 위젯 표시/숨김") {
                            PanelController.shared.toggle()
                        }
                    }
                }
                .padding(14)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(20)
        }
        .frame(minWidth: 560, minHeight: 700)
    }

    private func saveKey(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            keyMessage = "API 키를 입력해 주세요."
            return
        }
        apiKey = trimmed
        Keychain.set(trimmed, for: "tmap-key")
        hasSavedKey = true
        keyMessage = "✓ API 키 저장 완료 (\(trimmed.prefix(6))...)"
        Task { await model.refresh() }
    }

    private func performSearch() async {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            searchStatus = "검색할 주소나 장소 이름(예: 강남역, 판교역)을 입력해 주세요."
            return
        }
        isSearching = true
        searchStatus = "'\(q)' 위치 검색 중..."
        searchResults = []
        defer { isSearching = false }

        // 1) Try TMAP POI Search first if API key exists
        if let key = Keychain.get("tmap-key"), !key.isEmpty,
           let tmapItems = try? await searchViaTMAP(query: q, apiKey: key),
           !tmapItems.isEmpty {
            searchResults = tmapItems
            searchStatus = "검색 결과 \(tmapItems.count)건 (원하는 위치의 등록 버튼을 누르세요)"
            return
        }

        // 2) Try Apple MKLocalSearch
        if let mkItems = await searchViaMapKit(query: q), !mkItems.isEmpty {
            searchResults = mkItems
            searchStatus = "검색 결과 \(mkItems.count)건 (원하는 위치의 등록 버튼을 누르세요)"
            return
        }

        // 3) Fallback to OpenStreetMap Nominatim
        if let osmItems = try? await searchViaNominatim(query: q), !osmItems.isEmpty {
            searchResults = osmItems
            searchStatus = "검색 결과 \(osmItems.count)건 (원하는 위치의 등록 버튼을 누르세요)"
            return
        }

        searchStatus = "'\(q)' 검색 결과를 찾지 못했습니다. 도로명 주소나 인근 역 이름으로 다시 검색해 보세요."
    }

    private func searchViaTMAP(query: String, apiKey: String) async throws -> [SearchCandidate] {
        guard var comp = URLComponents(string: "https://apis.openapi.sk.com/tmap/pois") else { return [] }
        comp.queryItems = [
            URLQueryItem(name: "version", value: "1"),
            URLQueryItem(name: "searchKeyword", value: query),
            URLQueryItem(name: "count", value: "5"),
            URLQueryItem(name: "reqCoordType", value: "WGS84GEO"),
            URLQueryItem(name: "resCoordType", value: "WGS84GEO")
        ]
        guard let url = comp.url else { return [] }
        var req = URLRequest(url: url)
        req.setValue(apiKey, forHTTPHeaderField: "appKey")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        let decoded = try JSONDecoder().decode(TMapPOIResponse.self, from: data)
        let pois = decoded.searchPoiInfo?.pois?.poi ?? []
        return pois.compactMap { poi in
            guard let latStr = poi.frontLat ?? poi.noorLat,
                  let lonStr = poi.frontLon ?? poi.noorLon,
                  let lat = Double(latStr),
                  let lon = Double(lonStr) else { return nil }
            let addr = [poi.upperAddrName, poi.middleAddrName, poi.lowerAddrName, poi.roadName, poi.firstBuildNo]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return SearchCandidate(title: poi.name ?? query, subtitle: addr, lat: lat, lon: lon)
        }
    }

    private func searchViaMapKit(query: String) async -> [SearchCandidate]? {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = query
        req.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 37.5665, longitude: 126.9780),
            span: MKCoordinateSpan(latitudeDelta: 2.0, longitudeDelta: 2.0)
        )
        guard let resp = try? await MKLocalSearch(request: req).start() else { return nil }
        return resp.mapItems.prefix(5).map { item in
            let c = item.placemark.coordinate
            let sub = [item.placemark.administrativeArea, item.placemark.locality, item.placemark.thoroughfare, item.placemark.subThoroughfare]
                .compactMap { $0 }
                .joined(separator: " ")
            return SearchCandidate(title: item.name ?? query, subtitle: sub.isEmpty ? "\(c.latitude), \(c.longitude)" : sub, lat: c.latitude, lon: c.longitude)
        }
    }

    private func searchViaNominatim(query: String) async throws -> [SearchCandidate] {
        guard var comp = URLComponents(string: "https://nominatim.openstreetmap.org/search") else { return [] }
        comp.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "limit", value: "5"),
            URLQueryItem(name: "countrycodes", value: "kr")
        ]
        guard let url = comp.url else { return [] }
        var req = URLRequest(url: url)
        req.setValue("SODADaily/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        req.setValue("ko-KR,ko;q=0.9", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        let items = try JSONDecoder().decode([NominatimItem].self, from: data)
        return items.compactMap { item in
            guard let lat = Double(item.lat), let lon = Double(item.lon) else { return nil }
            let parts = item.display_name.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let title = parts.first ?? query
            return SearchCandidate(title: title, subtitle: item.display_name, lat: lat, lon: lon)
        }
    }
}

struct OpenSettingsButton: View {
    var body: some View {
        Button("설정...") {
            SettingsWindowController.shared.show()
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
        if (Keychain.get("tmap-key") ?? "").isEmpty || DailyModel.shared.places.count < 2 {
            SettingsWindowController.shared.show()
        }
        Task { await DailyModel.shared.startup() }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in
                guard DailyModel.shared.autoRefreshEnabled else { return }
                await DailyModel.shared.refresh()
            }
        }
    }
    func applicationWillTerminate(_ notification: Notification) { timer?.invalidate() }
}
