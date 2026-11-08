import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../core/accessibility/accessibility_controller.dart';
import '../../core/models/domain_models.dart';
import '../../core/theme/app_theme.dart';
import '../../core/maps/carto_basemap.dart';
import '../../core/maps/explore_map_controller.dart';
import '../maps/neighborhood_map.dart';

/// Cabecera cívica accesible presente en toda la app:
/// - Nombre de la aplicación centralizado
/// - Zona barrial activa
/// - Control `A / A+` de tamaño de letra (`>= 48x48dp`)
/// - Acceso a perfil / sesión (`>= 48x48dp`)
class CivicAppBar extends StatelessWidget implements PreferredSizeWidget {
  const CivicAppBar({
    super.key,
    required this.title,
    required this.neighborhoodLabel,
    required this.accessibilityController,
    required this.onProfileTap,
    this.showBackButton = false,
    this.onBackTap,
    this.isOffline = false,
    this.onToggleOfflineTap,
    this.height = 112,
  });
  final String title;
  final String neighborhoodLabel;
  final AccessibilityController accessibilityController;
  final VoidCallback onProfileTap;
  final bool showBackButton;
  final VoidCallback? onBackTap;
  final bool isOffline;
  final VoidCallback? onToggleOfflineTap;
  final double height;
  @override
  Size get preferredSize => Size.fromHeight(height);
  @override
  Widget build(BuildContext context) => Material(
    color: AppTheme.surfaceCard,
    child: SafeArea(
      bottom: false,
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  TextButton(
                    key: const Key('btn_toggle_text_scale'),
                    onPressed: accessibilityController.toggleLargeText,
                    child: Text(
                      accessibilityController.isLargeTextEnabled
                          ? 'A+'
                          : 'A/A+',
                      semanticsLabel: 'Cambiar tamaño del texto',
                    ),
                  ),
                  IconButton(
                    key: const Key('btn_open_profile'),
                    onPressed: onProfileTap,
                    tooltip: 'Mi perfil y actividades',
                    icon: const Icon(Icons.person_outline),
                  ),
                ],
              ),
              if (showBackButton)
                TextButton.icon(
                  key: const Key('btn_volver_appbar'),
                  onPressed: onBackTap,
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('Volver'),
                ),
              Text(neighborhoodLabel, style: const TextStyle(fontSize: 16)),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Etiqueta accesible de estado de sincronización que combina SIEMPRE ícono +
/// texto explícito (nunca usa solo color).
class SyncStatusBadge extends StatelessWidget {
  const SyncStatusBadge({
    super.key,
    required this.status,
    this.isEmergency = false,
  });

  final SyncStatus status;
  final bool isEmergency;

  @override
  Widget build(BuildContext context) {
    late final Color bg;
    late final Color fg;
    late final IconData icon;
    late final String text;

    switch (status) {
      case SyncStatus.confirmado:
        bg = const Color(0xFFDDF7E8);
        fg = AppTheme.actionGreen;
        icon = Icons.check_circle_outline;
        text = isEmergency
            ? 'Reporte comunicado a la comunidad'
            : 'Confirmado en el barrio';
        break;
      case SyncStatus.borrador:
      case SyncStatus.pendiente:
        bg = const Color(0xFFFFF3CD);
        fg = AppTheme.amberWarning;
        icon = Icons.cloud_off;
        text = isEmergency
            ? 'Guardado en este teléfono · Aún NO comunicado (sin conexión)'
            : 'Guardado en este teléfono · Pendiente de sincronizar';
        break;
      case SyncStatus.enviando:
        bg = const Color(0xFFE0F2FE);
        fg = AppTheme.practiceBlue;
        icon = Icons.sync;
        text = 'Enviando al servidor…';
        break;
      case SyncStatus.error:
        bg = const Color(0xFFFEE2E2);
        fg = AppTheme.urgentRed;
        icon = Icons.error_outline;
        text = 'Error de envío · Toca Reintentar en Mis actividades';
        break;
      case SyncStatus.conflicto:
        bg = const Color(0xFFFEE2E2);
        fg = AppTheme.urgentRed;
        icon = Icons.warning_amber_rounded;
        text = 'Conflicto de versión · Requiere revisión';
        break;
    }

    return Semantics(
      label: 'Estado de sincronización: $text',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: fg.withValues(alpha: 0.45)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: fg),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                text,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: fg,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Etiqueta accesible de estado de publicación (`Abierta`, `En coordinación`,
/// `Resuelta`, `Cancelada`) con ícono + texto.
class PublicationStatusBadge extends StatelessWidget {
  const PublicationStatusBadge({super.key, required this.status});

  final PublicationStatus status;

  @override
  Widget build(BuildContext context) {
    late final Color bg;
    late final Color fg;
    late final IconData icon;

    switch (status) {
      case PublicationStatus.abierta:
        bg = const Color(0xFFDDF7E8);
        fg = AppTheme.actionGreen;
        icon = Icons.radio_button_checked;
        break;
      case PublicationStatus.enCoordinacion:
        bg = const Color(0xFFFFF3CD);
        fg = AppTheme.amberWarning;
        icon = Icons.handshake_outlined;
        break;
      case PublicationStatus.resuelta:
        bg = const Color(0xFFE2E8F0);
        fg = AppTheme.textPrimary;
        icon = Icons.task_alt;
        break;
      case PublicationStatus.cancelada:
        bg = const Color(0xFFFEE2E2);
        fg = AppTheme.urgentRed;
        icon = Icons.cancel_outlined;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: fg.withValues(alpha: 0.4)),
      ),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Icon(icon, size: 18, color: fg),
          const SizedBox(width: 6),
          Text(
            status.label,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }
}

/// Tarjeta permanente con líneas oficiales peruanas de emergencia (`105`, `116`,
/// `106`, `115`) y aclaración ética de que la app no despacha rescate.
class OfficialEmergencyChannelsCard extends StatelessWidget {
  const OfficialEmergencyChannelsCard({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8F6),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.urgentRed, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.phone_in_talk, color: AppTheme.urgentRed, size: 24),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Emergencias Oficiales (Perú)',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.urgentRed,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Ante riesgo de vida, incendio o urgencia médica llama a los canales públicos oficiales. Esta red vecinal es solidaria y NO moviliza unidades de rescate.',
            style: TextStyle(
              fontSize: 16,
              color: AppTheme.textPrimary,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: const [
              _OfficialNumberChip(number: '105', agency: 'Policía PNP'),
              _OfficialNumberChip(number: '116', agency: 'Bomberos CGBVP'),
              _OfficialNumberChip(number: '106', agency: 'SAMU Médico'),
              _OfficialNumberChip(
                number: '115',
                agency: 'INDECI Defensa Civil',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _OfficialNumberChip extends StatelessWidget {
  const _OfficialNumberChip({required this.number, required this.agency});

  final String number;
  final String agency;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Línea oficial $number $agency',
      child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.urgentRed),
        ),
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              number,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w900,
                color: AppTheme.urgentRed,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              agency,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: AppTheme.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Mapa accesible por cuadrantes barriales con equivalente completo en lista
/// navegable por teclado, TalkBack y VoiceOver.
class AccessibleQuadrantMapWidget extends StatelessWidget {
  const AccessibleQuadrantMapWidget({
    super.key,
    required this.publications,
    required this.originLat,
    required this.originLng,
    required this.onSelectPublication,
    this.privateLocation,
    this.online = false,
  });
  final List<Publication> publications;
  final double? originLat;
  final double? originLng;
  final ValueChanged<Publication> onSelectPublication;
  final LatLng? privateLocation;
  final bool online;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        'Ubicaciones aproximadas',
        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
      ),
      const Text(
        'También puedes elegir un resultado en la lista de abajo. El mapa necesita internet.',
      ),
      NeighborhoodMap(
        online: online,
        records: publications.map(NeighborhoodMapRecord.publication).toList(),
        center: privateLocation ?? approximateMapPoint(originLat, originLng),
        privateLocation: privateLocation,
        onSelect: (record) => onSelectPublication(record.publication!),
      ),
      for (final publication in publications)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: OutlinedButton(
            onPressed: () => onSelectPublication(publication),
            child: Text(
              '${publication.title}\n${publication.sector} · ${publication.distanceLabelFrom(lat: originLat, lng: originLng)}',
              textAlign: TextAlign.left,
            ),
          ),
        ),
      if (publications.isEmpty) const Text('No hay resultados en esta zona.'),
    ],
  );
}
