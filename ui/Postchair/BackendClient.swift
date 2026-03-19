import Foundation

@MainActor
protocol BackendClientProtocol {
    func fetchBackendStatus() async throws -> BackendStatus
    func fetchMonitoringState() async throws -> MonitoringState
    func startMonitoring() async throws -> MonitoringState
    func stopMonitoring() async throws -> MonitoringState
    func fetchNotificationSettings() async throws -> NotificationSettingsPayload
    func fetchModelCatalog() async throws -> ModelCatalog
    func updateNotificationSettings(
        enabled: Bool,
        thresholdSeconds: Int,
        enabledLabelIDs: [Int],
        focusMode: String
    ) async throws -> NotificationSettingsPayload
    func updateSelectedModel(filename: String) async throws -> ModelCatalog
    func updateTrainingRecordingLabel(labelID: Int?) async throws -> TrainingSessionState
    func completeTrainingSession(modelName: String) async throws -> (ModelCatalog, TrainingResult)
}

struct BackendClient: BackendClientProtocol {
    private let baseURL: URL
    private let encoder = JSONEncoder()

    init(baseURL: URL = URL(string: "http://127.0.0.1:8000")!) {
        self.baseURL = baseURL
    }

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
        let body = try makeNotificationSettingsBody(
            enabled: enabled,
            thresholdSeconds: thresholdSeconds,
            enabledLabelIDs: enabledLabelIDs,
            focusMode: focusMode
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

    func updateTrainingRecordingLabel(labelID: Int?) async throws -> TrainingSessionState {
        struct Payload: Encodable {
            let labelID: Int?

            enum CodingKeys: String, CodingKey {
                case labelID = "label_id"
            }
        }

        let body = try encoder.encode(Payload(labelID: labelID))
        return TrainingSessionState(
            dictionary: try await requestObject(path: "/api/training-session/recording", method: "POST", body: body)
        )
    }

    func completeTrainingSession(modelName: String) async throws -> (ModelCatalog, TrainingResult) {
        struct Payload: Encodable {
            let modelName: String

            enum CodingKeys: String, CodingKey {
                case modelName = "model_name"
            }
        }

        let body = try encoder.encode(Payload(modelName: modelName))
        let response = try await requestObject(path: "/api/training-session/complete", method: "POST", body: body)
        let modelCatalog = ModelCatalog(dictionary: response["model_catalog"] as? [String: Any] ?? [:])
        let trainingResult = TrainingResult(dictionary: response["training_result"] as? [String: Any] ?? [:])
        return (modelCatalog, trainingResult)
    }

    func makeNotificationSettingsBody(
        enabled: Bool,
        thresholdSeconds: Int,
        enabledLabelIDs: [Int],
        focusMode: String
    ) throws -> Data {
        struct Payload: Encodable {
            let enabled: Bool
            let thresholdSeconds: Int
            let enabledLabelIDs: [Int]
            let focusMode: String

            enum CodingKeys: String, CodingKey {
                case enabled
                case thresholdSeconds = "threshold_seconds"
                case enabledLabelIDs = "enabled_label_ids"
                case focusMode = "focus_mode"
            }
        }

        return try encoder.encode(
            Payload(
                enabled: enabled,
                thresholdSeconds: thresholdSeconds,
                enabledLabelIDs: enabledLabelIDs,
                focusMode: focusMode
            )
        )
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
            let bodyText = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            throw BackendClientError.server(statusCode: httpResponse.statusCode, body: bodyText)
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
    case server(statusCode: Int, body: String)
    case transport(path: String, underlying: Error)
    case decode(path: String, message: String, body: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "バックエンドから不正なレスポンスを受信しました。"
        case let .server(statusCode, body):
            return "バックエンドエラー: \(statusCode) \(body)"
        case let .transport(path, underlying):
            return "バックエンド通信失敗 \(path): \(underlying.localizedDescription)"
        case let .decode(path, message, body):
            return "バックエンド応答の解釈に失敗 \(path): \(message) body=\(body)"
        }
    }
}
