import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { test } from 'node:test';
import { NestFactory } from '@nestjs/core';
import { UnauthorizedException } from '@nestjs/common';
import pg from 'pg';
import { decodeJwt } from 'jose';
import { AppModule } from '../dist/app.module.js';
import { ChatRealtime } from '../dist/chat-realtime.js';
import { EntraIdentity } from '../dist/entra-identity.js';

const connectionString = process.env.DATABASE_URL;
if (!connectionString) throw new Error('Configura DATABASE_URL.');
const url = new URL(connectionString);
if (url.hostname !== '127.0.0.1' || url.pathname !== '/conecta2_dev') throw new Error('Usa conecta2_dev local.');

test('negociación Web PubSub restringida', async () => {
  const previous = process.env.WEB_PUBSUB_CONNECTION_STRING;
  const fakeKey = Buffer.alloc(32, 1).toString('base64');
  process.env.WEB_PUBSUB_CONNECTION_STRING = `Endpoint=https://test.webpubsub.azure.com;AccessKey=${fakeKey};Version=1.0;`;
  let service;
  try {
    service = new ChatRealtime();
  } finally {
    if (previous === undefined) delete process.env.WEB_PUBSUB_CONNECTION_STRING;
    else process.env.WEB_PUBSUB_CONNECTION_STRING = previous;
  }
  const user = randomUUID();
  const response = await service.negotiate(user, '150121');
  const connection = new URL(response.url);
  assert.equal(connection.protocol, 'wss:');
  const claims = decodeJwt(connection.searchParams.get('access_token'));
  assert.ok(Object.values(claims).includes(user));
  assert.ok(JSON.stringify(claims).includes('district-150121'));
  assert.doesNotMatch(JSON.stringify(claims), /webpubsub\.(joinLeaveGroup|sendToGroup)/);

});

test('chats privados, grupos de emergencia respetan la cuenta', async (t) => {
  const [author, neighbor, stranger, publication, otherPublication, emergency, thread] =
    Array.from({ length: 7 }, randomUUID);
  const actors = new Map([['Bearer autor', author], ['Bearer vecino', neighbor], ['Bearer tercero', stranger]]);
  const client = new pg.Client({ connectionString });
  await client.connect();
  let app;
  try {
    await client.query(`insert into public.profiles(id,alias,district_ubigeo)
      values($1,'Autor','150121'),($2,'Vecino','150121'),($3,'Tercero','150101')`, [author, neighbor, stranger]);
    await client.query(`insert into public.publications(id,client_mutation_id,author_id,kind,title,district_ubigeo)
      values($1,$1,$4,'servicio','Primer aviso','150121'),($2,$2,$4,'servicio','Segundo aviso','150121'),
      ($3,$3,$4,'emergencia_solicitud','Reporte de prueba','150121')`, [publication, otherPublication, emergency, author]);

    app = await NestFactory.create(AppModule, { logger: false });
    const identity = app.get(EntraIdentity);
    t.mock.method(identity, 'requireProfileId', async (authorization) => {
      const actor = actors.get(authorization);
      if (!actor) throw new UnauthorizedException();
      return actor;
    });
    const realtime = app.get(ChatRealtime);
    const privateSignals = [];
    const groupSignals = [];
    t.mock.method(realtime, 'privateChanged', async (users) => { privateSignals.push(users); });
    t.mock.method(realtime, 'groupChanged', async (district, owner) => { groupSignals.push([district, owner]); });
    t.mock.method(realtime, 'negotiate', async (actor, district) => ({ actor, district }));
    await app.listen(0, '127.0.0.1');
    const endpoint = `${await app.getUrl()}/api/v1/chats`;
    const api = (path, account, method = 'GET', body) => fetch(`${endpoint}/${path}`, {
      method,
      headers: { ...(account && { Authorization: `Bearer ${account}` }),
        ...(body && { 'Content-Type': 'application/json' }) },
      body: body ? JSON.stringify(body) : undefined,
    });

    assert.equal((await api('negotiate')).status, 401);
    assert.deepEqual(await (await api('negotiate', 'vecino')).json(), { actor: neighbor, district: '150121' });

    const open = { id: thread, clientMutationId: randomUUID(), publicationId: publication };
    const opened = await Promise.all([api('threads', 'vecino', 'POST', open), api('threads', 'vecino', 'POST', open)]);
    assert.deepEqual(await Promise.all(opened.map((response) => response.json())), [{ id: thread }, { id: thread }]);
    const reused = await api('threads', 'vecino', 'POST', { ...open, id: randomUUID(), clientMutationId: randomUUID(), publicationId: otherPublication });
    assert.deepEqual(await reused.json(), { id: thread });
    assert.equal((await api(`threads/${thread}`, 'tercero')).status, 404);

    const message = { id: randomUUID(), clientMutationId: randomUUID(), body: 'Mensaje privado', recipientId: author };
    const path = `threads/${thread}/messages`;
    assert.equal((await api(path, 'tercero', 'POST', message)).status, 404);
    const sends = await Promise.all([api(path, 'vecino', 'POST', message), api(path, 'vecino', 'POST', message)]);
    assert.deepEqual(sends.map(({ status }) => status), [200, 200]);
    assert.equal((await api(path, 'vecino', 'POST', { ...message, body: 'Otro texto' })).status, 409);
    assert.equal((await (await api(path, 'autor')).json()).messages[0].body, message.body);
    assert.deepEqual(await (await api(`${path}?peerId=${author}`, 'tercero')).json(), { messages: [] });
    assert.equal((await (await api('threads', 'autor')).json()).conversations.length, 1);
    assert.equal(privateSignals.length, 2);
    assert.ok(privateSignals.every((users) => users.includes(author) && users.includes(neighbor) && !users.includes(stranger)));
    const group = `groups/${emergency}/messages`;
    const groupMessage = { id: randomUUID(), clientMutationId: randomUUID(), body: 'Mensaje del distrito' };
    assert.equal((await api(group, 'tercero', 'POST', groupMessage)).status, 404);
    assert.equal((await api(group, 'vecino', 'POST', groupMessage)).status, 200);
    assert.equal((await api(group, 'vecino', 'POST', groupMessage)).status, 200);
    assert.deepEqual(groupSignals, [['150121', author]]);
    assert.deepEqual(await (await api(group, 'tercero')).json(), { messages: [] });
    const groupActivity = await (await api('activity', 'autor', 'POST', { groups: [emergency] })).json();
    assert.ok(groupActivity.activity[`group:${emergency}`]);
    assert.ok(groupActivity.activity[`neighbor:${neighbor}`]);
    await client.query("update public.publications set status='resuelta' where id=$1", [emergency]);
    assert.equal((await api(group, 'vecino', 'POST', { ...groupMessage, id: randomUUID(), clientMutationId: randomUUID() })).status, 409);
    assert.equal((await (await api(group, 'vecino')).json()).messages.length, 1);

  } finally {
    try {
      await app?.close();
      await client.query('delete from public.profiles where id=any($1::uuid[])', [[author, neighbor, stranger]]);
    } finally {
      await client.end();
    }
  }
});
