import { createHash } from 'node:crypto';
import { BadRequestException, ConflictException, ForbiddenException, HttpException, Injectable, NotFoundException } from '@nestjs/common';
import { PoolClient } from 'pg';
import { Database } from './database';

type Fields = Record<string, unknown>;

export const uuidPattern = /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i;
const actions: Readonly<Record<string, readonly string[]>> = {
  publication: ['upsert', 'insert', 'create'],
  publication_edit: ['update'],
  publication_delete: ['delete'],
  publication_location: ['update'],
  publication_status: ['update_status'],
  recommendation: ['upsert', 'delete'],
  help_offer: ['upsert'],
  profile: ['upsert'],
};

export function object(value: unknown): Fields {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new BadRequestException('Se esperaba un objeto JSON.');
  }
  return value as Fields;
}

export function id(value: unknown): string {
  if (typeof value !== 'string' || !uuidPattern.test(value)) {
    throw new BadRequestException('Identificador inválido.');
  }
  return value.toLowerCase();
}

function text(value: unknown, fallback = ''): string {
  if (value == null) return fallback;
  if (typeof value !== 'string' || value.includes('\0')) throw new BadRequestException('Texto inválido.');
  return value.trim();
}

function flag(value: unknown) {
  return value === true || value === 1;
}

function coordinate(value: unknown, maximum: number): number | null {
  if (value == null) return null;
  if (typeof value !== 'number' || !Number.isFinite(value) || Math.abs(value) > maximum) {
    throw new BadRequestException('Coordenadas inválidas.');
  }
  return value;
}

function location(fields: Fields) {
  return [text(fields.district_ubigeo) || null,
    coordinate(fields.approx_lat, 90), coordinate(fields.approx_lng, 180)] as const;
}

function serviceLocation(fields: Fields) {
  return flag(fields.share_service_location)
    ? [true, coordinate(fields.service_lat, 85.05112878), coordinate(fields.service_lng, 180), text(fields.service_address)]
    : [false, null, null, ''];
}

@Injectable()
export class PublicationOperations {
  constructor(private readonly database: Database) {}

  async apply(input: unknown, actor: string | null, source: string) {
    const request = object(input);
    const { entityType, action, expectedVersion } = request;
    const operationId = request.operationId;
    const entityId = id(request.entityId);
    const payload = object(request.payload);
    if (typeof operationId !== 'string' || !/^[a-zA-Z0-9-]{1,100}$/.test(operationId) ||
        typeof entityType !== 'string' || typeof action !== 'string' ||
        !Object.hasOwn(actions, entityType) || !actions[entityType].includes(action) ||
        typeof expectedVersion !== 'number' || !Number.isSafeInteger(expectedVersion) || expectedVersion < 0) {
      throw new BadRequestException('Operación de sincronización inválida.');
    }
    if (request.ownerUserId !== (actor ?? 'anonymous') ||
        (!actor && (entityType !== 'publication' || payload.kind !== 'emergencia_solicitud'))) {
      throw new ForbiddenException('La sesión no puede enviar esta operación.');
    }

    const actorKey = actor ?? 'anonymous';
    const snapshot = JSON.stringify({ entityType, entityId, action, expectedVersion, payload });
    const client = await this.database.pool.connect();
    try {
      await client.query('begin');
      await client.query('select pg_advisory_xact_lock(hashtextextended($1, 0))', [`${actorKey}:${operationId}`]);
      const { rows: [receipt] } = await client.query(`
        select result_version, request_hash = sha256(convert_to(($3::jsonb)::text, 'UTF8')) as matches
        from public.publication_operation_receipts where actor_key = $1 and operation_id = $2
      `, [actorKey, operationId, snapshot]);
      let version = receipt?.result_version ?? null;
      if (receipt && !receipt.matches) throw new ConflictException('El identificador ya se usó con otros datos.');
      if (!receipt) {
        if (entityType === 'publication') {
          version = await this.createPublication(client, actor, entityId, payload, source);
        } else if (actor && entityType === 'profile') {
          await this.updateProfile(client, actor, entityId, payload);
        } else if (actor && (entityType === 'recommendation' || entityType === 'help_offer')) {
          await this.recordAction(client, actor, entityType, entityId, action, payload);
        } else if (actor) {
          version = await this.changePublication(client, actor, entityType, entityId, expectedVersion, payload);
        }
        await client.query(`
          insert into public.publication_operation_receipts (actor_key, operation_id, request_hash, result_version)
          values ($1, $2, sha256(convert_to(($3::jsonb)::text, 'UTF8')), $4)
        `, [actorKey, operationId, snapshot, version]);
      }
      await client.query('commit');
      return { version };
    } catch (error) {
      await client.query('rollback');
      if (error && typeof error === 'object' && 'code' in error) {
        if (error.code === '23505') throw new ConflictException('Ya existe un registro con esos identificadores.');
        if (['23502', '23503', '23514', '22P02', '22003'].includes(String(error.code))) {
          throw new BadRequestException('Revisa los datos de la operación.');
        }
      }
      throw error;
    } finally {
      client.release();
    }
  }

  private async createPublication(client: PoolClient, actor: string | null, entity: string, p: Fields, source: string) {
    const mutation = id(p.client_mutation_id);
    if (id(p.id) !== entity) throw new BadRequestException('Los identificadores del aviso no coinciden.');
    if (!actor) {
      const sourceHash = createHash('sha256').update(source).digest('hex');
      const limit = await client.query(`
        insert into public.guest_report_limits values ($1, now(), 1)
        on conflict (source_hash) do update set
          window_start = case when guest_report_limits.window_start <= now() - interval '1 minute' then now() else guest_report_limits.window_start end,
          reports = case when guest_report_limits.window_start <= now() - interval '1 minute' then 1 else guest_report_limits.reports + 1 end
        where guest_report_limits.window_start <= now() - interval '1 minute' or guest_report_limits.reports < 10
        returning reports
      `, [sourceHash]);
      if (limit.rowCount === 0) throw new HttpException('Demasiados reportes. Intenta de nuevo en un minuto.', 429);
    }
    const description = text(p.description);
    if (!description) throw new BadRequestException('Completa la descripción del aviso.');
    const { rows: [created] } = await client.query(`
      insert into public.publications (id, client_mutation_id, author_id, kind, category, title,
        description, neighborhood, sector, availability_text, priority, status, share_resource_consent,
        district_ubigeo, approx_lat, approx_lng, share_service_location, service_lat, service_lng, service_address)
      values ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,'abierta',$12,$13,$14,$15,$16,$17,$18,$19)
      on conflict do nothing returning version
    `, [entity, mutation, actor, text(p.kind), text(p.category, 'general'), text(p.title), description,
      text(p.neighborhood, 'Pueblo Libre'), text(p.sector, 'Zona general'), text(p.availability_text),
      actor ? text(p.priority, 'normal') : 'emergencia', flag(p.share_resource_consent), ...location(p), ...serviceLocation(p)]);
    if (created) return created.version;
    const { rows: [previous] } = await client.query(`
      select version from public.publications where id = $1 and client_mutation_id = $2
        and author_id is not distinct from $3::uuid
    `, [entity, mutation, actor]);
    if (!previous) throw new ConflictException('El aviso ya existe con otros identificadores.');
    return previous.version;
  }

  private async changePublication(client: PoolClient, actor: string, type: string, entity: string, expected: number, p: Fields) {
    const { rows: [current] } = await client.query(`
      select version, deleted_at, status from public.publications where id = $1 and author_id = $2 for update
    `, [entity, actor]);
    if (!current) throw new NotFoundException('El aviso no está disponible para esta cuenta.');
    if (current.deleted_at || current.version !== expected) throw new ConflictException('El aviso cambió. Revisa su versión.');

    let change: string;
    let values: unknown[] = [];
    switch (type) {
      case 'publication_edit':
        change = 'title=$2, description=$3, category=$4, availability_text=$5';
        values = [text(p.title), text(p.description), text(p.category), text(p.availability_text)];
        if (!values[1]) throw new BadRequestException('Completa la descripción del aviso.');
        break;
      case 'publication_location':
        change = 'district_ubigeo=$2, approx_lat=$3, approx_lng=$4, share_service_location=$5, service_lat=$6, service_lng=$7, service_address=$8';
        values = [...location(p), ...serviceLocation(p)];
        if (values.slice(0, 3).some((value) => value == null)) throw new BadRequestException('Elige un distrito y un punto.');
        break;
      case 'publication_status': {
        const next = text(p.status);
        if ((current.status === 'cancelada' && next !== 'cancelada') ||
            (current.status === 'resuelta' && !['resuelta', 'abierta'].includes(next))) {
          throw new ConflictException('El cambio de estado no está permitido.');
        }
        change = 'status=$2';
        values = [next];
        break;
      }
      case 'publication_delete':
        change = 'deleted_at=now()';
        break;
      default:
        throw new BadRequestException('Operación no compatible.');
    }
    const { rows: [result] } = await client.query(`
      update public.publications set ${change}, version=version+1, updated_at=now() where id=$1 returning version
    `, [entity, ...values]);
    return result.version;
  }

  private async updateProfile(client: PoolClient, actor: string, entity: string, p: Fields) {
    if (actor !== entity) throw new ForbiddenException('Solo puedes modificar tu perfil.');
    await client.query(`
      update public.profiles set alias=$2, neighborhood=$3, sector=$4, bio=$5,
        district_ubigeo=$6, approx_lat=$7, approx_lng=$8, use_gps_approx=$9, share_resources_consent=$10,
        updated_at=now() where id=$1
    `, [actor, text(p.alias), text(p.neighborhood), text(p.sector), text(p.bio), ...location(p),
      flag(p.use_gps_approx), flag(p.share_resources_consent)]);
  }

  private async recordAction(client: PoolClient, actor: string, type: string, entity: string, action: string, p: Fields) {
    const publication = id(p.publication_id);
    const { rows: [target] } = await client.query(`
      select id, author_id, kind, category, district_ubigeo, sector, deleted_at, status
      from public.publications where id=$1 for update
    `, [publication]);
    if (!target) throw new NotFoundException('El aviso no existe.');
    if (type === 'recommendation' && action === 'delete') {
      const deleted = await client.query('delete from public.recommendations where id=$1 and user_id=$2 and publication_id=$3',
        [entity, actor, publication]);
      if (deleted.rowCount) await this.recount(client, publication);
      return;
    }
    if (target.deleted_at || target.author_id === actor) throw new ForbiddenException('No puedes realizar esa acción en este aviso.');
    const mutation = id(p.client_mutation_id);
    if (type === 'recommendation') {
      if (target.kind !== 'servicio') {
        const { rowCount } = await client.query(`
          select 1 from public.profiles where id=$1 and district_ubigeo=$2
            and nullif(lower(btrim(sector)), '') = nullif(lower(btrim($3)), '')
        `, [actor, target.district_ubigeo, target.sector]);
        if (target.kind !== 'anuncio' || target.category !== 'producto' || !rowCount) {
          throw new ForbiddenException('Solo se recomiendan servicios o productos del mismo distrito y sector.');
        }
      }
      const saved = await client.query(`
        insert into public.recommendations (id,client_mutation_id,publication_id,user_id,comment)
        values ($1,$2,$3,$4,$5) on conflict (publication_id,user_id) do update
        set comment=excluded.comment,updated_at=now()
        where recommendations.id=excluded.id and recommendations.client_mutation_id=excluded.client_mutation_id
      `, [entity, mutation, publication, actor, text(p.comment)]);
      if (!saved.rowCount) throw new ConflictException('La recomendación ya existe en otro dispositivo.');
      await this.recount(client, publication);
      return;
    }
    if (['resuelta', 'cancelada'].includes(target.status)) throw new ConflictException('El aviso ya no recibe ofertas.');
    const saved = await client.query(`
      insert into public.help_offers (id,client_mutation_id,publication_id,helper_id,note,resource_shared,explicit_share_consent)
      values ($1,$2,$3,$4,$5,$6,$7) on conflict (publication_id,helper_id) do update
      set note=excluded.note,resource_shared=excluded.resource_shared,explicit_share_consent=excluded.explicit_share_consent,updated_at=now()
      where help_offers.id=excluded.id and help_offers.client_mutation_id=excluded.client_mutation_id
    `, [entity, mutation, publication, actor, text(p.note), text(p.resource_shared), flag(p.explicit_share_consent)]);
    if (!saved.rowCount) throw new ConflictException('La oferta ya existe en otro dispositivo.');
    await client.query(`update public.publications set status='en_coordinacion',version=version+1,updated_at=now()
      where id=$1 and status='abierta'`, [publication]);
  }

  private async recount(client: PoolClient, publication: string) {
    await client.query(`update public.publications set recommendation_count=(
      select count(*) from public.recommendations where publication_id=$1),version=version+1,updated_at=now() where id=$1`, [publication]);
  }
}
