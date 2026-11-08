import { BadRequestException, Body, Controller, Get, Headers, HttpCode, Ip, NotFoundException, Param, Post, Query } from '@nestjs/common';
import { Database } from './database';
import { EntraIdentity } from './entra-identity';
import { id, object, PublicationOperations } from './publication-operations';

function numberInRange(value: unknown, name: string, min: number, max: number) {
  if (typeof value !== 'string' || !/^-?\d+(?:\.\d+)?$/.test(value)) {
    throw new BadRequestException(`${name} debe ser un número decimal.`);
  }
  const number = Number(value);
  if (number < min || number > max) {
    throw new BadRequestException(`${name} debe estar entre ${min} y ${max}.`);
  }
  return number;
}

function districtCode(value: unknown) {
  if (value == null) return null;
  if (typeof value !== 'string' || !/^\d{6}$/.test(value)) throw new BadRequestException('Distrito inválido.');
  return value;
}

function optionalText(value: unknown) {
  if (value == null) return null;
  if (typeof value !== 'string' || value.length > 120 || value.includes('\0')) throw new BadRequestException('Filtro inválido.');
  return value.trim() || null;
}

function pageLimit(value: unknown, fallback: string, maximum: number) {
  const limit = numberInRange(value ?? fallback, 'limit', 1, maximum);
  if (!Number.isInteger(limit)) throw new BadRequestException('limit debe ser entero.');
  return limit;
}

const publicationColumns = `to_jsonb(p)-'location' || jsonb_build_object(
  'author_alias', coalesce(a.alias,'Vecino'), 'owner_user_id', p.author_id, 'sync_status', 'confirmado') as publication`;

@Controller('api/v1/publications')
export class PublicationsController {
  constructor(private readonly database: Database, private readonly identity: EntraIdentity,
    private readonly operations: PublicationOperations) {}

  @Post('operations')
  @HttpCode(200)
  async applyOperation(@Headers('authorization') authorization: string | undefined,
    @Ip() source: string, @Body() body: unknown) {
    const actor = authorization === undefined ? null : await this.identity.requireProfileId(authorization);
    return this.operations.apply(body, actor, source);
  }

  @Get('feed')
  async feed(@Headers('authorization') authorization: string | undefined, @Query() query: Record<string, unknown>) {
    const actor = await this.identity.requireProfileId(authorization);
    const beforeTime = optionalText(query.beforeTime);
    const beforeId = query.beforeId == null ? null : id(query.beforeId);
    if ((beforeTime === null) !== (beforeId === null) ||
        (beforeTime && !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z$/.test(beforeTime)) ||
        (beforeTime && !Number.isFinite(Date.parse(beforeTime)))) {
      throw new BadRequestException('Cursor de fecha inválido.');
    }
    const { rows } = await this.database.pool.query(`
      select ${publicationColumns} from public.publications p left join public.profiles a on a.id=p.author_id
      where p.deleted_at is null and (p.author_id=$1 or p.district_ubigeo=$2)
        and ($3::timestamptz is null or (p.created_at,p.id)<($3,$4::uuid))
      order by p.created_at desc,p.id desc limit $5
    `, [actor, districtCode(query.district), beforeTime, beforeId, pageLimit(query.limit, '30', 100)]);
    return { publications: rows.map((row) => row.publication) };
  }

  @Get('search')
  async search(@Headers('authorization') authorization: string | undefined, @Query() query: Record<string, unknown>) {
    await this.identity.requireProfileId(authorization);
    const latitude = query.lat == null ? null : numberInRange(query.lat, 'lat', -90, 90);
    const longitude = query.lng == null ? null : numberInRange(query.lng, 'lng', -180, 180);
    const district = districtCode(query.district);
    if ((latitude === null) !== (longitude === null) || (latitude === null && !district)) {
      throw new BadRequestException('Indica un punto o distrito válido.');
    }
    const { rows } = await this.database.pool.query(`
      with origin as (select st_setsrid(st_makepoint($2,$1),4326)::geography as point)
      select ${publicationColumns} from public.publications p cross join origin o
      left join public.profiles a on a.id=p.author_id
      where p.deleted_at is null
        and (st_dwithin(p.location,o.point,$3) or (p.district_ubigeo=$4 and (o.point is null or p.location is null)))
        and ($5::text is null or p.kind=$5) and ($6::text is null or p.category=$6)
        and ($7::text is null or strpos(lower(p.title || ' ' || p.description || ' ' || p.sector),lower($7))>0)
      order by case p.priority when 'emergencia' then 0 when 'urgente' then 1 else 2 end,
        st_distance(p.location,o.point) nulls last,p.created_at desc,p.id desc limit $8
    `, [latitude, longitude, numberInRange(query.radiusMeters ?? '1000', 'radiusMeters', 100, 20000),
      district, optionalText(query.kind), query.category === 'todos' ? null : optionalText(query.category),
      optionalText(query.search), pageLimit(query.limit, '201', 1000)]);
    return { publications: rows.map((row) => row.publication) };
  }

  @Post('changes')
  @HttpCode(200)
  async changes(@Headers('authorization') authorization: string | undefined, @Body() body: unknown) {
    await this.identity.requireProfileId(authorization);
    const { ids } = object(body);
    if (!Array.isArray(ids) || ids.length > 100) throw new BadRequestException('Envía hasta 100 identificadores.');
    const { rows } = await this.database.pool.query(`
      select case when p.deleted_at is null then
        to_jsonb(p)-'location' || jsonb_build_object('author_alias',coalesce(a.alias,'Vecino'),
          'owner_user_id',p.author_id,'sync_status','confirmado') end as publication,
        p.id as publication_id,p.deleted_at
      from public.publications p left join public.profiles a on a.id=p.author_id where p.id=any($1::uuid[])
    `, [ids.map(id)]);
    return {
      publications: rows.filter((row) => row.publication).map((row) => row.publication),
      tombstones: rows.filter((row) => row.deleted_at).map(({ publication_id, deleted_at }) => ({ publication_id, deleted_at })),
    };
  }

  @Get('mine')
  async mine(@Headers('authorization') authorization: string | undefined) {
    const actor = await this.identity.requireProfileId(authorization);
    const { rows } = await this.database.pool.query(`
      select ${publicationColumns} from public.publications p join public.profiles a on a.id=p.author_id
      where p.author_id=$1 and p.deleted_at is null order by p.created_at desc,p.id desc limit 200
    `, [actor]);
    return { publications: rows.map((row) => row.publication) };
  }

  @Get('mine/:id')
  async own(@Headers('authorization') authorization: string | undefined, @Param('id') entity: string) {
    const actor = await this.identity.requireProfileId(authorization);
    const { rows: [row] } = await this.database.pool.query(`
      select ${publicationColumns} from public.publications p join public.profiles a on a.id=p.author_id
      where p.author_id=$1 and p.id=$2
    `, [actor, id(entity)]);
    if (!row) throw new NotFoundException('El aviso no está disponible para esta cuenta.');
    return row.publication;
  }

  @Get('community')
  async community(@Headers('authorization') authorization: string | undefined) {
    const actor = await this.identity.requireProfileId(authorization);
    const [recommendations, offers, resources, groups] = await Promise.all([
      this.database.pool.query(`
        select r.*,a.alias as user_alias,$1::uuid as owner_user_id,'confirmado' as sync_status
        from public.recommendations r join public.profiles a on a.id=r.user_id
        join public.publications p on p.id=r.publication_id join public.profiles viewer on viewer.id=$1
        where p.deleted_at is null and (p.district_ubigeo=viewer.district_ubigeo or p.author_id=$1 or r.user_id=$1)
      `, [actor]),
      this.database.pool.query(`
        select h.*,a.alias as helper_alias,$1::uuid as owner_user_id,'confirmado' as sync_status
        from public.help_offers h join public.profiles a on a.id=h.helper_id
        join public.publications p on p.id=h.publication_id
        where p.deleted_at is null and (p.author_id=$1 or h.helper_id=$1)
      `, [actor]),
      this.database.pool.query(`select to_jsonb(r)-'location' as record from public.community_resources r
        join public.profiles p on p.id=$1 and p.neighborhood=r.neighborhood`, [actor]),
      this.database.pool.query(`select g.* from public.support_groups g
        join public.profiles p on p.id=$1 and p.neighborhood=g.neighborhood`, [actor]),
    ]);
    return { recommendations: recommendations.rows, help_offers: offers.rows,
      community_resources: resources.rows.map((row) => row.record), support_groups: groups.rows };
  }

  @Get('resources')
  async resources(@Headers('authorization') authorization: string | undefined, @Query() query: Record<string, unknown>) {
    await this.identity.requireProfileId(authorization);
    const { rows } = await this.database.pool.query(`
      with origin as (select st_setsrid(st_makepoint($2,$1),4326)::geography as point)
      select to_jsonb(r)-'location' as record from public.community_resources r cross join origin o
      where st_dwithin(r.location,o.point,$3)
      order by st_distance(r.location,o.point),r.id limit $4
    `, [numberInRange(query.lat, 'lat', -90, 90), numberInRange(query.lng, 'lng', -180, 180),
      numberInRange(query.radiusMeters ?? '20000', 'radiusMeters', 100, 20000), pageLimit(query.limit, '201', 1000)]);
    return { resources: rows.map((row) => row.record) };
  }

  @Get('nearby')
  async nearby(
    @Headers('authorization') authorization: string | undefined,
    @Query('lat') lat: unknown,
    @Query('lng') lng: unknown,
    @Query('radiusMeters') radiusMeters: unknown = '1000',
  ) {
    const signedIn = authorization !== undefined;
    if (signedIn) await this.identity.requireProfileId(authorization);
    const { rows } = await this.database.pool.query(
      `select n.* from public.find_nearby_publications($1, $2, $3) n
       join public.publications p on p.id=n.id where $4::boolean or p.is_demo
       order by n.distance_meters,p.created_at desc,p.id`,
      [
        numberInRange(lat, 'lat', -90, 90),
        numberInRange(lng, 'lng', -180, 180),
        numberInRange(radiusMeters, 'radiusMeters', 100, 20000),
        signedIn,
      ],
    );
    return { publications: rows };
  }
}
