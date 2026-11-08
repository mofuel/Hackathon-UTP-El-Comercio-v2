import 'package:hackathon_utp_el_comercio/core/maps/carto_tile_cache.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:hackathon_utp_el_comercio/core/accessibility/accessibility_controller.dart';
import 'package:hackathon_utp_el_comercio/core/database/local_sqlite_database.dart';
import 'package:hackathon_utp_el_comercio/core/geography/peru_location_catalog.dart';
import 'package:hackathon_utp_el_comercio/core/maps/carto_basemap.dart';
import 'package:hackathon_utp_el_comercio/core/maps/tile_load_health.dart';
import 'package:hackathon_utp_el_comercio/core/maps/explore_map_controller.dart';
import 'package:hackathon_utp_el_comercio/core/maps/map_location_service.dart';
import 'package:hackathon_utp_el_comercio/core/models/domain_models.dart';
import 'package:hackathon_utp_el_comercio/core/state/app_controller.dart';
import 'package:hackathon_utp_el_comercio/core/sync/outbox_sync_service.dart';
import 'package:hackathon_utp_el_comercio/core/sync/supabase_remote_gateway.dart';
import 'package:hackathon_utp_el_comercio/features/maps/explore_map_screen.dart';
import 'package:hackathon_utp_el_comercio/features/maps/neighborhood_map.dart';
import 'package:hackathon_utp_el_comercio/features/services/services_directory_screen.dart';
import 'package:hackathon_utp_el_comercio/main.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);
Publication pub(
  String id, {
  String district = '150121',
  PublicationKind kind = PublicationKind.servicio,
  String category = 'electricidad',
  double? lat = -12.076,
  double? lng = -77.063,
  String owner = 'other',
  SyncStatus sync = SyncStatus.confirmado,
  bool consent = false,
  PublicationStatus status = PublicationStatus.abierta,
}) => Publication(
  id: id,
  clientMutationId: id,
  ownerUserId: owner,
  authorId: owner,
  authorAlias: 'Prueba',
  kind: kind,
  category: category,
  title: 'Registro $id',
  description: 'Descripción de prueba',
  neighborhood: 'Pueblo Libre',
  sector: 'Referencia pública',
  districtUbigeo: district,
  approxLat: lat,
  approxLng: lng,
  syncStatus: sync,
  shareResourceConsent: consent,
  status: status,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

Future<AppController> app({
  bool authenticated = true,
  SupabaseRemoteGateway? remote,
}) async {
  final db = LocalSqliteDatabase(engine: InMemoryTransactionalStoreEngine());
  final gateway =
      remote ??
      (SupabaseRemoteGateway(forceSupabaseAvailable: false)
        ..simulateNetworkOffline = true);
  final c = AppController(
    database: db,
    remoteGateway: gateway,
    outboxSyncService: OutboxSyncService(database: db, remoteGateway: gateway),
  );
  await c.initialize(startWithActiveSession: authenticated);
  return c;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(PeruLocationCatalog.load);

  testWidgets(
    'El directorio consulta cerca del GPS y centra el mapa con el punto privado',
    (tester) async {
      final remote = _MapGateway();
      final c = await app(remote: remote);
      addTearDown(c.dispose);
      await c.updateLocationPreference(
        neighborhood: 'Sin distrito',
        sector: 'Sin sector',
        approxLat: null,
        approxLng: null,
        useGpsApprox: false,
      );
      remote.connected = true;
      c.updateServiceFilters(mapQuadrantView: true);
      final location = _DirectoryLocation();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AnimatedBuilder(
              animation: c,
              builder: (_, _) => ServicesDirectoryScreen(
                controller: c,
                locationService: location,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(location.reads, 0);
      expect(remote.calls, 0);
      expect(find.text('Registro remote-map'), findsNothing);

      final button = find.byKey(const Key('btn_locate_service_map'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();

      final map = tester.widget<NeighborhoodMap>(find.byType(NeighborhoodMap));
      expect(map.center, _DirectoryLocation.point);
      expect(map.privateLocation, _DirectoryLocation.point);
      final result = map.records.singleWhere(
        (record) => record.id == 'pub:remote-map',
      );
      expect(remote.lastOrigin, -12.076);
      expect(c.currentUser!.approxLat, isNull);
      expect(c.currentUser!.districtUbigeo, isNull);

      c.openServiceDetail(result.publication!);
      await c.refreshAllLocalData();
      expect(c.selectedPublication?.id, 'remote-map');
    },
  );

  test('Configuración ausente, URL HTTPS y clave fuera de diagnósticos', () {
    expect(const CartoConfiguration(apiKey: '').isConfigured, isFalse);
    const c = CartoConfiguration(apiKey: 'test-only-key');
    final uri = c.tileUri(12, 1171, 2186);
    expect(uri.host, 'basemaps.cartocdn.com');
    expect(uri.path, '/rastertiles/voyager/12/1171/2186.png');
    expect(uri.queryParameters['key'], 'test-only-key');
    expect(c.toString(), isNot(contains('test-only-key')));
  });

  test(
    'Coordenadas válidas redondeadas; inválidas y ausentes sin marcador',
    () {
      expect(
        approximateMapPoint(-12.076499, -77.063499),
        const LatLng(-12.076, -77.063),
      );
      for (final lat in [null, double.nan, double.infinity, 90.0, -91.0]) {
        expect(approximateMapPoint(lat, -77), isNull);
      }
      expect(approximateMapPoint(-12, 181), isNull);
      expect(
        NeighborhoodMapRecord.publication(pub('no', lat: null)).point,
        isNull,
      );
      expect(
        NeighborhoodMapRecord.resource(
          CommunityResource.fromSqlMap({'id': 'missing'}),
        ).point,
        isNull,
      );
    },
  );

  test('Recursos de emergencia requieren consentimiento para el marcador', () {
    expect(
      NeighborhoodMapRecord.publication(
        pub('no', kind: PublicationKind.emergenciaOferta),
      ).point,
      isNull,
    );
    expect(
      NeighborhoodMapRecord.publication(
        pub('yes', kind: PublicationKind.emergenciaOferta, consent: true),
      ).point,
      isNotNull,
    );
  });

  test('Identidad móvil real por canal y validación de SHA-1', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MobileMapIdentity.channel, (call) async {
          expect(call.method, 'headers');
          return {'X-Ios-Bundle-Identifier': 'com.example.test'};
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MobileMapIdentity.channel, null),
    );
    final headers = await MobileMapIdentity.headers();
    expect(MobileMapIdentity.isValid(headers, TargetPlatform.iOS), isTrue);
    expect(
      MobileMapIdentity.isValid({
        'X-Android-Package': 'com.example.test',
        'X-Android-Cert': 'AB' * 20,
      }, TargetPlatform.android),
      isTrue,
    );
    expect(
      MobileMapIdentity.isValid({
        'X-Android-Package': 'com.example.test',
      }, TargetPlatform.android),
      isFalse,
    );
  });

  test('Tiles envían clave e identidad; respuesta válida y errores sin filtrar URLs', () async {
    final result = <bool>[];
    var calls = 0;
    final provider = CartoTileProvider(
      tileCache: _NoCache(),
      configuration: const CartoConfiguration(apiKey: 'test-key'),
      identity: {'X-Ios-Bundle-Identifier': 'com.example.test'},
      onTileResult: result.add,
      client: MockClient((request) async {
        calls++;
        expect(request.headers['X-Ios-Bundle-Identifier'], 'com.example.test');
        expect(request.url.queryParameters['key'], 'test-key');
        if (calls == 1) {
          return http.Response.bytes(
            _png,
            200,
            headers: {'content-type': 'image/png'},
          );
        }
        throw http.ClientException('URL con clave que no debe salir');
      }),
    );
    final cancel = Completer<void>();
    expect(
      await provider.bytes(
        const TileCoordinates(1171, 2186, 12),
        cancel.future,
      ),
      _png,
    );
    await provider.bytes(const TileCoordinates(1172, 2186, 12), cancel.future);
    expect(result, [true, false]);
    final image = provider.getImageWithCancelLoadingSupport(
      const TileCoordinates(1171, 2186, 12),
      TileLayer(),
      cancel.future,
    );
    expect(image.toString(), isNot(contains('test-key')));
    await provider.dispose();
  });

  test('Tiles limitan a cuatro peticiones simultáneas', () async {
    var active = 0;
    var peak = 0;
    final provider = CartoTileProvider(
      tileCache: _NoCache(),
      configuration: const CartoConfiguration(apiKey: 'test'),
      identity: {},
      onTileResult: (_) {},
      client: MockClient((request) async {
        active++;
        if (active > peak) peak = active;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        active--;
        return http.Response.bytes(
          _png,
          200,
          headers: {'content-type': 'image/png'},
        );
      }),
    );
    final cancel = Completer<void>();
    await Future.wait([
      for (var i = 0; i < 10; i++)
        provider.bytes(TileCoordinates(i, 0, 3), cancel.future),
    ]);
    expect(peak, lessThanOrEqualTo(4));
    cancel.complete();
    await provider.dispose();
  });

  test(
    'Tile rechazado por CARTO conserva estado de error sin exponer clave',
    () async {
      final status = <bool>[];
      final provider = CartoTileProvider(
        tileCache: _NoCache(),
        configuration: const CartoConfiguration(apiKey: 'private-test'),
        identity: {},
        onTileResult: status.add,
        client: MockClient((_) async => http.Response('Forbidden', 403)),
      );
      await provider.bytes(
        const TileCoordinates(1, 1, 3),
        Completer<void>().future,
      );
      expect(status, [false]);
      await provider.dispose();
    },
  );

  testWidgets('Timeout de tiles se informa y devuelve una imagen segura', (
    tester,
  ) async {
    final status = <bool>[];
    final blocked = Completer<http.Response>();
    final provider = CartoTileProvider(
      tileCache: _NoCache(),
      configuration: const CartoConfiguration(apiKey: 'test'),
      identity: {},
      onTileResult: status.add,
      client: MockClient((_) => blocked.future),
    );
    final result = provider.bytes(
      const TileCoordinates(1, 1, 3),
      Completer<void>().future,
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 13));
    expect(status, [false]);
    expect(await result, isNotEmpty);
    blocked.complete(http.Response('cancelled', 503));
    await provider.dispose();
  });

  test(
    'Avisos de calles se limpian al recuperarse y omiten fallos fuera de vista',
    () {
      final health = TileLoadHealth();
      final tile = const TileCoordinates(1171, 2186, 12);
      final view = LatLngBounds(
        const LatLng(-12.2, -77.2),
        const LatLng(-12, -77),
      );
      health.record(tile, false);
      expect(health.hasFailure(view, 12), isTrue);
      health.record(tile, true);
      expect(health.hasFailure(view, 12), isFalse);
      expect(health.hasLoaded(view, 12), isTrue);
      health.record(const TileCoordinates(0, 0, 12), false);
      expect(health.hasFailure(view, 12), isFalse);
      health.record(tile, false);
      expect(health.hasFailure(view, 14), isFalse);
      health.clear();
      expect(health.hasFailure(view, 12), isFalse);
    },
  );

  test('Agrupación visual, selección de coordenadas reales y descarte fuera de vista', () {
    final values = [
      for (var i = 0; i < 50; i++) NeighborhoodMapRecord.publication(pub('$i')),
      NeighborhoodMapRecord.publication(pub('away', lat: -16, lng: -72)),
      NeighborhoodMapRecord.publication(pub('none', lat: null)),
    ];
    final groups = groupMapMarkers(
      values,
      14,
      LatLngBounds(const LatLng(-12.2, -77.2), const LatLng(-12, -77)),
    );
    expect(groups.length, 1);
    expect(groups.single.records.length, 50);
    expect(groups.single.point, values.first.point);
  });

  test(
    'Copia local, UBIGEO y categorías conservan operaciones pendientes',
    () async {
      final c = await app();
      addTearDown(c.dispose);
      final uid = c.currentUser!.id;
      await c.database.mergeRemotePublications([
        pub('map-service'),
        pub(
          'map-favor',
          kind: PublicationKind.favorSolicitud,
          category: 'acompanamiento',
        ),
        pub('map-molina', district: '150114', lat: null, lng: null),
        pub('map-sangani', district: '120307', lat: null, lng: null),
        pub('map-resolved', status: PublicationStatus.resuelta),
        pub(
          'map-pending-other',
          owner: 'another-account',
          sync: SyncStatus.pendiente,
        ),
      ]);
      final pending = await c.submitPublication(
        kind: PublicationKind.favorSolicitud,
        category: 'acompanamiento',
        title: 'Mi pendiente',
        description: 'Sin conexión',
      );
      final before = (await c.database.listOutboxForUser(uid)).length;
      final m = ExploreMapController(c);
      addTearDown(m.dispose);
      await m.refresh();
      expect(m.records.any((r) => r.publication?.id == pending.id), isTrue);
      expect(
        m.records.any((r) => r.publication?.id == 'map-pending-other'),
        isFalse,
      );
      expect(
        m.records.any((r) => r.publication?.id == 'map-resolved'),
        isFalse,
      );
      m.setFilter(MapRecordFilter.servicios);
      await m.loadLocal();
      expect(
        m.records.every((r) => r.group == MapRecordFilter.servicios),
        isTrue,
      );
      m.setCategory('electricidad');
      await m.loadLocal();
      expect(m.records.every((r) => r.category == 'electricidad'), isTrue);
      m.setFilter(MapRecordFilter.todos);
      await m.setZone(
        const PeruLocationSelection(
          departmentCode: '15',
          provinceCode: '1501',
          districtCode: '150114',
        ),
      );
      expect(m.records.map((r) => r.publication?.id), contains('map-molina'));
      expect(m.center, isNull);
      expect(m.records.every((r) => r.districtUbigeo == '150114'), isTrue);
      await m.setZone(const PeruLocationSelection(departmentCode: '12'));
      expect(m.records.any((r) => r.publication?.id == 'map-sangani'), isTrue);
      expect((await c.database.listOutboxForUser(uid)).length, before);
    },
  );

  test(
    'Sin sesión ni después de salir se exponen registros cacheados',
    () async {
      final c = await app();
      addTearDown(c.dispose);
      final m = ExploreMapController(c);
      addTearDown(m.dispose);
      await m.refresh();
      expect(m.records, isNotEmpty);
      await c.signOut();
      await m.loadLocal();
      expect(m.records, isEmpty);
      final anonymous = await app(authenticated: false);
      addTearDown(anonymous.dispose);
      await anonymous.database.mergeRemotePublications([pub('private-cache')]);
      final n = ExploreMapController(anonymous);
      addTearDown(n.dispose);
      await n.refresh();
      expect(n.records, isEmpty);
    },
  );

  test(
    'Consulta remota acotada, error de conexión y respuesta tardía tras salir',
    () async {
      final remote = _MapGateway();
      final c = await app(remote: remote);
      addTearDown(c.dispose);
      final m = ExploreMapController(c);
      addTearDown(m.dispose);
      remote.connected = true;
      await m.refresh();
      expect(remote.calls, 1);
      expect(remote.lastLimit, 201);
      expect(m.records.any((r) => r.publication?.id == 'remote-map'), isTrue);
      final calls = remote.calls;
      m.centerOn(const LatLng(-12.076, -77.063));
      expect(remote.calls, calls);
      remote.fail = true;
      await m.refresh();
      expect(m.notice, contains('No se pudo actualizar'));
      expect(m.records.any((r) => r.publication?.id == 'remote-map'), isTrue);
      remote.fail = false;
      await m.setZone(
        const PeruLocationSelection(
          departmentCode: '15',
          provinceCode: '1501',
          districtCode: '150114',
        ),
      );
      expect(remote.lastOrigin, isNull);
      expect(remote.lastDistrict, '150114');
      remote.pending = Completer<List<Publication>>();
      final request = m.refresh();
      await Future<void>.delayed(Duration.zero);
      remote.connected = false;
      await c.signOut();
      remote.pending!.complete([pub('late-private')]);
      await request;
      expect(m.records, isEmpty);
      expect(
        (await c.database.listPublications(activeUserId: 'anonymous'))
            .any((p) => p.id == 'late-private'),
        isFalse,
      );
    },
  );

  testWidgets(
    'Mapa inicializa, selecciona marcador y ofrece zoom y atribuciones visibles',
    (tester) async {
      NeighborhoodMapRecord? selected;
      final record = NeighborhoodMapRecord.publication(pub('single'));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: NeighborhoodMap(
                records: [record],
                privateLocation: const LatLng(-12.075, -77.062),
                center: record.point,
                onSelect: (r) => selected = r,
                configuration: const CartoConfiguration(apiKey: 'test'),
                tileProvider: _MemoryTiles(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(FlutterMap), findsOneWidget);
      expect(find.byKey(const Key('map_private_location')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('map_marker_pub:single')));
      expect(selected?.id, record.id);
      await tester.tap(find.byKey(const Key('map_zoom_in')));
      await tester.pumpAndSettle();
      expect(find.text('© CARTO'), findsOneWidget);
      expect(find.text('© OpenStreetMap contributors'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'Calles de memoria no producen un timeout falso al reabrir el mapa',
    (tester) async {
      final png = await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        ui.Canvas(recorder)
            .drawColor(const Color(0xFFEEEEEE), ui.BlendMode.src);
        final picture = recorder.endRecording();
        final image = await picture.toImage(2, 2);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        picture.dispose();
        return data!.buffer.asUint8List();
      });
      for (var attempt = 0; attempt < 2; attempt++) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: NeighborhoodMap(
                  records: [],
                  center: const LatLng(-12.076, -77.063),
                  onSelect: (_) {},
                  configuration: const CartoConfiguration(apiKey: 'test'),
                  tileProvider: _LoadedTiles(png!),
                ),
              ),
            ),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 16));
        expect(find.byKey(const Key('map_tile_error')), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  testWidgets(
    'Ausencia de clave y pérdida de conexión mantienen alternativa accesible',
    (tester) async {
      Future<void> show(bool online) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: NeighborhoodMap(
                records: [],
                center: null,
                onSelect: (_) {},
                online: online,
                configuration: const CartoConfiguration(apiKey: ''),
              ),
            ),
          ),
        ),
      );
      await show(true);
      await tester.pumpAndSettle();
      expect(find.textContaining('pendiente de configurar'), findsOneWidget);
      expect(find.byType(FlutterMap), findsNothing);
      await show(false);
      await tester.pumpAndSettle();
      expect(find.textContaining('Sin conexión'), findsOneWidget);
      expect(find.byType(FlutterMap), findsNothing);
    },
  );

  test(
    'Permiso denegado no obtiene coordenadas ni inicia seguimiento',
    () async {
      final original = GeolocatorPlatform.instance;
      final denied = _DeniedLocation();
      GeolocatorPlatform.instance = denied;
      addTearDown(() => GeolocatorPlatform.instance = original);
      expect(await MapLocationService().locate(), isNull);
      expect(denied.requests, 1);
      expect(denied.reads, 0);
    },
  );

  testWidgets(
    'GPS denegado conserva zona y filtros; texto grande sin desbordar',
    (tester) async {
      final c = await app();
      addTearDown(c.dispose);
      final before = c.activeDistrictUbigeo;
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ExploreMapScreen(
              controller: c,
              locationService: _NoLocation(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const Key('map_locate_me')),
        300,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('map_results_scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('map_locate_me')));
      await tester.pumpAndSettle();
      expect(find.textContaining('No se obtuvo permiso'), findsOneWidget);
      expect(c.activeDistrictUbigeo, before);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('Inicio a mapa y detalle real por lista en dos clics', (
    tester,
  ) async {
    final c = await app();
    addTearDown(c.dispose);
    await c.database.mergeRemotePublications([pub('direct')]);
    await tester.pumpWidget(
      Conecta2App(
        appController: c,
        accessibilityController: AccessibilityController(),
      ),
    );
    await tester.pumpAndSettle();
    final home = find.byKey(const Key('btn_home_explorar_mapa'));
    await tester.ensureVisible(home);
    await tester.pumpAndSettle();
    await tester.tap(home);
    await tester.pumpAndSettle();
    expect(c.currentSection, AppSection.explorarMapa);
    expect(find.byType(ExploreMapScreen), findsOneWidget);
    final result = find.byKey(const ValueKey('map_list_pub:direct'));
    await tester.scrollUntilVisible(
      result,
      300,
      scrollable: find
          .descendant(
            of: find.byKey(const Key('map_results_scroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    await tester.tap(result);
    await tester.pumpAndSettle();
    expect(c.currentSection, AppSection.detalleServicio);
    expect(c.selectedPublication?.id, 'direct');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Seleccionar pines abre los detalles sobre el mapa', (
    tester,
  ) async {
    final c = await app();
    addTearDown(c.dispose);
    await c.database.mergeRemotePublications([
      pub('servicio-pin'),
      pub('emergencia-pin', kind: PublicationKind.emergenciaSolicitud),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ExploreMapScreen(controller: c)),
      ),
    );
    await tester.pumpAndSettle();
    final map = tester.widget<NeighborhoodMap>(find.byType(NeighborhoodMap));
    for (final id in ['servicio-pin', 'emergencia-pin']) {
      map.onSelect(map.records.singleWhere((record) => record.id == 'pub:$id'));
      await tester.pumpAndSettle();
      final dialog = find.byKey(const Key('map_record_detail'));
      expect(
        find.descendant(of: dialog, matching: find.text('Registro $id')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: dialog,
          matching: find.text('Descripción de prueba'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Cerrar'));
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _MemoryTiles extends TileProvider {
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      MemoryImage(_png);
}

class _DirectoryLocation extends MapLocationService {
  static const point = LatLng(-12.075932, -77.063108);
  int reads = 0;
  @override
  Future<LatLng?> locatePrecise() async {
    reads++;
    return point;
  }
}

class _NoLocation extends MapLocationService {
  @override
  Future<LatLng?> locate() async => null;
}

class _DeniedLocation extends GeolocatorPlatform {
  int requests = 0, reads = 0;
  @override
  Future<bool> isLocationServiceEnabled() async => true;
  @override
  Future<LocationPermission> checkPermission() async =>
      LocationPermission.denied;
  @override
  Future<LocationPermission> requestPermission() async {
    requests++;
    return LocationPermission.denied;
  }

  @override
  Future<Position> getCurrentPosition({
    LocationSettings? locationSettings,
  }) async {
    reads++;
    throw StateError('No debe consultar GPS');
  }
}

class _MapGateway extends SupabaseRemoteGateway {
  _MapGateway() : super(forceSupabaseAvailable: false);
  bool connected = false, fail = false;
  int calls = 0;
  int? lastLimit;
  double? lastOrigin;
  String? lastDistrict;
  Completer<List<Publication>>? pending;
  @override
  bool get isLiveSupabaseConnected => connected;
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
    calls++;
    lastLimit = maxResults;
    lastOrigin = originLat;
    lastDistrict = districtUbigeo;
    if (fail) throw StateError('Sin red');
    if (pending != null) return pending!.future;
    return [pub('remote-map')];
  }

  @override
  Future<List<Publication>> fetchOwnMapPublications() async => [];
  @override
  Future<List<CommunityResource>> fetchMapResources({
    required double originLat,
    required double originLng,
    int radiusMeters = 20000,
    int maxResults = 201,
  }) async => [];
}

class _LoadedTiles extends TileProvider {
  _LoadedTiles(this.bytes);
  final Uint8List bytes;
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      MemoryImage(bytes);
}

class _NoCache implements MapTileCache {
  @override
  Future<Uint8List?> read(String key) async => null;
  @override
  Future<void> write(String key, Uint8List bytes, Duration lifetime) async {}
}
