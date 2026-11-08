import 'dart:async';
import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../config/app_config.dart';
import '../models/domain_models.dart';
import '../models/entity_id.dart';
import '../models/emergency_group_message.dart';

/// Contrato de motor transaccional SQLite para permitir ejecución nativa con
/// `sqflite` en Android/iOS y pruebas deterministas en entornos sin canal nativo.
abstract class LocalStoreEngine {
  Future<void> init();
  Future<T> runInTransaction<T>(
    Future<T> Function(LocalStoreTransaction txn) action,
  );
  Future<List<Map<String, Object?>>> query(
    String table, {
    String? where,
    List<Object?>? whereArgs,
    String? orderBy,
  });
  Future<void> close();
}

abstract class LocalStoreTransaction {
  Future<void> upsert(
    String table,
    String primaryKey,
    Map<String, Object?> values,
  );
  Future<void> delete(
    String table, {
    required String where,
    required List<Object?> whereArgs,
  });
  Future<List<Map<String, Object?>>> query(
    String table, {
    String? where,
    List<Object?>? whereArgs,
  });
}

/// Implementación real con SQLite (`sqflite`) para Android e iPhone.
class SqfliteStoreEngine implements LocalStoreEngine {
  SqfliteStoreEngine({this.databaseFileName = 'nexo_vecinal_v1.db'});

  final String databaseFileName;
  Database? _db;

  static const groupMessagesSchema = """
    CREATE TABLE IF NOT EXISTS emergency_group_messages_local (
      cache_id TEXT PRIMARY KEY, owner_user_id TEXT NOT NULL, id TEXT NOT NULL,
      client_mutation_id TEXT NOT NULL, publication_id TEXT NOT NULL,
      sender_id TEXT NOT NULL, sender_alias TEXT NOT NULL, body TEXT NOT NULL,
      created_at TEXT NOT NULL, sync_status TEXT NOT NULL, last_error TEXT NOT NULL DEFAULT ''
    )
  """;
  static const groupMessagesIndex =
      'CREATE INDEX IF NOT EXISTS idx_group_messages_local ON emergency_group_messages_local(owner_user_id,publication_id,created_at,id)';
  static const List<String> schemaStatements = [
    groupMessagesSchema,
    groupMessagesIndex,
    '''
    CREATE TABLE IF NOT EXISTS profiles_local (
      id TEXT PRIMARY KEY,
      alias TEXT NOT NULL,
      neighborhood TEXT NOT NULL,
      sector TEXT NOT NULL,
      district_ubigeo TEXT,
      email TEXT NOT NULL DEFAULT '',
      bio TEXT NOT NULL DEFAULT '',
      approx_lat REAL,
      approx_lng REAL,
      use_gps_approx INTEGER NOT NULL DEFAULT 0,
      share_resources_consent INTEGER NOT NULL DEFAULT 0,
      is_demo INTEGER NOT NULL DEFAULT 0,
      updated_at TEXT NOT NULL
    )
    ''',
    '''
    CREATE TABLE IF NOT EXISTS publications_local (
      id TEXT PRIMARY KEY,
      client_mutation_id TEXT NOT NULL UNIQUE,
      owner_user_id TEXT NOT NULL,
      author_id TEXT NOT NULL,
      author_alias TEXT NOT NULL,
      kind TEXT NOT NULL,
      category TEXT NOT NULL,
      title TEXT NOT NULL,
      description TEXT NOT NULL,
      neighborhood TEXT NOT NULL,
      sector TEXT NOT NULL,
      district_ubigeo TEXT,
      availability_text TEXT NOT NULL DEFAULT '',
      priority TEXT NOT NULL DEFAULT 'normal',
      status TEXT NOT NULL DEFAULT 'abierta',
      approx_lat REAL,
      approx_lng REAL,
      share_resource_consent INTEGER NOT NULL DEFAULT 0,
      deleted_at TEXT,
      share_service_location INTEGER NOT NULL DEFAULT 0,
      service_lat REAL,
      service_lng REAL,
      service_address TEXT NOT NULL DEFAULT '',
      recommendation_count INTEGER NOT NULL DEFAULT 0,
      sync_status TEXT NOT NULL DEFAULT 'confirmado',
      last_error TEXT NOT NULL DEFAULT '',
      version INTEGER NOT NULL DEFAULT 1,
      is_demo INTEGER NOT NULL DEFAULT 0,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    ''',
    'CREATE INDEX IF NOT EXISTS idx_pub_local_kind ON publications_local(kind, status, neighborhood)',
    'CREATE INDEX IF NOT EXISTS idx_pub_local_owner ON publications_local(owner_user_id)',
    '''
    CREATE TABLE IF NOT EXISTS recommendations_local (
      id TEXT PRIMARY KEY,
      client_mutation_id TEXT NOT NULL UNIQUE,
      owner_user_id TEXT NOT NULL,
      publication_id TEXT NOT NULL,
      user_id TEXT NOT NULL,
      user_alias TEXT NOT NULL,
      comment TEXT NOT NULL DEFAULT '',
      sync_status TEXT NOT NULL DEFAULT 'confirmado',
      last_error TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      UNIQUE(publication_id, user_id)
    )
    ''',
    '''
    CREATE TABLE IF NOT EXISTS help_offers_local (
      id TEXT PRIMARY KEY,
      client_mutation_id TEXT NOT NULL UNIQUE,
      owner_user_id TEXT NOT NULL,
      publication_id TEXT NOT NULL,
      helper_id TEXT NOT NULL,
      helper_alias TEXT NOT NULL,
      note TEXT NOT NULL DEFAULT '',
      resource_shared TEXT NOT NULL DEFAULT '',
      explicit_share_consent INTEGER NOT NULL DEFAULT 0,
      status TEXT NOT NULL DEFAULT 'enviada',
      sync_status TEXT NOT NULL DEFAULT 'confirmado',
      last_error TEXT NOT NULL DEFAULT '',
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      UNIQUE(publication_id, helper_id)
    )
    ''',
    '''
    CREATE TABLE IF NOT EXISTS conversations_local (
      id TEXT PRIMARY KEY,
      client_mutation_id TEXT NOT NULL UNIQUE,
      owner_user_id TEXT NOT NULL,
      publication_id TEXT NOT NULL,
      publication_title TEXT NOT NULL,
      publication_author_id TEXT NOT NULL,
      publication_author_alias TEXT NOT NULL,
      participant_id TEXT NOT NULL,
      participant_alias TEXT NOT NULL,
      sync_status TEXT NOT NULL DEFAULT 'confirmado',
      updated_at TEXT NOT NULL,
      UNIQUE(publication_id, participant_id)
    )
    ''',
    '''
    CREATE TABLE IF NOT EXISTS messages_local (
      id TEXT PRIMARY KEY,
      client_mutation_id TEXT NOT NULL UNIQUE,
      owner_user_id TEXT NOT NULL,
      conversation_id TEXT NOT NULL,
      sender_id TEXT NOT NULL,
      sender_alias TEXT NOT NULL,
      body TEXT NOT NULL,
      sync_status TEXT NOT NULL DEFAULT 'confirmado',
      created_at TEXT NOT NULL
    )
    ''',
    '''
    CREATE TABLE IF NOT EXISTS drafts_local (
      draft_key TEXT NOT NULL,
      owner_user_id TEXT NOT NULL,
      kind TEXT NOT NULL,
      title TEXT NOT NULL,
      description TEXT NOT NULL,
      category TEXT NOT NULL DEFAULT 'general',
      availability_text TEXT NOT NULL DEFAULT '',
      location_json TEXT NOT NULL DEFAULT '',
      priority TEXT NOT NULL DEFAULT 'normal',
      updated_at TEXT NOT NULL,
      PRIMARY KEY (draft_key, owner_user_id)
    )
    ''',
    '''
    CREATE TABLE IF NOT EXISTS outbox_operations (
      operation_id TEXT PRIMARY KEY,
      owner_user_id TEXT NOT NULL,
      entity_type TEXT NOT NULL,
      entity_id TEXT NOT NULL,
      action TEXT NOT NULL,
      payload_json TEXT NOT NULL,
      sync_status TEXT NOT NULL DEFAULT 'pendiente',
      attempts INTEGER NOT NULL DEFAULT 0,
      last_error TEXT NOT NULL DEFAULT '',
      expected_version INTEGER NOT NULL DEFAULT 1,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    ''',
    'CREATE INDEX IF NOT EXISTS idx_outbox_owner ON outbox_operations(owner_user_id, sync_status)',
    '''
    CREATE TABLE IF NOT EXISTS community_resources_local (
      id TEXT PRIMARY KEY,
      kind TEXT NOT NULL,
      title TEXT NOT NULL,
      description TEXT NOT NULL,
      neighborhood TEXT NOT NULL,
      sector TEXT NOT NULL,
      approx_lat REAL NOT NULL,
      approx_lng REAL NOT NULL,
      contact_info TEXT NOT NULL,
      source_label TEXT NOT NULL,
      is_demo INTEGER NOT NULL DEFAULT 0,
      updated_at TEXT NOT NULL
    )
    ''',
    '''
    CREATE TABLE IF NOT EXISTS support_groups_local (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      description TEXT NOT NULL,
      neighborhood TEXT NOT NULL,
      sector TEXT NOT NULL,
      coordinator_label TEXT NOT NULL,
      channel_note TEXT NOT NULL,
      is_demo INTEGER NOT NULL DEFAULT 0
    )
    ''',
    '''
    CREATE TABLE IF NOT EXISTS cache_metadata (
      cache_key TEXT PRIMARY KEY,
      last_synced_at TEXT NOT NULL
    )
    ''',
    '''
    CREATE TABLE IF NOT EXISTS practice_progress_local (
      scenario_id TEXT PRIMARY KEY,
      completed_missions_json TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    ''',
    '''
    CREATE TABLE IF NOT EXISTS manual_location_local (
      id TEXT PRIMARY KEY,
      district_ubigeo TEXT,
      neighborhood TEXT NOT NULL,
      sector TEXT NOT NULL,
      approx_lat REAL,
      approx_lng REAL,
      use_gps_approx INTEGER NOT NULL DEFAULT 0
    )
    ''',
  ];

  static Future<void> upgradeLocationTables(Database db) async {
    for (final table in ['profiles_local', 'publications_local']) {
      final columns = (await db.rawQuery('PRAGMA table_info($table)'))
          .map((row) => row['name'] as String)
          .toList();
      await db.execute('ALTER TABLE $table RENAME TO ${table}_v1');
      final create = schemaStatements.firstWhere(
        (sql) => sql.contains('CREATE TABLE IF NOT EXISTS $table ('),
      );
      await db.execute(create);
      final fields = columns.map((name) => '"$name"').join(',');
      await db.execute(
        'INSERT INTO $table ($fields) SELECT $fields FROM ${table}_v1',
      );
      await db.execute('DROP TABLE ${table}_v1');
    }
    for (final sql in schemaStatements) {
      await db.execute(sql);
    }
  }

  @override
  Future<void> init() async {
    if (_db != null) return;
    final databasesPath = await getDatabasesPath();
    final fullPath = p.join(databasesPath, databaseFileName);
    _db = await openDatabase(
      fullPath,
      version: 5,
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 5) {
          await db.execute(groupMessagesSchema);
          await db.execute(groupMessagesIndex);
        }
        if (oldVersion < 2) await upgradeLocationTables(db);
        if (oldVersion >= 2 && oldVersion < 3) {
          await db.execute(
            'ALTER TABLE publications_local ADD COLUMN share_service_location INTEGER NOT NULL DEFAULT 0',
          );
          await db.execute(
            'ALTER TABLE publications_local ADD COLUMN service_lat REAL',
          );
          await db.execute(
            'ALTER TABLE publications_local ADD COLUMN service_lng REAL',
          );
          await db.execute(
            "ALTER TABLE publications_local ADD COLUMN service_address TEXT NOT NULL DEFAULT ''",
          );
        }
        if (oldVersion >= 2 && oldVersion < 4) {
          final columns = await db.rawQuery(
            'PRAGMA table_info(publications_local)',
          );
          if (!columns.any((row) => row['name'] == 'deleted_at')) {
            await db.execute(
              'ALTER TABLE publications_local ADD COLUMN deleted_at TEXT',
            );
          }
        }
        if (oldVersion < 3) {
          final columns = await db.rawQuery('PRAGMA table_info(drafts_local)');
          if (!columns.any((row) => row['name'] == 'location_json')) {
            await db.execute(
              "ALTER TABLE drafts_local ADD COLUMN location_json TEXT NOT NULL DEFAULT ''",
            );
          }
        }
      },
      onCreate: (db, version) async {
        for (final sql in schemaStatements) {
          await db.execute(sql);
        }
      },
    );
  }

  @override
  Future<T> runInTransaction<T>(
    Future<T> Function(LocalStoreTransaction txn) action,
  ) async {
    final db = _db;
    if (db == null) {
      throw StateError('Base de datos SQLite no inicializada');
    }
    return db.transaction((txn) async {
      return action(_SqfliteTransactionAdapter(txn));
    });
  }

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    String? where,
    List<Object?>? whereArgs,
    String? orderBy,
  }) async {
    final db = _db;
    if (db == null) {
      throw StateError('Base de datos SQLite no inicializada');
    }
    return db.query(
      table,
      where: where,
      whereArgs: whereArgs,
      orderBy: orderBy,
    );
  }

  @override
  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}

class _SqfliteTransactionAdapter implements LocalStoreTransaction {
  _SqfliteTransactionAdapter(this._txn);
  final Transaction _txn;

  @override
  Future<void> upsert(
    String table,
    String primaryKey,
    Map<String, Object?> values,
  ) async {
    await _txn.insert(
      table,
      values,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<void> delete(
    String table, {
    required String where,
    required List<Object?> whereArgs,
  }) async {
    await _txn.delete(table, where: where, whereArgs: whereArgs);
  }

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    String? where,
    List<Object?>? whereArgs,
  }) async {
    return _txn.query(table, where: where, whereArgs: whereArgs);
  }
}

/// Motor transaccional en memoria con semántica idéntica de llaves primarias y
/// rollback atómico para pruebas unitarias/widget o respaldo cuando el canal
/// nativo no está montado.
class InMemoryTransactionalStoreEngine implements LocalStoreEngine {
  final Map<String, Map<String, Map<String, Object?>>> _tables = {};
  bool _initialized = false;
  Future<void> _transactionTail = Future<void>.value();

  @override
  Future<void> init() async {
    if (_initialized) return;
    for (final name in const [
      'manual_location_local',
      'profiles_local',
      'publications_local',
      'recommendations_local',
      'help_offers_local',
      'conversations_local',
      'messages_local',
      'drafts_local',
      'outbox_operations',
      'community_resources_local',
      'support_groups_local',
      'cache_metadata',
      'practice_progress_local',
    ]) {
      _tables.putIfAbsent(name, () => <String, Map<String, Object?>>{});
    }
    _initialized = true;
  }

  @override
  Future<T> runInTransaction<T>(
    Future<T> Function(LocalStoreTransaction txn) action,
  ) async {
    final previous = _transactionTail;
    final release = Completer<void>();
    _transactionTail = release.future;
    await previous;
    // Snapshot profundo para garantizar atomicidad ante excepciones (rollback real)
    final snapshot = <String, Map<String, Map<String, Object?>>>{};
    for (final entry in _tables.entries) {
      snapshot[entry.key] = {
        for (final row in entry.value.entries)
          row.key: Map<String, Object?>.from(row.value),
      };
    }
    try {
      final txn = _InMemoryTransactionAdapter(_tables);
      return await action(txn);
    } catch (_) {
      _tables
        ..clear()
        ..addAll(snapshot);
      rethrow;
    } finally {
      release.complete();
    }
  }

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    String? where,
    List<Object?>? whereArgs,
    String? orderBy,
  }) async {
    final rows = (_tables[table]?.values ?? const <Map<String, Object?>>[])
        .map((r) => Map<String, Object?>.from(r))
        .where((row) => _matchesWhere(row, where, whereArgs))
        .toList();
    if (orderBy != null && orderBy.trim().isNotEmpty) {
      final parts = orderBy.trim().split(RegExp(r'\s+'));
      final col = parts.first;
      final desc = parts.length > 1 && parts[1].toUpperCase() == 'DESC';
      rows.sort((a, b) {
        final va = a[col]?.toString() ?? '';
        final vb = b[col]?.toString() ?? '';
        return desc ? vb.compareTo(va) : va.compareTo(vb);
      });
    }
    return rows;
  }

  @override
  Future<void> close() async {}
}

class _InMemoryTransactionAdapter implements LocalStoreTransaction {
  _InMemoryTransactionAdapter(this._tables);
  final Map<String, Map<String, Map<String, Object?>>> _tables;

  @override
  Future<void> upsert(
    String table,
    String primaryKey,
    Map<String, Object?> values,
  ) async {
    final tableMap = _tables.putIfAbsent(table, () => {});
    final keyVal = values[primaryKey]?.toString() ?? '';
    tableMap[keyVal] = Map<String, Object?>.from(values);
  }

  @override
  Future<void> delete(
    String table, {
    required String where,
    required List<Object?> whereArgs,
  }) async {
    final tableMap = _tables[table];
    if (tableMap == null) return;
    final keysToRemove = <String>[];
    for (final entry in tableMap.entries) {
      if (_matchesWhere(entry.value, where, whereArgs)) {
        keysToRemove.add(entry.key);
      }
    }
    for (final k in keysToRemove) {
      tableMap.remove(k);
    }
  }

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    String? where,
    List<Object?>? whereArgs,
  }) async {
    final tableMap = _tables[table];
    if (tableMap == null) return const [];
    return tableMap.values
        .where((row) => _matchesWhere(row, where, whereArgs))
        .map((row) => Map<String, Object?>.from(row))
        .toList();
  }
}

bool _matchesWhere(
  Map<String, Object?> row,
  String? where,
  List<Object?>? whereArgs,
) {
  if (where == null || where.trim().isEmpty) return true;
  final clauses = where.split(' AND ');
  var argIndex = 0;
  for (final rawClause in clauses) {
    final clause = rawClause.trim();
    if (clause.contains(' = ?')) {
      final col = clause.split(' = ?').first.trim();
      final expected = whereArgs != null && argIndex < whereArgs.length
          ? whereArgs[argIndex++]
          : null;
      if (row[col]?.toString() != expected?.toString()) {
        return false;
      }
    } else if (clause.contains(' <> ?')) {
      final col = clause.split(' <> ?').first.trim();
      final expected = whereArgs != null && argIndex < whereArgs.length
          ? whereArgs[argIndex++]
          : null;
      if (row[col]?.toString() == expected?.toString()) {
        return false;
      }
    }
  }
  return true;
}

/// Repositorio SQLite local con soporte offline-first, cola outbox transaccional,
/// borradores por usuario y aislamiento estricto entre cuentas.
class LocalSqliteDatabase {
  LocalSqliteDatabase({LocalStoreEngine? engine})
    : _engine = engine ?? SqfliteStoreEngine();

  final LocalStoreEngine _engine;

  Future<void> initAndSeedDemoData({bool seedDemo = true}) async {
    // Un fallo de disco debe ser visible: nunca sustituir persistencia por RAM.
    await _engine.init();
    if (!seedDemo) return;

    final existingPubs = await _engine.query('publications_local');
    if (existingPubs.isEmpty) {
      await _seedInitialDemoData();
    }
  }

  Future<void> _seedInitialDemoData() async {
    final now = DateTime.now().toUtc();
    final demoPublications = <Publication>[
      Publication(
        id: 'pub-demo-servicio-luis',
        clientMutationId: 'mut-demo-servicio-luis',
        ownerUserId: 'public_seed',
        authorId: 'user-demo-luis',
        authorAlias: 'Luis Alberto Mendoza',
        kind: PublicationKind.servicio,
        category: 'electricidad',
        title: 'Electricista domiciliario · Instalación y revisión',
        description: 'Instalación de llaves térmicas y diferenciales, reparación de cableado y tomacorrientes domiciliarios en Pueblo Libre. Atención previa coordinación vecinal.',
        neighborhood: 'Pueblo Libre',
        sector: 'Sector Sucre / Candamo',
        availabilityText: 'Lunes a Sábado de 8:00 am a 6:00 pm',
        priority: PublicationPriority.normal,
        status: PublicationStatus.abierta,
        approxLat: -12.074,
        approxLng: -77.065,
        recommendationCount: 2,
        syncStatus: SyncStatus.confirmado,
        isDemo: true,
        createdAt: now.subtract(const Duration(days: 5)),
        updatedAt: now.subtract(const Duration(hours: 2)),
      ),
      Publication(
        id: 'pub-demo-servicio-elena',
        clientMutationId: 'mut-demo-servicio-elena',
        ownerUserId: 'public_seed',
        authorId: 'user-demo-elena',
        authorAlias: 'Elena Flores',
        kind: PublicationKind.servicio,
        category: 'costura',
        title: 'Costuras, bastas y arreglos de ropa',
        description: 'Taller casero de costura, zurcido y arreglo de prendas para vecinos del barrio. Trato paciente y entregas puntuales.',
        neighborhood: 'Pueblo Libre',
        sector: 'Sector Sucre / Candamo',
        availabilityText: 'Lunes a Viernes de 9:00 am a 5:00 pm',
        priority: PublicationPriority.normal,
        status: PublicationStatus.abierta,
        approxLat: -12.075,
        approxLng: -77.064,
        recommendationCount: 1,
        syncStatus: SyncStatus.confirmado,
        isDemo: true,
        createdAt: now.subtract(const Duration(days: 4)),
        updatedAt: now.subtract(const Duration(hours: 4)),
      ),
      Publication(
        id: 'pub-demo-servicio-marcos',
        clientMutationId: 'mut-demo-servicio-marcos',
        ownerUserId: 'public_seed',
        authorId: 'user-demo-marcos',
        authorAlias: 'Marcos Tapia',
        kind: PublicationKind.servicio,
        category: 'jardineria',
        title: 'Cuidado de jardines, macetas y poda',
        description: 'Mantenimiento de jardines interiores, balcones y plantas ornamentales. Incluye limpieza de hojas al terminar.',
        neighborhood: 'Pueblo Libre',
        sector: 'Sector Plaza Bolívar',
        availabilityText: 'Mañanas de 8:00 am a 1:00 pm',
        priority: PublicationPriority.normal,
        status: PublicationStatus.abierta,
        approxLat: -12.077,
        approxLng: -77.062,
        recommendationCount: 1,
        syncStatus: SyncStatus.confirmado,
        isDemo: true,
        createdAt: now.subtract(const Duration(days: 3)),
        updatedAt: now.subtract(const Duration(hours: 6)),
      ),
      Publication(
        id: 'pub-demo-servicio-lejano',
        clientMutationId: 'mut-demo-servicio-lejano',
        ownerUserId: 'public_seed',
        authorId: 'user-demo-pedro',
        authorAlias: 'Pedro Quispe',
        kind: PublicationKind.servicio,
        category: 'gasfiteria',
        title: 'Gasfitería general en Jesús María (Sector Salaverry)',
        description: 'Reparación de fugas y grifería en sector alejado (> 2.5 km de Plaza Bolívar) para verificar filtro espacial por radio.',
        neighborhood: 'Jesús María',
        sector: 'Sector Residencial San Felipe',
        availabilityText: 'Lunes a Sábado',
        priority: PublicationPriority.normal,
        status: PublicationStatus.abierta,
        approxLat: -12.092,
        approxLng: -77.048,
        recommendationCount: 0,
        syncStatus: SyncStatus.confirmado,
        isDemo: true,
        createdAt: now.subtract(const Duration(days: 2)),
        updatedAt: now.subtract(const Duration(hours: 5)),
      ),
      Publication(
        id: 'pub-demo-favor-carmen',
        clientMutationId: 'mut-demo-favor-carmen',
        ownerUserId: 'public_seed',
        authorId: 'user-demo-carmen',
        authorAlias: 'Doña Carmen (72 años)',
        kind: PublicationKind.prestamo,
        category: 'herramientas',
        title: '¿Alguien tiene escalera de tijera por 2 horas?',
        description: 'Es para colocar unas cortinas en la sala y cambiar un foco alto del patio. Mi nieto la recoge y la devolvemos limpia hoy mismo por la tarde.',
        neighborhood: 'Pueblo Libre',
        sector: 'Sector San Martín',
        availabilityText: 'Hoy por la tarde (2 horas aprox.)',
        priority: PublicationPriority.normal,
        status: PublicationStatus.abierta,
        approxLat: -12.076,
        approxLng: -77.063,
        syncStatus: SyncStatus.confirmado,
        isDemo: true,
        createdAt: now.subtract(const Duration(minutes: 35)),
        updatedAt: now.subtract(const Duration(minutes: 35)),
      ),
      Publication(
        id: 'pub-demo-favor-manuel',
        clientMutationId: 'mut-demo-favor-manuel',
        ownerUserId: 'public_seed',
        authorId: 'user-demo-manuel',
        authorAlias: 'Don Manuel (68 años)',
        kind: PublicationKind.favorSolicitud,
        category: 'acompanamiento',
        title: 'Compañía para caminar por Parque Candamo',
        description: 'Caminata matutina suave de 30 minutos a paso tranquilo. Busco conversar y tomar aire fresco con algún vecino del barrio.',
        neighborhood: 'Pueblo Libre',
        sector: 'Sector Sucre / Candamo',
        availabilityText: 'Mañana a las 9:00 am',
        priority: PublicationPriority.normal,
        status: PublicationStatus.abierta,
        approxLat: -12.074,
        approxLng: -77.065,
        syncStatus: SyncStatus.confirmado,
        isDemo: true,
        createdAt: now.subtract(const Duration(hours: 2)),
        updatedAt: now.subtract(const Duration(hours: 2)),
      ),
      Publication(
        id: 'pub-demo-emergencia-hernan',
        clientMutationId: 'mut-demo-emergencia-hernan',
        ownerUserId: 'public_seed',
        authorId: 'user-demo-hernan',
        authorAlias: 'Don Hernán (81 años)',
        kind: PublicationKind.emergenciaSolicitud,
        category: 'primeros_auxilios_apoyo',
        title: 'Apoyo para adulto mayor que no puede bajar escaleras',
        description: 'Solicita apoyo vecinal para alcanzar compras de farmacia mientras se restablece el ascensor del edificio. Sin riesgo vital; reporte comunitario de demostración.',
        neighborhood: 'Pueblo Libre',
        sector: 'Sector San Martín',
        availabilityText: 'Atención prioritaria hoy',
        priority: PublicationPriority.emergencia,
        status: PublicationStatus.abierta,
        approxLat: -12.076,
        approxLng: -77.062,
        syncStatus: SyncStatus.confirmado,
        isDemo: true,
        createdAt: now.subtract(const Duration(minutes: 25)),
        updatedAt: now.subtract(const Duration(minutes: 25)),
      ),
    ];

    final demoRecommendations = <ServiceRecommendation>[
      ServiceRecommendation(
        id: 'rec-demo-1',
        clientMutationId: 'mut-rec-demo-1',
        ownerUserId: 'public_seed',
        publicationId: 'pub-demo-servicio-luis',
        userId: 'user-demo-maria',
        userAlias: 'Vecina María C.',
        comment: 'Don Luis vino puntual a cambiar una llave térmica de la cocina. Explicó con mucha calma el problema y dejó todo limpio.',
        syncStatus: SyncStatus.confirmado,
        createdAt: now.subtract(const Duration(days: 10)),
        updatedAt: now.subtract(const Duration(days: 10)),
      ),
      ServiceRecommendation(
        id: 'rec-demo-2',
        clientMutationId: 'mut-rec-demo-2',
        ownerUserId: 'public_seed',
        publicationId: 'pub-demo-servicio-luis',
        userId: 'user-demo-jorge',
        userAlias: 'Don Jorge A.',
        comment: 'Excelente disposición para revisar el tablero principal de la casa. Trato respetuoso y transparente.',
        syncStatus: SyncStatus.confirmado,
        createdAt: now.subtract(const Duration(days: 18)),
        updatedAt: now.subtract(const Duration(days: 18)),
      ),
      ServiceRecommendation(
        id: 'rec-demo-3',
        clientMutationId: 'mut-rec-demo-3',
        ownerUserId: 'public_seed',
        publicationId: 'pub-demo-servicio-elena',
        userId: 'user-demo-carmen',
        userAlias: 'Doña Carmen',
        comment: 'Arregló dos abrigos con mucho esmero. Muy recomendada en el barrio.',
        syncStatus: SyncStatus.confirmado,
        createdAt: now.subtract(const Duration(days: 7)),
        updatedAt: now.subtract(const Duration(days: 7)),
      ),
      ServiceRecommendation(
        id: 'rec-demo-4',
        clientMutationId: 'mut-rec-demo-4',
        ownerUserId: 'public_seed',
        publicationId: 'pub-demo-servicio-marcos',
        userId: 'user-demo-manuel',
        userAlias: 'Don Manuel',
        comment: 'Dejó las plantas del patio muy bien cuidadas y podadas.',
        syncStatus: SyncStatus.confirmado,
        createdAt: now.subtract(const Duration(days: 6)),
        updatedAt: now.subtract(const Duration(days: 6)),
      ),
    ];

    final demoResources = <CommunityResource>[
      CommunityResource(
        id: 'res-demo-plaza-bolivar',
        kind: 'punto_encuentro',
        title: 'Plaza Bolívar · Punto de referencia público',
        description: 'Espacio público abierto e iluminado. Lugar sugerido para entrega de préstamos o encuentro vecinal (condiciones en terreno sin confirmar).',
        neighborhood: 'Pueblo Libre',
        sector: 'Sector Plaza Bolívar',
        approxLat: -12.077,
        approxLng: -77.063,
        contactInfo: 'Vereda principal frente al municipio',
        sourceLabel: 'Referencia comunitaria · Demostración Pueblo Libre',
        isDemo: true,
        updatedAt: now,
      ),
      CommunityResource(
        id: 'res-demo-parque-candamo',
        kind: 'punto_encuentro',
        title: 'Parque Candamo · Punto de referencia público',
        description: 'Explanada central y pérgola de encuentro vecinal. Referencia pública sugerida; disponibilidad sin confirmar.',
        neighborhood: 'Pueblo Libre',
        sector: 'Sector Sucre / Candamo',
        approxLat: -12.074,
        approxLng: -77.065,
        contactInfo: 'Cruce Av. Sucre y Parque Candamo',
        sourceLabel: 'Referencia comunitaria · Demostración Pueblo Libre',
        isDemo: true,
        updatedAt: now,
      ),
      CommunityResource(
        id: 'res-demo-botiquin-san-martin',
        kind: 'recurso_comunitario',
        title: 'Punto solidario y botiquín básico · Sector San Martín',
        description: 'Recurso comunitario demostrativo compartido por comité vecinal voluntario. No garantiza atención médica ni despacho de unidades.',
        neighborhood: 'Pueblo Libre',
        sector: 'Sector San Martín',
        approxLat: -12.076,
        approxLng: -77.061,
        contactInfo: 'Coordinación previa por chat vecinal',
        sourceLabel: 'Dato ficticio de demostración · Sin confirmar',
        isDemo: true,
        updatedAt: now,
      ),
      CommunityResource(
        id: 'res-oficial-emergencias-peru',
        kind: 'directorio_oficial',
        title: 'Canales oficiales de emergencia (Perú)',
        description: 'Ante peligro vital, incendio o emergencia médica comunícate con los servicios públicos oficiales: Policía 105 · Bomberos 116 · SAMU 106 · INDECI 115. Esta app vecinal no moviliza rescate.',
        neighborhood: 'Pueblo Libre',
        sector: 'Todo el distrito',
        approxLat: -12.076,
        approxLng: -77.063,
        contactInfo: '105 Policía · 116 Bomberos · 106 SAMU · 115 INDECI',
        sourceLabel: 'Fuente oficial peruana (PNP / CGBVP / MINSA / INDECI)',
        isDemo: false,
        updatedAt: now,
      ),
    ];

    final demoGroups = <SupportGroup>[
      const SupportGroup(
        id: 'grp-demo-1',
        name: 'Brigada Vecinal Solidaria · Sector San Martín',
        description: 'Vecinos voluntarios para compras de farmacia, acompañamiento a personas mayores y préstamo de linternas o herramientas.',
        neighborhood: 'Pueblo Libre',
        sector: 'Sector San Martín',
        coordinatorLabel:
            'Coordinación voluntaria rotativa (Datos de demostración)',
        channelNote:
            'Apoyo solidario gratuito · No reemplaza a emergencias oficiales',
        isDemo: true,
      ),
      const SupportGroup(
        id: 'grp-demo-2',
        name: 'Red de Cuidado del Adulto Mayor · Parque Candamo',
        description: 'Acompañamiento en caminatas matutinas y aviso preventivo ante cortes de agua o electricidad en el sector.',
        neighborhood: 'Pueblo Libre',
        sector: 'Sector Sucre / Candamo',
        coordinatorLabel:
            'Comité vecinal Parque Candamo (Datos de demostración)',
        channelNote: 'Comunidad solidaria sin pagos ni cobros',
        isDemo: true,
      ),
    ];

    await _engine.runInTransaction((txn) async {
      for (final pub in demoPublications) {
        await txn.upsert('publications_local', 'id', pub.toSqlMap());
      }
      for (final rec in demoRecommendations) {
        await txn.upsert('recommendations_local', 'id', rec.toSqlMap());
      }
      for (final res in demoResources) {
        await txn.upsert('community_resources_local', 'id', res.toSqlMap());
      }
      for (final grp in demoGroups) {
        await txn.upsert('support_groups_local', 'id', grp.toSqlMap());
      }
      await txn.upsert('cache_metadata', 'cache_key', {
        'cache_key': 'initial_seed',
        'last_synced_at': now.toIso8601String(),
      });
    });
  }

  /// Guarda perfil local del usuario autenticado.
  Future<Map<String, Object?>?> readManualLocation() async {
    final rows = await _engine.query(
      'manual_location_local',
      where: 'id = ?',
      whereArgs: ['selected'],
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> saveManualLocation(Map<String, Object?> value) async {
    await _engine.runInTransaction(
      (txn) => txn.upsert('manual_location_local', 'id', {
        'id': 'selected',
        ...value,
      }),
    );
  }

  Future<void> saveUserProfile(
    UserProfile profile, {
    required bool queueSync,
  }) async {
    final now = DateTime.now().toUtc();
    await _engine.runInTransaction((txn) async {
      await txn.upsert('profiles_local', 'id', profile.toSqlMap());
      if (queueSync) {
        final op = OutboxOperation(
          operationId: 'profile-${profile.id}',
          ownerUserId: profile.id,
          entityType: 'profile',
          entityId: profile.id,
          action: 'upsert',
          payloadJson: jsonEncode(profile.toSqlMap()),
          syncStatus: SyncStatus.pendiente,
          createdAt: now,
          updatedAt: now,
        );
        await txn.upsert('outbox_operations', 'operation_id', op.toSqlMap());
      }
    });
  }

  Future<UserProfile?> getUserProfile(String userId) async {
    final rows = await _engine.query(
      'profiles_local',
      where: 'id = ?',
      whereArgs: [userId],
    );
    if (rows.isEmpty) return null;
    return UserProfile.fromSqlMap(rows.first);
  }

  /// Crea o actualiza una publicación localmente y registra su operación en la
  /// cola Outbox dentro de la MISMA transacción SQLite.
  /// Si se reintenta con el mismo [Publication.clientMutationId], no duplica
  /// la publicación ni la operación en la cola.
  Future<Publication> createOrUpdatePublicationTransactional(
    Publication publication,
  ) async {
    if (publication.kind == PublicationKind.emergenciaOferta &&
        !publication.shareResourceConsent) {
      throw StateError(
        'Compartir un recurso en emergencia requiere decisión explícita del usuario.',
      );
    }

    final now = DateTime.now().toUtc();
    return _engine.runInTransaction((txn) async {
      // Idempotencia local por client_mutation_id: si ya existe una fila con el
      // mismo client_mutation_id, reutilizamos su ID estable sin duplicar.
      final existingByMutation = await txn.query(
        'publications_local',
        where: 'client_mutation_id = ?',
        whereArgs: [publication.clientMutationId],
      );

      final effectiveId = existingByMutation.isNotEmpty
          ? (existingByMutation.first['id'] as String)
          : publication.id;

      final pendingPub = Publication(
        id: effectiveId,
        clientMutationId: publication.clientMutationId,
        ownerUserId: publication.ownerUserId,
        authorId: publication.authorId,
        authorAlias: publication.authorAlias,
        kind: publication.kind,
        category: publication.category,
        title: publication.title.trim(),
        description: publication.description.trim(),
        neighborhood: publication.neighborhood,
        sector: publication.sector,
        districtUbigeo: publication.districtUbigeo,
        availabilityText: publication.availabilityText.trim(),
        priority: publication.priority,
        status: publication.status,
        approxLat: AppConfig.roundOptionalPublicCoordinate(
          publication.approxLat,
        ),
        approxLng: AppConfig.roundOptionalPublicCoordinate(
          publication.approxLng,
        ),
        shareResourceConsent: publication.shareResourceConsent,
        shareServiceLocation: publication.shareServiceLocation,
        serviceLat: publication.serviceLat,
        serviceLng: publication.serviceLng,
        serviceAddress: publication.serviceAddress,
        recommendationCount: publication.recommendationCount,
        syncStatus: SyncStatus.pendiente,
        lastError: '',
        version: publication.version,
        isDemo: publication.isDemo,
        createdAt: publication.createdAt,
        updatedAt: now,
      );

      await txn.upsert('publications_local', 'id', pendingPub.toSqlMap());

      final outboxOp = OutboxOperation(
        operationId: pendingPub.clientMutationId,
        ownerUserId: pendingPub.ownerUserId,
        entityType: 'publication',
        entityId: pendingPub.id,
        action: 'upsert',
        payloadJson: jsonEncode(pendingPub.toSqlMap()),
        syncStatus: SyncStatus.pendiente,
        expectedVersion: pendingPub.version,
        createdAt: now,
        updatedAt: now,
      );

      await txn.upsert(
        'outbox_operations',
        'operation_id',
        outboxOp.toSqlMap(),
      );

      // Limpiar borrador asociado en la misma transacción una vez pasado a cola
      await txn.delete(
        'drafts_local',
        where: 'owner_user_id = ? AND draft_key = ?',
        whereArgs: [
          pendingPub.ownerUserId,
          '${pendingPub.ownerUserId}::${FormDraft.publicationKey(pendingPub.kind, pendingPub.category)}',
        ],
      );

      return pendingPub;
    });
  }

  Future<Publication> updatePublicationLocation({
    required String publicationId,
    required String actingUserId,
    required Map<String, Object?> location,
  }) async {
    return _engine.runInTransaction((txn) async {
      final rows = await txn.query(
        'publications_local',
        where: 'id = ?',
        whereArgs: [publicationId],
      );
      if (rows.isEmpty) {
        throw StateError('La publicación no está disponible en este teléfono.');
      }
      final current = Publication.fromSqlMap(rows.first);
      if (current.authorId != actingUserId) {
        throw StateError('Solo el autor puede ubicar su publicación.');
      }
      final share = location['share_service_location'] == true;
      if (share && !current.kind.isService) {
        throw StateError('Solo un servicio puede compartir un punto exacto.');
      }
      final now = DateTime.now().toUtc();
      final updated = current.copyWith(
        districtUbigeo: location['district_ubigeo'] as String,
        approxLat: (location['approx_lat'] as num).toDouble(),
        approxLng: (location['approx_lng'] as num).toDouble(),
        shareServiceLocation: share,
        serviceLat: (location['service_lat'] as num?)?.toDouble(),
        serviceLng: (location['service_lng'] as num?)?.toDouble(),
        serviceAddress: share ? location['service_address'] as String : '',
        syncStatus: SyncStatus.pendiente,
        version: current.version + 1,
        updatedAt: now,
      );
      await txn.upsert('publications_local', 'id', updated.toSqlMap());
      final op = OutboxOperation(
        operationId: EntityId.create(),
        ownerUserId: actingUserId,
        entityType: 'publication_location',
        entityId: publicationId,
        action: 'update',
        payloadJson: jsonEncode(location),
        syncStatus: SyncStatus.pendiente,
        expectedVersion: current.version,
        createdAt: now,
        updatedAt: now,
      );
      await txn.upsert('outbox_operations', 'operation_id', op.toSqlMap());
      return updated;
    });
  }

  /// Actualiza el estado de una publicación validando permisos de autor y
  /// transiciones permitidas (`abierta`, `en_coordinacion`, `resuelta`, `cancelada`).
  Future<Publication> editPublication({
    required String publicationId,
    required String actingUserId,
    required Map<String, Object?> changes,
    bool delete = false,
  }) async {
    return _engine.runInTransaction((txn) async {
      final rows = await txn.query(
        'publications_local',
        where: 'id = ?',
        whereArgs: [publicationId],
      );
      if (rows.isEmpty) throw StateError('La publicación no existe.');
      final current = Publication.fromSqlMap(rows.single);
      if (current.authorId != actingUserId) {
        throw StateError('Solo el autor puede cambiar su publicación.');
      }
      if (current.isDeleted) {
        throw StateError('La publicación ya fue eliminada.');
      }
      final now = DateTime.now().toUtc();
      if (delete) {
        final pending = await txn.query(
          'outbox_operations',
          where: 'entity_id = ? AND owner_user_id = ?',
          whereArgs: [publicationId, actingUserId],
        );
        final neverSent = pending.any(
          (row) =>
              row['entity_type'] == 'publication' &&
              row['attempts'] == 0 &&
              row['sync_status'] == 'pendiente',
        );
        if (neverSent) {
          // Una creación que nunca salió del teléfono se cancela sin publicarla.
          final cancelled = current.copyWith(
            deletedAt: now,
            syncStatus: SyncStatus.borrador,
            updatedAt: now,
          );
          await txn.upsert('publications_local', 'id', cancelled.toSqlMap());
          await txn.delete(
            'outbox_operations',
            where: 'entity_id = ? AND owner_user_id = ?',
            whereArgs: [publicationId, actingUserId],
          );
          final messages = await txn.query(
            'emergency_group_messages_local',
            where: 'owner_user_id = ? AND publication_id = ?',
            whereArgs: [actingUserId, publicationId],
          );
          for (final message in messages) {
            final draft = FormDraft(
              draftKey: 'cancelled_group_${message['id']}',
              ownerUserId: actingUserId,
              kind: current.kind,
              title: current.title,
              description: message['body'] as String,
              updatedAt: now,
            );
            final values = draft.toSqlMap();
            values['draft_key'] = '$actingUserId::${draft.draftKey}';
            await txn.upsert('drafts_local', 'draft_key', values);
            await txn.delete(
              'outbox_operations',
              where: 'operation_id = ?',
              whereArgs: [message['client_mutation_id']],
            );
            await txn.delete(
              'emergency_group_messages_local',
              where: 'cache_id = ?',
              whereArgs: [message['cache_id']],
            );
          }
          return cancelled;
        }
      }
      final updated = current.copyWith(
        title: changes['title'] as String?,
        description: changes['description'] as String?,
        category: changes['category'] as String?,
        availabilityText: changes['availability_text'] as String?,
        deletedAt: delete ? now : null,
        version: current.version + 1,
        syncStatus: SyncStatus.pendiente,
        lastError: '',
        updatedAt: now,
      );
      final op = OutboxOperation(
        operationId: EntityId.create(),
        ownerUserId: actingUserId,
        entityType: delete ? 'publication_delete' : 'publication_edit',
        entityId: publicationId,
        action: 'update',
        payloadJson: jsonEncode(
          delete
              ? <String, Object?>{}
              : {
                  'title': updated.title,
                  'description': updated.description,
                  'category': updated.category,
                  'availability_text': updated.availabilityText,
                },
        ),
        expectedVersion: current.version,
        syncStatus: SyncStatus.pendiente,
        createdAt: now,
        updatedAt: now,
      );
      await txn.upsert('publications_local', 'id', updated.toSqlMap());
      await txn.upsert('outbox_operations', 'operation_id', op.toSqlMap());
      return updated;
    });
  }

  Future<void> applyPublicationTombstones(
    List<Map<String, Object?>> rows,
  ) async {
    await _engine.runInTransaction((txn) async {
      for (final row in rows) {
        final found = await txn.query(
          'publications_local',
          where: 'id = ?',
          whereArgs: [row['publication_id']],
        );
        if (found.isEmpty) continue;
        final local = Publication.fromSqlMap(found.single);
        // Una eliminación confirmada prevalece; el borrador conflictivo queda en la cola.
        final deleted = local.copyWith(
          deletedAt: DateTime.parse(row['deleted_at'] as String),
        );
        await txn.upsert('publications_local', 'id', deleted.toSqlMap());
      }
    });
  }

  Future<Publication> transitionPublicationStatus({
    required String publicationId,
    required String actingUserId,
    required PublicationStatus newStatus,
  }) async {
    return _engine.runInTransaction((txn) async {
      final rows = await txn.query(
        'publications_local',
        where: 'id = ?',
        whereArgs: [publicationId],
      );
      if (rows.isEmpty) {
        throw StateError('La publicación no existe.');
      }
      final current = Publication.fromSqlMap(rows.first);
      if (current.authorId != actingUserId) {
        throw StateError(
          'Solo el autor puede cambiar el estado de su publicación.',
        );
      }
      if (current.status != newStatus &&
          !current.status.allowedNextStatuses.contains(newStatus)) {
        throw StateError(
          'Transición no permitida de ${current.status.label} a ${newStatus.label}.',
        );
      }

      final now = DateTime.now().toUtc();
      final updated = current.copyWith(
        status: newStatus,
        syncStatus: SyncStatus.pendiente,
        version: current.version + 1,
        updatedAt: now,
      );

      await txn.upsert('publications_local', 'id', updated.toSqlMap());

      final outboxOp = OutboxOperation(
        operationId: '${updated.clientMutationId}-status-${updated.version}',
        ownerUserId: actingUserId,
        entityType: 'publication_status',
        entityId: updated.id,
        action: 'update_status',
        payloadJson: jsonEncode(updated.toSqlMap()),
        syncStatus: SyncStatus.pendiente,
        expectedVersion: current.version,
        createdAt: now,
        updatedAt: now,
      );
      await txn.upsert(
        'outbox_operations',
        'operation_id',
        outboxOp.toSqlMap(),
      );
      return updated;
    });
  }

  /// Consulta publicaciones visibles para el usuario activo (datos públicos/demo
  /// más las publicaciones propias pendientes de ese usuario, nunca los
  /// pendientes privados de otra cuenta distinta).
  Future<List<Publication>> listPublications({
    required String activeUserId,
    PublicationKind? kind,
    String? category,
    String? searchQuery,
    double? originLat,
    double? originLng,
    double? maxRadiusMeters,
  }) async {
    final rows = await _engine.query(
      'publications_local',
      orderBy: 'created_at DESC',
    );
    final result = <Publication>[];
    for (final row in rows) {
      final pub = Publication.fromSqlMap(row);
      if (pub.isDeleted) continue;
      // Si es una publicación no confirmada de otra cuenta local, no mostrarla
      if (!pub.syncStatus.isConfirmed &&
          pub.ownerUserId != 'public_seed' &&
          pub.ownerUserId != activeUserId) {
        continue;
      }
      if (kind != null && pub.kind != kind) continue;
      if (category != null &&
          category.isNotEmpty &&
          category != 'todos' &&
          pub.category != category) {
        continue;
      }
      if (searchQuery != null && searchQuery.trim().isNotEmpty) {
        final q = searchQuery.trim().toLowerCase();
        final matches =
            pub.title.toLowerCase().contains(q) ||
            pub.description.toLowerCase().contains(q) ||
            pub.sector.toLowerCase().contains(q) ||
            pub.authorAlias.toLowerCase().contains(q);
        if (!matches) continue;
      }
      if (originLat != null &&
          originLng != null &&
          maxRadiusMeters != null &&
          maxRadiusMeters > 0) {
        final dist = pub.distanceFrom(lat: originLat, lng: originLng);
        if (dist == null || dist > maxRadiusMeters) continue;
      }
      result.add(pub);
    }
    return result;
  }

  /// Registra o modifica una recomendación vecinal.
  /// Reglas estrictas:
  /// - Los productos solo admiten recomendaciones del mismo distrito y sector.
  /// - Prohibida la auto-recomendación (`authorId == userId`).
  /// - Máximo una recomendación por `(publicationId, userId)`.
  Future<ServiceRecommendation> submitOrUpdateRecommendation({
    required String id,
    required String clientMutationId,
    required String publicationId,
    required String userId,
    required String userAlias,
    required String comment,
    bool allowUpdateExisting = false,
  }) async {
    return _engine.runInTransaction((txn) async {
      final pubRows = await txn.query(
        'publications_local',
        where: 'id = ?',
        whereArgs: [publicationId],
      );
      if (pubRows.isEmpty) {
        throw StateError('El servicio indicado no existe.');
      }
      final pub = Publication.fromSqlMap(pubRows.first);
      if (pub.isDeleted) throw StateError('La publicación fue eliminada.');
      if (!pub.kind.isService && !pub.isProduct) {
        throw StateError(
          'Solo se pueden recomendar servicios y productos del directorio.',
        );
      }
      if (pub.authorId == userId) {
        throw StateError(
          pub.isProduct
              ? 'No puedes recomendar tu propio producto.'
              : 'No puedes recomendar tu propio servicio.',
        );
      }
      if (pub.isProduct) {
        final profiles = await txn.query(
          'profiles_local',
          where: 'id = ?',
          whereArgs: [userId],
        );
        if (profiles.isEmpty ||
            !pub.isInSameZoneAs(UserProfile.fromSqlMap(profiles.single))) {
          throw StateError(
            'Solo pueden recomendar este producto los vecinos del mismo distrito y sector.',
          );
        }
      }

      final existingRows = await txn.query(
        'recommendations_local',
        where: 'publication_id = ? AND user_id = ?',
        whereArgs: [publicationId, userId],
      );

      if (existingRows.isNotEmpty && !allowUpdateExisting) {
        throw StateError(
          'Ya registraste una recomendación. Puedes modificarla o retirarla.',
        );
      }

      final now = DateTime.now().toUtc();
      final effectiveId = existingRows.isNotEmpty
          ? (existingRows.first['id'] as String)
          : id;
      final effectiveMutationId = existingRows.isNotEmpty
          ? (existingRows.first['client_mutation_id'] as String)
          : clientMutationId;

      final rec = ServiceRecommendation(
        id: effectiveId,
        clientMutationId: effectiveMutationId,
        ownerUserId: userId,
        publicationId: publicationId,
        userId: userId,
        userAlias: userAlias,
        comment: comment.trim(),
        syncStatus: SyncStatus.pendiente,
        createdAt: existingRows.isNotEmpty
            ? DateTime.parse(existingRows.first['created_at'] as String)
            : now,
        updatedAt: now,
      );

      await txn.upsert('recommendations_local', 'id', rec.toSqlMap());

      // Los productos muestran solo vistos buenos confirmados.
      if (existingRows.isEmpty && !pub.isProduct) {
        final updatedPub = pub.copyWith(
          recommendationCount: pub.recommendationCount + 1,
          updatedAt: now,
        );
        await txn.upsert('publications_local', 'id', updatedPub.toSqlMap());
      }

      final op = OutboxOperation(
        operationId: rec.clientMutationId,
        ownerUserId: userId,
        entityType: 'recommendation',
        entityId: rec.id,
        action: 'upsert',
        payloadJson: jsonEncode(rec.toSqlMap()),
        syncStatus: SyncStatus.pendiente,
        createdAt: now,
        updatedAt: now,
      );
      await txn.upsert('outbox_operations', 'operation_id', op.toSqlMap());
      return rec;
    });
  }

  /// Permite retirar la propia recomendación sobre un servicio.
  Future<void> withdrawRecommendation({
    required String publicationId,
    required String userId,
  }) async {
    await _engine.runInTransaction((txn) async {
      final existingRows = await txn.query(
        'recommendations_local',
        where: 'publication_id = ? AND user_id = ?',
        whereArgs: [publicationId, userId],
      );
      if (existingRows.isEmpty) {
        throw StateError(
          'No tienes una recomendación activa en esta publicación.',
        );
      }
      final existing = ServiceRecommendation.fromSqlMap(existingRows.first);
      await txn.delete(
        'recommendations_local',
        where: 'id = ?',
        whereArgs: [existing.id],
      );

      final pubRows = await txn.query(
        'publications_local',
        where: 'id = ?',
        whereArgs: [publicationId],
      );
      final pub = pubRows.isEmpty
          ? null
          : Publication.fromSqlMap(pubRows.first);
      if (pub != null && !pub.isProduct) {
        final updatedPub = pub.copyWith(
          recommendationCount: pub.recommendationCount > 0
              ? pub.recommendationCount - 1
              : 0,
          updatedAt: DateTime.now().toUtc(),
        );
        await txn.upsert('publications_local', 'id', updatedPub.toSqlMap());
      }

      final now = DateTime.now().toUtc();
      final op = OutboxOperation(
        operationId: 'del-${existing.clientMutationId}',
        ownerUserId: userId,
        entityType: 'recommendation',
        entityId: existing.id,
        action: 'delete',
        payloadJson: jsonEncode(existing.toSqlMap()),
        syncStatus: SyncStatus.pendiente,
        createdAt: now,
        updatedAt: now,
      );
      await txn.upsert('outbox_operations', 'operation_id', op.toSqlMap());
    });
  }

  Future<List<ServiceRecommendation>> listRecommendationsForService(
    String publicationId,
  ) async {
    final rows = await _engine.query(
      'recommendations_local',
      where: 'publication_id = ?',
      whereArgs: [publicationId],
      orderBy: 'created_at DESC',
    );
    return rows.map(ServiceRecommendation.fromSqlMap).toList();
  }

  Future<List<ServiceRecommendation>> listRecommendationsByUser(
    String userId,
  ) async {
    final rows = await _engine.query(
      'recommendations_local',
      where: 'user_id = ?',
      whereArgs: [userId],
      orderBy: 'updated_at DESC',
    );
    return rows.map(ServiceRecommendation.fromSqlMap).toList();
  }

  /// Envía una oferta gratuita de ayuda solidaria en una transacción local + outbox.
  Future<HelpOffer> submitHelpOffer({
    required String id,
    required String clientMutationId,
    required String publicationId,
    required String helperId,
    required String helperAlias,
    required String note,
    String resourceShared = '',
    bool explicitShareConsent = false,
  }) async {
    if (resourceShared.trim().isNotEmpty && !explicitShareConsent) {
      throw StateError(
        'Para compartir un recurso debes marcar explícitamente tu consentimiento.',
      );
    }

    return _engine.runInTransaction((txn) async {
      final pubRows = await txn.query(
        'publications_local',
        where: 'id = ?',
        whereArgs: [publicationId],
      );
      if (pubRows.isEmpty) {
        throw StateError('La solicitud ya no está disponible.');
      }
      final pub = Publication.fromSqlMap(pubRows.first);
      if (pub.isDeleted) throw StateError('La publicación fue eliminada.');
      if (pub.authorId == helperId) {
        throw StateError(
          'No puedes enviar una oferta de ayuda a tu propia solicitud.',
        );
      }
      if (pub.status == PublicationStatus.resuelta ||
          pub.status == PublicationStatus.cancelada) {
        throw StateError(
          'Esta solicitud ya fue ${pub.status.label.toLowerCase()}.',
        );
      }

      final existing = await txn.query(
        'help_offers_local',
        where: 'publication_id = ? AND helper_id = ?',
        whereArgs: [publicationId, helperId],
      );

      final now = DateTime.now().toUtc();
      final effectiveId = existing.isNotEmpty
          ? (existing.first['id'] as String)
          : id;
      final effectiveMutationId = existing.isNotEmpty
          ? (existing.first['client_mutation_id'] as String)
          : clientMutationId;

      final offer = HelpOffer(
        id: effectiveId,
        clientMutationId: effectiveMutationId,
        ownerUserId: helperId,
        publicationId: publicationId,
        helperId: helperId,
        helperAlias: helperAlias,
        note: note.trim(),
        resourceShared: resourceShared.trim(),
        explicitShareConsent: explicitShareConsent,
        status: OfferStatus.enviada,
        syncStatus: SyncStatus.pendiente,
        createdAt: now,
        updatedAt: now,
      );

      await txn.upsert('help_offers_local', 'id', offer.toSqlMap());

      if (pub.status == PublicationStatus.abierta) {
        final updatedPub = pub.copyWith(
          status: PublicationStatus.enCoordinacion,
          updatedAt: now,
        );
        await txn.upsert('publications_local', 'id', updatedPub.toSqlMap());
      }

      final op = OutboxOperation(
        operationId: offer.clientMutationId,
        ownerUserId: helperId,
        entityType: 'help_offer',
        entityId: offer.id,
        action: 'upsert',
        payloadJson: jsonEncode(offer.toSqlMap()),
        syncStatus: SyncStatus.pendiente,
        createdAt: now,
        updatedAt: now,
      );
      await txn.upsert('outbox_operations', 'operation_id', op.toSqlMap());
      return offer;
    });
  }

  Future<List<HelpOffer>> listOffersForPublication(String publicationId) async {
    final rows = await _engine.query(
      'help_offers_local',
      where: 'publication_id = ?',
      whereArgs: [publicationId],
      orderBy: 'created_at DESC',
    );
    return rows.map(HelpOffer.fromSqlMap).toList();
  }

  Future<List<HelpOffer>> listOffersByUser(String userId) async {
    final rows = await _engine.query(
      'help_offers_local',
      where: 'helper_id = ?',
      whereArgs: [userId],
      orderBy: 'updated_at DESC',
    );
    return rows.map(HelpOffer.fromSqlMap).toList();
  }

  /// Abre o recupera una conversación contextual única entre dos participantes
  /// autenticados sobre una publicación o solicitud.
  static Future<void> _recordChatActivity(
    LocalStoreTransaction txn,
    String owner,
    String chatKey,
    DateTime date,
  ) async {
    final key = 'chat_activity:$owner:$chatKey';
    final old = await txn.query(
      'cache_metadata',
      where: 'cache_key = ?',
      whereArgs: [key],
    );
    final previous = old.isEmpty
        ? null
        : DateTime.tryParse(old.first['last_synced_at'] as String);
    if (previous == null || date.isAfter(previous)) {
      await txn.upsert('cache_metadata', 'cache_key', {
        'cache_key': key,
        'last_synced_at': date.toUtc().toIso8601String(),
      });
    }
  }

  Future<Map<String, DateTime>> readChatActivity(String owner) async {
    final rows = await _engine.query('cache_metadata');
    final prefix = 'chat_activity:$owner:';
    return {
      for (final row in rows)
        if ((row['cache_key'] as String).startsWith(prefix))
          (row['cache_key'] as String).substring(prefix.length): DateTime.parse(
            row['last_synced_at'] as String,
          ),
    };
  }

  Future<void> mergeChatActivity(
    String owner,
    Map<String, DateTime> activity,
  ) async {
    await _engine.runInTransaction((txn) async {
      for (final entry in activity.entries) {
        await _recordChatActivity(txn, owner, entry.key, entry.value);
      }
    });
  }

  Future<void> migrateNeighborChatPreferences(String owner) async {
    final threads = await listConversationsForUser(owner);
    final redirects = {
      for (final thread in threads)
        for (final type in ['pin', 'hidden'])
          'chat_$type:$owner:private:${thread.id}':
              'chat_$type:$owner:neighbor:${thread.peerIdFor(owner)}',
    };
    await _engine.runInTransaction((txn) async {
      final rows = await txn.query('cache_metadata');
      for (final row in rows) {
        final oldKey = row['cache_key'] as String,
            key = redirects[row['cache_key']];
        if (key == null) continue;
        await txn.upsert('cache_metadata', 'cache_key', {
          'cache_key': key,
          'last_synced_at': row['last_synced_at'],
        });
        await txn.delete(
          'cache_metadata',
          where: 'cache_key = ?',
          whereArgs: [oldKey],
        );
      }
    });
  }

  /// Preferencias privadas de este teléfono, separadas por cuenta y tipo de chat.
  Future<({Set<String> pinned, Set<String> hidden})> readChatPreferences(
    String owner,
  ) async {
    final rows = await _engine.query('cache_metadata');
    Set<String> keys(String type) {
      final prefix = 'chat_$type:$owner:';
      return rows
          .map((row) => row['cache_key'] as String)
          .where((key) => key.startsWith(prefix))
          .map((key) => key.substring(prefix.length))
          .toSet();
    }

    return (pinned: keys('pin'), hidden: keys('hidden'));
  }

  Future<void> saveChatPreference({
    required String owner,
    required String chatKey,
    bool? pinned,
    bool? hidden,
  }) async {
    if (owner.isEmpty ||
        !(chatKey.startsWith('private:') ||
            chatKey.startsWith('neighbor:') ||
            chatKey.startsWith('group:'))) {
      throw StateError('Selecciona un chat de tu cuenta.');
    }
    await _engine.runInTransaction((txn) async {
      for (final setting in {
        'pin': hidden == true ? false : pinned,
        'hidden': hidden,
      }.entries) {
        if (setting.value == null) continue;
        final key = 'chat_${setting.key}:$owner:$chatKey';
        if (setting.value!) {
          await txn.upsert('cache_metadata', 'cache_key', {
            'cache_key': key,
            'last_synced_at': DateTime.now().toUtc().toIso8601String(),
          });
        } else {
          await txn.delete(
            'cache_metadata',
            where: 'cache_key = ?',
            whereArgs: [key],
          );
        }
      }
    });
  }

  Future<void> markEmergencyGroupVisited(
    String owner,
    String publicationId,
  ) async {
    await _engine.runInTransaction((txn) async {
      await txn.upsert('cache_metadata', 'cache_key', {
        'cache_key': 'group_visit:$owner:$publicationId',
        'last_synced_at': DateTime.now().toUtc().toIso8601String(),
      });
    });
  }

  Future<Set<String>> visitedEmergencyGroups(String owner) async {
    final rows = await _engine.query('cache_metadata');
    final prefix = 'group_visit:$owner:';
    return rows
        .map((r) => r['cache_key'] as String)
        .where((k) => k.startsWith(prefix))
        .map((k) => k.substring(prefix.length))
        .toSet();
  }

  Future<List<EmergencyGroupMessage>> listEmergencyGroupMessages(
    String owner,
    String publicationId,
  ) async {
    final rows = await _engine.query(
      'emergency_group_messages_local',
      where: 'owner_user_id = ? AND publication_id = ?',
      whereArgs: [owner, publicationId],
      orderBy: 'created_at ASC',
    );
    return rows.map(EmergencyGroupMessage.fromMap).toList()..sort((a, b) {
      final result = a.createdAt.compareTo(b.createdAt);
      return result == 0 ? a.id.compareTo(b.id) : result;
    });
  }

  Future<EmergencyGroupMessage> saveEmergencyGroupMessage({
    required String owner,
    required String publicationId,
    required String senderAlias,
    required String body,
  }) async {
    if (body.trim().isEmpty || body.trim().length > 1000) {
      throw StateError('Escribe un mensaje de hasta 1000 caracteres.');
    }
    final now = DateTime.now().toUtc();
    final id = EntityId.create();
    final message = EmergencyGroupMessage(
      id: id,
      clientMutationId: id,
      publicationId: publicationId,
      senderId: owner,
      senderAlias: senderAlias,
      body: body.trim(),
      createdAt: now,
      syncStatus: SyncStatus.pendiente,
    );
    await _engine.runInTransaction((txn) async {
      await txn.upsert('emergency_group_messages_local', 'cache_id', {
        'cache_id': '$owner:$id',
        'owner_user_id': owner,
        ...message.toMap(),
      });
      await txn.delete(
        'drafts_local',
        where: 'draft_key = ?',
        whereArgs: ['$owner::group_$publicationId'],
      );
      final op = OutboxOperation(
        operationId: id,
        ownerUserId: owner,
        entityType: 'emergency_group_message',
        entityId: id,
        action: 'insert',
        payloadJson: jsonEncode(message.toMap()),
        syncStatus: SyncStatus.pendiente,
        createdAt: now,
        updatedAt: now,
      );
      await txn.upsert('outbox_operations', 'operation_id', op.toSqlMap());
      await _recordChatActivity(
        txn,
        owner,
        'group:$publicationId',
        message.createdAt,
      );
    });
    return message;
  }

  Future<void> mergeEmergencyGroupMessages(
    String owner,
    List<EmergencyGroupMessage> messages,
  ) async {
    await _engine.runInTransaction((txn) async {
      for (final message in messages) {
        final old = await txn.query(
          'emergency_group_messages_local',
          where: 'cache_id = ?',
          whereArgs: ['$owner:${message.id}'],
        );
        if (old.isNotEmpty && old.single['sync_status'] != 'confirmado') {
          continue;
        }
        await txn.upsert('emergency_group_messages_local', 'cache_id', {
          'cache_id': '$owner:${message.id}',
          'owner_user_id': owner,
          ...message.toMap(),
        });
        await _recordChatActivity(
          txn,
          owner,
          'group:${message.publicationId}',
          message.createdAt,
        );
      }
    });
  }

  Future<ConversationThread> openOrGetConversation({
    required String id,
    required String clientMutationId,
    required Publication publication,
    required String participantId,
    required String participantAlias,
  }) async {
    if (publication.authorId == participantId) {
      throw StateError(
        'No puedes iniciar una conversación privada contigo mismo.',
      );
    }

    return _engine.runInTransaction((txn) async {
      final rows = await txn.query('conversations_local');
      final existing =
          rows
              .map(ConversationThread.fromSqlMap)
              .where(
                (thread) =>
                    thread.involvesUser(participantId) &&
                    thread.peerIdFor(participantId) == publication.authorId,
              )
              .toList()
            ..sort((a, b) => a.id.compareTo(b.id));
      if (existing.isNotEmpty) return existing.first;

      final now = DateTime.now().toUtc();
      final thread = ConversationThread(
        id: id,
        clientMutationId: clientMutationId,
        ownerUserId: participantId,
        publicationId: publication.id,
        publicationTitle: publication.title,
        publicationAuthorId: publication.authorId,
        publicationAuthorAlias: publication.authorAlias,
        participantId: participantId,
        participantAlias: participantAlias,
        syncStatus: SyncStatus.pendiente,
        updatedAt: now,
      );

      await txn.upsert('conversations_local', 'id', thread.toSqlMap());

      final op = OutboxOperation(
        operationId: thread.clientMutationId,
        ownerUserId: participantId,
        entityType: 'conversation',
        entityId: thread.id,
        action: 'upsert',
        payloadJson: jsonEncode(thread.toSqlMap()),
        syncStatus: SyncStatus.pendiente,
        createdAt: now,
        updatedAt: now,
      );
      await txn.upsert('outbox_operations', 'operation_id', op.toSqlMap());
      return thread;
    });
  }

  /// Lista únicamente las conversaciones donde `userId` es uno de los dos
  /// participantes (`publicationAuthorId` o `participantId`). Un tercero ajeno
  /// recibe cero conversaciones.
  Future<List<ConversationThread>> listConversationsForUser(
    String userId,
  ) async {
    final allRows = await _engine.query(
      'conversations_local',
      orderBy: 'updated_at DESC',
    );
    return allRows
        .map(ConversationThread.fromSqlMap)
        .where((c) => c.involvesUser(userId))
        .toList();
  }

  /// Consulta los mensajes de una conversación verificando que `actingUserId`
  /// sea participante legítimo. Un tercero recibe [StateError].
  Future<List<ChatMessage>> listMessagesForConversation({
    required String conversationId,
    required String actingUserId,
  }) async {
    final convRows = await _engine.query(
      'conversations_local',
      where: 'id = ?',
      whereArgs: [conversationId],
    );
    if (convRows.isEmpty) {
      throw StateError('La conversación no existe.');
    }
    final conv = ConversationThread.fromSqlMap(convRows.first);
    if (!conv.involvesUser(actingUserId)) {
      throw StateError(
        'Acceso denegado: no eres participante de esta conversación privada.',
      );
    }

    final peers = await listConversationsForUser(actingUserId);
    final peer = conv.peerIdFor(actingUserId);
    final msgRows = <Map<String, Object?>>[];
    for (final thread in peers.where(
      (t) => t.peerIdFor(actingUserId) == peer,
    )) {
      msgRows.addAll(
        await _engine.query(
          'messages_local',
          where: 'conversation_id = ?',
          whereArgs: [thread.id],
        ),
      );
    }
    return msgRows.map(ChatMessage.fromSqlMap).toList()..sort((a, b) {
      final byTime = a.createdAt.compareTo(b.createdAt);
      return byTime == 0 ? a.id.compareTo(b.id) : byTime;
    });
  }

  /// Guarda un mensaje cuando hay conexión activa confirmada o para sincronizar.
  /// Regla del encargo: "Mensajes offline no se envían: indica que requieren
  /// conexión y conserva el texto como borrador si procede."
  Future<ChatMessage> recordOnlineMessage({
    required String id,
    required String clientMutationId,
    required String conversationId,
    required String senderId,
    required String senderAlias,
    required String body,
    required SyncStatus syncStatus,
    DateTime? createdAt,
  }) async {
    return _engine.runInTransaction((txn) async {
      final convRows = await txn.query(
        'conversations_local',
        where: 'id = ?',
        whereArgs: [conversationId],
      );
      if (convRows.isEmpty) {
        throw StateError('La conversación no existe.');
      }
      final conv = ConversationThread.fromSqlMap(convRows.first);
      if (!conv.involvesUser(senderId)) {
        throw StateError(
          'Acceso denegado: un tercero no puede escribir en esta conversación.',
        );
      }

      final msg = ChatMessage(
        id: id,
        clientMutationId: clientMutationId,
        ownerUserId: senderId,
        conversationId: conversationId,
        senderId: senderId,
        senderAlias: senderAlias,
        body: body.trim(),
        syncStatus: syncStatus,
        createdAt: createdAt ?? DateTime.now().toUtc(),
      );

      await txn.upsert('messages_local', 'id', msg.toSqlMap());
      for (final owner in [conv.publicationAuthorId, conv.participantId]) {
        await _recordChatActivity(
          txn,
          owner,
          'neighbor:${conv.peerIdFor(owner)}',
          msg.createdAt,
        );
      }
      return msg;
    });
  }

  /// Guarda un borrador de formulario o mensaje offline por usuario.
  Future<void> saveDraft(FormDraft draft) async {
    await _engine.runInTransaction((txn) async {
      // Usamos clave compuesta en drafts_local pero para nuestro helper upsert:
      final compositeMap = Map<String, Object?>.from(draft.toSqlMap());
      compositeMap['draft_key'] = '${draft.ownerUserId}::${draft.draftKey}';
      await txn.upsert('drafts_local', 'draft_key', compositeMap);
    });
  }

  Future<void> consolidateNeighborDrafts(
    String owner,
    String conversationId,
  ) async {
    await _engine.runInTransaction((txn) async {
      final rows = await txn.query('conversations_local');
      final threads = rows
          .map(ConversationThread.fromSqlMap)
          .where((t) => t.involvesUser(owner))
          .toList();
      final selected = threads.where((t) => t.id == conversationId).firstOrNull;
      if (selected == null) return;
      final keys = {
        for (final t in threads)
          if (t.peerIdFor(owner) == selected.peerIdFor(owner))
            '$owner::chat_${t.id}',
      };
      final drafts = (await txn.query(
        'drafts_local',
        where: 'owner_user_id = ?',
        whereArgs: [owner],
      )).where((d) => keys.contains(d['draft_key'])).toList();
      if (drafts.isEmpty) return;
      final text = drafts
          .map((d) => d['description'] as String)
          .where((t) => t.isNotEmpty)
          .toSet()
          .join('\n\n');
      final target = '$owner::chat_$conversationId';
      await txn.upsert('drafts_local', 'draft_key', {
        ...drafts.first,
        'draft_key': target,
        'description': text,
      });
      for (final draft in drafts) {
        if (draft['draft_key'] != target) {
          await txn.delete(
            'drafts_local',
            where: 'draft_key = ?',
            whereArgs: [draft['draft_key']],
          );
        }
      }
    });
  }

  Future<FormDraft?> getDraft({
    required String ownerUserId,
    required String draftKey,
  }) async {
    final rows = await _engine.query(
      'drafts_local',
      where: 'draft_key = ?',
      whereArgs: ['$ownerUserId::$draftKey'],
    );
    if (rows.isEmpty) return null;
    final map = Map<String, Object?>.from(rows.first);
    map['draft_key'] = draftKey;
    return FormDraft.fromSqlMap(map);
  }

  Future<List<FormDraft>> listDraftsForUser(String ownerUserId) async {
    final rows = await _engine.query(
      'drafts_local',
      where: 'owner_user_id = ?',
      whereArgs: [ownerUserId],
      orderBy: 'updated_at DESC',
    );
    return rows.map((row) {
      final copy = Map<String, Object?>.from(row);
      final rawKey = (copy['draft_key'] as String?) ?? '';
      if (rawKey.contains('::')) {
        copy['draft_key'] = rawKey.split('::').last;
      }
      return FormDraft.fromSqlMap(copy);
    }).toList();
  }

  Future<void> deleteDraft({
    required String ownerUserId,
    required String draftKey,
  }) async {
    await _engine.runInTransaction((txn) async {
      await txn.delete(
        'drafts_local',
        where: 'draft_key = ?',
        whereArgs: ['$ownerUserId::$draftKey'],
      );
    });
  }

  /// Obtiene operaciones pendientes exclusivamente de [ownerUserId].
  /// Jamás devuelve operaciones de otra cuenta al cambiar de usuario.
  Future<List<OutboxOperation>> listOutboxForUser(String ownerUserId) async {
    final rows = await _engine.query(
      'outbox_operations',
      where: 'owner_user_id = ?',
      whereArgs: [ownerUserId],
      orderBy: 'created_at ASC',
    );
    return rows.map(OutboxOperation.fromSqlMap).toList();
  }

  /// Actualiza el estado de una operación en la cola Outbox y de la entidad
  /// local asociada (confirmado, enviando, error o conflicto).
  Future<void> updateOutboxAndEntityStatus({
    required String operationId,
    required SyncStatus newStatus,
    String lastError = '',
    int? confirmedServerVersion,
    String? expectedPayloadJson,
  }) async {
    final now = DateTime.now().toUtc();
    await _engine.runInTransaction((txn) async {
      final opRows = await txn.query(
        'outbox_operations',
        where: 'operation_id = ?',
        whereArgs: [operationId],
      );
      if (opRows.isEmpty) return;
      final op = OutboxOperation.fromSqlMap(opRows.first);
      if (expectedPayloadJson != null &&
          op.payloadJson != expectedPayloadJson) {
        return;
      }

      if (newStatus == SyncStatus.confirmado) {
        await txn.delete(
          'outbox_operations',
          where: 'operation_id = ?',
          whereArgs: [operationId],
        );
      } else {
        final updatedOp = OutboxOperation(
          operationId: op.operationId,
          ownerUserId: op.ownerUserId,
          entityType: op.entityType,
          entityId: op.entityId,
          action: op.action,
          payloadJson: op.payloadJson,
          syncStatus: newStatus,
          attempts: op.attempts + (newStatus == SyncStatus.enviando ? 1 : 0),
          lastError: lastError,
          expectedVersion: op.expectedVersion,
          createdAt: op.createdAt,
          updatedAt: now,
        );
        await txn.upsert(
          'outbox_operations',
          'operation_id',
          updatedOp.toSqlMap(),
        );
      }

      if (op.entityType == 'publication' ||
          op.entityType == 'publication_status' ||
          op.entityType == 'publication_location' ||
          op.entityType == 'publication_edit' ||
          op.entityType == 'publication_delete') {
        final pubRows = await txn.query(
          'publications_local',
          where: 'id = ?',
          whereArgs: [op.entityId],
        );
        if (pubRows.isNotEmpty) {
          final pub = Publication.fromSqlMap(pubRows.first);
          final related = await txn.query(
            'outbox_operations',
            where: 'entity_id = ? AND owner_user_id = ?',
            whereArgs: [op.entityId, op.ownerUserId],
          );
          final hasOtherPending = related.any(
            (row) =>
                row['operation_id'] != op.operationId &&
                row['sync_status'] != 'confirmado',
          );
          final updatedPub = pub.copyWith(
            syncStatus: newStatus == SyncStatus.confirmado && hasOtherPending
                ? SyncStatus.pendiente
                : newStatus,
            lastError: lastError,
            version: hasOtherPending
                ? pub.version
                : confirmedServerVersion ?? pub.version,
            updatedAt: now,
          );
          await txn.upsert('publications_local', 'id', updatedPub.toSqlMap());
        }
      } else if (op.entityType == 'recommendation') {
        final recRows = await txn.query(
          'recommendations_local',
          where: 'id = ?',
          whereArgs: [op.entityId],
        );
        if (recRows.isNotEmpty) {
          final map = Map<String, Object?>.from(recRows.first);
          map['sync_status'] = newStatus.dbValue;
          map['last_error'] = lastError;
          map['updated_at'] = now.toIso8601String();
          await txn.upsert('recommendations_local', 'id', map);
        }
      } else if (op.entityType == 'help_offer') {
        final offerRows = await txn.query(
          'help_offers_local',
          where: 'id = ?',
          whereArgs: [op.entityId],
        );
        if (offerRows.isNotEmpty) {
          final map = Map<String, Object?>.from(offerRows.first);
          map['sync_status'] = newStatus.dbValue;
          map['last_error'] = lastError;
          map['updated_at'] = now.toIso8601String();
          await txn.upsert('help_offers_local', 'id', map);
        }
      } else if (op.entityType == 'emergency_group_message') {
        final key = '${op.ownerUserId}:${op.entityId}';
        final rows = await txn.query(
          'emergency_group_messages_local',
          where: 'cache_id = ?',
          whereArgs: [key],
        );
        if (rows.isNotEmpty) {
          final row = Map<String, Object?>.from(rows.single);
          row['sync_status'] = newStatus.dbValue;
          row['last_error'] = lastError;
          await txn.upsert('emergency_group_messages_local', 'cache_id', row);
        }
      } else if (op.entityType == 'conversation') {
        final convRows = await txn.query(
          'conversations_local',
          where: 'id = ?',
          whereArgs: [op.entityId],
        );
        if (convRows.isNotEmpty) {
          final map = Map<String, Object?>.from(convRows.first);
          map['sync_status'] = newStatus.dbValue;
          map['updated_at'] = now.toIso8601String();
          await txn.upsert('conversations_local', 'id', map);
        }
      }

      if (newStatus == SyncStatus.confirmado) {
        await txn.upsert('cache_metadata', 'cache_key', {
          'cache_key': 'last_remote_sync',
          'last_synced_at': now.toIso8601String(),
        });
      }
    });
  }

  /// Almacena publicaciones descargadas desde Supabase sin sobrescribir
  /// silenciosamente ediciones locales pendientes (detecta conflicto si la
  /// versión remota diverge de una publicación con cambios locales pendientes).
  Future<void> mergeRemotePublications(List<Publication> remoteList) async {
    final now = DateTime.now().toUtc();
    await _engine.runInTransaction((txn) async {
      for (final remote in remoteList) {
        final row = remote.toSqlMap();
        final localRows = await txn.query(
          'publications_local',
          where: 'id = ?',
          whereArgs: [remote.id],
        );
        if (localRows.isNotEmpty) {
          final local = Publication.fromSqlMap(localRows.first);
          if (!local.syncStatus.isConfirmed) continue;
          if (local.isDeleted && !remote.isDeleted) continue;
          if (remote.isGuestReport &&
              local.ownerUserId == Publication.guestOwnerId) {
            row['owner_user_id'] = Publication.guestOwnerId;
          }
        }
        await txn.upsert('publications_local', 'id', row);
      }
      await txn.upsert('cache_metadata', 'cache_key', {
        'cache_key': 'last_remote_sync',
        'last_synced_at': now.toIso8601String(),
      });
    });
  }

  /// La elección del usuario conserva el texto local en un borrador antes de cargar el servidor.
  Future<void> keepDraftAndAcceptRemote(
    Publication remote,
    String ownerId,
  ) async {
    await _engine.runInTransaction((txn) async {
      final rows = await txn.query(
        'publications_local',
        where: 'id = ?',
        whereArgs: [remote.id],
      );
      if (rows.isEmpty) return;
      final local = Publication.fromSqlMap(rows.first);
      if (local.authorId != ownerId || remote.authorId != ownerId) {
        throw StateError('Solo puedes revisar tus publicaciones.');
      }
      final draft = FormDraft(
        draftKey: 'conflict_${local.id}',
        ownerUserId: ownerId,
        kind: local.kind,
        title: local.title,
        description: local.description,
        category: local.category,
        availabilityText: local.availabilityText,
        updatedAt: DateTime.now().toUtc(),
      );
      final values = draft.toSqlMap();
      values['draft_key'] = '$ownerId::${draft.draftKey}';
      await txn.upsert('drafts_local', 'draft_key', values);
      await txn.delete(
        'outbox_operations',
        where: 'owner_user_id = ? AND entity_id = ?',
        whereArgs: [ownerId, remote.id],
      );
      await txn.upsert('publications_local', 'id', remote.toSqlMap());
    });
  }

  Future<void> mergeCommunitySnapshot(
    Map<String, List<Map<String, Object?>>> snapshot,
  ) async {
    await _engine.runInTransaction((txn) async {
      for (final entry in snapshot.entries) {
        final table = '${entry.key}_local';
        for (final row in entry.value) {
          final existing = await txn.query(
            table,
            where: 'id = ?',
            whereArgs: [row['id']],
          );
          if (existing.isNotEmpty &&
              existing.first['sync_status'] != null &&
              existing.first['sync_status'] != 'confirmado') {
            continue;
          }
          Map<String, Object?> values;
          switch (entry.key) {
            case 'recommendations':
              values = ServiceRecommendation.fromSqlMap(row).toSqlMap();
            case 'help_offers':
              values = HelpOffer.fromSqlMap(row).toSqlMap();
            case 'conversations':
              values = ConversationThread.fromSqlMap(row).toSqlMap();
            case 'community_resources':
              values = CommunityResource.fromSqlMap(row).toSqlMap();
            case 'support_groups':
              values = SupportGroup.fromSqlMap(row).toSqlMap();
            default:
              continue;
          }
          await txn.upsert(table, 'id', values);
        }
      }
    });
  }

  Future<List<CommunityResource>> listCommunityResources({
    String? neighborhood,
    String? kind,
  }) async {
    final rows = await _engine.query('community_resources_local');
    return rows.map(CommunityResource.fromSqlMap).where((r) {
      if (neighborhood != null &&
          neighborhood.isNotEmpty &&
          r.neighborhood != neighborhood) {
        return false;
      }
      if (kind != null && kind.isNotEmpty && r.kind != kind) {
        return false;
      }
      return true;
    }).toList();
  }

  Future<List<SupportGroup>> listSupportGroups({String? neighborhood}) async {
    final rows = await _engine.query('support_groups_local');
    return rows.map(SupportGroup.fromSqlMap).where((g) {
      if (neighborhood != null &&
          neighborhood.isNotEmpty &&
          g.neighborhood != neighborhood) {
        return false;
      }
      return true;
    }).toList();
  }

  Future<DateTime?> getLastSyncTimestamp() async {
    final rows = await _engine.query(
      'cache_metadata',
      where: 'cache_key = ?',
      whereArgs: ['last_remote_sync'],
    );
    if (rows.isNotEmpty) {
      return DateTime.tryParse((rows.first['last_synced_at'] as String?) ?? '');
    }
    final seedRows = await _engine.query(
      'cache_metadata',
      where: 'cache_key = ?',
      whereArgs: ['initial_seed'],
    );
    if (seedRows.isNotEmpty) {
      return DateTime.tryParse(
        (seedRows.first['last_synced_at'] as String?) ?? '',
      );
    }
    return null;
  }

  /// Limpia la caché privada (conversaciones y mensajes de la sesión saliente)
  /// al cerrar sesión, manteniendo aislados por `owner_user_id` los pendientes.
  Future<void> clearPrivateCacheOnSignOut(String signedOutUserId) async {
    await _engine.runInTransaction((txn) async {
      final groupRows = await txn.query(
        'emergency_group_messages_local',
        where: 'owner_user_id = ?',
        whereArgs: [signedOutUserId],
      );
      for (final row in groupRows) {
        if (row['sync_status'] == 'confirmado') {
          await txn.delete(
            'emergency_group_messages_local',
            where: 'cache_id = ?',
            whereArgs: [row['cache_id']],
          );
        }
      }
      final conversations = await txn.query('conversations_local');
      for (final row in conversations) {
        final conversation = ConversationThread.fromSqlMap(row);
        if (conversation.involvesUser(signedOutUserId)) {
          await txn.delete(
            'messages_local',
            where: 'conversation_id = ?',
            whereArgs: [conversation.id],
          );
          await txn.delete(
            'conversations_local',
            where: 'id = ?',
            whereArgs: [conversation.id],
          );
        }
      }
    });
  }

  /// Guarda progreso local de práctica en tabla separada (`practice_progress_local`).
  Future<void> savePracticeProgress(
    String scenarioId,
    List<String> completedMissions,
  ) async {
    final now = DateTime.now().toUtc();
    await _engine.runInTransaction((txn) async {
      await txn.upsert('practice_progress_local', 'scenario_id', {
        'scenario_id': scenarioId,
        'completed_missions_json': jsonEncode(completedMissions),
        'updated_at': now.toIso8601String(),
      });
    });
  }

  Future<List<String>> getPracticeProgress(String scenarioId) async {
    final rows = await _engine.query(
      'practice_progress_local',
      where: 'scenario_id = ?',
      whereArgs: [scenarioId],
    );
    if (rows.isEmpty) return const [];
    final raw = (rows.first['completed_missions_json'] as String?) ?? '[]';
    final decoded = jsonDecode(raw) as List<dynamic>;
    return decoded.map((e) => e.toString()).toList();
  }
}
