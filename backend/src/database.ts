import { Injectable, OnModuleDestroy } from '@nestjs/common';
import { Pool } from 'pg';

@Injectable()
export class Database implements OnModuleDestroy {
  readonly pool: Pool;

  constructor() {
    const connectionString = process.env.DATABASE_URL;
    if (!connectionString) throw new Error('Configura DATABASE_URL.');
    this.pool = new Pool({ connectionString, connectionTimeoutMillis: 5000 });
    this.pool.on('error', (error) => console.error('Conexión PostgreSQL inactiva:', error.message));
  }

  async onModuleDestroy() {
    await this.pool.end();
  }
}
