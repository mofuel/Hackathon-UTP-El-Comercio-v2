import { ForbiddenException, Injectable, ServiceUnavailableException, UnauthorizedException } from '@nestjs/common';
import { createRemoteJWKSet, decodeJwt, jwtVerify } from 'jose';
import { Database } from './database';

const uuid = /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i;
const tenantName = /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/i;

interface Issuer {
  issuer: string;
  keys: ReturnType<typeof createRemoteJWKSet>;
}

interface VerifiedIdentity {
  issuer: string;
  subject: string;
  supabaseProfileId?: string;
}

@Injectable()
export class EntraIdentity {
  constructor(private readonly database: Database) {}

  private readonly subdomain = process.env.ENTRA_TENANT_SUBDOMAIN ?? '';
  private readonly tenantId = (process.env.ENTRA_TENANT_ID ?? '').toLowerCase();
  private readonly audience = (process.env.ENTRA_API_CLIENT_ID ?? '').toLowerCase();
  private readonly mobileClientId = (process.env.ENTRA_MOBILE_CLIENT_ID ?? '').toLowerCase();
  private readonly supabaseUrl = process.env.SUPABASE_AUTH_URL?.replace(/\/+$/, '');
  private readonly supabaseKey = process.env.SUPABASE_AUTH_PUBLIC_KEY;
  private issuerMetadata?: Promise<Issuer>;

  async requireUser(authorization: string | undefined): Promise<VerifiedIdentity> {
    const token = /^Bearer ([^\s,]+)$/i.exec(authorization ?? '')?.[1];
    if (!token) throw new UnauthorizedException('Se requiere un token de acceso.');

    if (this.supabaseUrl) {
      const claims = this.decodeToken(token);
      if (claims.iss === `${this.supabaseUrl}/auth/v1`) {
        return this.verifySupabase(token, claims);
      }
      if (!this.subdomain) throw new UnauthorizedException('El emisor del token no es válido.');
    }

    const { issuer, keys } = await this.getIssuer();
    const { payload } = await jwtVerify(token, keys, {
      issuer,
      audience: this.audience,
      algorithms: ['RS256'],
      requiredClaims: ['exp', 'sub', 'tid', 'oid', 'ver'],
    }).catch((error: unknown) => {
      if (error instanceof TypeError || (error instanceof Error &&
        'code' in error && ['ERR_JWKS_TIMEOUT', 'ERR_JOSE_GENERIC'].includes(String(error.code)))) {
        throw new ServiceUnavailableException('No se pudieron consultar las claves de identidad.');
      }
      throw new UnauthorizedException('El token de acceso no es válido.');
    });

    if (payload.ver !== '2.0' || payload.tid !== this.tenantId ||
        typeof payload.oid !== 'string' || !uuid.test(payload.oid)) {
      throw new UnauthorizedException('La identidad del token no es válida.');
    }
    if (payload.azp !== this.mobileClientId || typeof payload.scp !== 'string' ||
        !payload.scp.split(' ').includes('access_as_user')) {
      throw new ForbiddenException('El token no concede acceso a Conecta2.');
    }

    return { issuer, subject: payload.oid.toLowerCase() };
  }

  async requireProfileId(authorization: string | undefined): Promise<string> {
    const { issuer, subject, supabaseProfileId } = await this.requireUser(authorization);
    const { rows: [profile] } = await this.database.pool.query(
      supabaseProfileId
        ? 'select id as profile_id from public.profiles where id = $1 and not is_demo'
        : 'select profile_id from public.profile_identities where issuer = $1 and subject = $2',
      supabaseProfileId ? [supabaseProfileId] : [issuer, subject],
    );
    if (!profile) throw new ForbiddenException('Completa tu perfil de Conecta2.');
    return profile.profile_id;
  }

  private decodeToken(token: string) {
    try {
      return decodeJwt(token);
    } catch {
      throw new UnauthorizedException('El token de acceso no es válido.');
    }
  }

  private async verifySupabase(token: string, claims: ReturnType<typeof decodeJwt>): Promise<VerifiedIdentity> {
    const issuer = `${this.supabaseUrl}/auth/v1`;
    const key = this.supabaseKey;
    if (!key || !/^https:\/\/[a-z0-9]+\.supabase\.co$/i.test(this.supabaseUrl ?? '')) {
      throw new ServiceUnavailableException('La autenticación de Supabase no está configurada.');
    }
    const subject = claims.sub;
    if (typeof subject !== 'string' || !uuid.test(subject) || claims.role !== 'authenticated' ||
        claims.aud !== 'authenticated' || claims.is_anonymous === true ||
        typeof claims.exp !== 'number' || claims.exp <= Date.now() / 1000) {
      throw new UnauthorizedException('La sesión de Supabase no es válida.');
    }

    let response: Response;
    try {
      response = await fetch(`${issuer}/user`, {
        headers: { apikey: key, Authorization: `Bearer ${token}` },
        redirect: 'error',
        signal: AbortSignal.timeout(5000),
      });
    } catch {
      throw new ServiceUnavailableException('No se pudo verificar la sesión con Supabase.');
    }
    if (response.status === 429 || response.status >= 500) {
      throw new ServiceUnavailableException('No se pudo verificar la sesión con Supabase.');
    }
    if (!response.ok) throw new UnauthorizedException('La sesión de Supabase no es válida.');
    const user = await response.json();
    if (user?.id !== subject || user.is_anonymous === true) {
      throw new UnauthorizedException('La identidad de Supabase no coincide.');
    }
    return { issuer, subject, supabaseProfileId: subject };
  }

  private getIssuer() {
    if (!tenantName.test(this.subdomain) || !uuid.test(this.tenantId) ||
        !uuid.test(this.audience) || !uuid.test(this.mobileClientId)) {
      throw new ServiceUnavailableException('La autenticación de Entra aún no está configurada.');
    }

    this.issuerMetadata ??= this.discoverIssuer().catch(() => {
      this.issuerMetadata = undefined;
      throw new ServiceUnavailableException('No se pudo consultar Microsoft Entra.');
    });
    return this.issuerMetadata;
  }

  private async discoverIssuer(): Promise<Issuer> {
    const authority = `https://${this.subdomain}.ciamlogin.com/${this.tenantId}/v2.0`;
    const response = await fetch(`${authority}/.well-known/openid-configuration`, {
      redirect: 'error',
      signal: AbortSignal.timeout(5000),
    });
    if (!response.ok) throw new Error('Metadatos OIDC no disponibles.');
    const { issuer, jwks_uri } = await response.json();
    const keys = new URL(jwks_uri);
    if (issuer !== `https://${this.tenantId}.ciamlogin.com/${this.tenantId}/v2.0` ||
        keys.protocol !== 'https:') {
      throw new Error('Metadatos OIDC no válidos.');
    }
    return { issuer, keys: createRemoteJWKSet(keys, { timeoutDuration: 5000 }) };
  }
}
