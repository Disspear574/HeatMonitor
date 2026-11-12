import SwiftUI

/// The settings window: Dock, menu bar label and panel blocks.
struct SettingsView: View {
    let dockChanged: () -> Void
    @AppStorage(Pref.showInDock) private var showInDock = false
    @AppStorage(Pref.liveLabel) private var live = false
    @AppStorage(Pref.labelValues) private var valuesRaw = MenuValue.cpuTemp.rawValue
    @AppStorage(Pref.panelBlocks) private var blocksRaw = encodeSet(Set(PanelBlock.allCases))
    @AppStorage(Pref.heatBase) private var heatBaseRaw = HeatBase.auto.rawValue
    @AppStorage(LimiterPref.enabled) private var limiterOn = false
    @AppStorage(LimiterPref.power) private var limitPower = true
    @AppStorage(LimiterPref.heat) private var limitHeat = true
    @AppStorage(LimiterPref.heatC) private var limitHeatC = 95.0
    @AppStorage(LimiterPref.holdMin) private var limitHoldMin = 3.0
    @AppStorage(LimiterPref.patterns) private var limitPatternsText = LimiterPref.defaultPatterns

    var body: some View {
        Form {
            Section("Основные") {
                Toggle("Показывать в Dock", isOn: $showInDock)
                    .onChange(of: showInDock) { _, _ in dockChanged() }
            }
            Section {
                Picker("Строка меню", selection: $live) {
                    Text("Только значок").tag(false)
                    Text("Значок и значения").tag(true)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                ForEach(MenuValue.allCases, id: \.self) { v in
                    Toggle(isOn: member(v, in: $valuesRaw)) { Label(title(v), systemImage: symbol(v)) }
                        .disabled(!live)
                }
            } header: {
                Text("Строка меню")
            } footer: {
                Text("Значения обновляются раз в 5 секунд. В режиме «Только значок» приложение ничего не опрашивает, пока панель и окно закрыты.")
            }
            Section {
                Picker("Нагрев процессов", selection: Binding(
                    get: { (HeatBase(rawValue: heatBaseRaw) ?? .auto).resolved(measured: Monitor.measuredCeiling != nil) },
                    set: { heatBaseRaw = $0.rawValue })) {
                    Text("Доля от максимума Mac").tag(HeatBase.maximum)
                    Text("Доля от общей нагрузки").tag(HeatBase.total)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            } header: {
                Text("Нагрев процессов")
            } footer: {
                Text(Monitor.measuredCeiling.map { String(format: tr("Максимум этого Mac замерен: %.0f Вт."), $0) }
                     ?? tr("Максимум этого Mac не замерен, поэтому по умолчанию показывается доля от общей нагрузки. Доля от максимума берёт наибольшую нагрузку, которую приложение видело."))
            }
            Section("Панель") {
                ForEach(PanelBlock.allCases, id: \.self) { b in Toggle(title(b), isOn: member(b, in: $blocksRaw)) }
            }
            Section {
                Toggle("Ограничивать процессы из списка", isOn: $limiterOn)
                Toggle("Когда не хватает питания от адаптера", isOn: $limitPower).disabled(!limiterOn)
                Toggle(String(format: tr("Когда CPU горячее %.0f°"), limitHeatC), isOn: $limitHeat).disabled(!limiterOn)
                Stepper(String(format: tr("Порог температуры: %.0f°"), limitHeatC), value: $limitHeatC, in: 80...105, step: 5)
                    .disabled(!limiterOn || !limitHeat)
                Stepper(String(format: tr("Ждать перед включением и снятием: %.0f мин"), limitHoldMin), value: $limitHoldMin, in: 1...15)
                    .disabled(!limiterOn)
                TextEditor(text: $limitPatternsText)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 96)
                    .disabled(!limiterOn)
            } header: {
                Text("Ограничитель")
            } footer: {
                Text("Процессы, в команде которых есть строка из списка (по одной на строку), переводятся в фоновый приоритет: медленнее, но не останавливаются. Только ваши процессы. После снятия нагрузки приоритет возвращается.")
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func member<T: CaseIterable & RawRepresentable & Hashable>(_ v: T, in raw: Binding<String>) -> Binding<Bool> where T.RawValue == String {
        Binding(get: { (decodeSet(raw.wrappedValue) as Set<T>).contains(v) },
                set: { on in
                    var s: Set<T> = decodeSet(raw.wrappedValue)
                    if on { s.insert(v) } else { s.remove(v) }
                    raw.wrappedValue = encodeSet(s)
                })
    }

    private func title(_ v: MenuValue) -> LocalizedStringKey {
        switch v {
        case .cpuTemp: "Температура CPU"
        case .gpuTemp: "Температура GPU"
        case .fan: "Обороты вентиляторов"
        case .power: "Потребление Mac"
        case .cpuLoad: "Загрузка CPU"
        }
    }

    private func symbol(_ v: MenuValue) -> String {
        MenuLabel.parts(Readings(cpuTemp: 0, gpuTemp: 0, fanRPM: 0, systemW: 0, cpuLoad: 0), values: [v]).first?.symbol ?? "questionmark"
    }

    private func title(_ b: PanelBlock) -> LocalizedStringKey {
        switch b {
        case .temperature: "Температура и график"
        case .sensors: "Датчики"
        case .load: "Нагрузка"
        case .power: "Питание"
        case .apps: "Что греет Mac"
        case .fans: "Вентиляторы"
        }
    }
}
