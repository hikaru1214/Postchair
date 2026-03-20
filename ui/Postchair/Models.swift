import Foundation

enum SidebarSection: String, CaseIterable, Identifiable {
    case connection
    case notifications
    case model
    case modelCreation
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connection: return "接続"
        case .notifications: return "通知"
        case .model: return "モデル"
        case .modelCreation: return "モデル作成"
        case .about: return "このアプリについて"
        }
    }

    var subtitle: String {
        switch self {
        case .connection: return "BLE と監視状態"
        case .notifications: return "通知タイミングと対象姿勢"
        case .model: return "推論モデルの選択と状態"
        case .modelCreation: return "姿勢データ収集と新規モデル学習"
        case .about: return "アプリと実行環境の情報"
        }
    }

    var icon: String {
        switch self {
        case .connection: return "bolt.horizontal.circle"
        case .notifications: return "bell"
        case .model: return "cpu"
        case .modelCreation: return "slider.horizontal.3"
        case .about: return "info.circle"
        }
    }

    var accent: AppAccent {
        switch self {
        case .connection: return .blue
        case .notifications: return .cyan
        case .model: return .green
        case .modelCreation: return .indigo
        case .about: return .sky
        }
    }
}

enum ConnectionState: String, Codable {
    case starting
    case connecting
    case connected
    case error
    case stopped

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = Self.parse((try? container.decode(String.self)) ?? "")
    }

    static func parse(_ raw: String) -> ConnectionState {
        let rawValue = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch rawValue {
        case "starting":
            return .starting
        case "connecting":
            return .connecting
        case "connected":
            return .connected
        case "error":
            return .error
        case "stopped":
            return .stopped
        default:
            if rawValue.contains("connect") {
                return .connected
            } else if rawValue.contains("start") {
                return .starting
            } else if rawValue.contains("error") || rawValue.contains("fail") {
                return .error
            } else {
                return .stopped
            }
        }
    }
}

struct LabelMetadata: Codable {
    let id: Int
    let name: String
    let severity: String

    init(id: Int, name: String, severity: String) {
        self.id = id
        self.name = name
        self.severity = severity
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id) ?? 0
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "未判定"
        severity = try container.decodeIfPresent(String.self, forKey: .severity) ?? "neutral"
    }

    init(dictionary: [String: Any]) {
        id = dictionary["id"] as? Int ?? 0
        name = dictionary["name"] as? String ?? "未判定"
        severity = dictionary["severity"] as? String ?? "neutral"
    }
}

struct NotificationEventPayload: Codable {
    let sequence: Int
    let labelID: Int?
    let label: LabelMetadata?
    let triggeredAt: String?

    enum CodingKeys: String, CodingKey {
        case sequence
        case labelID = "label_id"
        case label
        case triggeredAt = "triggered_at"
    }

    init(sequence: Int, labelID: Int?, label: LabelMetadata?, triggeredAt: String?) {
        self.sequence = sequence
        self.labelID = labelID
        self.label = label
        self.triggeredAt = triggeredAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sequence = try container.decodeIfPresent(Int.self, forKey: .sequence) ?? 0
        labelID = try container.decodeIfPresent(Int.self, forKey: .labelID)
        label = try container.decodeIfPresent(LabelMetadata.self, forKey: .label)
        triggeredAt = try container.decodeIfPresent(String.self, forKey: .triggeredAt)
    }

    init(dictionary: [String: Any]) {
        sequence = dictionary["sequence"] as? Int ?? 0
        labelID = dictionary["label_id"] as? Int
        if let raw = dictionary["label"] as? [String: Any] {
            label = LabelMetadata(dictionary: raw)
        } else {
            label = nil
        }
        triggeredAt = dictionary["triggered_at"] as? String
    }
}

struct LiveFrame: Codable {
    let center: Int
    let leftFoot: Int
    let rear: Int
    let rightFoot: Int
    let receivedAt: String

    enum CodingKeys: String, CodingKey {
        case center
        case leftFoot = "left_foot"
        case rear
        case rightFoot = "right_foot"
        case receivedAt = "received_at"
    }

    init(center: Int, leftFoot: Int, rear: Int, rightFoot: Int, receivedAt: String) {
        self.center = center
        self.leftFoot = leftFoot
        self.rear = rear
        self.rightFoot = rightFoot
        self.receivedAt = receivedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        center = try container.decodeIfPresent(Int.self, forKey: .center) ?? 0
        leftFoot = try container.decodeIfPresent(Int.self, forKey: .leftFoot) ?? 0
        rear = try container.decodeIfPresent(Int.self, forKey: .rear) ?? 0
        rightFoot = try container.decodeIfPresent(Int.self, forKey: .rightFoot) ?? 0
        receivedAt = try container.decodeIfPresent(String.self, forKey: .receivedAt) ?? ""
    }

    init(dictionary: [String: Any]) {
        center = dictionary["center"] as? Int ?? 0
        leftFoot = dictionary["left_foot"] as? Int ?? 0
        rear = dictionary["rear"] as? Int ?? 0
        rightFoot = dictionary["right_foot"] as? Int ?? 0
        receivedAt = dictionary["received_at"] as? String ?? ""
    }
}

struct BackendStatus: Codable {
    let running: Bool
    let version: String
    let modelLoaded: Bool
    let connectionState: ConnectionState
    let lastError: String?

    enum CodingKeys: String, CodingKey {
        case running
        case version
        case modelLoaded = "model_loaded"
        case connectionState = "connection_state"
        case lastError = "last_error"
    }

    init(running: Bool, version: String, modelLoaded: Bool, connectionState: ConnectionState, lastError: String?) {
        self.running = running
        self.version = version
        self.modelLoaded = modelLoaded
        self.connectionState = connectionState
        self.lastError = lastError
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        running = try container.decodeIfPresent(Bool.self, forKey: .running) ?? false
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? "0.0.0"
        modelLoaded = try container.decodeIfPresent(Bool.self, forKey: .modelLoaded) ?? false
        connectionState = try container.decodeIfPresent(ConnectionState.self, forKey: .connectionState) ?? .stopped
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
    }

    init(dictionary: [String: Any]) {
        running = dictionary["running"] as? Bool ?? false
        version = dictionary["version"] as? String ?? "0.0.0"
        modelLoaded = dictionary["model_loaded"] as? Bool ?? false
        connectionState = ConnectionState.parse(dictionary["connection_state"] as? String ?? "")
        lastError = dictionary["last_error"] as? String
    }

    static let placeholder = BackendStatus(
        running: false,
        version: "0.0.0",
        modelLoaded: false,
        connectionState: .stopped,
        lastError: nil
    )
}

struct MonitoringState: Codable {
    let active: Bool
    let connectionState: ConnectionState
    let deviceName: String
    let deviceAddress: String?
    let modelLoaded: Bool
    let latestFrame: LiveFrame?
    let latestLabelID: Int?
    let latestLabelMetadata: LabelMetadata?
    let lastError: String?
    let startedAt: String?
    let lastFrameAt: String?
    let notificationEvent: NotificationEventPayload
    let trainingSession: TrainingSessionState

    var resolvedConnectionState: ConnectionState {
        if connectionState != .stopped {
            return connectionState
        }
        if active, deviceAddress != nil {
            return .connected
        }
        if active, latestFrame != nil {
            return .connected
        }
        if active {
            return .starting
        }
        return .stopped
    }

    enum CodingKeys: String, CodingKey {
        case active
        case connectionState = "connection_state"
        case deviceName = "device_name"
        case deviceAddress = "device_address"
        case modelLoaded = "model_loaded"
        case latestFrame = "latest_frame"
        case latestLabelID = "latest_label_id"
        case latestLabelMetadata = "latest_label_metadata"
        case lastError = "last_error"
        case startedAt = "started_at"
        case lastFrameAt = "last_frame_at"
        case notificationEvent = "notification_event"
        case trainingSession = "training_session"
    }

    init(
        active: Bool,
        connectionState: ConnectionState,
        deviceName: String,
        deviceAddress: String?,
        modelLoaded: Bool,
        latestFrame: LiveFrame?,
        latestLabelID: Int?,
        latestLabelMetadata: LabelMetadata?,
        lastError: String?,
        startedAt: String?,
        lastFrameAt: String?,
        notificationEvent: NotificationEventPayload,
        trainingSession: TrainingSessionState
    ) {
        self.active = active
        self.connectionState = connectionState
        self.deviceName = deviceName
        self.deviceAddress = deviceAddress
        self.modelLoaded = modelLoaded
        self.latestFrame = latestFrame
        self.latestLabelID = latestLabelID
        self.latestLabelMetadata = latestLabelMetadata
        self.lastError = lastError
        self.startedAt = startedAt
        self.lastFrameAt = lastFrameAt
        self.notificationEvent = notificationEvent
        self.trainingSession = trainingSession
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        active = try container.decodeIfPresent(Bool.self, forKey: .active) ?? false
        connectionState = try container.decodeIfPresent(ConnectionState.self, forKey: .connectionState) ?? .stopped
        deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName) ?? "ESP32_SmartSensor"
        deviceAddress = try container.decodeIfPresent(String.self, forKey: .deviceAddress)
        modelLoaded = try container.decodeIfPresent(Bool.self, forKey: .modelLoaded) ?? false
        latestFrame = try container.decodeIfPresent(LiveFrame.self, forKey: .latestFrame)
        latestLabelID = try container.decodeIfPresent(Int.self, forKey: .latestLabelID)
        latestLabelMetadata = try container.decodeIfPresent(LabelMetadata.self, forKey: .latestLabelMetadata)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        startedAt = try container.decodeIfPresent(String.self, forKey: .startedAt)
        lastFrameAt = try container.decodeIfPresent(String.self, forKey: .lastFrameAt)
        notificationEvent = try container.decodeIfPresent(NotificationEventPayload.self, forKey: .notificationEvent)
            ?? NotificationEventPayload(sequence: 0, labelID: nil, label: nil, triggeredAt: nil)
        trainingSession = try container.decodeIfPresent(TrainingSessionState.self, forKey: .trainingSession)
            ?? .empty
    }

    init(dictionary: [String: Any]) {
        active = dictionary["active"] as? Bool ?? false
        connectionState = ConnectionState.parse(dictionary["connection_state"] as? String ?? "")
        deviceName = dictionary["device_name"] as? String ?? "ESP32_SmartSensor"
        deviceAddress = dictionary["device_address"] as? String
        modelLoaded = dictionary["model_loaded"] as? Bool ?? false
        if let raw = dictionary["latest_frame"] as? [String: Any] {
            latestFrame = LiveFrame(dictionary: raw)
        } else {
            latestFrame = nil
        }
        latestLabelID = dictionary["latest_label_id"] as? Int
        if let raw = dictionary["latest_label_metadata"] as? [String: Any] {
            latestLabelMetadata = LabelMetadata(dictionary: raw)
        } else {
            latestLabelMetadata = nil
        }
        lastError = dictionary["last_error"] as? String
        startedAt = dictionary["started_at"] as? String
        lastFrameAt = dictionary["last_frame_at"] as? String
        if let raw = dictionary["notification_event"] as? [String: Any] {
            notificationEvent = NotificationEventPayload(dictionary: raw)
        } else {
            notificationEvent = NotificationEventPayload(sequence: 0, labelID: nil, label: nil, triggeredAt: nil)
        }
        if let raw = dictionary["training_session"] as? [String: Any] {
            trainingSession = TrainingSessionState(dictionary: raw)
        } else {
            trainingSession = .empty
        }
    }

    static let placeholder = MonitoringState(
        active: false,
        connectionState: .stopped,
        deviceName: "ESP32_SmartSensor",
        deviceAddress: nil,
        modelLoaded: false,
        latestFrame: nil,
        latestLabelID: nil,
        latestLabelMetadata: nil,
        lastError: nil,
        startedAt: nil,
        lastFrameAt: nil,
        notificationEvent: NotificationEventPayload(sequence: 0, labelID: nil, label: nil, triggeredAt: nil),
        trainingSession: .empty
    )
}

struct TrainingSessionState: Codable {
    let activeLabelID: Int?
    let activeLabel: LabelMetadata?
    let samplesByLabelID: [String: Int]
    let totalSamples: Int
    let startedAt: String?
    let lastRecordedAt: String?
    let lastTrainingError: String?

    enum CodingKeys: String, CodingKey {
        case activeLabelID = "active_label_id"
        case activeLabel = "active_label"
        case samplesByLabelID = "samples_by_label_id"
        case totalSamples = "total_samples"
        case startedAt = "started_at"
        case lastRecordedAt = "last_recorded_at"
        case lastTrainingError = "last_training_error"
    }

    init(
        activeLabelID: Int?,
        activeLabel: LabelMetadata?,
        samplesByLabelID: [String: Int],
        totalSamples: Int,
        startedAt: String?,
        lastRecordedAt: String?,
        lastTrainingError: String?
    ) {
        self.activeLabelID = activeLabelID
        self.activeLabel = activeLabel
        self.samplesByLabelID = samplesByLabelID
        self.totalSamples = totalSamples
        self.startedAt = startedAt
        self.lastRecordedAt = lastRecordedAt
        self.lastTrainingError = lastTrainingError
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activeLabelID = try container.decodeIfPresent(Int.self, forKey: .activeLabelID)
        activeLabel = try container.decodeIfPresent(LabelMetadata.self, forKey: .activeLabel)
        samplesByLabelID = try container.decodeIfPresent([String: Int].self, forKey: .samplesByLabelID) ?? [:]
        totalSamples = try container.decodeIfPresent(Int.self, forKey: .totalSamples) ?? 0
        startedAt = try container.decodeIfPresent(String.self, forKey: .startedAt)
        lastRecordedAt = try container.decodeIfPresent(String.self, forKey: .lastRecordedAt)
        lastTrainingError = try container.decodeIfPresent(String.self, forKey: .lastTrainingError)
    }

    init(dictionary: [String: Any]) {
        activeLabelID = dictionary["active_label_id"] as? Int
        if let raw = dictionary["active_label"] as? [String: Any] {
            activeLabel = LabelMetadata(dictionary: raw)
        } else {
            activeLabel = nil
        }
        samplesByLabelID = dictionary["samples_by_label_id"] as? [String: Int] ?? [:]
        totalSamples = dictionary["total_samples"] as? Int ?? 0
        startedAt = dictionary["started_at"] as? String
        lastRecordedAt = dictionary["last_recorded_at"] as? String
        lastTrainingError = dictionary["last_training_error"] as? String
    }

    static let empty = TrainingSessionState(
        activeLabelID: nil,
        activeLabel: nil,
        samplesByLabelID: [:],
        totalSamples: 0,
        startedAt: nil,
        lastRecordedAt: nil,
        lastTrainingError: nil
    )
}

struct TrainingResult {
    let modelName: String
    let modelFilename: String
    let dataFilename: String
    let sampleCount: Int
    let accuracyText: String?

    init(
        modelName: String,
        modelFilename: String,
        dataFilename: String,
        sampleCount: Int,
        accuracyText: String?
    ) {
        self.modelName = modelName
        self.modelFilename = modelFilename
        self.dataFilename = dataFilename
        self.sampleCount = sampleCount
        self.accuracyText = accuracyText
    }

    init(dictionary: [String: Any]) {
        modelName = dictionary["model_name"] as? String ?? ""
        modelFilename = dictionary["model_filename"] as? String ?? ""
        dataFilename = dictionary["data_filename"] as? String ?? ""
        sampleCount = dictionary["sample_count"] as? Int ?? 0
        if let metrics = dictionary["metrics"] as? [String: Any],
           let accuracy = metrics["accuracy"] as? Double {
            accuracyText = String(format: "%.3f", accuracy)
        } else {
            accuracyText = nil
        }
    }
}

struct NotificationSettingsPayload: Codable {
    let enabled: Bool
    let thresholdSeconds: Int
    let enabledLabelIDs: [Int]
    let focusMode: String

    private static let allowedNotificationLabelIDs = Set([2, 3, 4, 5])

    private static func normalizedLabelIDs(_ ids: [Int]) -> [Int] {
        Array(Set(ids).intersection(allowedNotificationLabelIDs)).sorted()
    }

    enum CodingKeys: String, CodingKey {
        case enabled
        case thresholdSeconds = "threshold_seconds"
        case enabledLabelIDs = "enabled_label_ids"
        case focusMode = "focus_mode"
    }

    init(enabled: Bool, thresholdSeconds: Int, enabledLabelIDs: [Int], focusMode: String) {
        self.enabled = enabled
        self.thresholdSeconds = thresholdSeconds
        self.enabledLabelIDs = Self.normalizedLabelIDs(enabledLabelIDs)
        self.focusMode = focusMode
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        thresholdSeconds = try container.decodeIfPresent(Int.self, forKey: .thresholdSeconds) ?? 60
        enabledLabelIDs = Self.normalizedLabelIDs(
            try container.decodeIfPresent([Int].self, forKey: .enabledLabelIDs) ?? [2, 3, 4, 5]
        )
        focusMode = try container.decodeIfPresent(String.self, forKey: .focusMode) ?? "indicator_only"
    }

    init(dictionary: [String: Any]) {
        enabled = dictionary["enabled"] as? Bool ?? true
        thresholdSeconds = dictionary["threshold_seconds"] as? Int ?? 60
        enabledLabelIDs = Self.normalizedLabelIDs(dictionary["enabled_label_ids"] as? [Int] ?? [2, 3, 4, 5])
        focusMode = dictionary["focus_mode"] as? String ?? "indicator_only"
    }
}

struct PostureLabelConfig: Identifiable {
    let id: Int
    let name: String
    let severity: String
}

struct TrainingLabelOption: Identifiable {
    let id: Int
    let name: String
}

struct LiveFrameSample: Identifiable {
    let id = UUID()
    let center: Int
    let left: Int
    let rear: Int
    let right: Int
    let timestamp: Date

    init(frame: LiveFrame) {
        center = frame.center
        left = frame.leftFoot
        rear = frame.rear
        right = frame.rightFoot
        timestamp = ISO8601DateFormatter().date(from: frame.receivedAt) ?? .now
    }

    var total: Int {
        center + left + rear + right
    }
}

struct PostureStatusItem: Identifiable {
    let id: Int
    let name: String
    let severity: String
    let isActive: Bool
}

struct ModelOption: Identifiable {
    let id: String
    let filename: String
    let displayName: String
    let fileSize: String
    let isSelected: Bool
    let isLoaded: Bool
}

struct ModelCatalog {
    let currentModelFilename: String?
    let currentModelDisplayName: String
    let modelLoaded: Bool
    let availableModels: [ModelOption]
    let lastError: String?

    init(
        currentModelFilename: String?,
        currentModelDisplayName: String,
        modelLoaded: Bool,
        availableModels: [ModelOption],
        lastError: String?
    ) {
        self.currentModelFilename = currentModelFilename
        self.currentModelDisplayName = currentModelDisplayName
        self.modelLoaded = modelLoaded
        self.availableModels = availableModels
        self.lastError = lastError
    }

    init(dictionary: [String: Any]) {
        currentModelFilename = dictionary["current_model_filename"] as? String
        currentModelDisplayName = dictionary["current_model_display_name"] as? String ?? "未選択"
        modelLoaded = dictionary["model_loaded"] as? Bool ?? false
        lastError = dictionary["last_error"] as? String
        availableModels = (dictionary["available_models"] as? [[String: Any]] ?? []).map { item in
            let filename = item["filename"] as? String ?? "unknown.joblib"
            let displayName = item["display_name"] as? String ?? filename
            let fileSize = item["file_size"] as? String ?? "-"
            let isSelected = item["is_selected"] as? Bool ?? false
            let isLoaded = item["is_loaded"] as? Bool ?? false
            return ModelOption(
                id: filename,
                filename: filename,
                displayName: displayName,
                fileSize: fileSize,
                isSelected: isSelected,
                isLoaded: isLoaded
            )
        }
    }

    static let placeholder = ModelCatalog(
        currentModelFilename: nil,
        currentModelDisplayName: "random_forest_label.joblib",
        modelLoaded: false,
        availableModels: [],
        lastError: nil
    )
}

struct NotificationSettingsState {
    var enabled: Bool
    var thresholdSeconds: Int
    var enabledLabelIDs: [Int]
    var focusMode: String
    var labelConfigurations: [PostureLabelConfig]

    init(payload: NotificationSettingsPayload) {
        enabled = payload.enabled
        thresholdSeconds = payload.thresholdSeconds
        enabledLabelIDs = payload.enabledLabelIDs
        focusMode = payload.focusMode
        labelConfigurations = Self.defaultLabels
    }

    static let defaultLabels = [
        PostureLabelConfig(id: 2, name: "猫背", severity: "warning"),
        PostureLabelConfig(id: 3, name: "前傾姿勢", severity: "warning"),
        PostureLabelConfig(id: 4, name: "右足組み", severity: "warning"),
        PostureLabelConfig(id: 5, name: "左足組み", severity: "warning"),
    ]

    static let defaultState = NotificationSettingsState(
        payload: NotificationSettingsPayload(
            enabled: true,
            thresholdSeconds: 60,
            enabledLabelIDs: [2, 3, 4, 5],
            focusMode: "indicator_only"
        )
    )
}

extension TrainingLabelOption {
    static let allCases = [
        TrainingLabelOption(id: 0, name: "離席"),
        TrainingLabelOption(id: 1, name: "良い姿勢"),
        TrainingLabelOption(id: 3, name: "前傾姿勢"),
        TrainingLabelOption(id: 2, name: "猫背"),
        TrainingLabelOption(id: 5, name: "左足組み"),
        TrainingLabelOption(id: 4, name: "右足組み"),
    ]
}

enum AppAccent {
    case blue
    case cyan
    case green
    case indigo
    case sky
    case violet
}
