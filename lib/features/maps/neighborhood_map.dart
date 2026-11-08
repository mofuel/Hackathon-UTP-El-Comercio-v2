import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/maps/carto_basemap.dart';
import '../../core/maps/explore_map_controller.dart';
import '../../core/maps/tile_load_health.dart';
import '../../core/theme/app_theme.dart';

class MapMarkerGroup {
  MapMarkerGroup(this.records);
  final List<NeighborhoodMapRecord> records;
  LatLng get point => records.first.point!;
}

/// Agrupa en celdas visuales sin modificar las coordenadas de los registros.
List<MapMarkerGroup> groupMapMarkers(
  List<NeighborhoodMapRecord> records,
  double zoom,
  LatLngBounds bounds,
) {
  final groups = <String, List<NeighborhoodMapRecord>>{};
  final scale = 256 * math.pow(2, zoom);
  for (final record in records) {
    final point = record.point;
    if (point == null || !bounds.contains(point)) continue;
    final sinLat = math.sin(point.latitude * math.pi / 180);
    final x = (point.longitude + 180) / 360 * scale;
    final y =
        (.5 - math.log((1 + sinLat) / (1 - sinLat)) / (4 * math.pi)) * scale;
    final cell = '${(x / 56).floor()}:${(y / 56).floor()}';
    groups.putIfAbsent(cell, () => []).add(record);
  }
  return groups.values.map(MapMarkerGroup.new).toList();
}

IconData mapRecordIcon(MapRecordFilter group) => switch (group) {
  MapRecordFilter.servicios => Icons.home_repair_service_outlined,
  MapRecordFilter.favores => Icons.volunteer_activism_outlined,
  MapRecordFilter.recursos => Icons.inventory_2_outlined,
  MapRecordFilter.emergencias => Icons.warning_amber_rounded,
  MapRecordFilter.todos => Icons.place_outlined,
};

class NeighborhoodMap extends StatefulWidget {
  const NeighborhoodMap({
    super.key,
    required this.records,
    required this.center,
    required this.onSelect,
    this.privateLocation,
    this.selectionPoint,
    this.onSelectPoint,
    this.online = true,
    this.configuration = const CartoConfiguration(),
    this.identityLoader = MobileMapIdentity.headers,
    this.tileProvider,
  });
  final List<NeighborhoodMapRecord> records;
  final LatLng? center;
  final LatLng? privateLocation;
  final LatLng? selectionPoint;
  final ValueChanged<LatLng>? onSelectPoint;
  final ValueChanged<NeighborhoodMapRecord> onSelect;
  final bool online;
  final CartoConfiguration configuration;
  final Future<Map<String, String>> Function() identityLoader;
  final TileProvider? tileProvider;
  @override
  State<NeighborhoodMap> createState() => _NeighborhoodMapState();
}

class _NeighborhoodMapState extends State<NeighborhoodMap>
    with WidgetsBindingObserver {
  final _map = MapController();
  int? _pinPointer;
  Offset? _pinOffset;
  Map<String, String>? _identity;
  CartoTileProvider? _tiles;
  bool _ready = false;
  final _health = TileLoadHealth();
  bool _loadTimedOut = false;
  bool get _tileFailed =>
      _loadTimedOut ||
      (_ready &&
          _health.hasFailure(_map.camera.visibleBounds, _map.camera.zoom));
  bool _tileLoaded = false;
  int _attempt = 0;
  int _tileEpoch = 0;
  Timer? _loadTimeout;
  static const _peru = LatLng(-9.19, -75.015);
  double get _centerZoom => widget.center == null
      ? 5
      : widget.center == widget.privateLocation
      ? 16
      : 14;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadIdentity();
  }

  Future<void> _loadIdentity() async {
    final identity = await widget.identityLoader();
    if (mounted) setState(() => _identity = identity);
  }

  @override
  void didUpdateWidget(covariant NeighborhoodMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((oldWidget.center != widget.center ||
            oldWidget.privateLocation != widget.privateLocation) &&
        _ready) {
      _map.move(widget.center ?? _peru, _centerZoom);
    }
    if (oldWidget.online != widget.online) {
      _ready = false;
      _loadTimeout?.cancel();
      _tileEpoch++;
      _tiles = null;
      _tileLoaded = false;
      _loadTimedOut = false;
      _health.clear();
    }
  }

  void _tileResult(TileCoordinates tile, bool success, int epoch) {
    if (!mounted || epoch != _tileEpoch) return;
    if (_health.resultFor(tile) == success) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || epoch != _tileEpoch) return;
      setState(() {
        _health.record(tile, success);
        if (success) {
          _tileLoaded = true;
          _loadTimedOut = false;
          _loadTimeout?.cancel();
        }
      });
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && widget.online && _tileFailed) {
      _retry();
    }
  }

  void _retry() {
    _loadTimeout?.cancel();
    setState(() {
      _tiles = null;
      _loadTimedOut = false;
      _health.clear();
      _tileLoaded = false;
      _ready = false;
      _attempt++;
      _tileEpoch++;
    });
  }

  @override
  void dispose() {
    _loadTimeout?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _map.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final identityValid =
        widget.tileProvider != null ||
        MobileMapIdentity.isValid(_identity ?? {}, Theme.of(context).platform);
    final available = widget.configuration.isConfigured && identityValid;
    String? unavailable;
    if (!widget.online) {
      unavailable =
          'Sin conexión: solo se muestran las zonas del mapa que ya abriste.';
    } else if (!widget.configuration.isConfigured) {
      unavailable =
          'El mapa está pendiente de configurar. La lista sigue disponible.';
    } else if (_identity == null) {
      unavailable = 'Preparando el mapa…';
    } else if (!identityValid) {
      unavailable = 'No se pudo identificar esta instalación para CARTO. Consulta la lista o vuelve a abrir la app.';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!widget.online)
          const Text(
            'Mapa sin conexión: zonas vistas guardadas hasta 30 días. Las áreas no guardadas pueden quedar vacías.',
          ),
        if (available) ...[
          SizedBox(
            height: 340,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: FlutterMap(
                key: ValueKey('carto_map_$_attempt'),
                mapController: _map,
                options: MapOptions(
                  initialCenter: widget.center ?? _peru,
                  initialZoom: _centerZoom,
                  minZoom: 3,
                  maxZoom: 18,
                  onTap: (_, point) => widget.onSelectPoint?.call(point),
                  onMapReady: () {
                    _ready = true;
                    _loadTimeout?.cancel();
                    _loadTimeout = Timer(const Duration(seconds: 15), () {
                      if (mounted && !_tileLoaded) {
                        setState(() => _loadTimedOut = true);
                      }
                    });
                  },
                  onPositionChanged: (_, _) {
                    if (mounted) setState(() {});
                  },
                ),
                children: [
                  TileLayer(
                    key: ValueKey('carto_tiles_$_attempt'),
                    urlTemplate: 'https://basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png',
                    tileProvider:
                        widget.tileProvider ??
                        (_tiles ??= CartoTileProvider(
                          configuration: widget.configuration,
                          online: widget.online,
                          identity: _identity!,
                          onTileResult: (_) {},
                          onTileStatus: ((epoch) =>
                              (TileCoordinates tile, bool ok) =>
                                  _tileResult(tile, ok, epoch))(_tileEpoch),
                        )),
                    maxNativeZoom: 18,
                    keepBuffer: 1,
                    panBuffer: 0,
                    tileDisplay: const TileDisplay.instantaneous(),
                    tileBuilder: (context, child, tile) {
                      final image = tile.imageInfo?.image;
                      if (image != null &&
                          image.width > 1 &&
                          image.height > 1) {
                        // También cuenta las imágenes reutilizadas de memoria,
                        // que no vuelven a ejecutar la petición HTTP.
                        _tileResult(tile.coordinates, true, _tileEpoch);
                      }
                      return child;
                    },
                    tileUpdateTransformer: TileUpdateTransformers.debounce(
                      const Duration(milliseconds: 180),
                    ),
                  ),
                  Builder(
                    builder: (context) {
                      final camera = MapCamera.of(context);
                      return MarkerLayer(
                        markers: [
                          if (widget.selectionPoint != null)
                            Marker(
                              point: widget.selectionPoint!,
                              width: 64,
                              height: 64,
                              child: RawGestureDetector(
                                key: const Key('map_location_picker_pin'),
                                behavior: HitTestBehavior.opaque,
                                gestures: widget.onSelectPoint == null
                                    ? const {}
                                    : {
                                        EagerGestureRecognizer:
                                            GestureRecognizerFactoryWithHandlers<
                                              EagerGestureRecognizer
                                            >(
                                              EagerGestureRecognizer.new,
                                              (_) {},
                                            ),
                                      },
                                child: Listener(
                                  behavior: HitTestBehavior.opaque,
                                  onPointerDown: widget.onSelectPoint == null
                                      ? null
                                      : (event) {
                                          if (_pinPointer != null) return;
                                          _pinPointer = event.pointer;
                                          _pinOffset = _map.camera
                                              .latLngToScreenOffset(
                                                widget.selectionPoint!,
                                              );
                                          widget.onSelectPoint!(
                                            widget.selectionPoint!,
                                          );
                                        },
                                  onPointerMove: (event) {
                                    if (event.pointer != _pinPointer ||
                                        _pinOffset == null) {
                                      return;
                                    }
                                    _pinOffset = _pinOffset! + event.delta;
                                    widget.onSelectPoint?.call(
                                      _map.camera.screenOffsetToLatLng(
                                        _pinOffset!,
                                      ),
                                    );
                                  },
                                  onPointerUp: (event) {
                                    if (event.pointer == _pinPointer) {
                                      _pinPointer = null;
                                    }
                                  },
                                  onPointerCancel: (event) {
                                    if (event.pointer == _pinPointer) {
                                      _pinPointer = null;
                                    }
                                  },
                                  child: const Icon(
                                    Icons.location_on,
                                    color: AppTheme.urgentRed,
                                    size: 56,
                                    semanticLabel: 'Punto elegido. Arrastra para cambiar su ubicación.',
                                  ),
                                ),
                              ),
                            ),
                          if (widget.privateLocation != null)
                            Marker(
                              point: widget.privateLocation!,
                              width: 56,
                              height: 56,
                              child: Tooltip(
                                message: 'Tu ubicación aproximada · solo visible para ti',
                                child: Semantics(
                                  label: 'Tu ubicación aproximada, privada',
                                  child: const Icon(
                                    Icons.person_pin_circle,
                                    key: Key('map_private_location'),
                                    color: AppTheme.practiceBlue,
                                    size: 52,
                                  ),
                                ),
                              ),
                            ),
                          for (final group in groupMapMarkers(
                            widget.records,
                            camera.zoom,
                            camera.visibleBounds,
                          ))
                            Marker(
                              point: group.point,
                              width: 56,
                              height: 56,
                              child: Semantics(
                                button: true,
                                label: group.records.length == 1
                                    ? group.records.first.title
                                    : '${group.records.length} registros en esta zona aproximada',
                                child: Material(
                                  color:
                                      group.records.first.group ==
                                          MapRecordFilter.emergencias
                                      ? AppTheme.urgentRed
                                      : AppTheme.actionGreen,
                                  shape: const CircleBorder(),
                                  child: InkWell(
                                    customBorder: const CircleBorder(),
                                    key: ValueKey(
                                      group.records.length == 1
                                          ? 'map_marker_${group.records.first.id}'
                                          : 'map_cluster_${group.records.first.id}',
                                    ),
                                    onTap: () => _selectGroup(group),
                                    child: Center(
                                      child: group.records.length == 1
                                          ? Icon(
                                              mapRecordIcon(
                                                group.records.first.group,
                                              ),
                                              color: Colors.white,
                                              size: 28,
                                            )
                                          : Text(
                                              '${group.records.length}',
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 20,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              IconButton.filledTonal(
                key: const Key('map_zoom_in'),
                tooltip: 'Acercar mapa',
                onPressed: () {
                  if (_ready) {
                    _map.move(
                      _map.camera.center,
                      math.min(18, _map.camera.zoom + 1),
                    );
                  }
                },
                icon: const Icon(Icons.add),
              ),
              IconButton.filledTonal(
                key: const Key('map_zoom_out'),
                tooltip: 'Alejar mapa',
                onPressed: () {
                  if (_ready) {
                    _map.move(
                      _map.camera.center,
                      math.max(3, _map.camera.zoom - 1),
                    );
                  }
                },
                icon: const Icon(Icons.remove),
              ),
              TextButton.icon(
                key: const Key('map_center_zone'),
                onPressed: () {
                  if (_ready) {
                    _map.move(
                      widget.center ?? _peru,
                      widget.center == null ? 5 : 14,
                    );
                  }
                },
                icon: const Icon(Icons.center_focus_strong),
                label: const Text('Centrar zona'),
              ),
            ],
          ),
          if (_tileFailed)
            Text(
              widget.online
                  ? 'No se cargaron algunas calles. Revisa la conexión o reintenta; la lista permanece disponible.'
                  : 'Esta vista incluye zonas que no están guardadas. Puedes consultar los avisos en la lista.',
              key: Key('map_tile_error'),
            ),
          if (!_tileLoaded && !_tileFailed && widget.tileProvider == null)
            const Text('Cargando calles…'),
          if (_tileFailed)
            TextButton.icon(
              key: const Key('map_retry_tiles'),
              onPressed: _retry,
              icon: const Icon(Icons.refresh),
              label: const Text('Reintentar mapa'),
            ),
        ] else
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(unavailable!, key: const Key('map_unavailable')),
          ),
        // Siempre visibles, también en capturas y sin desplegar un panel.
        Wrap(
          spacing: 4,
          children: [
            TextButton(
              onPressed: () => launchUrl(
                Uri.parse('https://www.openstreetmap.org/copyright'),
              ),
              child: const Text(
                '© OpenStreetMap contributors',
                style: TextStyle(fontSize: 14),
              ),
            ),
            TextButton(
              onPressed: () =>
                  launchUrl(Uri.parse('https://carto.com/attributions')),
              child: const Text('© CARTO', style: TextStyle(fontSize: 14)),
            ),
          ],
        ),
        if (widget.privateLocation != null)
          const Text(
            'Pin azul: tu ubicación aproximada, solo visible para ti. No se guarda ni se publica.',
          ),
        Text(
          widget.records.any(
                (record) => record.publication?.shareServiceLocation == true,
              )
              ? 'Los puntos exactos de servicios se comparten por decisión de su autor. Los demás son zonas aproximadas.'
              : 'Zonas aproximadas; no indican viviendas. Una capital distrital solo sirve como referencia.',
        ),
      ],
    );
  }

  Future<void> _selectGroup(MapMarkerGroup group) async {
    if (group.records.length == 1) {
      widget.onSelect(group.records.first);
      return;
    }
    final record = await showModalBottomSheet<NeighborhoodMapRecord>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => FractionallySizedBox(
        heightFactor: .65,
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Registros en esta zona aproximada'),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: group.records.length,
                itemBuilder: (context, index) => ListTile(
                  minTileHeight: 64,
                  title: Text(group.records[index].title),
                  onTap: () => Navigator.pop(context, group.records[index]),
                ),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cerrar'),
            ),
          ],
        ),
      ),
    );
    if (mounted && record != null) widget.onSelect(record);
  }
}
