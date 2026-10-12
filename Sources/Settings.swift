import SwiftUI

/// The settings window: Dock, menu bar label and panel blocks.
struct SettingsView: View {
    let dockChanged: () -> Void
    @AppStorage(Pref.showInDock) private var showInDock = false
    @AppStorage(Pref.liveLabel) private var live = false
    @AppStorage(Pref.labelValues) private var valuesRaw = MenuValue.cpuTemp.rawValue
    @AppStorage(Pref.panelBlocks) private var blocksRaw = encodeSet(Set(PanelBlock.allCases))

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
                ForEach(MenuValue.allCases, id: \.self) { v in
                    Toggle(isOn: member(v, in: $valuesRaw)) { Label(title(v), systemImage: symbol(v)) }
                        .disabled(!live)
                }
            } header: {
                Text("Строка меню")
            } footer: {
                Text("Значения обновляются раз в 5 секунд. В режиме «Только значок» приложение ничего не опрашивает, пока панель и окно закрыты.")
            }
            Section("Панель") {
                ForEach(PanelBlock.allCases, id: \.self) { b in Toggle(title(b), isOn: member(b, in: $blocksRaw)) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
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
