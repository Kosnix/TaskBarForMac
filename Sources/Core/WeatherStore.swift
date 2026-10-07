import Foundation
import Observation

/// Current weather for the taskbar's widget, from Open-Meteo (free, no key,
/// no account). Only the typed city name is sent — to look up its
/// coordinates — and then those coordinates, nothing else. The location is
/// never read from the Mac itself.
@MainActor
@Observable
final class WeatherStore {
    static let shared = WeatherStore()

    struct Snapshot {
        var place: String
        var temperature: Double
        var high: Double
        var low: Double
        var code: Int
        var unit: String
    }

    private(set) var snapshot: Snapshot?
    private(set) var failed = false

    @ObservationIgnored private var city = ""
    @ObservationIgnored private var coordinates: (lat: Double, lon: Double, name: String)?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var lastFetch = Date.distantPast

    /// Called whenever the widget is shown or the city changes; fetches at
    /// most every 15 minutes for the same city.
    func configure(city: String) {
        let trimmed = city.trimmingCharacters(in: .whitespaces)
        if trimmed != self.city {
            self.city = trimmed
            coordinates = nil
            snapshot = nil
            lastFetch = .distantPast
        }
        guard !trimmed.isEmpty, Date().timeIntervalSince(lastFetch) > 15 * 60, refreshTask == nil else { return }
        refreshTask = Task {
            await fetch()
            refreshTask = nil
        }
    }

    private func fetch() async {
        lastFetch = Date()
        do {
            if coordinates == nil { coordinates = try await geocode(city) }
            guard let coordinates else { throw URLError(.cannotFindHost) }
            snapshot = try await forecast(coordinates)
            failed = false
        } catch {
            failed = true
            lastFetch = Date().addingTimeInterval(-14 * 60) // retry in a minute
        }
    }

    private func geocode(_ name: String) async throws -> (lat: Double, lon: Double, name: String) {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "count", value: "1"),
            URLQueryItem(name: "language", value: Localization.effectiveLocale.language.languageCode?.identifier ?? "en"),
        ]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        struct Response: Decodable {
            struct Result: Decodable { let name: String; let latitude: Double; let longitude: Double }
            let results: [Result]?
        }
        guard let first = try JSONDecoder().decode(Response.self, from: data).results?.first else { throw URLError(.cannotFindHost) }
        return (first.latitude, first.longitude, first.name)
    }

    private func forecast(_ place: (lat: Double, lon: Double, name: String)) async throws -> Snapshot {
        let fahrenheit = Localization.effectiveLocale.measurementSystem == .us
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(place.lat)),
            URLQueryItem(name: "longitude", value: String(place.lon)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "forecast_days", value: "1"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "temperature_unit", value: fahrenheit ? "fahrenheit" : "celsius"),
        ]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        struct Response: Decodable {
            struct Current: Decodable { let temperature_2m: Double; let weather_code: Int }
            struct Daily: Decodable { let temperature_2m_max: [Double]; let temperature_2m_min: [Double] }
            let current: Current
            let daily: Daily
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        return Snapshot(
            place: place.name,
            temperature: response.current.temperature_2m,
            high: response.daily.temperature_2m_max.first ?? response.current.temperature_2m,
            low: response.daily.temperature_2m_min.first ?? response.current.temperature_2m,
            code: response.current.weather_code,
            unit: fahrenheit ? "°F" : "°C"
        )
    }

    // MARK: - WMO weather codes

    static func symbol(for code: Int) -> String {
        switch code {
        case 0: return "sun.max.fill"
        case 1, 2: return "cloud.sun.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...57: return "cloud.drizzle.fill"
        case 61...67: return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 80...82: return "cloud.heavyrain.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    static func descriptionKey(for code: Int) -> String {
        switch code {
        case 0: return "weather.clear"
        case 1, 2: return "weather.partly"
        case 3: return "weather.cloudy"
        case 45, 48: return "weather.fog"
        case 51...57: return "weather.drizzle"
        case 61...67: return "weather.rain"
        case 71...77, 85, 86: return "weather.snow"
        case 80...82: return "weather.showers"
        case 95...99: return "weather.thunder"
        default: return "weather.cloudy"
        }
    }
}
