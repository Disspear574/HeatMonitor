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

// At 100 % macOS holds the charge and the battery reads about −1 W; a bigger draw is a shortage even below the
// adapter's rating, because the adapter or cable may deliver less than it advertises.
func adapterShort(batteryW: Double?, adapterInW: Double?, adapterMaxW: Int?) -> Bool {
    guard let v = batteryW, v < -0.5 else { return false }
    if v <= -3 { return true }
    guard let inW = adapterInW, let max = adapterMaxW else { return true }
    return inW >= Double(max) * 0.9
}

/// A connected Mac port: what is plugged in and whether it powers the Mac.
struct PortLink: Equatable {
    let type: String
    let name: String?
    let transports: [String]
    let supplyW: Int?
    let powersMac: Bool
    var budgetW: Double? = nil
}

func deviceName(vendor: String?, model: String) -> String {
    let brand = vendor?.split(separator: " ").first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ",.")) } ?? ""
    return brand.isEmpty || model.lowercased().hasPrefix(brand.lowercased()) ? model : "\(brand) \(model)"
}

// USB product strings are firmware identifiers like "SAMSUNG_Android"; short all-caps words are acronyms and stay.
func usbProductName(_ raw: String) -> String {
    raw.split(whereSeparator: { $0 == "_" || $0 == " " }).map { w in
        w.count >= 5 && w.allSatisfy(\.isUppercase) ? w.capitalized : String(w)
    }.joined(separator: " ")
}

enum PowerVia: Equatable { case magSafe, charger, dock }

// A port that offers the Mac power is a supply; one that also carries data or video is a dock.
func powerVia(_ p: PortLink) -> PowerVia? {
    guard p.supplyW != nil else { return nil }
    if p.type.hasPrefix("MagSafe") { return .magSafe }
    return p.transports.contains { $0 != "CC" } ? .dock : .charger
}

func usbDevices(_ ports: [PortLink]) -> [(name: String, budgetW: Double?)] {
    ports.compactMap { p in
        guard p.type == "USB-C", p.supplyW == nil, p.transports.contains(where: { $0 != "CC" }),
              let name = p.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        return (name, p.budgetW)
    }
}

// The Mac draws from one supply at a time, the one that offers the most power; the rest stand idle.
func powerSupplies(_ ports: [PortLink]) -> (active: PowerVia, name: String?, idle: [(via: PowerVia, watts: Int?)])? {
    guard let port = ports.first(where: \.powersMac), let active = powerVia(port) else { return nil }
    let idle = ports.filter { !$0.powersMac }.compactMap { p in powerVia(p).map { (via: $0, watts: p.supplyW) } }
    return (active, active == .dock ? port.name : nil, idle)
}

// Measured members keep their watts; the rest of the app's energy, exited children included, goes by weight.
func splitWatts(_ total: Double, weights: [(pid: Int32, weight: Double)], fixed: [Int32: Double]) -> [Int32: Double] {
    var out = fixed.filter { pid, _ in weights.contains { $0.pid == pid } }
    let rest = max(total - out.values.reduce(0, +), 0)
    let open = weights.filter { out[$0.pid] == nil }
    let sum = open.reduce(0) { $0 + $1.weight }
    if sum > 0 {
        for m in open { out[m.pid] = rest * m.weight / sum }
    } else if let first = open.first ?? weights.first {
        out[first.pid, default: 0] += rest
    }
    return out
}

// CPU tools report 100% per logical core; the UI uses 100% for the whole CPU.
func machineCPUPercent(_ corePercent: Double, cores: Int) -> Double {
    guard corePercent.isFinite else { return 0 }
    return max(0, corePercent) / Double(max(cores, 1))
}

// A fresh interval is required: a lifetime average is not a current reading.
func intervalCPU(previous: Double?, current: Double, seconds: Double) -> Double? {
    guard let previous, previous.isFinite, current.isFinite, seconds.isFinite,
          seconds > 0, current >= previous else { return nil }
    return (current - previous) / seconds * 100
}

func percentText(_ value: Double) -> String {
    guard value.isFinite, value >= 0 else { return "—" }
    if value == 0 { return "0%" }
    if value < 0.1 { return "<0.1%" }
    return String(format: value < 10 ? "%.1f%%" : "%.0f%%", value)
}

/// Temperature band of a CPU reading; Apple Silicon cores run at 100–110° under full load.
enum TempLevel: Int, CaseIterable {
    case ok, warm, hot, crit

    init(_ t: Double) {
        switch t {
        case ..<70: self = .ok
        case ..<85: self = .warm
        case ..<100: self = .hot
        default: self = .crit
        }
    }

    static func optional(_ t: Double?) -> TempLevel? { t.map(TempLevel.init) }
}

func scaleFraction(_ t: Double, from lo: Double = 30, to hi: Double = 110) -> Double {
    min(max((t - lo) / (hi - lo), 0), 1)
}

/// Whether the adapter covers what the Mac draws.
enum PowerVerdict: Equatable {
    case enough(spareW: Double?), short(deficitW: Double), battery(drawW: Double?), unknown

    static func make(plugged: Bool?, batteryW: Double?, adapterInW: Double?, adapterMaxW: Int?, systemW: Double?) -> PowerVerdict {
        guard let plugged else { return .unknown }
        guard plugged else { return .battery(drawW: systemW) }
        if let v = batteryW, adapterShort(batteryW: v, adapterInW: adapterInW, adapterMaxW: adapterMaxW) { return .short(deficitW: -v) }
        guard let max = adapterMaxW, let inW = adapterInW else { return .enough(spareW: nil) }
        return .enough(spareW: Double(max) - inW)
    }
}

/// A heat cause the process list does not show.
enum HeatCause: Equatable { case cpuLoad(Double), graphics(Double), fastCharge(Double) }

// GPU busy percent reads high at idle clocks, so only real power counts.
func extraHeatCauses(cpuUsage: Double, gpuWatts: Double?, batteryW: Double?) -> [HeatCause] {
    var out: [HeatCause] = []
    if cpuUsage >= 60 { out.append(.cpuLoad(cpuUsage)) }
    if let g = gpuWatts, g >= 5 { out.append(.graphics(g)) }
    if let b = batteryW, b > 15 { out.append(.fastCharge(b)) }
    return out
}

/// Fan controls, or trackpad temperatures on a fanless Mac.
enum FanCardKind { case fans, chassis }

func fanCardKind(fanCount: Int) -> FanCardKind { fanCount > 0 ? .fans : .chassis }

/// How often the Advice checks run: fast in the section and until a CPU sample exists, slow for the sidebar count.
enum AdviceSchedule {
    static let section: TimeInterval = 5
    static let badge: TimeInterval = 60

    static func interval(windowOnScreen: Bool, adviceShown: Bool, hasCPUSample: Bool) -> TimeInterval? {
        guard windowOnScreen else { return nil }
        return adviceShown || !hasCPUSample ? section : badge
    }
}

/// A section of the main window's sidebar.
enum WindowSection: String, CaseIterable, Identifiable {
    case overview, processes, cooling, power, advice

    var id: String { rawValue }
    var shortcut: Character { Character(String((Self.allCases.firstIndex(of: self) ?? 0) + 1)) }
    var titleKey: String {
        switch self { case .overview: "Обзор"; case .processes: "Процессы"; case .cooling: "Охлаждение"; case .power: "Питание"; case .advice: "Советы" }
    }
}
