import { WebPubSubServiceClient } from '@azure/web-pubsub';
import { Injectable, Logger } from '@nestjs/common';

@Injectable()
export class ChatRealtime {
  private readonly logger = new Logger(ChatRealtime.name);
  private readonly client = process.env.WEB_PUBSUB_CONNECTION_STRING
    ? new WebPubSubServiceClient(process.env.WEB_PUBSUB_CONNECTION_STRING, process.env.WEB_PUBSUB_HUB || 'conecta2-chat')
    : null;

  async negotiate(actor: string, district: string | null) {
    if (!this.client) return { url: null };
    const { url } = await this.client.getClientAccessToken({
      userId: actor,
      roles: [],
      groups: district ? [`district-${district}`] : [],
      expirationTimeInMinutes: 5,
    });
    return { url };
  }

  async privateChanged(users: string[]) {
    const client = this.client;
    if (!client) return;
    const event = { type: 'private_changed' };
    await this.deliver(users.map((user) => client.sendToUser(user, event, {
      abortSignal: AbortSignal.timeout(3000),
    })));
  }

  async groupChanged(district: string | null, author: string | null) {
    const client = this.client;
    if (!client) return;
    const event = { type: 'groups_changed' };
    // Las señales no incluyen texto, identificadores de grupos ni datos vecinales.
    await this.deliver([
      ...(district ? [client.group(`district-${district}`).sendToAll(event, {
        abortSignal: AbortSignal.timeout(3000),
      })] : []),
      ...(author ? [client.sendToUser(author, event, { abortSignal: AbortSignal.timeout(3000) })] : []),
    ]);
  }

  private async deliver(sends: Promise<unknown>[]) {
    const results = await Promise.allSettled(sends);
    if (results.some((result) => result.status === 'rejected')) {
      this.logger.warn('Una señal de chat no llegó a Web PubSub. El cliente puede actualizar por HTTP.');
    }
  }
}
