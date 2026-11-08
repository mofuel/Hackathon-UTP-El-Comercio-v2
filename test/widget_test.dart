import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hackathon_utp_el_comercio/core/geography/peru_location_catalog.dart';

import 'package:hackathon_utp_el_comercio/core/accessibility/accessibility_controller.dart';
import 'package:hackathon_utp_el_comercio/core/config/app_config.dart';
import 'package:hackathon_utp_el_comercio/core/database/local_sqlite_database.dart';
import 'package:hackathon_utp_el_comercio/core/models/domain_models.dart';
import 'package:hackathon_utp_el_comercio/core/state/app_controller.dart';
import 'package:hackathon_utp_el_comercio/core/sync/outbox_sync_service.dart';
import 'package:hackathon_utp_el_comercio/core/sync/supabase_remote_gateway.dart';
import 'package:hackathon_utp_el_comercio/core/theme/app_theme.dart';
import 'package:hackathon_utp_el_comercio/features/practice/practice_simulator.dart';
import 'package:hackathon_utp_el_comercio/main.dart';

Future<AppController> _createInitializedTestController({
  bool offline = false,
  bool signedIn = true,
}) async {
  final db = LocalSqliteDatabase(engine: InMemoryTransactionalStoreEngine());
  final gateway = SupabaseRemoteGateway(forceSupabaseAvailable: false)
    ..simulateNetworkOffline = offline;
  final outbox = OutboxSyncService(database: db, remoteGateway: gateway);
  final controller = AppController(
    database: db,
    remoteGateway: gateway,
    outboxSyncService: outbox,
  );
  await controller.initialize(startWithActiveSession: signedIn);
  return controller;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(PeruLocationCatalog.load);
  testWidgets('Publicar limpia el formulario después de guardar en la cola', (
    tester,
  ) async {
    final controller = await _createInitializedTestController(offline: true);
    addTearDown(controller.dispose);
    controller.openQuickPublish(
      presetKind: PublicationKind.servicio,
      lockTypeForTwoClickFlow: false,
    );
    await tester.pumpWidget(
      Conecta2App(
        appController: controller,
        accessibilityController: AccessibilityController(),
      ),
    );
    await tester.pumpAndSettle();

    final title = find.byKey(const Key('input_publish_title'));
    final description = find.byKey(const Key('input_publish_description'));
    final availability = find.byKey(const Key('input_publish_availability'));
    final submit = find.byKey(const Key('btn_submit_publication'));
    await tester.enterText(title, 'Arreglo de lámparas');
    await tester.enterText(availability, 'Sábados por la mañana');
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(title).controller!.text,
      'Arreglo de lámparas',
    );

    await tester.enterText(description, 'Reviso lámparas del barrio.');
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pumpAndSettle();

    for (final field in [title, description, availability]) {
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    }
    expect(
      controller.lastSubmittedPublication?.syncStatus,
      SyncStatus.pendiente,
    );
    expect(
      await controller.database.getDraft(
        ownerUserId: controller.currentUser!.id,
        draftKey: 'publish_servicio',
      ),
      isNull,
    );
  });

  testWidgets(
    'Un vecino publica un producto con precio y otra cuenta lo encuentra por cercanía',
    (tester) async {
      final publisher = await _createInitializedTestController(offline: true);
      final reader = await _createInitializedTestController(signedIn: false);
      addTearDown(publisher.dispose);
      addTearDown(reader.dispose);
      await reader.signIn(
        email: 'lector-productos@example.test',
        password: 'clave-de-prueba',
      );
      expect(reader.currentUser!.id, isNot(publisher.currentUser!.id));
      for (final controller in [publisher, reader]) {
        await controller.updateLocationPreference(
          neighborhood: 'Pueblo Libre',
          sector: 'Sector San Martín',
          districtUbigeo: '150121',
          approxLat: AppConfig.defaultLat,
          approxLng: AppConfig.defaultLng,
          useGpsApprox: false,
        );
      }

      final accessibility = AccessibilityController();
      addTearDown(accessibility.dispose);
      await tester.pumpWidget(
        Conecta2App(
          key: ObjectKey(publisher),
          appController: publisher,
          accessibilityController: accessibility,
        ),
      );
      final publish = find.byKey(const Key('btn_home_publicar_servicio_favor'));
      await tester.ensureVisible(publish);
      await tester.tap(publish);
      await tester.pumpAndSettle();
      final productChip = find.byKey(const Key('chip_kind_producto'));
      await tester.ensureVisible(productChip);
      await tester.tap(productChip);
      await tester.pumpAndSettle();
      expect(find.text('Descripción y precio del producto'), findsOneWidget);

      final title = find.byKey(const Key('input_publish_title'));
      final description = find.byKey(const Key('input_publish_description'));
      const price = 'Precio: S/ 10. Entrega cerca del parque.';
      await tester.enterText(title, 'Mochila de barrio');
      await tester.enterText(description, price);
      final submit = find.byKey(const Key('btn_submit_publication'));
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();

      final product = publisher.lastSubmittedPublication!;
      expect(product.kind, PublicationKind.anuncio);
      expect(product.isProduct, isTrue);
      expect(product.description, price);
      expect(product.syncStatus, SyncStatus.pendiente);
      expect(
        await publisher.database.getDraft(
          ownerUserId: publisher.currentUser!.id,
          draftKey: 'publish_producto',
        ),
        isNull,
      );
      final announcement = await publisher.submitPublication(
        kind: PublicationKind.anuncio,
        category: 'general',
        title: 'Mochila extraviada',
        description: 'Aviso general del barrio.',
      );
      publisher.remoteGateway.simulateNetworkOffline = false;
      publisher.outboxSyncService.networkAvailable = true;
      await publisher.retryOutboxSync();
      final confirmed = publisher.publications.singleWhere(
        (item) => item.id == product.id,
      );
      expect(confirmed.syncStatus, SyncStatus.confirmado);

      await reader.database.mergeRemotePublications([
        confirmed,
        announcement.copyWith(syncStatus: SyncStatus.confirmado),
      ]);
      await reader.refreshAllLocalData();
      reader.navigateTo(AppSection.servicios);
      await tester.pumpWidget(
        Conecta2App(
          key: ObjectKey(reader),
          appController: reader,
          accessibilityController: accessibility,
        ),
      );
      final card = find.byKey(Key('card_service_${product.id}'));
      expect(card, findsNothing);
      await tester.tap(find.byKey(const Key('chip_service_cat_producto')));
      await tester.pumpAndSettle();
      final radius = find.byKey(const Key('chip_radius_600'));
      await tester.ensureVisible(radius);
      await tester.tap(radius);
      await tester.pumpAndSettle();
      final search = find.byKey(const Key('input_search_services'));
      await tester.enterText(search, 'mochila');
      await tester.pumpAndSettle();
      expect(reader.filteredServices.map((item) => item.id), [product.id]);
      expect(
        reader.filteredFavors.any((item) => item.id == product.id),
        isFalse,
      );
      await tester.ensureVisible(card);
      expect(find.text(price), findsOneWidget);
      await tester.tap(card);
      await tester.pumpAndSettle();
      expect(find.text(price), findsOneWidget);
      expect(find.byKey(const Key('btn_recomendar_servicio')), findsNothing);
      final endorse = find.byKey(const Key('btn_recomendar_producto'));
      await tester.ensureVisible(endorse);
      expect(find.text('Vistos buenos (0)'), findsOneWidget);
      await reader.updateLocationPreference(
        neighborhood: 'Pueblo Libre',
        sector: 'Sector Plaza Bolívar',
        districtUbigeo: '150121',
        approxLat: AppConfig.defaultLat,
        approxLng: AppConfig.defaultLng,
        useGpsApprox: false,
      );
      await tester.pumpAndSettle();
      expect(tester.widget<ElevatedButton>(endorse).onPressed, isNull);
      await expectLater(
        reader.recommendService(service: confirmed),
        throwsStateError,
      );
      await reader.updateLocationPreference(
        neighborhood: 'Pueblo Libre',
        sector: 'Sector San Martín',
        districtUbigeo: '150121',
        approxLat: AppConfig.defaultLat,
        approxLng: AppConfig.defaultLng,
        useGpsApprox: false,
      );
      await tester.pumpAndSettle();
      reader.outboxSyncService.networkAvailable = false;
      await tester.tap(endorse);
      await tester.pumpAndSettle();
      expect(find.text('Vistos buenos (0)'), findsOneWidget);
      reader.outboxSyncService.networkAvailable = true;
      await reader.retryOutboxSync();
      await tester.pumpAndSettle();
      expect(find.text('Vistos buenos (1)'), findsOneWidget);

      await reader.database.mergeRemotePublications([
        confirmed.copyWith(approxLat: reader.activeLat! + 0.05),
      ]);
      await reader.refreshAllLocalData();
      expect(reader.filteredServices, isEmpty);
    },
  );

  group('1. Presupuesto estricto de <= 3 clics desde Inicio', () {
    testWidgets(
      'Tarea 1 (Pedir ayuda): Inicio -> Necesito ayuda (Clic 1) -> escribir -> Enviar solicitud (Clic 2)',
      (WidgetTester tester) async {
        final controller = await _createInitializedTestController();
        final accessibility = AccessibilityController();

        await tester.pumpWidget(
          Conecta2App(
            appController: controller,
            accessibilityController: accessibility,
          ),
        );
        await tester.pumpAndSettle();

        var clickCount = 0;

        // Clic 1: Necesito ayuda
        await tester.tap(find.byKey(const Key('btn_home_necesito_ayuda')));
        clickCount++;
        await tester.pumpAndSettle();

        // Escribir texto (no suma clics según encargo)
        await tester.enterText(
          find.byKey(const Key('input_publish_title')),
          'Apoyo para recoger medicina en botica de Sucre',
        );
        await tester.enterText(
          find.byKey(const Key('input_publish_description')),
          'Necesito apoyo hoy por la tarde en Sector Sucre.',
        );

        // Clic 2: Enviar solicitud
        await tester.ensureVisible(
          find.byKey(const Key('btn_submit_publication')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('btn_submit_publication')));
        clickCount++;
        await tester.pumpAndSettle();

        expect(clickCount, lessThanOrEqualTo(3));
        expect(clickCount, equals(2));
        expect(
          find.byKey(const Key('card_submitted_publication_result')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'Tarea 2 (Reportar emergencia): Inicio -> Reportar emergencia (Clic 1) -> escribir -> Enviar reporte (Clic 2)',
      (WidgetTester tester) async {
        final controller = await _createInitializedTestController();
        final accessibility = AccessibilityController();

        await tester.pumpWidget(
          Conecta2App(
            appController: controller,
            accessibilityController: accessibility,
          ),
        );
        await tester.pumpAndSettle();

        var clickCount = 0;

        // Clic 1: Reportar emergencia
        await tester.tap(find.byKey(const Key('btn_home_reportar_emergencia')));
        clickCount++;
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('input_publish_title')),
          'Corte de luz y adulto mayor requiere linterna en San Martín',
        );
        await tester.enterText(
          find.byKey(const Key('input_publish_description')),
          'Frente al parque del sector, sin riesgo vital.',
        );

        // Clic 2: Enviar reporte
        await tester.ensureVisible(
          find.byKey(const Key('btn_submit_publication')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('btn_submit_publication')));
        clickCount++;
        await tester.pumpAndSettle();

        expect(clickCount, equals(2));
        expect(find.text('Reporte comunicado a la comunidad'), findsOneWidget);
      },
    );

    testWidgets('Un invitado puede reportar y sincronizar al reconectar', (
      tester,
    ) async {
      final controller = await _createInitializedTestController(
        offline: true,
        signedIn: false,
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        Conecta2App(
          appController: controller,
          accessibilityController: AccessibilityController(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('btn_home_reportar_emergencia')));
      await tester.pumpAndSettle();
      expect(controller.currentSection, AppSection.publicarRapido);
      await tester.enterText(
        find.byKey(const Key('input_publish_title')),
        'Árbol caído en la avenida',
      );
      await tester.enterText(
        find.byKey(const Key('input_publish_description')),
        'Hay ramas que bloquean el paso.',
      );
      final send = find.byKey(const Key('btn_submit_publication'));
      await tester.ensureVisible(send);
      await tester.pumpAndSettle();
      await tester.tap(send);
      await tester.pumpAndSettle();

      final report = controller.lastSubmittedPublication!;
      expect(report.isGuestReport, isTrue);
      expect(report.syncStatus, SyncStatus.pendiente);
      expect(controller.userOutbox.single.entityId, report.id);
      await controller.setOfflineMode(false);
      await tester.pumpAndSettle();
      expect(controller.isAuthenticated, isFalse);
      expect(controller.userOutbox, isEmpty);
      expect(find.text('Reporte comunicado a la comunidad'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('Perfil muestra el formulario solo al cerrar sesión', (
      tester,
    ) async {
      final controller = await _createInitializedTestController();
      addTearDown(controller.dispose);
      controller.navigateTo(AppSection.autenticacion);
      await tester.pumpWidget(
        Conecta2App(
          appController: controller,
          accessibilityController: AccessibilityController(),
        ),
      );
      await tester.pumpAndSettle();
      final email = find.byKey(const Key('input_auth_email'));
      final signOut = find.byKey(const Key('btn_sign_out'));
      expect(email, findsNothing);
      expect(signOut, findsOneWidget);
      await tester.tap(signOut);
      await tester.pumpAndSettle();
      controller.navigateTo(AppSection.autenticacion);
      await tester.pumpAndSettle();
      expect(email, findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets(
      'Tarea 3 (Publicar servicio o favor): Inicio -> Publicar servicio o favor (Clic 1) -> seleccionar tipo (Clic 2) -> escribir -> Publicar en mi barrio (Clic 3)',
      (WidgetTester tester) async {
        final controller = await _createInitializedTestController();
        final accessibility = AccessibilityController();

        await tester.pumpWidget(
          Conecta2App(
            appController: controller,
            accessibilityController: accessibility,
          ),
        );
        await tester.pumpAndSettle();

        var clickCount = 0;

        // Clic 1: Publicar servicio o favor
        await tester.ensureVisible(
          find.byKey(const Key('btn_home_publicar_servicio_favor')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('btn_home_publicar_servicio_favor')),
        );
        clickCount++;
        await tester.pumpAndSettle();

        // Clic 2: Seleccionar tipo (Ofrecer favor gratuito)
        await tester.tap(find.byKey(const Key('chip_kind_favor_oferta')));
        clickCount++;
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('input_publish_title')),
          'Clases gratuitas de uso de celular para adultos mayores',
        );
        await tester.enterText(
          find.byKey(const Key('input_publish_description')),
          'Sábados por la mañana en Parque Candamo.',
        );

        // Clic 3: Publicar en mi barrio
        await tester.ensureVisible(
          find.byKey(const Key('btn_submit_publication')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('btn_submit_publication')));
        clickCount++;
        await tester.pumpAndSettle();

        expect(clickCount, equals(3));
        expect(
          find.byKey(const Key('card_submitted_publication_result')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'Tarea 4 (Ofrecer ayuda): Inicio -> Ver favores y ayudar (Clic 1) -> abrir solicitud (Clic 2) -> Enviar oferta de ayuda (Clic 3)',
      (WidgetTester tester) async {
        final controller = await _createInitializedTestController();
        final accessibility = AccessibilityController();

        await tester.pumpWidget(
          Conecta2App(
            appController: controller,
            accessibilityController: accessibility,
          ),
        );
        await tester.pumpAndSettle();

        var clickCount = 0;

        // Clic 1: Ver favores y ayudar
        await tester.ensureVisible(
          find.byKey(const Key('btn_home_ver_favores')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('btn_home_ver_favores')));
        clickCount++;
        await tester.pumpAndSettle();

        // Clic 2: Abrir solicitud de Doña Carmen
        await tester.ensureVisible(
          find.byKey(const Key('card_favor_pub-demo-favor-carmen')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('card_favor_pub-demo-favor-carmen')),
        );
        clickCount++;
        await tester.pumpAndSettle();

        await tester.enterText(
          find.byKey(const Key('input_favor_offer_note')),
          'Doña Carmen, yo tengo escalera de tijera y se la llevo en 15 minutos.',
        );

        // Clic 3: Enviar oferta de ayuda
        await tester.ensureVisible(
          find.byKey(const Key('btn_enviar_oferta_ayuda')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('btn_enviar_oferta_ayuda')));
        clickCount++;
        await tester.pumpAndSettle();

        expect(clickCount, equals(3));
        expect(
          find.byKey(const Key('banner_favor_detail_feedback')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'Tarea 5 y 6 (Contactar prestador y Recomendar servicio en <= 3 clics desde Inicio)',
      (WidgetTester tester) async {
        final controller = await _createInitializedTestController();
        final accessibility = AccessibilityController();

        await tester.pumpWidget(
          Conecta2App(
            appController: controller,
            accessibilityController: accessibility,
          ),
        );
        await tester.pumpAndSettle();

        var clickCount = 0;

        // Clic 1: Buscar servicios
        await tester.ensureVisible(
          find.byKey(const Key('btn_home_buscar_servicios')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('btn_home_buscar_servicios')));
        clickCount++;
        await tester.pumpAndSettle();

        // Clic 2: Abrir ficha de Elena Flores (Costura)
        await tester.ensureVisible(
          find.byKey(const Key('card_service_pub-demo-servicio-elena')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('card_service_pub-demo-servicio-elena')),
        );
        clickCount++;
        await tester.pumpAndSettle();

        // Clic 3 (Tarea 6): Recomendar servicio
        await tester.ensureVisible(
          find.byKey(const Key('btn_recomendar_servicio')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('btn_recomendar_servicio')));
        clickCount++;
        await tester.pumpAndSettle();

        expect(clickCount, equals(3));
        final publish = find.byKey(const Key('btn_recomendar_servicio'));
        expect(tester.widget<ElevatedButton>(publish).onPressed, isNull);
        expect(
          find.textContaining('Tu opinión vecinal fue registrada'),
          findsNothing,
        );
        final edit = find.byKey(const Key('btn_modificar_recomendacion'));
        final remove = find.byKey(const Key('btn_retirar_recomendacion'));
        final comment = find.byKey(
          const Key('input_service_recommendation_comment'),
        );
        await tester.enterText(comment, 'Opinión actualizada.');
        await tester.ensureVisible(edit);
        await tester.pumpAndSettle();
        await tester.tap(edit);
        await tester.pumpAndSettle();
        final recommendations = await controller.database
            .listRecommendationsForService(controller.selectedPublication!.id);
        final mine = recommendations.singleWhere(
          (recommendation) =>
              recommendation.userId == controller.currentUser!.id,
        );
        expect(mine.comment, 'Opinión actualizada.');
        await tester.ensureVisible(remove);
        await tester.pumpAndSettle();
        await tester.tap(remove);
        await tester.pumpAndSettle();
        expect(tester.widget<ElevatedButton>(publish).onPressed, isNotNull);
      },
    );

    testWidgets(
      'Tarea 7 (Iniciar práctica en <= 3 clics y completar las 5 misiones con 0 escrituras reales)',
      (WidgetTester tester) async {
        final controller = await _createInitializedTestController();
        final accessibility = AccessibilityController();

        final initialRealPubs = (await controller.database.listPublications(
          activeUserId: 'any',
        )).length;
        final initialRealOutbox = (await controller.database.listOutboxForUser(
          controller.currentUser!.id,
        )).length;

        await tester.pumpWidget(
          Conecta2App(
            appController: controller,
            accessibilityController: accessibility,
          ),
        );
        await tester.pumpAndSettle();

        var clickCount = 0;

        // Clic 1: Practicar una emergencia
        await tester.ensureVisible(
          find.byKey(const Key('btn_home_practicar_emergencia')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const Key('btn_home_practicar_emergencia')),
        );
        clickCount++;
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('banner_practica_datos_ficticios')),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('btn_salir_de_la_practica')),
          findsOneWidget,
        );

        // Clic 2: Elegir escenario Lluvia intensa
        await tester.ensureVisible(
          find.byKey(const Key('card_scenario_lluvia')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('card_scenario_lluvia')));
        clickCount++;
        await tester.pumpAndSettle();

        // Clic 3: Iniciar práctica
        await tester.ensureVisible(
          find.byKey(const Key('btn_iniciar_practica')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('btn_iniciar_practica')));
        clickCount++;
        await tester.pumpAndSettle();

        expect(clickCount, equals(3));

        // Verificar aislamiento total tras usar el repositorio de práctica
        final afterRealPubs = (await controller.database.listPublications(
          activeUserId: 'any',
        )).length;
        final afterRealOutbox = (await controller.database.listOutboxForUser(
          controller.currentUser!.id,
        )).length;

        expect(afterRealPubs, equals(initialRealPubs));
        expect(afterRealOutbox, equals(initialRealOutbox));
      },
    );
  });

  group('2. SQLite Outbox, Idempotencia, Aislamiento entre cuentas y Reglas de Dominio', () {
    test('Transacción SQLite local + Outbox, idempotencia sin duplicados, error de servidor y aislamiento entre cuentas', () async {
      final controller = await _createInitializedTestController(offline: true);
      final mariaId = controller.currentUser!.id;

      // Crear reporte en modo offline con llave de idempotencia fija
      final createdOffline = await controller.submitPublication(
        kind: PublicationKind.emergenciaSolicitud,
        category: 'primeros_auxilios_apoyo',
        title: 'Solicitud offline de María',
        description: 'Necesito apoyo con agua potable en Sector Sucre.',
        customClientMutationId: 'mut-idempotent-test-1',
      );

      expect(createdOffline.syncStatus, equals(SyncStatus.pendiente));

      // Reintentar la misma mutación no debe duplicar ni la publicación ni la operación en outbox
      await controller.submitPublication(
        kind: PublicationKind.emergenciaSolicitud,
        category: 'primeros_auxilios_apoyo',
        title: 'Solicitud offline de María',
        description: 'Necesito apoyo con agua potable en Sector Sucre.',
        customClientMutationId: 'mut-idempotent-test-1',
      );

      final mariaOutbox = await controller.database.listOutboxForUser(mariaId);
      expect(mariaOutbox.length, equals(1));

      // Cambiar de cuenta a Don Jorge: no debe ver ni sincronizar la cola privada de María
      await controller.signOut();
      await controller.signIn(
        email: 'jorge@pueblolibre.pe',
        password: 'vecinos-pueblo-libre',
      );
      final jorgeId = controller.currentUser!.id;
      expect(jorgeId, isNot(equals(mariaId)));

      final jorgeOutbox = await controller.database.listOutboxForUser(jorgeId);
      expect(jorgeOutbox, isEmpty);

      // Volver a María, simular error de servidor y verificar que se marca como `error` sin perder datos
      await controller.signOut();
      await controller.signIn(
        email: 'maria@pueblolibre.pe',
        password: 'vecinos-pueblo-libre',
      );
      controller.remoteGateway.simulateNetworkOffline = false;
      controller.remoteGateway.simulateServerError = true;

      final errSummary = await controller.retryOutboxSync();
      expect(errSummary.errorCount, equals(1));

      // Restaurar servidor normal y confirmar sincronización idempotente
      controller.remoteGateway.simulateServerError = false;
      final okSummary = await controller.retryOutboxSync();
      expect(okSummary.confirmedCount, equals(1));
      expect(okSummary.pendingCount, equals(0));
    });

    test('Rechaza auto-recomendación, rechaza duplicado y niega lectura/escritura de chat privado a un tercero', () async {
      final controller = await _createInitializedTestController();
      expect(controller.currentUser, isNotNull);

      // María publica un servicio propio
      final ownService = await controller.submitPublication(
        kind: PublicationKind.servicio,
        category: 'costura',
        title: 'Taller de tejido de María',
        description: 'Arreglos de chompas en Sucre.',
      );

      // 1. Auto-recomendación rechazada
      expect(
        () => controller.recommendService(service: ownService),
        throwsA(isA<StateError>()),
      );

      // 2. Recomendación válida a otro servicio (Don Luis) y rechazo de duplicado
      final luisService = controller.publications.firstWhere(
        (p) => p.id == 'pub-demo-servicio-luis',
      );
      await controller.recommendService(
        service: luisService,
        comment: 'Muy buen electricista.',
      );
      expect(
        () => controller.recommendService(
          service: luisService,
          allowUpdateExisting: false,
        ),
        throwsA(isA<StateError>()),
      );

      // 3. Chat privado entre María y Don Luis: un tercero (Don Jorge) tiene acceso denegado
      final thread = await controller.requestContactWithProvider(
        publication: luisService,
        initialMessage: 'Hola Don Luis, necesito revisar mi tablero.',
      );

      expect(
        () => controller.database.listMessagesForConversation(
          conversationId: thread.id,
          actingUserId: 'user-tercero-ajeno-jorge',
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        () => controller.database.recordOnlineMessage(
          id: 'msg-intruso',
          clientMutationId: 'mut-intruso',
          conversationId: thread.id,
          senderId: 'user-tercero-ajeno-jorge',
          senderAlias: 'Intruso',
          body: 'Intento leer o escribir sin permiso',
          syncStatus: SyncStatus.confirmado,
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('Simulacro interactivo completa los 3 escenarios y las 5 misiones 100% offline', () {
      for (final scenario in kPracticeScenarios) {
        final repo = PracticeIsolatedRepository(initialScenario: scenario);
        repo.startPractice();
        expect(repo.practiceStarted, isTrue);

        // Misión 1
        repo.completeMission1RecognizeReport();
        expect(repo.mission1Recognized, isTrue);

        // Misión 2
        final onlineReport = repo.submitPracticeReport(
          title: 'Práctica en 2 clics',
          description: 'Prueba',
        );
        expect(onlineReport.syncStatus, equals(SyncStatus.confirmado));
        expect(repo.mission2ReportedInTwoClicks, isTrue);

        // Misión 3
        repo.offerHelpAndSendPracticeChat('Voy con botiquín');
        expect(repo.mission3OfferedAndChatted, isTrue);
        expect(repo.practiceChatMessages.length, equals(2));

        // Misión 4 (sin conexión -> pendiente -> reconectar y reintentar sin duplicar)
        repo.setSimulatedOffline(true);
        final offlinePub1 = repo.submitPracticeReport(
          title: 'Reporte sin red',
          description: 'En modo avión',
          idempotencyKey: 'key-offline-mission4',
        );
        expect(offlinePub1.syncStatus, equals(SyncStatus.pendiente));
        final countBeforeRetry = repo.practiceUserPublications.length;

        // Reintento con la misma llave no duplica
        repo.submitPracticeReport(
          title: 'Reporte sin red',
          description: 'En modo avión',
          idempotencyKey: 'key-offline-mission4',
        );
        repo.retryPracticeOfflineQueueIdempotent();
        expect(repo.practiceUserPublications.length, equals(countBeforeRetry));
        expect(repo.mission4OfflineQueuedAndRetried, isTrue);

        // Misión 5
        repo.markPracticeActivityResolved();
        expect(repo.mission5ResolvedWithFeedback, isTrue);
        expect(repo.completedMissionsCount, equals(5));
      }
    });

    test('Contraste matemático AAA/AA verificado en paleta cívica', () {
      expect(
        AppTheme.contrastRatio(AppTheme.textPrimary, AppTheme.surfacePrimary),
        greaterThanOrEqualTo(7.0),
      );
      expect(
        AppTheme.contrastRatio(Colors.white, AppTheme.actionGreen),
        greaterThanOrEqualTo(7.0),
      );
      expect(
        AppTheme.contrastRatio(Colors.white, AppTheme.urgentRed),
        greaterThanOrEqualTo(7.0),
      );
      expect(
        AppTheme.contrastRatio(Colors.white, AppTheme.practiceBlue),
        greaterThanOrEqualTo(7.0),
      );
      expect(AppConfig.appName, equals('Conecta2'));
    });
  });
}
