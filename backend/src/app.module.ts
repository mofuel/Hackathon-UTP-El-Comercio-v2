import { Module } from '@nestjs/common';
import { Chats, ChatsController } from './chats';
import { ChatRealtime } from './chat-realtime';
import { Database } from './database';
import { EntraIdentity } from './entra-identity';
import { HealthController } from './health.controller';
import { ProfileController } from './profile.controller';
import { PublicationsController } from './publications.controller';
import { PublicationOperations } from './publication-operations';
import { FcmTransport, PrivatePushController, PrivatePushWorker } from './private-message-push';

@Module({
  controllers: [PublicationsController, ProfileController, ChatsController, PrivatePushController, HealthController],
  providers: [Database, EntraIdentity, PublicationOperations, Chats, ChatRealtime, FcmTransport, PrivatePushWorker],
})
export class AppModule {}
