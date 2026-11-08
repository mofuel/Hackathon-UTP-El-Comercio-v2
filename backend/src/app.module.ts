import { Module } from '@nestjs/common';
import { Chats, ChatsController } from './chats';
import { ChatRealtime } from './chat-realtime';
import { Database } from './database';
import { EntraIdentity } from './entra-identity';
import { ProfileController } from './profile.controller';
import { PublicationsController } from './publications.controller';
import { PublicationOperations } from './publication-operations';

@Module({
  controllers: [PublicationsController, ProfileController, ChatsController],
  providers: [Database, EntraIdentity, PublicationOperations, Chats, ChatRealtime],
})
export class AppModule {}
