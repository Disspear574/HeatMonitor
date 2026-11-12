import SwiftUI

/// Power section: adapter verdict, power flow, source and ports, battery.
struct PowerView: View {
    var m: Monitor

    var body: some View {
        Text("Питание").frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
