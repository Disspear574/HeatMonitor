import AppKit
import SwiftUI

/// Processes section: the heat table with its toolbar and footnote.
struct ProcessesView: View {
    @Bindable var m: Monitor
    // Redraws the footnote at once when the heat base changes here or in Settings.
    @AppStorage(Pref.heatBase) private var heatBaseRaw = HeatBase.auto.rawValue
    @State private var selection = Set<Row.ID>()
    @AppStorage("columns") private var storedColumns = Data()
    @State private var columns: TableColumnCustomization<Row> = {
        var c = TableColumnCustomization<Row>()
        c[visibility: "gpu"] = .hidden
        return c
    }()

    var body: some View {
        let selected = selection.first.flatMap { id in m.rows.first { $0.id == id } }
        VStack(alignment: .leading, spacing: 0) {
            if let message = m.message {
                Text(message).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.edge).padding(.vertical, 8)
            }
            ProcessTable(m: m, selection: $selection, columns: $columns)
                .environment(\.defaultMinListRowHeight, Theme.rowHeight)
                .overlay {
                    if m.rows.isEmpty {
                        ProgressView("Собираю список процессов…").controlSize(.small)
                    }
                }
            Text(footnote)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.edge).padding(.vertical, 10)
        }
        .toolbar { toolbar(selected) }
        .onChange(of: selection) { _, _ in m.message = nil }
        .onAppear {
            if let saved = try? JSONDecoder().decode(TableColumnCustomization<Row>.self, from: storedColumns) { columns = saved }
        }
        .onChange(of: columns) { _, c in storedColumns = (try? JSONEncoder().encode(c)) ?? Data() }
    }

    @ToolbarContentBuilder private func toolbar(_ selected: Row?) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            HStack(spacing: 6) {
                if let row = selected {
                    Image(nsImage: row.icon).resizable().frame(width: 16, height: 16)
                    Text(row.name).lineLimit(1).truncationMode(.middle).help(row.name)
                } else {
                    Text("Выберите процесс").foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: 220, alignment: .trailing)
            Button("Что это?") { if let row = selected { m.search(row) } }
                .disabled(selected == nil)
            Button("Завершить", role: .destructive) { if let row = selected { m.terminate(row) } }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(selected == nil)
            ViewMenu(m: m, columns: $columns)
        }
    }

    private var footnote: String {
        let watts = String(format: "%.0f", m.heatCeiling)
        let caption = switch m.heatBase {
        case .total:
            tr("Нагрев — сколько ватт процесс тратит на CPU и GPU. Процент — его доля в текущей нагрузке CPU и GPU, вместе 100%; это не загрузка CPU. Знак ≈ — оценка.")
        case _ where Monitor.measuredCeiling == nil:
            String(format: tr("Нагрев — сколько ватт процесс тратит на CPU и GPU. Процент — доля от наибольшей нагрузки, замеченной на этом Mac (%@ Вт). Знак ≈ — оценка."), watts)
        default:
            String(format: tr("Нагрев — сколько ватт процесс тратит на CPU и GPU. Процент — доля от максимума этого Mac (%@ Вт). Знак ≈ — оценка."), watts)
        }
        return caption + " " + tr("Показаны 40 самых горячих строк.")
    }
}

/// Grouping, heat base and visible columns of the process table.
struct ViewMenu: View {
    @Bindable var m: Monitor
    @Binding var columns: TableColumnCustomization<Row>
    private let items = [("heat", "Нагрев"), ("cpu", "CPU"), ("gpu", "Время GPU"), ("mem", "Память")]

    var body: some View {
        Menu("Вид") {
            Toggle("Группировать по приложениям", isOn: $m.grouped)
            Divider()
            HeatBasePicker(m: m)
            Divider()
            Section("Столбцы") {
                ForEach(items, id: \.0) { id, title in
                    Toggle(tr(title), isOn: Binding(
                        get: { columns[visibility: id] != .hidden },
                        set: { columns[visibility: id] = $0 ? .visible : .hidden }))
                }
            }
        }
        .fixedSize()
    }
}

struct HeatBar: View {
    let percent: Double
    let watts: Double
    let share: Double
    let estimated: Bool
    var body: some View {
        let mark = estimated ? "≈" : ""
        HStack(spacing: 8) {
            LevelBar(fraction: max(share, 0.03), color: (share > 0.6 ? TempLevel.crit : share > 0.25 ? .hot : .warm).fill)
                .frame(width: 50)
            Text(mark + pct(percent)).monospacedDigit().frame(minWidth: 46, alignment: .trailing)
            Text(mark + wFine(watts)).foregroundStyle(.secondary).monospacedDigit().frame(minWidth: 64, alignment: .trailing)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .trailing)
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
        .pickerStyle(.inline).labelsHidden()
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
            .width(min: 180, ideal: 190)
            .customizationID("heat")
            TableColumn("CPU", value: \.cpuShare) { row in
                Text(pct(row.cpuShare)).monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help(tr("CPU: 100% — весь процессор, а не одно ядро.") + " " + String(format: tr("≈%.1f ядра"), row.cpu / 100)
                          + ". " + String(format: tr("По шкале одного ядра: %.1f%%."), row.cpu))
            }
            .width(70)
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
            .width(90)
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
