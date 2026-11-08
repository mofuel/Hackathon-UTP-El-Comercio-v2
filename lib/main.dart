import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/accessibility/accessibility_controller.dart';
import 'core/accessibility/text_input_support.dart';
import 'core/config/app_config.dart';
import 'core/database/local_sqlite_database.dart';
import 'core/notifications/push_notification_service.dart';
import 'core/state/app_controller.dart';
import 'core/sync/azure_remote_gateway.dart';
import 'core/sync/outbox_sync_service.dart';
import 'core/sync/supabase_remote_gateway.dart';
import 'core/theme/app_theme.dart';
import 'features/activities/my_activities_and_profile_screen.dart';
import 'features/auth/auth_and_onboarding_screen.dart';
import 'features/auth/password_recovery_screen.dart';
import 'features/chat/chat_screens.dart';
import 'features/chat/emergency_group_chat_screen.dart';
import 'features/chat/private_message_push_widgets.dart';
import 'features/emergencies/emergency_hub_screen.dart';
import 'features/favors/favor_detail_screen.dart';
import 'features/favors/favors_screen.dart';
import 'features/home/home_screen.dart';
import 'features/maps/explore_map_screen.dart';
import 'features/practice/practice_simulator.dart';
import 'features/publish/publish_screen.dart';
import 'features/services/service_detail_screen.dart';
import 'features/services/services_directory_screen.dart';
import 'features/shared/civic_widgets.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(PushNotificationService.instance.initialize());

  if (!AzureRemoteGateway.requested && AppConfig.hasSupabaseCredentials) {
    try {
      await Supabase.initialize(
        url: AppConfig.supabaseUrl,
        publishableKey: AppConfig.supabaseAnonKey,
        authOptions: FlutterAuthClientOptions(
          detectSessionInUriPredicate: AppConfig.isAuthCallbackUri,
        ),
      );
    } catch (_) {
      // Si el dispositivo arranca en modo avión desde primera instalación,
      // continúa con SQLite local y cola Outbox sin bloquear el arranque.
    }
  }

  final database = LocalSqliteDatabase();
  final remoteGateway = AzureRemoteGateway.requested
      ? AzureRemoteGateway()
      : SupabaseRemoteGateway();
  final outboxSyncService = OutboxSyncService(
    database: database,
    remoteGateway: remoteGateway,
  );
  final appController = AppController(
    database: database,
    remoteGateway: remoteGateway,
    outboxSyncService: outboxSyncService,
  );
  final accessibilityController = AccessibilityController();

  await appController.initialize(startWithActiveSession: true);

  runApp(
    Conecta2App(
      appController: appController,
      accessibilityController: accessibilityController,
    ),
  );
}

/// Aplicación principal de Conecta2.
class Conecta2App extends StatelessWidget {
  const Conecta2App({
    super.key,
    required this.appController,
    required this.accessibilityController,
  });

  final AppController appController;
  final AccessibilityController accessibilityController;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([appController, accessibilityController]),
      builder: (context, _) {
        final mediaReduceMotion =
            MediaQuery.maybeDisableAnimationsOf(context) ?? false;
        final reduceMotion = accessibilityController.effectiveReduceMotion(
          mediaReduceMotion,
        );

        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: '${AppConfig.appName} — ${AppConfig.subtitle}',
          theme: AppTheme.buildTheme(reduceMotion: reduceMotion),
          builder: (context, child) {
            final currentMedia = MediaQuery.of(context);
            final systemFactor = currentMedia.textScaler.scale(1.0);
            final combinedFactor =
                systemFactor * accessibilityController.userTextScaleMultiplier;

            return MediaQuery(
              data: currentMedia.copyWith(
                textScaler: TextScaler.linear(combinedFactor),
                disableAnimations: reduceMotion,
              ),
              child: child ?? const SizedBox.shrink(),
            );
          },
          home: PrivateMessagePushListener(
            key: ObjectKey(appController),
            controller: appController,
            child: _MainCivicShell(
              controller: appController,
              accessibilityController: accessibilityController,
            ),
          ),
        );
      },
    );
  }
}

class _MainCivicShell extends StatelessWidget {
  const _MainCivicShell({
    required this.controller,
    required this.accessibilityController,
  });

  final AppController controller;
  final AccessibilityController accessibilityController;

  @override
  Widget build(BuildContext context) {
    final section = controller.currentSection;
    final showBack = section != AppSection.inicio;
    final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    if (controller.passwordRecoveryPending) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Recuperar contraseña'),
          automaticallyImplyLeading: false,
        ),
        body: SafeArea(
          child: KeyboardDismissibleBody(
            keyboardVisible: keyboardVisible,
            child: PasswordRecoveryScreen(controller: controller),
          ),
        ),
      );
    }
    if (section == AppSection.practicaSimulacro) {
      return Scaffold(
        body: SafeArea(
          child: KeyboardDismissibleBody(
            keyboardVisible: keyboardVisible,
            child: PracticeSimulatorScreen(
              database: controller.database,
              onExitPractice: controller.goHome,
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: CivicAppBar(
        title: AppConfig.appName,
        height:
            (MediaQuery.textScalerOf(context).scale(1) > 1.3 ? 164 : 100) +
            (showBack ? 56 : 0),
        neighborhoodLabel:
            '${controller.activeNeighborhood} · ${controller.activeSector}',
        accessibilityController: accessibilityController,
        showBackButton: showBack,
        onBackTap: controller.goBack,
        isOffline: controller.isOfflineMode,
        onProfileTap: () => controller.navigateTo(AppSection.misActividades),
      ),
      body: SafeArea(
        child: KeyboardDismissibleBody(
          keyboardVisible: keyboardVisible,
          child: _buildActiveSectionBody(),
        ),
      ),
      bottomNavigationBar: _buildAccessibleBottomNav(),
    );
  }

  Widget _buildActiveSectionBody() {
    switch (controller.currentSection) {
      case AppSection.inicio:
        return HomeScreen(controller: controller);
      case AppSection.publicarRapido:
        return PublishScreen(controller: controller);
      case AppSection.servicios:
        return ServicesDirectoryScreen(controller: controller);
      case AppSection.detalleServicio:
        return ServiceDetailScreen(controller: controller);
      case AppSection.favores:
        return FavorsScreen(controller: controller);
      case AppSection.detalleFavor:
        return FavorDetailScreen(controller: controller);
      case AppSection.explorarMapa:
        return ExploreMapScreen(controller: controller);
      case AppSection.emergencias:
        return EmergencyHubScreen(controller: controller);
      case AppSection.chatEmergencia:
        return EmergencyGroupChatScreen(controller: controller);
      case AppSection.chatLista:
        return ChatListScreen(controller: controller);
      case AppSection.chatConversacion:
        return ChatConversationScreen(
          key: ValueKey(controller.selectedConversation?.id),
          controller: controller,
        );
      case AppSection.misActividades:
        return MyActivitiesAndProfileScreen(controller: controller);
      case AppSection.autenticacion:
        return AuthAndOnboardingScreen(controller: controller);
      case AppSection.practicaSimulacro:
        return PracticeSimulatorScreen(
          database: controller.database,
          onExitPractice: controller.goHome,
        );
    }
  }

  Widget _buildAccessibleBottomNav() {
    final destinations = <(String, IconData, VoidCallback)>[
      ('Inicio', Icons.home_outlined, controller.goHome),
      (
        'Servicios',
        Icons.search,
        () => controller.navigateTo(AppSection.servicios),
      ),
      (
        'Actividad',
        Icons.person_outline,
        () => controller.navigateTo(AppSection.misActividades),
      ),
      (
        'Chats',
        Icons.chat_bubble_outline,
        () => controller.navigateTo(AppSection.chatLista),
      ),
    ];
    return SafeArea(
      top: false,
      child: Material(
        color: AppTheme.surfaceCard,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final destination in destinations)
              Expanded(
                child: TextButton(
                  key: ValueKey('nav_${destination.$1.toLowerCase()}'),
                  onPressed: destination.$3,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(destination.$2),
                      const SizedBox(height: 4),
                      Text(
                        destination.$1,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 16),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
