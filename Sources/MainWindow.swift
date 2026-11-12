import AppKit
import SwiftUI

/// Main window: sidebar with sections and a live value next to each.
struct MainView: View {
    @Bindable var m: Monitor
    @State private var section: WindowSection = .overview
    @StateObject private var advice = AdviceModel()
    @State private var onScreen = false

    var body: some View {
        NavigationSplitView {
            List(WindowSection.allCases, selection: Binding(get: { section }, set: { if let s = $0 { section = s } })) { s in
                SidebarRow(section: s, value: value(s))
                    .tag(s)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: Theme.sidebarWidth, max: 260)
        } detail: {
            detail
                .navigationTitle(tr(section.titleKey))
                .background { shortcuts }
        }
        .frame(minWidth: 760, minHeight: 520)
        .whileOnScreen(start: { onScreen = true; syncAdvice() }, stop: { onScreen = false; syncAdvice() })
        .onChange(of: section) { _, _ in syncAdvice() }
    }

    private func syncAdvice() {
        advice.setVisibility(windowOnScreen: onScreen, adviceShown: onScreen && section == .advice)
    }

    @ViewBuilder private var detail: some View {
        switch section {
        case .overview: OverviewView(m: m) { section = $0 }
        case .processes: ProcessesView(m: m)
        case .cooling: CoolingView(m: m)
        case .power: PowerView(m: m)
        case .advice: AdviceView(model: advice)
        }
    }

    private func value(_ s: WindowSection) -> SidebarValue? {
        switch s {
        case .overview: return nil
        case .advice: return .badge(advice.stoppable.count)
        case .processes: return m.hottestRow.map { .text($0.name, .secondary) }
        case .cooling: return m.cpuHot.map { .text(fmt($0), tempColor($0)) }
        case .power: return m.battery?.systemW.map { .text(w($0), .secondary) }
        }
    }

    // The app has no main menu by default, so ⌘1–⌘5 live on hidden buttons in the window.
    private var shortcuts: some View {
        ZStack {
            ForEach(WindowSection.allCases) { s in
                Button(tr(s.titleKey)) { section = s }
                    .keyboardShortcut(KeyEquivalent(s.shortcut), modifiers: .command)
            }
        }
        .opacity(0)
        .accessibilityHidden(true)
    }
}

/// What a sidebar row shows on its right edge.
enum SidebarValue {
    case text(String, Color)
    case badge(Int)
}

struct SidebarRow: View {
    let section: WindowSection
    let value: SidebarValue?

    var body: some View {
        HStack(spacing: 6) {
            Label(tr(section.titleKey), systemImage: section.symbol)
            Spacer(minLength: 4)
            switch value {
            case .text(let text, let color)?:
                Text(text).foregroundStyle(color).monospacedDigit().lineLimit(1).truncationMode(.tail)
            case .badge(let n)? where n > 0:
                Text("\(n)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).frame(minHeight: 17)
                    .background(Capsule().fill(TempLevel.hot.fill))
            default:
                EmptyView()
            }
        }
    }
}

extension WindowSection {
    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .processes: "list.bullet.rectangle"
        case .cooling: "thermometer.medium"
        case .power: "bolt"
        case .advice: "lightbulb"
        }
    }
}
