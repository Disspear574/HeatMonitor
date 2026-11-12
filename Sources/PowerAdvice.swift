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

/// What a USB-C cable's e-marker says it carries.
struct CableRating: Equatable {
    let volts: Int
    let amps: Int
    let epr: Bool
    // Above 20 V needs EPR; 240 W is the USB PD ceiling.
    var watts: Int { min((epr ? volts : min(volts, 20)) * amps, 240) }
}

// USB PD Discover Identity: ID header product type 3 or 4 is a passive or active cable; the cable VDO is the fourth.
func cableRating(vdos: [UInt32]) -> CableRating? {
    guard vdos.count >= 4, [3, 4].contains(vdos[0] >> 27 & 7) else { return nil }
    let v = vdos[3]
    let amps: Int
    switch v >> 5 & 3 {
    case 1: amps = 3
    case 2: amps = 5
    default: return nil
    }
    return CableRating(volts: [20, 30, 40, 50][Int(v >> 9 & 3)], amps: amps, epr: v >> 17 & 1 == 1)
}

/// What limits the power the Mac gets from its supply.
enum PowerCause: Equatable { case cableRated(CableRating), cable(ratedW: Int, gotW: Int), weakAdapter(gotW: Int?) }

// A cable shows only when the negotiated power sits at its ceiling; MagSafe always uses Apple's cable.
func powerCause(ratedW: Int?, negotiatedW: Int?, cable: CableRating? = nil, magSafe: Bool = false) -> PowerCause {
    if !magSafe, let c = cable, c.watts < 240, let got = negotiatedW, Double(got) >= Double(c.watts) * 0.9 { return .cableRated(c) }
    if !magSafe, cable == nil, let rated = ratedW, let got = negotiatedW, Double(got) < Double(rated) * 0.9 { return .cable(ratedW: rated, gotW: got) }
    return .weakAdapter(gotW: negotiatedW)
}

// Cable limits are worth knowing at any load; a weak adapter only matters when the battery covers the gap.
func powerLimit(plugged: Bool, short: Bool, ratedW: Int?, negotiatedW: Int?, cable: CableRating?, magSafe: Bool) -> PowerCause? {
    guard plugged else { return nil }
    let cause = powerCause(ratedW: ratedW, negotiatedW: negotiatedW, cable: cable, magSafe: magSafe)
    if case .weakAdapter = cause, !short { return nil }
    return cause
}

/// A power recommendation shown in the Power section.
enum PowerTip: Equatable { case lowPowerOnAdapter(PowerCause) }

func powerTips(plugged: Bool, short: Bool, acMode: EnergyMode?, ratedW: Int?, negotiatedW: Int?,
               cable: CableRating? = nil, magSafe: Bool = false) -> [PowerTip] {
    var tips: [PowerTip] = []
    if plugged, short, acMode != .low {
        tips.append(.lowPowerOnAdapter(powerCause(ratedW: ratedW, negotiatedW: negotiatedW, cable: cable, magSafe: magSafe)))
    }
    return tips
}
