import { Module } from '@nestjs/common';
import { Database } from './database';
import { EntraIdentity } from './entra-identity';
import { ProfileController } from './profile.controller';
import { PublicationsController } from './publications.controller';
import { PublicationOperations } from './publication-operations';

@Module({
  controllers: [PublicationsController, ProfileController],
  providers: [Database, EntraIdentity, PublicationOperations],
})
export class AppModule {}
