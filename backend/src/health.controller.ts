import { Controller, Get, ServiceUnavailableException } from '@nestjs/common';
import { Database } from './database';

@Controller('health')
export class HealthController {
  constructor(private readonly database: Database) {}

  @Get('live')
  live() {
    return { status: 'ok' };
  }

  @Get('ready')
  async ready() {
    try {
      const query = {
        text: `SELECT to_regclass('public.private_message_push_queue') IS NOT NULL
          AND EXISTS (SELECT 1 FROM public.peru_districts) AS ready`,
        query_timeout: 2000,
      };
      const { rows } = await this.database.pool.query<{ ready: boolean }>(query);
      if (rows[0]?.ready) return { status: 'ok' };
    } catch {
      // La respuesta pública no incluye errores ni detalles de la conexión.
    }
    throw new ServiceUnavailableException('Base de datos no disponible.');
  }
}
