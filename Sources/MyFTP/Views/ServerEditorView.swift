import FTPKit
import SwiftUI

struct ServerEditorView: View {
    @Environment(AppModel.self) private var model
    @State private var draft: ServerBookmark
    @State private var password = ""

    private var storedFingerprint: String? {
        model.bookmarks.first { $0.id == draft.id }?.pinnedFingerprint
    }

    init(bookmark: ServerBookmark) {
        _draft = State(initialValue: bookmark)
    }

    var body: some View {
        Form {
            Section("Servidor") {
                TextField("Nombre", text: $draft.name)
                TextField("Dirección", text: $draft.host, prompt: Text("ftp.ejemplo.com"))
                TextField("Puerto", value: $draft.port, format: .number.grouping(.never))
                Picker("Seguridad", selection: $draft.security) {
                    ForEach(FTPConfiguration.Security.allCases, id: \.self) { security in
                        Text(security.label).tag(security)
                    }
                }
                if draft.security != .plain {
                    Toggle(isOn: $draft.allowInvalidCertificates) {
                        Text("Certificado autofirmado")
                        Text("En lugar de validar el certificado con las autoridades del sistema, la primera vez se te pedirá aceptar su huella y después solo se aceptará ese certificado.")
                    }
                    if draft.allowInvalidCertificates, let fingerprint = storedFingerprint {
                        LabeledContent("Huella aceptada") {
                            VStack(alignment: .trailing, spacing: 4) {
                                Text(fingerprint)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .multilineTextAlignment(.trailing)
                                Button("Olvidar certificado") { model.forgetCertificate(for: draft.id) }
                                    .controlSize(.small)
                            }
                        }
                    }
                }
            }

            Section("Credenciales") {
                TextField("Usuario", text: $draft.username, prompt: Text("Vacío para acceso anónimo"))
                    .textContentType(.username)
                SecureField("Contraseña", text: $password)
                    .textContentType(.password)
            }

            Section("Opciones") {
                TextField("Carpeta inicial", text: $draft.initialPath, prompt: Text("Por defecto, la del usuario"))
            }

            if draft.security == .plain {
                Label("Con FTP sin cifrar, la contraseña y los archivos viajan en claro por la red.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(draft.name.isEmpty ? "Servidor" : draft.name)
        .onAppear {
            password = Keychain.password(for: draft.id) ?? ""
        }
        .onChange(of: draft.security) { old, new in
            if draft.port == old.defaultPort { draft.port = new.defaultPort }
        }
        .toolbar {
            ToolbarItemGroup {
                Button("Guardar") {
                    model.save(draft, password: password)
                }
                Button {
                    model.save(draft, password: password)
                    model.connect(draft)
                } label: {
                    if model.isConnecting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Conectar", systemImage: "bolt.horizontal")
                    }
                }
                .disabled(model.isConnecting || draft.host.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }
}
