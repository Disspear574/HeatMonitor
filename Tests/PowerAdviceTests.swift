import Foundation

func powerAdviceTests() {
    // pmset -g custom: the AC section's powermode, not the battery one.
    let custom = """
    Battery Power:
     powermode            0
     sleep                1
    AC Power:
     Sleep On Power Button 1
     powermode            1
     sleep                1
    """
    check(acEnergyMode(pmsetCustom: custom) == .low, "AC powermode read from the AC section")
    check(acEnergyMode(pmsetCustom: "AC Power:\n powermode 2\n") == .high, "high power")
    check(acEnergyMode(pmsetCustom: "Battery Power:\n powermode 1\nAC Power:\n sleep 1\n") == nil, "no AC powermode")
    check(acEnergyMode(pmsetCustom: "") == nil, "empty output")

    // Rated watts come from the adapter name.
    check(ratedWatts(adapterName: "140W USB-C Power Adapter") == 140, "Apple 140 W name")
    check(ratedWatts(adapterName: "96W USB-C Power Adapter") == 96, "Apple 96 W name")
    check(ratedWatts(adapterName: "USB-C Power Adapter") == nil, "no watts in name")
    check(ratedWatts(adapterName: nil) == nil, "no name")

    // Cause: negotiated well below rated means the cable (or port) limits it.
    check(powerCause(ratedW: 140, negotiatedW: 94) == .cable(ratedW: 140, gotW: 94), "140 W adapter, 94 W negotiated")
    check(powerCause(ratedW: 96, negotiatedW: 94) == .weakAdapter(gotW: 94), "close to rating: adapter is weak")
    check(powerCause(ratedW: nil, negotiatedW: 60) == .weakAdapter(gotW: 60), "unknown rating")
    check(powerCause(ratedW: 140, negotiatedW: nil) == .weakAdapter(gotW: nil), "unknown negotiated")

    // Cable e-marker: the 20 V / 5 A cable sold as 240 W, and a 50 V EPR Thunderbolt cable.
    let fake = cableRating(vdos: [0x1860_0000, 0, 0, 0x0008_4040])
    check(fake == CableRating(volts: 20, amps: 5, epr: false) && fake?.watts == 100, "20 V cable is 100 W")
    let epr = cableRating(vdos: [0x1c60_315c, 0, 0, 0x000a_2e43])
    check(epr == CableRating(volts: 50, amps: 5, epr: true) && epr?.watts == 240, "EPR cable is 240 W")
    check(cableRating(vdos: [0x01c0_2fe6, 0, 0, 0x40]) == nil, "power brick is not a cable")
    check(cableRating(vdos: [0x1860_0000]) == nil, "too few VDOs")

    // A known cable at its ceiling wins; a cable that is not at its ceiling is not blamed.
    let c100 = CableRating(volts: 20, amps: 5, epr: false)
    check(powerCause(ratedW: nil, negotiatedW: 100, cable: c100) == .cableRated(c100), "third-party adapter on a 100 W cable")
    check(powerCause(ratedW: 140, negotiatedW: 94, cable: c100) == .cableRated(c100), "Apple 140 W on a 100 W cable")
    check(powerCause(ratedW: 140, negotiatedW: 94, cable: CableRating(volts: 50, amps: 5, epr: true)) == .weakAdapter(gotW: 94), "EPR cable is not the limit")
    check(powerCause(ratedW: 140, negotiatedW: 60, cable: c100, magSafe: true) == .weakAdapter(gotW: 60), "MagSafe ignores USB-C cables")

    // Limit line: cable causes always, a weak adapter only during a shortage.
    check(powerLimit(plugged: true, short: false, ratedW: 140, negotiatedW: 94, cable: nil, magSafe: false) == .cable(ratedW: 140, gotW: 94), "cable shown without shortage")
    check(powerLimit(plugged: true, short: false, ratedW: nil, negotiatedW: 60, cable: nil, magSafe: false) == nil, "weak adapter hidden without shortage")
    check(powerLimit(plugged: true, short: true, ratedW: nil, negotiatedW: 60, cable: nil, magSafe: true) == .weakAdapter(gotW: 60), "weak adapter during shortage")
    check(powerLimit(plugged: false, short: true, ratedW: 140, negotiatedW: 94, cable: nil, magSafe: false) == nil, "on battery")

    // Tips: shortage on the adapter and not already in Low Power.
    let tip = PowerTip.lowPowerOnAdapter(.cable(ratedW: 140, gotW: 94))
    check(powerTips(plugged: true, short: true, acMode: .automatic, ratedW: 140, negotiatedW: 94) == [tip], "shortage, automatic")
    check(powerTips(plugged: true, short: true, acMode: nil, ratedW: 140, negotiatedW: 94) == [tip], "mode unknown still advises")
    check(powerTips(plugged: true, short: true, acMode: .high, ratedW: 140, negotiatedW: 94) == [tip], "high power advises")
    check(powerTips(plugged: true, short: true, acMode: .low, ratedW: 140, negotiatedW: 94) == [], "already low power")
    check(powerTips(plugged: true, short: false, acMode: .automatic, ratedW: 140, negotiatedW: 94) == [], "no shortage")
    check(powerTips(plugged: false, short: true, acMode: .automatic, ratedW: nil, negotiatedW: nil) == [], "on battery")
}
