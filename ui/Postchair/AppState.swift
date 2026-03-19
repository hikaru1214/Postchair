import AppKit
import Combine
import Foundation
import UserNotifications

struct AppNotificationSettings {
    let authorizationStatus: UNAuthorizationStatus
    let alertSetting: UNNotificationSetting
}

@MainActor
protocol NotificationCenterProtocol: AnyObject {
    var delegate: UNUserNotificationCenterDelegate? { get set }
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func notificationSettings() async -> AppNotificationSettings
    func add(_ request: UNNotificationRequest) async throws
}

@MainActor
final class SystemNotificationCenter: NotificationCenterProtocol {
    static let shared = SystemNotificationCenter()

    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    var delegate: UNUserNotificationCenterDelegate? {
        get { center.delegate }
        set { center.delegate = newValue }
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await center.requestAuthorization(options: options)
    }

    func notificationSettings() async -> AppNotificationSettings {
        let settings = await center.notificationSettings()
        return AppNotificationSettings(
            authorizationStatus: settings.authorizationStatus,
            alertSetting: settings.alertSetting
        )
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await center.add(request)
    }
}

@MainActor
final class AppState: NSObject, ObservableObject {
    @Published var selectedSection: SidebarSection = .connection
    @Published var backendStatus = BackendStatus.placeholder
    @Published var monitoringState = MonitoringState.placeholder
    @Published var notificationSettings = NotificationSettingsState.defaultState
    @Published var modelCatalog = ModelCatalog.placeholder
    @Published var backendLaunchError: String?
    @Published var isLoading = false
    @Published var frameHistory: [LiveFrameSample] = []
    @Published var notificationAuthorizationSummary = "確認中"
    @Published var isNightModeEnabled = UserDefaults.standard.bool(forKey: "postchair.nightModeEnabled")

    private let backendClient: BackendClientProtocol
    private let processManager: any BackendProcessManaging
    private var notificationCenter: NotificationCenterProtocol
    private var didPrepare = false
    private var pollingTask: Task<Void, Never>?
    private var lastDeliveredNotificationSequence = 0
    private var lastRecordedFrameTimestamp: String?

    override init() {
        self.backendClient = BackendClient()
        self.processManager = BackendProcessManager()
        self.notificationCenter = SystemNotificationCenter.shared
        super.init()
    }

    init(
        backendClient: BackendClientProtocol,
        processManager: any BackendProcessManaging,
        notificationCenter: NotificationCenterProtocol
    ) {
        self.backendClient = backendClient
        self.processManager = processManager
        self.notificationCenter = notificationCenter
        super.init()
    }

    var menuBarTitle: String {
        switch monitoringState.resolvedConnectionState {
        case .connected:
            if let label = currentLabelName {
                return "Postchair · \(label)"
            }
            return "Postchair · 接続中"
        case .connecting, .starting:
            return "Postchair · 接続準備中"
        case .error:
            return "Postchair · エラー"
        case .stopped:
            return "Postchair · 停止中"
        }
    }

    var menuBarSymbol: String {
        switch monitoringState.resolvedConnectionState {
        case .connected:
            return "figure.seated.side.right"
        case .connecting, .starting:
            return "dot.radiowaves.left.and.right"
        case .error:
            return "exclamationmark.triangle"
        case .stopped:
            return "pause.circle"
        }
    }

    var currentLabelName: String? {
        resolvedLabelName(
            for: monitoringState.latestLabelID,
            backendName: monitoringState.latestLabelMetadata?.name
        )
    }

    var postureStatusItems: [PostureStatusItem] {
        notificationSettings.labelConfigurations.map {
            PostureStatusItem(
                id: $0.id,
                name: $0.name,
                severity: $0.severity,
                isActive: monitoringState.latestLabelID == $0.id
            )
        }
    }

    var frameAverage: (center: Int, left: Int, rear: Int, right: Int)? {
        guard !frameHistory.isEmpty else { return nil }
        let count = frameHistory.count
        return (
            center: frameHistory.map(\.center).reduce(0, +) / count,
            left: frameHistory.map(\.left).reduce(0, +) / count,
            rear: frameHistory.map(\.rear).reduce(0, +) / count,
            right: frameHistory.map(\.right).reduce(0, +) / count
        )
    }

    func prepareIfNeeded() async {
        guard !didPrepare else { return }
        didPrepare = true
        isLoading = true
        notificationCenter.delegate = self
        await requestNotificationPermission()
        do {
            try await processManager.startIfNeeded()
            backendLaunchError = nil
        } catch {
            backendLaunchError = error.localizedDescription
        }
        await refreshAll()
        await refreshModelCatalog()
        startPolling()
        isLoading = false
    }

    func shutdown() async {
        pollingTask?.cancel()
        pollingTask = nil
        await processManager.stopOwnedProcess()
    }

    func startMonitoring() async {
        do {
            _ = try await backendClient.startMonitoring()
            await refreshMonitoringState()
        } catch {
            backendLaunchError = error.localizedDescription
        }
    }

    func stopMonitoring() async {
        do {
            _ = try await backendClient.stopMonitoring()
            await refreshMonitoringState()
        } catch {
            backendLaunchError = error.localizedDescription
        }
    }

    func updateNotifications(
        enabled: Bool? = nil,
        thresholdSeconds: Int? = nil,
        enabledLabelIDs: [Int]? = nil,
        focusMode: String? = nil
    ) async {
        do {
            let updated = try await backendClient.updateNotificationSettings(
                enabled: enabled ?? notificationSettings.enabled,
                thresholdSeconds: thresholdSeconds ?? notificationSettings.thresholdSeconds,
                enabledLabelIDs: enabledLabelIDs ?? notificationSettings.enabledLabelIDs,
                focusMode: focusMode ?? notificationSettings.focusMode
            )
            notificationSettings = NotificationSettingsState(payload: updated)
        } catch {
            backendLaunchError = error.localizedDescription
        }
    }

    func toggleLabel(_ labelID: Int, isEnabled: Bool) async {
        var ids = Set(notificationSettings.enabledLabelIDs)
        if isEnabled {
            ids.insert(labelID)
        } else {
            ids.remove(labelID)
        }
        await updateNotifications(enabledLabelIDs: ids.sorted())
    }

    func openDashboardWindow() {
        NSApp.activate(ignoringOtherApps: true)
    }

    func selectModel(filename: String) async {
        do {
            modelCatalog = try await backendClient.updateSelectedModel(filename: filename)
            await refreshBackendStatus()
            await refreshMonitoringState()
        } catch {
            backendLaunchError = error.localizedDescription
        }
    }

    func refreshNow() async {
        await refreshAll()
    }

    func setNightModeEnabled(_ value: Bool) {
        isNightModeEnabled = value
        UserDefaults.standard.set(value, forKey: "postchair.nightModeEnabled")
    }

    func sendTestNotification() async {
        guard await ensureNotificationPermission() else { return }
        let content = UNMutableNotificationContent()
        content.title = "Postchair テスト通知"
        content.body = "通知設定は正常です。"
        content.sound = .default
        let request = UNNotificationRequest(identifier: "postchair-test", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func startPolling() {
        pollingTask?.cancel()
        pollingTask = Task {
            while !Task.isCancelled {
                await refreshLiveState()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func refreshAll() async {
        await refreshBackendStatus()
        await refreshMonitoringState()
        await refreshNotificationSettings()
    }

    private func refreshBackendStatus() async {
        do {
            backendStatus = try await backendClient.fetchBackendStatus()
            backendLaunchError = backendStatus.lastError
        } catch {
            backendLaunchError = error.localizedDescription
        }
    }

    private func refreshMonitoringState() async {
        do {
            monitoringState = try await backendClient.fetchMonitoringState()
            recordHistoryIfNeeded()
            if monitoringState.lastError == nil, backendStatus.lastError == nil {
                backendLaunchError = nil
            }
            await deliverNotificationIfNeeded(from: monitoringState.notificationEvent)
        } catch {
            backendLaunchError = error.localizedDescription
        }
    }

    private func refreshNotificationSettings() async {
        do {
            let payload = try await backendClient.fetchNotificationSettings()
            notificationSettings = NotificationSettingsState(payload: payload)
        } catch {
            backendLaunchError = error.localizedDescription
        }
    }

    private func refreshLiveState() async {
        await refreshBackendStatus()
        await refreshMonitoringState()
    }

    private func refreshModelCatalog() async {
        do {
            modelCatalog = try await backendClient.fetchModelCatalog()
        } catch {
            backendLaunchError = error.localizedDescription
        }
    }

    func deliverNotificationIfNeeded(from event: NotificationEventPayload) async {
        guard event.sequence > lastDeliveredNotificationSequence else { return }
        guard notificationSettings.enabled else { return }
        guard let labelID = event.labelID else { return }
        guard notificationSettings.enabledLabelIDs.contains(labelID) else { return }
        guard let labelName = resolvedLabelName(for: event.labelID, backendName: event.label?.name) else { return }
        let settings = await notificationCenter.notificationSettings()
        guard isNotificationAuthorized(settings.authorizationStatus) else { return }
        guard settings.alertSetting != .disabled else { return }

        let content = UNMutableNotificationContent()
        content.title = "姿勢アラート"
        content.body = "\(labelName) が継続しています。姿勢を戻してください。"
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "postchair-\(event.sequence)",
            content: content,
            trigger: nil
        )
        do {
            try await notificationCenter.add(request)
            lastDeliveredNotificationSequence = event.sequence
        } catch {
            backendLaunchError = "ローカル通知の登録に失敗しました: \(error.localizedDescription)"
        }
    }

    private func resolvedLabelName(for labelID: Int?, backendName: String?) -> String? {
        if let labelID,
           let localName = notificationSettings.labelConfigurations.first(where: { $0.id == labelID })?.name {
            return localName
        }
        return backendName
    }

    private func requestNotificationPermission() async {
        _ = await ensureNotificationPermission()
    }

    private func ensureNotificationPermission() async -> Bool {
        notificationCenter.delegate = self
        _ = try? await notificationCenter.requestAuthorization(options: [.alert, .sound, .badge])
        let settings = await notificationCenter.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            notificationAuthorizationSummary = "許可済み"
            return true
        case .denied:
            notificationAuthorizationSummary = "拒否"
            return false
        case .notDetermined:
            notificationAuthorizationSummary = "未決定"
            return false
        @unknown default:
            notificationAuthorizationSummary = "不明"
            return false
        }
    }

    private func isNotificationAuthorized(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied, .notDetermined:
            return false
        @unknown default:
            return false
        }
    }

    private func recordHistoryIfNeeded() {
        guard let frame = monitoringState.latestFrame else { return }
        guard !frame.receivedAt.isEmpty else { return }
        guard frame.receivedAt != lastRecordedFrameTimestamp else { return }

        lastRecordedFrameTimestamp = frame.receivedAt
        frameHistory.append(LiveFrameSample(frame: frame))
        if frameHistory.count > 120 {
            frameHistory.removeFirst(frameHistory.count - 120)
        }
    }

    var deliveredNotificationSequenceForTesting: Int {
        lastDeliveredNotificationSequence
    }
}

extension AppState: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
