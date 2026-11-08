import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import '../config/app_config.dart';
import '../geography/peru_location_catalog.dart';
import '../maps/chosen_map_location.dart';
import '../maps/carto_basemap.dart';
import '../models/entity_id.dart';
import '../models/emergency_group_message.dart';
import '../database/local_sqlite_database.dart';
import '../models/domain_models.dart';
import '../sync/azure_remote_gateway.dart';
import '../sync/outbox_sync_service.dart';
import '../sync/supabase_remote_gateway.dart';

/// Intención conservada cuando un vecino sin sesión activa intenta realizar una
/// acción que requiere autenticación, para retomarla inmediatamente al ingresar.
class PendingAuthIntent {
  const PendingAuthIntent({
    required this.description,
    required this.targetRoute,
    this.publicationId,
    this.presetKind,
    this.lockType = false,
  });

  final String description;
  final String targetRoute;
  final String? publicationId;
  final PublicationKind? presetKind;
  final bool lockType;
}

/// Rutas principales de primer nivel accesibles desde Inicio en 1 clic.
enum AppSection {
  inicio,
  publicarRapido,
  servicios,
  detalleServicio,
  favores,
  detalleFavor,
  emergencias,
  explorarMapa,
  chatLista,
  chatConversacion,
  chatEmergencia,
  misActividades,
  autenticacion,
  practicaSimulacro,
}

/// Controlador central de estado de la aplicación comunitaria Conecta2.
class AppController extends ChangeNotifier with WidgetsBindingObserver {
  Timer? _syncTimer;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  bool _networkUnavailable = false;
  bool feedLoading = false, feedHasMore = true;
  DateTime? _feedBeforeTime;
  String? _feedBeforeId;
  String? _feedHeadId;
  String _feedScope = '';
  bool _cachingFeed = false;
  bool _appForeground = true;
  String get _currentFeedScope => '${currentUser?.id}:$activeDistrictUbigeo';
  void _resetFeedScope() {
    if (_feedScope == _currentFeedScope) return;
    _feedScope = _currentFeedScope;
    _feedHeadId = null;
    _feedBeforeTime = null;
    _feedBeforeId = null;
    feedHasMore = true;
  }

  List<Publication> get neighborhoodFeed => !isAuthenticated
      ? const []
      : (publications.where((p) => !p.isDeleted).toList()..sort((a, b) {
          final order = b.createdAt.compareTo(a.createdAt);
          return order == 0 ? b.id.compareTo(a.id) : order;
        }));

  StreamSubscription<void>? _authSubscription;
  StreamSubscription<void>? _recoverySubscription;
  bool _passwordRecoveryPending = false;
  bool get passwordRecoveryPending => _passwordRecoveryPending;
  bool _authActionInProgress = false;
  bool _restoringAuthSession = false;
  int _authEpoch = 0;
  bool _refreshingRemote = false;
  bool _disposed = false;
  AppController({
    required this.database,
    required this.remoteGateway,
    required this.outboxSyncService,
  });

  final LocalSqliteDatabase database;
  final SupabaseRemoteGateway remoteGateway;
  bool get usesAzureBackend => remoteGateway is AzureRemoteGateway;
  final OutboxSyncService outboxSyncService;

  late final PeruLocationCatalog locationCatalog;
  String? _selectedManualUbigeo;
  bool _selectedManualUsesGps = false;
  bool get activeUsesGps =>
      _currentUser?.useGpsApprox ?? _selectedManualUsesGps;
  String? get activeDistrictUbigeo => _currentUser != null
      ? _currentUser!.districtUbigeo
      : _selectedManualUbigeo;

  String get activeAdministrativeLocationLabel {
    final district = locationCatalog.district(activeDistrictUbigeo);
    if (district == null) return activeNeighborhood;
    return '${district.name}, ${locationCatalog.entry(district.provinceCode)!.name}, ${locationCatalog.entry(district.departmentCode)!.name}';
  }

  bool _initialized = false;
  bool get initialized => _initialized;

  UserProfile? _currentUser;
  UserProfile? get currentUser => _currentUser;
  bool get isAuthenticated => _currentUser != null;

  String get activeNeighborhood =>
      _currentUser?.neighborhood ?? _selectedManualNeighborhood;
  String get activeSector => _currentUser?.sector ?? _selectedManualSector;
  double? get activeLat =>
      _currentUser != null ? _currentUser!.approxLat : _selectedManualLat;
  double? get activeLng =>
      _currentUser != null ? _currentUser!.approxLng : _selectedManualLng;

  String _selectedManualNeighborhood = AppConfig.defaultNeighborhood;
  String _selectedManualSector = AppConfig.defaultSector;
  double? _selectedManualLat = AppConfig.defaultLat;
  double? _selectedManualLng = AppConfig.defaultLng;

  AppSection _currentSection = AppSection.inicio;
  AppSection get currentSection => _currentSection;

  final List<AppSection> _navigationStack = <AppSection>[AppSection.inicio];

  /// Estado del flujo de publicación rápida (2 clics para emergencia / pedir ayuda,
  /// 3 clics para publicar servicio o favor general).
  PublicationKind _publishPresetKind = PublicationKind.favorSolicitud;
  PublicationKind get publishPresetKind => _publishPresetKind;

  bool _publishTypeLocked = false;
  bool get publishTypeLocked => _publishTypeLocked;

  Publication? _lastSubmittedPublication;
  Publication? get lastSubmittedPublication => _lastSubmittedPublication;

  /// Filtros del directorio de servicios
  List<Publication> _directoryPublications = const [];
  static const _directoryRangeMeters = 20000;

  double? get directoryLat =>
      activeLat ?? locationCatalog.district(activeDistrictUbigeo)?.capitalLat;
  double? get directoryLng =>
      activeLng ?? locationCatalog.district(activeDistrictUbigeo)?.capitalLng;

  String _serviceSearchQuery = '';
  String get serviceSearchQuery => _serviceSearchQuery;

  String _serviceCategoryFilter = 'todos';
  String get serviceCategoryFilter => _serviceCategoryFilter;

  double? _serviceRadiusMeters;
  double? get serviceRadiusMeters => _serviceRadiusMeters;

  bool _serviceMapQuadrantView = false;
  bool get serviceMapQuadrantView => _serviceMapQuadrantView;

  /// Filtros de favores solidarios
  String _favorCategoryFilter = 'todos';
  String get favorCategoryFilter => _favorCategoryFilter;

  PublicationStatus? _favorStatusFilter;
  PublicationStatus? get favorStatusFilter => _favorStatusFilter;

  /// Selección de detalle y conversación
  Publication? _selectedPublication;
  Publication? get selectedPublication => _selectedPublication;

  Publication? _selectedEmergencyGroup;
  Publication? get selectedEmergencyGroup => _publications
      .where((p) => p.id == _selectedEmergencyGroup?.id)
      .firstOrNull;
  Set<String> _visitedEmergencyGroups = {};
  List<Publication> get emergencyGroupChats => publications
      .where(
        (p) =>
            _visitedEmergencyGroups.contains(p.id) &&
            !_hiddenChats.contains('group:${p.id}') &&
            canViewEmergencyGroup(p),
      )
      .toList();
  bool canViewEmergencyGroup(Publication publication) {
    final p = publications.where((p) => p.id == publication.id).firstOrNull;
    return currentUser != null &&
        p != null &&
        p.kind.isEmergency &&
        !p.isDeleted &&
        (p.authorId == currentUser!.id ||
            (p.districtUbigeo != null &&
                p.districtUbigeo == currentUser!.districtUbigeo));
  }

  ConversationThread? _selectedConversation;
  ConversationThread? get selectedConversation => _selectedConversation;

  PendingAuthIntent? _pendingAuthIntent;
  PendingAuthIntent? get pendingAuthIntent => _pendingAuthIntent;

  bool _showOnboardingTutorial = false;
  bool get showOnboardingTutorial => _showOnboardingTutorial;

  String? _statusBannerMessage;
  String? get statusBannerMessage => _statusBannerMessage;

  List<Publication> _publications = const [];
  List<Publication> get publications => _publications;

  List<CommunityResource> _communityResources = const [];
  List<CommunityResource> get communityResources => _communityResources;

  List<SupportGroup> _supportGroups = const [];
  List<SupportGroup> get supportGroups => _supportGroups;

  List<OutboxOperation> _userOutbox = const [];
  List<OutboxOperation> get userOutbox => _userOutbox;

  List<FormDraft> _userDrafts = const [];
  List<FormDraft> get userDrafts => _userDrafts;

  List<ConversationThread> _userConversations = const [];
  String chatKeyFor(ConversationThread thread) =>
      'neighbor:${thread.peerIdFor(currentUser!.id)}';
  String _normalizeChatKey(String key) {
    final thread = _userConversations
        .where((t) => 'private:${t.id}' == key)
        .firstOrNull;
    return thread == null ? key : chatKeyFor(thread);
  }

  List<ConversationThread> get userConversations {
    if (currentUser == null) return const [];
    final peers = <String, ConversationThread>{};
    for (final thread in _userConversations) {
      final key = chatKeyFor(thread), old = peers[key];
      if (old == null || thread.id.compareTo(old.id) < 0) peers[key] = thread;
    }
    return peers.entries
        .where((e) => !_hiddenChats.contains(e.key))
        .map((e) => e.value)
        .toList();
  }

  Set<String> _pinnedChats = {}, _hiddenChats = {};
  Map<String, DateTime> _chatActivity = {};
  DateTime chatLastActivity(String key, DateTime fallback) {
    key = _normalizeChatKey(key);
    for (final thread in _userConversations) {
      if (chatKeyFor(thread) == key && thread.updatedAt.isAfter(fallback)) {
        fallback = thread.updatedAt;
      }
    }
    final date = _chatActivity[key];
    return date != null && date.isAfter(fallback) ? date : fallback;
  }

  bool isChatPinned(String key) =>
      _pinnedChats.contains(_normalizeChatKey(key));
  bool _canOrganizeChat(String key) =>
      currentUser != null &&
      (_userConversations.any((t) => key == chatKeyFor(t)) ||
          publications.any(
            (p) =>
                key == 'group:${p.id}' &&
                _visitedEmergencyGroups.contains(p.id) &&
                canViewEmergencyGroup(p),
          ));

  Future<void> setChatPinned(String chatKey, bool pinned) async {
    chatKey = _normalizeChatKey(chatKey);
    if (!_canOrganizeChat(chatKey)) {
      throw StateError('Selecciona un chat de tu cuenta.');
    }
    final owner = currentUser!.id;
    await database.saveChatPreference(
      owner: owner,
      chatKey: chatKey,
      pinned: pinned,
    );
    if (currentUser?.id == owner) await refreshAllLocalData();
  }

  Future<void> restoreChat(String chatKey, {bool pinned = false}) async {
    chatKey = _normalizeChatKey(chatKey);
    if (!_canOrganizeChat(chatKey)) return;
    final owner = currentUser!.id;
    await database.saveChatPreference(
      owner: owner,
      chatKey: chatKey,
      hidden: false,
      pinned: pinned,
    );
    if (currentUser?.id == owner) await refreshAllLocalData();
  }

  Future<void> hideChat(String chatKey) async {
    chatKey = _normalizeChatKey(chatKey);
    if (!_canOrganizeChat(chatKey)) {
      throw StateError('Selecciona un chat de tu cuenta.');
    }
    final owner = currentUser!.id;
    await database.saveChatPreference(
      owner: owner,
      chatKey: chatKey,
      hidden: true,
    );
    if (currentUser?.id == owner) await refreshAllLocalData();
  }

  bool _refreshingChatActivity = false;
  Future<void> refreshChatActivity() async {
    final owner = currentUser?.id;
    if (owner == null ||
        _disposed ||
        isOfflineMode ||
        _refreshingChatActivity ||
        !remoteGateway.isLiveSupabaseConnected) {
      return;
    }
    _refreshingChatActivity = true;
    try {
      final activity = await remoteGateway
          .fetchChatActivity(_visitedEmergencyGroups.toList())
          .timeout(const Duration(seconds: 15));
      if (_disposed || currentUser?.id != owner) return;
      final known = {
        for (final thread in _userConversations) chatKeyFor(thread),
      };
      if (activity.keys.any(
        (key) => key.startsWith('neighbor:') && !known.contains(key),
      )) {
        final rows = await remoteGateway.fetchConversationList().timeout(
          const Duration(seconds: 15),
        );
        if (_disposed || currentUser?.id != owner) return;
        await database.mergeCommunitySnapshot({'conversations': rows});
      }
      await database.mergeChatActivity(owner, activity);
      await refreshAllLocalData();
    } finally {
      _refreshingChatActivity = false;
    }
  }

  DateTime? _lastSyncTimestamp;
  DateTime? get lastSyncTimestamp => _lastSyncTimestamp;

  bool get isOfflineMode =>
      _networkUnavailable ||
      remoteGateway.simulateNetworkOffline ||
      (!remoteGateway.isLiveSupabaseConnected && !remoteGateway.isTestDouble);

  /// Inicializa SQLite, semilla comunitaria de Pueblo Libre y sesión activa.
  Future<void> initialize({bool startWithActiveSession = true}) async {
    locationCatalog = await PeruLocationCatalog.load();
    await database.initAndSeedDemoData(seedDemo: remoteGateway.isTestDouble);
    final manual = await database.readManualLocation();
    if (manual != null) {
      _selectedManualUbigeo = manual['district_ubigeo'] as String?;
      _selectedManualUsesGps = manual['use_gps_approx'] == 1;
      _selectedManualNeighborhood = manual['neighborhood'] as String;
      _selectedManualSector = manual['sector'] as String;
      _selectedManualLat = (manual['approx_lat'] as num?)?.toDouble();
      _selectedManualLng = (manual['approx_lng'] as num?)?.toDouble();
    }

    if (startWithActiveSession) {
      final sessionProfile = await remoteGateway.getCurrentSessionProfile();
      if (sessionProfile != null) {
        _currentUser = await _preferPendingLocalProfile(sessionProfile);
      } else if (remoteGateway.isTestDouble) {
        // Sesión vecinal por defecto para permitir verificación inmediata del
        // presupuesto de <= 3 clics desde Inicio (puede cerrarse o cambiarse).
        final defaultProfile = await remoteGateway.signInAccount(
          email: 'maria@pueblolibre.pe',
          password: 'vecinos-pueblo-libre',
        );
        _currentUser = defaultProfile;
      }
      if (_currentUser != null) {
        await database.saveUserProfile(_currentUser!, queueSync: false);
      }
    }

    await refreshAllLocalData();
    _initialized = true;
    _authSubscription = remoteGateway.signedInSessionChanges.listen(
      (_) {
        if (!_authActionInProgress) unawaited(_restoreSessionFromLink());
      },
      onError: (Object error) {
        if (_disposed) return;
        _statusBannerMessage =
            'No se pudo completar la confirmación. Vuelve a iniciar sesión.';
        notifyListeners();
      },
    );
    _recoverySubscription = remoteGateway.passwordRecoveryChanges.listen(
      (_) {
        if (_disposed || !remoteGateway.hasPasswordRecoverySession) return;
        _authEpoch++;
        _passwordRecoveryPending = true;
        _currentUser = null;
        _selectedConversation = null;
        _selectedEmergencyGroup = null;
        _selectedPublication = null;
        notifyListeners();
      },
      onError: (Object error) {
        if (_disposed) return;
        _statusBannerMessage = 'El enlace no es válido o venció. Solicita otro correo de recuperación.';
        notifyListeners();
      },
    );
    if (remoteGateway.isLiveSupabaseConnected && !remoteGateway.isTestDouble) {
      if (startWithActiveSession && _currentUser == null) {
        unawaited(_restoreSessionFromLink());
      }
      WidgetsBinding.instance.addObserver(this);
      _connectivitySubscription = Connectivity().onConnectivityChanged.listen((
        types,
      ) {
        if (_disposed) return;
        _networkUnavailable = types.every(
          (type) => type == ConnectivityResult.none,
        );
        outboxSyncService.networkAvailable = !_networkUnavailable;
        notifyListeners();
        if (!_networkUnavailable) unawaited(refreshFromServer());
      }, onError: (Object _) {});

      _syncTimer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => refreshFromServer(),
      );
      unawaited(refreshFromServer());
    }
    notifyListeners();
  }

  Future<void> refreshFromServer() async {
    if (_refreshingRemote ||
        _disposed ||
        !_appForeground ||
        !remoteGateway.isLiveSupabaseConnected ||
        remoteGateway.simulateNetworkOffline) {
      return;
    }
    _resetFeedScope();
    final scope = _feedScope;
    _refreshingRemote = true;
    final uid = _currentUser?.id;
    try {
      final guestSync = await outboxSyncService.syncPendingForUser(
        Publication.guestOwnerId,
      );
      if (_disposed || _currentUser?.id != uid || scope != _currentFeedScope) {
        return;
      }
      if (guestSync.confirmedCount > 0 ||
          (uid == null && _userOutbox.isNotEmpty)) {
        await refreshAllLocalData();
      }
      if (uid == null ||
          _disposed ||
          _currentUser?.id != uid ||
          scope != _currentFeedScope) {
        return;
      }
      await outboxSyncService.syncPendingForUser(uid);
      final previousHead = _feedHeadId;
      final page = await remoteGateway
          .fetchFeedPage(districtUbigeo: activeDistrictUbigeo)
          .timeout(const Duration(seconds: 15));
      if (_disposed || _currentUser?.id != uid || scope != _currentFeedScope) {
        return;
      }
      await database.mergeRemotePublications(page);
      if (_feedBeforeTime == null ||
          (page.length == 30 &&
              previousHead != null &&
              !page.any((p) => p.id == previousHead))) {
        feedHasMore = page.length == 30;
        if (page.isNotEmpty) {
          _feedBeforeTime = page.last.createdAt;
          _feedBeforeId = page.last.id;
        }
      }
      _feedHeadId = page.firstOrNull?.id;
      _networkUnavailable = false;
      outboxSyncService.networkAvailable = true;
      await outboxSyncService.syncPendingForUser(uid);
      final cached = await database.listPublications(activeUserId: uid);
      final updates = await remoteGateway
          .fetchCachedPublicationUpdates(cached)
          .timeout(const Duration(seconds: 15));
      if (_disposed || currentUser?.id != uid || scope != _currentFeedScope) {
        return;
      }
      await database.mergeRemotePublications(updates);
      final tombstones = await remoteGateway
          .fetchPublicationTombstones(cached.map((p) => p.id).toList())
          .timeout(const Duration(seconds: 15));
      if (_disposed || _currentUser?.id != uid || scope != _currentFeedScope) {
        return;
      }
      await database.applyPublicationTombstones(tombstones);
      await refreshAllLocalData();
      unawaited(cacheFeedForOffline());
      final snapshot = await remoteGateway.fetchCommunitySnapshot().timeout(
        const Duration(seconds: 15),
      );
      if (_disposed || _currentUser?.id != uid || scope != _currentFeedScope) {
        return;
      }
      await database.mergeCommunitySnapshot(snapshot);
      await refreshAllLocalData();
    } catch (_) {
      if (!_disposed && _currentUser?.id == uid) {
        _networkUnavailable = true;
        outboxSyncService.networkAvailable = false;
        _statusBannerMessage = 'No se pudo actualizar el barrio. Consulta la copia guardada; los envíos pendientes aún NO están comunicados.';
        notifyListeners();
      }
    } finally {
      _refreshingRemote = false;
    }
  }

  Future<UserProfile> _preferPendingLocalProfile(UserProfile remote) async {
    final local = await database.getUserProfile(remote.id);
    if (local == null) return remote;
    final pending = await database.listOutboxForUser(remote.id);
    return remoteGateway.lastProfileFetchWasOffline ||
            pending.any(
              (op) =>
                  op.entityType == 'profile' &&
                  op.syncStatus != SyncStatus.confirmado,
            )
        ? local
        : remote;
  }

  Future<void> _restoreSessionFromLink() async {
    if (_disposed ||
        _restoringAuthSession ||
        _authActionInProgress ||
        _passwordRecoveryPending) {
      return;
    }
    _restoringAuthSession = true;
    final epoch = _authEpoch;
    try {
      final remoteProfile = await remoteGateway.getCurrentSessionProfile();
      if (remoteProfile == null) return;
      final profile = await _preferPendingLocalProfile(remoteProfile);
      if (_disposed ||
          epoch != _authEpoch ||
          _authActionInProgress ||
          _currentUser?.id == profile.id) {
        return;
      }
      final previousId = _currentUser?.id;
      if (previousId != null) {
        await database.clearPrivateCacheOnSignOut(previousId);
      }
      if (_disposed || epoch != _authEpoch) return;
      _selectedConversation = null;
      _selectedEmergencyGroup = null;
      _currentUser = profile;
      await database.saveUserProfile(profile, queueSync: false);
      if (_disposed || epoch != _authEpoch) return;
      await refreshAllLocalData();
      if (_disposed || epoch != _authEpoch) return;
      _resumePendingIntentOrGoHome();
      unawaited(refreshFromServer());
    } catch (_) {
      if (!_disposed) {
        _statusBannerMessage =
            'Correo confirmado. Inicia sesión para entrar al barrio.';
        notifyListeners();
      }
    } finally {
      _restoringAuthSession = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appForeground = state == AppLifecycleState.resumed;
    if (_appForeground) unawaited(refreshFromServer());
  }

  @override
  void dispose() {
    _disposed = true;
    _syncTimer?.cancel();
    unawaited(_authSubscription?.cancel());
    unawaited(_recoverySubscription?.cancel());
    unawaited(_connectivitySubscription?.cancel());
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Recarga todas las listas desde SQLite respetando el aislamiento por usuario.
  Future<void> refreshAllLocalData() async {
    final activeId = _currentUser?.id ?? Publication.guestOwnerId;
    final allPublications = await database.listPublications(
      activeUserId: activeId,
    );
    _directoryPublications = allPublications
        .where((p) => p.kind.isService || p.isProduct)
        .toList();
    _publications = allPublications.where((publication) {
      if (publication.ownerUserId == activeId) return true;
      final distance = publication.distanceFrom(lat: activeLat, lng: activeLng);
      return (distance != null && distance <= 20000) ||
          (activeDistrictUbigeo != null &&
              publication.districtUbigeo == activeDistrictUbigeo);
    }).toList();
    _communityResources = await database.listCommunityResources(
      neighborhood: activeNeighborhood,
    );
    _supportGroups = await database.listSupportGroups(
      neighborhood: activeNeighborhood,
    );
    _lastSyncTimestamp = await database.getLastSyncTimestamp();

    _visitedEmergencyGroups = _currentUser == null
        ? {}
        : await database.visitedEmergencyGroups(activeId);
    if (_currentUser != null) {
      await database.migrateNeighborChatPreferences(activeId);
    }
    _chatActivity = _currentUser == null
        ? {}
        : await database.readChatActivity(activeId);
    final chatPreferences = _currentUser == null
        ? (pinned: <String>{}, hidden: <String>{})
        : await database.readChatPreferences(activeId);
    _pinnedChats = chatPreferences.pinned;
    _hiddenChats = chatPreferences.hidden;
    _userOutbox = await database.listOutboxForUser(activeId);
    _userDrafts = await database.listDraftsForUser(activeId);
    _userConversations = _currentUser == null
        ? const []
        : await database.listConversationsForUser(activeId);

    final submittedId = _lastSubmittedPublication?.id;
    if (submittedId != null) {
      _lastSubmittedPublication = allPublications
          .where((publication) => publication.id == submittedId)
          .firstOrNull;
    }

    if (_selectedPublication != null) {
      final selected = _selectedPublication!;
      final candidates = selected.kind.isService || selected.isProduct
          ? _directoryPublications
          : _publications;
      _selectedPublication = candidates
          .where((p) => p.id == selected.id)
          .firstOrNull;
    }

    notifyListeners();
  }

  /// Activa o desactiva el modo sin conexión para pruebas o uso real sin red.
  Future<void> setOfflineMode(bool offline) async {
    remoteGateway.simulateNetworkOffline = offline;
    if (!offline) {
      final summary = await outboxSyncService.syncPendingForUser(
        Publication.guestOwnerId,
      );
      final uid = _currentUser?.id;
      final accountSync = uid == null
          ? null
          : await outboxSyncService.syncPendingForUser(uid);
      final confirmedCount =
          summary.confirmedCount + (accountSync?.confirmedCount ?? 0);
      if (confirmedCount > 0) {
        _statusBannerMessage =
            'Conexión restablecida: $confirmedCount envío(s) confirmado(s) con el barrio.';
      }
    } else {
      _statusBannerMessage = 'Modo sin conexión activo: puedes consultar datos guardados y crear solicitudes en cola local.';
    }
    await refreshAllLocalData();
  }

  void clearStatusBanner() {
    _statusBannerMessage = null;
    notifyListeners();
  }

  void toggleOnboardingTutorial(bool visible) {
    _showOnboardingTutorial = visible;
    notifyListeners();
  }

  /// Navegación directa sin pasos redundantes.
  void navigateTo(AppSection section) {
    _lastSubmittedPublication = null;
    if (_currentSection != section) {
      _navigationStack.add(section);
      _currentSection = section;
    }
    notifyListeners();
  }

  void goHome() {
    _lastSubmittedPublication = null;
    _navigationStack
      ..clear()
      ..add(AppSection.inicio);
    _currentSection = AppSection.inicio;
    notifyListeners();
  }

  void goBack() {
    _lastSubmittedPublication = null;
    if (_navigationStack.length > 1) {
      _navigationStack.removeLast();
      _currentSection = _navigationStack.last;
    } else {
      _currentSection = AppSection.inicio;
    }
    notifyListeners();
  }

  /// Clic 1 desde Inicio:
  /// - `Reportar emergencia` -> tipo `emergenciaSolicitud` y prioridad `emergencia` predefinidos (2 clics total).
  /// - `Necesito ayuda` -> tipo `favorSolicitud` y prioridad `normal` predefinidos (2 clics total).
  /// - `Publicar servicio o favor` -> permite elegir tipo en clic 2 y enviar en clic 3 (3 clics total).
  void openQuickPublish({
    required PublicationKind presetKind,
    required bool lockTypeForTwoClickFlow,
  }) {
    _lastSubmittedPublication = null;
    _publishPresetKind = presetKind;
    _publishTypeLocked = lockTypeForTwoClickFlow;

    if (!isAuthenticated && presetKind != PublicationKind.emergenciaSolicitud) {
      _pendingAuthIntent = PendingAuthIntent(
        description: presetKind.isEmergency
            ? 'Reportar emergencia vecinal'
            : 'Publicar en mi barrio',
        targetRoute: 'publicar',
        presetKind: presetKind,
        lockType: lockTypeForTwoClickFlow,
      );
      navigateTo(AppSection.autenticacion);
      return;
    }

    navigateTo(AppSection.publicarRapido);
  }

  void setPublishPresetKind(PublicationKind kind) {
    _publishPresetKind = kind;
    notifyListeners();
  }

  /// Clic 2 (en flujos de emergencia/ayuda) o Clic 3 (en flujo de servicio/favor):
  /// Guarda en SQLite y cola Outbox dentro de la misma transacción e intenta
  /// sincronizar si hay conexión.
  Future<Publication> submitPublication({
    required PublicationKind kind,
    required String category,
    required String title,
    required String description,
    String availabilityText = '',
    bool shareResourceConsent = false,
    String? customClientMutationId,
    ChosenMapLocation? location,
  }) async {
    final user = _currentUser;
    if (user == null && kind != PublicationKind.emergenciaSolicitud) {
      throw StateError('Inicia sesión para publicar en tu barrio.');
    }
    if (title.trim().isEmpty) {
      throw StateError('Escribe un título breve y claro.');
    }
    if (description.trim().isEmpty) {
      throw StateError('Describe brevemente qué necesitas o qué ofreces.');
    }

    if (location != null) _validatePublicationLocation(location, kind);
    final now = DateTime.now().toUtc();
    final mutationId = customClientMutationId ?? EntityId.create();
    final pubId = EntityId.create();

    final priority = kind.isEmergency
        ? PublicationPriority.emergencia
        : PublicationPriority.normal;

    final draftPub = Publication(
      id: pubId,
      clientMutationId: mutationId,
      ownerUserId: user?.id ?? Publication.guestOwnerId,
      authorId: user?.id ?? '',
      authorAlias: user?.alias ?? 'Invitado',
      kind: kind,
      category: category,
      title: title.trim(),
      description: description.trim(),
      neighborhood: location == null
          ? activeNeighborhood
          : locationCatalog.district(location.districtUbigeo)!.name,
      sector: activeSector,
      districtUbigeo: location?.districtUbigeo ?? activeDistrictUbigeo,
      availabilityText: availabilityText.trim().isEmpty
          ? 'Horario flexible previa coordinación'
          : availabilityText.trim(),
      priority: priority,
      status: PublicationStatus.abierta,
      approxLat: location?.publicLat ?? activeLat,
      approxLng: location?.publicLng ?? activeLng,
      shareResourceConsent: shareResourceConsent,
      shareServiceLocation: location?.shareExactService ?? false,
      serviceLat: location?.serviceLat,
      serviceLng: location?.serviceLng,
      serviceAddress: location?.shareExactService == true
          ? location!.address
          : '',
      syncStatus: SyncStatus.pendiente,
      createdAt: now,
      updatedAt: now,
    );

    final savedLocal = await database.createOrUpdatePublicationTransactional(
      draftPub,
    );

    // Intento inmediato de sincronización si hay red disponible
    await outboxSyncService.syncPendingForUser(
      savedLocal.ownerUserId,
      onlyOperationId: savedLocal.clientMutationId,
    );

    await refreshAllLocalData();
    final effectivePub =
        _publications.where((p) => p.id == savedLocal.id).firstOrNull ??
        savedLocal;
    if (user?.id == _currentUser?.id) {
      _lastSubmittedPublication = effectivePub;
      notifyListeners();
    }
    return effectivePub;
  }

  /// Abre el detalle de un servicio (Clic 2 desde Buscar servicios).
  void openServiceDetail(Publication service) {
    _selectedPublication = service;
    navigateTo(AppSection.detalleServicio);
  }

  /// Abre el detalle de un favor o emergencia (Clic 2 desde Ver favores y ayudar).
  void openFavorDetail(Publication favor) {
    if (favor.isProduct) {
      openServiceDetail(favor);
      return;
    }
    _selectedPublication = favor;
    navigateTo(AppSection.detalleFavor);
  }

  /// Clic 3 en `Buscar servicios` -> abrir ficha -> `He usado este servicio y lo recomiendo`.
  Future<ServiceRecommendation> recommendService({
    required Publication service,
    String comment = 'Buen trato vecinal y cumplimiento puntual.',
    bool allowUpdateExisting = false,
  }) async {
    final user = _currentUser;
    if (user == null) {
      _pendingAuthIntent = PendingAuthIntent(
        description: 'Recomendar publicación de ${service.authorAlias}',
        targetRoute: 'detalle_servicio',
        publicationId: service.id,
      );
      navigateTo(AppSection.autenticacion);
      throw StateError('Inicia sesión para registrar tu recomendación.');
    }

    final rec = await database.submitOrUpdateRecommendation(
      id: EntityId.forContext('recommendation:${service.id}:${user.id}'),
      clientMutationId: EntityId.forContext(
        'recommendation:${service.id}:${user.id}',
      ),
      publicationId: service.id,
      userId: user.id,
      userAlias: user.alias,
      comment: comment,
      allowUpdateExisting: allowUpdateExisting,
    );

    await outboxSyncService.syncPendingForUser(
      user.id,
      onlyEntityId: rec.id,
    );
    await refreshAllLocalData();
    return rec;
  }

  Future<void> withdrawServiceRecommendation(Publication service) async {
    final user = _currentUser;
    if (user == null) return;
    await database.withdrawRecommendation(
      publicationId: service.id,
      userId: user.id,
    );
    await outboxSyncService.syncPendingForUser(user.id);
    await refreshAllLocalData();
  }

  /// Clic 3 en `Buscar servicios` -> abrir ficha -> escribir mensaje y `Enviar solicitud de contacto`.
  Future<ConversationThread> requestContactWithProvider({
    required Publication publication,
    required String initialMessage,
  }) async {
    if (publication.isGuestReport) {
      throw StateError('Este reporte de invitado no tiene chat privado.');
    }
    final user = _currentUser;
    if (user == null) {
      _pendingAuthIntent = PendingAuthIntent(
        description: 'Contactar a ${publication.authorAlias}',
        targetRoute: 'detalle_servicio',
        publicationId: publication.id,
      );
      navigateTo(AppSection.autenticacion);
      throw StateError('Inicia sesión para contactar a este vecino.');
    }

    final initialText = initialMessage.trim().isEmpty
        ? 'Hola ${publication.authorAlias}, vi tu publicación en el barrio y quisiera coordinar.'
        : initialMessage.trim();

    final peers = [user.id, publication.authorId]..sort();
    final contextId = EntityId.forContext('conversation:${peers.join(':')}');
    final thread = await database.openOrGetConversation(
      id: contextId,
      clientMutationId: contextId,
      publication: publication,
      participantId: user.id,
      participantAlias: user.alias,
    );

    final cleanMessage = 'Sobre «${publication.title}»: $initialText';

    await database.saveChatPreference(
      owner: user.id,
      chatKey: 'neighbor:${thread.peerIdFor(user.id)}',
      hidden: false,
    );

    await database.consolidateNeighborDrafts(user.id, thread.id);
    final previous = await database.getDraft(
      ownerUserId: user.id,
      draftKey: 'chat_${thread.id}',
    );
    if (previous != null &&
        previous.description.isNotEmpty &&
        previous.description != cleanMessage) {
      await database.saveDraft(
        FormDraft.fromSqlMap({
          ...previous.toSqlMap(),
          'draft_key': 'saved_chat_${EntityId.create()}',
        }),
      );
    }
    final draft = await _savePrivateDraft(
      user.id, thread.id, cleanMessage,
      kind: publication.kind, title: 'Mensaje de contacto', previous: previous,
    );
    await outboxSyncService.syncPendingForUser(
      user.id,
      onlyOperationId: thread.clientMutationId,
    );

    // Regla del encargo: los mensajes de chat requieren conexión activa;
    // si está offline, no se fingen enviados y se conserva el texto como borrador.
    if (remoteGateway.simulateNetworkOffline) {
      _selectedConversation = thread;
      await refreshAllLocalData();
      _statusBannerMessage = 'Sin conexión: la conversación quedó preparada y tu mensaje se guardó como borrador para enviarlo al reconectar.';
      navigateTo(AppSection.chatConversacion);
      return thread;
    }

    await remoteGateway.ensureNeighborConversation(
      id: thread.id,
      mutationId: thread.clientMutationId,
      publicationId: publication.id,
    );

    final (msgId, msgMutationId) = _privateMessageIds(draft);

    final message = await remoteGateway.sendRealtimeMessage(
      id: msgId,
      clientMutationId: msgMutationId,
      conversationId: thread.id,
      recipientId: thread.peerIdFor(user.id),
      senderId: user.id,
      senderAlias: user.alias,
      body: cleanMessage,
    );

    await database.recordOnlineMessage(
      id: msgId,
      clientMutationId: msgMutationId,
      conversationId: thread.id,
      senderId: user.id,
      senderAlias: user.alias,
      body: cleanMessage,
      syncStatus: SyncStatus.confirmado,
      createdAt: message.createdAt,
    );

    await database.deleteDraft(
      ownerUserId: user.id,
      draftKey: 'chat_${thread.id}',
    );
    _selectedConversation = thread;
    await refreshAllLocalData();
    _statusBannerMessage =
        'Solicitud de contacto enviada a ${publication.authorAlias}.';
    navigateTo(AppSection.chatConversacion);
    return thread;
  }

  /// Clic 3 en `Ver favores y ayudar` -> abrir solicitud -> nota opcional y `Enviar oferta de ayuda`.
  Future<HelpOffer> submitOfferToHelp({
    required Publication publication,
    required String note,
    String resourceShared = '',
    bool explicitShareConsent = false,
  }) async {
    if (publication.isGuestReport) {
      throw StateError('Este reporte de invitado no admite ofertas privadas.');
    }
    final user = _currentUser;
    if (user == null) {
      _pendingAuthIntent = PendingAuthIntent(
        description: 'Ofrecer ayuda a ${publication.authorAlias}',
        targetRoute: 'detalle_favor',
        publicationId: publication.id,
      );
      navigateTo(AppSection.autenticacion);
      throw StateError('Inicia sesión para ofrecer tu ayuda.');
    }

    final cleanNote = note.trim().isEmpty
        ? 'Hola ${publication.authorAlias}, soy vecino de ${user.sector} y puedo ayudarte gratuitamente.'
        : note.trim();

    final offer = await database.submitHelpOffer(
      id: EntityId.forContext('offer:${publication.id}:${user.id}'),
      clientMutationId: EntityId.forContext(
        'offer:${publication.id}:${user.id}',
      ),
      publicationId: publication.id,
      helperId: user.id,
      helperAlias: user.alias,
      note: cleanNote,
      resourceShared: resourceShared,
      explicitShareConsent: explicitShareConsent,
    );

    await outboxSyncService.syncPendingForUser(
      user.id,
      onlyEntityId: offer.id,
    );

    await refreshAllLocalData();
    final synced = (await database.listOffersForPublication(publication.id))
        .where((item) => item.id == offer.id)
        .firstOrNull ?? offer;
    _statusBannerMessage = synced.syncStatus.isConfirmed
        ? 'Oferta solidaria enviada y confirmada.'
        : 'Tu oferta sigue guardada en este teléfono, pendiente de confirmación.';
    notifyListeners();
    return synced;
  }

  /// Cambia el estado de una publicación propia (`abierta` -> `en_coordinacion` -> `resuelta` / `cancelada`).
  Future<Publication> updatePublicationStatus({
    required String publicationId,
    required PublicationStatus newStatus,
  }) async {
    final user = _currentUser;
    if (user == null) {
      throw StateError('Inicia sesión para gestionar tus publicaciones.');
    }
    final updated = await database.transitionPublicationStatus(
      publicationId: publicationId,
      actingUserId: user.id,
      newStatus: newStatus,
    );
    await outboxSyncService.syncPendingForUser(user.id);
    await refreshAllLocalData();
    _statusBannerMessage = 'Estado actualizado a "${newStatus.label}".';
    notifyListeners();
    return updated;
  }

  /// Envía un mensaje dentro de una conversación privada existente.
  /// Si está offline, bloquea el envío ficticio, informa que requiere conexión
  /// y conserva el texto como borrador local.
  Future<void> sendChatMessageInThread({
    required ConversationThread thread,
    required String text,
  }) async {
    final user = _currentUser;
    if (user == null) {
      throw StateError('Inicia sesión para enviar mensajes.');
    }
    final clean = text.trim();
    if (clean.isEmpty) {
      throw StateError('Escribe un mensaje antes de enviar.');
    }

    final draft = await _savePrivateDraft(user.id, thread.id, clean);
    if (remoteGateway.simulateNetworkOffline) {
      await refreshAllLocalData();
      throw StateError(
        'Los mensajes de chat requieren conexión activa y no se envían sin internet. Conservamos tu texto como borrador.',
      );
    }

    final (msgId, mutId) = _privateMessageIds(draft);

    final message = await remoteGateway.sendRealtimeMessage(
      id: msgId,
      clientMutationId: mutId,
      conversationId: thread.id,
      recipientId: thread.peerIdFor(user.id),
      senderId: user.id,
      senderAlias: user.alias,
      body: clean,
    );

    await database.recordOnlineMessage(
      id: msgId,
      clientMutationId: mutId,
      conversationId: thread.id,
      senderId: user.id,
      senderAlias: user.alias,
      body: clean,
      syncStatus: SyncStatus.confirmado,
      createdAt: message.createdAt,
    );

    await database.deleteDraft(
      ownerUserId: user.id,
      draftKey: 'chat_${thread.id}',
    );
    await refreshAllLocalData();
  }

  Future<FormDraft> _savePrivateDraft(String owner, String thread, String body, {
    PublicationKind kind = PublicationKind.servicio,
    String title = 'Mensaje',
    FormDraft? previous,
  }) async {
    final key = 'chat_$thread';
    final current = previous ?? await database.getDraft(ownerUserId: owner, draftKey: key);
    if (current != null && current.description.trim() == body) return current;
    final draft = FormDraft(draftKey: key, ownerUserId: owner, kind: kind,
      title: title, description: body, updatedAt: DateTime.now().toUtc());
    await database.saveDraft(draft);
    return draft;
  }

  (String, String) _privateMessageIds(FormDraft draft) {
    final key = '${draft.ownerUserId}:${draft.draftKey}:${draft.updatedAt.microsecondsSinceEpoch}';
    return (EntityId.forContext('message:$key'), EntityId.forContext('message-mutation:$key'));
  }

  Future<void> openEmergencyGroup(Publication publication) async {
    await refreshAllLocalData();
    if (!canViewEmergencyGroup(publication)) {
      throw StateError(
        'Inicia sesión y elige el distrito de esta emergencia en tu perfil.',
      );
    }
    final uid = currentUser!.id;
    await database.markEmergencyGroupVisited(uid, publication.id);
    await database.saveChatPreference(
      owner: uid,
      chatKey: 'group:${publication.id}',
      hidden: false,
    );
    if (currentUser?.id != uid) return;
    _selectedEmergencyGroup = publication;
    await refreshAllLocalData();
    if (currentUser?.id != uid) return;
    _visitedEmergencyGroups.add(publication.id);
    navigateTo(AppSection.chatEmergencia);
  }

  Future<List<EmergencyGroupMessage>> emergencyGroupHistory(
    Publication publication,
  ) async {
    if (!canViewEmergencyGroup(publication)) return const [];
    return database.listEmergencyGroupMessages(currentUser!.id, publication.id);
  }

  Future<List<EmergencyGroupMessage>> refreshEmergencyGroup(
    Publication publication, {
    EmergencyGroupMessage? before,
  }) async {
    if (!canViewEmergencyGroup(publication)) {
      throw StateError('No tienes acceso a este grupo.');
    }
    final uid = currentUser!.id;
    final remote = await remoteGateway
        .fetchEmergencyGroupMessages(
          publication.id,
          beforeTime: before?.createdAt,
          beforeId: before?.id,
        )
        .timeout(const Duration(seconds: 15));
    if (currentUser?.id != uid || !canViewEmergencyGroup(publication)) {
      return const [];
    }
    await database.mergeEmergencyGroupMessages(uid, remote);
    return remote;
  }

  Future<void> sendEmergencyGroupMessage(
    Publication publication,
    String body,
  ) async {
    if (!canViewEmergencyGroup(publication)) {
      throw StateError('No tienes acceso a este grupo.');
    }
    final current = publications
        .where((p) => p.id == publication.id)
        .firstOrNull;
    if (current == null ||
        current.status == PublicationStatus.resuelta ||
        current.status == PublicationStatus.cancelada) {
      throw StateError(
        'Esta emergencia está cerrada. Puedes consultar la conversación.',
      );
    }
    final uid = currentUser!.id;
    await database.saveEmergencyGroupMessage(
      owner: uid,
      publicationId: publication.id,
      senderAlias: currentUser!.alias,
      body: body,
    );
    await outboxSyncService.syncPendingForUser(uid);
    if (currentUser?.id == uid) await refreshAllLocalData();
  }

  bool isViewingPrivateChat(String conversationId) {
    final owner = currentUser?.id;
    final selected = selectedConversation;
    if (currentSection != AppSection.chatConversacion ||
        owner == null ||
        selected == null ||
        !selected.involvesUser(owner)) {
      return false;
    }
    return selected.id == conversationId ||
        _userConversations.any(
          (thread) =>
              thread.id == conversationId &&
              thread.involvesUser(owner) &&
              thread.peerIdFor(owner) == selected.peerIdFor(owner),
        );
  }

  Future<bool> openPrivateChatFromPush(
    String conversationId,
    String userId,
  ) async {
    if (_disposed || currentUser?.id != userId || passwordRecoveryPending) {
      return false;
    }
    var thread = _userConversations
        .where((item) => item.id == conversationId && item.involvesUser(userId))
        .firstOrNull;
    if (thread == null) {
      thread = await remoteGateway
          .fetchPrivateConversation(conversationId)
          .timeout(const Duration(seconds: 10));
      if (thread == null || _disposed || currentUser?.id != userId) {
        return false;
      }
      await database.mergeCommunitySnapshot({
        'conversations': [thread.toSqlMap()],
      });
      if (_disposed || currentUser?.id != userId) return false;
      await refreshAllLocalData();
    }
    if (_disposed || currentUser?.id != userId || passwordRecoveryPending) {
      return false;
    }
    if (!isViewingPrivateChat(conversationId)) {
      await openConversation(thread);
    }
    return !_disposed &&
        currentUser?.id == userId &&
        isViewingPrivateChat(conversationId);
  }

  Future<void> openConversation(ConversationThread thread) async {
    final owner = currentUser?.id;
    if (owner == null || !thread.involvesUser(owner)) return;
    await database.saveChatPreference(
      owner: owner,
      chatKey: 'neighbor:${thread.peerIdFor(owner)}',
      hidden: false,
    );
    if (currentUser?.id != owner) return;
    await database.consolidateNeighborDrafts(owner, thread.id);
    await refreshAllLocalData();
    if (currentUser?.id != owner) return;
    _selectedConversation = thread;
    navigateTo(AppSection.chatConversacion);
  }

  Future<void> cacheFeedForOffline() async {
    if (_cachingFeed || _disposed || !isAuthenticated || isOfflineMode) return;
    _cachingFeed = true;
    final scope = _currentFeedScope;
    try {
      while (!_disposed &&
          _appForeground &&
          scope == _currentFeedScope &&
          !isOfflineMode &&
          feedHasMore) {
        final before = _feedBeforeId;
        await loadMoreFeed();
        if (_feedBeforeId == before) break;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    } finally {
      _cachingFeed = false;
    }
  }

  Future<void> loadMoreFeed() async {
    _resetFeedScope();
    final scope = _feedScope;
    if (feedLoading || !feedHasMore || !isAuthenticated || isOfflineMode) {
      return;
    }
    feedLoading = true;
    notifyListeners();
    final uid = currentUser!.id;
    try {
      final page = await remoteGateway
          .fetchFeedPage(
            districtUbigeo: activeDistrictUbigeo,
            beforeTime: _feedBeforeTime,
            beforeId: _feedBeforeId,
          )
          .timeout(const Duration(seconds: 15));
      if (_disposed || uid != currentUser?.id || scope != _currentFeedScope) {
        return;
      }
      await database.mergeRemotePublications(page);
      feedHasMore = page.length == 30;
      if (page.isNotEmpty) {
        _feedBeforeTime = page.last.createdAt;
        _feedBeforeId = page.last.id;
      }
      await refreshAllLocalData();
    } catch (_) {
      if (!_disposed && uid == currentUser?.id) {
        _statusBannerMessage =
            'No se cargaron más avisos. Los guardados siguen disponibles.';
      }
    } finally {
      if (!_disposed) {
        feedLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> editPublication(
    Publication publication, {
    required String title,
    required String description,
    required String category,
    String availabilityText = '',
  }) async {
    final changes = <String, Object?>{
      'title': title.trim(),
      'description': description.trim(),
      'category': category.trim(),
      'availability_text': availabilityText.trim(),
    };
    if (title.trim().length < 3 ||
        title.trim().length > 120 ||
        description.trim().isEmpty ||
        description.trim().length > 1000 ||
        category.trim().length < 2 ||
        category.trim().length > 50 ||
        availabilityText.trim().length > 200) {
      throw StateError('Revisa los campos y sus límites.');
    }
    await _mutatePublication(publication, changes, false);
  }

  Future<void> deletePublication(Publication publication) =>
      _mutatePublication(publication, {}, true);
  Future<void> _mutatePublication(
    Publication publication,
    Map<String, Object?> changes,
    bool deleting,
  ) async {
    final uid = currentUser?.id;
    if (uid == null || publication.authorId != uid) {
      throw StateError('Solo el autor puede cambiar su publicación.');
    }
    await database.editPublication(
      publicationId: publication.id,
      actingUserId: uid,
      changes: changes,
      delete: deleting,
    );
    if (deleting && _selectedPublication?.id == publication.id) {
      _selectedPublication = null;
      goHome();
    }
    await refreshAllLocalData();
    await outboxSyncService.syncPendingForUser(uid);
    if (currentUser?.id == uid) await refreshAllLocalData();
  }

  void _validatePublicationLocation(
    ChosenMapLocation location,
    PublicationKind kind,
  ) {
    if (locationCatalog.district(location.districtUbigeo) == null ||
        approximateMapPoint(
              location.point.latitude,
              location.point.longitude,
            ) ==
            null) {
      throw StateError('Selecciona un distrito y punto válidos.');
    }
    if (location.shareExactService && !kind.isService) {
      throw StateError('Solo un servicio puede compartir un punto exacto.');
    }
    if (location.address.length > 300) {
      throw StateError('La dirección debe tener como máximo 300 caracteres.');
    }
  }

  Future<void> updatePublicationLocation(
    Publication publication,
    ChosenMapLocation location,
  ) async {
    final uid = _currentUser?.id;
    if (uid == null || publication.authorId != uid) {
      throw StateError('Solo el autor puede ubicar su publicación.');
    }
    _validatePublicationLocation(location, publication.kind);
    await database.updatePublicationLocation(
      publicationId: publication.id,
      actingUserId: uid,
      location: location.toMap(),
    );
    await refreshAllLocalData();
    if (!isOfflineMode) await outboxSyncService.syncPendingForUser(uid);
    if (_currentUser?.id == uid) await refreshAllLocalData();
  }

  /// Actualiza filtros del directorio de servicios
  void updateServiceFilters({
    String? searchQuery,
    String? category,
    double? radiusMeters,
    bool clearRadius = false,
    bool? mapQuadrantView,
  }) {
    if (searchQuery != null) _serviceSearchQuery = searchQuery;
    if (category != null) _serviceCategoryFilter = category;
    if (clearRadius) {
      _serviceRadiusMeters = null;
    } else if (radiusMeters != null) {
      _serviceRadiusMeters = radiusMeters;
    }
    if (mapQuadrantView != null) _serviceMapQuadrantView = mapQuadrantView;
    notifyListeners();
  }

  Future<void> refreshServiceDirectory({
    double? nearLat,
    double? nearLng,
  }) async {
    final userId = currentUser?.id;
    if (userId == null ||
        isOfflineMode ||
        !remoteGateway.isLiveSupabaseConnected) {
      return;
    }
    final district = activeDistrictUbigeo;
    final origin = approximateMapPoint(
      nearLat ?? directoryLat,
      nearLng ?? directoryLng,
    );
    if (district == null && origin == null) return;

    Future<List<Publication>> fetch({
      required PublicationKind kind,
      String? category,
      bool byDistrict = false,
    }) => remoteGateway
        .fetchPublicationsWithinRadius(
          originLat: byDistrict ? null : origin?.latitude,
          originLng: byDistrict ? null : origin?.longitude,
          radiusMeters: _directoryRangeMeters,
          districtUbigeo: byDistrict ? district : null,
          kind: kind,
          category: category,
        )
        .timeout(const Duration(seconds: 15));

    final pages = await Future.wait([
      if (district != null) ...[
        fetch(kind: PublicationKind.servicio, byDistrict: true),
        fetch(
          kind: PublicationKind.anuncio,
          category: Publication.productCategory,
          byDistrict: true,
        ),
      ],
      if (origin != null) ...[
        fetch(kind: PublicationKind.servicio),
        fetch(
          kind: PublicationKind.anuncio,
          category: Publication.productCategory,
        ),
      ],
    ]);
    if (_disposed ||
        currentUser?.id != userId ||
        activeDistrictUbigeo != district) {
      return;
    }
    final results = {for (final p in pages.expand((page) => page)) p.id: p};
    await database.mergeRemotePublications(results.values.toList());
    if (!_disposed && currentUser?.id == userId) await refreshAllLocalData();
  }

  List<Publication> get filteredServices => directoryServices();

  List<Publication> directoryServices({double? nearLat, double? nearLng}) {
    final origin = approximateMapPoint(
      nearLat ?? directoryLat,
      nearLng ?? directoryLng,
    );
    final district = activeDistrictUbigeo;
    final owner = currentUser?.id ?? Publication.guestOwnerId;
    return _directoryPublications.where((p) {
      final distance = p.distanceFrom(
        lat: origin?.latitude,
        lng: origin?.longitude,
      );
      final sameDistrict = district != null && p.districtUbigeo == district;
      if (p.ownerUserId != owner &&
          !sameDistrict &&
          (distance == null || distance > _directoryRangeMeters)) {
        return false;
      }
      final matchesCategory =
          _serviceCategoryFilter == Publication.productCategory
          ? p.isProduct
          : p.kind.isService &&
                (_serviceCategoryFilter == 'todos' ||
                    p.category == _serviceCategoryFilter);
      if (!matchesCategory) return false;
      if (_serviceSearchQuery.trim().isNotEmpty) {
        final q = _serviceSearchQuery.trim().toLowerCase();
        final match =
            p.title.toLowerCase().contains(q) ||
            p.description.toLowerCase().contains(q) ||
            p.authorAlias.toLowerCase().contains(q) ||
            p.sector.toLowerCase().contains(q);
        if (!match) return false;
      }
      if (_serviceRadiusMeters != null && _serviceRadiusMeters! > 0) {
        if (distance != null && distance > _serviceRadiusMeters!) return false;
        if (distance == null && !sameDistrict) return false;
      }
      return true;
    }).toList();
  }

  void updateFavorFilters({
    String? category,
    PublicationStatus? status,
    bool clearStatus = false,
  }) {
    if (category != null) _favorCategoryFilter = category;
    if (clearStatus) {
      _favorStatusFilter = null;
    } else if (status != null) {
      _favorStatusFilter = status;
    }
    notifyListeners();
  }

  List<Publication> get filteredFavors {
    return _publications.where((p) {
      if (!p.kind.isSolidarityFavor || p.isProduct) return false;
      if (_favorCategoryFilter != 'todos' &&
          p.category != _favorCategoryFilter) {
        return false;
      }
      if (_favorStatusFilter != null && p.status != _favorStatusFilter) {
        return false;
      }
      return true;
    }).toList();
  }

  List<Publication> get emergencyPublications {
    return _publications.where((p) => p.kind.isEmergency).toList();
  }

  List<Publication> get myPublications {
    final uid = _currentUser?.id;
    if (uid == null) return const [];
    return _publications.where((p) => p.authorId == uid).toList();
  }

  /// Reintento manual de toda la cola Outbox o de una operación específica.
  Future<OutboxSyncSummary> retryOutboxSync({String? onlyOperationId}) async {
    final summary = await outboxSyncService.syncPendingForUser(
      _currentUser?.id ?? Publication.guestOwnerId,
      onlyOperationId: onlyOperationId,
    );
    _statusBannerMessage = summary.lastMessage.isNotEmpty
        ? summary.lastMessage
        : 'Reintento completado.';
    await refreshAllLocalData();
    unawaited(refreshFromServer());
    return summary;
  }

  Future<void> keepDraftAndLoadServer(String publicationId) async {
    final user = _currentUser;
    if (user == null) {
      throw StateError('Inicia sesión para revisar tus cambios.');
    }
    final remote = await remoteGateway.fetchOwnPublication(publicationId);
    if (_currentUser?.id != user.id) {
      throw StateError('La sesión cambió. Vuelve a intentarlo.');
    }
    await database.keepDraftAndAcceptRemote(remote, user.id);
    _statusBannerMessage = 'Se cargó la versión del barrio. Conservamos tu texto anterior en Borradores.';
    await refreshAllLocalData();
  }

  /// Registro de nueva cuenta vecinal y reanudación de intención pendiente.
  Future<void> registerAndSignIn({
    required String alias,
    required String email,
    required String password,
    required String neighborhood,
    required String sector,
    required double? approxLat,
    required double? approxLng,
    required bool useGpsApprox,
    String? districtUbigeo,
  }) async {
    if (districtUbigeo != null &&
        locationCatalog.district(districtUbigeo) == null) {
      throw StateError(
        'Selecciona un distrito reconocido en el catálogo INEI.',
      );
    }
    if (_currentUser == null) {
      await updateLocationPreference(
        neighborhood: neighborhood,
        sector: sector,
        districtUbigeo: districtUbigeo,
        approxLat: approxLat,
        approxLng: approxLng,
        useGpsApprox: useGpsApprox,
      );
    }
    _authActionInProgress = true;
    final authEpoch = ++_authEpoch;
    try {
      final profile = await remoteGateway.registerAccount(
        alias: alias,
        email: email,
        password: password,
        neighborhood: neighborhood,
        sector: sector,
        approxLat: approxLat,
        approxLng: approxLng,
        useGpsApprox: useGpsApprox,
        districtUbigeo: districtUbigeo,
      );
      if (_disposed || authEpoch != _authEpoch || _passwordRecoveryPending) {
        throw StateError('La sesión cambió. Vuelve a intentarlo.');
      }
      _currentUser = profile;
      await database.saveUserProfile(profile, queueSync: true);
      await outboxSyncService.syncPendingForUser(profile.id);
      await refreshAllLocalData();
      _resumePendingIntentOrGoHome();
      unawaited(refreshFromServer());
    } finally {
      _authActionInProgress = false;
    }
  }

  /// Inicio de sesión y reanudación automática de intención pendiente.
  Future<void> signIn({required String email, required String password}) =>
      _signInUsing(() => remoteGateway.signInAccount(email: email, password: password));

  Future<void> signInWithEntra(String alias) {
    final gateway = remoteGateway;
    if (gateway is! AzureRemoteGateway) throw StateError('Entra no está configurado.');
    return _signInUsing(() => gateway.signInHosted(alias));
  }

  Future<void> _signInUsing(Future<UserProfile> Function() authenticate) async {
    _authActionInProgress = true;
    final authEpoch = ++_authEpoch;
    try {
      final remoteProfile = await authenticate();
      final profile = await _preferPendingLocalProfile(remoteProfile);
      if (_disposed || authEpoch != _authEpoch || _passwordRecoveryPending) {
        throw StateError('La sesión cambió. Vuelve a intentarlo.');
      }
      _currentUser = profile;
      await database.saveUserProfile(profile, queueSync: false);
      await refreshAllLocalData();
      _resumePendingIntentOrGoHome();
      unawaited(refreshFromServer());
    } finally {
      _authActionInProgress = false;
    }
  }

  /// Cierre de sesión seguro: limpia caché privada de conversaciones/mensajes
  /// del usuario saliente y preserva sus operaciones pendientes aisladas por
  /// `owner_user_id`.
  Future<void> signOut() async {
    _authEpoch++;
    final previousId = _currentUser?.id;
    await remoteGateway.signOutAccount();
    _passwordRecoveryPending = false;
    _feedBeforeTime = null;
    _feedBeforeId = null;
    feedHasMore = true;
    if (previousId != null) {
      await database.clearPrivateCacheOnSignOut(previousId);
    }
    _currentUser = null;
    _selectedConversation = null;
    _selectedEmergencyGroup = null;
    await refreshAllLocalData();
    goHome();
  }

  Future<void> requestPasswordReset(String email) async {
    final cleanEmail = email.trim().toLowerCase();
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(cleanEmail)) {
      throw StateError('Ingresa un correo electrónico válido.');
    }
    await remoteGateway.requestPasswordReset(cleanEmail);
  }

  Future<void> completePasswordRecovery(String password) async {
    if (!_passwordRecoveryPending ||
        !remoteGateway.hasPasswordRecoverySession) {
      throw StateError(
        'Abre un enlace de recuperación válido para cambiar tu contraseña.',
      );
    }
    if (password.length < 8) {
      throw StateError('La nueva contraseña debe tener al menos 8 caracteres.');
    }
    final epoch = _authEpoch;
    await remoteGateway.updateRecoveredPassword(password);
    if (_disposed || epoch != _authEpoch) return;
    _passwordRecoveryPending = false;
    await _restoreSessionFromLink();
    if (_disposed || epoch != _authEpoch) return;
    _statusBannerMessage = 'Contraseña actualizada.';
    notifyListeners();
  }

  /// Actualiza la zona manual o preferencia de GPS aproximado sin bloquear al
  /// usuario que rechaza el permiso de ubicación.
  Future<void> updateLocationPreference({
    required String neighborhood,
    required String sector,
    required double? approxLat,
    required double? approxLng,
    required bool useGpsApprox,
    String? districtUbigeo,
  }) async {
    if (districtUbigeo != null &&
        locationCatalog.district(districtUbigeo) == null) {
      throw StateError(
        'Selecciona un distrito reconocido en el catálogo INEI.',
      );
    }
    _selectedManualUbigeo = districtUbigeo;
    _selectedManualUsesGps = useGpsApprox;
    _selectedManualNeighborhood = neighborhood;
    _selectedManualSector = sector;
    _selectedManualLat = AppConfig.roundOptionalPublicCoordinate(approxLat);
    _selectedManualLng = AppConfig.roundOptionalPublicCoordinate(approxLng);

    await database.saveManualLocation({
      'district_ubigeo': districtUbigeo,
      'neighborhood': neighborhood,
      'sector': sector,
      'approx_lat': _selectedManualLat,
      'approx_lng': _selectedManualLng,
      'use_gps_approx': useGpsApprox ? 1 : 0,
    });
    if (_currentUser != null) {
      final updated = _currentUser!.copyWith(
        neighborhood: neighborhood,
        sector: sector,
        districtUbigeo: districtUbigeo,
        clearCoordinates: approxLat == null || approxLng == null,
        approxLat: _selectedManualLat,
        approxLng: _selectedManualLng,
        useGpsApprox: useGpsApprox,
        updatedAt: DateTime.now().toUtc(),
      );
      _currentUser = updated;
      await database.saveUserProfile(updated, queueSync: true);
      await outboxSyncService.syncPendingForUser(updated.id);
    }
    await refreshAllLocalData();
  }

  void _resumePendingIntentOrGoHome() {
    final intent = _pendingAuthIntent;
    _pendingAuthIntent = null;
    if (intent == null) {
      goHome();
      return;
    }

    if (intent.targetRoute == 'publicar' && intent.presetKind != null) {
      _publishPresetKind = intent.presetKind!;
      _publishTypeLocked = intent.lockType;
      navigateTo(AppSection.publicarRapido);
      return;
    }

    if (intent.publicationId != null) {
      final match = _publications
          .where((p) => p.id == intent.publicationId)
          .toList();
      if (match.isNotEmpty) {
        _selectedPublication = match.first;
        navigateTo(
          match.first.kind.isService || match.first.isProduct
              ? AppSection.detalleServicio
              : AppSection.detalleFavor,
        );
        return;
      }
    }

    goHome();
  }
}
