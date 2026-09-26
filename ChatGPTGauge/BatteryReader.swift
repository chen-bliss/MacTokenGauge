import Foundation
import IOKit.ps

enum BatteryReader {
    static func current() -> BatteryReading? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        guard let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            let transport = description[kIOPSTransportTypeKey] as? String
            guard transport == nil || transport == (kIOPSInternalType as String) else { continue }
            guard let current = integer(description[kIOPSCurrentCapacityKey]),
                  let maximum = integer(description[kIOPSMaxCapacityKey]),
                  maximum > 0 else { continue }

            let percent = Int((Double(current) / Double(maximum) * 100).rounded())
            let charging = boolean(description[kIOPSIsChargingKey])
            return BatteryReading(percent: min(100, max(0, percent)), charging: charging)
        }
        return nil
    }

    static func symbol(for reading: BatteryReading) -> String {
        if reading.charging { return "battery.100percent.bolt" }
        switch reading.percent {
        case 0..<13: return "battery.0percent"
        case 13..<38: return "battery.25percent"
        case 38..<63: return "battery.50percent"
        case 63..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private static func integer(_ any: Any?) -> Int? {
        switch any {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        default:
            return nil
        }
    }

    private static func boolean(_ any: Any?) -> Bool {
        switch any {
        case let value as Bool:
            return value
        case let value as NSNumber:
            return value.boolValue
        default:
            return false
        }
    }
}
