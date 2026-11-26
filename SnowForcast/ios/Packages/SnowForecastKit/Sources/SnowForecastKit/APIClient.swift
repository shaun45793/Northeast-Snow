import Foundation

public enum SnowAPIError: Error, LocalizedError {
    case invalidURL(String)
    case httpStatus(Int, String)
    case decodingFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid backend URL: \(url)"
        case .httpStatus(let code, let body):
            return "Server returned HTTP \(code): \(body)"
        case .decodingFailed(let error):
            return "Failed to decode forecast response: \(error.localizedDescription)"
        }
    }
}

public protocol SnowForecastProviding: Sendable {
    func fetchMountains(state: String?) async throws -> [MountainSummary]
    func fetchMountainForecast(mountainId: String, elevation: ElevationBand) async throws -> MountainForecastResponse
    func fetchDiscussions() async throws -> [MeteorologistDiscussion]
    func fetchMLStatus(scope: String?) async throws -> TrainingStatusResponse
    func triggerRetrain() async throws -> TrainingStatusResponse
}

public final class SnowForecastAPIClient: SnowForecastProviding, @unchecked Sendable {
    public let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder

    public init(baseURLString: String = "http://127.0.0.1:8000", session: URLSession = .shared) throws {
        guard let url = URL(string: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw SnowAPIError.invalidURL(baseURLString)
        }
        self.baseURL = url
        self.session = session
        self.decoder = SnowForecastAPIClient.makeDecoder()
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)

            let withFractional = ISO8601DateFormatter()
            withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFractional.date(from: str) {
                return date
            }

            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = standard.date(from: str) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO8601 date string: \(str)"
            )
        }
        return decoder
    }

    public func fetchMountains(state: String? = nil) async throws -> [MountainSummary] {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/v1/mountains"), resolvingAgainstBaseURL: false)
        if let state, !state.isEmpty, state != "All" {
            components?.queryItems = [URLQueryItem(name: "state", value: state)]
        }
        guard let url = components?.url else { throw SnowAPIError.invalidURL(baseURL.absoluteString) }
        return try await get(url)
    }

    public func fetchMountainForecast(
        mountainId: String,
        elevation: ElevationBand = .summit
    ) async throws -> MountainForecastResponse {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/v1/mountains/\(mountainId)/forecast"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "elevation", value: elevation.rawValue)]
        guard let url = components?.url else { throw SnowAPIError.invalidURL(baseURL.absoluteString) }
        return try await get(url)
    }

    public func fetchDiscussions() async throws -> [MeteorologistDiscussion] {
        let url = baseURL.appendingPathComponent("api/v1/discussions")
        return try await get(url)
    }

    public func fetchMLStatus(scope: String? = "global") async throws -> TrainingStatusResponse {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/v1/ml/status"),
            resolvingAgainstBaseURL: false
        )
        if let scope {
            components?.queryItems = [URLQueryItem(name: "scope", value: scope)]
        }
        guard let url = components?.url else { throw SnowAPIError.invalidURL(baseURL.absoluteString) }
        return try await get(url)
    }

    public func triggerRetrain() async throws -> TrainingStatusResponse {
        let url = baseURL.appendingPathComponent("api/v1/ml/retrain")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (data, response) = try await session.data(for: request)
        return try decodeResponse(data: data, response: response)
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        let (data, response) = try await session.data(from: url)
        return try decodeResponse(data: data, response: response)
    }

    private func decodeResponse<T: Decodable>(data: Data, response: URLResponse) throws -> T {
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw SnowAPIError.httpStatus(http.statusCode, body)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw SnowAPIError.decodingFailed(error)
        }
    }
}
