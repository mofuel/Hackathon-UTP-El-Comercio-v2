import { BadRequestException, Body, Controller, ForbiddenException, Get, Headers, NotFoundException, Put } from '@nestjs/common';
import { Database } from './database';
import { EntraIdentity } from './entra-identity';

@Controller('api/v1/me')
export class ProfileController {
  constructor(private readonly database: Database, private readonly identity: EntraIdentity) {}

  @Get()
  async getProfile(@Headers('authorization') authorization: string | undefined) {
    const { issuer, subject, supabaseProfileId } = await this.identity.requireUser(authorization);
    const { rows: [profile] } = await this.database.pool.query(`
      select p.id, p.alias, p.neighborhood, p.sector, p.district_ubigeo, p.bio,
        p.approx_lat, p.approx_lng, p.use_gps_approx, p.share_resources_consent, p.updated_at
      from public.profiles p
      where p.id = coalesce($3::uuid, (
        select profile_id from public.profile_identities where issuer = $1 and subject = $2
      )) and ($3::uuid is null or not p.is_demo)
    `, [issuer, subject, supabaseProfileId ?? null]);
    if (!profile) throw new NotFoundException('Completa tu perfil de Conecta2.');
    return profile;
  }

  @Put()
  async saveProfile(
    @Headers('authorization') authorization: string | undefined,
    @Body('alias') input: unknown,
  ) {
    const { issuer, subject, supabaseProfileId } = await this.identity.requireUser(authorization);
    const alias = typeof input === 'string' ? input.trim() : '';
    const length = [...alias].length;
    if (length < 2 || length > 60 || alias.includes('\0')) {
      throw new BadRequestException('El alias debe contener entre 2 y 60 caracteres válidos.');
    }

    if (supabaseProfileId) {
      // Los perfiles de la instantánea conservaron el UUID de Supabase Auth.
      const { rows: [profile] } = await this.database.pool.query(`
        insert into public.profiles (id, alias) values ($1, $2)
        on conflict (id) do update set id = excluded.id where not profiles.is_demo
        returning id, alias, neighborhood, sector, district_ubigeo, bio,
          approx_lat, approx_lng, use_gps_approx, share_resources_consent, updated_at
      `, [supabaseProfileId, alias]);
      if (!profile) throw new ForbiddenException('No se puede usar este perfil.');
      return profile;
    }

    const client = await this.database.pool.connect();
    try {
      await client.query('begin');
      // Serializa el alta cuando la misma identidad envía dos solicitudes a la vez.
      await client.query('select pg_advisory_xact_lock(hashtextextended($1, 0))', [JSON.stringify([issuer, subject])]);
      const { rows: [existing] } = await client.query(`
        select profile_id from public.profile_identities where issuer = $1 and subject = $2
      `, [issuer, subject]);
      const { rows: [profile] } = existing
        ? await client.query(`
            update public.profiles set alias = $2, updated_at = now() where id = $1
            returning id, alias, neighborhood, sector, district_ubigeo, bio,
              approx_lat, approx_lng, use_gps_approx, share_resources_consent, updated_at
          `, [existing.profile_id, alias])
        : await client.query(`
            insert into public.profiles (alias) values ($1)
            returning id, alias, neighborhood, sector, district_ubigeo, bio,
              approx_lat, approx_lng, use_gps_approx, share_resources_consent, updated_at
          `, [alias]);
      if (!existing) {
        await client.query(`
          insert into public.profile_identities (issuer, subject, profile_id) values ($1, $2, $3)
        `, [issuer, subject, profile.id]);
      }
      await client.query('commit');
      return profile;
    } catch (error) {
      await client.query('rollback');
      throw error;
    } finally {
      client.release();
    }
  }
}
