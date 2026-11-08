import { BadRequestException, Body, ConflictException, Controller, Get, Header, Headers, HttpCode, Injectable, NotFoundException, Param, Post, Query } from '@nestjs/common';
import { PoolClient } from 'pg';
import { ChatRealtime } from './chat-realtime';
import { Database } from './database';
import { EntraIdentity } from './entra-identity';
import { id, object } from './publication-operations';

const peers = `((c.publication_author_id=$1 and c.participant_id=$2)
  or (c.publication_author_id=$2 and c.participant_id=$1))`;
const participant = '(c.publication_author_id=$1 or c.participant_id=$1)';
const emergencyAccess = `p.kind in ('emergencia_solicitud','emergencia_oferta') and p.deleted_at is null
  and (p.author_id=$1 or (p.district_ubigeo is not null and p.district_ubigeo=viewer.district_ubigeo))`;
const threadFields = `c.*, p.title as publication_title, a.alias as publication_author_alias,
  b.alias as participant_alias, $1::uuid as owner_user_id, 'confirmado' as sync_status`;
const threadJoins = `from public.conversations c join public.publications p on p.id=c.publication_id
  join public.profiles a on a.id=c.publication_author_id join public.profiles b on b.id=c.participant_id`;

function cursor(query: Record<string, unknown>): [string | null, string | null] {
  const { beforeTime, beforeId } = query;
  if (beforeTime == null && beforeId == null) return [null, null];
  if (typeof beforeTime !== 'string' || !/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,6})?Z$/.test(beforeTime) ||
      !Number.isFinite(Date.parse(beforeTime))) throw new BadRequestException('Cursor inválido.');
  return [beforeTime, id(beforeId)];
}

function message(value: unknown) {
  const input = object(value);
  const body = typeof input.body === 'string' ? input.body.trim() : '';
  if (!body || [...body].length > 1000 || body.includes('\0')) {
    throw new BadRequestException('Escribe un mensaje de hasta 1000 caracteres.');
  }
  return { messageId: id(input.id), mutation: id(input.clientMutationId), body };
}

@Injectable()
export class Chats {
  constructor(private readonly database: Database, private readonly realtime: ChatRealtime) {}

  private async transaction<T>(work: (client: PoolClient) => Promise<T>) {
    const client = await this.database.pool.connect();
    try {
      await client.query('begin');
      const result = await work(client);
      await client.query('commit');
      return result;
    } catch (error) {
      await client.query('rollback');
      if (error && typeof error === 'object' && 'code' in error && error.code === '23505') {
        throw new ConflictException('El identificador ya pertenece a otra operación.');
      }
      throw error;
    } finally {
      client.release();
    }
  }

  async ensure(actor: string, value: unknown) {
    const input = object(value);
    const requested = id(input.id);
    const mutation = id(input.clientMutationId);
    const publication = id(input.publicationId);
    const result = await this.transaction(async (client) => {
      const { rows: [match] } = await client.query(`
        select case when c.publication_author_id=$1 then c.participant_id else c.publication_author_id end as peer
        from public.conversations c where ${participant} and c.id=$2
      `, [actor, requested]);
      const { rows: [target] } = await client.query(`
        select author_id from public.publications where id=$1 and deleted_at is null for share
      `, [publication]);
      const peer = match?.peer ?? target?.author_id;
      if (!peer || peer === actor) throw new NotFoundException('No se puede iniciar esta conversación.');
      await client.query('select pg_advisory_xact_lock(hashtextextended($1,0))',
        [`chat:${[actor, peer].sort().join(':')}`]);
      const { rows: [existing] } = await client.query(`
        select c.id from public.conversations c where ${peers} order by c.created_at,c.id limit 1
      `, [actor, peer]);
      if (existing) return { id: existing.id, peer, created: false };
      if (target?.author_id !== peer) throw new NotFoundException('El aviso ya no admite conversaciones nuevas.');
      await client.query(`insert into public.conversations(id,client_mutation_id,publication_id,publication_author_id,participant_id)
        values($1,$2,$3,$4,$5)`, [requested, mutation, publication, peer, actor]);
      return { id: requested, peer, created: true };
    });
    if (result.created) await this.realtime.privateChanged([actor, result.peer]);
    return { id: result.id };
  }

  async list(actor: string, thread?: string) {
    const { rows } = await this.database.pool.query(`select ${threadFields} ${threadJoins}
      where ${participant} and ($2::uuid is null or c.id=$2) order by c.updated_at desc,c.id`, [actor, thread ?? null]);
    return rows;
  }

  async privateHistory(actor: string, thread: string, peer: string | null, page: [string | null, string | null]) {
    const { rows } = await this.database.pool.query(`
      select to_jsonb(m) || jsonb_build_object('sender_alias',p.alias,'owner_user_id',$1::uuid) as message
      from public.conversations c join public.messages m on m.conversation_id=c.id
      join public.profiles p on p.id=m.sender_id
      where ${participant} and (c.id=$3 and $2::uuid is null or ${peers})
        and ($4::timestamptz is null or (m.created_at,m.id)<($4,$5::uuid))
      order by m.created_at desc,m.id desc limit 100
    `, [actor, peer, thread, ...page]);
    return { messages: rows.map((row) => row.message) };
  }

  async sendPrivate(actor: string, thread: string, value: unknown) {
    const input = object(value);
    const peer = input.recipientId == null ? null : id(input.recipientId);
    const item = message(input);
    const result = await this.transaction(async (client) => {
      const { rows: [target] } = await client.query(`
        select c.id, case when c.publication_author_id=$1 then c.participant_id else c.publication_author_id end as recipient
        from public.conversations c where ${participant} and (c.id=$3 and $2::uuid is null or ${peers})
        order by c.created_at,c.id limit 1 for update
      `, [actor, peer, thread]);
      if (!target) throw new NotFoundException('La conversación no está disponible.');
      const inserted = await client.query(`insert into public.messages(id,client_mutation_id,conversation_id,sender_id,body)
        values($1,$2,$3,$4,$5) on conflict(client_mutation_id) do nothing`,
      [item.messageId, item.mutation, target.id, actor, item.body]);
      const { rows: [saved] } = await client.query(`
        select m.id,m.sender_id,m.body,c.publication_author_id,c.participant_id,
          to_jsonb(m) || jsonb_build_object('sender_alias',p.alias,'owner_user_id',$1::uuid) as message
        from public.messages m join public.conversations c on c.id=m.conversation_id
        join public.profiles p on p.id=m.sender_id where m.client_mutation_id=$2
      `, [actor, item.mutation]);
      if (saved?.id !== item.messageId || saved.sender_id !== actor || saved.body !== item.body ||
          ![saved.publication_author_id,saved.participant_id].includes(target.recipient)) {
        throw new ConflictException('La clave de reintento ya se usó con otro mensaje.');
      }
      if (inserted.rowCount) await client.query('update public.conversations set updated_at=now() where id=$1', [target.id]);
      return { message: saved.message, recipient: target.recipient, created: Boolean(inserted.rowCount) };
    });
    if (result.created) await this.realtime.privateChanged([actor, result.recipient]);
    return result.message;
  }

  async groupHistory(actor: string, publication: string, page: [string | null, string | null]) {
    const { rows } = await this.database.pool.query(`
      select to_jsonb(m) || jsonb_build_object('sender_alias',a.alias) as message
      from public.emergency_group_messages m join public.publications p on p.id=m.publication_id
      join public.profiles viewer on viewer.id=$1 join public.profiles a on a.id=m.sender_id
      where p.id=$2 and ${emergencyAccess} and ($3::timestamptz is null or (m.created_at,m.id)<($3,$4::uuid))
      order by m.created_at desc,m.id desc limit 100
    `, [actor, publication, ...page]);
    return { messages: rows.map((row) => row.message) };
  }

  async sendGroup(actor: string, publication: string, value: unknown) {
    const item = message(value);
    const result = await this.transaction(async (client) => {
      const { rows: [group] } = await client.query(`select p.status,p.district_ubigeo,p.author_id from public.publications p
        join public.profiles viewer on viewer.id=$1 where p.id=$2 and ${emergencyAccess} for share of p`, [actor, publication]);
      if (!group) throw new NotFoundException('El grupo no está disponible.');
      const existing = await client.query('select 1 from public.emergency_group_messages where client_mutation_id=$1', [item.mutation]);
      if (!existing.rowCount && ['resuelta', 'cancelada'].includes(group.status)) {
        throw new ConflictException('El grupo de emergencia quedó en modo lectura.');
      }
      const inserted = existing.rowCount ? false : Boolean((await client.query(`
        insert into public.emergency_group_messages(id,client_mutation_id,publication_id,sender_id,body)
        values($1,$2,$3,$4,$5) on conflict(client_mutation_id) do nothing
      `, [item.messageId, item.mutation, publication, actor, item.body])).rowCount);
      const { rows: [saved] } = await client.query(`select m.*,a.alias as sender_alias from public.emergency_group_messages m
        join public.profiles a on a.id=m.sender_id where m.client_mutation_id=$1`, [item.mutation]);
      if (saved?.id !== item.messageId || saved.sender_id !== actor || saved.publication_id !== publication || saved.body !== item.body) {
        throw new ConflictException('La clave de reintento ya se usó con otro mensaje.');
      }
      return { saved, inserted, group };
    });
    if (result.inserted) await this.realtime.groupChanged(result.group.district_ubigeo, result.group.author_id);
    return result.saved;
  }

  async activity(actor: string, groups: string[]) {
    const { rows } = await this.database.pool.query(`
      select 'neighbor:' || case when c.publication_author_id=$1 then c.participant_id else c.publication_author_id end as key,
        max(c.updated_at) as last_activity from public.conversations c where ${participant} group by 1
      union all
      select 'group:' || p.id, latest.created_at from public.publications p join public.profiles viewer on viewer.id=$1
      cross join lateral (select m.created_at from public.emergency_group_messages m where m.publication_id=p.id
        order by m.created_at desc,m.id desc limit 1) latest
      where p.id=any($2::uuid[]) and ${emergencyAccess}
    `, [actor, groups]);
    return { activity: Object.fromEntries(rows.map((row) => [row.key, row.last_activity])) };
  }

  async negotiate(actor: string) {
    const { rows: [profile] } = await this.database.pool.query('select district_ubigeo from public.profiles where id=$1', [actor]);
    return this.realtime.negotiate(actor, profile?.district_ubigeo ?? null);
  }
}

@Controller('api/v1/chats')
export class ChatsController {
  constructor(private readonly identity: EntraIdentity, private readonly chats: Chats) {}

  @Post('threads') @HttpCode(200)
  async ensure(@Headers('authorization') auth: string | undefined, @Body() body: unknown) {
    return this.chats.ensure(await this.identity.requireProfileId(auth), body);
  }

  @Get('threads')
  async list(@Headers('authorization') auth: string | undefined) {
    return { conversations: await this.chats.list(await this.identity.requireProfileId(auth)) };
  }

  @Get('threads/:id')
  async thread(@Headers('authorization') auth: string | undefined, @Param('id') thread: string) {
    const [result] = await this.chats.list(await this.identity.requireProfileId(auth), id(thread));
    if (!result) throw new NotFoundException('La conversación no está disponible.');
    return result;
  }

  @Get('threads/:id/messages')
  async privateHistory(@Headers('authorization') auth: string | undefined, @Param('id') thread: string, @Query() query: Record<string, unknown>) {
    return this.chats.privateHistory(await this.identity.requireProfileId(auth), id(thread),
      query.peerId == null ? null : id(query.peerId), cursor(query));
  }

  @Post('threads/:id/messages') @HttpCode(200)
  async sendPrivate(@Headers('authorization') auth: string | undefined, @Param('id') thread: string, @Body() body: unknown) {
    return this.chats.sendPrivate(await this.identity.requireProfileId(auth), id(thread), body);
  }

  @Get('groups/:id/messages')
  async groupHistory(@Headers('authorization') auth: string | undefined, @Param('id') group: string, @Query() query: Record<string, unknown>) {
    return this.chats.groupHistory(await this.identity.requireProfileId(auth), id(group), cursor(query));
  }

  @Post('groups/:id/messages') @HttpCode(200)
  async sendGroup(@Headers('authorization') auth: string | undefined, @Param('id') group: string, @Body() body: unknown) {
    return this.chats.sendGroup(await this.identity.requireProfileId(auth), id(group), body);
  }

  @Post('activity') @HttpCode(200)
  async activity(@Headers('authorization') auth: string | undefined, @Body() body: unknown) {
    const actor = await this.identity.requireProfileId(auth);
    const { groups } = object(body);
    if (!Array.isArray(groups) || groups.length > 100) throw new BadRequestException('Envía hasta 100 grupos.');
    return this.chats.activity(actor, groups.map(id));
  }

  @Get('negotiate')
  @Header('Cache-Control', 'no-store')
  async negotiate(@Headers('authorization') auth: string | undefined) {
    return this.chats.negotiate(await this.identity.requireProfileId(auth));
  }
}
