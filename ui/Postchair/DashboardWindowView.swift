import Combine
import SwiftUI

struct DashboardWindowView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ZStack {
            FrostedBackground()
                .ignoresSafeArea()

            HStack(spacing: 0) {
                sidebar
                Divider()
                    .background(Color.white.opacity(0.55))
                    .padding(.vertical, 54)
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        SectionHeaderView(section: appState.selectedSection)
                        sectionContent
                    }
                    .padding(.horizontal, 54)
                    .padding(.vertical, 52)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(28)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
                .frame(height: 56)
            Text("設定")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AppColors.secondaryText(nightMode: appState.isNightModeEnabled).opacity(0.7))
                .padding(.horizontal, 18)
                .padding(.bottom, 22)

            ForEach(SidebarSection.allCases) { section in
                SidebarButton(section: section, isSelected: section == appState.selectedSection) {
                    appState.selectedSection = section
                }
            }
            Spacer()
        }
        .frame(width: 330, alignment: .topLeading)
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch appState.selectedSection {
        case .connection:
            ConnectionSectionView()
        case .notifications:
            NotificationSectionView()
        case .model:
            ModelSectionView()
        case .modelCreation:
            ModelCreationSectionView()
        case .about:
            AboutSectionView()
        }
    }
}

struct MenuBarContentView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(appState.menuBarTitle)
                .font(.headline)
            if let error = appState.backendLaunchError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Button("ダッシュボードを開く") {
                openWindow(id: "dashboard")
                appState.openDashboardWindow()
            }
            Button(appState.monitoringState.active ? "監視を停止" : "監視を開始") {
                Task {
                    if appState.monitoringState.active {
                        await appState.stopMonitoring()
                    } else {
                        await appState.startMonitoring()
                    }
                }
            }
            Divider()
            Button("終了") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(10)
        .frame(width: 260)
    }
}

struct ConnectionSectionView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 24) {
            SurfaceCard(accent: .blue) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("バックエンドと BLE 接続")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(AppColors.bodyText(nightMode: appState.isNightModeEnabled))
                        Text("Python サービスを常駐起動し、ESP32 の姿勢データを監視します")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(AppColors.secondaryText(nightMode: appState.isNightModeEnabled))
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { appState.monitoringState.active },
                        set: { isOn in
                            Task {
                                if isOn {
                                    await appState.startMonitoring()
                                } else {
                                    await appState.stopMonitoring()
                                }
                            }
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(SidebarSection.connection.accent.color)
                }
            }

            SurfaceCard(accent: .blue) {
                MetricRow(title: "接続状態", value: label(for: appState.monitoringState.resolvedConnectionState))
                MetricRow(title: "デバイス名", value: appState.monitoringState.deviceName)
                MetricRow(title: "BLE アドレス", value: appState.monitoringState.deviceAddress ?? "未接続")
                MetricRow(title: "現在の姿勢", value: appState.currentLabelName ?? "未判定")
                MetricRow(title: "最終フレーム", value: appState.monitoringState.lastFrameAt ?? "未受信")
                if let error = appState.backendLaunchError ?? appState.monitoringState.lastError {
                    Divider()
                    Text(error)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.red.opacity(0.8))
                }
            }

            if let frame = appState.monitoringState.latestFrame {
                SurfaceCard(accent: .blue) {
                    Text("センサーライブ値")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(AppColors.bodyText(nightMode: appState.isNightModeEnabled))
                    HStack(spacing: 18) {
                        sensorCard(title: "Center", value: frame.center)
                        sensorCard(title: "Left", value: frame.leftFoot)
                        sensorCard(title: "Rear", value: frame.rear)
                        sensorCard(title: "Right", value: frame.rightFoot)
                    }
                }
            }
        }
    }

    private func label(for state: ConnectionState) -> String {
        switch state {
        case .starting: return "起動中"
        case .connecting: return "接続待機"
        case .connected: return "接続中"
        case .error: return "エラー"
        case .stopped: return "停止中"
        }
    }

    private func sensorCard(title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(AppColors.secondaryText(nightMode: appState.isNightModeEnabled))
            Text("\(value)")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(AppColors.bodyText(nightMode: appState.isNightModeEnabled))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(appState.isNightModeEnabled ? Color.white.opacity(0.06) : Color.white.opacity(0.55))
        )
    }
}

struct NotificationSectionView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 24) {
            SurfaceCard(accent: .cyan) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("通知を有効にする")
                            .font(.system(size: 21, weight: .bold))
                            .foregroundStyle(AppColors.bodyText(nightMode: appState.isNightModeEnabled))
                        Text("macOS 標準通知で姿勢悪化をお知らせします")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(AppColors.secondaryText(nightMode: appState.isNightModeEnabled))
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { appState.notificationSettings.enabled },
                        set: { value in
                            Task { await appState.updateNotifications(enabled: value) }
                        }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .tint(SidebarSection.notifications.accent.color)
                }
            }

            SurfaceCard(accent: .cyan) {
                HStack {
                    Text("通知までの継続時間")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(AppColors.bodyText(nightMode: appState.isNightModeEnabled))
                    Spacer()
                    Text("\(appState.notificationSettings.thresholdSeconds)秒")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(AppColors.secondaryText(nightMode: appState.isNightModeEnabled))
                }

                Slider(
                    value: Binding(
                        get: { Double(appState.notificationSettings.thresholdSeconds) },
                        set: { value in
                            Task { await appState.updateNotifications(thresholdSeconds: Int(value.rounded())) }
                        }
                    ),
                    in: 10 ... 180,
                    step: 5
                )
                .tint(SidebarSection.notifications.accent.color)

                HStack {
                    Text("10秒")
                    Spacer()
                    Text("3分")
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppColors.secondaryText(nightMode: appState.isNightModeEnabled).opacity(0.55))

                Divider()

                Text("通知する姿勢")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(AppColors.secondaryText(nightMode: appState.isNightModeEnabled))

                ForEach(appState.notificationSettings.labelConfigurations) { label in
                    HStack {
                        Text(label.name)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(AppColors.bodyText(nightMode: appState.isNightModeEnabled))
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { appState.notificationSettings.enabledLabelIDs.contains(label.id) },
                            set: { value in
                                Task { await appState.toggleLabel(label.id, isEnabled: value) }
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(SidebarSection.notifications.accent.color)
                    }
                }
            }

            SurfaceCard(accent: .cyan) {
                Text("通知状態")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(AppColors.bodyText(nightMode: appState.isNightModeEnabled))
                MetricRow(title: "通知許可", value: appState.notificationAuthorizationSummary)
                MetricRow(title: "現在の姿勢", value: appState.currentLabelName ?? "未判定")
                MetricRow(title: "最終通知", value: appState.monitoringState.notificationEvent.triggeredAt ?? "未通知")
                MetricRow(
                    title: "通知対象数",
                    value: "\(appState.notificationSettings.enabledLabelIDs.count)姿勢"
                )
                Text("設定した継続時間の中で、同じ悪姿勢が全ログの80%以上を占めたときだけ通知します。猫背と前傾姿勢の合算では通知しません。比率が80%未満に戻ると、次回は再通知されます。")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AppColors.secondaryText(nightMode: appState.isNightModeEnabled))

                Button("テスト通知を送る") {
                    Task {
                        await appState.sendTestNotification()
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(SidebarSection.notifications.accent.color.opacity(0.12))
                )
            }
        }
    }
}

struct ModelSectionView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 24) {
            SurfaceCard(accent: .green) {
                HStack(spacing: 20) {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(SidebarSection.model.accent.color.opacity(0.12))
                        .frame(width: 82, height: 82)
                        .overlay(
                            Image(systemName: appState.modelCatalog.modelLoaded ? "checkmark.circle" : "xmark.circle")
                                .font(.system(size: 38, weight: .medium))
                                .foregroundStyle(SidebarSection.model.accent.color)
                        )
                    VStack(alignment: .leading, spacing: 8) {
                        Text(appState.modelCatalog.currentModelDisplayName)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(AppColors.bodyText(nightMode: appState.isNightModeEnabled))
                        Text("Python 推論モデル")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(AppColors.secondaryText(nightMode: appState.isNightModeEnabled))
                    }
                }
                Divider()
                MetricRow(title: "現在選択中", value: appState.modelCatalog.currentModelFilename ?? "未選択")
                MetricRow(title: "モデル読込状態", value: appState.modelCatalog.modelLoaded ? "読み込み済み" : "未読込")
                MetricRow(title: "推論エンジン", value: "Python / scikit-learn")
            }

            SurfaceCard(accent: .green) {
                Text("利用可能なモデル")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(AppColors.bodyText(nightMode: appState.isNightModeEnabled))
                Text("バックエンドの `models` ディレクトリにある `.joblib` を切り替えます")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppColors.secondaryText(nightMode: appState.isNightModeEnabled))

                if appState.modelCatalog.availableModels.isEmpty {
                    Text("利用可能なモデルが見つかりません")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AppColors.secondaryText(nightMode: appState.isNightModeEnabled))
                } else {
                    ForEach(appState.modelCatalog.availableModels) { model in
                        HStack(spacing: 18) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(model.displayName)
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(AppColors.bodyText(nightMode: appState.isNightModeEnabled))
                                Text("\(model.filename) • \(model.fileSize)")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(AppColors.secondaryText(nightMode: appState.isNightModeEnabled))
                            }
                            Spacer()
                            if model.isLoaded {
                                PlaceholderChip(text: "読込中")
                            }
                            Button(model.isSelected ? "選択中" : "このモデルを使う") {
                                Task {
                                    await appState.selectModel(filename: model.filename)
                                }
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(model.isSelected ? SidebarSection.model.accent.color.opacity(0.18) : SidebarSection.model.accent.color.opacity(0.10))
                            )
                            .foregroundStyle(model.isSelected ? SidebarSection.model.accent.color : AppColors.bodyText(nightMode: appState.isNightModeEnabled))
                            .disabled(model.isSelected)
                        }
                    }
                }

                if let error = appState.modelCatalog.lastError {
                    Divider()
                    Text(error)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.red.opacity(0.8))
                }
            }
        }
    }
}

struct ModelCreationSectionView: View {
    @EnvironmentObject private var appState: AppState

    private var activeLabelID: Int? {
        appState.trainingSession.activeLabelID
    }

    private var canEditControls: Bool {
        appState.monitoringState.active && !appState.isTrainingModel
    }

    private var canStartTraining: Bool {
        canEditControls
            && activeLabelID == nil
            && appState.trainingSession.totalSamples > 0
            && !appState.modelTrainingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 24) {
            SurfaceCard(accent: .indigo) {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("姿勢データ収集")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(AppColors.bodyText(nightMode: appState.isNightModeEnabled))
                        Text("1つだけ ON にして記録し、切り替えるときは一度 OFF に戻してください")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(AppColors.secondaryText(nightMode: appState.isNightModeEnabled))
                    }
                    Spacer()
                    PlaceholderChip(text: appState.monitoringState.active ? "監視中" : "監視停止")
                }

                ForEach(TrainingLabelOption.allCases) { label in
                    Button {
                        Task {
                            await appState.setTrainingRecordingLabel(
                                activeLabelID == label.id ? nil : label.id
                            )
                        }
                    } label: {
                        HStack(spacing: 18) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(label.name)
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(AppColors.bodyText(nightMode: appState.isNightModeEnabled))
                                Text("\(sampleCount(for: label.id))サンプル")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(AppColors.secondaryText(nightMode: appState.isNightModeEnabled))
                            }
                            Spacer()
                            HStack(spacing: 8) {
                                Image(systemName: activeLabelID == label.id ? "pause.fill" : "record.circle")
                                    .font(.system(size: 14, weight: .bold))
                                Text(activeLabelID == label.id ? "停止" : "記録開始")
                                    .font(.system(size: 14, weight: .bold))
                            }
                            .foregroundStyle(activeLabelID == label.id ? Color.white : SidebarSection.modelCreation.accent.color)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(
                                        activeLabelID == label.id
                                            ? SidebarSection.modelCreation.accent.color
                                            : SidebarSection.modelCreation.accent.color.opacity(0.14)
                                    )
                            )
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .fill(
                                    activeLabelID == label.id
                                        ? SidebarSection.modelCreation.accent.color.opacity(0.12)
                                        : (appState.isNightModeEnabled ? Color.white.opacity(0.04) : Color.white.opacity(0.56))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                                        .stroke(
                                            activeLabelID == label.id
                                                ? SidebarSection.modelCreation.accent.color.opacity(0.35)
                                                : AppColors.cardBorder(nightMode: appState.isNightModeEnabled),
                                            lineWidth: 1
                                        )
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!isToggleEnabled(for: label.id))
                    .opacity(isToggleEnabled(for: label.id) ? 1 : 0.55)
                }

                if !appState.monitoringState.active {
                    Text("データ収集前に、接続セクションで監視を開始してください。")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.red.opacity(0.8))
                }
            }

            SurfaceCard(accent: .indigo) {
                Text("収集状態")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(AppColors.bodyText(nightMode: appState.isNightModeEnabled))
                MetricRow(title: "現在記録中", value: appState.trainingSession.activeLabel?.name ?? "なし")
                MetricRow(title: "総サンプル数", value: "\(appState.trainingSession.totalSamples)")
                MetricRow(title: "開始時刻", value: appState.trainingSession.startedAt ?? "未開始")
                MetricRow(title: "最終記録", value: appState.trainingSession.lastRecordedAt ?? "未記録")

                if let error = appState.trainingSession.lastTrainingError {
                    Divider()
                    Text(error)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.red.opacity(0.8))
                }
            }

            SurfaceCard(accent: .indigo) {
                Text("モデル学習")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(AppColors.bodyText(nightMode: appState.isNightModeEnabled))

                TextField("モデル名", text: $appState.modelTrainingName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 16, weight: .medium))
                    .disabled(!canEditControls)

                if let message = appState.trainingMessage {
                    Text(message)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(message.contains("学習完了") ? SidebarSection.modelCreation.accent.color : Color.red.opacity(0.8))
                }

                Button {
                    Task {
                        await appState.completeTrainingSession()
                    }
                } label: {
                    HStack(spacing: 12) {
                        if appState.isTrainingModel {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(appState.isTrainingModel ? "学習中..." : "完了して学習")
                            .font(.system(size: 17, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(SidebarSection.modelCreation.accent.color.opacity(canStartTraining ? 0.18 : 0.08))
                    )
                }
                .buttonStyle(.plain)
                .foregroundStyle(canStartTraining ? SidebarSection.modelCreation.accent.color : AppColors.secondaryText(nightMode: appState.isNightModeEnabled))
                .disabled(!canStartTraining)

                Text("学習前にすべてのトグルを OFF に戻してください。今回の収集データだけで新しいモデルを作成します。")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppColors.secondaryText(nightMode: appState.isNightModeEnabled))
            }
        }
    }

    private func sampleCount(for labelID: Int) -> Int {
        appState.trainingSession.samplesByLabelID[String(labelID)] ?? 0
    }

    private func isToggleEnabled(for labelID: Int) -> Bool {
        guard canEditControls else { return false }
        if let activeLabelID {
            return activeLabelID == labelID
        }
        return true
    }
}

struct AboutSectionView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 24) {
            SurfaceCard(accent: .sky) {
                VStack(spacing: 22) {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.75), SidebarSection.about.accent.color.opacity(0.20)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 124, height: 124)
                        .overlay(
                            Image(systemName: "figure.seated.side")
                                .font(.system(size: 50, weight: .light))
                                .foregroundStyle(SidebarSection.about.accent.color)
                        )
                    Text("Postchair")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(AppColors.bodyText(nightMode: appState.isNightModeEnabled))
                    Text("バージョン \(appState.backendStatus.version)")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(AppColors.secondaryText(nightMode: appState.isNightModeEnabled))
                }
                .frame(maxWidth: .infinity)
            }

            SurfaceCard(accent: .sky) {
                MetricRow(title: "バックエンド", value: "Python localhost API")
                MetricRow(title: "BLE フレームワーク", value: "Bleak")
                MetricRow(title: "ハードウェア", value: "ESP32 + FSR x4")
                MetricRow(title: "メニューバー動作", value: "有効")
                MetricRow(title: "バックエンド状態", value: appState.backendStatus.running ? "稼働中" : "停止")
                MetricRow(title: "通知許可", value: appState.notificationAuthorizationSummary)
                MetricRow(title: "現在モデル", value: appState.modelCatalog.currentModelDisplayName)
            }
        }
    }
}
