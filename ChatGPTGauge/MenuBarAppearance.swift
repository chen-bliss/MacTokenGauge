import AppKit
import SwiftUI

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case text
    case battery
    case bars
    case ring
    case rings
    case combined

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: return L10n.s(.styleText)
        case .battery: return L10n.s(.styleBattery)
        case .bars: return L10n.s(.styleBars)
        case .ring: return L10n.s(.styleRing)
        case .rings: return L10n.s(.styleRings)
        case .combined: return L10n.s(.styleCombined)
        }
    }

    var detail: String {
        switch self {
        case .text: return L10n.s(.detailText)
        case .battery: return L10n.s(.detailBattery)
        case .bars: return L10n.s(.detailBars)
        case .ring: return L10n.s(.detailRing)
        case .rings: return L10n.s(.detailRings)
        case .combined: return L10n.s(.detailCombined)
        }
    }
}

struct BarSlot: Identifiable, Codable, Equatable {
    var id: UUID
    var target: String
    var colorHex: String

    static let defaults: [BarSlot] = [
        BarSlot(id: UUID(), target: "chatgpt.primary", colorHex: "1F8A4C"),
        BarSlot(id: UUID(), target: "chatgpt.secondary", colorHex: "2F6FED"),
        BarSlot(id: UUID(), target: "cursor.cursor-total", colorHex: "E07A1F"),
        BarSlot(id: UUID(), target: "claude.five_hour", colorHex: "8E4EC6")
    ]
}

struct BarTarget: Identifiable, Hashable {
    var id: String
    var title: String

    static let catalog: [BarTarget] = [
        BarTarget(id: "chatgpt.primary", title: "ChatGPT · 5 小时"),
        BarTarget(id: "chatgpt.secondary", title: "ChatGPT · 7 天"),
        BarTarget(id: "cursor.cursor-total", title: "Cursor · 本月"),
        BarTarget(id: "cursor.cursor-auto", title: "Cursor · Auto"),
        BarTarget(id: "cursor.cursor-api", title: "Cursor · API"),
        BarTarget(id: "cursor.cursor-requests", title: "Cursor · 本月请求"),
        BarTarget(id: "cursor.cursor-ondemand", title: "Cursor · 按量"),
        BarTarget(id: "claude.five_hour", title: "Claude · 5 小时"),
        BarTarget(id: "claude.seven_day", title: "Claude · 7 天"),
        BarTarget(id: "claude.seven_day_opus", title: "Claude · Opus 每周"),
        BarTarget(id: "claude.seven_day_sonnet", title: "Claude · Sonnet 每周"),
        BarTarget(id: "battery", title: "本机电量")
    ]

    static func available(accounts: [ProviderAccount]) -> [BarTarget] {
        var items = catalog
        for account in accounts {
            for window in account.windows {
                let id = "\(account.id).\(window.id)"
                guard !items.contains(where: { $0.id == id }) else { continue }
                items.append(BarTarget(id: id, title: "\(account.name) · \(window.title)"))
            }
        }
        return items
    }

    static func title(for id: String, accounts: [ProviderAccount]) -> String {
        L10n.barTitle(id: id, accounts: accounts)
    }
}

enum ColorHex {
    static func color(from hex: String) -> Color {
        var value: UInt64 = 0
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        Scanner(string: cleaned).scanHexInt64(&value)
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    static func hex(from color: Color) -> String {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        let red = Int((resolved.redComponent * 255).rounded())
        let green = Int((resolved.greenComponent * 255).rounded())
        let blue = Int((resolved.blueComponent * 255).rounded())
        return String(format: "%02X%02X%02X", red, green, blue)
    }
}

struct ResolvedBar: Identifiable {
    var id: UUID
    var title: String
    var fraction: Double
    var color: Color
    var caption: String
}

enum BarResolver {
    static func resolve(
        slots: [BarSlot],
        accounts: [ProviderAccount],
        battery: BatteryReading?,
        now: Date
    ) -> [ResolvedBar] {
        slots.map { slot in
            let match = measurement(for: slot.target, accounts: accounts, battery: battery, now: now)
            return ResolvedBar(
                id: slot.id,
                title: BarTarget.title(for: slot.target, accounts: accounts),
                fraction: match.fraction,
                color: ColorHex.color(from: slot.colorHex),
                caption: match.caption
            )
        }
    }

    private static func measurement(
        for target: String,
        accounts: [ProviderAccount],
        battery: BatteryReading?,
        now: Date
    ) -> (fraction: Double, caption: String) {
        if target == "battery" {
            guard let battery else { return (0, L10n.s(.noBatteryData)) }
            let state = battery.charging ? L10n.s(.charging) : L10n.s(.onBattery)
            return (Double(battery.percent) / 100, L10n.f(.batteryStateLine, battery.percent, state))
        }
        let parts = target.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let account = accounts.first(where: { $0.id == parts[0] }),
              let window = account.windows.first(where: { $0.id == parts[1] }) else {
            return (0, L10n.s(.noSlotData))
        }
        let remain = L10n.f(.remainLine, Int(window.remainingPercent.rounded()))
        guard let resetAt = window.resetAt else { return (window.remainingPercent / 100, remain) }
        return (
            window.remainingPercent / 100,
            [remain, UsageFormatting.longCountdown(until: resetAt, now: now), UsageFormatting.clock(resetAt, now: now)].joined(separator: L10n.period)
        )
    }
}

struct StackedBarsIcon: View {
    var bars: [ResolvedBar]

    var body: some View {
        let image = MenuBarIconImage.bars(bars)
        Image(nsImage: image)
            .renderingMode(.original)
            .frame(width: image.size.width, height: image.size.height)
            .fixedSize()
            .help(bars.map { L10n.f(.accountLine, $0.title, $0.caption) }.joined(separator: L10n.period))
    }
}

struct MultiRingsIcon: View {
    var bars: [ResolvedBar]

    var body: some View {
        let image = MenuBarIconImage.rings(bars)
        Image(nsImage: image)
            .renderingMode(.original)
            .frame(width: image.size.width, height: image.size.height)
            .fixedSize()
            .help(bars.map { L10n.f(.accountLine, $0.title, $0.caption) }.joined(separator: L10n.period))
    }
}

struct CombinedRingIcon: View {
    var bars: [ResolvedBar]

    var body: some View {
        let image = MenuBarIconImage.combined(bars)
        Image(nsImage: image)
            .renderingMode(.original)
            .frame(width: image.size.width, height: image.size.height)
            .fixedSize()
            .help(bars.map { L10n.f(.accountLine, $0.title, $0.caption) }.joined(separator: L10n.period))
    }
}

enum MenuBarIconImage {
    static func bars(_ bars: [ResolvedBar]) -> NSImage {
        let width: CGFloat = 34
        let count = CGFloat(max(bars.count, 1))
        let maxHeight: CGFloat = 18
        let gapRatio: CGFloat = 0.55
        var line = min(3, maxHeight / (count + max(0, count - 1) * gapRatio))
        line = max(1.6, line)
        var gap = line * gapRatio
        var height = count * line + max(0, count - 1) * gap
        if height > maxHeight {
            let scale = maxHeight / height
            line *= scale
            gap *= scale
            height = maxHeight
        }
        return draw(width: width, height: max(height, line)) { _ in
            guard !bars.isEmpty else { return }
            for (index, bar) in bars.enumerated() {
                let y = height - line - CGFloat(index) * (line + gap)
                let fraction = min(1, max(0, bar.fraction))
                let track = NSRect(x: 0, y: y, width: width, height: line)
                nsColor(bar.color).withAlphaComponent(0.28).setFill()
                NSBezierPath(roundedRect: track, xRadius: line / 2, yRadius: line / 2).fill()
                let fillWidth = max(line, width * fraction)
                let fill = NSRect(x: 0, y: y, width: fillWidth, height: line)
                nsColor(bar.color).setFill()
                NSBezierPath(roundedRect: fill, xRadius: line / 2, yRadius: line / 2).fill()
            }
        }
    }

    static func ring(percent: Double) -> NSImage {
        let side: CGFloat = 16
        let line: CGFloat = 2.4
        return draw(width: side, height: side) { rect in
            strokeRing(
                center: NSPoint(x: rect.midX, y: rect.midY),
                radius: side / 2 - line,
                line: line,
                fraction: percent / 100,
                color: nsColor(gaugeColor(percent)),
                track: .tertiaryLabelColor
            )
        }
    }

    static func rings(_ bars: [ResolvedBar]) -> NSImage {
        let count = max(bars.count, 1)
        let side: CGFloat = count > 4 ? 12 : 15
        let gap: CGFloat = 3
        let width = CGFloat(count) * side + CGFloat(max(0, count - 1)) * gap
        return draw(width: width, height: side) { _ in
            let drawn = bars.isEmpty ? 1 : bars.count
            for index in 0..<drawn {
                let origin = CGFloat(index) * (side + gap)
                let center = NSPoint(x: origin + side / 2, y: side / 2)
                let color = bars.indices.contains(index) ? nsColor(bars[index].color) : NSColor.tertiaryLabelColor
                let fraction = bars.indices.contains(index) ? bars[index].fraction : 0
                strokeRing(
                    center: center,
                    radius: side / 2 - 1.5,
                    line: side > 13 ? 2.2 : 1.8,
                    fraction: fraction,
                    color: color,
                    track: color.withAlphaComponent(0.28)
                )
            }
        }
    }

    static func combined(_ bars: [ResolvedBar]) -> NSImage {
        let side: CGFloat = 18
        return draw(width: side, height: side) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let items: [(Double, NSColor)] = bars.isEmpty
                ? [(0, .tertiaryLabelColor)]
                : bars.map { ($0.fraction, nsColor($0.color)) }
            let outer = side / 2 - 1
            let count = CGFloat(items.count)
            let line = min(2.2, max(1.25, (outer - 1.2 - max(0, count - 1) * 0.55) / count))
            let gap: CGFloat = items.count == 1 ? 0 : 0.55
            for (index, item) in items.enumerated() {
                let radius = outer - line / 2 - CGFloat(index) * (line + gap)
                guard radius > 1 else { continue }
                strokeRing(
                    center: center,
                    radius: radius,
                    line: line,
                    fraction: item.0,
                    color: item.1,
                    track: item.1.withAlphaComponent(0.28)
                )
            }
        }
    }

    private static func strokeRing(
        center: NSPoint,
        radius: CGFloat,
        line: CGFloat,
        fraction: Double,
        color: NSColor,
        track: NSColor
    ) {
        let outline = NSBezierPath()
        outline.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360, clockwise: false)
        outline.lineWidth = line
        track.setStroke()
        outline.stroke()

        let amount = min(1, max(0, fraction))
        guard amount > 0.01 else { return }
        let arc = NSBezierPath()
        arc.lineWidth = line
        arc.lineCapStyle = .round
        if amount >= 0.985 {
            arc.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360, clockwise: false)
        } else {
            let start: CGFloat = 90
            let end = start - amount * 360
            arc.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
        }
        color.setStroke()
        arc.stroke()
    }

    private static func draw(width: CGFloat, height: CGFloat, _ body: (NSRect) -> Void) -> NSImage {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let pixelsWide = max(1, Int((width * scale).rounded()))
        let pixelsHigh = max(1, Int((height * scale).rounded()))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return NSImage(size: NSSize(width: width, height: height))
        }
        rep.size = NSSize(width: width, height: height)
        let appearance = NSApp.effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            body(NSRect(x: 0, y: 0, width: width, height: height))
            NSGraphicsContext.restoreGraphicsState()
        }
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        image.isTemplate = false
        return image
    }

    private static func nsColor(_ color: Color) -> NSColor {
        NSColor(color).usingColorSpace(.sRGB) ?? .labelColor
    }
}
