import { BadRequestException, Body, ConflictException, Controller, Delete, Get, Headers, Injectable, Logger, OnModuleDestroy, OnModuleInit, Param, Put, ServiceUnavailableException } from '@nestjs/common';
import { JWT } from 'google-auth-library';
import { Database } from './database';
import { EntraIdentity } from './entra-identity';
import { id, object } from './publication-operations';

interface PushJob {
  id: string;
  attempts: number;
  device_id: string;
  installation_id: string;
  recipient_id: string;
  message_id: string;
  conversation_id: string;
  expires_at: Date;
}

@Injectable()
export class FcmTransport {
  private readonly config = process.env.FCM_SERVICE_ACCOUNT_JSON;
  private account?: { project: string; auth: JWT };

  get available() { return Boolean(this.config); }

  async send(job: PushJob): Promise<'sent' | 'invalid' | 'retry'> {
    if (!this.account) {
      const { project_id, client_email, private_key } = JSON.parse(this.config ?? '{}');
      if (![project_id, client_email, private_key].every((value) => typeof value === 'string' && value.length)) {
        throw new Error('Configuración FCM inválida.');
      }
      this.account = { project: project_id, auth: new JWT({ email: client_email, key: private_key,
        scopes: ['https://www.googleapis.com/auth/firebase.messaging'] }) };
    }
    const { token } = await this.account.auth.getAccessToken();
    if (!token) throw new Error('No se pudo autorizar Firebase.');
    const remaining = Math.floor((job.expires_at.getTime() - Date.now()) / 1000);
    if (remaining <= 0) return 'sent';
    const response = await fetch(`https://fcm.googleapis.com/v1/projects/${encodeURIComponent(this.account.project)}/messages:send`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      signal: AbortSignal.timeout(10000),
      body: JSON.stringify({ message: {
        fid: job.installation_id,
        notification: { title: 'Conecta2', body: 'Tienes un mensaje nuevo.' },
        data: { type: 'private_message', recipient_id: job.recipient_id,
          conversation_id: job.conversation_id, message_id: job.message_id },
        android: { ttl: `${remaining}s`, notification: { tag: job.conversation_id } },
        apns: { headers: { 'apns-collapse-id': job.conversation_id,
          'apns-expiration': String(Math.floor(job.expires_at.getTime() / 1000)) } },
      } }),
    });
    if (response.ok) return 'sent';
    const result = await response.json().catch(() => null);
    return Array.isArray(result?.error?.details) && result.error.details.some(
      (entry: { errorCode?: string }) => entry?.errorCode === 'UNREGISTERED',
    ) ? 'invalid' : 'retry';
  }
}

@Injectable()
export class PrivatePushWorker implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(PrivatePushWorker.name);
  private timer?: NodeJS.Timeout;
  private running?: Promise<void>;

  constructor(private readonly database: Database, private readonly fcm: FcmTransport) {}

  onModuleInit() {
    if (this.fcm.available) {
      this.timer = setInterval(() => void this.drain(), 5000);
      this.timer.unref();
    }
  }

  async onModuleDestroy() {
    clearInterval(this.timer);
    await this.running;
  }

  drain() {
    return this.running ??= this.processBatch().catch(() => {
      this.logger.warn('No se pudo procesar la cola de avisos. Se reintentará.');
    }).finally(() => { this.running = undefined; });
  }

  private async processBatch() {
    await this.database.pool.query(`delete from public.private_message_push_queue q
      where q.created_at <= now() - interval '1 hour'
         or (q.attempts >= 5 and q.available_at <= now())
         or not exists(select 1 from public.private_message_installations i where i.device_id=q.device_id
           and i.recipient_id=q.recipient_id and i.installation_id=q.installation_id)`);
    const { rows } = await this.database.pool.query<PushJob>(`with ready as (
      select id from public.private_message_push_queue where available_at<=now() and attempts<5
      order by available_at,id limit 20 for update skip locked
    ), claimed as (
      update public.private_message_push_queue q set attempts=q.attempts+1,available_at=now()+interval '2 minutes'
      from ready where q.id=ready.id returning q.*
    ) select c.*,m.conversation_id,c.created_at + interval '1 hour' as expires_at
      from claimed c join public.messages m on m.id=c.message_id`);
    await Promise.all(rows.map(async (job) => {
      try {
        const { rowCount } = await this.database.pool.query(`select 1 from public.private_message_installations
          where device_id=$1 and installation_id=$2 and recipient_id=$3`,
        [job.device_id, job.installation_id, job.recipient_id]);
        if (!rowCount) return;
        const result = await this.fcm.send(job);
        if (result === 'retry') return;
        await this.database.pool.query(`with completed as (
          delete from public.private_message_push_queue where id=$1 and attempts=$2
          returning device_id,installation_id,recipient_id
        ) delete from public.private_message_installations i using completed c
          where $3::boolean and i.device_id=c.device_id and i.installation_id=c.installation_id and i.recipient_id=c.recipient_id`,
        [job.id, job.attempts, result === 'invalid']);
      } catch {
        this.logger.warn('Un aviso sigue pendiente para el próximo intento.');
      }
    }));
  }
}

@Controller('api/v1/chats/push')
export class PrivatePushController {
  constructor(private readonly identity: EntraIdentity, private readonly database: Database, private readonly fcm: FcmTransport) {}

  @Get(':device')
  async status(@Headers('authorization') auth: string | undefined, @Param('device') device: string) {
    const actor = await this.identity.requireProfileId(auth);
    const { rowCount } = await this.database.pool.query(`select 1 from public.private_message_installations
      where device_id=$1 and recipient_id=$2`, [id(device), actor]);
    return { enabled: Boolean(rowCount), available: this.fcm.available };
  }

  @Put(':device')
  async enable(@Headers('authorization') auth: string | undefined, @Param('device') device: string, @Body() body: unknown) {
    const actor = await this.identity.requireProfileId(auth);
    if (!this.fcm.available) throw new ServiceUnavailableException('Los avisos aún no están configurados.');
    const { installationId } = object(body);
    if (typeof installationId !== 'string' || !/^[A-Za-z0-9_-]{10,256}$/.test(installationId)) {
      throw new BadRequestException('Instalación inválida.');
    }
    await this.database.pool.query(`insert into public.private_message_installations(device_id,installation_id,recipient_id)
      values($1,$2,$3) on conflict(device_id) do update
      set installation_id=excluded.installation_id,recipient_id=excluded.recipient_id,updated_at=now()`,
    [id(device), installationId, actor]).catch((error: { code?: string }) => {
      if (error.code === '23505') throw new ConflictException('La instalación ya está registrada en otro dispositivo.');
      throw error;
    });
    return { enabled: true };
  }

  @Delete(':device')
  async disable(@Headers('authorization') auth: string | undefined, @Param('device') device: string) {
    const actor = await this.identity.requireProfileId(auth);
    await this.database.pool.query('delete from public.private_message_installations where device_id=$1 and recipient_id=$2',
      [id(device), actor]);
    return { enabled: false };
  }
}
