import SwiftUI

struct MenuBarLabel: View {
    var accounts: [ProviderAccount]
    var battery: BatteryReading?
    var showBattery: Bool
    var style: MenuBarStyle
    var barSlots: [BarSlot]
    var now: Date
    var textTemplate: String
    var batteryMark: BatteryMark

    var body: some View {
        HStack(spacing: 6) {
            switch style {
            case .text:
                textLabel
                if showBattery { batteryOnlyLabel }
            case .battery:
                batteryOnlyLabel
            case .bars:
                StackedBarsIcon(bars: resolvedBars)
                if showBattery { batteryOnlyLabel }
            case .ring:
                ringLabel
                if showBattery { batteryOnlyLabel }
            case .rings:
                MultiRingsIcon(bars: resolvedBars)
                if showBattery { batteryOnlyLabel }
            case .combined:
                CombinedRingIcon(bars: resolvedBars)
                if showBattery { batteryOnlyLabel }
            }
        }
        .fixedSize(horizontal: true, vertical: true)
        .id(style.rawValue)
        .help(helpText)
    }

    private var resolvedBars: [ResolvedBar] {
        BarResolver.resolve(slots: barSlots, accounts: accounts, battery: battery, now: now)
    }

    @ViewBuilder
    private var textLabel: some View {
        let visible = accounts.filter { UsageFormatting.headline($0.windows) != nil }
        if visible.isEmpty {
            Image(systemName: "gauge.with.dots.needle.33percent")
            Text(L10n.s(.usage))
                .font(.system(size: 12, weight: .medium))
        } else {
            Text(renderedMenuText)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
    }

    private var renderedMenuText: String {
        MenuText.render(template: textTemplate, accounts: accounts, now: now)
    }

    @ViewBuilder
    private var ringLabel: some View {
        if let window = tightestWindow {
            Image(nsImage: MenuBarIconImage.ring(percent: window.remainingPercent))
                .renderingMode(.original)
                .frame(width: 16, height: 16)
                .fixedSize()
            Text("\(Int(window.remainingPercent.rounded()))%")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(gaugeColor(window.remainingPercent))
        } else {
            Image(systemName: "gauge.with.dots.needle.33percent")
            Text(L10n.s(.usage))
                .font(.system(size: 12, weight: .medium))
        }
    }

    private var tightestWindow: UsageWindow? {
        let windows = accounts.flatMap(\.windows)
        return UsageFormatting.headline(windows)
    }

    @ViewBuilder
    private var batteryOnlyLabel: some View {
        switch batteryMark {
        case .icon:
            batterySymbol
        case .percent:
            batteryPercentText
        }
    }

    @ViewBuilder
    private var batterySymbol: some View {
        if let battery {
            Image(systemName: BatteryReader.symbol(for: battery))
                .font(.system(size: 12))
                .foregroundStyle(battery.percent <= 20 && !battery.charging ? gaugeColor(0) : Color.primary)
                .help(battery.charging ? L10n.f(.batteryChargingHelp, battery.percent) : L10n.f(.batteryIdleHelp, battery.percent))
        } else {
            Image(systemName: "battery.0percent")
        }
    }

    @ViewBuilder
    private var batteryPercentText: some View {
        if let battery {
            Text("\(battery.percent)%")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(battery.percent <= 20 && !battery.charging ? gaugeColor(0) : Color.primary)
                .help(battery.charging ? L10n.f(.batteryChargingHelp, battery.percent) : L10n.f(.batteryIdleHelp, battery.percent))
        } else {
            Text(L10n.s(.noBatteryShort))
                .font(.system(size: 12, weight: .medium))
        }
    }

    private var helpText: String {
        var lines = accounts.compactMap { account -> String? in
            guard !account.windows.isEmpty else { return nil }
            let body = account.windows.map { window -> String in
                let name = L10n.windowTitle(window)
                guard let resetAt = window.resetAt else {
                    return L10n.f(.helpLeft, name, Int(window.remainingPercent.rounded()))
                }
                return L10n.f(.helpLeftReset, name, Int(window.remainingPercent.rounded()), UsageFormatting.clock(resetAt, now: now))
            }.joined(separator: L10n.period)
            return L10n.f(.accountLine, account.name, body)
        }
        if showBattery || style == .battery, let battery {
            lines.append(battery.charging ? L10n.f(.batteryChargingHelp, battery.percent) : L10n.f(.batteryIdleHelp, battery.percent))
        }
        if style == .bars || style == .rings || style == .combined {
            let barLines = resolvedBars.map { L10n.f(.accountLine, $0.title, $0.caption) }
            return (barLines + lines).joined(separator: L10n.period)
        }
        return lines.isEmpty ? L10n.s(.noUsageYet) : lines.joined(separator: L10n.period)
    }
}

enum MenuText {
    static let fallback = "{name} {percent} {countdown}"

    static func render(template: String, accounts: [ProviderAccount], now: Date) -> String {
        let pattern = template.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = pattern.isEmpty ? fallback : pattern
        let parts = accounts.compactMap { account -> String? in
            guard let window = UsageFormatting.headline(account.windows) else { return nil }
            let countdown = window.resetAt.map { UsageFormatting.shortCountdown(until: $0, now: now) } ?? ""
            let reset = window.resetAt.map { UsageFormatting.clock($0, now: now) } ?? ""
            return source
                .replacingOccurrences(of: "{name}", with: account.menuTitle)
                .replacingOccurrences(of: "{percent}", with: "\(Int(window.remainingPercent.rounded()))%")
                .replacingOccurrences(of: "{countdown}", with: countdown)
                .replacingOccurrences(of: "{window}", with: L10n.windowTitle(window))
                .replacingOccurrences(of: "{reset}", with: reset)
        }
        let text = parts.joined(separator: "  ").trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? L10n.s(.usage) : text
    }
}

struct GaugeMark: View {
    var percent: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.18), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.015, min(1, percent / 100)))
                .stroke(gaugeColor(percent), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

func gaugeColor(_ remaining: Double) -> Color {
    if remaining <= 15 { return Color(red: 0.86, green: 0.22, blue: 0.18) }
    if remaining <= 40 { return Color(red: 0.86, green: 0.48, blue: 0.12) }
    return Color(red: 0.12, green: 0.55, blue: 0.34)
}
