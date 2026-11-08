import 'dart:async';

import '../models/domain_models.dart';
import '../models/emergency_group_message.dart';
import '../notifications/push_notification_service.dart';
import 'azure_chat_signals.dart';
import 'entra_mobile_session.dart';
import 'supabase_remote_gateway.dart';

/// Conecta las publicaciones, los chats y los avisos con la API de Conecta2.
class AzureRemoteGateway extends SupabaseRemoteGateway {
  AzureRemoteGateway({EntraMobileSession? session})
    : _session = session ?? EntraMobileSession();

  final EntraMobileSession _session;
  late final _chatSignals = AzureChatSignals(_session);
  Future<void> _pushWrites = Future.value();
  bool _signingOut = false;
  static bool get requested => EntraMobileSession.apiUrl.isNotEmpty;
  static final _uuid = RegExp(
    r'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$',
    caseSensitive: false,
  );

  @override
  bool get isLiveSupabaseConnected => _session.configured;
  @override
  Stream<void> get signedInSessionChanges => const Stream.empty();
  @override
  Stream<void> get passwordRecoveryChanges => const Stream.empty();
  @override
  bool get hasPasswordRecoverySession => false;

  Future<UserProfile> signInHosted(String alias) => _session.signIn(alias);

  @override
  Future<UserProfile> signInAccount({
    required String email,
    required String password,
  }) => signInHosted('');

  @override
  Future<UserProfile> registerAccount({
    required String email,
    required String password,
    required String alias,
    required String neighborhood,
    required String sector,
    required double? approxLat,
    required double? approxLng,
    required bool useGpsApprox,
    String? districtUbigeo,
  }) => signInHosted(alias);

  @override
  Future<void> requestPasswordReset(String email) async =>
      throw StateError('Usa «Olvidé mi contraseña» en el acceso seguro.');
  @override
  Future<void> updateRecoveredPassword(String password) async =>
      throw StateError('Completa la recuperación en el acceso seguro.');

  @override
  Future<UserProfile?> getCurrentSessionProfile() async {
    final profile = await _session.restore();
    lastProfileFetchWasOffline = _session.offlineProfile;
    return profile;
  }

  @override
  Future<void> signOutAccount() async {
    _signingOut = true;
    _chatSignals.reset();
    try {
      await _pushWrites;
      final owner = _session.profile?.id;
      if (owner != null && await _session.readPushOwner() == owner) {
        try {
          await _updatePrivateMessagePush(
            owner,
            null,
          ).timeout(const Duration(seconds: 4));
        } catch (_) {
          if (await PushNotificationService.instance.unregisterInstallation()) {
            await _session.setPushOwner(null);
          }
        }
      }
    } catch (_) {
      // El cierre local debe continuar incluso cuando el teléfono está sin red.
    } finally {
      try {
        await _session.signOut();
      } finally {
        _signingOut = false;
      }
    }
  }

  @override
  Future<RemoteSyncResult> pushOutboxOperation(
    OutboxOperation operation,
  ) async {
    const pending = RemoteSyncResult(
      status: SyncStatus.pendiente,
      errorMessage: 'El cambio sigue guardado en este teléfono y aún no se ha comunicado.',
    );
    if (!isLiveSupabaseConnected || simulateNetworkOffline) return pending;
    if (!const {
      'publication',
      'publication_edit',
      'publication_delete',
      'publication_location',
      'publication_status',
      'recommendation',
      'help_offer',
      'profile',
      'conversation',
      'emergency_group_message',
    }.contains(operation.entityType)) {
      return pending;
    }
    final guest = operation.ownerUserId == Publication.guestOwnerId;
    if (!guest && _session.profile?.id != operation.ownerUserId) return pending;

    try {
      if (operation.entityType == 'conversation' ||
          operation.entityType == 'emergency_group_message') {
        final payload = operation.decodePayload();
        if (guest) return pending;
        if (operation.entityType == 'conversation') {
          await ensureNeighborConversation(
            id: payload['id'] as String,
            mutationId: payload['client_mutation_id'] as String,
            publicationId: payload['publication_id'] as String,
          );
        } else {
          final publication = Uri.encodeComponent(
            payload['publication_id'] as String,
          );
          await _session.request(
            'POST',
            'chats/groups/$publication/messages',
            body: {
              'id': payload['id'],
              'clientMutationId': payload['client_mutation_id'],
              'body': payload['body'],
            },
          );
        }
        return const RemoteSyncResult(status: SyncStatus.confirmado);
      }
      final result = await _session.request(
        'POST',
        'publications/operations',
        guest: guest,
        body: {
          'operationId': operation.operationId,
          'ownerUserId': operation.ownerUserId,
          'entityType': operation.entityType,
          'entityId': operation.entityId,
          'action': operation.action,
          'expectedVersion': operation.expectedVersion,
          'payload': operation.decodePayload(),
        },
      );
      return RemoteSyncResult(
        status: SyncStatus.confirmado,
        confirmedVersion: result['version'] as int?,
      );
    } on AzureApiError catch (error) {
      if (error.status == 429) return pending;
      if (error.status == 409) {
        return const RemoteSyncResult(
          status: SyncStatus.conflicto,
          errorMessage: 'El aviso o la acción cambió. Revísalo antes de volver a enviarlo.',
        );
      }
      return const RemoteSyncResult(
        status: SyncStatus.error,
        errorMessage:
            'El servidor no confirmó el cambio. Tus datos siguen guardados.',
      );
    }
  }

  static List<Map<String, Object?>> _rows(Object? value) => (value as List)
      .map((row) => Map<String, Object?>.from(row as Map))
      .toList();

  Future<List<Publication>> _publications(
    String endpoint, [
    Map<String, String> query = const {},
  ]) async {
    final result = await _session.request(
      'GET',
      'publications/$endpoint',
      query: query,
    );
    return _rows(result['publications']).map(Publication.fromSqlMap).toList();
  }

  @override
  Future<List<Publication>> fetchFeedPage({
    String? districtUbigeo,
    DateTime? beforeTime,
    String? beforeId,
    int limit = 30,
  }) => _publications('feed', {
    'district': ?districtUbigeo,
    if (beforeTime != null && beforeId != null) ...{
      'beforeTime': beforeTime.toUtc().toIso8601String(),
      'beforeId': beforeId,
    },
    'limit': '$limit',
  });

  @override
  Future<List<Publication>> fetchPublicationsWithinRadius({
    required double? originLat,
    required double? originLng,
    required int radiusMeters,
    String? districtUbigeo,
    PublicationKind? kind,
    String? category,
    String? searchText,
    int? maxResults,
  }) async {
    if (originLat == null && districtUbigeo == null) return const [];
    return _publications('search', {
      if (originLat != null && originLng != null) ...{
        'lat': '$originLat',
        'lng': '$originLng',
      },
      'district': ?districtUbigeo,
      'kind': ?kind?.dbValue,
      'category': ?category,
      'search': ?searchText,
      'radiusMeters': '${radiusMeters.clamp(100, 20000)}',
      'limit': '${maxResults ?? 1000}',
    });
  }

  Future<List<Map<String, Object?>>> _changes(
    Iterable<String> input,
    String key,
  ) async {
    final ids = input.where(_uuid.hasMatch).toList();
    final result = <Map<String, Object?>>[];
    for (var i = 0; i < ids.length; i += 100) {
      final response = await _session.request(
        'POST',
        'publications/changes',
        body: {'ids': ids.skip(i).take(100).toList()},
      );
      result.addAll(_rows(response[key]));
    }
    return result;
  }

  @override
  Future<List<Publication>> fetchCachedPublicationUpdates(
    List<Publication> cached,
  ) async {
    final versions = {
      for (final publication in cached) publication.id: publication.version,
    };
    final rows = await _changes(versions.keys, 'publications');
    return rows
        .map(Publication.fromSqlMap)
        .where((row) => row.version > versions[row.id]!)
        .toList();
  }

  @override
  Future<List<Map<String, Object?>>> fetchPublicationTombstones(
    List<String> ids,
  ) => _changes(ids, 'tombstones');

  @override
  Future<List<Publication>> fetchOwnMapPublications() => _publications('mine');

  @override
  Future<Publication> fetchOwnPublication(String id) async =>
      Publication.fromSqlMap(
        await _session.request(
          'GET',
          'publications/mine/${Uri.encodeComponent(id)}',
        ),
      );

  @override
  Future<List<CommunityResource>> fetchMapResources({
    required double originLat,
    required double originLng,
    int radiusMeters = 20000,
    int maxResults = 201,
  }) async {
    final result = await _session.request(
      'GET',
      'publications/resources',
      query: {
        'lat': '$originLat',
        'lng': '$originLng',
        'radiusMeters': '$radiusMeters',
        'limit': '$maxResults',
      },
    );
    return _rows(result['resources'])
        .map(CommunityResource.fromSqlMap)
        .toList();
  }

  @override
  Future<Map<String, List<Map<String, Object?>>>>
  fetchCommunitySnapshot() async {
    final result = await _session.request('GET', 'publications/community');
    return {
      for (final key in [
        'recommendations',
        'help_offers',
        'community_resources',
        'support_groups',
      ])
        key: _rows(result[key]),
    };
  }

  @override
  Future<List<Map<String, Object?>>> fetchConversationList() async =>
      _rows((await _session.request('GET', 'chats/threads'))['conversations']);

  @override
  Future<Map<String, DateTime>> fetchChatActivity(List<String> groups) async {
    final ids = groups.where(_uuid.hasMatch).toList();
    final result = <String, DateTime>{};
    for (var i = 0; i < ids.length || i == 0; i += 100) {
      final response = await _session.request(
        'POST',
        'chats/activity',
        body: {'groups': ids.skip(i).take(100).toList()},
      );
      final activity = Map<String, String>.from(response['activity'] as Map);
      result.addAll(
        activity.map((key, value) => MapEntry(key, DateTime.parse(value))),
      );
    }
    return result;
  }

  @override
  Stream<void> watchChatActivity() => _chatSignals.events.map((_) {});

  @override
  Future<bool> privateMessagePushEnabled() async {
    final device = await _session.pushDeviceId();
    final response = await _session.request('GET', 'chats/push/$device');
    return response['enabled'] == true;
  }

  @override
  Future<void> setPrivateMessagePush(String userId, String? installationId) {
    if (_signingOut) throw StateError('La sesión cambió.');
    final write = _pushWrites.then(
      (_) => _updatePrivateMessagePush(userId, installationId),
    );
    _pushWrites = write.then((_) {}, onError: (Object _) {});
    return write;
  }

  Future<void> _updatePrivateMessagePush(
    String userId,
    String? installationId,
  ) async {
    if (_session.profile?.id != userId) throw StateError('La sesión cambió.');
    final device = await _session.pushDeviceId();
    if (_session.profile?.id != userId) throw StateError('La sesión cambió.');
    if (installationId != null) await _session.setPushOwner(userId);
    await _session.request(
      installationId == null ? 'DELETE' : 'PUT',
      'chats/push/$device',
      body: installationId == null ? null : {'installationId': installationId},
    );
    if (installationId == null) await _session.setPushOwner(null);
  }

  @override
  Future<ConversationThread?> fetchPrivateConversation(
    String conversationId,
  ) async {
    try {
      return ConversationThread.fromSqlMap(
        await _session.request(
          'GET',
          'chats/threads/${Uri.encodeComponent(conversationId)}',
        ),
      );
    } on AzureApiError catch (error) {
      if (error.status == 404) return null;
      rethrow;
    }
  }

  @override
  Future<List<EmergencyGroupMessage>> fetchEmergencyGroupMessages(
    String publicationId, {
    DateTime? beforeTime,
    String? beforeId,
  }) async {
    final response = await _session.request(
      'GET',
      'chats/groups/${Uri.encodeComponent(publicationId)}/messages',
      query: _page(beforeTime, beforeId),
    );
    return _rows(response['messages'])
        .map(EmergencyGroupMessage.fromMap)
        .toList();
  }

  Map<String, String> _page(DateTime? time, String? id) => {
    if (time != null && id != null) ...{
      'beforeTime': time.toUtc().toIso8601String(),
      'beforeId': id,
    },
  };

  @override
  Stream<void> watchEmergencyGroup(String publicationId) => _chatSignals.events
      .where((event) => event != 'private_changed')
      .map((_) {});

  @override
  Stream<ChatMessage> watchConversationMessages(
    String conversationId, {
    String? peerId,
  }) {
    final owner = _session.profile?.id;
    if (owner == null) return const Stream.empty();
    late StreamController<ChatMessage> output;
    StreamSubscription<String>? signals;
    Timer? timer;
    final seen = <String>{};
    var busy = false, cancelled = false;
    bool active() => !cancelled && _session.profile?.id == owner;

    Future<void> refresh() async {
      if (!active() || busy || simulateNetworkOffline) return;
      busy = true;
      try {
        DateTime? before;
        String? beforeId;
        while (active()) {
          final response = await _session.request(
            'GET',
            'chats/threads/${Uri.encodeComponent(conversationId)}/messages',
            query: {..._page(before, beforeId), 'peerId': ?peerId},
          );
          if (!active()) return;
          final rows = _rows(response['messages']);
          var foundSeen = false;
          for (final row in rows) {
            if (!seen.add(row['id'] as String)) {
              foundSeen = true;
            } else {
              output.add(
                ChatMessage.fromSqlMap({
                  ...row,
                  'conversation_id': conversationId,
                }),
              );
            }
          }
          if (rows.length < 100 || foundSeen) break;
          before = DateTime.parse(rows.last['created_at'] as String);
          beforeId = rows.last['id'] as String;
        }
      } catch (error) {
        if (active()) output.addError(error);
      } finally {
        busy = false;
      }
    }

    output = StreamController<ChatMessage>(
      onListen: () {
        signals = _chatSignals.events
            .where((event) => event != 'groups_changed')
            .listen((_) => unawaited(refresh()));
        timer = Timer.periodic(
          const Duration(seconds: 10),
          (_) => unawaited(refresh()),
        );
        unawaited(refresh());
      },
      onCancel: () async {
        cancelled = true;
        timer?.cancel();
        await signals?.cancel();
      },
    );
    return output.stream;
  }

  @override
  Future<void> ensureNeighborConversation({
    required String id,
    required String mutationId,
    required String publicationId,
  }) async {
    await _session.request(
      'POST',
      'chats/threads',
      body: {
        'id': id,
        'clientMutationId': mutationId,
        'publicationId': publicationId,
      },
    );
  }

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
    if (simulateNetworkOffline || _session.profile?.id != senderId) {
      throw StateError('El mensaje sigue guardado como borrador.');
    }
    final response = await _session.request(
      'POST',
      'chats/threads/${Uri.encodeComponent(conversationId)}/messages',
      body: {
        'id': id,
        'clientMutationId': clientMutationId,
        'recipientId': recipientId,
        'body': body,
      },
    );
    return ChatMessage.fromSqlMap({
      ...response,
      'conversation_id': conversationId,
    });
  }
}
