import SwiftUI

@main
struct MVMApp: App {
    var body: some Scene {
        MenuBarExtra("MVM", systemImage: "slider.horizontal.3") {
            ContentView()
        }
        .menuBarExtraStyle(.window)
    }
}

