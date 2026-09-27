# MyFTP

Cliente FTP/FTPS básico para macOS, escrito en Swift y SwiftUI, sin dependencias externas.

**Requisitos:** macOS 27 (Golden Gate) o posterior y Xcode 27.

## Funciones

- Servidores guardados en la barra lateral. Las contraseñas se guardan en el Llavero de macOS.
- **FTP**, **FTPS explícito** (`AUTH TLS`, puerto 21) y **FTPS implícito** (puerto 990).
  - Con FTPS también se cifra el canal de datos (`PROT P`).
  - Opción para aceptar certificados autofirmados.
- Modo pasivo (`EPSV`, y `PASV` si el servidor no admite `EPSV`).
- Listados con `MLSD` cuando el servidor lo admite. Si no, se usa `LIST` en formato Unix o DOS/IIS.
- Navegación por carpetas, con ordenación por nombre, tamaño y fecha.
- Descarga de archivos a la carpeta **Descargas**: doble clic, menú contextual o barra de herramientas.
- Subida de archivos arrastrándolos desde el Finder o con el botón **Subir**.
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

## Decisiones técnicas

- **Foundation Streams en vez de Network.framework:** el FTPS explícito necesita activar TLS en una conexión ya abierta (después de `AUTH TLS`), y `NWConnection` no lo permite. Los Streams sí, con `kCFStreamPropertySSLSettings`.
- **La IP que anuncia `PASV` se ignora:** el canal de datos se conecta siempre al mismo host del canal de control, porque detrás de un NAT el servidor suele anunciar una IP privada.

## Limitaciones conocidas

- Solo modo pasivo; el modo activo (`PORT`/`EPRT`) no está implementado.
- Por ahora solo se suben y descargan archivos sueltos, no carpetas completas.
- No se reanudan transferencias interrumpidas (`REST`).
- Algunos servidores FTPS exigen reutilizar la sesión TLS en el canal de datos (por ejemplo, vsftpd con `require_ssl_reuse=YES`). Con esos servidores los listados y las transferencias pueden fallar.
- La pila TLS de Foundation Streams puede no negociar TLS 1.3. Todos los servidores FTPS habituales aceptan TLS 1.2.
- El ejecutable del paquete no se firma ni se distribuye como `.app`. Para distribuirlo habría que crear un proyecto de app en Xcode con este paquete como dependencia.
