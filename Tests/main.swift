import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok { failures += 1; print("FAIL line \(line): \(what)") }
}
let t0 = Date(timeIntervalSince1970: 1_000)

// Heat base: auto follows whether the chip was measured; an explicit choice wins.
check(HeatBase.auto.resolved(measured: true) == .maximum, "auto on a measured chip uses the maximum")
check(HeatBase.auto.resolved(measured: false) == .total, "auto on an unmeasured chip uses the total")
check(HeatBase.maximum.resolved(measured: false) == .maximum, "explicit maximum stays")
check(HeatBase.total.resolved(measured: true) == .total, "explicit total stays")
check(heatPercent(7.3, of: .maximum, ceiling: 73, total: 10) == 10, "share of the maximum")
check(heatPercent(5, of: .total, ceiling: 73, total: 10) == 50, "share of the total")
check(heatPercent(1, of: .total, ceiling: 73, total: 0) == 0, "no load, no division by zero")

// splitWatts: measured members keep their value, the rest goes by weight, or to the first member when nobody is busy.
let sw = splitWatts(10, weights: [(1, 0), (2, 30), (3, 10)], fixed: [1: 2])
check(sw[1] == 2 && sw[2] == 6 && sw[3] == 2, "measured kept, rest by weight: \(sw)")
check(splitWatts(4, weights: [(7, 0), (5, 0)], fixed: [:]) == [7: 4], "idle members: first listed gets it")
check(splitWatts(1, weights: [(1, 5)], fixed: [1: 3]) == [1: 3], "measured above the total stays measured")
check(splitWatts(3, weights: [(1, 5), (2, 0)], fixed: [1: 1]) == [1: 1, 2: 2], "rest goes to the unmeasured member")
check(splitWatts(0, weights: [(1, 5)], fixed: [:]) == [1: 0], "no energy, zero watts")

// launchIdle: a window "closed" event before anything opened must not start polling.
var d = Demand()
d.set(window: false, now: t0)
check(!d.wantsFull(at: t0), "idle at launch")
check(d.stopAt == nil, "no stop deadline at launch")

// Panel open → full; closed → full for 60 s, then off.
d.set(panel: true, now: t0)
check(d.wantsFull(at: t0), "panel open polls")
check(d.stopAt == nil, "no deadline while open")
d.set(panel: false, now: t0)
check(d.wantsFull(at: t0.addingTimeInterval(59)), "grace 59 s")
check(!d.wantsFull(at: t0.addingTimeInterval(60)), "stops at 60 s")
check(d.stopAt == t0.addingTimeInterval(60), "deadline at 60 s")

// graceFromLastClose: panel closes, window opens and closes later → grace from the window close.
var g = Demand()
g.set(panel: true, now: t0)
g.set(panel: false, now: t0)
g.set(window: true, now: t0.addingTimeInterval(30))
g.set(window: false, now: t0.addingTimeInterval(50))
check(g.wantsFull(at: t0.addingTimeInterval(100)), "grace counts from last close")
check(g.stopAt == t0.addingTimeInterval(110), "deadline from last close")

// skipsMissing: fixed order, missing values skipped, empty selection → nothing.
let r = Readings(cpuTemp: 62.4, gpuTemp: 48, fanRPM: nil, systemW: 9.2, cpuLoad: 12.6)
let p = MenuLabel.parts(r, values: [.cpuLoad, .fan, .cpuTemp, .power])
check(p.map(\.text) == ["62°", "9 W", "13%"], "order and skip: \(p.map(\.text))")
check(p.first?.symbol == "thermometer.medium", "cpu temp symbol")
check(MenuLabel.parts(r, values: []).isEmpty, "empty selection")
check(MenuLabel.parts(r, values: [.power], wattFormat: "%.0f Вт").map(\.text) == ["9 Вт"], "watt format")

// Stored sets: stable order, unknown names ignored.
check(encodeSet(Set<MenuValue>([.power, .cpuTemp])) == "cpuTemp,power", "encode order")
check(decodeSet("power,bogus,cpuTemp") as Set<MenuValue> == [.power, .cpuTemp], "decode ignores unknown")
check(decodeSet(Pref.defaults[Pref.panelBlocks] as! String) as Set<PanelBlock> == Set(PanelBlock.allCases), "all blocks by default")
check(Pref.defaults[Pref.showInDock] as? Bool == false, "dock off by default")

// Macs without SMC core keys: CPU from IOHID die sensors, M2+ "PMU tdie*" first, M1 "ACC MTR".
check(hidCPU(["PMU tdie1": 50, "PMU tdie2": 57, "NAND CH0 temp": 40]) == 57, "tdie max")
check(hidCPU(["eACC MTR Temp Sensor0": 44, "gas gauge battery": 30]) == 44, "ACC MTR fallback")
check(hidCPU(["NAND CH0 temp": 40]) == nil, "no cpu sensor")

// adapterShort: a small battery draw with adapter headroom is not a shortage.
check(!adapterShort(batteryW: -0.9, adapterInW: 13.7, adapterMaxW: 85), "headroom, battery held at 100%")
check(adapterShort(batteryW: -5, adapterInW: 80, adapterMaxW: 85), "adapter at its limit")
check(adapterShort(batteryW: -2, adapterInW: nil, adapterMaxW: nil), "unknown adapter keeps the warning")
check(!adapterShort(batteryW: -0.3, adapterInW: 84, adapterMaxW: 85), "draw below 0.5 W")
check(!adapterShort(batteryW: nil, adapterInW: 84, adapterMaxW: 85), "no battery reading")

// usbDevices: a device on a data wire is named, a supply is not.
let iPhone = PortLink(type: "USB-C", name: "iPhone", transports: ["CC", "USB2"], supplyW: nil, powersMac: false, budgetW: 12)
let dock = PortLink(type: "USB-C", name: "Ugreen Thunderbolt 4 Docking Station", transports: ["CC", "USB2", "CIO"], supplyW: 85, powersMac: true)
let charger = PortLink(type: "USB-C", name: nil, transports: ["CC"], supplyW: 96, powersMac: false)
let magSafe = PortLink(type: "MagSafe 3", name: nil, transports: ["CC"], supplyW: 140, powersMac: false)
let devices = usbDevices([iPhone, dock, charger, magSafe])
check(devices.map(\.name) == ["iPhone"] && devices.first?.budgetW == 12, "dock and chargers are not devices; budget kept")
check(usbDevices([PortLink(type: "USB-C", name: " ", transports: ["CC", "USB3"], supplyW: nil, powersMac: false)]).isEmpty, "blank name")
check(usbDevices([PortLink(type: "USB-C", name: "Cable", transports: ["CC"], supplyW: nil, powersMac: false)]).isEmpty, "CC only")

// powerSupplies: the marked port powers the Mac, other supplies stand idle.
check(powerVia(dock) == .dock && powerVia(charger) == .charger && powerVia(magSafe) == .magSafe && powerVia(iPhone) == nil, "supply kinds")
let both = powerSupplies([iPhone, dock, magSafe])
check(both?.active == .dock && both?.idle.count == 1 && both?.idle.first?.via == .magSafe && both?.idle.first?.watts == 140, "dock wins, MagSafe idle")
check(both?.name == "Ugreen Thunderbolt 4 Docking Station", "active dock keeps its name")
check(powerSupplies([PortLink(type: "USB-C", name: "x", transports: ["CC"], supplyW: 96, powersMac: true)])?.name == nil, "a charger is not named")
check(powerSupplies([iPhone, magSafe]) == nil, "no marked supply")

// deviceName: the vendor's first word goes before the model unless the model already has it.
check(deviceName(vendor: "Ugreen Group Limited", model: "Thunderbolt 4 Docking Station (8-in-1)") == "Ugreen Thunderbolt 4 Docking Station (8-in-1)", "brand added")
check(deviceName(vendor: "CalDigit, Inc.", model: "CalDigit TS4") == "CalDigit TS4", "brand already in model")
check(deviceName(vendor: nil, model: "TS4") == "TS4", "no vendor")

// usbProductName: firmware underscores and shouting go, acronyms and mixed case stay.
check(usbProductName("SAMSUNG_Android") == "Samsung Android", "Samsung firmware name")
check(usbProductName("iPhone") == "iPhone", "mixed case kept")
check(usbProductName("USB 10/100/1000 LAN") == "USB 10/100/1000 LAN", "acronyms kept")
check(usbProductName("Portable SSD T7") == "Portable SSD T7", "short caps kept")

// Percentages use the whole CPU, keep small loads visible, and require fresh deltas.
check(machineCPUPercent(42, cores: 12) == 3.5, "42% of one core is 3.5% of a 12-core CPU")
check(machineCPUPercent(1200, cores: 12) == 100, "all cores fully busy")
check(machineCPUPercent(100, cores: 0) == 100, "invalid core count has safe fallback")
check(percentText(0) == "0%", "zero is zero, not less than 0.1")
check(percentText(0.04) == "<0.1%", "tiny positive load stays visible")
check(percentText(3.5) == "3.5%", "small load retains precision")
check(percentText(.nan) == "—", "invalid reading is unavailable")
check(intervalCPU(previous: nil, current: 999, seconds: 5) == nil, "first reading has no current CPU")
check(intervalCPU(previous: 100, current: 102.1, seconds: 5).map { abs($0 - 42) < 0.0001 } == true, "CPU delta over interval")
check(intervalCPU(previous: 100, current: 2, seconds: 5) == nil, "reset counter is unavailable")
check(intervalCPU(previous: 1, current: 2, seconds: 0) == nil, "zero interval is unavailable")

// TempLevel and scale: thresholds 70 / 85 / 100, scale 30–110.
check(TempLevel(69.9) == .ok && TempLevel(70) == .warm && TempLevel(85) == .hot && TempLevel(100) == .crit, "levels")
check(TempLevel(67).wordKey == "Норма" && TempLevel(120).wordKey == "Критично", "level words")
check(scaleFraction(30) == 0 && scaleFraction(70) == 0.5 && scaleFraction(110) == 1, "scale ends and middle")
check(scaleFraction(10) == 0 && scaleFraction(130) == 1, "scale clamps")
// No reading yet is shown as a dash, never as "ok".
check(TempLevel.optional(nil) == nil && TempLevel.optional(90) == .hot, "optional level")

// PowerVerdict: 33 of 140 W with a full battery is enough with 107 W spare.
check(PowerVerdict.make(plugged: true, batteryW: -1, adapterInW: 33, adapterMaxW: 140, systemW: 33.1) == .enough(spareW: 107), "enough + spare")
check(PowerVerdict.make(plugged: true, batteryW: -12, adapterInW: 64, adapterMaxW: 67, systemW: 76) == .short(deficitW: 12), "short")
check(PowerVerdict.make(plugged: false, batteryW: -9, adapterInW: nil, adapterMaxW: nil, systemW: 9) == .battery(drawW: 9), "on battery")
check(PowerVerdict.make(plugged: nil, batteryW: nil, adapterInW: nil, adapterMaxW: nil, systemW: nil) == .unknown, "no battery")

// Extra heat causes keep heatReason's thresholds.
check(extraHeatCauses(gpuWatts: 4.9, batteryW: 15) == [], "below thresholds")
check(extraHeatCauses(gpuWatts: 5, batteryW: 15.1) == [.graphics(5), .fastCharge(15.1)], "both, graphics first")

// A fanless Air gets the chassis card.
check(fanCardKind(fanCount: 0) == .chassis && fanCardKind(fanCount: 2) == .fans, "fan card kind")

// Advice: nothing while closed, 5 s until a CPU sample, then 60 s outside the section.
check(AdviceSchedule.interval(windowOnScreen: false, adviceShown: true, hasCPUSample: true) == nil, "closed: no timer")
check(AdviceSchedule.interval(windowOnScreen: true, adviceShown: false, hasCPUSample: false) == 5, "open: second read after 5 s")
check(AdviceSchedule.interval(windowOnScreen: true, adviceShown: false, hasCPUSample: true) == 60, "badge pace")
check(AdviceSchedule.interval(windowOnScreen: true, adviceShown: true, hasCPUSample: true) == 5, "section pace")

// Sections: ⌘1–⌘5 in sidebar order.
check(WindowSection.allCases.map(\.shortcut) == ["1", "2", "3", "4", "5"], "section shortcuts")
check(WindowSection.cooling.titleKey == "Охлаждение", "section title key")

powerAdviceTests()

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
