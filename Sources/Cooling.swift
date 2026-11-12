import SwiftUI

/// Cooling section: temperature, sensors and fans or the chassis.
struct CoolingView: View {
    var m: Monitor

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.gap) {
                WeightedColumns(weights: [1.25, 1]) {
                    TemperatureCard(m: m).stretchedCard()
                    SensorList(m: m).stretchedCard()
                }
                switch fanCardKind(fanCount: m.fans.count) {
                case .fans: FanCard(m: m).card()
                case .chassis: CaseCard(m: m).card()
                }
            }
            .padding(Theme.edge)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { SensorsButton() }
        }
    }
}

/// Named temperatures; a sensor this Mac lacks is left out, not shown as a dash.
private struct SensorList: View {
    var m: Monitor

    private struct Entry {
        let label: Text
        let value: Text
    }

    private var entries: [Entry] {
        var out: [Entry] = []
        func add(_ label: Text, _ t: Double?, coloured: Bool) {
            guard let t else { return }
            out.append(Entry(label: label, value: Text(fmt(t)).foregroundStyle(coloured ? tempColor(t) : .primary)))
        }
        add(Text("CPU, самое горячее ядро"), m.cpuHot, coloured: true)
        add(Text("CPU, пик за 5 с"), m.cpuPeak, coloured: false)
        add(Text("CPU в среднем"), m.cpuMean, coloured: true)
        add(Text(verbatim: "GPU"), m.gpuHot, coloured: true)
        add(Text(verbatim: "SSD"), m.ssd, coloured: false)
        add(Text("Батарея"), m.batteryTemp, coloured: false)
        if !m.palmRest.isEmpty {
            out.append(Entry(label: Text("Трекпад"), value: Text(m.palmRest.map(fmt).joined(separator: " · "))))
        }
        return out
    }

    var body: some View {
        let rows = entries
        VStack(alignment: .leading, spacing: 0) {
            CardTitle("Датчики").padding(.bottom, 3)
            if rows.isEmpty {
                Text("собираю данные…").foregroundStyle(.secondary).padding(.vertical, 5)
            }
            ForEach(rows.indices, id: \.self) { i in
                if i > 0 { Divider() }
                LabeledValueRow(label: rows[i].label, value: rows[i].value)
            }
        }
    }
}

/// Every fan's speed with the Auto / Max switch and its error under it.
private struct FanCard: View {
    var m: Monitor

    private var speeds: String {
        guard m.fans.contains(where: { $0.rpm >= 1 }) else { return tr("стоят") }
        return m.fans.map { String(format: tr("%.0f об/мин"), $0.rpm) }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardTitle("Вентиляторы").padding(.bottom, 8)
            HStack(alignment: .center, spacing: 10) {
                Text(speeds).font(.system(size: 17, weight: .semibold)).monospacedDigit()
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                FanSwitch(m: m).fixedSize()
            }
            Text("Макс спрашивает пароль администратора. При выходе из приложения вентиляторы вернутся в Авто.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            if let message = m.fanMessage {
                Text(message).font(.system(size: 11)).foregroundStyle(TempLevel.hot.text)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }
        }
    }
}

/// Trackpad temperatures on a Mac without fans, where heat leaves through the case.
struct CaseCard: View {
    var m: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardTitle("Корпус").padding(.bottom, 3)
            LabeledValueRow(label: Text("Трекпад"), value: trackpad)
            Text("без вентиляторов: macOS охлаждает снижением частот")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
    }

    private var trackpad: Text {
        guard !m.palmRest.isEmpty else { return Text(verbatim: "—") }
        return m.palmRest.enumerated().reduce(Text(verbatim: "")) { text, item in
            text + Text(item.offset > 0 ? " · " : "") + Text(fmt(item.element)).foregroundStyle(caseColor(item.element))
        }
    }
}
