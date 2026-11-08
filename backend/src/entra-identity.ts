import { ForbiddenException, Injectable, ServiceUnavailableException, UnauthorizedException } from '@nestjs/common';
import { createRemoteJWKSet, jwtVerify } from 'jose';
import { Database } from './database';

const uuid = /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i;
const tenantName = /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/i;

interface Issuer {
  issuer: string;
  keys: ReturnType<typeof createRemoteJWKSet>;
}

@Injectable()
export class EntraIdentity {
  constructor(private readonly database: Database) {}

  private readonly subdomain = process.env.ENTRA_TENANT_SUBDOMAIN ?? '';
  private readonly tenantId = (process.env.ENTRA_TENANT_ID ?? '').toLowerCase();
  private readonly audience = (process.env.ENTRA_API_CLIENT_ID ?? '').toLowerCase();
  private readonly mobileClientId = (process.env.ENTRA_MOBILE_CLIENT_ID ?? '').toLowerCase();
  private issuerMetadata?: Promise<Issuer>;

  async requireUser(authorization: string | undefined) {
    const token = /^Bearer ([^\s,]+)$/i.exec(authorization ?? '')?.[1];
    if (!token) throw new UnauthorizedException('Se requiere un token de acceso.');

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
    const { issuer, subject } = await this.requireUser(authorization);
    const { rows: [profile] } = await this.database.pool.query(
      'select profile_id from public.profile_identities where issuer = $1 and subject = $2',
      [issuer, subject],
    );
    if (!profile) throw new ForbiddenException('Completa tu perfil de Conecta2.');
    return profile.profile_id;
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
