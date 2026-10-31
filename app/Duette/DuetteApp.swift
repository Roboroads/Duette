import DuetteAudio
import SwiftUI

@main
struct DuetteApp: App {
    var body: some Scene {
        MenuBarExtra("Duette", systemImage: "waveform.circle") {
            Text(DuetteDriver.deviceUID)
                .padding()
        }
        .menuBarExtraStyle(.window)
    }
}
