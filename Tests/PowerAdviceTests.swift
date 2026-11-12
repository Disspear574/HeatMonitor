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

    // Tips: shortage on the adapter and not already in Low Power.
    let tip = PowerTip.lowPowerOnAdapter(.cable(ratedW: 140, gotW: 94))
    check(powerTips(plugged: true, short: true, acMode: .automatic, ratedW: 140, negotiatedW: 94) == [tip], "shortage, automatic")
    check(powerTips(plugged: true, short: true, acMode: nil, ratedW: 140, negotiatedW: 94) == [tip], "mode unknown still advises")
    check(powerTips(plugged: true, short: true, acMode: .high, ratedW: 140, negotiatedW: 94) == [tip], "high power advises")
    check(powerTips(plugged: true, short: true, acMode: .low, ratedW: 140, negotiatedW: 94) == [], "already low power")
    check(powerTips(plugged: true, short: false, acMode: .automatic, ratedW: 140, negotiatedW: 94) == [], "no shortage")
    check(powerTips(plugged: false, short: true, acMode: .automatic, ratedW: nil, negotiatedW: nil) == [], "on battery")
}
