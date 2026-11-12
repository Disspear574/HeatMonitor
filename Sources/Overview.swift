import SwiftUI

/// Overview section: the verdict, temperature, what heats the Mac and three small cards.
struct OverviewView: View {
    var m: Monitor
    let open: (WindowSection) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.gap) {
                VerdictCard(m: m, open: open)
                WeightedColumns(weights: [1.25, 1]) {
                    TemperatureCard(m: m).stretchedCard()
                    HeatTopCard(m: m, open: open).stretchedCard()
                }
                WeightedColumns(weights: [1, 1, 1]) {
                    PowerMiniCard(m: m).stretchedCard()
                    LoadMiniCard(m: m).stretchedCard()
                    switch fanCardKind(fanCount: m.fans.count) {
                    case .fans: FanMiniCard(m: m).stretchedCard()
                    case .chassis: CaseCard(m: m).stretchedCard()
                    }
                }
            }
            .padding(Theme.edge)
        }
    }
}

/// Three clickable lines: how hot, what heats, whether power is enough.
private struct VerdictCard: View {
    var m: Monitor
    let open: (WindowSection) -> Void

    var body: some View {
        VStack(spacing: 0) {
            heatRow
            Divider()
            sourceRow
            Divider()
            powerRow
        }
        // The mockup gives this card 6 pt top and bottom instead of 12.
        .padding(.vertical, -6)
        .card()
    }

    private var heatRow: some View {
        let level = TempLevel.optional(m.cpuHot)
        let detail = m.cpuHot.map { fmt($0) + " · " + thermalText(m.thermal).0.localizedLowercase } ?? tr("собираю данные…")
        return VerdictRow(label: "Тепло", word: level?.word ?? "—", wordColor: level?.text ?? .secondary, detail: detail) {
            open(.cooling)
        }
    }

    private var sourceRow: some View {
        let causes = extraHeatCauses(gpuWatts: m.gpuWatts, batteryW: m.battery?.batteryW).map { cause in
            switch cause {
            case .graphics(let watts): String(format: tr("графика тратит %.0f Вт"), watts)
            case .fastCharge(let watts): String(format: tr("быстрая зарядка +%.0f Вт"), watts)
            }
        }
        var word = "", parts = causes
        if let row = m.hottestRow {
            let share = (row.estimated ? "≈" : "") + pct(m.heatShare(row))
            word = row.name
            parts.insert(wFine(row.heat) + " · " + String(format: tr(m.heatBase == .maximum ? "%@ от максимума Mac" : "%@ от общей нагрузки"), share), at: 0)
        } else if m.rows.isEmpty {
            word = "—"
            parts = [tr("собираю данные…")]
        } else if parts.isEmpty {
            parts = [tr("Нагрузка маленькая — сейчас ничего не греет")]
        }
        return VerdictRow(label: "Греет", word: word, detail: parts.joined(separator: " · ")) { open(.processes) }
    }

    private var powerRow: some View {
        let p = PowerLine(m.battery)
        return VerdictRow(label: "Питание", word: p.word, wordColor: p.color, detail: p.detail) { open(.power) }
    }
}

private struct VerdictRow: View {
    let label: LocalizedStringKey
    let word: String
    var wordColor: Color = .primary
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
                if !word.isEmpty {
                    Text(word).fontWeight(.semibold).foregroundStyle(wordColor).lineLimit(1).truncationMode(.tail)
                }
                Text(detail).foregroundStyle(.secondary).monospacedDigit().lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Power verdict as a coloured word and a detail, shared by the verdict row and the small card.
private struct PowerLine {
    let word: String
    let detail: String
    let color: Color
    var short = false

    init(_ b: SystemInfo.Battery?) {
        switch PowerVerdict.make(plugged: b?.plugged, batteryW: b?.batteryW, adapterInW: b?.adapterInW,
                                 adapterMaxW: b?.adapterMaxW, systemW: b?.systemW) {
        case .enough(let spare):
            (word, detail, color) = (tr("Хватает"), spare.map { String(format: tr("запас %.0f Вт"), $0) } ?? "", TempLevel.ok.text)
        case .short(let deficit):
            short = true
            (word, detail, color) = (tr("Не хватает"), String(format: tr("из батареи %.1f Вт"), deficit), TempLevel.hot.text)
        case .battery(let draw):
            (word, detail, color) = (tr("От батареи"), w(draw), .primary)
        case .unknown:
            (word, detail, color) = ("", tr("нет данных о питании"), .secondary)
        }
    }
}

/// Big CPU temperature, its band on the 30–110° scale and the last 3 minutes; Cooling shows it too.
struct TemperatureCard: View {
    var m: Monitor

    var body: some View {
        let level = TempLevel.optional(m.cpuHot)
        let thermal = thermalText(m.thermal)
        VStack(alignment: .leading, spacing: 0) {
            CardTitle("Температура CPU").padding(.bottom, 8)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                RollingText(value: fmt(m.cpuHot))
                    .font(.system(size: 48, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(level?.text ?? .secondary)
                Text(level?.word ?? tr("собираю данные…"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(level?.text ?? .secondary)
            }
            Text(thermal.0).foregroundStyle(thermal.1).padding(.top, 4)
            TempScale(t: m.cpuHot, peak: m.cpuPeak).padding(.top, 14)
            TempTicks().padding(.top, 4)
            Sparkline(values: m.history)
                .frame(height: 62)
                .overlay(alignment: .top) { Divider() }
                .overlay(alignment: .bottom) { Divider() }
                .padding(.top, 10)
            HStack {
                Text("3 мин назад")
                Spacer()
                if let lo = m.history.min(), let hi = m.history.max() {
                    Text(String(format: tr("диапазон %.0f–%.0f°"), lo, hi))
                    Spacer()
                }
                Text("сейчас")
            }
            .font(.system(size: 10)).monospacedDigit().foregroundStyle(.tertiary)
            .padding(.top, 2)
        }
    }
}

/// Four colour zones with the current reading as a bar and the 5 s peak as a thin line.
private struct TempScale: View {
    let t: Double?
    let peak: Double?

    private static let zones = Gradient(stops: [
        .init(color: TempLevel.ok.fill, location: 0), .init(color: TempLevel.ok.fill, location: 0.5),
        .init(color: TempLevel.warm.fill, location: 0.5), .init(color: TempLevel.warm.fill, location: 0.6875),
        .init(color: TempLevel.hot.fill, location: 0.6875), .init(color: TempLevel.hot.fill, location: 0.875),
        .init(color: TempLevel.crit.fill, location: 0.875), .init(color: TempLevel.crit.fill, location: 1),
    ])

    var body: some View {
        GeometryReader { g in
            let width = g.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(gradient: Self.zones, startPoint: .leading, endPoint: .trailing))
                    .opacity(0.9)
                    .frame(height: 8)
                if let peak {
                    Rectangle().fill(.secondary).frame(width: 2, height: 12)
                        .offset(x: min(max(width * scaleFraction(peak) - 1, 0), width - 2))
                }
                if let t {
                    RoundedRectangle(cornerRadius: 2).fill(.primary).frame(width: 4, height: 16)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Theme.cardHighlight).padding(-2))
                        .offset(x: min(max(width * scaleFraction(t) - 2, 0), width - 4))
                }
            }
            .frame(width: width, height: 16)
        }
        .frame(height: 16)
    }
}

private struct TempTicks: View {
    private static let marks: [Double] = [30, 70, 85, 100, 110]

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .topLeading) {
                ForEach(Self.marks, id: \.self) { t in
                    // Edge labels stay inside the card; the middle ones centre on their threshold.
                    let anchor: CGFloat = t == Self.marks.first ? 0 : t == Self.marks.last ? 1 : 0.5
                    Text(fmt(t)).fixedSize()
                        .alignmentGuide(.leading) { d in d.width * anchor - g.size.width * scaleFraction(t) }
                }
            }
        }
        .font(.system(size: 10)).monospacedDigit().foregroundStyle(.tertiary)
        .frame(height: 13)
    }
}

/// The five hottest processes, whatever the table's sort order.
private struct HeatTopCard: View {
    var m: Monitor
    let open: (WindowSection) -> Void

    var body: some View {
        let top = Array(m.rows.sorted { $0.heat > $1.heat }.prefix(5))
        VStack(alignment: .leading, spacing: 0) {
            CardTitle("Что греет Mac").padding(.bottom, 4)
            if top.isEmpty {
                Text("Собираю список процессов…").foregroundStyle(.secondary).padding(.vertical, 4)
            }
            ForEach(top) { row in
                let share = m.heatShare(row)
                HStack(spacing: 8) {
                    Image(nsImage: row.icon).resizable().frame(width: 16, height: 16)
                    (Text(row.name) + (row.count > 1 ? Text(verbatim: " ×\(row.count)").foregroundStyle(.secondary) : Text(verbatim: "")))
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                    LevelBar(fraction: max(share, 3) / 100,
                             color: (share > 60 ? TempLevel.crit : share > 25 ? .hot : .warm).fill, height: 5)
                        .frame(width: 54)
                    Text((row.estimated ? "≈" : "") + wFine(row.heat))
                        .monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .trailing)
                }
                .padding(.vertical, 4)
            }
            Spacer(minLength: 0)
            Button("Все процессы") { open(.processes) }
                .buttonStyle(.link)
                .padding(.top, 8)
        }
    }
}

private struct PowerMiniCard: View {
    var m: Monitor

    var body: some View {
        let p = PowerLine(m.battery)
        VStack(alignment: .leading, spacing: 0) {
            CardTitle("Питание").padding(.bottom, 8)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if !p.word.isEmpty { Text(p.word).fontWeight(.semibold).foregroundStyle(p.color) }
                if !p.detail.isEmpty {
                    Text((p.word.isEmpty ? "" : "· ") + p.detail).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .lineLimit(1)
            if let b = m.battery, b.plugged, let inW = b.adapterInW, let maxW = b.adapterMaxW, maxW > 0 {
                LevelBar(fraction: inW / Double(maxW), color: (p.short ? TempLevel.hot : .ok).fill)
                    .padding(.top, 8).padding(.bottom, 6)
                Text(String(format: tr("%.0f из %ld Вт"), inW, maxW))
                    .foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }
}

private struct LoadMiniCard: View {
    var m: Monitor

    var body: some View {
        let cores = String(format: tr("≈%.1f ядра"), m.cpuUsage / 100 * Double(SystemInfo.cores))
        let gpu = m.gpu.map { pct($0) + (m.gpuWatts.map { " · " + w($0) } ?? "") } ?? "—"
        VStack(alignment: .leading, spacing: 0) {
            CardTitle("Нагрузка").padding(.bottom, 3)
            LabeledValueRow(label: Text(verbatim: "CPU"), value: Text(pct(m.cpuUsage) + " · " + cores))
            Divider()
            LabeledValueRow(label: Text(verbatim: "GPU"), value: Text(gpu))
            Divider()
            LabeledValueRow(label: Text("Память"), value: Text(ofGB(m.memUsed, SystemInfo.totalRAM)))
            Divider()
            LabeledValueRow(label: Text("Своп"),
                            value: Text(m.swap.total > 0 ? ofGB(m.swap.used, m.swap.total) : tr("нет")))
        }
    }
}

private struct FanMiniCard: View {
    var m: Monitor

    var body: some View {
        let rpm = m.fans.map(\.rpm).max() ?? 0
        VStack(alignment: .leading, spacing: 0) {
            CardTitle("Вентиляторы").padding(.bottom, 8)
            Text(rpm < 1 ? tr("стоят") : String(format: tr("%.0f об/мин"), rpm))
                .font(.system(size: 17, weight: .semibold)).monospacedDigit()
                .padding(.bottom, 8)
            FanSwitch(m: m)
            if let message = m.fanMessage {
                Text(message).font(.system(size: 11)).foregroundStyle(TempLevel.hot.text)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }
        }
    }
}

/// One label–value line of a card.
struct LabeledValueRow: View {
    let label: Text
    let value: Text

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            label.foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            value.monospacedDigit().multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 5)
    }
}

/// Columns that share the width by weight and stretch to the tallest one, as the mockup's CSS grid does.
struct WeightedColumns: Layout {
    var weights: [CGFloat]
    var spacing: CGFloat = Theme.gap

    private func widths(_ total: CGFloat, count: Int) -> [CGFloat] {
        let w = (0..<count).map { $0 < weights.count ? weights[$0] : 1 }
        let free = max(total - spacing * CGFloat(max(count - 1, 0)), 0)
        let sum = max(w.reduce(0, +), 1)
        return w.map { free * $0 / sum }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let total = proposal.width ?? subviews.reduce(spacing * CGFloat(max(subviews.count - 1, 0))) {
            $0 + $1.sizeThatFits(.unspecified).width
        }
        let height = zip(subviews, widths(total, count: subviews.count))
            .map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }.max() ?? 0
        return CGSize(width: total, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (view, width) in zip(subviews, widths(bounds.width, count: subviews.count)) {
            view.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }
}

extension View {
    // Cards in one row take the row's full height, so their bottoms line up.
    func stretchedCard() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).card()
    }
}
