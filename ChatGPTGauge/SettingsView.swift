import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var monitor: UsageMonitor
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchNote = ""

    var body: some View {
        ScrollView {
            form
        }
        .environment(\.layoutDirection, monitor.appLanguage.layoutDirection)
        .id(monitor.appLanguage.rawValue)
        .frame(minWidth: 540, minHeight: 560)
    }

    private var form: some View {
        Form {
            Section(L10n.s(.sectionLanguage)) {
                Picker(L10n.s(.languageLabel), selection: $monitor.appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.nativeName).tag(language)
                    }
                }
                Text(L10n.s(.languageHelp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.s(.sectionData)) {
                Toggle(L10n.s(.liveToggle), isOn: $monitor.liveEnabled)
                Text(L10n.s(.liveHelp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent(L10n.s(.refreshInterval)) {
                    Slider(value: $monitor.refreshMinutes, in: 1...30, step: 1) {
                        Text(L10n.s(.refreshInterval))
                    } minimumValueLabel: {
                        Text("1")
                    } maximumValueLabel: {
                        Text("30")
                    }
                    .frame(width: 180)
                    Text(L10n.f(.minutesValue, Int(monitor.refreshMinutes)))
                        .frame(width: 72, alignment: .trailing)
                }
                Toggle(L10n.s(.refreshOnWake), isOn: $monitor.refreshOnWake)
                Text(L10n.s(.refreshOnWakeHelp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if monitor.powerSaver {
                    Text(L10n.s(.powerSaverOn))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(L10n.s(.sectionMenu)) {
                Picker(L10n.s(.iconStyle), selection: $monitor.menuBarStyle) {
                    ForEach(MenuBarStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                Text(monitor.menuBarStyle.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if monitor.menuBarStyle == .text {
                    textEditor
                }
                if monitor.menuBarStyle == .bars || monitor.menuBarStyle == .rings || monitor.menuBarStyle == .combined {
                    barEditor
                }
                Toggle(L10n.s(.showBattery), isOn: $monitor.showBattery)
                if monitor.showBattery || monitor.menuBarStyle == .battery {
                    Picker(L10n.s(.batteryChoice), selection: $monitor.batteryMark) {
                        ForEach(BatteryMark.allCases) { mark in
                            Text(mark.title).tag(mark)
                        }
                    }
                    .pickerStyle(.segmented)
                    LabeledContent(L10n.s(.batteryInterval)) {
                        Slider(value: $monitor.batteryMinutes, in: 1...30, step: 1) {
                            Text(L10n.s(.batteryInterval))
                        } minimumValueLabel: {
                            Text("1")
                        } maximumValueLabel: {
                            Text("30")
                        }
                        .frame(width: 180)
                        Text(L10n.f(.minutesValue, Int(monitor.batteryMinutes)))
                            .frame(width: 72, alignment: .trailing)
                    }
                    Text(L10n.s(.batteryIntervalHelp))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(L10n.s(.batteryHelp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.s(.sectionPlace)) {
                Text(L10n.s(.placeHelp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.s(.sectionAlert)) {
                Toggle(L10n.s(.alertToggle), isOn: $monitor.alertsEnabled)
                LabeledContent(L10n.s(.alertLevel)) {
                    Slider(value: $monitor.alertThreshold, in: 5...50, step: 5) {
                        Text(L10n.s(.alertLevel))
                    } minimumValueLabel: {
                        Text("5%")
                    } maximumValueLabel: {
                        Text("50%")
                    }
                    .frame(width: 180)
                    Text("\(Int(monitor.alertThreshold))%")
                        .frame(width: 52, alignment: .trailing)
                }
                Text(L10n.s(.alertHelp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(L10n.s(.launchLogin), isOn: $launchAtLogin)
                if !launchNote.isEmpty {
                    Text(launchNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(L10n.s(.sectionNotes)) {
                Text(L10n.s(.noteStyles))
                Text(L10n.s(.notePrivacy))
                Text(L10n.s(.noteAccounts))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding(.top, 8)
        .onChange(of: monitor.liveEnabled) { _, _ in monitor.savePreferences() }
        .onChange(of: monitor.refreshMinutes) { _, _ in monitor.savePreferences() }
        .onChange(of: monitor.refreshOnWake) { _, _ in monitor.savePreferences(scheduleRefresh: false) }
        .onChange(of: monitor.batteryMinutes) { _, _ in monitor.savePreferences(scheduleRefresh: false) }
        .onChange(of: monitor.alertsEnabled) { _, _ in monitor.savePreferences() }
        .onChange(of: monitor.alertThreshold) { _, _ in monitor.savePreferences() }
        .onChange(of: monitor.showBattery) { _, _ in
            monitor.battery = BatteryReader.current()
            monitor.savePreferences()
        }
        .onChange(of: monitor.menuBarStyle) { _, _ in monitor.savePreferences() }
        .onChange(of: launchAtLogin) { _, enabled in
            guard enabled != (SMAppService.mainApp.status == .enabled) else { return }
            updateLaunchAtLogin(enabled)
        }
    }

    private var textEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(L10n.s(.textTemplateLabel), text: $monitor.menuTextTemplate)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 6) {
                tokenButton("{name}", L10n.s(.tokenName))
                tokenButton("{percent}", L10n.s(.tokenPercent))
                tokenButton("{countdown}", L10n.s(.tokenCountdown))
                tokenButton("{window}", L10n.s(.tokenWindow))
                tokenButton("{reset}", L10n.s(.tokenReset))
            }
            Text(MenuText.render(template: monitor.menuTextTemplate, accounts: monitor.accounts, now: monitor.now))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
            Text(L10n.s(.textTemplateHelp))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func tokenButton(_ token: String, _ title: String) -> some View {
        Button(title) {
            var text = monitor.menuTextTemplate
            if !text.isEmpty, !text.hasSuffix(" ") { text += " " }
            monitor.menuTextTemplate = text + token
        }
        .controlSize(.small)
    }

    private var barEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(L10n.s(.preview))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                slotPreview
            }
            ForEach(monitor.barSlots) { slot in
                HStack(spacing: 8) {
                    Picker(L10n.s(.meaning), selection: targetBinding(slot)) {
                        ForEach(BarTarget.available(accounts: monitor.accounts)) { target in
                            Text(BarTarget.title(for: target.id, accounts: monitor.accounts)).tag(target.id)
                        }
                    }
                    .labelsHidden()
                    ColorPicker(L10n.s(.colorLabel), selection: colorBinding(slot))
                        .labelsHidden()
                    Button {
                        monitor.moveSlot(slot.id, direction: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.borderless)
                    Button {
                        monitor.moveSlot(slot.id, direction: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    Button {
                        monitor.removeSlot(slot.id)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(monitor.barSlots.count <= 1)
                }
            }
            Button(monitor.menuBarStyle == .bars ? L10n.s(.addBar) : L10n.s(.addRing)) { monitor.addSlot() }
                .disabled(monitor.barSlots.count >= 6)
            Text(slotHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var slotPreview: some View {
        let bars = BarResolver.resolve(
            slots: monitor.barSlots,
            accounts: monitor.accounts,
            battery: monitor.battery,
            now: monitor.now
        )
        switch monitor.menuBarStyle {
        case .rings:
            MultiRingsIcon(bars: bars)
        case .combined:
            CombinedRingIcon(bars: bars)
        default:
            StackedBarsIcon(bars: bars)
        }
    }

    private var slotHint: String {
        switch monitor.menuBarStyle {
        case .rings:
            return L10n.s(.hintRings)
        case .combined:
            return L10n.s(.hintCombined)
        default:
            return L10n.s(.hintBars)
        }
    }

    private func targetBinding(_ slot: BarSlot) -> Binding<String> {
        Binding(
            get: { slot.target },
            set: { monitor.updateSlotTarget(slot.id, target: $0) }
        )
    }

    private func colorBinding(_ slot: BarSlot) -> Binding<Color> {
        Binding(
            get: { ColorHex.color(from: slot.colorHex) },
            set: { monitor.updateSlotColor(slot.id, color: $0) }
        )
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                launchNote = L10n.s(.launchOn)
            } else {
                try SMAppService.mainApp.unregister()
                launchNote = ""
            }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            launchNote = L10n.f(.launchDenied, error.localizedDescription)
        }
    }
}
