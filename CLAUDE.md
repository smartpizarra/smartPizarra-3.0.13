# CLAUDE.md

# Smart Pizarra — guía para Claude

## Objetivo

Cuatro pantallas HTML para una app Android en TV box, ejecutadas en Android WebView 101 y conectadas con Kodular/App Inventor. Mantener el código ligero, compatible con Chromium/WebView 101 y funcional sin internet cuando sea posible.

## Archivos y responsabilidades

- `config.html`: configura orientación y grupo de ligas. Guarda en `localStorage`; solo envía el JSON de salida al pulsar **Salir**.
- `loading.html`: pantalla de carga con progreso y pasos. Espera hasta 5 s por `updateData()` y continúa aunque no lleguen datos. Al terminar, informa a la app.
- `connection.html`: pantalla de desconexión; comprueba internet periódicamente, comunica cambios y aplica protección contra burn-in.
- `fingerprint.html`: muestra el ID del dispositivo y su QR; solicita el ID a la app, supervisa la conexión y reintenta generar el QR si falla.

## Integración con Kodular/App Inventor

- La app invoca funciones JavaScript mediante `RunJavaScript`.
- Los mensajes de la página a la app se envían como texto JSON mediante `window.AppInventor.setWebViewString(mensaje)`.
- En pruebas de navegador, puede usarse un `AppInventor.setWebViewString` simulado que escriba en consola.
- `updateData(json)` acepta un objeto JavaScript o una cadena JSON. Ignora los campos ausentes o inválidos.
- No inventar ni cambiar nombres de `origin`, `action`, `status` o propiedades JSON sin revisar el bloque correspondiente de la app: son parte del contrato entre ambos lados.

## Contratos de entrada comunes

Las pantallas que lo admiten reciben mediante `updateData()`:

- `version`, `url`, `email`: datos informativos.
- `scale`: porcentaje de escala (10–300; 100 = tamaño normal), en `loading.html`, `connection.html` y `fingerprint.html`.
- `id`: ID del dispositivo, en las pantallas que lo muestran.
- `checkEndpoints`: en `connection.html` y `fingerprint.html`, permite reemplazar los endpoints usados para verificar internet.

**La orientación no se pasa por `updateData()`.** `config.html` la guarda y las otras pantallas la leen de `localStorage`.

## Persistencia y diseño compartidos

- `smartpizarra.orientation`: orientación guardada, `0`, `90`, `180` o `270`.
- `smartpizarra.league`: opción guardada por `config.html` (`mlb`, `nba`, `nflnhl` o `none`).
- `smartpizarra.scale`: escala en % guardada por `config.html` (10–300, botones −/+ de 5 en 5; 60 por defecto = zoom `0.6`, definido en `DEFAULT_CONFIG.scale` de config.html y `savedScaleDefault` de las otras tres pantallas, que deben coincidir; no confundir con `defaultScale`, que es el tamaño visual 100). **Solo se informa en los JSON; ninguna pantalla la aplica.** En los JSON viaja como **factor de zoom** (`% / 100`: 80% → `0.8`), porque la app lo usa como `z` en `document.body.style.zoom = z` de su código de giro/zoom de otra página. En `localStorage` se guarda en % entero. La escala visual de las pantallas sigue llegando por `updateData({scale})`.
- La orientación por defecto es `90°` si no existe un valor guardado (`DEFAULT_CONFIG.orientation` en config.html y `defaultOrientation` en las otras tres pantallas; deben coincidir).
- Las pantallas de contenido usan `#stage` / `#scaler` y un gestor de layout para rotación y escala. Conserva el comportamiento de ajuste a pantalla.
- `config.html` ofrece las categorías MLB, NBA, NFL & NHL y NINGUNO; al salir incluye solo la lista de ligas de la opción seleccionada (`leagues`).

## Mensajes de salida conocidos

- `config.html`: un solo mensaje al salir: `origin:"config"`, `action:"exit"`; incluye `status` (`saved`, `unchanged` o `error`), `internetStatus`, `orientation`, `scale` y `leagues`.
- `loading.html`: al completar la carga envía `origin:"loadingPage"`, `action:"loading"`, `status:"true"` e `internetStatus`.
- `connection.html`: al iniciar envía `origin:"connection_status"`, `action:"info"`; después informa el estado con `action:"connection"`.
- `fingerprint.html`: envía eventos como `info`, `qr_generated`, `qr_error`, `id_empty` y `connection`. Respeta las mayúsculas/minúsculas de `origin` y los valores del archivo; por ejemplo, `fingerPrint` aparece con esa capitalización en sus eventos del QR.

- **Configuración compartida:** solo `config.html` escribe `smartpizarra.orientation`, `smartpizarra.league` y `smartpizarra.scale`. `loading.html`, `connection.html` y `fingerprint.html` solo las leen y agregan `orientation`, `scale` y `leagues` a **todos** sus mensajes (las mismas claves que el JSON de "Salir"). No se envía el tipo de liga (`league`/etiqueta), solo `leagues` con el listado. El listado está copiado en los cuatro archivos (`LEAGUE_OPTIONS[...].values` / `CONFIG.league.options` / `LEAGUE_CONFIG.options`) y debe ser idéntico en todos.

Consulta el JSON construido en el código antes de cambiar un contrato; los ejemplos de arriba son un resumen, no sustituyen el código.

## Funciones públicas

- `config.html`: `updateData(json)`, `getConfig()`, `saveConfig()`, `exitConfig()`, `checkConnection()`, `checkConnectionAsync()`.
- `loading.html`: `updateData(json)`.
- `connection.html`: `updateData(json)`, `checkConnection()`, `checkConnectionAsync()`.
- `fingerprint.html`: `updateData(json)`, `setCode(id)`, `refreshQR()`, `requestIdAgain()`, `checkConnection()`, `checkConnectionAsync()`, `wakeScreen()`, `simulateOffline()`, `simulateOnline()`.

## Restricciones para cambios

1. Mantener compatibilidad con Android WebView 101 y el hardware de TV box; evitar APIs modernas sin fallback.
2. Priorizar JavaScript ES5 (`var` y `function`) en las pantallas que ya siguen ese estilo. `loading.html` usa clases y algunas características modernas: no hacer una refactorización amplia sin probarla en el WebView objetivo.
3. Evitar librerías externas innecesarias, filtros pesados y efectos caros para GPU. Mantener animaciones centradas en `transform` y `opacity`.
4. Preservar el control remoto/teclado de `config.html`, incluidos navegación por flechas, OK/Enter/Espacio, teclas 1–4 y Esc.
5. Preservar las protecciones anti-burn-in de `connection.html` y `fingerprint.html`.
6. `fingerprint.html` intenta cargar `qrcode.min.js` localmente y luego desde CDN. Para funcionamiento sin red, incluir la copia local junto al HTML en los assets.
7. Manejar posibles errores o bloqueos de `localStorage`; no asumir que siempre está disponible.
8. Mantener los comentarios de arquitectura y contratos actualizados cuando se modifiquen las funciones o mensajes.

## Pruebas mínimas después de modificar

- Abrir cada HTML en el WebView objetivo o en Chrome para una primera comprobación.
- Simular `updateData()` y revisar en consola el JSON enviado a `setWebViewString`.
- Probar orientación `0/90/180/270`, guardado y persistencia entre pantallas.
- Probar `scale` mínimo, normal y máximo donde aplique.
- Probar conexión online/offline y recuperación de red.
- Probar `fingerprint.html` con ID válido, ID vacío y fallo de carga/renderizado del QR.
- Probar navegación por control remoto en `config.html`.
- Verificar que los cambios no alteren los nombres ni la estructura de los mensajes esperados por Kodular/App Inventor.

## Regla para Claude

Antes de editar, localizar la sección y función responsables dentro del HTML afectado. Hacer cambios mínimos y localizados; no reescribir archivos completos ni duplicar lógica sin necesidad. Tratar los contratos de comunicación, las claves de `localStorage`, la orientación/escala y la compatibilidad del WebView como interfaces estables. Si un requisito no está definido en estos archivos, indicarlo en vez de asumirlo.
