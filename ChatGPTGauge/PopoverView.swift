import AppKit
import SwiftUI

struct PopoverView: View {
    @ObservedObject var monitor: UsageMonitor
    @State private var contentHeight: CGFloat = 720

    private var maxPanelHeight: CGFloat {
        let available = (NSScreen.main?.visibleFrame.height ?? 900) - 28
        return min(860, max(560, available))
    }

    private var panelHeight: CGFloat {
        min(max(contentHeight, 420), maxPanelHeight)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                ForEach(monitor.accounts) { account in
                    AccountSection(account: account, now: monitor.now)
                }
                if monitor.showBattery {
                    batterySection
                }
                footer
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                }
            }
        }
        .scrollDisabled(contentHeight <= maxPanelHeight)
        .frame(width: 440, height: panelHeight)
        .onPreferenceChange(ContentHeightKey.self) { newHeight in
            guard newHeight > 80 else { return }
            contentHeight = newHeight
        }
        .environment(\.layoutDirection, monitor.appLanguage.layoutDirection)
        .onAppear { monitor.start() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.s(.usage))
                    .font(.headline)
                Text(L10n.s(.usageSubtitle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                monitor.reload(userInitiated: true)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
                    .opacity(monitor.isRefreshing ? 0.35 : 1)
            }
            .buttonStyle(.borderless)
            .disabled(monitor.isRefreshing)
            .help(L10n.s(.refreshHelp))
        }
    }

    @ViewBuilder
    private var batterySection: some View {
        if let battery = monitor.battery {
            HStack(spacing: 8) {
                Image(systemName: BatteryReader.symbol(for: battery))
                    .font(.title3)
                    .foregroundStyle(battery.percent <= 20 && !battery.charging ? gaugeColor(0) : Color.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.f(.batteryPercent, battery.percent))
                        .font(.subheadline.weight(.semibold))
                    Text(battery.charging ? L10n.s(.charging) : L10n.s(.onBattery))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            Text(L10n.s(.noBatteryDevice))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Button(L10n.s(.settings)) {
                DispatchQueue.main.async {
                    SettingsPresenter.show(monitor: monitor)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Spacer()
            Button(L10n.s(.quit)) { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

}

private struct AccountSection: View {
    var account: ProviderAccount
    var now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(account.name)
                    .font(.subheadline.weight(.semibold))
                if let plan = account.plan {
                    Text(plan)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let capturedAt = account.capturedAt {
                    Text(UsageFormatting.updatedAgo(capturedAt, now: now))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if let label = account.accountLabel, !label.isEmpty {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if account.windows.isEmpty {
                Text(account.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(account.windows.prefix(4)) { window in
                        WindowCard(window: window, now: now)
                    }
                }
                if account.windows.contains(where: { $0.remainingPercent <= 0 }) {
                    let names = account.windows.filter { $0.remainingPercent <= 0 }.map { L10n.windowTitle($0) }.joined(separator: L10n.s(.listSep))
                    Text(L10n.f(.exhausted, names))
                        .font(.caption)
                        .foregroundStyle(gaugeColor(0))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if account.status != L10n.s(.official) {
                    Text(account.status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let credits = account.creditsBalance {
                    Text(L10n.f(.creditsLine, credits))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let note = account.note {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct WindowCard: View {
    var window: UsageWindow
    var now: Date

    var body: some View {
        VStack(spacing: 8) {
            Text(L10n.windowTitle(window))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: window.remainingPercent / 100)
                    .stroke(gaugeColor(window.remainingPercent), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text("\(Int(window.remainingPercent.rounded()))%")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(gaugeColor(window.remainingPercent))
                    Text(L10n.s(.remainingWord))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 84, height: 84)
            .padding(.vertical, 2)

            if let resetAt = window.resetAt {
                Text(UsageFormatting.longCountdown(until: resetAt, now: now))
                    .font(.caption.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(UsageFormatting.clock(resetAt, now: now))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text(L10n.s(.noReset))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(L10n.f(.usedLine, Int(window.usedPercent.rounded())))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
