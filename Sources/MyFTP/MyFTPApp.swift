import AppKit
import SwiftUI

@main
struct MyFTPApp: App {
    @State private var model = AppModel()

    init() {
        // Necesario al ejecutarse como ejecutable de Swift Package (sin bundle .app)
        // para que la app aparezca en el Dock y reciba el foco del teclado.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("MyFTP") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear { NSApplication.shared.activate() }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Nuevo servidor") { model.addBookmark() }
                    .keyboardShortcut("n")
            }
        }
    }
}
