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

/// UserDefaults keys and defaults shared by settings, the menu bar item and the panel.
enum Pref {
    static let showInDock = "showInDock"
    static let liveLabel = "menuLive"
    static let labelValues = "menuValues"
    static let panelBlocks = "panelBlocks"
    static var defaults: [String: Any] {
        [showInDock: false, liveLabel: false, labelValues: MenuValue.cpuTemp.rawValue,
         panelBlocks: encodeSet(Set(PanelBlock.allCases))]
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
