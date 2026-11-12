import SwiftUI

/// Power section: adapter verdict, power flow, source and ports, battery.
struct PowerView: View {
    var m: Monitor
    @StateObject private var energy = EnergyModeModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gap) {
                if let b = m.battery {
                    flowCard(b)
                    if b.plugged { energyCard(b) }
                    HStack(alignment: .top, spacing: Theme.gap) {
                        sourceCard
                        batteryCard(b)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    sourceCard
                    Text("Нет данных о батарее").foregroundStyle(.secondary)
                }
            }
            .padding(Theme.edge)
        }
        .onAppear { energy.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in energy.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in energy.refresh() }
    }

    private func energyCard(_ b: SystemInfo.Battery) -> some View {
        let short = b.batteryW.map { adapterShort(batteryW: $0, adapterInW: b.adapterInW, adapterMaxW: b.adapterMaxW) } ?? false
        let tips = powerTips(plugged: b.plugged, short: short, acMode: energy.acMode,
                             ratedW: ratedWatts(adapterName: energy.adapterName), negotiatedW: energy.negotiatedW ?? b.adapterMaxW)
        return VStack(alignment: .leading, spacing: 8) {
            CardTitle("Режим энергопотребления от адаптера")
            ForEach(Array(tips.enumerated()), id: \.offset) { _, tip in
                switch tip {
                case .lowPowerOnAdapter(let cause):
                    Label("Чтобы сберечь батарею, включите режим энергосбережения от адаптера", systemImage: "leaf")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(TempLevel.hot.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(causeText(cause)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("Включить энергосбережение") { energy.set(.low) }
                        .buttonStyle(.borderedProminent).disabled(energy.busy)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Сейчас: \(modeWord(energy.acMode))").lineLimit(2)
                Spacer(minLength: 0)
                if let mode = energy.acMode, mode != .automatic {
                    Button("Вернуть «Автоматически»") { energy.set(.automatic) }.disabled(energy.busy)
                }
            }
            if let error = energy.error {
                Text(error).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Text("macOS спросит пароль администратора; HeatMonitor его не видит и не хранит.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func causeText(_ cause: PowerCause) -> String {
        switch cause {
        case let .cable(rated, got):
            return String(format: tr("Адаптер %ld Вт, получено %ld Вт: ограничивает кабель, нужен USB-C 240 Вт (EPR)."), rated, got)
        case let .weakAdapter(got?):
            return String(format: tr("Адаптер даёт %ld Вт: слабый для такой нагрузки."), got)
        case .weakAdapter(nil):
            return tr("Адаптер слабый для такой нагрузки.")
        }
    }

    private func modeWord(_ mode: EnergyMode?) -> String {
        switch mode {
        case .automatic: tr("автоматически")
        case .low: tr("энергосбережение")
        case .high: tr("высокая производительность")
        case nil: "—"
        }
    }

    private func flowCard(_ b: SystemInfo.Battery) -> some View {
        let status = adapterStatus(b)
        return VStack(alignment: .leading, spacing: 0) {
            Label(status.1, systemImage: status.0)
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(status.2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 10)
            HStack(spacing: 8) {
                FlowBox(title: Text("Адаптер"), value: adapterValue(b), color: .primary)
                FlowArrow(symbol: b.plugged ? "arrow.right" : nil)
                FlowBox(title: Text("Mac потребляет"), value: w(b.systemW), color: .primary)
                FlowArrow(symbol: batteryArrow(b))
                FlowBox(title: b.percent.map { Text("Батарея \($0)%") } ?? Text("Батарея"),
                        value: batteryValue(b.batteryW), color: batteryColor(b.batteryW))
            }
            if b.plugged, let inW = b.adapterInW, let max = b.adapterMaxW, max > 0 {
                let load = inW / Double(max)
                LevelBar(fraction: load, color: load > 0.9 ? TempLevel.hot.fill : TempLevel.ok.fill)
                    .padding(.top, 20).padding(.bottom, 6)
                Text("Адаптер загружен на \(Int((load * 100).rounded()))%")
                    .foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .card()
    }

    private var sourceCard: some View {
        let devices = usbDevices(m.ports)
        return VStack(alignment: .leading, spacing: 8) {
            CardTitle("Источник и порты")
            if let p = powerSupplies(m.ports) {
                Label(supplyText(p), systemImage: "powerplug").fixedSize(horizontal: false, vertical: true)
            } else if m.battery?.plugged == false {
                Label(String(format: tr("Питание: %@."), tr("от батареи")), systemImage: "battery.50percent")
            }
            if devices.isEmpty {
                Text("Устройств USB-C нет").foregroundStyle(.secondary)
            }
            ForEach(Array(devices.enumerated()), id: \.offset) { _, d in
                Label(deviceText(d), systemImage: "cable.connector").fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .card()
    }

    private func batteryCard(_ b: SystemInfo.Battery) -> some View {
        let health = [b.healthPercent.map { "\($0)%" }, b.cycles.map { String(format: tr("%ld цикл."), $0) }]
            .compactMap { $0 }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 0) {
            CardTitle("Батарея").padding(.bottom, 3)
            ValueRow(key: "Заряд", value: b.percent.map { "\($0)%" } ?? "—")
            if !b.plugged, let left = b.minutesLeft {
                Divider()
                ValueRow(key: "Осталось", value: duration(Double(left * 60)))
            }
            Divider()
            ValueRow(key: "Здоровье", value: health.ifEmpty("—"))
            Divider()
            ValueRow(key: "Температура", value: fmt(m.batteryTemp))
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .card()
    }

    private func adapterValue(_ b: SystemInfo.Battery) -> String {
        guard b.plugged else { return tr("не подключён") }
        if let inW = b.adapterInW, let max = b.adapterMaxW { return String(format: tr("%.0f из %ld Вт"), inW, max) }
        return w(b.adapterInW)
    }

    // Off the adapter the battery feeds the Mac; on it, the arrow follows the battery's own flow.
    private func batteryArrow(_ b: SystemInfo.Battery) -> String? {
        guard b.plugged else { return "arrow.left" }
        guard let v = b.batteryW else { return nil }
        return v > 0.3 ? "arrow.right" : v < -0.3 ? "arrow.left" : nil
    }

    private func batteryValue(_ v: Double?) -> String {
        guard let v else { return "—" }
        if v > 0.3 { return String(format: tr("+%.1f Вт"), v) }
        if v < -0.3 { return String(format: tr("−%.1f Вт"), -v) }
        return tr("0 Вт")
    }

    private func batteryColor(_ v: Double?) -> Color {
        guard let v else { return .primary }
        return v > 0.3 ? TempLevel.ok.text : v < -0.3 ? TempLevel.hot.text : .primary
    }
}

/// One stage of the power flow: caption above a large wattage.
private struct FlowBox: View {
    let title: Text
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            title.foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.system(size: 17, weight: .semibold)).monospacedDigit().foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(.vertical, 10).padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .background(Theme.track, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Arrow between flow stages; an empty slot keeps the boxes aligned when nothing flows.
private struct FlowArrow: View {
    let symbol: String?

    var body: some View {
        Group {
            if let symbol { Image(systemName: symbol) } else { Color.clear }
        }
        .font(.system(size: 12)).foregroundStyle(.secondary)
        .frame(width: 14)
    }
}

/// Key on the left, value on the right, as in the mockup's key-value rows.
private struct ValueRow: View {
    let key: LocalizedStringKey
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(key).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            Text(value).monospacedDigit().multilineTextAlignment(.trailing).lineLimit(2)
        }
        .padding(.vertical, 5)
    }
}
