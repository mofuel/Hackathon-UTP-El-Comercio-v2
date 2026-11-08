import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

/// Recepción de notificaciones móviles compartida por las funciones de la app.
final class PushNotificationService {
  PushNotificationService._();

  static final instance = PushNotificationService._();

  Future<FirebaseMessaging?>? _initialization;

  Future<FirebaseMessaging?> get _messaging =>
      _initialization ??= _initializeMessaging();

  Future<void> initialize() async {
    await _messaging;
  }

  /// Pide permiso únicamente cuando el usuario decide activar notificaciones.
  Future<AuthorizationStatus?> requestPermission() async {
    final messaging = await _messaging;
    return (await messaging?.requestPermission())?.authorizationStatus;
  }

  Future<bool> get isAvailable async => await _messaging != null;

  /// Registra la instalación solo después de obtener el permiso del sistema.
  Future<String?> registerInstallation() async {
    final messaging = await _messaging;
    if (messaging == null) return null;
    final settings = await messaging.getNotificationSettings();
    if (settings.authorizationStatus != AuthorizationStatus.authorized &&
        settings.authorizationStatus != AuthorizationStatus.provisional) {
      return null;
    }
    if (defaultTargetPlatform == TargetPlatform.iOS &&
        await messaging.getAPNSToken() == null) {
      return null;
    }

    final registration = Completer<String?>();
    final subscription = messaging.onRegistered.listen(
      (id) {
        if (!registration.isCompleted) registration.complete(id);
      },
      onError: (Object _) {
        if (!registration.isCompleted) registration.complete(null);
      },
    );
    try {
      await messaging.register();
      return await registration.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => null,
      );
    } finally {
      await subscription.cancel();
    }
  }

  Stream<RemoteMessage> get foregroundMessages async* {
    if (await _messaging != null) yield* FirebaseMessaging.onMessage;
  }

  Future<bool> unregisterInstallation() async {
    final messaging = await _messaging;
    if (messaging == null) return false;
    final result = Completer<bool>();
    final subscription = messaging.onUnregistered.listen(
      (_) {
        if (!result.isCompleted) result.complete(true);
      },
      onError: (Object _) {
        if (!result.isCompleted) result.complete(false);
      },
    );
    try {
      await messaging.unregister().timeout(const Duration(seconds: 2));
      return await result.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () => false,
      );
    } finally {
      await subscription.cancel();
    }
  }

  Stream<RemoteMessage> get openedMessages async* {
    if (await _messaging != null) yield* FirebaseMessaging.onMessageOpenedApp;
  }

  /// Recupera el aviso que abrió una app que estaba cerrada.
  Future<RemoteMessage?> takeInitialMessage() async {
    final messaging = await _messaging;
    return messaging?.getInitialMessage();
  }

  Future<FirebaseMessaging?> _initializeMessaging() async {
    final options = _mobileOptions();
    if (options == null) return null;

    try {
      await Firebase.initializeApp(options: options);
      final messaging = FirebaseMessaging.instance;
      return await messaging.isSupported() ? messaging : null;
    } catch (error) {
      debugPrint(
        'No se pudo iniciar Firebase Messaging (${error.runtimeType}).',
      );
      return null;
    }
  }

  FirebaseOptions? _mobileOptions() {
    if (kIsWeb) return null;
    final (appId, apiKey) = switch (defaultTargetPlatform) {
      TargetPlatform.android => (
        const String.fromEnvironment('FIREBASE_ANDROID_APP_ID'),
        const String.fromEnvironment('FIREBASE_ANDROID_API_KEY'),
      ),
      TargetPlatform.iOS => (
        const String.fromEnvironment('FIREBASE_IOS_APP_ID'),
        const String.fromEnvironment('FIREBASE_IOS_API_KEY'),
      ),
      _ => ('', ''),
    };
    const projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
    const senderId = String.fromEnvironment('FIREBASE_MESSAGING_SENDER_ID');
    if ([
      appId,
      apiKey,
      projectId,
      senderId,
    ].any((value) => value.trim().isEmpty)) {
      return null;
    }

    return FirebaseOptions(
      apiKey: apiKey,
      appId: appId,
      messagingSenderId: senderId,
      projectId: projectId,
    );
  }
}
