import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hackathon_utp_el_comercio/core/database/local_sqlite_database.dart';
import 'package:hackathon_utp_el_comercio/core/models/domain_models.dart';
import 'package:hackathon_utp_el_comercio/core/models/entity_id.dart';
import 'package:hackathon_utp_el_comercio/core/state/app_controller.dart';
import 'package:hackathon_utp_el_comercio/core/sync/azure_remote_gateway.dart';
import 'package:hackathon_utp_el_comercio/core/sync/entra_mobile_session.dart';
import 'package:hackathon_utp_el_comercio/core/sync/outbox_sync_service.dart';
import 'package:hackathon_utp_el_comercio/core/sync/supabase_remote_gateway.dart';
import 'package:http/http.dart' as http;

class _LostResponseGateway extends SupabaseRemoteGateway {
  _LostResponseGateway() : super(forceSupabaseAvailable: false);

  final attempts = <(String, String)>[];

  @override
  Future<ChatMessage> sendRealtimeMessage({
    required String id,
    required String clientMutationId,
    required String conversationId,
    String? recipientId,
    required String senderId,
    required String senderAlias,
    required String body,
  }) async {
    attempts.add((id, clientMutationId));
    if (attempts.length == 1) {
      throw http.ClientException('Se perdió la respuesta');
    }
    return super.sendRealtimeMessage(
      id: id,
      clientMutationId: clientMutationId,
      conversationId: conversationId,
      recipientId: recipientId,
      senderId: senderId,
      senderAlias: senderAlias,
      body: body,
    );
  }
}

class _GroupSession extends EntraMobileSession {
  _GroupSession(String owner) {
    profile = UserProfile.fromSqlMap({'id': owner, 'alias': 'Vecina'});
  }

  final sent = <(String, Map<String, Object?>)>[];

  @override
  bool get configured => true;

  @override
  Future<Map<String, Object?>> request(
    String method,
    String path, {
    Map<String, String> query = const {},
    Object? body,
    bool guest = false,
  }) async {
    expect(method, 'POST');
    expect(guest, isFalse);
    sent.add((path, body! as Map<String, Object?>));
    if (sent.length == 1) throw const AzureApiError(503);
    return {'id': sent.last.$2['id']};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'El reintento de un borrador privado usa los mismos identificadores',
    () async {
      final db = LocalSqliteDatabase(
        engine: InMemoryTransactionalStoreEngine(),
      );
      final gateway = _LostResponseGateway();
      final app = AppController(
        database: db,
        remoteGateway: gateway,
        outboxSyncService: OutboxSyncService(
          database: db,
          remoteGateway: gateway,
        ),
      );
      addTearDown(app.dispose);
      await app.initialize();
      final user = app.currentUser!;
      final service = app.publications.firstWhere(
        (p) => p.kind.isService && p.authorId != user.id,
      );
      final thread = await db.openOrGetConversation(
        id: EntityId.create(),
        clientMutationId: EntityId.create(),
        publication: service,
        participantId: user.id,
        participantAlias: user.alias,
      );
      Future<void> send() =>
          app.sendChatMessageInThread(thread: thread, text: 'Hola vecino');

      await expectLater(send(), throwsA(isA<http.ClientException>()));
      expect(
        await db.getDraft(ownerUserId: user.id, draftKey: 'chat_${thread.id}'),
        isNotNull,
      );
      await send();
      expect(gateway.attempts[0], gateway.attempts[1]);
      expect(
        await db.getDraft(ownerUserId: user.id, draftKey: 'chat_${thread.id}'),
        isNull,
      );
      await send();
      expect(gateway.attempts[2], isNot(gateway.attempts[1]));
      expect(
        await db.listMessagesForConversation(
          conversationId: thread.id,
          actingUserId: user.id,
        ),
        hasLength(2),
      );
    },
  );

  test('Azure reintenta la cola grupal con el mismo identificador', () async {
    final owner = EntityId.create();
    final group = EntityId.create();
    final messageId = EntityId.create();
    final mutation = EntityId.create();
    final now = DateTime.now();
    final session = _GroupSession(owner);
    final gateway = AzureRemoteGateway(session: session);
    final operation = OutboxOperation(
      operationId: messageId,
      entityId: messageId,
      entityType: 'emergency_group_message',
      ownerUserId: owner,
      action: 'insert',
      payloadJson: jsonEncode({
        'id': messageId,
        'publication_id': group,
        'client_mutation_id': mutation,
        'body': 'Estamos en casa',
      }),
      syncStatus: SyncStatus.pendiente,
      createdAt: now,
      updatedAt: now,
    );

    expect(
      (await gateway.pushOutboxOperation(operation)).status,
      SyncStatus.error,
    );
    expect(
      (await gateway.pushOutboxOperation(operation)).status,
      SyncStatus.confirmado,
    );
    expect(
      session.sent.map((entry) => entry.$1),
      List.filled(2, 'chats/groups/$group/messages'),
    );
    expect(
      session.sent.map((entry) => entry.$2['clientMutationId']),
      List.filled(2, mutation),
    );
  });
}
