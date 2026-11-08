import { Module } from '@nestjs/common';
import { Database } from './database';
import { EntraIdentity } from './entra-identity';
import { ProfileController } from './profile.controller';
import { PublicationsController } from './publications.controller';

@Module({
  controllers: [PublicationsController, ProfileController],
  providers: [Database, EntraIdentity],
})
export class AppModule {}
