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
        .alert(
            model.certificatePrompt?.changed == true ? "¡El certificado del servidor ha cambiado!" : "¿Confiar en este certificado?",
            isPresented: Binding(
                get: { model.certificatePrompt != nil },
                set: { if !$0 { model.certificatePrompt = nil } }
            ),
            presenting: model.certificatePrompt
        ) { prompt in
            Button(prompt.changed ? "Confiar en el nuevo certificado" : "Confiar y conectar",
                   role: prompt.changed ? .destructive : nil) {
                model.trustCertificate(prompt)
            }
            Button("Cancelar", role: .cancel) {}
        } message: { prompt in
            if prompt.changed {
                Text("Puede tratarse de una suplantación (alguien interceptando la conexión). Acepta el nuevo certificado solo si sabes que el servidor lo ha renovado; compruébalo con tu proveedor.\n\n\(prompt.summary)\nSHA-256: \(prompt.fingerprint)")
            } else {
                Text("Es la primera vez que te conectas a este servidor con certificado autofirmado. Si confías en él, se guardará su huella y en adelante se rechazará cualquier otro certificado.\n\n\(prompt.summary)\nSHA-256: \(prompt.fingerprint)")
            }
        }
        .alert(
            "Conexión sin cifrar",
            isPresented: Binding(
                get: { model.plainTextPrompt != nil },
                set: { if !$0 { model.plainTextPrompt = nil } }
            ),
            presenting: model.plainTextPrompt
        ) { bookmark in
            Button("Conectar sin cifrar", role: .destructive) {
                model.connect(bookmark, allowPlainText: true)
            }
            Button("Cancelar", role: .cancel) {}
        } message: { _ in
            Text("Con FTP sin cifrar, tu usuario, tu contraseña y los archivos viajan en claro. Cualquiera en tu misma red (por ejemplo, una wifi pública) podría verlos. Usa FTPS si tu servidor lo admite.")
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
