# Conecta2 API · Desarrollo

API NestJS y PostgreSQL 17 con PostGIS para probar la búsqueda geográfica del paso 1.
Requiere Node.js 24 y Docker con Compose. La base escucha en `127.0.0.1:55432`.
La API escucha en `127.0.0.1:3000` por defecto. La consulta de prueba sin token devuelve únicamente avisos marcados como demo.

Ejecuta desde `backend/` en PowerShell.

```powershell
Copy-Item .env.example .env
docker compose up -d --wait
npm.cmd ci
npm.cmd run db:migrate
npm.cmd run db:ubigeo
npm.cmd run build
npm.cmd run test:integration
npm.cmd start
```

La prueba crea publicaciones temporales y las borra al terminar. Consulta la API con datos que ya existan en la base local.

```powershell
Invoke-RestMethod 'http://127.0.0.1:3000/api/v1/publications/nearby?lat=-12.076&lng=-77.063&radiusMeters=800'
```

El radio se expresa en metros, admite de 100 a 20 000 y usa 1000 por defecto. La respuesta contiene hasta 200 publicaciones ordenadas por distancia. Los avisos sin ubicación o con borrado lógico se excluyen.

`001_base.sql` crea perfiles, el vínculo de identidad y el catálogo. `002_publications.sql` crea publicaciones y la búsqueda. `db:ubigeo` importa el catálogo versionado de `assets/geography/` y puede repetirse. `db:migrate` ejecuta cada archivo en una transacción y comprueba el checksum de los archivos aplicados.

Detén PostgreSQL con `docker compose stop`. Los datos de desarrollo quedan en el volumen de Compose.

## Identidad y perfiles

Para conservar el inicio de sesión actual, configura `SUPABASE_AUTH_URL` y `SUPABASE_AUTH_PUBLIC_KEY` en la API de Azure. En Flutter, configura `CONECTA2_API_URL`, `SUPABASE_URL` y `SUPABASE_ANON_KEY`. La API valida la sesión con Supabase Auth y usa el UUID de la cuenta para recuperar su perfil de PostgreSQL en Azure. Las publicaciones, recomendaciones y chats pasan por la API de Azure.

Para usar Microsoft Entra External ID, el paso 2 requiere un tenant **externo de clientes**. En ese tenant registra una API y un cliente público separado para la app móvil.

1. En la aplicación de la API, configura la versión de token de acceso `2`, expón el permiso delegado `access_as_user` y conserva el identificador de aplicación de la API.
2. En el cliente público, configura la URI de retorno de la app y añade el permiso delegado de la API. Asocia el cliente al flujo de registro e inicio de sesión con correo y contraseña. El cliente usa código de autorización con PKCE y solicita el scope `api://<id-de-la-api>/access_as_user` si conservas el URI de aplicación predeterminado.
3. Completa en `.env` `ENTRA_TENANT_SUBDOMAIN` (solo el nombre anterior a `.ciamlogin.com`), `ENTRA_TENANT_ID`, `ENTRA_API_CLIENT_ID` y `ENTRA_MOBILE_CLIENT_ID`. La API valida tokens con las claves públicas de Entra. No se requiere un secreto de cliente.

Con un token de acceso emitido para la API, envíalo en `Authorization: Bearer …`.

- `PUT /api/v1/me` con `{"alias":"Vecina de prueba"}` crea el perfil o actualiza su alias.
- `GET /api/v1/me` devuelve el perfil de la sesión, o `404` si aún no se creó.

La identidad se vincula por emisor y `oid` de Entra. Para trasladar una cuenta existente, enlaza el `oid` verificado a su UUID de perfil antes de habilitar la nueva app. El correo no se usa para vincular cuentas. La prueba de integración usa dos identidades firmadas localmente y comprueba también firma inválida, expiración, audiencia, aislamiento y alta concurrente.

Referencias de Microsoft para [crear un tenant externo](https://learn.microsoft.com/en-us/entra/external-id/customers/quickstart-tenant-setup), [exponer permisos de una API](https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-configure-app-expose-web-apis) y [habilitar la recuperación de contraseña](https://learn.microsoft.com/en-us/entra/external-id/customers/how-to-enable-password-reset-customers).

## Publicaciones y sincronización

Ejecuta `npm.cmd run db:migrate` para aplicar `003_publication_actions.sql`. Desde la raíz Flutter, configura `CONECTA2_API_URL` y las cuatro variables públicas de Entra en un archivo de `--dart-define-from-file`. Registra `pe.vecinos.app.entra://oauth/callback` como URI de retorno personalizada en la plataforma **Aplicaciones móviles y de escritorio** del cliente público. El emulador Android de desarrollo puede usar `http://10.0.2.2:3000`. Para un dispositivo usa una API alcanzable por HTTPS. [Configuración de la URI de retorno en Entra](https://learn.microsoft.com/entra/identity-platform/how-to-add-redirect-uri)

Con `CONECTA2_API_URL` configurada, la app usa el acceso alojado por Entra. La cuenta obtiene su UUID de `/api/v1/me`. Registra la vinculación de los perfiles importados antes de que sus usuarios entren, para conservar su UUID y la cola local asociada.

La API recibe el contenido de SQLite en `POST /api/v1/publications/operations`, guarda cada resultado en la misma transacción que su cambio y responde `409` si la versión quedó obsoleta o se reutiliza un identificador con datos distintos. El feed, las búsquedas, los recursos y las actualizaciones de avisos requieren sesión. El reporte de emergencia invitado usa la misma ruta de operaciones y tiene un límite por IP. El límite local usa la IP directa de la conexión. Configura proxies de confianza antes de publicarlo detrás de un proxy.

Las pruebas de integración cubren creación repetida, lectura por otra cuenta, edición, conflicto, recomendaciones, ofertas y borrado lógico. El volcado de publicaciones y perfiles reales corresponde al ensayo y traspaso de datos.

## Chats y avisos de mensajes

`npm.cmd run db:migrate` aplica `004_conversations.sql` y `005_private_message_notifications.sql`. La API conserva los hilos por vecino y consulta sus mensajes con paginación. Un grupo de emergencia admite al autor y a vecinos con el mismo UBIGEO. Cuando el reporte se resuelve o cancela, el grupo queda en lectura. Flutter conserva borradores privados y envía mensajes grupales pendientes al reconectar.

- **Web PubSub.** Configura `WEB_PUBSUB_CONNECTION_STRING` y, si quieres cambiar el nombre, `WEB_PUBSUB_HUB`. `GET /api/v1/chats/negotiate` emite una URL de conexión de cinco minutos para la cuenta autenticada. El socket solo avisa que hay cambios y la API HTTP comprueba los permisos al consultar el historial. Sin Web PubSub, las pantallas de chats se actualizan por HTTP cada 10 segundos. [SDK oficial de Web PubSub](https://learn.microsoft.com/azure/azure-web-pubsub/reference-server-sdk-js)
- **Firebase.** Configura `FCM_SERVICE_ACCOUNT_JSON` como secreto del servidor con una cuenta autorizada para enviar FCM en el proyecto de la app. Configura los valores públicos de Firebase en Flutter y APNs para iOS según el README principal. Cada vecino activa los avisos en Chats en su propio teléfono. El servidor procesa la cola cada cinco segundos mientras está activo. En Azure, mantén al menos una réplica activa si ejecutas el trabajador dentro de la API. [Envíos de FCM por ID de instalación](https://firebase.google.com/docs/reference/fcm/rest/v1/projects.messages)

El aviso push dice «Tienes un mensaje nuevo» y abre el chat solo para su destinatario. La cola se crea en la misma transacción que el mensaje privado. El trabajador usa `SKIP LOCKED` y reintenta hasta cinco veces durante una hora. Si FCM informa que la instalación dejó de estar registrada, se elimina su asociación. Al cerrar sesión sin acceso a la API, la app intenta desregistrar la instalación en Firebase.

Para la comprobación con servicios reales, configura el tenant externo de Entra, Web PubSub y FCM. Inicia sesión con dos cuentas. Envía un mensaje desde la primera con la segunda en primer plano, y repite con el teléfono destinatario en segundo plano. Toca el aviso y comprueba que abre la conversación. Con una tercera cuenta comprueba que el historial privado no es accesible. `npm.cmd run test:integration` cubre permisos, reintentos y cola local con transportes simulados.
