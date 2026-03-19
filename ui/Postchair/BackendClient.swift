import Foundation

struct BackendClient {
    private let baseURL = URL(string: "http://127.0.0.1:8000")!
    private let encoder = JSONEncoder()

    func fetchBackendStatus() async throws -> BackendStatus {
        BackendStatus(dictionary: try await requestObject(path: "/api/status", method: "GET", body: nil))
    }

    func fetchMonitoringState() async throws -> MonitoringState {
        MonitoringState(dictionary: try await requestObject(path: "/api/monitoring", method: "GET", body: nil))
    }

    func startMonitoring() async throws -> MonitoringState {
        let payload = try encoder.encode([String: String]())
        return MonitoringState(dictionary: try await requestObject(path: "/api/monitoring/start", method: "POST", body: payload))
    }

    func stopMonitoring() async throws -> MonitoringState {
        let payload = try encoder.encode([String: String]())
        return MonitoringState(dictionary: try await requestObject(path: "/api/monitoring/stop", method: "POST", body: payload))
    }

    func fetchNotificationSettings() async throws -> NotificationSettingsPayload {
        NotificationSettingsPayload(dictionary: try await requestObject(path: "/api/notifications", method: "GET", body: nil))
    }

    func fetchModelCatalog() async throws -> ModelCatalog {
        ModelCatalog(dictionary: try await requestObject(path: "/api/model", method: "GET", body: nil))
    }

    func updateNotificationSettings(
        enabled: Bool,
        thresholdSeconds: Int,
        enabledLabelIDs: [Int],
        focusMode: String
    ) async throws -> NotificationSettingsPayload {
        struct Payload: Encodable {
            let enabled: Bool
            let thresholdSeconds: Int
            let enabledLabelIDs: [Int]
            let focusMode: String
        }

        let body = try encoder.encode(
            Payload(
                enabled: enabled,
                thresholdSeconds: thresholdSeconds,
                enabledLabelIDs: enabledLabelIDs,
                focusMode: focusMode
            )
        )
        return NotificationSettingsPayload(dictionary: try await requestObject(path: "/api/notifications", method: "PUT", body: body))
    }

    func updateSelectedModel(filename: String) async throws -> ModelCatalog {
        struct Payload: Encodable {
            let filename: String
        }

        let body = try encoder.encode(Payload(filename: filename))
        return ModelCatalog(dictionary: try await requestObject(path: "/api/model", method: "PUT", body: body))
    }

    private func requestObject(path: String, method: String, body: Data?) async throws -> [String: Any] {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw BackendClientError.transport(path: path, underlying: error)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackendClientError.invalidResponse
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw BackendClientError.server(statusCode: httpResponse.statusCode)
        }
        do {
            let json = try JSONSerialization.jsonObject(with: data)
            guard let object = json as? [String: Any] else {
                throw BackendClientError.invalidResponse
            }
            return object
        } catch {
            let bodyText = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            throw BackendClientError.decode(path: path, message: error.localizedDescription, body: bodyText)
        }
    }
}

enum BackendClientError: LocalizedError {
    case invalidResponse
    case server(statusCode: Int)
    case transport(path: String, underlying: Error)
    case decode(path: String, message: String, body: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "バックエンドから不正なレスポンスを受信しました。"
        case let .server(statusCode):
            return "バックエンドエラー: \(statusCode)"
        case let .transport(path, underlying):
            return "バックエンド通信失敗 \(path): \(underlying.localizedDescription)"
        case let .decode(path, message, body):
            return "バックエンド応答の解釈に失敗 \(path): \(message) body=\(body)"
        }
    }
}
