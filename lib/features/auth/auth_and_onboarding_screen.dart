import '../../core/accessibility/text_input_support.dart';

import 'package:geolocator/geolocator.dart';
import 'package:flutter/material.dart';

import '../../core/config/app_config.dart';
import '../../core/geography/peru_location_catalog.dart';
import '../shared/peru_location_selector.dart';
import '../../core/state/app_controller.dart';
import '../../core/theme/app_theme.dart';
import 'auth_error_message.dart';
import '../maps/location_picker_screen.dart';
import '../../core/maps/carto_basemap.dart';
import '../../core/maps/chosen_map_location.dart';

/// Pantalla de registro, inicio de sesión, cambio de cuenta, cierre de sesión
/// y configuración de zona manual / ubicación opcional por GPS.
/// Cumple las reglas del encargo:
/// - Nunca bloquea a quien rechaza el permiso de ubicación GPS (permite elegir
///   barrio o sector manualmente).
/// - Si el usuario llegó aquí por una acción que requería sesión, muestra la
///   intención conservada y la retoma automáticamente al autenticarse.
class AuthAndOnboardingScreen extends StatefulWidget {
  const AuthAndOnboardingScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<AuthAndOnboardingScreen> createState() =>
      _AuthAndOnboardingScreenState();
}

class _AuthAndOnboardingScreenState extends State<AuthAndOnboardingScreen> {
  bool _isRegisterMode = false;
  bool _submitting = false;
  bool _requestRecovery = false;
  bool _recoveryEmailSent = false;

  final TextEditingController _aliasController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  final _locationKey = GlobalKey<FormFieldState<PeruLocationSelection>>();
  final _sectorController = TextEditingController();
  PeruLocationSelection _location = const PeruLocationSelection.empty();
  bool _locationChanged = false;
  bool _useOptionalGps = false;
  double? _pinLat;
  double? _pinLng;
  double? _gpsLat;
  double? _gpsLng;
  bool _requestingGps = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _location = widget.controller.locationCatalog.selectionForDistrict(
      widget.controller.activeDistrictUbigeo,
    );
    _sectorController.text = widget.controller.activeSector;
    _gpsLat = widget.controller.activeUsesGps
        ? widget.controller.activeLat
        : null;
    _gpsLng = widget.controller.activeUsesGps
        ? widget.controller.activeLng
        : null;
    _useOptionalGps = widget.controller.activeUsesGps;
  }

  @override
  void dispose() {
    _sectorController.dispose();
    _aliasController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  ({String name, String sector, String? code, double? lat, double? lng})
  _formLocation() {
    final c = widget.controller;
    final district = c.locationCatalog.district(_location.districtCode);
    if (district == null) {
      if (!_locationChanged && c.currentUser != null) {
        return (
          name: c.activeNeighborhood,
          sector: _sectorController.text.trim().isEmpty
              ? c.activeSector
              : _sectorController.text.trim(),
          code: c.activeDistrictUbigeo,
          lat: c.activeLat,
          lng: c.activeLng,
        );
      }
      throw StateError('Selecciona departamento, provincia y distrito.');
    }
    return (
      name: district.name,
      sector: _sectorController.text.trim().isEmpty
          ? 'Zona general del distrito'
          : _sectorController.text.trim(),
      code: district.code,
      lat:
          _pinLat ??
          (_useOptionalGps
              ? _gpsLat
              : !_locationChanged
              ? c.activeLat
              : district.capitalLat),
      lng:
          _pinLng ??
          (_useOptionalGps
              ? _gpsLng
              : !_locationChanged
              ? c.activeLng
              : district.capitalLng),
    );
  }

  Future<void> _toggleGps(bool enabled) async {
    if (!enabled) {
      setState(() {
        _useOptionalGps = false;
        _gpsLat = null;
        _gpsLng = null;
      });
      return;
    }
    setState(() {
      _requestingGps = true;
      _errorMessage = null;
    });
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw StateError(
          'Activa la ubicación del teléfono o elige tu zona manualmente.',
        );
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        throw StateError('Puedes continuar eligiendo tu barrio manualmente.');
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.low,
          timeLimit: Duration(seconds: 20),
        ),
      );
      if (!mounted) return;
      setState(() {
        _pinLat = null;
        _pinLng = null;
        _gpsLat = AppConfig.roundPublicCoordinate(position.latitude);
        _gpsLng = AppConfig.roundPublicCoordinate(position.longitude);
        _useOptionalGps = true;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _useOptionalGps = false;
          _errorMessage = 'No se obtuvo ubicación. Puedes continuar con el barrio elegido manualmente.';
        });
      }
    } finally {
      if (mounted) setState(() => _requestingGps = false);
    }
  }

  Future<void> _handleAuthSubmit() async {
    FocusScope.of(context).unfocus();
    if (_submitting) return;
    setState(() {
      _errorMessage = null;
      _submitting = true;
    });
    try {
      if (widget.controller.usesAzureBackend) {
        await widget.controller.signInWithEntra(_aliasController.text);
      } else if (_requestRecovery) {
        if (_recoveryEmailSent) return;
        await widget.controller.requestPasswordReset(_emailController.text);
        if (mounted) setState(() => _recoveryEmailSent = true);
      } else if (_isRegisterMode) {
        if (!(_locationKey.currentState?.validate() ?? false)) return;
        final zone = _formLocation();
        await widget.controller.registerAndSignIn(
          alias: _aliasController.text,
          email: _emailController.text,
          password: _passwordController.text,
          neighborhood: zone.name,
          sector: zone.sector,
          approxLat: zone.lat,
          approxLng: zone.lng,
          useGpsApprox: _useOptionalGps,
          districtUbigeo: zone.code,
        );
      } else {
        await widget.controller.signIn(
          email: _emailController.text,
          password: _passwordController.text,
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = authErrorMessage(e);
        });
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _handleSaveLocationOnly() async {
    FocusScope.of(context).unfocus();
    if (!(_locationKey.currentState?.validate() ?? false)) return;
    try {
      final zone = _formLocation();
      await widget.controller.updateLocationPreference(
        neighborhood: zone.name,
        sector: zone.sector,
        districtUbigeo: zone.code,
        approxLat: zone.lat,
        approxLng: zone.lng,
        useGpsApprox: _useOptionalGps,
      );
      if (!mounted) return;
      setState(() => _locationChanged = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Zona guardada: ${zone.name} · ${zone.sector}')),
      );
    } catch (error) {
      if (mounted) {
        setState(() => _errorMessage = authErrorMessage(error));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final user = c.currentUser;
    final pendingIntent = c.pendingAuthIntent;

    return SingleChildScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (c.statusBannerMessage != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Semantics(
                liveRegion: true,
                child: Text(c.statusBannerMessage!),
              ),
            ),
          if (pendingIntent != null) ...[
            Container(
              key: const Key('banner_pending_auth_intent'),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF3CD),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppTheme.amberWarning, width: 1.5),
              ),
              child: Text(
                'Acción en espera: "${pendingIntent.description}". Inicia sesión o regístrate para retomarla inmediatamente.',
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.amberWarning,
                ),
              ),
            ),
            const SizedBox(height: 14),
          ],

          // Datos de la sesión activa y cierre de sesión.
          if (user != null) ...[
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppTheme.surfaceCard,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppTheme.actionGreen, width: 1.5),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Sesión activa: ${user.alias}',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Correo: ${user.email} · Zona: ${c.activeAdministrativeLocationLabel} (${user.sector})',
                    style: const TextStyle(
                      fontSize: 16,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      OutlinedButton.icon(
                        key: const Key('btn_sign_out'),
                        onPressed: c.signOut,
                        icon: const Icon(Icons.logout),
                        label: const Text('Cerrar sesión'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],

          // Selector manual de barrio/sector y ubicación aproximada por GPS opcional
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.surfaceCard,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppTheme.borderSoft),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Tu barrio y ubicación aproximada (Privacidad protegida)',
                  style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'El permiso de GPS es 100% opcional. Si prefieres no activarlo, elige tu distrito y sector manualmente sin ningún bloqueo. Nunca publicamos tu dirección exacta.',
                  style: TextStyle(
                    fontSize: 16,
                    color: AppTheme.textSecondary,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 12),
                if (c.currentUser != null &&
                    c.locationCatalog.district(c.activeDistrictUbigeo) == null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      'Ubicación anterior: ${c.activeNeighborhood} · ${c.activeSector}. Se conserva hasta que elijas un distrito; no se asigna un UBIGEO por el nombre.',
                    ),
                  ),
                PeruLocationSelector(
                  key: _locationKey,
                  catalog: c.locationCatalog,
                  value: _location,
                  isRequired:
                      _isRegisterMode || user == null || _locationChanged,
                  onChanged: (next) => setState(() {
                    if (next.districtCode != _location.districtCode) {
                      _sectorController.clear();
                      _useOptionalGps = false;
                      _gpsLat = null;
                      _gpsLng = null;
                      _pinLat = null;
                      _pinLng = null;
                    }
                    _locationChanged = true;
                    _location = next;
                  }),
                ),
                OutlinedButton.icon(
                  key: const Key('btn_choose_profile_pin'),
                  onPressed: _location.districtCode == null
                      ? null
                      : () async {
                          final district = c.locationCatalog.district(
                            _location.districtCode,
                          );
                          final choice =
                              await Navigator.push<ChosenMapLocation>(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => LocationPickerScreen(
                                    catalog: c.locationCatalog,
                                    districtUbigeo: _location.districtCode,
                                    initialPoint: approximateMapPoint(
                                      _pinLat ??
                                          (_locationChanged
                                              ? district?.capitalLat
                                              : c.activeLat),
                                      _pinLng ??
                                          (_locationChanged
                                              ? district?.capitalLng
                                              : c.activeLng),
                                    ),
                                  ),
                                ),
                              );
                          if (!mounted || choice == null) return;
                          setState(() {
                            _location = c.locationCatalog.selectionForDistrict(
                              choice.districtUbigeo,
                            );
                            _pinLat = choice.publicLat;
                            _pinLng = choice.publicLng;
                            _locationChanged = true;
                            _useOptionalGps = false;
                          });
                        },
                  icon: const Icon(Icons.add_location_alt_outlined),
                  label: Text(
                    _pinLat == null
                        ? 'Elegir punto en el mapa o buscar dirección'
                        : 'Cambiar punto seleccionado',
                  ),
                ),

                const SizedBox(height: 24),
                TextField(
                  key: const Key('input_location_reference'),
                  contextMenuBuilder: buildTextSelectionToolbar,
                  onTapOutside: dismissTextInput,
                  controller: _sectorController,
                  maxLength: 100,
                  decoration: const InputDecoration(
                    labelText: 'Barrio, sector o referencia (opcional)',
                    helperText: 'Conserva una referencia aproximada, sin dirección exacta.',
                    helperMaxLines: 3,
                  ),
                ),
                if (_location.districtCode != null && !_useOptionalGps)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      c.locationCatalog
                                  .district(_location.districtCode)
                                  ?.capitalLat ==
                              null
                          ? 'El distrito no tiene coordenadas de capital disponibles. Puedes continuar sin GPS: se mostrará por distrito, sin distancia ni marcador.'
                          : 'Sin GPS, una zona nueva usa la capital distrital publicada por el INEI como referencia aproximada.',
                    ),
                  ),
                const SizedBox(height: 10),
                Material(
                  type: MaterialType.transparency,
                  child: SwitchListTile(
                    key: const Key('switch_optional_gps'),
                    contentPadding: EdgeInsets.zero,
                    value: _useOptionalGps,
                    onChanged: _requestingGps ? null : _toggleGps,
                    title: const Text(
                      'Usar ubicación aproximada por GPS (opcional)',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    subtitle: const Text(
                      'Solo para calcular distancia a servicios cercanos; redondeada a nivel de sector.',
                      style: TextStyle(fontSize: 16),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  key: const Key('btn_save_manual_zone'),
                  onPressed: _handleSaveLocationOnly,
                  icon: const Icon(Icons.place_outlined),
                  label: const Text('Guardar zona seleccionada'),
                ),
              ],
            ),
          ),

          if (user == null && c.usesAzureBackend) ...[
            const SizedBox(height: 16),
            const Text('Inicia sesión, crea tu cuenta o recupera tu contraseña en el acceso seguro.'),
            const SizedBox(height: 12),
            TextField(
              controller: _aliasController,
              maxLength: 60,
              decoration: const InputDecoration(labelText: 'Alias para una cuenta nueva (opcional)'),
            ),
            if (_errorMessage != null) Text(_errorMessage!),
            ElevatedButton.icon(
              onPressed: _submitting ? null : _handleAuthSubmit,
              icon: const Icon(Icons.login),
              label: Text(_submitting ? 'Conectando…' : 'Continuar al acceso seguro'),
            ),
          ],
          if (user == null && !c.usesAzureBackend) ...[
            const SizedBox(height: 16),

            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppTheme.surfaceCard,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppTheme.borderSoft),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_requestRecovery)
                    Text(
                      'Recuperar contraseña',
                      style: Theme.of(context).textTheme.titleLarge,
                    )
                  else
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final mode in [false, true])
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Semantics(
                              selected: _isRegisterMode == mode,
                              child: OutlinedButton(
                                key: Key(
                                  mode ? 'tab_register_mode' : 'tab_login_mode',
                                ),
                                style: OutlinedButton.styleFrom(
                                  backgroundColor: _isRegisterMode == mode
                                      ? const Color(0xFFC8F5DF)
                                      : AppTheme.surfaceCard,
                                  minimumSize: const Size(0, 56),
                                ),
                                onPressed: _submitting
                                    ? null
                                    : () => setState(() {
                                        _isRegisterMode = mode;
                                        _errorMessage = null;
                                      }),
                                child: Text(
                                  mode
                                      ? 'Crear cuenta vecinal'
                                      : 'Iniciar sesión',
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  const SizedBox(height: 14),
                  if (_isRegisterMode) ...[
                    TextField(
                      contextMenuBuilder: buildTextSelectionToolbar,
                      onTapOutside: dismissTextInput,
                      key: const Key('input_auth_alias'),
                      controller: _aliasController,
                      style: const TextStyle(fontSize: 18),
                      decoration: const InputDecoration(
                        labelText: 'Tu nombre o alias público en el barrio',
                        hintText: 'Ej. Doña Rosa · Sector Candamo',
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  TextField(
                    contextMenuBuilder: buildTextSelectionToolbar,
                    onTapOutside: dismissTextInput,
                    key: const Key('input_auth_email'),
                    controller: _emailController,
                    keyboardType: TextInputType.emailAddress,
                    style: const TextStyle(fontSize: 18),
                    decoration: const InputDecoration(
                      labelText: 'Correo electrónico',
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (!_requestRecovery)
                    TextField(
                      contextMenuBuilder: buildTextSelectionToolbar,
                      onTapOutside: dismissTextInput,
                      key: const Key('input_auth_password'),
                      controller: _passwordController,
                      obscureText: true,
                      style: const TextStyle(fontSize: 18),
                      decoration: const InputDecoration(
                        labelText: 'Contraseña',
                      ),
                    ),
                  if (!_isRegisterMode && !_requestRecovery)
                    TextButton(
                      key: const Key('btn_forgot_password'),
                      onPressed: _submitting
                          ? null
                          : () => setState(() {
                              _requestRecovery = true;
                              _recoveryEmailSent = false;
                              _errorMessage = null;
                            }),
                      child: const Text('Olvidé mi contraseña'),
                    ),
                  if (_requestRecovery) ...[
                    const SizedBox(height: 12),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        _recoveryEmailSent
                            ? 'Si existe una cuenta con ese correo, recibirás un enlace para elegir una nueva contraseña. Revisa también el correo no deseado. Abre el enlace en este teléfono.'
                            : 'Escribe el correo de tu cuenta. Te enviaremos un enlace para abrir la recuperación en esta app.',
                      ),
                    ),
                    TextButton(
                      key: const Key('btn_back_from_recovery_request'),
                      onPressed: _submitting
                          ? null
                          : () => setState(() {
                              _requestRecovery = false;
                              _recoveryEmailSent = false;
                              _errorMessage = null;
                            }),
                      child: const Text('Volver a iniciar sesión'),
                    ),
                  ],
                  if (_errorMessage != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      _errorMessage!,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.urgentRed,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 58),
                    child: ElevatedButton.icon(
                      key: const Key('btn_submit_auth'),
                      onPressed: _submitting || _recoveryEmailSent
                          ? null
                          : _handleAuthSubmit,
                      icon: const Icon(Icons.login),
                      label: Text(
                        _submitting
                            ? 'Conectando…'
                            : _requestRecovery
                            ? (_recoveryEmailSent
                                  ? 'Correo solicitado'
                                  : 'Enviar enlace de recuperación')
                            : _isRegisterMode
                            ? 'Registrarme y entrar al barrio'
                            : 'Ingresar a mi cuenta',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
