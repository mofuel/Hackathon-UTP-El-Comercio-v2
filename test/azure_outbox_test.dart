import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hackathon_utp_el_comercio/core/database/local_sqlite_database.dart';
import 'package:hackathon_utp_el_comercio/core/models/domain_models.dart';
import 'package:hackathon_utp_el_comercio/core/models/entity_id.dart';
import 'package:hackathon_utp_el_comercio/core/sync/azure_remote_gateway.dart';
import 'package:hackathon_utp_el_comercio/core/sync/entra_mobile_session.dart';
import 'package:hackathon_utp_el_comercio/core/sync/outbox_sync_service.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;

class _TestSession extends EntraMobileSession {
  _TestSession(String account, this.sent, this.received) {
    profile = UserProfile.fromSqlMap({'id': account, 'alias': 'Vecino'});
  }

  final List<Map<String, Object?>> sent;
  final Map<String, Map<String, Object?>> received;

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
    if (path == 'publications/feed') {
      return {'publications': received.values.toList()};
    }
    expect(path, 'publications/operations');
    final operation = body! as Map<String, Object?>;
    sent.add(operation);
    final key = operation['operationId']! as String;
    if (!received.containsKey(key)) {
      received[key] = {
        ...operation['payload']! as Map<String, Object?>,
        'sync_status': 'confirmado',
      };
      throw http.ClientException('Se perdió la respuesta del primer envío');
    }
    return {'version': 1};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'SQLite conserva el identificador al reconectar y reintentar en Azure',
    () async {
      ffi.sqfliteFfiInit();
      ffi.databaseFactory = ffi.databaseFactoryFfi;
      final dir = await Directory.systemTemp.createTemp('conecta2-azure-');
      final file = '${dir.path}${Platform.pathSeparator}test.db';
      var engine = SqfliteStoreEngine(databaseFileName: file);
      addTearDown(() async {
        await engine.close();
        await dir.delete(recursive: true);
      });
      var database = LocalSqliteDatabase(engine: engine);
      await database.initAndSeedDemoData(seedDemo: false);
      final account = EntityId.create();
      final publication = Publication.fromSqlMap({
        'id': EntityId.create(),
        'client_mutation_id': EntityId.create(),
        'owner_user_id': account,
        'author_id': account,
        'kind': 'anuncio',
        'category': 'producto',
        'title': 'Pan del barrio',
        'description': 'A S/ 2',
        'district_ubigeo': '150101',
      });
      await database.createOrUpdatePublicationTransactional(publication);

      await engine.close();
      engine = SqfliteStoreEngine(databaseFileName: file);
      database = LocalSqliteDatabase(engine: engine);
      await database.initAndSeedDemoData(seedDemo: false);
      final sent = <Map<String, Object?>>[];
      final received = <String, Map<String, Object?>>{};
      final author = AzureRemoteGateway(
        session: _TestSession(account, sent, received),
      );
      final neighbor = AzureRemoteGateway(
        session: _TestSession(EntityId.create(), sent, received),
      );
      final outbox = OutboxSyncService(
        database: database,
        remoteGateway: author,
      );
      outbox.networkAvailable = false;
      expect((await outbox.syncPendingForUser(account)).pendingCount, 1);
      expect(sent, isEmpty);

      outbox.networkAvailable = true;
      expect((await outbox.syncPendingForUser(account)).errorCount, 1);
      expect((await outbox.syncPendingForUser(account)).confirmedCount, 1);
      expect(await database.listOutboxForUser(account), isEmpty);
      expect(sent.map((operation) => operation['operationId']), [
        publication.clientMutationId,
        publication.clientMutationId,
      ]);
      expect(
        (await neighbor.fetchFeedPage(districtUbigeo: '150101')).single.id,
        publication.id,
      );
    },
  );
}
