import '../database/local_sqlite_database.dart';
import '../models/domain_models.dart';
import 'supabase_remote_gateway.dart';

/// Resumen de ejecución del motor de sincronización Outbox.
class OutboxSyncSummary {
  const OutboxSyncSummary({
    required this.confirmedCount,
    required this.pendingCount,
    required this.errorCount,
    required this.conflictCount,
    this.lastMessage = '',
  });

  final int confirmedCount;
  final int pendingCount;
  final int errorCount;
  final int conflictCount;
  final String lastMessage;

  bool get allConfirmed =>
      pendingCount == 0 && errorCount == 0 && conflictCount == 0;
}

/// Motor de sincronización de la cola local (`outbox_operations`) hacia Supabase.
/// Garantiza:
/// 1. Solo procesa operaciones cuyo `owner_user_id` coincide exactamente con el
///    usuario activo o la cola local de invitado.
/// 2. Transición verificable `pendiente` -> `enviando` -> `confirmado` | `error` | `conflicto`.
/// 3. Idempotencia ante reintentos manuales o reconexión.
class OutboxSyncService {
  OutboxSyncService({required this.database, required this.remoteGateway});

  final LocalSqliteDatabase database;
  final RemoteBackendGateway remoteGateway;

  bool networkAvailable = true;
  bool _isSyncing = false;
  bool get isSyncing => _isSyncing;

  /// Procesa las operaciones pendientes de la cuenta o invitado indicado.
  Future<OutboxSyncSummary> syncPendingForUser(
    String activeUserId, {
    String? onlyOperationId,
    String? onlyEntityId,
  }) async {
    if (activeUserId.trim().isEmpty) {
      return const OutboxSyncSummary(
        confirmedCount: 0,
        pendingCount: 0,
        errorCount: 0,
        conflictCount: 0,
        lastMessage: 'Inicia sesión para sincronizar tus envíos pendientes.',
      );
    }

    if (_isSyncing || !networkAvailable) {
      final currentOps = await database.listOutboxForUser(activeUserId);
      return OutboxSyncSummary(
        confirmedCount: 0,
        pendingCount: currentOps.length,
        errorCount: 0,
        conflictCount: 0,
        lastMessage: 'Sincronización en curso…',
      );
    }

    _isSyncing = true;
    var confirmed = 0;
    var lastMsg = '';

    try {
      final operations = await database.listOutboxForUser(activeUserId);
      final selected = operations
          .where((op) => op.operationId == onlyOperationId)
          .firstOrNull;
      final blocked = <String>{};
      for (final op in operations) {
        if (!networkAvailable) break;
        if (blocked.contains(op.entityId)) continue;
        if (onlyEntityId != null && op.entityId != onlyEntityId) continue;
        if (onlyOperationId != null && op.entityId != selected?.entityId) {
          continue;
        }
        // Verificación defensiva de aislamiento entre cuentas
        if (op.ownerUserId != activeUserId) {
          continue;
        }

        // Un conflicto necesita revisión explícita, no un reintento automático.
        if (op.syncStatus == SyncStatus.conflicto) {
          blocked.add(op.entityId);
          continue;
        }
        // Paso 1: marcar como `enviando`
        await database.updateOutboxAndEntityStatus(
          operationId: op.operationId,
          expectedPayloadJson: op.payloadJson,
          newStatus: SyncStatus.enviando,
        );

        // Paso 2: enviar al gateway remoto con llave de idempotencia
        RemoteSyncResult result;
        try {
          result = await remoteGateway
              .pushOutboxOperation(op)
              .timeout(const Duration(seconds: 15));
        } catch (_) {
          result = const RemoteSyncResult(
            status: SyncStatus.error,
            errorMessage:
                'No se pudo confirmar el envío. Tu contenido sigue guardado.',
          );
        }

        // Paso 3: reflejar resultado real en SQLite (`confirmado`, `pendiente`, `error`, `conflicto`)
        await database.updateOutboxAndEntityStatus(
          operationId: op.operationId,
          expectedPayloadJson: op.payloadJson,
          newStatus: result.status,
          lastError: result.errorMessage,
          confirmedServerVersion: result.confirmedVersion,
        );

        if (result.status != SyncStatus.confirmado) blocked.add(op.entityId);
        switch (result.status) {
          case SyncStatus.confirmado:
            confirmed++;
            lastMsg = 'Sincronizado y comunicado a la comunidad.';
            break;
          case SyncStatus.borrador:
          case SyncStatus.pendiente:
          case SyncStatus.enviando:
            lastMsg = result.errorMessage;
            break;
          case SyncStatus.error:
            lastMsg = result.errorMessage;
            break;
          case SyncStatus.conflicto:
            lastMsg = result.errorMessage;
            break;
        }
        if (op.operationId == onlyOperationId) break;
      }
    } finally {
      _isSyncing = false;
    }

    final remaining = await database.listOutboxForUser(activeUserId);
    final remPending = remaining
        .where(
          (o) =>
              o.syncStatus == SyncStatus.pendiente ||
              o.syncStatus == SyncStatus.enviando,
        )
        .length;
    final remErrors = remaining
        .where((o) => o.syncStatus == SyncStatus.error)
        .length;
    final remConflicts = remaining
        .where((o) => o.syncStatus == SyncStatus.conflicto)
        .length;

    return OutboxSyncSummary(
      confirmedCount: confirmed,
      pendingCount: remPending,
      errorCount: remErrors,
      conflictCount: remConflicts,
      lastMessage: lastMsg,
    );
  }
}
