import 'dart:convert';

import '../config/app_config.dart';

/// Tipos de publicación soportados en la red vecinal.
enum PublicationKind {
  anuncio('anuncio', 'Anuncio del barrio', 'Anuncio vecinal'),
  servicio('servicio', 'Oficio o servicio', 'Directorio de servicios'),
  favorSolicitud('favor_solicitud', 'Solicitar ayuda o favor', 'Ayuda vecinal'),
  favorOferta('favor_oferta', 'Ofrecer un favor solidario', 'Oferta solidaria'),
  prestamo('prestamo', 'Préstamo de herramienta o equipo', 'Préstamo gratuito'),
  donacion('donacion', 'Donación comunitaria', 'Donación gratuita'),
  habilidad('habilidad', 'Intercambio de habilidades', 'Aprender y compartir'),
  emergenciaSolicitud(
    'emergencia_solicitud',
    'Reporte de necesidad en emergencia',
    'Emergencia vecinal',
  ),
  emergenciaOferta(
    'emergencia_oferta',
    'Ofrecer recurso para emergencia',
    'Apoyo en emergencia',
  );

  const PublicationKind(this.dbValue, this.label, this.shortBadge);
  final String dbValue;
  final String label;
  final String shortBadge;

  bool get isService => this == PublicationKind.servicio;

  bool get isEmergency =>
      this == PublicationKind.emergenciaSolicitud ||
      this == PublicationKind.emergenciaOferta;

  bool get isSolidarity => !isService;
  bool get isSolidarityFavor => !isService && !isEmergency;

  static PublicationKind fromDb(String value) {
    for (final item in PublicationKind.values) {
      if (item.dbValue == value) return item;
    }
    return PublicationKind.favorSolicitud;
  }
}

/// Nivel de prioridad de una publicación.
enum PublicationPriority {
  normal('normal', 'Normal · Con calma'),
  urgente('urgente', 'Urgente hoy'),
  emergencia('emergencia', 'Emergencia · Prioridad alta');

  const PublicationPriority(this.dbValue, this.label);
  final String dbValue;
  final String label;

  static PublicationPriority fromDb(String value) {
    for (final item in PublicationPriority.values) {
      if (item.dbValue == value) return item;
    }
    return PublicationPriority.normal;
  }
}

/// Estados del ciclo de vida de una publicación o solicitud solidaria.
enum PublicationStatus {
  abierta('abierta', 'Abierta'),
  enCoordinacion('en_coordinacion', 'En coordinación'),
  resuelta('resuelta', 'Resuelta'),
  cancelada('cancelada', 'Cancelada');

  const PublicationStatus(this.dbValue, this.label);
  final String dbValue;
  final String label;

  static PublicationStatus fromDb(String value) {
    for (final item in PublicationStatus.values) {
      if (item.dbValue == value) return item;
    }
    return PublicationStatus.abierta;
  }

  /// Transiciones válidas de estado según las reglas del dominio.
  List<PublicationStatus> get allowedNextStatuses {
    switch (this) {
      case PublicationStatus.abierta:
        return const [
          PublicationStatus.enCoordinacion,
          PublicationStatus.resuelta,
          PublicationStatus.cancelada,
        ];
      case PublicationStatus.enCoordinacion:
        return const [
          PublicationStatus.abierta,
          PublicationStatus.resuelta,
          PublicationStatus.cancelada,
        ];
      case PublicationStatus.resuelta:
        return const [PublicationStatus.abierta];
      case PublicationStatus.cancelada:
        return const [];
    }
  }
}

/// Estados explícitos y diferenciados de sincronización local/remota.
/// Solo la confirmación del servidor permite pasar a [confirmado].
enum SyncStatus {
  borrador('borrador', 'Borrador guardado en teléfono'),
  pendiente('pendiente', 'Pendiente de envío · NO comunicado'),
  enviando('enviando', 'Enviando al servidor...'),
  confirmado('confirmado', 'Confirmado por el servidor'),
  error('error', 'Error de envío · Reintento disponible'),
  conflicto('conflicto', 'Conflicto de versión · Requiere revisión');

  const SyncStatus(this.dbValue, this.label);
  final String dbValue;
  final String label;

  bool get isConfirmed => this == SyncStatus.confirmado;
  bool get needsSync =>
      this == SyncStatus.pendiente ||
      this == SyncStatus.error ||
      this == SyncStatus.conflicto;

  static SyncStatus fromDb(String value) {
    for (final item in SyncStatus.values) {
      if (item.dbValue == value) return item;
    }
    return SyncStatus.pendiente;
  }
}

/// Estados de una oferta de ayuda solidaria.
enum OfferStatus {
  enviada('enviada', 'Oferta enviada'),
  aceptada('aceptada', 'En coordinación'),
  retirada('retirada', 'Retirada'),
  completada('completada', 'Completada');

  const OfferStatus(this.dbValue, this.label);
  final String dbValue;
  final String label;

  static OfferStatus fromDb(String value) {
    for (final item in OfferStatus.values) {
      if (item.dbValue == value) return item;
    }
    return OfferStatus.enviada;
  }
}

/// Perfil público mínimo del vecino.
class UserProfile {
  const UserProfile({
    required this.id,
    required this.alias,
    required this.neighborhood,
    required this.sector,
    this.districtUbigeo,
    this.email = '',
    this.bio = '',
    this.approxLat = -12.076,
    this.approxLng = -77.063,
    this.useGpsApprox = false,
    this.shareResourcesConsent = false,
    this.isDemo = false,
    required this.updatedAt,
  });

  final String id;
  final String alias;
  final String neighborhood;
  final String sector;
  final String? districtUbigeo;
  final String email;
  final String bio;
  final double? approxLat;
  final double? approxLng;
  final bool useGpsApprox;
  final bool shareResourcesConsent;
  final bool isDemo;
  final DateTime updatedAt;

  UserProfile copyWith({
    String? alias,
    String? neighborhood,
    String? sector,
    String? districtUbigeo,
    bool clearCoordinates = false,
    String? email,
    String? bio,
    double? approxLat,
    double? approxLng,
    bool? useGpsApprox,
    bool? shareResourcesConsent,
    bool? isDemo,
    DateTime? updatedAt,
  }) {
    return UserProfile(
      id: id,
      alias: alias ?? this.alias,
      neighborhood: neighborhood ?? this.neighborhood,
      sector: sector ?? this.sector,
      districtUbigeo: districtUbigeo ?? this.districtUbigeo,
      email: email ?? this.email,
      bio: bio ?? this.bio,
      approxLat: clearCoordinates
          ? null
          : approxLat != null
          ? AppConfig.roundOptionalPublicCoordinate(approxLat)
          : this.approxLat,
      approxLng: clearCoordinates
          ? null
          : approxLng != null
          ? AppConfig.roundOptionalPublicCoordinate(approxLng)
          : this.approxLng,
      useGpsApprox: useGpsApprox ?? this.useGpsApprox,
      shareResourcesConsent:
          shareResourcesConsent ?? this.shareResourcesConsent,
      isDemo: isDemo ?? this.isDemo,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, Object?> toSqlMap() => {
    'id': id,
    'alias': alias,
    'neighborhood': neighborhood,
    'sector': sector,
    'district_ubigeo': districtUbigeo,
    'email': email,
    'bio': bio,
    'approx_lat': AppConfig.roundOptionalPublicCoordinate(approxLat),
    'approx_lng': AppConfig.roundOptionalPublicCoordinate(approxLng),
    'use_gps_approx': useGpsApprox ? 1 : 0,
    'share_resources_consent': shareResourcesConsent ? 1 : 0,
    'is_demo': isDemo ? 1 : 0,
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };

  factory UserProfile.fromSqlMap(Map<String, Object?> map) {
    return UserProfile(
      id: (map['id'] as String?) ?? '',
      alias: (map['alias'] as String?) ?? 'Vecino',
      neighborhood:
          (map['neighborhood'] as String?) ?? AppConfig.defaultNeighborhood,
      sector: (map['sector'] as String?) ?? AppConfig.defaultSector,
      districtUbigeo: map['district_ubigeo'] as String?,
      email: (map['email'] as String?) ?? '',
      bio: (map['bio'] as String?) ?? '',
      approxLat: (map['approx_lat'] as num?)?.toDouble(),
      approxLng: (map['approx_lng'] as num?)?.toDouble(),
      useGpsApprox:
          (map['use_gps_approx'] == 1 || map['use_gps_approx'] == true),
      shareResourcesConsent:
          (map['share_resources_consent'] == 1 ||
          map['share_resources_consent'] == true),
      isDemo: (map['is_demo'] == 1 || map['is_demo'] == true),
      updatedAt:
          DateTime.tryParse((map['updated_at'] as String?) ?? '') ??
          DateTime.now().toUtc(),
    );
  }
}

/// Publicación unificada (Servicio del directorio, Favor solidario o Reporte de emergencia).
class Publication {
  static const guestOwnerId = 'anonymous';
  static const productCategory = 'producto';

  const Publication({
    this.deletedAt,
    required this.id,
    required this.clientMutationId,
    required this.ownerUserId,
    required this.authorId,
    required this.authorAlias,
    required this.kind,
    required this.category,
    required this.title,
    required this.description,
    required this.neighborhood,
    required this.sector,
    this.districtUbigeo,
    this.availabilityText = '',
    this.priority = PublicationPriority.normal,
    this.status = PublicationStatus.abierta,
    required this.approxLat,
    required this.approxLng,
    this.shareResourceConsent = false,
    this.shareServiceLocation = false,
    this.serviceLat,
    this.serviceLng,
    this.serviceAddress = '',
    this.recommendationCount = 0,
    this.syncStatus = SyncStatus.confirmado,
    this.lastError = '',
    this.version = 1,
    this.isDemo = false,
    required this.createdAt,
    required this.updatedAt,
  });

  final DateTime? deletedAt;
  bool get isDeleted => deletedAt != null;
  final String id;
  final String clientMutationId;
  final String ownerUserId;
  final String authorId;
  bool get isGuestReport =>
      authorId.isEmpty && kind == PublicationKind.emergenciaSolicitud;
  final String authorAlias;
  final PublicationKind kind;
  final String category;
  bool get isProduct =>
      kind == PublicationKind.anuncio && category == productCategory;

  bool isInSameZoneAs(UserProfile profile) {
    final district = districtUbigeo;
    final normalizedSector = sector.trim().toLowerCase();
    return district != null &&
        district.isNotEmpty &&
        district == profile.districtUbigeo &&
        normalizedSector.isNotEmpty &&
        normalizedSector == profile.sector.trim().toLowerCase();
  }

  final String title;
  final String description;
  final String neighborhood;
  final String sector;
  final String? districtUbigeo;
  final String availabilityText;
  final PublicationPriority priority;
  final PublicationStatus status;
  final double? approxLat;
  final double? approxLng;
  final bool shareResourceConsent;
  final bool shareServiceLocation;
  final double? serviceLat;
  final double? serviceLng;
  final String serviceAddress;
  final int recommendationCount;
  final SyncStatus syncStatus;
  final String lastError;
  final int version;
  final bool isDemo;
  final DateTime createdAt;
  final DateTime updatedAt;

  String distanceLabelFrom({required double? lat, required double? lng}) {
    final distance = distanceFrom(lat: lat, lng: lng);
    return distance == null
        ? 'Sin distancia geográfica disponible'
        : AppConfig.formatApproximateDistance(distance);
  }

  int? distanceFrom({required double? lat, required double? lng}) {
    if (lat == null || lng == null || approxLat == null || approxLng == null) {
      return null;
    }
    return AppConfig.approximateDistanceMeters(
      fromLat: lat,
      fromLng: lng,
      toLat: approxLat!,
      toLng: approxLng!,
    );
  }

  Publication copyWith({
    DateTime? deletedAt,
    String? title,
    String? districtUbigeo,
    double? approxLat,
    double? approxLng,
    bool? shareServiceLocation,
    double? serviceLat,
    double? serviceLng,
    String? serviceAddress,
    String? description,
    String? category,
    String? availabilityText,
    PublicationPriority? priority,
    PublicationStatus? status,
    int? recommendationCount,
    SyncStatus? syncStatus,
    String? lastError,
    int? version,
    DateTime? updatedAt,
  }) {
    return Publication(
      deletedAt: deletedAt ?? this.deletedAt,
      id: id,
      clientMutationId: clientMutationId,
      ownerUserId: ownerUserId,
      authorId: authorId,
      authorAlias: authorAlias,
      kind: kind,
      category: category ?? this.category,
      title: title ?? this.title,
      description: description ?? this.description,
      neighborhood: neighborhood,
      sector: sector,
      districtUbigeo: districtUbigeo ?? this.districtUbigeo,
      availabilityText: availabilityText ?? this.availabilityText,
      priority: priority ?? this.priority,
      status: status ?? this.status,
      approxLat: approxLat ?? this.approxLat,
      approxLng: approxLng ?? this.approxLng,
      shareResourceConsent: shareResourceConsent,
      shareServiceLocation: shareServiceLocation ?? this.shareServiceLocation,
      serviceLat: (shareServiceLocation ?? this.shareServiceLocation)
          ? (serviceLat ?? this.serviceLat)
          : null,
      serviceLng: (shareServiceLocation ?? this.shareServiceLocation)
          ? (serviceLng ?? this.serviceLng)
          : null,
      serviceAddress: (shareServiceLocation ?? this.shareServiceLocation)
          ? (serviceAddress ?? this.serviceAddress)
          : '',
      recommendationCount: recommendationCount ?? this.recommendationCount,
      syncStatus: syncStatus ?? this.syncStatus,
      lastError: lastError ?? this.lastError,
      version: version ?? this.version,
      isDemo: isDemo,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, Object?> toSqlMap() => {
    'deleted_at': deletedAt?.toUtc().toIso8601String(),
    'id': id,
    'client_mutation_id': clientMutationId,
    'owner_user_id': ownerUserId,
    'author_id': authorId,
    'author_alias': authorAlias,
    'kind': kind.dbValue,
    'category': category,
    'title': title,
    'description': description,
    'neighborhood': neighborhood,
    'sector': sector,
    'district_ubigeo': districtUbigeo,
    'availability_text': availabilityText,
    'priority': priority.dbValue,
    'status': status.dbValue,
    'approx_lat': AppConfig.roundOptionalPublicCoordinate(approxLat),
    'approx_lng': AppConfig.roundOptionalPublicCoordinate(approxLng),
    'share_resource_consent': shareResourceConsent ? 1 : 0,
    'share_service_location': shareServiceLocation ? 1 : 0,
    'service_lat': shareServiceLocation ? serviceLat : null,
    'service_lng': shareServiceLocation ? serviceLng : null,
    'service_address': shareServiceLocation ? serviceAddress : '',
    'recommendation_count': recommendationCount,
    'sync_status': syncStatus.dbValue,
    'last_error': lastError,
    'version': version,
    'is_demo': isDemo ? 1 : 0,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };

  factory Publication.fromSqlMap(Map<String, Object?> map) {
    return Publication(
      deletedAt: DateTime.tryParse(map['deleted_at'] as String? ?? ''),
      id: (map['id'] as String?) ?? '',
      clientMutationId: (map['client_mutation_id'] as String?) ?? '',
      ownerUserId: (map['owner_user_id'] as String?) ?? 'public',
      authorId: (map['author_id'] as String?) ?? '',
      authorAlias:
          map['author_id'] == null &&
              map['kind'] == PublicationKind.emergenciaSolicitud.dbValue
          ? 'Invitado'
          : (map['author_alias'] as String?) ?? 'Vecino',
      kind: PublicationKind.fromDb(
        (map['kind'] as String?) ?? 'favor_solicitud',
      ),
      category: (map['category'] as String?) ?? 'general',
      title: (map['title'] as String?) ?? '',
      description: (map['description'] as String?) ?? '',
      neighborhood:
          (map['neighborhood'] as String?) ?? AppConfig.defaultNeighborhood,
      sector: (map['sector'] as String?) ?? AppConfig.defaultSector,
      districtUbigeo: map['district_ubigeo'] as String?,
      availabilityText: (map['availability_text'] as String?) ?? '',
      priority: PublicationPriority.fromDb(
        (map['priority'] as String?) ?? 'normal',
      ),
      status: PublicationStatus.fromDb((map['status'] as String?) ?? 'abierta'),
      approxLat: ((map['approx_lat'] ?? map['public_lat']) as num?)?.toDouble(),
      approxLng: ((map['approx_lng'] ?? map['public_lng']) as num?)?.toDouble(),
      shareServiceLocation:
          map['share_service_location'] == true ||
          map['share_service_location'] == 1,
      serviceLat: (map['service_lat'] as num?)?.toDouble(),
      serviceLng: (map['service_lng'] as num?)?.toDouble(),
      serviceAddress: map['service_address'] as String? ?? '',
      shareResourceConsent:
          (map['share_resource_consent'] == 1 ||
          map['share_resource_consent'] == true),
      recommendationCount: (map['recommendation_count'] as num?)?.toInt() ?? 0,
      syncStatus: SyncStatus.fromDb(
        (map['sync_status'] as String?) ?? 'confirmado',
      ),
      lastError: (map['last_error'] as String?) ?? '',
      version: (map['version'] as num?)?.toInt() ?? 1,
      isDemo: (map['is_demo'] == 1 || map['is_demo'] == true),
      createdAt:
          DateTime.tryParse((map['created_at'] as String?) ?? '') ??
          DateTime.now().toUtc(),
      updatedAt:
          DateTime.tryParse((map['updated_at'] as String?) ?? '') ??
          DateTime.now().toUtc(),
    );
  }
}

/// Recomendación vecinal sobre un servicio del directorio.
/// Una por usuario y servicio; sin auto-recomendaciones; permite modificar o retirar.
class ServiceRecommendation {
  const ServiceRecommendation({
    required this.id,
    required this.clientMutationId,
    required this.ownerUserId,
    required this.publicationId,
    required this.userId,
    required this.userAlias,
    this.comment = '',
    this.syncStatus = SyncStatus.confirmado,
    this.lastError = '',
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String clientMutationId;
  final String ownerUserId;
  final String publicationId;
  final String userId;
  final String userAlias;
  final String comment;
  final SyncStatus syncStatus;
  final String lastError;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, Object?> toSqlMap() => {
    'id': id,
    'client_mutation_id': clientMutationId,
    'owner_user_id': ownerUserId,
    'publication_id': publicationId,
    'user_id': userId,
    'user_alias': userAlias,
    'comment': comment,
    'sync_status': syncStatus.dbValue,
    'last_error': lastError,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };

  factory ServiceRecommendation.fromSqlMap(Map<String, Object?> map) {
    return ServiceRecommendation(
      id: (map['id'] as String?) ?? '',
      clientMutationId: (map['client_mutation_id'] as String?) ?? '',
      ownerUserId: (map['owner_user_id'] as String?) ?? 'public',
      publicationId: (map['publication_id'] as String?) ?? '',
      userId: (map['user_id'] as String?) ?? '',
      userAlias: (map['user_alias'] as String?) ?? 'Vecino del barrio',
      comment: (map['comment'] as String?) ?? '',
      syncStatus: SyncStatus.fromDb(
        (map['sync_status'] as String?) ?? 'confirmado',
      ),
      lastError: (map['last_error'] as String?) ?? '',
      createdAt:
          DateTime.tryParse((map['created_at'] as String?) ?? '') ??
          DateTime.now().toUtc(),
      updatedAt:
          DateTime.tryParse((map['updated_at'] as String?) ?? '') ??
          DateTime.now().toUtc(),
    );
  }
}

/// Oferta gratuita de ayuda solidaria para una solicitud vecinal.
class HelpOffer {
  const HelpOffer({
    required this.id,
    required this.clientMutationId,
    required this.ownerUserId,
    required this.publicationId,
    required this.helperId,
    required this.helperAlias,
    required this.note,
    this.resourceShared = '',
    this.explicitShareConsent = false,
    this.status = OfferStatus.enviada,
    this.syncStatus = SyncStatus.confirmado,
    this.lastError = '',
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String clientMutationId;
  final String ownerUserId;
  final String publicationId;
  final String helperId;
  final String helperAlias;
  final String note;
  final String resourceShared;
  final bool explicitShareConsent;
  final OfferStatus status;
  final SyncStatus syncStatus;
  final String lastError;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, Object?> toSqlMap() => {
    'id': id,
    'client_mutation_id': clientMutationId,
    'owner_user_id': ownerUserId,
    'publication_id': publicationId,
    'helper_id': helperId,
    'helper_alias': helperAlias,
    'note': note,
    'resource_shared': resourceShared,
    'explicit_share_consent': explicitShareConsent ? 1 : 0,
    'status': status.dbValue,
    'sync_status': syncStatus.dbValue,
    'last_error': lastError,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };

  factory HelpOffer.fromSqlMap(Map<String, Object?> map) {
    return HelpOffer(
      id: (map['id'] as String?) ?? '',
      clientMutationId: (map['client_mutation_id'] as String?) ?? '',
      ownerUserId: (map['owner_user_id'] as String?) ?? 'public',
      publicationId: (map['publication_id'] as String?) ?? '',
      helperId: (map['helper_id'] as String?) ?? '',
      helperAlias: (map['helper_alias'] as String?) ?? 'Vecino',
      note: (map['note'] as String?) ?? '',
      resourceShared: (map['resource_shared'] as String?) ?? '',
      explicitShareConsent:
          (map['explicit_share_consent'] == 1 ||
          map['explicit_share_consent'] == true),
      status: OfferStatus.fromDb((map['status'] as String?) ?? 'enviada'),
      syncStatus: SyncStatus.fromDb(
        (map['sync_status'] as String?) ?? 'confirmado',
      ),
      lastError: (map['last_error'] as String?) ?? '',
      createdAt:
          DateTime.tryParse((map['created_at'] as String?) ?? '') ??
          DateTime.now().toUtc(),
      updatedAt:
          DateTime.tryParse((map['updated_at'] as String?) ?? '') ??
          DateTime.now().toUtc(),
    );
  }
}

/// Conversación privada contextual a una publicación entre dos participantes autenticados.
class ConversationThread {
  const ConversationThread({
    required this.id,
    required this.clientMutationId,
    required this.ownerUserId,
    required this.publicationId,
    required this.publicationTitle,
    required this.publicationAuthorId,
    required this.publicationAuthorAlias,
    required this.participantId,
    required this.participantAlias,
    this.syncStatus = SyncStatus.confirmado,
    required this.updatedAt,
  });

  final String id;
  final String clientMutationId;
  final String ownerUserId;
  final String publicationId;
  final String publicationTitle;
  final String publicationAuthorId;
  final String publicationAuthorAlias;
  final String participantId;
  final String participantAlias;
  final SyncStatus syncStatus;
  final DateTime updatedAt;

  bool involvesUser(String userId) =>
      userId == publicationAuthorId || userId == participantId;

  String peerIdFor(String userId) =>
      userId == publicationAuthorId ? participantId : publicationAuthorId;

  String peerAliasFor(String userId) =>
      userId == publicationAuthorId ? participantAlias : publicationAuthorAlias;

  Map<String, Object?> toSqlMap() => {
    'id': id,
    'client_mutation_id': clientMutationId,
    'owner_user_id': ownerUserId,
    'publication_id': publicationId,
    'publication_title': publicationTitle,
    'publication_author_id': publicationAuthorId,
    'publication_author_alias': publicationAuthorAlias,
    'participant_id': participantId,
    'participant_alias': participantAlias,
    'sync_status': syncStatus.dbValue,
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };

  factory ConversationThread.fromSqlMap(Map<String, Object?> map) {
    return ConversationThread(
      id: (map['id'] as String?) ?? '',
      clientMutationId: (map['client_mutation_id'] as String?) ?? '',
      ownerUserId: (map['owner_user_id'] as String?) ?? '',
      publicationId: (map['publication_id'] as String?) ?? '',
      publicationTitle:
          (map['publication_title'] as String?) ?? 'Coordinación vecinal',
      publicationAuthorId: (map['publication_author_id'] as String?) ?? '',
      publicationAuthorAlias:
          (map['publication_author_alias'] as String?) ?? 'Vecino',
      participantId: (map['participant_id'] as String?) ?? '',
      participantAlias: (map['participant_alias'] as String?) ?? 'Vecino',
      syncStatus: SyncStatus.fromDb(
        (map['sync_status'] as String?) ?? 'confirmado',
      ),
      updatedAt:
          DateTime.tryParse((map['updated_at'] as String?) ?? '') ??
          DateTime.now().toUtc(),
    );
  }
}

/// Mensaje individual dentro de una conversación privada.
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.clientMutationId,
    required this.ownerUserId,
    required this.conversationId,
    required this.senderId,
    required this.senderAlias,
    required this.body,
    this.syncStatus = SyncStatus.confirmado,
    required this.createdAt,
  });

  final String id;
  final String clientMutationId;
  final String ownerUserId;
  final String conversationId;
  final String senderId;
  final String senderAlias;
  final String body;
  final SyncStatus syncStatus;
  final DateTime createdAt;

  Map<String, Object?> toSqlMap() => {
    'id': id,
    'client_mutation_id': clientMutationId,
    'owner_user_id': ownerUserId,
    'conversation_id': conversationId,
    'sender_id': senderId,
    'sender_alias': senderAlias,
    'body': body,
    'sync_status': syncStatus.dbValue,
    'created_at': createdAt.toUtc().toIso8601String(),
  };

  factory ChatMessage.fromSqlMap(Map<String, Object?> map) {
    return ChatMessage(
      id: (map['id'] as String?) ?? '',
      clientMutationId: (map['client_mutation_id'] as String?) ?? '',
      ownerUserId: (map['owner_user_id'] as String?) ?? '',
      conversationId: (map['conversation_id'] as String?) ?? '',
      senderId: (map['sender_id'] as String?) ?? '',
      senderAlias: (map['sender_alias'] as String?) ?? 'Vecino',
      body: (map['body'] as String?) ?? '',
      syncStatus: SyncStatus.fromDb(
        (map['sync_status'] as String?) ?? 'confirmado',
      ),
      createdAt:
          DateTime.tryParse((map['created_at'] as String?) ?? '') ??
          DateTime.now().toUtc(),
    );
  }
}

/// Recurso comunitario, punto de referencia o directorio oficial.
class CommunityResource {
  const CommunityResource({
    required this.id,
    required this.kind,
    required this.title,
    required this.description,
    required this.neighborhood,
    required this.sector,
    required this.approxLat,
    required this.approxLng,
    required this.contactInfo,
    required this.sourceLabel,
    this.isDemo = false,
    required this.updatedAt,
  });

  final String id;
  final String kind;
  final String title;
  final String description;
  final String neighborhood;
  final String sector;
  final double? approxLat;
  final double? approxLng;
  final String contactInfo;
  final String sourceLabel;
  final bool isDemo;
  final DateTime updatedAt;

  Map<String, Object?> toSqlMap() => {
    'id': id,
    'kind': kind,
    'title': title,
    'description': description,
    'neighborhood': neighborhood,
    'sector': sector,
    'approx_lat': AppConfig.roundOptionalPublicCoordinate(approxLat),
    'approx_lng': AppConfig.roundOptionalPublicCoordinate(approxLng),
    'contact_info': contactInfo,
    'source_label': sourceLabel,
    'is_demo': isDemo ? 1 : 0,
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };

  factory CommunityResource.fromSqlMap(Map<String, Object?> map) {
    return CommunityResource(
      id: (map['id'] as String?) ?? '',
      kind: (map['kind'] as String?) ?? 'punto_encuentro',
      title: (map['title'] as String?) ?? '',
      description: (map['description'] as String?) ?? '',
      neighborhood:
          (map['neighborhood'] as String?) ?? AppConfig.defaultNeighborhood,
      sector: (map['sector'] as String?) ?? AppConfig.defaultSector,
      approxLat: (map['approx_lat'] as num?)?.toDouble(),
      approxLng: (map['approx_lng'] as num?)?.toDouble(),
      contactInfo: (map['contact_info'] as String?) ?? '',
      sourceLabel: (map['source_label'] as String?) ?? '',
      isDemo: (map['is_demo'] == 1 || map['is_demo'] == true),
      updatedAt:
          DateTime.tryParse((map['updated_at'] as String?) ?? '') ??
          DateTime.now().toUtc(),
    );
  }
}

/// Grupo de apoyo barrial.
class SupportGroup {
  const SupportGroup({
    required this.id,
    required this.name,
    required this.description,
    required this.neighborhood,
    required this.sector,
    required this.coordinatorLabel,
    required this.channelNote,
    this.isDemo = false,
  });

  final String id;
  final String name;
  final String description;
  final String neighborhood;
  final String sector;
  final String coordinatorLabel;
  final String channelNote;
  final bool isDemo;

  Map<String, Object?> toSqlMap() => {
    'id': id,
    'name': name,
    'description': description,
    'neighborhood': neighborhood,
    'sector': sector,
    'coordinator_label': coordinatorLabel,
    'channel_note': channelNote,
    'is_demo': isDemo ? 1 : 0,
  };

  factory SupportGroup.fromSqlMap(Map<String, Object?> map) {
    return SupportGroup(
      id: (map['id'] as String?) ?? '',
      name: (map['name'] as String?) ?? '',
      description: (map['description'] as String?) ?? '',
      neighborhood:
          (map['neighborhood'] as String?) ?? AppConfig.defaultNeighborhood,
      sector: (map['sector'] as String?) ?? AppConfig.defaultSector,
      coordinatorLabel: (map['coordinator_label'] as String?) ?? '',
      channelNote: (map['channel_note'] as String?) ?? '',
      isDemo: (map['is_demo'] == 1 || map['is_demo'] == true),
    );
  }
}

/// Entrada persistente en la cola Outbox local para sincronización idempotente.
class OutboxOperation {
  const OutboxOperation({
    required this.operationId,
    required this.ownerUserId,
    required this.entityType,
    required this.entityId,
    required this.action,
    required this.payloadJson,
    required this.syncStatus,
    this.attempts = 0,
    this.lastError = '',
    this.expectedVersion = 1,
    required this.createdAt,
    required this.updatedAt,
  });

  final String operationId;
  final String ownerUserId;
  final String entityType;
  final String entityId;
  final String action;
  final String payloadJson;
  Map<String, dynamic> decodePayload() =>
      jsonDecode(payloadJson) as Map<String, dynamic>;
  final SyncStatus syncStatus;
  final int attempts;
  final String lastError;
  final int expectedVersion;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, Object?> toSqlMap() => {
    'operation_id': operationId,
    'owner_user_id': ownerUserId,
    'entity_type': entityType,
    'entity_id': entityId,
    'action': action,
    'payload_json': payloadJson,
    'sync_status': syncStatus.dbValue,
    'attempts': attempts,
    'last_error': lastError,
    'expected_version': expectedVersion,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };

  factory OutboxOperation.fromSqlMap(Map<String, Object?> map) {
    return OutboxOperation(
      operationId: (map['operation_id'] as String?) ?? '',
      ownerUserId: (map['owner_user_id'] as String?) ?? '',
      entityType: (map['entity_type'] as String?) ?? '',
      entityId: (map['entity_id'] as String?) ?? '',
      action: (map['action'] as String?) ?? 'upsert',
      payloadJson: (map['payload_json'] as String?) ?? '{}',
      syncStatus: SyncStatus.fromDb(
        (map['sync_status'] as String?) ?? 'pendiente',
      ),
      attempts: (map['attempts'] as num?)?.toInt() ?? 0,
      lastError: (map['last_error'] as String?) ?? '',
      expectedVersion: (map['expected_version'] as num?)?.toInt() ?? 1,
      createdAt:
          DateTime.tryParse((map['created_at'] as String?) ?? '') ??
          DateTime.now().toUtc(),
      updatedAt:
          DateTime.tryParse((map['updated_at'] as String?) ?? '') ??
          DateTime.now().toUtc(),
    );
  }
}

/// Borrador local persistido por usuario y clave de formulario.
class FormDraft {
  static String publicationKey(PublicationKind kind, String category) =>
      kind == PublicationKind.anuncio && category == Publication.productCategory
      ? 'publish_producto'
      : 'publish_${kind.dbValue}';

  const FormDraft({
    required this.draftKey,
    required this.ownerUserId,
    required this.kind,
    required this.title,
    required this.description,
    this.category = 'general',
    this.locationJson = '',
    this.availabilityText = '',
    this.priority = PublicationPriority.normal,
    required this.updatedAt,
  });

  final String draftKey;
  final String ownerUserId;
  final PublicationKind kind;
  final String title;
  final String description;
  final String category;
  final String locationJson;
  final String availabilityText;
  final PublicationPriority priority;
  final DateTime updatedAt;

  Map<String, Object?> toSqlMap() => {
    'draft_key': draftKey,
    'owner_user_id': ownerUserId,
    'kind': kind.dbValue,
    'title': title,
    'description': description,
    'category': category,
    'location_json': locationJson,
    'availability_text': availabilityText,
    'priority': priority.dbValue,
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };

  factory FormDraft.fromSqlMap(Map<String, Object?> map) {
    return FormDraft(
      draftKey: (map['draft_key'] as String?) ?? 'general',
      ownerUserId: (map['owner_user_id'] as String?) ?? 'guest',
      kind: PublicationKind.fromDb(
        (map['kind'] as String?) ?? 'favor_solicitud',
      ),
      title: (map['title'] as String?) ?? '',
      description: (map['description'] as String?) ?? '',
      category: (map['category'] as String?) ?? 'general',
      locationJson: map['location_json'] as String? ?? '',
      availabilityText: (map['availability_text'] as String?) ?? '',
      priority: PublicationPriority.fromDb(
        (map['priority'] as String?) ?? 'normal',
      ),
      updatedAt:
          DateTime.tryParse((map['updated_at'] as String?) ?? '') ??
          DateTime.now().toUtc(),
    );
  }
}
