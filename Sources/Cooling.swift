import SwiftUI

/// Cooling section: temperature, sensors and fans or the chassis.
struct CoolingView: View {
    var m: Monitor

    var body: some View {
        Text("Охлаждение").frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
