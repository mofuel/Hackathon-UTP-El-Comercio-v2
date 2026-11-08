import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { test } from 'node:test';
import { NestFactory } from '@nestjs/core';
import { exportJWK, generateKeyPair, SignJWT } from 'jose';
import pg from 'pg';
import { AppModule } from '../dist/app.module.js';

const connectionString = process.env.DATABASE_URL;
if (!connectionString) throw new Error('Configura DATABASE_URL.');
const database = new URL(connectionString);
if (database.hostname !== '127.0.0.1' || database.pathname !== '/conecta2_dev') {
  throw new Error('Usa una base local conecta2_dev para la prueba.');
}

test('valida tokens y separa perfiles manteniendo sus UUID', async (t) => {
  const tenantId = randomUUID();
  const audience = randomUUID();
  const mobile = randomUUID();
  const oidA = randomUUID();
  const oidB = randomUUID();
  const previousProfile = randomUUID();
  const guestPublication = randomUUID();
  const guestOperation = randomUUID();
  const issuer = `https://${tenantId}.ciamlogin.com/${tenantId}/v2.0`;
  const discovery = `https://conecta2-test.ciamlogin.com/${tenantId}/v2.0/.well-known/openid-configuration`;
  const keysUrl = `https://conecta2-test.ciamlogin.com/${tenantId}/discovery/v2.0/keys`;
  Object.assign(process.env, {
    ENTRA_TENANT_SUBDOMAIN: 'conecta2-test',
    ENTRA_TENANT_ID: tenantId,
    ENTRA_API_CLIENT_ID: audience,
    ENTRA_MOBILE_CLIENT_ID: mobile,
  });

  const { privateKey, publicKey } = await generateKeyPair('RS256');
  const { privateKey: untrusted } = await generateKeyPair('RS256');
  const jwk = { ...await exportJWK(publicKey), kid: 'test', alg: 'RS256', use: 'sig' };
  const originalFetch = fetch;
  t.mock.method(globalThis, 'fetch', (input, options) => {
    if (String(input) === discovery) return Promise.resolve(Response.json({ issuer, jwks_uri: keysUrl }));
    if (String(input) === keysUrl) return Promise.resolve(Response.json({ keys: [jwk] }));
    return originalFetch(input, options);
  });

  const token = (oid, claims = {}, signingKey = privateKey) => new SignJWT({
    oid, tid: tenantId, sub: oid, azp: mobile, scp: 'access_as_user',
    ver: '2.0', iss: issuer, aud: audience, exp: Math.floor(Date.now() / 1000) + 60, ...claims,
  }).setProtectedHeader({ alg: 'RS256', kid: 'test' }).sign(signingKey);

  const client = new pg.Client({ connectionString });
  await client.connect();
  let app;
  try {
    await client.query('insert into public.profiles (id, alias) values ($1, $2)', [previousProfile, 'Perfil existente']);
    await client.query('insert into public.profile_identities values ($1, $2, $3)', [issuer, oidB, previousProfile]);
    app = await NestFactory.create(AppModule, { logger: false });
    await app.listen(0, '127.0.0.1');
    const endpoint = `${await app.getUrl()}/api/v1/me`;
    const request = (accessToken, body) => fetch(endpoint, {
      method: body ? 'PUT' : 'GET',
      headers: {
        ...(accessToken ? { Authorization: `Bearer ${accessToken}` } : {}),
        ...(body ? { 'Content-Type': 'application/json' } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    });

    assert.equal((await request()).status, 401);
    assert.equal((await request(await token(oidA, {}, untrusted))).status, 401);
    assert.equal((await request(await token(oidA, { aud: randomUUID() }))).status, 401);
    assert.equal((await request(await token(oidA, { tid: randomUUID() }))).status, 401);
    assert.equal((await request(await token(oidA, { iss: 'https://otro.example' }))).status, 401);
    assert.equal((await request(await token(oidA, { exp: 1 }))).status, 401);
    assert.equal((await request(await token(oidA, { scp: undefined }))).status, 403);
    assert.equal((await request(await token(oidA, { azp: randomUUID() }))).status, 403);

    const accessA = await token(oidA);
    const accessB = await token(oidB);
    assert.equal((await request(accessA)).status, 404);
    assert.equal((await request(accessA, { alias: 'x' })).status, 400);
    const writes = await Promise.all([
      request(accessA, { alias: 'Vecina A', id: previousProfile }),
      request(accessA, { alias: 'Vecina A' }),
    ]);
    assert.deepEqual(writes.map(({ status }) => status), [200, 200]);
    const [first, second] = await Promise.all(writes.map((response) => response.json()));
    assert.equal(first.id, second.id);
    assert.notEqual(first.id, previousProfile);
    assert.equal((await (await request(accessA)).json()).id, first.id);
    assert.equal((await (await request(accessB)).json()).alias, 'Perfil existente');
    assert.equal((await (await request(accessB, { alias: 'Vecino B' })).json()).id, previousProfile);

    await t.test('reconectar confirma un aviso una sola vez y difunde sus cambios', async () => {
      const author = first.id;
      const publication = randomUUID();
      const mutation = randomUUID();
      await client.query("update public.profiles set district_ubigeo='150101',sector='Zona de prueba' where id=any($1::uuid[])", [[author, previousProfile]]);
      const publications = `${await app.getUrl()}/api/v1/publications`;
      const api = (path, accessToken, body) => fetch(`${publications}/${path}`, {
        method: body ? 'POST' : 'GET',
        headers: {
          ...(accessToken ? { Authorization: `Bearer ${accessToken}` } : {}),
          ...(body ? { 'Content-Type': 'application/json' } : {}),
        },
        body: body ? JSON.stringify(body) : undefined,
      });
      const create = {
        operationId: mutation, entityType: 'publication', ownerUserId: author,
        entityId: publication, action: 'upsert', expectedVersion: 1,
        payload: {
          id: publication, client_mutation_id: mutation, kind: 'anuncio', category: 'producto',
          title: 'Producto de prueba', description: 'Panes a S/ 2', district_ubigeo: '150101',
          sector: 'Zona de prueba', approx_lat: -12.047, approx_lng: -77.028,
          author_id: previousProfile,
        },
      };
      assert.equal((await api('operations', accessB, create)).status, 403);
      assert.equal((await api('feed', null)).status, 401);
      const confirmations = await Promise.all([api('operations', accessA, create), api('operations', accessA, create)]);
      assert.deepEqual(confirmations.map(({ status }) => status), [200, 200]);
      assert.deepEqual(await Promise.all(confirmations.map((response) => response.json())), [{ version: 1 }, { version: 1 }]);
      assert.equal((await api('operations', accessA, { ...create, payload: { ...create.payload, title: 'Otro título' } })).status, 409);
      const feed = await (await api('feed?district=150101', accessB)).json();
      const received = feed.publications.filter(({ id }) => id === publication);
      assert.equal(received.length, 1);
      assert.equal(received[0].author_id, author);
      const nearby = await api('search?lat=-12.047&lng=-77.028&radiusMeters=200&category=producto', accessB);
      assert.equal(nearby.status, 200);
      assert.ok((await nearby.json()).publications.some(({ id }) => id === publication));
      const districtOnly = await api('search?district=150101&kind=anuncio', accessB);
      assert.ok((await districtOnly.json()).publications.some(({ id }) => id === publication));
      assert.equal((await api(`mine/${publication}`, accessB)).status, 404);

      const edit = { ...create, operationId: randomUUID(), entityType: 'publication_edit', action: 'update',
        payload: { ...create.payload, description: 'Panes a S/ 3' } };
      assert.deepEqual(await (await api('operations', accessA, edit)).json(), { version: 2 });
      assert.equal((await api('operations', accessA, { ...edit, operationId: randomUUID() })).status, 409);
      assert.deepEqual(await (await api('operations', accessA, edit)).json(), { version: 2 });

      const recommendation = { operationId: randomUUID(), entityType: 'recommendation',
        entityId: randomUUID(), ownerUserId: previousProfile, action: 'upsert', expectedVersion: 0,
        payload: { publication_id: publication, client_mutation_id: randomUUID(), comment: 'Recomendado' } };
      assert.equal((await api('operations', accessB, recommendation)).status, 200);
      assert.equal((await api('operations', accessB, recommendation)).status, 200);
      const changedRecommendation = { ...recommendation, operationId: randomUUID(),
        payload: { ...recommendation.payload, comment: 'Comentario actualizado' } };
      assert.equal((await api('operations', accessB, changedRecommendation)).status, 200);
      assert.equal((await api('operations', accessB, recommendation)).status, 200);
      const recommendationSnapshot = await (await api('community', accessB)).json();
      assert.equal(recommendationSnapshot.recommendations.find(({ id }) => id === recommendation.entityId).comment, 'Comentario actualizado');
      let changes = await (await api('changes', accessB, { ids: [publication] })).json();
      assert.equal(changes.publications[0].recommendation_count, 1);
      assert.equal(changes.publications[0].description, 'Panes a S/ 3');
      assert.equal((await api('operations', accessB, { ...recommendation, operationId: randomUUID(), action: 'delete' })).status, 200);

      const offer = { ...recommendation, operationId: randomUUID(), entityId: randomUUID(), entityType: 'help_offer',
        payload: { publication_id: publication, client_mutation_id: randomUUID(), note: 'Puedo ayudar' } };
      assert.equal((await api('operations', accessB, offer)).status, 200);
      const community = await (await api('community', accessA)).json();
      assert.equal(community.help_offers.find(({ id }) => id === offer.entityId).helper_id, previousProfile);
      changes = await (await api('changes', accessB, { ids: [publication] })).json();
      const version = changes.publications[0].version;
      assert.equal(changes.publications[0].status, 'en_coordinacion');
      const removal = { ...create, operationId: randomUUID(), entityType: 'publication_delete',
        action: 'delete', expectedVersion: version, payload: {} };
      assert.deepEqual(await (await api('operations', accessA, removal)).json(), { version: version + 1 });
      const removed = await (await api('changes', accessB, { ids: [publication] })).json();
      assert.equal(removed.publications.length, 0);
      assert.equal(removed.tombstones[0].publication_id, publication);

      const report = { ...create, operationId: guestOperation, ownerUserId: 'anonymous', entityId: guestPublication,
        payload: { ...create.payload, id: guestPublication, client_mutation_id: randomUUID(),
          kind: 'emergencia_solicitud', category: 'general', title: 'Reporte de prueba' } };
      assert.equal((await api('operations', null, report)).status, 200);
      assert.deepEqual(await (await api('operations', null, report)).json(), { version: 1 });
      const guestFeed = await (await api('feed?district=150101', accessB)).json();
      assert.equal(guestFeed.publications.find(({ id }) => id === guestPublication).author_id, null);
    });
  } finally {
    try {
      await app?.close();
      await client.query(`delete from public.publication_operation_receipts
        where operation_id=$1 or actor_key in (select profile_id::text from public.profile_identities where issuer=$2)`, [guestOperation, issuer]);
      await client.query('delete from public.publications where id=$1', [guestPublication]);
      await client.query(`
        delete from public.profiles where id = $1 or id in (
          select profile_id from public.profile_identities where issuer = $2
        )
      `, [previousProfile, issuer]);
    } finally {
      await client.end();
    }
  }
});
