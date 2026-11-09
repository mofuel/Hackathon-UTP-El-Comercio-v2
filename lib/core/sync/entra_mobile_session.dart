import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_appauth/flutter_appauth.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/app_config.dart';
import '../models/domain_models.dart';
import '../models/entity_id.dart';

part 'supabase_azure_session.dart';

class AzureApiError implements Exception {
  const AzureApiError(this.status);
  final int status;
}

class EntraMobileSession {
  static const apiUrl = String.fromEnvironment('CONECTA2_API_URL');
  static const _subdomain = String.fromEnvironment('ENTRA_TENANT_SUBDOMAIN');
  static const _tenantId = String.fromEnvironment('ENTRA_TENANT_ID');
  static const _apiClientId = String.fromEnvironment('ENTRA_API_CLIENT_ID');
  static const _mobileClientId = String.fromEnvironment(
    'ENTRA_MOBILE_CLIENT_ID',
  );
  static const _redirect = 'pe.vecinos.app.entra://oauth/callback';
  static const _discovery =
      'https://$_subdomain.ciamlogin.com/$_tenantId/v2.0/.well-known/openid-configuration';
  static const _scopes = [
    'openid',
    'profile',
    'offline_access',
    'api://$_apiClientId/access_as_user',
  ];

  final _appAuth = const FlutterAppAuth();
  final _storage = const FlutterSecureStorage();
  final _client = http.Client();

  UserProfile? profile;
  bool offlineProfile = false;
  String? _accessToken;
  String? _refreshToken;
  DateTime? _expiresAt;
  Future<String>? _refreshing;
  int _generation = 0;

  String get _storageKey =>
      'conecta2_entra:$_tenantId:$_mobileClientId:$apiUrl';

  Future<String>? _pushDevice;
  Future<String> pushDeviceId() => _pushDevice ??= _loadPushDevice();

  Future<String> _loadPushDevice() async {
    final key = '$_storageKey:pushDevice';
    final current = await _storage.read(key: key);
    if (current != null) return current;
    final id = EntityId.create();
    await _storage.write(key: key, value: id);
    return id;
  }

  Future<String?> readPushOwner() =>
      _storage.read(key: '$_storageKey:pushOwner');

  Future<void> setPushOwner(String? owner) => owner == null
      ? _storage.delete(key: '$_storageKey:pushOwner')
      : _storage.write(key: '$_storageKey:pushOwner', value: owner);

  bool get _apiConfigured {
    final url = Uri.tryParse(apiUrl);
    return url != null &&
        url.host.isNotEmpty &&
        url.userInfo.isEmpty &&
        !url.hasQuery &&
        !url.hasFragment &&
        (url.scheme == 'https' ||
            (kDebugMode &&
                url.scheme == 'http' &&
                const [
                  '127.0.0.1',
                  'localhost',
                  '10.0.2.2',
                ].contains(url.host)));
  }

  bool get configured =>
      _apiConfigured &&
      _subdomain.isNotEmpty &&
      _tenantId.isNotEmpty &&
      _apiClientId.isNotEmpty &&
      _mobileClientId.isNotEmpty;

  Future<UserProfile> signIn(String alias) async {
    if (!configured) {
      throw StateError('Configura el servidor de Conecta2 y Microsoft Entra.');
    }
    final generation = ++_generation;
    try {
      final tokens = await _appAuth.authorizeAndExchangeCode(
        AuthorizationTokenRequest(
          _mobileClientId,
          _redirect,
          discoveryUrl: _discovery,
          scopes: _scopes,
          promptValues: ['select_account'],
        ),
      );
      _acceptTokens(tokens, generation);
      Map<String, Object?> result;
      try {
        result = await request('GET', 'me');
      } on AzureApiError catch (error) {
        if (error.status != 404) rethrow;
        result = await request(
          'PUT',
          'me',
          body: {'alias': alias.trim().isEmpty ? 'Vecino' : alias.trim()},
        );
      }
      _checkGeneration(generation);
      final signedIn = UserProfile.fromSqlMap(result);
      profile = signedIn;
      await _persist();
      return signedIn;
    } catch (_) {
      if (generation == _generation) await signOut();
      rethrow;
    }
  }

  Future<UserProfile?> restore() async {
    if (!configured) return null;
    final generation = _generation;
    if (_refreshToken == null && profile == null) {
      final stored = await _storage.read(key: _storageKey);
      if (stored == null) return null;
      final record = jsonDecode(stored) as Map<String, dynamic>;
      _checkGeneration(generation);
      _refreshToken = record['refresh'] as String;
      profile = UserProfile.fromSqlMap(
        Map<String, Object?>.from(record['profile'] as Map),
      );
    }
    try {
      final remote = UserProfile.fromSqlMap(await request('GET', 'me'));
      _checkGeneration(generation);
      if (profile != null && profile!.id != remote.id) {
        await signOut();
        return null;
      }
      profile = remote;
      offlineProfile = false;
      await _persist();
      return remote;
    } on AzureApiError catch (error) {
      if (const [401, 403, 404].contains(error.status)) {
        if (generation == _generation) await signOut();
        return null;
      }
    } on FlutterAppAuthPlatformException catch (error) {
      if (error.platformErrorDetails.error == 'invalid_grant') {
        if (generation == _generation) await signOut();
        return null;
      }
    } on TimeoutException {
      // La caché corresponde a la última identidad validada en este teléfono.
    } on http.ClientException {
      // El perfil guardado sigue disponible cuando la red no responde.
    }
    offlineProfile = true;
    return generation == _generation ? profile : null;
  }

  Future<void> signOut() async {
    ++_generation;
    profile = null;
    offlineProfile = false;
    _refreshToken = null;
    _accessToken = null;
    _expiresAt = null;
    final pending = _refreshing;
    if (pending != null) {
      try {
        await pending;
      } catch (_) {
        /* Session already invalidated. */
      }
    }
    await _storage.delete(key: _storageKey);
  }

  Future<Map<String, Object?>> request(
    String method,
    String path, {
    Map<String, String> query = const {},
    Object? body,
    bool guest = false,
  }) async {
    if (!configured) {
      throw StateError('El servidor de Conecta2 no está configurado.');
    }
    final url = Uri.parse(
      '${apiUrl.replaceFirst(RegExp(r'/+$'), '')}/api/v1/$path',
    );
    final generation = _generation;
    final token = guest ? null : await _token();
    _checkGeneration(generation);
    final request = http.Request(
      method,
      url.replace(queryParameters: query.isEmpty ? null : query),
    )..followRedirects = false;
    if (token != null) request.headers['Authorization'] = 'Bearer $token';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final response = await _client
        .send(request)
        .then(http.Response.fromStream)
        .timeout(const Duration(seconds: 14));
    _checkGeneration(generation);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AzureApiError(response.statusCode);
    }
    return Map<String, Object?>.from(jsonDecode(response.body) as Map);
  }

  Future<String> _token() async {
    final current = _accessToken;
    if (current != null &&
        _expiresAt!.isAfter(DateTime.now().add(const Duration(seconds: 30)))) {
      return current;
    }
    final refresh = _refreshToken;
    if (refresh == null) throw const AzureApiError(401);
    return _refreshing ??= _renew(
      refresh,
      _generation,
    ).whenComplete(() => _refreshing = null);
  }

  Future<String> _renew(String refresh, int generation) async {
    final tokens = await _appAuth
        .token(
          TokenRequest(
            _mobileClientId,
            _redirect,
            discoveryUrl: _discovery,
            scopes: _scopes,
            refreshToken: refresh,
          ),
        )
        .timeout(const Duration(seconds: 12));
    _acceptTokens(tokens, generation);
    await _persist();
    _checkGeneration(generation);
    return _accessToken!;
  }

  void _acceptTokens(TokenResponse response, int generation) {
    _checkGeneration(generation);
    final access = response.accessToken;
    final refresh = response.refreshToken ?? _refreshToken;
    if (access == null || refresh == null) {
      throw StateError('Entra no devolvió una sesión renovable.');
    }
    _accessToken = access;
    _refreshToken = refresh;
    _expiresAt =
        response.accessTokenExpirationDateTime ??
        DateTime.now().add(const Duration(minutes: 2));
  }

  void _checkGeneration(int generation) {
    if (generation != _generation) throw const AzureApiError(401);
  }

  Future<void> _persist() async {
    if (_refreshToken == null || profile == null) return;
    await _storage.write(
      key: _storageKey,
      value: jsonEncode({
        'refresh': _refreshToken,
        'profile': profile!.toSqlMap(),
      }),
    );
  }
}
