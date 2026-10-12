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
        monitor.$readings.sink { [weak self] r in self?.refreshLabel(r) }.store(in: &bag)
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

    func popoverDidShow(_ n: Notification) { onPanel(true) }
    func popoverDidClose(_ n: Notification) { onPanel(false) }

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
    @ObservedObject var m: Monitor
    let close: () -> Void
    @AppStorage(Pref.panelBlocks) private var blocksRaw = encodeSet(Set(PanelBlock.allCases))

    var body: some View {
        let blocks: Set<PanelBlock> = decodeSet(blocksRaw)
        VStack(alignment: .leading, spacing: 12) {
            if blocks.contains(.temperature) { temperature }
            if blocks.contains(.sensors) {
                row([("CPU средн.", fmt(m.cpuMean)), ("GPU", fmt(m.gpuHot)), ("SSD", fmt(m.ssd)), ("Батарея", fmt(m.batteryTemp))])
            }
            if blocks.contains(.load) {
                row([("CPU", String(format: "%.0f%%", m.cpuUsage)), ("GPU", m.gpu.map { String(format: "%.0f%%", $0) } ?? "—"),
                     m.swap.used >= 50e6
                        ? ("Память + swap", String(format: tr("%@ из %@ ГБ + %@ ГБ"), gb(m.memUsed), gbTotal(SystemInfo.totalRAM), gb(m.swap.used)))
                        : ("Память", ofGB(m.memUsed, SystemInfo.totalRAM))])
            }
            if blocks.contains(.power), let b = m.battery {
                let s = adapterStatus(b)
                Label(s.1, systemImage: s.0).font(.callout).foregroundStyle(s.2).fixedSize(horizontal: false, vertical: true)
            }
            if blocks.contains(.apps) { apps }
            if blocks.contains(.fans), !m.fans.isEmpty { FanSwitch(m: m) }
            Divider()
            HStack {
                Button("Открыть окно") { close(); Windows.shared.showMain(m) }
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }
                    .help("Настройки")
                    .simultaneousGesture(TapGesture().onEnded { close(); NSApp.activate(ignoringOtherApps: true) })
                Button("Выйти") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private var temperature: some View {
        let state = thermalText(m.thermal)
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(fmt(m.cpuHot))
                    .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(tempColor(m.cpuHot ?? 0))
                Text("пик за 5 с: \(fmt(m.cpuPeak))").font(.caption).foregroundStyle(.secondary)
                Text(state.0).font(.caption).foregroundStyle(state.1).lineLimit(2)
            }
            .frame(width: 120, alignment: .leading)
            Sparkline(values: m.history).frame(height: 44)
        }
    }

    private func row(_ items: [(LocalizedStringKey, String)]) -> some View {
        HStack(spacing: 12) {
            ForEach(items.indices, id: \.self) { i in Stat(title: items[i].0, value: items[i].1) }
        }
    }

    private var apps: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Что греет Mac").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(m.rows.prefix(5)) { r in
                HStack(spacing: 6) {
                    Image(nsImage: r.icon).resizable().frame(width: 16, height: 16)
                    Text(r.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(String(format: "%.1f", r.heat)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
    }
}
