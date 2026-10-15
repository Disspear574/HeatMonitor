import Foundation

/// A value the menu bar label can show.
enum MenuValue: String, CaseIterable { case cpuTemp, gpuTemp, fan, power, cpuLoad }

/// A block of the menu bar panel that settings can hide.
enum PanelBlock: String, CaseIterable { case temperature, sensors, load, power, apps, fans }

/// The latest numbers behind the label; nil when the Mac has no such sensor or no sample yet.
struct Readings: Equatable {
    var cpuTemp: Double?
    var gpuTemp: Double?
    var fanRPM: Double?
    var systemW: Double?
    var cpuLoad: Double?
}

/// One piece of the label: an SF Symbol and its text.
struct MenuPart: Equatable { let symbol: String; let text: String }

enum MenuLabel {
    static func parts(_ r: Readings, values: Set<MenuValue>, wattFormat: String = "%.0f W") -> [MenuPart] {
        MenuValue.allCases.filter(values.contains).compactMap { v -> MenuPart? in
            switch v {
            case .cpuTemp: return r.cpuTemp.map { MenuPart(symbol: "thermometer.medium", text: String(format: "%.0f°", $0)) }
            case .gpuTemp: return r.gpuTemp.map { MenuPart(symbol: "square.3.layers.3d", text: String(format: "%.0f°", $0)) }
            case .fan: return r.fanRPM.map { MenuPart(symbol: "fan", text: String(format: "%.0f", $0)) }
            case .power: return r.systemW.map { MenuPart(symbol: "bolt.fill", text: String(format: wattFormat, $0)) }
            case .cpuLoad: return r.cpuLoad.map { MenuPart(symbol: "cpu", text: String(format: "%.0f%%", $0)) }
            }
        }
    }
}

// Sets are stored as comma-separated raw values in UserDefaults, in declaration order.
func decodeSet<T: CaseIterable & RawRepresentable>(_ s: String) -> Set<T> where T.RawValue == String {
    Set(s.split(separator: ",").compactMap { T(rawValue: String($0)) })
}
func encodeSet<T: CaseIterable & RawRepresentable>(_ v: Set<T>) -> String where T.RawValue == String {
    T.allCases.filter(v.contains).map(\.rawValue).joined(separator: ",")
}

/// What a process's heat percent is taken of: the Mac's full-load watts or the current total of every process.
enum HeatBase: String, CaseIterable {
    case auto, maximum, total

    // Auto takes the maximum only where it was measured; a guessed ceiling would inflate every share.
    func resolved(measured: Bool) -> HeatBase { self == .auto ? (measured ? .maximum : .total) : self }
}

/// Heat share in percent; `base` must already be resolved.
func heatPercent(_ watts: Double, of base: HeatBase, ceiling: Double, total: Double) -> Double {
    let whole = base == .maximum ? ceiling : total
    return whole > 0 ? watts / whole * 100 : 0
}

/// UserDefaults keys and defaults shared by settings, the menu bar item and the panel.
enum Pref {
    static let showInDock = "showInDock"
    static let liveLabel = "menuLive"
    static let labelValues = "menuValues"
    static let panelBlocks = "panelBlocks"
    static let heatBase = "heatBase"
    static var defaults: [String: Any] {
        [showInDock: false, liveLabel: false, labelValues: MenuValue.cpuTemp.rawValue,
         panelBlocks: encodeSet(Set(PanelBlock.allCases)), heatBase: HeatBase.auto.rawValue]
    }
}

/// Who needs full polling now, and when it may stop: 60 s after the panel and the window close.
struct Demand {
    static let grace: TimeInterval = 60
    private(set) var panel = false
    private(set) var window = false
    private var idleSince: Date?
    private var open: Bool { panel || window }

    mutating func set(panel: Bool, now: Date) { let was = open; self.panel = panel; settle(was, now) }
    mutating func set(window: Bool, now: Date) { let was = open; self.window = window; settle(was, now) }

    private mutating func settle(_ was: Bool, _ now: Date) {
        if open { idleSince = nil } else if was { idleSince = now }
    }

    func wantsFull(at now: Date) -> Bool {
        open || idleSince.map { now.timeIntervalSince($0) < Self.grace } == true
    }

    var stopAt: Date? { open ? nil : idleSince?.addingTimeInterval(Self.grace) }
}

// IOHID die sensors when SMC has no core keys: "PMU tdie*" on M2 and later, "ACC MTR" on M1.
func hidCPU(_ sensors: [String: Double]) -> Double? {
    let tdie = sensors.filter { $0.key.hasPrefix("PMU tdie") }.values
    return tdie.max() ?? sensors.filter { $0.key.contains("ACC MTR") }.values.max()
}

// A battery draw on the adapter is a shortage only near the adapter's rating; at 100 % macOS holds the charge and the battery reads about −1 W.
func adapterShort(batteryW: Double?, adapterInW: Double?, adapterMaxW: Int?) -> Bool {
    guard let v = batteryW, v < -0.5 else { return false }
    guard let inW = adapterInW, let max = adapterMaxW else { return true }
    return inW >= Double(max) * 0.9
}
