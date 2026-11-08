import '../../core/accessibility/text_input_support.dart';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../core/maps/carto_basemap.dart';
import '../../core/maps/map_location_service.dart';

import '../../core/models/domain_models.dart';
import '../../core/state/app_controller.dart';
import '../../core/theme/app_theme.dart';
import '../shared/civic_widgets.dart';

/// Directorio barrial de oficios, servicios y productos con filtro por
/// categoría, búsqueda textual, radio espacial (PostGIS / distancia aproximada)
/// y alternancia entre Lista y Mapa accesible por cuadrantes.
class ServicesDirectoryScreen extends StatefulWidget {
  const ServicesDirectoryScreen({
    super.key,
    required this.controller,
    this.locationService,
  });

  final AppController controller;
  final MapLocationService? locationService;

  @override
  State<ServicesDirectoryScreen> createState() =>
      _ServicesDirectoryScreenState();
}

class _ServicesDirectoryScreenState extends State<ServicesDirectoryScreen> {
  AppController get controller => widget.controller;
  late final TextEditingController _searchController;
  LatLng? _privateLocation;
  bool _locating = false;
  bool _loading = false;
  bool _refreshFailed = false;
  String? _locationNotice;
  int _refreshRequest = 0;

  LatLng? get _origin => _privateLocation == null
      ? approximateMapPoint(controller.directoryLat, controller.directoryLng)
      : approximateMapPoint(
          _privateLocation!.latitude,
          _privateLocation!.longitude,
        );

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController(
      text: controller.serviceSearchQuery,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refresh();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (!controller.isAuthenticated ||
        controller.isOfflineMode ||
        !controller.remoteGateway.isLiveSupabaseConnected ||
        (_origin == null && controller.activeDistrictUbigeo == null)) {
      return;
    }
    final request = ++_refreshRequest;
    setState(() {
      _loading = true;
      _refreshFailed = false;
    });
    try {
      final origin = _origin;
      await controller.refreshServiceDirectory(
        nearLat: origin?.latitude,
        nearLng: origin?.longitude,
      );
    } catch (_) {
      if (mounted && request == _refreshRequest) {
        setState(() => _refreshFailed = true);
      }
    } finally {
      if (mounted && request == _refreshRequest) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _locate() async {
    setState(() {
      _locating = true;
      _locationNotice = null;
    });
    try {
      final point = await (widget.locationService ?? MapLocationService())
          .locatePrecise();
      if (!mounted) return;
      if (point == null) {
        setState(
          () => _locationNotice = 'Activa la ubicación del teléfono y permite el acceso a Conecta2 para ver tu posición.',
        );
        return;
      }
      setState(() {
        _privateLocation = point;
        _locationNotice = 'El punto azul es tu ubicación y solo tú lo ves.';
      });
      await _refresh();
    } catch (_) {
      if (mounted) {
        setState(
          () => _locationNotice = 'No pudimos obtener tu ubicación. Puedes seguir buscando por la zona de tu perfil.',
        );
      }
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  static const List<MapEntry<String, String>> categories = [
    MapEntry('todos', 'Todos los oficios'),
    MapEntry(Publication.productCategory, 'Productos'),
    MapEntry('electricidad', 'Electricidad'),
    MapEntry('costura', 'Costura y ropa'),
    MapEntry('jardineria', 'Jardinería'),
    MapEntry('gasfiteria', 'Gasfitería'),
  ];

  static const List<MapEntry<double?, String>> radiusOptions = [
    MapEntry(null, 'Todo el barrio'),
    MapEntry(600, 'Hasta 600 m'),
    MapEntry(1200, 'Hasta 1.2 km'),
    MapEntry(3000, 'Hasta 3 km'),
  ];

  @override
  Widget build(BuildContext context) {
    final origin = _origin;
    final services = controller.directoryServices(
      nearLat: origin?.latitude,
      nearLng: origin?.longitude,
    );
    final missingZone =
        origin == null && controller.activeDistrictUbigeo == null;
    final showingProducts =
        controller.serviceCategoryFilter == Publication.productCategory;

    return SingleChildScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppTheme.surfaceCard,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppTheme.borderSoft),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Directorio de productos y servicios del barrio',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Encuentra productos cercanos y servicios recomendados. Abre una ficha para ver los detalles o contactar a quien publica.',
                  style: TextStyle(fontSize: 16, color: AppTheme.textSecondary),
                ),
                const SizedBox(height: 12),
                TextField(
                  contextMenuBuilder: buildTextSelectionToolbar,
                  onTapOutside: dismissTextInput,
                  key: const Key('input_search_services'),
                  controller: _searchController,
                  onChanged: (q) =>
                      controller.updateServiceFilters(searchQuery: q),
                  style: const TextStyle(fontSize: 18),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    labelText: 'Buscar por producto, oficio, nombre o sector',
                    hintText: 'Ej. Mochila, electricista, Candamo…',
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Categoría:',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final entry in categories)
                      ChoiceChip(
                        key: Key('chip_service_cat_${entry.key}'),
                        label: Text(
                          entry.value,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: controller.serviceCategoryFilter == entry.key
                                ? Colors.white
                                : AppTheme.textPrimary,
                          ),
                        ),
                        selected: controller.serviceCategoryFilter == entry.key,
                        selectedColor: AppTheme.actionGreen,
                        backgroundColor: AppTheme.surfaceContainer,
                        onSelected: (_) => controller.updateServiceFilters(
                          category: entry.key,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  _privateLocation == null
                      ? 'Distancia máxima desde tu zona:'
                      : 'Distancia máxima desde tu ubicación:',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final rad in radiusOptions)
                      ChoiceChip(
                        key: Key('chip_radius_${rad.key?.toInt() ?? 0}'),
                        label: Text(
                          rad.value,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: controller.serviceRadiusMeters == rad.key
                                ? Colors.white
                                : AppTheme.textPrimary,
                          ),
                        ),
                        selected: controller.serviceRadiusMeters == rad.key,
                        selectedColor: AppTheme.actionGreen,
                        backgroundColor: AppTheme.surfaceContainer,
                        onSelected: (_) => controller.updateServiceFilters(
                          radiusMeters: rad.key,
                          clearRadius: rad.key == null,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const Key('btn_toggle_service_map_view'),
                        onPressed: () => controller.updateServiceFilters(
                          mapQuadrantView: !controller.serviceMapQuadrantView,
                        ),
                        icon: Icon(
                          controller.serviceMapQuadrantView
                              ? Icons.view_list_outlined
                              : Icons.map_outlined,
                        ),
                        label: Text(
                          controller.serviceMapQuadrantView
                              ? 'Ver como lista detallada'
                              : 'Ver en mapa por cuadrantes',
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 14),
          if (controller.serviceMapQuadrantView) ...[
            OutlinedButton.icon(
              key: const Key('btn_locate_service_map'),
              onPressed: _locating ? null : _locate,
              icon: const Icon(Icons.my_location),
              label: Text(
                _locating ? 'Buscando tu ubicación…' : 'Mi ubicación',
              ),
            ),
            if (_locationNotice != null)
              Semantics(liveRegion: true, child: Text(_locationNotice!)),
            const SizedBox(height: 8),
            AccessibleQuadrantMapWidget(
              online:
                  controller.remoteGateway.isLiveSupabaseConnected &&
                  !controller.isOfflineMode,
              publications: services,
              originLat: origin?.latitude,
              originLng: origin?.longitude,
              privateLocation: _privateLocation,
              onSelectPublication: controller.openServiceDetail,
            ),
            const SizedBox(height: 14),
          ],

          if (controller.isAuthenticated && missingZone)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text(
                'Elige un distrito en tu perfil o toca «Mi ubicación» en el mapa para buscar cerca.',
              ),
            ),
          if (controller.isAuthenticated &&
              missingZone &&
              !controller.serviceMapQuadrantView)
            OutlinedButton.icon(
              onPressed: _locating
                  ? null
                  : () {
                      controller.updateServiceFilters(mapQuadrantView: true);
                      _locate();
                    },
              icon: const Icon(Icons.my_location),
              label: const Text('Buscar cerca de mí'),
            ),
          if (_loading) const LinearProgressIndicator(),
          if (_refreshFailed) ...[
            const Text(
              'No pudimos actualizar el directorio. Puedes consultar los resultados guardados.',
            ),
            TextButton(
              onPressed: _refresh,
              child: const Text('Volver a intentar'),
            ),
          ],
          Text(
            showingProducts
                ? '${services.length} producto(s) disponible(s)'
                : '${services.length} servicio(s) disponible(s)',
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 10),

          if (services.isEmpty && !_loading && !missingZone)
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: AppTheme.surfaceCard,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppTheme.borderSoft),
              ),
              child: Text(
                showingProducts
                    ? 'No se encontraron productos con esos filtros. Prueba ampliar el radio a "Todo el barrio".'
                    : 'No se encontraron servicios con esos filtros en este radio. Prueba ampliar el radio a "Todo el barrio".',
                style: const TextStyle(
                  fontSize: 17,
                  color: AppTheme.textSecondary,
                ),
              ),
            )
          else
            for (final srv in services) ...[
              _ServiceCard(
                service: srv,
                originLat: origin?.latitude,
                originLng: origin?.longitude,
                onTap: () => controller.openServiceDetail(srv),
              ),
              const SizedBox(height: 12),
            ],
        ],
      ),
    );
  }
}

class _ServiceCard extends StatelessWidget {
  const _ServiceCard({
    required this.service,
    required this.originLat,
    required this.originLng,
    required this.onTap,
  });

  final Publication service;
  final double? originLat;
  final double? originLng;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final distLabel = service.distanceLabelFrom(lat: originLat, lng: originLng);

    return Semantics(
      button: true,
      label: service.isProduct
          ? 'Producto ${service.title} por ${service.authorAlias}, $distLabel. Toca para abrir ficha.'
          : 'Servicio ${service.title} por ${service.authorAlias}, $distLabel, ${service.recommendationCount} opiniones vecinales. Toca para abrir ficha.',
      child: Material(
        color: AppTheme.surfaceCard,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          key: Key('card_service_${service.id}'),
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppTheme.borderSoft, width: 1.5),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    PublicationStatusBadge(status: service.status),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: AppTheme.surfaceContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        service.isProduct
                            ? 'Producto'
                            : '${service.recommendationCount} opinión(es) vecinal(es)',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.actionGreen,
                        ),
                      ),
                    ),
                    if (service.isDemo)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE2E8F0),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text(
                          'Demostración Pueblo Libre',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  service.title,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${service.isProduct ? 'Publicado por' : 'Prestador'}: ${service.authorAlias} · ${service.sector} ($distLabel)',
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.actionGreen,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  service.description,
                  style: const TextStyle(
                    fontSize: 17,
                    color: AppTheme.textSecondary,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!service.isProduct)
                      Text(
                        'Horario: ${service.availabilityText}',
                        style: const TextStyle(fontSize: 16),
                      ),
                    const Text(
                      'Abrir ficha →',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
