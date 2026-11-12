import AppKit
import Combine
import SwiftUI

/// The menu bar item: left click toggles the panel, right click offers Open and Quit.
@MainActor
final class StatusController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let monitor: Monitor
    private let onPanel: (Bool) -> Void
    private var bag: Set<AnyCancellable> = []

    init(monitor: Monitor, onPanel: @escaping (Bool) -> Void) {
        self.monitor = monitor
        self.onPanel = onPanel
        super.init()
        let host = NSHostingController(rootView: MenuPanel(m: monitor) { [weak self] in self?.popover.performClose(nil) })
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.delegate = self
        if let b = item.button {
            b.target = self
            b.action = #selector(click)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            b.imagePosition = .imageLeading
        }
        monitor.onReadings = { [weak self] r in self?.refreshLabel(r) }
        refreshLabel(monitor.readings)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self.map { $0.refreshLabel($0.monitor.readings) } } }
            .store(in: &bag)
    }

    @objc private func click() {
        if NSApp.currentEvent?.type == .rightMouseUp { return showMenu() }
        if popover.isShown { return popover.performClose(nil) }
        guard let b = item.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: tr("Открыть Диспетчер тепла"), action: #selector(openMain), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: tr("Выйти"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func openMain() { Windows.shared.showMain(monitor) }

    private var outsideClicks: Any?

    // A transient popover in an app without a Dock icon never sees clicks in other apps, so those are watched here.
    func popoverDidShow(_ n: Notification) {
        onPanel(true)
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.popover.performClose(nil) }
        }
    }

    func popoverDidClose(_ n: Notification) {
        onPanel(false)
        if let outsideClicks { NSEvent.removeMonitor(outsideClicks) }
        outsideClicks = nil
    }

    private func refreshLabel(_ r: Readings) {
        guard let b = item.button else { return }
        let d = UserDefaults.standard
        let parts = d.bool(forKey: Pref.liveLabel)
            ? MenuLabel.parts(r, values: decodeSet(d.string(forKey: Pref.labelValues) ?? ""), wattFormat: tr("%.0f Вт")) : []
        b.image = parts.isEmpty ? Self.symbol("thermometer.medium") : nil
        b.attributedTitle = Self.title(parts)
        b.setAccessibilityLabel(([tr("Диспетчер тепла")] + parts.map(\.text)).joined(separator: " "))
    }

    private static func title(_ parts: [MenuPart]) -> NSAttributedString {
        let s = NSMutableAttributedString()
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        for (i, p) in parts.enumerated() {
            if i > 0 { s.append(NSAttributedString(string: "  ")) }
            let a = NSTextAttachment()
            a.image = symbol(p.symbol)
            s.append(NSAttributedString(attachment: a))
            s.append(NSAttributedString(string: " " + p.text, attributes: [.font: font]))
        }
        return s
    }

    private static func symbol(_ name: String) -> NSImage? {
        let i = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        i?.isTemplate = true
        return i
    }
}

/// The compact panel in the menu bar popover; blocks follow the Panel settings.
struct MenuPanel: View {
    var m: Monitor
    let close: () -> Void
    @AppStorage(Pref.panelBlocks) private var blocksRaw = encodeSet(Set(PanelBlock.allCases))
    // Redraws the app list at once when the heat base changes.
    @AppStorage(Pref.heatBase) private var heatBaseRaw = HeatBase.auto.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let blocks: Set<PanelBlock> = decodeSet(blocksRaw)
        VStack(alignment: .leading, spacing: 8) {
            if blocks.contains(.temperature) { temperature }
            if blocks.contains(.sensors) {
                values([("CPU средн.", fmt(m.cpuMean), m.cpuMean.map(tempColor)), ("GPU", fmt(m.gpuHot), m.gpuHot.map(tempColor)),
                        ("SSD", fmt(m.ssd), nil), ("Батарея", fmt(m.batteryTemp), nil)])
            }
            if blocks.contains(.load) {
                let load: [(LocalizedStringKey, String, Color?)] = [("CPU", pct(m.cpuUsage), nil), ("GPU", m.gpu.map { pct($0) } ?? "—", nil),
                                                                   ("Память", String(format: tr("%@ ГБ"), gb(m.memUsed)), nil)]
                values(m.swap.used >= 50e6 ? load + [("Своп", String(format: tr("%@ ГБ"), gb(m.swap.used)), nil)] : load)
            }
            if blocks.contains(.power) { power }
            if blocks.contains(.apps) { apps }
            if blocks.contains(.fans), !m.fans.isEmpty { fans }
            HStack {
                Button("Открыть окно") { close(); Windows.shared.showMain(m) }
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }
                    .help("Настройки")
                    .simultaneousGesture(TapGesture().onEnded { close(); NSApp.activate(ignoringOtherApps: true) })
                Button("Выйти") { NSApp.terminate(nil) }
            }
            .padding(.top, 4)
        }
        .padding(12)
        .frame(width: 340)
    }

    private var temperature: some View {
        let state = tempWord(m.cpuHot, m.thermal)
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                CardTitle("Температура CPU")
                Text(fmt(m.cpuHot))
                    .font(.system(size: 36, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(TempLevel.optional(m.cpuHot)?.text ?? .secondary)
                    .contentTransition(.numericText(value: m.cpuHot ?? 0))
                    .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: m.cpuHot)
                Text(m.cpuHot == nil ? tr("собираю данные…") : state.0)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(m.cpuHot == nil ? .secondary : state.1)
                    .lineLimit(2)
                Text("пик за 5 с: \(fmt(m.cpuPeak))").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            .frame(width: 128, alignment: .leading)
            Sparkline(values: m.history).frame(height: 52)
        }
        .card()
    }

    private func values(_ items: [(LocalizedStringKey, String, Color?)]) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(items.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 2) {
                    Text(items[i].0).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Text(items[i].1).font(.system(size: 13, weight: .medium)).monospacedDigit()
                        .foregroundStyle(items[i].2 ?? .primary).lineLimit(1).minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .card()
    }

    @ViewBuilder private var power: some View {
        let supply = powerSupplies(m.ports)
        let devices = usbDevices(m.ports)
        if m.battery != nil || supply != nil || !devices.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                CardTitle("Питание")
                if let b = m.battery {
                    let line = PowerLine(b)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if !line.word.isEmpty { Text(line.word).fontWeight(.semibold).foregroundStyle(line.color) }
                        Text(line.detail).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .lineLimit(1)
                    let draw = b.systemW.map { String(format: tr("Mac берёт %.0f Вт"), $0) }
                    let adapter = b.plugged ? b.adapterInW.flatMap { inW in
                        b.adapterMaxW.map { String(format: tr("адаптер %.0f из %ld Вт"), inW, $0) }
                    } : nil
                    let usage = [draw, adapter].compactMap { $0 }
                    if !usage.isEmpty {
                        Text(usage.joined(separator: " · ")).foregroundStyle(.secondary).monospacedDigit()
                    }
                    if line.short, let cause = powerLimit(b, ports: m.ports) {
                        Text(powerCauseText(cause)).font(.system(size: 11)).foregroundStyle(TempLevel.hot.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let supply {
                    Text(supplyText(supply)).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !devices.isEmpty {
                    Text("На USB-C: \(devices.map(deviceText).joined(separator: ", "))").font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .card()
        }
    }

    private var apps: some View {
        let top = Array(m.rows.sorted { $0.heat > $1.heat }.prefix(5))
        return VStack(alignment: .leading, spacing: 0) {
            CardTitle("Что греет Mac").padding(.bottom, 2)
            if top.isEmpty {
                Text("Собираю список процессов…").foregroundStyle(.secondary).padding(.vertical, 3)
            }
            ForEach(top) { r in
                let share = m.heatShare(r)
                HStack(spacing: 8) {
                    Image(nsImage: r.icon).resizable().frame(width: 16, height: 16)
                    Text(r.name).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    LevelBar(fraction: max(share, 3) / 100, color: (share > 60 ? TempLevel.crit : share > 25 ? .hot : .warm).fill, height: 5)
                        .frame(width: 44)
                    Text((r.estimated ? "≈" : "") + wFine(r.heat)).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .trailing)
                        .help((r.estimated ? "≈" : "") + pct(share))
                }
                .padding(.vertical, 3)
            }
        }
        .card()
    }

    private var fans: some View {
        let rpm = m.fans.map(\.rpm).max() ?? 0
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    CardTitle("Вентиляторы")
                    Text(rpm < 1 ? tr("стоят") : String(format: tr("%.0f об/мин"), rpm))
                        .font(.system(size: 13, weight: .medium)).monospacedDigit()
                }
                Spacer()
                FanSwitch(m: m).fixedSize()
            }
            if let message = m.fanMessage {
                Text(message).font(.system(size: 11)).foregroundStyle(TempLevel.hot.text).fixedSize(horizontal: false, vertical: true)
            }
        }
        .card()
    }
}
