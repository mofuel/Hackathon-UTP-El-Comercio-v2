import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { test } from 'node:test';
import { SignJWT } from 'jose';
import { EntraIdentity } from '../dist/entra-identity.js';
import { ProfileController } from '../dist/profile.controller.js';

test('Azure usa el UUID verificado de Supabase y rechaza sesiones ajenas', async (t) => {
  const origin = 'https://conecta2test.supabase.co';
  const subject = randomUUID();
  const profile = { id: subject, alias: 'Perfil migrado' };
  process.env.SUPABASE_AUTH_URL = origin;
  process.env.SUPABASE_AUTH_PUBLIC_KEY = 'public-test-key';
  const database = { pool: { query: async (sql, params) => {
    assert.match(sql, /public\.profiles/);
    assert.ok(params.includes(subject));
    return { rows: [profile] };
  } } };
  const identity = new EntraIdentity(database);
  const controller = new ProfileController(database, identity);
  const signed = (claims = {}) => new SignJWT({
    sub: subject, iss: `${origin}/auth/v1`, aud: 'authenticated', role: 'authenticated',
    exp: Math.floor(Date.now() / 1000) + 60, ...claims,
  }).setProtectedHeader({ alg: 'HS256' }).sign(Buffer.alloc(32, 12));

  let remoteUser = subject;
  let remoteStatus = 200;
  t.mock.method(globalThis, 'fetch', async (url, options) => {
    assert.equal(url, `${origin}/auth/v1/user`);
    assert.equal(options.headers.apikey, 'public-test-key');
    assert.match(options.headers.Authorization, /^Bearer /);
    assert.equal(options.redirect, 'error');
    return Response.json({ id: remoteUser }, { status: remoteStatus });
  });

  const authorization = `Bearer ${await signed()}`;
  assert.equal(await controller.getProfile(authorization), profile);
  assert.equal(await controller.saveProfile(authorization, 'Alias de prueba'), profile);
  remoteUser = randomUUID();
  await assert.rejects(identity.requireUser(authorization), { status: 401 });
  remoteUser = subject;
  remoteStatus = 401;
  await assert.rejects(identity.requireUser(authorization), { status: 401 });
  remoteStatus = 429;
  await assert.rejects(identity.requireUser(authorization), { status: 503 });
  const foreign = await signed({ iss: 'https://otroproyecto.supabase.co/auth/v1' });
  await assert.rejects(identity.requireUser(`Bearer ${foreign}`), { status: 401 });
  const elevated = await signed({ role: 'service_role' });
  await assert.rejects(identity.requireUser(`Bearer ${elevated}`), { status: 401 });
});
