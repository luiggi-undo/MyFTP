import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            if let browser = model.browser {
                BrowserView(browser: browser)
                    .id(ObjectIdentifier(browser))
            } else if let bookmark = model.selectedBookmark {
                ServerEditorView(bookmark: bookmark)
                    .id(bookmark.id)
            } else {
                ContentUnavailableView(
                    "Ningún servidor seleccionado",
                    systemImage: "externaldrive.connected.to.line.below",
                    description: Text("Añade un servidor con el botón + de la barra lateral.")
                )
            }
        }
        .alert(
            "No se pudo completar la operación",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("Aceptar", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        List(selection: $model.selection) {
            Section("Servidores") {
                ForEach(model.bookmarks) { bookmark in
                    HStack {
                        Label(bookmark.name.isEmpty ? bookmark.host : bookmark.name, systemImage: "server.rack")
                        Spacer()
                        if model.browser?.bookmark.id == bookmark.id {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 7))
                                .foregroundStyle(.green)
                                .help("Conectado")
                        }
                    }
                    .tag(bookmark.id)
                    .contextMenu {
                        Button("Conectar") { model.connect(bookmark) }
                        Divider()
                        Button("Eliminar", role: .destructive) { model.delete(bookmark.id) }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button(action: model.addBookmark) {
                    Label("Nuevo servidor", systemImage: "plus")
                }
            }
        }
    }
}
