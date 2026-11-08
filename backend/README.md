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

El paso 2 requiere un tenant **externo de clientes** de Microsoft Entra External ID. En ese tenant registra una API y un cliente público separado para la app móvil.

1. En la aplicación de la API, configura la versión de token de acceso `2`, expón el permiso delegado `access_as_user` y conserva el identificador de aplicación de la API.
2. En el cliente público, configura la URI de retorno de la app y añade el permiso delegado de la API. Asocia el cliente al flujo de registro e inicio de sesión con correo y contraseña. El cliente usa código de autorización con PKCE y solicita el scope `api://<id-de-la-api>/access_as_user` si conservas el URI de aplicación predeterminado.
3. Completa en `.env` `ENTRA_TENANT_SUBDOMAIN` (solo el nombre anterior a `.ciamlogin.com`), `ENTRA_TENANT_ID`, `ENTRA_API_CLIENT_ID` y `ENTRA_MOBILE_CLIENT_ID`. La API valida tokens con las claves públicas de Entra. No se requiere un secreto de cliente.

Con un token de acceso emitido para la API, envíalo en `Authorization: Bearer …`.

- `PUT /api/v1/me` con `{"alias":"Vecina de prueba"}` crea el perfil o actualiza su alias.
- `GET /api/v1/me` devuelve el perfil de la sesión, o `404` si aún no se creó.

La identidad se vincula por emisor y `oid` de Entra. Para trasladar una cuenta existente, enlaza el `oid` verificado a su UUID de perfil antes de habilitar la nueva app. El correo no se usa para vincular cuentas. La prueba de integración usa dos identidades firmadas localmente y comprueba también firma inválida, expiración, audiencia, aislamiento y alta concurrente.

Referencias de Microsoft para [crear un tenant externo](https://learn.microsoft.com/en-us/entra/external-id/customers/quickstart-tenant-setup), [exponer permisos de una API](https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-configure-app-expose-web-apis) y [habilitar la recuperación de contraseña](https://learn.microsoft.com/en-us/entra/external-id/customers/how-to-enable-password-reset-customers).
