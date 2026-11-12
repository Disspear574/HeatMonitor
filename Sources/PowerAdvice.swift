import Foundation

/// macOS Energy Mode for one power source, as pmset `powermode` stores it.
enum EnergyMode: Int { case automatic = 0, low = 1, high = 2 }

func acEnergyMode(pmsetCustom: String) -> EnergyMode? {
    var inAC = false
    for line in pmsetCustom.split(separator: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasSuffix("Power:") { inAC = t == "AC Power:"; continue }
        guard inAC else { continue }
        let parts = t.split(separator: " ", omittingEmptySubsequences: true)
        if parts.count == 2, parts[0] == "powermode", let v = Int(parts[1]) { return EnergyMode(rawValue: v) }
    }
    return nil
}

func ratedWatts(adapterName: String?) -> Int? {
    guard let name = adapterName, let r = name.range(of: #"\d+(?=\s*W)"#, options: .regularExpression) else { return nil }
    return Int(name[r])
}

/// Why the adapter does not cover the Mac.
enum PowerCause: Equatable { case cable(ratedW: Int, gotW: Int), weakAdapter(gotW: Int?) }

// Well below the rating means the cable or port negotiated less than the adapter can give.
func powerCause(ratedW: Int?, negotiatedW: Int?) -> PowerCause {
    if let rated = ratedW, let got = negotiatedW, Double(got) < Double(rated) * 0.9 { return .cable(ratedW: rated, gotW: got) }
    return .weakAdapter(gotW: negotiatedW)
}

/// A power recommendation shown in the Power section.
enum PowerTip: Equatable { case lowPowerOnAdapter(PowerCause) }

func powerTips(plugged: Bool, short: Bool, acMode: EnergyMode?, ratedW: Int?, negotiatedW: Int?) -> [PowerTip] {
    var tips: [PowerTip] = []
    if plugged, short, acMode != .low { tips.append(.lowPowerOnAdapter(powerCause(ratedW: ratedW, negotiatedW: negotiatedW))) }
    return tips
}
