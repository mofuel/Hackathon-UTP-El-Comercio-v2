import { Module } from '@nestjs/common';
import { Database } from './database';
import { PublicationsController } from './publications.controller';

@Module({
  controllers: [PublicationsController],
  providers: [Database],
})
export class AppModule {}
