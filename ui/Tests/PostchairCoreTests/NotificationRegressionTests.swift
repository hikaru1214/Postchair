import Foundation
import UserNotifications
import XCTest
@testable import PostchairCore

private actor FakeProcessManager: BackendProcessManaging {
    func startIfNeeded() async throws {}
    func stopOwnedProcess() async {}
}

private struct FakeBackendClient: BackendClientProtocol {
    func fetchBackendStatus() async throws -> BackendStatus { .placeholder }
    func fetchMonitoringState() async throws -> MonitoringState { .placeholder }
    func startMonitoring() async throws -> MonitoringState { .placeholder }
    func stopMonitoring() async throws -> MonitoringState { .placeholder }
    func fetchNotificationSettings() async throws -> NotificationSettingsPayload { .defaultPayload }
    func fetchModelCatalog() async throws -> ModelCatalog { .placeholder }
    func updateNotificationSettings(
        enabled: Bool,
        thresholdSeconds: Int,
        enabledLabelIDs: [Int],
        focusMode: String
    ) async throws -> NotificationSettingsPayload {
        NotificationSettingsPayload(
            enabled: enabled,
            thresholdSeconds: thresholdSeconds,
            enabledLabelIDs: enabledLabelIDs,
            focusMode: focusMode
        )
    }
    func updateSelectedModel(filename: String) async throws -> ModelCatalog { .placeholder }
    func updateTrainingRecordingLabel(labelID: Int?) async throws -> TrainingSessionState { .empty }
    func completeTrainingSession(modelName: String) async throws -> (ModelCatalog, TrainingResult) {
        (.placeholder, TrainingResult(modelName: modelName, modelFilename: "", dataFilename: "", sampleCount: 0, accuracyText: nil))
    }
}

private enum FakeNotificationError: LocalizedError {
    case failed

    var errorDescription: String? { "fake failure" }
}

private final class FakeNotificationCenter: NotificationCenterProtocol {
    var delegate: UNUserNotificationCenterDelegate?
    var settings: AppNotificationSettings
    var addCallCount = 0
    var requests: [UNNotificationRequest] = []
    var shouldFailAdd = false

    init(
        settings: AppNotificationSettings = AppNotificationSettings(
            authorizationStatus: .authorized,
            alertSetting: .enabled
        )
    ) {
        self.settings = settings
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        true
    }

    func notificationSettings() async -> AppNotificationSettings {
        settings
    }

    func add(_ request: UNNotificationRequest) async throws {
        addCallCount += 1
        if shouldFailAdd {
            throw FakeNotificationError.failed
        }
        requests.append(request)
    }
}

final class NotificationRegressionTests: XCTestCase {
    @MainActor
    func testNotificationSettingsBodyUsesSnakeCaseKeys() throws {
        let client = BackendClient()

        let body = try client.makeNotificationSettingsBody(
            enabled: true,
            thresholdSeconds: 25,
            enabledLabelIDs: [2, 4],
            focusMode: "indicator_only"
        )

        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(json["enabled"] as? Bool, true)
        XCTAssertEqual(json["threshold_seconds"] as? Int, 25)
        XCTAssertEqual(json["enabled_label_ids"] as? [Int], [2, 4])
        XCTAssertEqual(json["focus_mode"] as? String, "indicator_only")
        XCTAssertNil(json["thresholdSeconds"])
        XCTAssertNil(json["enabledLabelIDs"])
    }

    @MainActor
    func testNotificationSequenceAdvancesOnlyAfterSuccessfulDelivery() async {
        let notificationCenter = FakeNotificationCenter()
        let appState = AppState(
            backendClient: FakeBackendClient(),
            processManager: FakeProcessManager(),
            notificationCenter: notificationCenter
        )
        let event = NotificationEventPayload(
            sequence: 1,
            labelID: 2,
            label: LabelMetadata(id: 2, name: "猫背", severity: "warning"),
            triggeredAt: "2026-03-20T00:00:00Z"
        )

        await appState.deliverNotificationIfNeeded(from: event)
        await appState.deliverNotificationIfNeeded(from: event)

        XCTAssertEqual(notificationCenter.addCallCount, 1)
        XCTAssertEqual(appState.deliveredNotificationSequenceForTesting, 1)
        XCTAssertEqual(notificationCenter.requests.first?.content.title, "姿勢アラート")
    }

    @MainActor
    func testNotificationFailureDoesNotConsumeSequence() async {
        let notificationCenter = FakeNotificationCenter()
        notificationCenter.shouldFailAdd = true
        let appState = AppState(
            backendClient: FakeBackendClient(),
            processManager: FakeProcessManager(),
            notificationCenter: notificationCenter
        )
        let event = NotificationEventPayload(
            sequence: 3,
            labelID: 2,
            label: LabelMetadata(id: 2, name: "猫背", severity: "warning"),
            triggeredAt: "2026-03-20T00:00:00Z"
        )

        await appState.deliverNotificationIfNeeded(from: event)
        await appState.deliverNotificationIfNeeded(from: event)

        XCTAssertEqual(notificationCenter.addCallCount, 2)
        XCTAssertEqual(appState.deliveredNotificationSequenceForTesting, 0)
        XCTAssertEqual(appState.backendLaunchError, "ローカル通知の登録に失敗しました: fake failure")
    }

    @MainActor
    func testUnauthorizedNotificationDoesNotConsumeSequenceAndCanRetryLater() async {
        let notificationCenter = FakeNotificationCenter(
            settings: AppNotificationSettings(
                authorizationStatus: .denied,
                alertSetting: .disabled
            )
        )
        let appState = AppState(
            backendClient: FakeBackendClient(),
            processManager: FakeProcessManager(),
            notificationCenter: notificationCenter
        )
        let event = NotificationEventPayload(
            sequence: 4,
            labelID: 2,
            label: LabelMetadata(id: 2, name: "猫背", severity: "warning"),
            triggeredAt: "2026-03-20T00:00:00Z"
        )

        await appState.deliverNotificationIfNeeded(from: event)
        XCTAssertEqual(notificationCenter.addCallCount, 0)
        XCTAssertEqual(appState.deliveredNotificationSequenceForTesting, 0)

        notificationCenter.settings = AppNotificationSettings(
            authorizationStatus: .authorized,
            alertSetting: .enabled
        )
        await appState.deliverNotificationIfNeeded(from: event)

        XCTAssertEqual(notificationCenter.addCallCount, 1)
        XCTAssertEqual(appState.deliveredNotificationSequenceForTesting, 4)
    }

    func testHealthyLaunchStateReturnsWithoutError() {
        XCTAssertNoThrow(
            try BackendProcessManager.validateLaunchState(
                isHealthy: true,
                processIsRunning: true,
                stderrText: "ignored"
            )
        )
    }

    func testUnhealthyRunningLaunchStateThrowsExpectedMessage() {
        XCTAssertThrowsError(
            try BackendProcessManager.validateLaunchState(
                isHealthy: false,
                processIsRunning: true,
                stderrText: "stderr"
            )
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "バックエンドは起動中ですが、ヘルスチェックに応答しませんでした。"
            )
        }
    }
}

private extension NotificationSettingsPayload {
    static let defaultPayload = NotificationSettingsPayload(
        enabled: true,
        thresholdSeconds: 60,
        enabledLabelIDs: [2, 3, 4, 5],
        focusMode: "indicator_only"
    )
}
