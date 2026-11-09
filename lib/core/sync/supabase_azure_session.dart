part of 'entra_mobile_session.dart';

/// Supabase Auth mantiene la sesión. El perfil y las operaciones viven en Azure.
class SupabaseAzureSession extends EntraMobileSession {
  GoTrueClient get _auth => Supabase.instance.client.auth;

  @override
  String get _storageKey =>
      'conecta2_supabase_auth:${AppConfig.supabaseUrl}:${EntraMobileSession.apiUrl}';

  @override
  bool get configured {
    if (!_apiConfigured || !AppConfig.hasSupabaseCredentials) return false;
    try {
      Supabase.instance.client;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<UserProfile> signInWithPassword(String email, String password) async {
    if (!configured) {
      throw StateError('Configura Supabase Auth y la API de Azure.');
    }
    final response = await _auth.signInWithPassword(
      email: email.trim(),
      password: password,
    );
    final user = response.user;
    if (user == null) throw const AzureApiError(401);
    return _loadProfile(user);
  }

  Future<UserProfile> registerWithPassword(
    String email,
    String password,
    String alias,
  ) async {
    if (!configured) {
      throw StateError('Configura Supabase Auth y la API de Azure.');
    }
    final response = await _auth.signUp(
      email: email.trim(),
      password: password,
      data: {'alias': alias.trim()},
      emailRedirectTo: AppConfig.authRedirectUrl,
    );
    if (response.session == null || response.user == null) {
      throw StateError(
        'Cuenta creada. Confirma tu correo y luego inicia sesión.',
      );
    }
    return _loadProfile(response.user!);
  }

  @override
  Future<String> _token() async {
    final session = _auth.currentSession;
    if (session == null) throw const AzureApiError(401);
    if (!session.isExpired) return session.accessToken;
    return _refreshing ??= _refreshAuthToken().whenComplete(
      () => _refreshing = null,
    );
  }

  Future<String> _refreshAuthToken() async {
    final refreshed = (await _auth.refreshSession().timeout(
      const Duration(seconds: 8),
    )).session;
    if (refreshed == null) throw const AzureApiError(401);
    return refreshed.accessToken;
  }

  Future<UserProfile> _loadProfile(User user) async {
    final storedAlias = user.userMetadata?['alias'];
    final alias = storedAlias is String ? storedAlias.trim() : '';
    Map<String, Object?> result;
    try {
      result = await request('GET', 'me');
    } on AzureApiError catch (error) {
      if (error.status != 404 || _auth.currentUser?.id != user.id) rethrow;
      result = await request(
        'PUT',
        'me',
        body: {
          'alias':
              alias.runes.length >= 2 &&
                  alias.runes.length <= 60 &&
                  !alias.contains('\u0000')
              ? alias
              : 'Vecino',
        },
      );
    }
    if (result['id'] != user.id || _auth.currentUser?.id != user.id) {
      throw const AzureApiError(401);
    }
    offlineProfile = false;
    return profile = UserProfile.fromSqlMap({
      ...result,
      'email': user.email ?? '',
    });
  }

  @override
  Future<UserProfile?> restore() async {
    if (!configured) return null;
    final user = _auth.currentUser;
    if (user == null) {
      profile = null;
      return null;
    }
    try {
      return await _loadProfile(user);
    } on AzureApiError catch (error) {
      if (error.status == 401 || error.status == 403) return null;
    } on AuthRetryableFetchException {
      // La sesión local permite consultar la copia guardada sin conexión.
    } on AuthException {
      return null;
    } on TimeoutException {
      // Azure puede estar temporalmente fuera de alcance.
    } on http.ClientException {
      // Conserva la misma identidad al consultar los datos locales.
    }
    if (_auth.currentUser?.id != user.id) return null;
    offlineProfile = true;
    if (profile?.id == user.id) return profile;
    return profile = UserProfile.fromSqlMap({
      'id': user.id,
      'email': user.email ?? '',
    });
  }

  @override
  Future<void> signOut() async {
    try {
      await super.signOut();
    } finally {
      await _auth.signOut(scope: SignOutScope.local);
    }
  }
}
