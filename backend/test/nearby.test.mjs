import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { test } from 'node:test';
import { NestFactory } from '@nestjs/core';
import pg from 'pg';
import { AppModule } from '../dist/app.module.js';

const connectionString = process.env.DATABASE_URL;
if (!connectionString) throw new Error('Configura DATABASE_URL.');
const url = new URL(connectionString);
if (url.hostname !== '127.0.0.1' || url.pathname !== '/conecta2_dev') {
  throw new Error('Usa una base local conecta2_dev para la prueba.');
}

test('PostGIS devuelve avisos cercanos ordenados y excluye los retirados', async (t) => {
  const client = new pg.Client({ connectionString });
  const profileId = randomUUID();
  const ids = Array.from({ length: 5 }, () => randomUUID());
  await client.connect();
  let app;
  try {
    const { rows: [district] } = await client.query(
      "select district from public.peru_districts where code = '150121'",
    );
    assert.equal(district?.district.toLowerCase(), 'pueblo libre');

    await client.query('insert into public.profiles (id, alias) values ($1, $2)', [profileId, 'Vecino de prueba']);
    const fixtures = [
      [ids[0], 'Servicio cercano', -12.0774, -77.063, null],
      [ids[1], 'Servicio a media distancia', -12.081, -77.063, null],
      [ids[2], 'Servicio fuera del radio', -12.105, -77.063, null],
      [ids[3], 'Servicio retirado', -12.076, -77.063, new Date()],
      [ids[4], 'Servicio sin coordenadas', null, null, null],
    ];
    for (const fixture of fixtures) {
      await client.query(`
        insert into public.publications
          (id, title, approx_lat, approx_lng, deleted_at, author_id,
           district_ubigeo, client_mutation_id, kind, is_demo)
        values ($1, $2, $3, $4, $5, $6, '150121', $1, 'servicio',true)
      `, [...fixture, profileId]);
    }

    app = await NestFactory.create(AppModule, { logger: false });
    await app.listen(0, '127.0.0.1');
    const endpoint = `${await app.getUrl()}/api/v1/publications/nearby`;
    const response = await fetch(`${endpoint}?lat=-12.076&lng=-77.063&radiusMeters=800`);
    assert.equal(response.status, 200);
    const body = await response.json();
    const matches = body.publications.filter(({ id }) => ids.includes(id));
    assert.deepEqual(matches.map(({ id }) => id), ids.slice(0, 2));
    assert.ok(matches[0].distance_meters > 100 && matches[0].distance_meters < 120);
    assert.ok(matches[1].distance_meters > 500 && matches[1].distance_meters < 600);
    t.diagnostic(matches.map(({ title, distance_meters }) => `${title}: ${Math.round(distance_meters)} m`).join(', '));

    const invalid = await fetch(`${endpoint}?lat=91&lng=-77.063`);
    assert.equal(invalid.status, 400);
  } finally {
    try {
      await app?.close();
      await client.query('delete from public.profiles where id = $1', [profileId]);
    } finally {
      await client.end();
    }
  }
});
