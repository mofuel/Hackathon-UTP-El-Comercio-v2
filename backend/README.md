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
