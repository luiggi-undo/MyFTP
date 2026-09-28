# MyFTP

Cliente FTP/FTPS básico para macOS, escrito en Swift y SwiftUI, sin dependencias externas.

**Requisitos:** macOS 27 (Golden Gate) o posterior y Xcode 27.

## Funciones

- Servidores guardados en la barra lateral. Las contraseñas se guardan en el Llavero de macOS.
- **FTP**, **FTPS explícito** (`AUTH TLS`, puerto 21) y **FTPS implícito** (puerto 990).
  - Con FTPS también se cifra el canal de datos (`PROT P`).
  - Certificados autofirmados con huella fijada: la primera vez se acepta su huella SHA-256 y después se rechaza cualquier otro certificado, también en los canales de datos.
- Modo pasivo (`EPSV`, y `PASV` si el servidor no admite `EPSV`).
- Listados con `MLSD` cuando el servidor lo admite. Si no, se usa `LIST` en formato Unix o DOS/IIS.
- Navegación por carpetas, con ordenación por nombre, tamaño y fecha.
- Descarga de archivos y carpetas completas a la carpeta **Descargas**: doble clic, menú contextual o barra de herramientas.
- Subida de archivos y carpetas completas arrastrándolos desde el Finder o con el botón **Subir**.
- Reanudación de transferencias fallidas (`REST`): el botón ↻ continúa donde se quedó. En carpetas se saltan los archivos ya completos.
- Crear carpetas, renombrar y eliminar. Las carpetas se borran con todo su contenido.
- Cola de transferencias con progreso y cancelación. Usa una segunda conexión, así que puedes seguir navegando mientras se transfiere.
- Registro de las órdenes y respuestas FTP. La contraseña no aparece.

## Compilar y ejecutar

1. Abre `Package.swift` con Xcode.
2. Elige el esquema **MyFTP** y el destino **My Mac**.
3. Pulsa ⌘R.

Desde la terminal:

```sh
swift build
swift run MyFTP
swift test        # tests de los parsers del protocolo
```

## Crear la app (.app firmada)

```sh
./scripts/build-app.sh
```

Genera `build/MyFTP.app` y `build/MyFTP.zip`. Sin más opciones, la firma es ad hoc: la app funciona en tu Mac, pero no sirve para distribuirla.

Para distribuirla a otros Macs necesitas un certificado **Developer ID Application**, que se obtiene con una cuenta del Apple Developer Program:

```sh
# Una sola vez: guardar las credenciales de notarización en el Llavero
xcrun notarytool store-credentials myftp-notary --apple-id tu@correo.com --team-id TEAMID

SIGN_IDENTITY="Developer ID Application: Tu Nombre (TEAMID)" \
NOTARY_PROFILE=myftp-notary \
VERSION=1.0 BUILD=1 \
./scripts/build-app.sh
```

Para ver las identidades de firma disponibles: `security find-identity -v -p codesigning`.

El icono está en `Resources/AppIcon.icon`. Es un archivo de Icon Composer: ábrelo con Icon Composer para editarlo. El script lo compila con `actool`, la herramienta de Xcode, y lo incluye en la app. Si prefieres un icono clásico, borra `AppIcon.icon` y pon en su lugar un `Resources/AppIcon.icns`.

## Estructura

```
Sources/
  FTPKit/                 Núcleo del protocolo (independiente de la interfaz)
    FTPClient.swift       Sesión FTP síncrona: login, TLS, canal de datos, órdenes
    FTPSession.swift      Envoltorio async/await sobre una cola serie
    FTPSocket.swift       Socket TCP (Foundation Streams) con TLS activable en caliente
    FTPReply.swift        Respuestas del servidor, incluidas las multilínea
    FTPListParser.swift   MLSD, LIST (Unix y DOS), PASV/EPSV y PWD
  MyFTP/                  App SwiftUI
    Models/               Servidores guardados, Llavero, estado de la conexión y transferencias
    Views/                Barra lateral, editor de servidor, explorador, transferencias y registro
Tests/FTPKitTests/        Tests (swift-testing)
```

## Seguridad

- **Huella del certificado fijada** para servidores con certificado autofirmado. Si el certificado cambia, la app bloquea la conexión y avisa de una posible suplantación.
- **Confirmación antes de usar FTP sin cifrar** cada vez que se va a enviar la contraseña.
- **Nombres remotos validados:** se ignoran las entradas con `/`, `..` o caracteres de control, y en las descargas de carpetas se comprueba que cada archivo queda dentro del destino. Así un servidor malicioso no puede escribir fuera de Descargas.
- **Sin inyección de órdenes:** se rechaza cualquier orden con saltos de línea o caracteres nulos, por ejemplo la que vendría de un archivo local llamado `a\r\nDELE x`.
- **Sin rebajar el cifrado:** si se eligió FTPS y el servidor no lo admite, la conexión falla; nunca pasa a FTP sin cifrar.
- **IP de `PASV` ignorada:** el canal de datos va siempre al mismo host que el de control, lo que evita que el servidor redirija la conexión a otra máquina.
- **Contraseñas en el Llavero**, nunca en disco ni en el registro.

## Decisiones técnicas

- **Foundation Streams en vez de Network.framework:** el FTPS explícito necesita activar TLS en una conexión ya abierta (después de `AUTH TLS`), y `NWConnection` no lo permite. Los Streams sí, con `kCFStreamPropertySSLSettings`.
- **La IP que anuncia `PASV` se ignora:** el canal de datos se conecta siempre al mismo host del canal de control, porque detrás de un NAT el servidor suele anunciar una IP privada.

## Limitaciones conocidas

- Solo modo pasivo; el modo activo (`PORT`/`EPRT`) no está implementado.
- En las transferencias de carpetas se omiten los enlaces simbólicos, para evitar bucles.
- Una transferencia cancelada borra los datos parciales y no se puede reanudar. Una que falla sí.
- Algunos servidores FTPS exigen reutilizar la sesión TLS en el canal de datos (por ejemplo, vsftpd con `require_ssl_reuse=YES`). Con esos servidores los listados y las transferencias pueden fallar.
- La pila TLS de Foundation Streams puede no negociar TLS 1.3. Todos los servidores FTPS habituales aceptan TLS 1.2.
