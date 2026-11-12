import SwiftUI

/// Overview section: the verdict, temperature, what heats the Mac and three small cards.
struct OverviewView: View {
    var m: Monitor
    let open: (WindowSection) -> Void

    var body: some View {
        Text("Обзор").frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
