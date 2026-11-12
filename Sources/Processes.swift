import AppKit
import SwiftUI

/// Processes section: the heat table with its toolbar and footnote.
struct ProcessesView: View {
    var m: Monitor

    var body: some View {
        Text("Процессы").frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct HeatBar: View {
    let percent: Double
    let watts: Double
    let share: Double
    let estimated: Bool
    var body: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary.opacity(0.5))
                Capsule().fill(share > 0.6 ? Color.red : share > 0.25 ? .orange : .yellow)
                    .frame(width: 50 * min(max(share, 0), 1))
            }
            .frame(width: 50, height: 6)
            VStack(alignment: .trailing, spacing: 1) {
                Text((estimated ? "≈" : "") + pct(percent)).monospacedDigit()
                Text((estimated ? "≈" : "") + wFine(watts)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .help(wFine(watts) + " · " + tr(estimated ? "Оценка по времени CPU: macOS считает энергию на всё приложение, здесь она поделена между его процессами"
              : "Энергия CPU по учёту macOS плюс доля энергии GPU"))
    }
}

/// Shares of the Mac's maximum or of the current total; the choice is shared with Settings.
struct HeatBasePicker: View {
    var m: Monitor
    @AppStorage(Pref.heatBase) private var raw = HeatBase.auto.rawValue
    var body: some View {
        Picker("Нагрев", selection: Binding(get: { m.heatBase }, set: { raw = $0.rawValue })) {
            Text("От максимума").tag(HeatBase.maximum)
            Text("От общей").tag(HeatBase.total)
        }
        .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
        .help("От максимума: какую часть полной мощности CPU и GPU берёт процесс. От общей: его доля в текущей нагрузке, вместе 100%.")
    }
}

struct ProcessTable: View {
    @Bindable var m: Monitor
    // Redraws the table at once when the heat base changes here or in Settings.
    @AppStorage(Pref.heatBase) private var heatBaseRaw = HeatBase.auto.rawValue
    @Binding var selection: Set<Row.ID>
    @Binding var columns: TableColumnCustomization<Row>

    var body: some View {
        Table(m.rows, selection: $selection, sortOrder: $m.sortOrder, columnCustomization: $columns) {
            TableColumn("Процесс", value: \.name) { row in
                HStack(spacing: 6) {
                    // Fixed slot keeps icons aligned whether or not the flame is shown.
                    Image(systemName: "flame.fill").foregroundStyle(.orange)
                        .opacity(m.hottest.contains(row.id) ? 1 : 0)
                        .frame(width: 12)
                        .help("Один из главных источников нагрева")
                    Image(nsImage: row.icon).resizable().frame(width: 16, height: 16)
                    Text(row.name).lineLimit(1).truncationMode(.middle).help(row.name)
                    if row.count > 1 { Text("×\(row.count)").foregroundStyle(.secondary) }
                }
            }
            .width(min: 180, ideal: 280, max: 340)
            .customizationID("name")
            .disabledCustomizationBehavior(.visibility)
            TableColumn("Нагрев", value: \.heat) { row in
                HeatBar(percent: m.heatShare(row), watts: row.heat, share: m.heatShare(row) / 100, estimated: row.estimated)
            }
            .width(145)
            .customizationID("heat")
            TableColumn("CPU", value: \.cpuShare) { row in
                VStack(alignment: .trailing, spacing: 1) {
                    Text(pct(row.cpuShare)).monospacedDigit()
                    Text(String(format: tr("≈%.1f ядра"), row.cpu / 100)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .help(tr("CPU: 100% — весь процессор, а не одно ядро.") + " " + String(format: tr("По шкале одного ядра: %.1f%%."), row.cpu))
            }
            .width(100)
            .customizationID("cpu")
            TableColumn("Время GPU", value: \.gpu) { row in
                Text(pct(row.gpu)).monospacedDigit()
                    .help(tr("Время GPU за интервал. Это не доля общей мощности GPU; значения процессов могут суммироваться выше 100%."))
                    .foregroundStyle(row.gpu < 0.05 ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(80)
            .customizationID("gpu")
            TableColumn("Память", value: \.memMB) { row in
                Text(row.memMB >= 1024 ? String(format: tr("%.1f ГБ"), row.memMB / 1024) : String(format: tr("%.0f МБ"), row.memMB))
                    .monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(110)
            .customizationID("mem")
        }
        .contextMenu(forSelectionType: Row.ID.self) { ids in
            if let id = ids.first, let row = m.rows.first(where: { $0.id == id }) {
                Button("Найти в интернете, что это") { m.search(row) }
                Divider()
                Button("Завершить «\(row.name)»") { m.terminate(row) }
                if let path = row.appPath {
                    Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                }
            }
        }
    }
}

