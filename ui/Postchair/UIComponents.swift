import SwiftUI

enum AppColors {
    static func pageBackgroundTop(nightMode: Bool) -> Color {
        nightMode ? Color(red: 0.10, green: 0.13, blue: 0.22) : Color(red: 0.95, green: 0.97, blue: 1.0)
    }

    static func pageBackgroundBottom(nightMode: Bool) -> Color {
        nightMode ? Color(red: 0.07, green: 0.09, blue: 0.16) : Color(red: 0.90, green: 0.93, blue: 0.98)
    }

    static func cardBackground(nightMode: Bool) -> Color {
        nightMode ? Color.white.opacity(0.10) : Color.white.opacity(0.84)
    }

    static func cardBorder(nightMode: Bool) -> Color {
        nightMode ? Color.white.opacity(0.10) : Color.white.opacity(0.72)
    }

    static func bodyText(nightMode: Bool) -> Color {
        nightMode ? Color.white.opacity(0.92) : Color(red: 0.16, green: 0.20, blue: 0.28)
    }

    static func secondaryText(nightMode: Bool) -> Color {
        nightMode ? Color(red: 0.72, green: 0.76, blue: 0.85) : Color(red: 0.47, green: 0.53, blue: 0.64)
    }

    static func sidebarSelection(nightMode: Bool) -> Color {
        nightMode ? Color.white.opacity(0.10) : Color.white.opacity(0.62)
    }
}

extension AppAccent {
    var color: Color {
        switch self {
        case .blue: return Color(red: 0.22, green: 0.62, blue: 0.97)
        case .cyan: return Color(red: 0.16, green: 0.74, blue: 0.96)
        case .green: return Color(red: 0.14, green: 0.80, blue: 0.58)
        case .indigo: return Color(red: 0.48, green: 0.55, blue: 0.98)
        case .sky: return Color(red: 0.05, green: 0.60, blue: 0.98)
        case .violet: return Color(red: 0.62, green: 0.38, blue: 0.95)
        }
    }
}

struct FrostedBackground: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        LinearGradient(
            colors: [
                AppColors.pageBackgroundTop(nightMode: appState.isNightModeEnabled),
                AppColors.pageBackgroundBottom(nightMode: appState.isNightModeEnabled),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(
            VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                .opacity(0.5)
        )
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(Color.white.opacity(0.35))
                .frame(width: 420, height: 420)
                .blur(radius: 80)
                .offset(x: 120, y: -160)
        }
    }
}

struct SurfaceCard<Content: View>: View {
    @EnvironmentObject private var appState: AppState
    let accent: AppAccent
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            content
        }
        .padding(32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(AppColors.cardBackground(nightMode: appState.isNightModeEnabled))
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(AppColors.cardBorder(nightMode: appState.isNightModeEnabled), lineWidth: 1)
                )
                .shadow(color: accent.color.opacity(0.08), radius: 22, y: 10)
                .shadow(color: .black.opacity(0.04), radius: 14, y: 8)
        )
    }
}

struct SidebarButton: View {
    @EnvironmentObject private var appState: AppState
    let section: SidebarSection
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: section.icon)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(isSelected ? section.accent.color : AppColors.secondaryText(nightMode: appState.isNightModeEnabled))
                    .frame(width: 28)
                Text(section.title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(AppColors.bodyText(nightMode: appState.isNightModeEnabled))
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(isSelected ? AppColors.sidebarSelection(nightMode: appState.isNightModeEnabled) : .clear)
            )
        }
        .buttonStyle(.plain)
    }
}

struct SectionHeaderView: View {
    @EnvironmentObject private var appState: AppState
    let section: SidebarSection

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.title)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(AppColors.bodyText(nightMode: appState.isNightModeEnabled))
            Text(section.subtitle)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AppColors.secondaryText(nightMode: appState.isNightModeEnabled))
        }
    }
}

struct MetricRow: View {
    @EnvironmentObject private var appState: AppState
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(AppColors.secondaryText(nightMode: appState.isNightModeEnabled))
            Spacer()
            Text(value)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(AppColors.bodyText(nightMode: appState.isNightModeEnabled))
        }
    }
}

struct PlaceholderChip: View {
    @EnvironmentObject private var appState: AppState
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(AppColors.secondaryText(nightMode: appState.isNightModeEnabled))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(appState.isNightModeEnabled ? Color.white.opacity(0.08) : Color.white.opacity(0.7))
                    .overlay(Capsule(style: .continuous).stroke(Color.gray.opacity(0.12), lineWidth: 1))
            )
    }
}

struct SparklineView: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            if values.count > 1 {
                let maxValue = max(values.max() ?? 1, 1)
                let minValue = values.min() ?? 0
                let range = max(maxValue - minValue, 1)

                Path { path in
                    for (index, value) in values.enumerated() {
                        let x = geometry.size.width * CGFloat(index) / CGFloat(max(values.count - 1, 1))
                        let normalized = (value - minValue) / range
                        let y = geometry.size.height * (1 - CGFloat(normalized))
                        if index == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(height: 70)
    }
}
