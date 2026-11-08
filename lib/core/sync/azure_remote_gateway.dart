import '../models/domain_models.dart';
import '../models/emergency_group_message.dart';
import 'entra_mobile_session.dart';
import 'supabase_remote_gateway.dart';

/// Adapter for the publication flows while the chat migration is still pending.
class AzureRemoteGateway extends SupabaseRemoteGateway {
  AzureRemoteGateway({EntraMobileSession? session})
    : _session = session ?? EntraMobileSession();

  final EntraMobileSession _session;
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
  Future<void> signOutAccount() => _session.signOut();

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
    }.contains(operation.entityType)) {
      return pending;
    }
    final guest = operation.ownerUserId == Publication.guestOwnerId;
    if (!guest && _session.profile?.id != operation.ownerUserId) return pending;

    try {
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
  Future<List<Map<String, Object?>>> fetchConversationList() async => const [];
  @override
  Future<Map<String, DateTime>> fetchChatActivity(List<String> groups) async =>
      const {};
  @override
  Stream<void> watchChatActivity() => const Stream.empty();
  @override
  Future<bool> privateMessagePushEnabled() async => false;
  @override
  Future<void> setPrivateMessagePush(
    String userId,
    String? installationId,
  ) async => _chatUnavailable();
  @override
  Future<ConversationThread?> fetchPrivateConversation(
    String conversationId,
  ) async => null;
  @override
  Future<List<EmergencyGroupMessage>> fetchEmergencyGroupMessages(
    String publicationId, {
    DateTime? beforeTime,
    String? beforeId,
  }) async => const [];
  @override
  Stream<void> watchEmergencyGroup(String publicationId) =>
      const Stream.empty();
  @override
  Stream<ChatMessage> watchConversationMessages(
    String conversationId, {
    String? peerId,
  }) => const Stream.empty();
  @override
  Future<void> ensureNeighborConversation({
    required String id,
    required String mutationId,
    required String publicationId,
  }) async => _chatUnavailable();
  @override
  Future<ChatMessage> sendRealtimeMessage({
    required String id,
    required String clientMutationId,
    required String conversationId,
    String? recipientId,
    required String senderId,
    required String senderAlias,
    required String body,
  }) async => _chatUnavailable();

  Never _chatUnavailable() => throw StateError(
    'Los chats de Azure estarán disponibles en la siguiente etapa.',
  );
}
