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

  } finally {
    try {
      await app?.close();
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
