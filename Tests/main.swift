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

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
