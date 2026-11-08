import 'dart:convert';

import '../../core/accessibility/text_input_support.dart';

import 'package:flutter/material.dart';

import '../../core/models/domain_models.dart';
import '../../core/state/app_controller.dart';
import '../../core/theme/app_theme.dart';
import '../shared/civic_widgets.dart';
import '../maps/location_picker_screen.dart';
import '../../core/maps/chosen_map_location.dart';
import '../../core/maps/carto_basemap.dart';

/// Pantalla de publicación y reporte rápido que respeta estrictamente el
/// presupuesto de clics:
/// - Reportar emergencia: Clic 1 en Inicio -> escribir -> Clic 2 en `Enviar reporte`.
/// - Pedir ayuda: Clic 1 en Inicio -> escribir -> Clic 2 en `Enviar solicitud`.
/// - Publicar servicio o favor: Clic 1 en Inicio -> Clic 2 seleccionar tipo -> escribir -> Clic 3 en `Publicar en mi barrio`.
/// Sin modales obligatorios de confirmación posterior.
class PublishScreen extends StatefulWidget {
  const PublishScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<PublishScreen> createState() => _PublishScreenState();
}

class _PublishScreenState extends State<PublishScreen> {
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _descController = TextEditingController();
  final TextEditingController _availabilityController = TextEditingController();

  late PublicationKind _selectedKind;
  String _selectedCategory = 'general';
  bool _explicitResourceShareConsent = false;
  String? _errorMessage;
  bool _submitting = false;
  ChosenMapLocation? _location;

  bool get _isProduct => _selectedCategory == Publication.productCategory;
  String get _draftKey =>
      FormDraft.publicationKey(_selectedKind, _selectedCategory);
  bool get _hasDraftContent =>
      _titleController.text.trim().isNotEmpty ||
      _descController.text.trim().isNotEmpty ||
      _availabilityController.text.trim().isNotEmpty ||
      _location != null;

  @override
  void initState() {
    super.initState();
    _selectedKind = widget.controller.publishPresetKind;
    _selectedCategory = _defaultCategoryForKind(_selectedKind);
    _restoreExistingDraftIfAny();
  }

  String _defaultCategoryForKind(PublicationKind kind) {
    switch (kind) {
      case PublicationKind.anuncio:
        return 'general';
      case PublicationKind.servicio:
        return 'electricidad';
      case PublicationKind.favorSolicitud:
      case PublicationKind.favorOferta:
        return 'acompanamiento';
      case PublicationKind.prestamo:
        return 'herramientas';
      case PublicationKind.donacion:
        return 'donaciones';
      case PublicationKind.habilidad:
        return 'habilidades';
      case PublicationKind.emergenciaSolicitud:
      case PublicationKind.emergenciaOferta:
        return 'primeros_auxilios_apoyo';
    }
  }

  Future<void> _restoreExistingDraftIfAny() async {
    if (_hasDraftContent) return;
    final draftKey = _draftKey;
    final draft = await widget.controller.database.getDraft(
      ownerUserId:
          widget.controller.currentUser?.id ?? Publication.guestOwnerId,
      draftKey: draftKey,
    );
    if (draft != null &&
        mounted &&
        !_submitting &&
        draftKey == _draftKey &&
        !_hasDraftContent) {
      setState(() {
        _titleController.text = draft.title;
        _descController.text = draft.description;
        _availabilityController.text = draft.availabilityText;
        if (draft.locationJson.isNotEmpty) {
          try {
            _location = ChosenMapLocation.tryFromMap(
              jsonDecode(draft.locationJson) as Map<String, dynamic>,
            );
          } catch (_) {
            _location = null;
          }
        }
      });
    }
  }

  Future<void> _persistDraftSilently() async {
    if (_titleController.text.trim().isEmpty &&
        _descController.text.trim().isEmpty &&
        _location == null) {
      return;
    }
    await widget.controller.database.saveDraft(
      FormDraft(
        draftKey: _draftKey,
        ownerUserId:
            widget.controller.currentUser?.id ?? Publication.guestOwnerId,
        kind: _selectedKind,
        title: _titleController.text,
        description: _descController.text,
        category: _selectedCategory,
        locationJson: _location == null ? '' : jsonEncode(_location!.toMap()),
        availabilityText: _availabilityController.text,
        priority: _selectedKind.isEmergency
            ? PublicationPriority.emergencia
            : PublicationPriority.normal,
        updatedAt: DateTime.now().toUtc(),
      ),
    );
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descController.dispose();
    _availabilityController.dispose();
    super.dispose();
  }

  String get _submitButtonLabel {
    if (_selectedKind == PublicationKind.emergenciaSolicitud ||
        _selectedKind == PublicationKind.emergenciaOferta) {
      return 'Enviar reporte';
    }
    if (widget.controller.publishTypeLocked &&
        _selectedKind == PublicationKind.favorSolicitud) {
      return 'Enviar solicitud';
    }
    return 'Publicar en mi barrio';
  }

  Future<void> _handleSubmit() async {
    if (_submitting) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _errorMessage = null;
      _submitting = true;
    });

    try {
      await widget.controller.submitPublication(
        kind: _selectedKind,
        category: _selectedCategory,
        title: _titleController.text,
        description: _descController.text,
        availabilityText: _availabilityController.text,
        shareResourceConsent: _explicitResourceShareConsent,
        location: _location,
      );
      if (mounted) {
        _titleController.clear();
        _descController.clear();
        _availabilityController.clear();
        setState(() {
          _location = null;
          _explicitResourceShareConsent = false;
          _submitting = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      await _persistDraftSilently();
      if (mounted) {
        setState(() {
          _submitting = false;
          _errorMessage = e.toString().replaceFirst('Bad state: ', '');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final submitted = c.lastSubmittedPublication;

    return SingleChildScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (submitted != null) ...[
            _buildSubmittedResultCard(context, submitted),
            const SizedBox(height: 16),
          ],

          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.surfaceCard,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: _selectedKind.isEmergency
                    ? AppTheme.urgentRed
                    : AppTheme.borderSoft,
                width: _selectedKind.isEmergency ? 2 : 1.5,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  _selectedKind.isEmergency
                      ? 'Reporte comunitario de emergencia'
                      : c.publishTypeLocked
                      ? 'Solicitar ayuda solidaria al barrio'
                      : 'Publicar servicio u ofrecimiento vecinal',
                  style: TextStyle(
                    fontSize: 21,
                    fontWeight: FontWeight.w800,
                    color: _selectedKind.isEmergency
                        ? AppTheme.urgentRed
                        : AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _selectedKind.isEmergency
                      ? 'Tipo y prioridad de emergencia predefinidos para enviarlo en 1 toque después de escribir. Ubicación aproximada: ${c.activeAdministrativeLocationLabel} · ${c.activeSector} (nunca mostramos tu dirección exacta).'
                      : 'Ubicación aproximada de publicación: ${c.activeAdministrativeLocationLabel} · ${c.activeSector}. Los favores comunitarios son 100% gratuitos.',
                  style: const TextStyle(
                    fontSize: 16,
                    color: AppTheme.textSecondary,
                    height: 1.35,
                  ),
                ),

                if (!c.publishTypeLocked) ...[
                  const SizedBox(height: 14),
                  const Text(
                    '1. Elige qué deseas publicar:',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _buildKindSelectorChip(
                        key: const Key('chip_kind_servicio'),
                        kind: PublicationKind.servicio,
                        label: 'Oficio o servicio',
                      ),
                      _buildKindSelectorChip(
                        key: const Key('chip_kind_producto'),
                        kind: PublicationKind.anuncio,
                        category: Publication.productCategory,
                        label: 'Producto',
                      ),
                      _buildKindSelectorChip(
                        key: const Key('chip_kind_favor_oferta'),
                        kind: PublicationKind.favorOferta,
                        label: 'Ofrecer favor gratuito',
                      ),
                      _buildKindSelectorChip(
                        key: const Key('chip_kind_anuncio'),
                        kind: PublicationKind.anuncio,
                        label: 'Anuncio del barrio',
                      ),
                      _buildKindSelectorChip(
                        key: const Key('chip_kind_prestamo'),
                        kind: PublicationKind.prestamo,
                        label: 'Prestar o pedir herramienta',
                      ),
                      _buildKindSelectorChip(
                        key: const Key('chip_kind_favor_solicitud'),
                        kind: PublicationKind.favorSolicitud,
                        label: 'Pedir favor solidario',
                      ),
                      _buildKindSelectorChip(
                        key: const Key('chip_kind_emergencia_oferta'),
                        kind: PublicationKind.emergenciaOferta,
                        label: 'Compartir recurso de emergencia',
                      ),
                    ],
                  ),
                ],

                OutlinedButton.icon(
                  key: const Key('btn_choose_publication_pin'),
                  onPressed: _submitting
                      ? null
                      : () async {
                          final choice =
                              await Navigator.push<ChosenMapLocation>(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => LocationPickerScreen(
                                    catalog: c.locationCatalog,
                                    districtUbigeo:
                                        _location?.districtUbigeo ??
                                        c.activeDistrictUbigeo,
                                    initialPoint:
                                        _location?.point ??
                                        approximateMapPoint(
                                          c.activeLat,
                                          c.activeLng,
                                        ),
                                    allowExactService: _selectedKind.isService,
                                  ),
                                ),
                              );
                          if (!mounted || choice == null) return;
                          setState(() => _location = choice);
                          await _persistDraftSilently();
                        },
                  icon: const Icon(Icons.add_location_alt_outlined),
                  label: Text(
                    _location == null
                        ? 'Ubicación de esta publicación (opcional)'
                        : 'Cambiar ubicación de esta publicación',
                  ),
                ),
                if (_location?.shareExactService == true)
                  const Text(
                    'Se compartirá el punto exacto de atención de este servicio.',
                  ),
                const SizedBox(height: 16),
                TextField(
                  contextMenuBuilder: buildTextSelectionToolbar,
                  onTapOutside: dismissTextInput,
                  key: const Key('input_publish_title'),
                  controller: _titleController,
                  readOnly: _submitting,
                  onChanged: (_) => _persistDraftSilently(),
                  style: const TextStyle(fontSize: 18),
                  decoration: InputDecoration(
                    labelText: _selectedKind.isEmergency
                        ? '¿Qué necesitas o qué ocurre en tu cuadra?'
                        : _isProduct
                        ? 'Nombre del producto'
                        : 'Título breve (ej. Electricista a domicilio / Escalera)',
                    hintText: _selectedKind.isEmergency
                        ? 'Ej. Adulto mayor necesita agua potable y linterna'
                        : 'Escribe en pocas palabras claras',
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  contextMenuBuilder: buildTextSelectionToolbar,
                  onTapOutside: dismissTextInput,
                  key: const Key('input_publish_description'),
                  controller: _descController,
                  readOnly: _submitting,
                  maxLines: 3,
                  onChanged: (_) => _persistDraftSilently(),
                  style: const TextStyle(fontSize: 18),
                  decoration: _isProduct
                      ? const InputDecoration(
                          labelText: 'Descripción y precio del producto',
                          hintText:
                              'Ej. Precio: S/ 10. Entrega cerca del parque.',
                        )
                      : const InputDecoration(
                          labelText: 'Detalles adicionales para tus vecinos',
                          hintText: 'Indica punto público cercano o cómo pueden coordinar contigo.',
                        ),
                ),
                if (_selectedKind == PublicationKind.servicio) ...[
                  const SizedBox(height: 14),
                  TextField(
                    contextMenuBuilder: buildTextSelectionToolbar,
                    onTapOutside: dismissTextInput,
                    key: const Key('input_publish_availability'),
                    controller: _availabilityController,
                    readOnly: _submitting,
                    onChanged: (_) => _persistDraftSilently(),
                    style: const TextStyle(fontSize: 18),
                    decoration: const InputDecoration(
                      labelText: 'Disponibilidad de atención (opcional)',
                      hintText: 'Ej. Lunes a Sábado de 8:00 am a 5:00 pm',
                    ),
                  ),
                ],

                if (_selectedKind == PublicationKind.emergenciaOferta) ...[
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF8F6),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppTheme.urgentRed),
                    ),
                    child: Material(
                      type: MaterialType.transparency,
                      child: CheckboxListTile(
                        key: const Key('checkbox_resource_consent'),
                        contentPadding: EdgeInsets.zero,
                        value: _explicitResourceShareConsent,
                        onChanged: _submitting
                            ? null
                            : (val) => setState(
                                () => _explicitResourceShareConsent =
                                    val ?? false,
                              ),
                        title: const Text(
                          'Confirmo que decido voluntariamente compartir este recurso durante la emergencia (solo se mostrará mi sector aproximado).',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],

                if (_errorMessage != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFEE2E2),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppTheme.urgentRed),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.error_outline,
                          color: AppTheme.urgentRed,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _errorMessage!,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.urgentRed,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 18),
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 60),
                  child: ElevatedButton.icon(
                    key: const Key('btn_submit_publication'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _selectedKind.isEmergency
                          ? AppTheme.urgentRed
                          : AppTheme.actionGreen,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: _submitting ? null : _handleSubmit,
                    icon: Icon(
                      _selectedKind.isEmergency
                          ? Icons.campaign_outlined
                          : Icons.send_rounded,
                      size: 24,
                    ),
                    label: Text(
                      _submitButtonLabel,
                      style: const TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          if (_selectedKind.isEmergency) ...[
            const SizedBox(height: 16),
            const OfficialEmergencyChannelsCard(),
          ],
        ],
      ),
    );
  }

  Widget _buildKindSelectorChip({
    required Key key,
    required PublicationKind kind,
    required String label,
    String? category,
  }) {
    final chipCategory = category ?? _defaultCategoryForKind(kind);
    final selected = _selectedKind == kind && _selectedCategory == chipCategory;
    return ChoiceChip(
      key: key,
      label: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: selected ? Colors.white : AppTheme.textPrimary,
          ),
        ),
      ),
      selected: selected,
      selectedColor: AppTheme.actionGreen,
      backgroundColor: AppTheme.surfaceContainer,
      onSelected: _submitting
          ? null
          : (_) {
              setState(() {
                _selectedKind = kind;
                if (!kind.isService && _location != null) {
                  _location = ChosenMapLocation(
                    point: _location!.point,
                    districtUbigeo: _location!.districtUbigeo,
                  );
                }
                _selectedCategory = chipCategory;
                widget.controller.setPublishPresetKind(kind);
              });
              if (kind == PublicationKind.anuncio) _restoreExistingDraftIfAny();
            },
    );
  }

  Widget _buildSubmittedResultCard(
    BuildContext context,
    Publication submitted,
  ) {
    return Container(
      key: const Key('card_submitted_publication_result'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: submitted.syncStatus.isConfirmed
            ? const Color(0xFFDDF7E8)
            : const Color(0xFFFFF3CD),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: submitted.syncStatus.isConfirmed
              ? AppTheme.actionGreen
              : AppTheme.amberWarning,
          width: 2,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SyncStatusBadge(
            status: submitted.syncStatus,
            isEmergency: submitted.kind.isEmergency,
          ),
          const SizedBox(height: 10),
          Text(
            submitted.title,
            style: const TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w800,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Sector aproximado: ${submitted.neighborhood} · ${submitted.sector}',
            style: const TextStyle(fontSize: 16, color: AppTheme.textSecondary),
          ),
          if (!submitted.syncStatus.isConfirmed) ...[
            const SizedBox(height: 8),
            const Text(
              'Importante: tu teléfono está sin conexión. El reporte está guardado de forma segura en este equipo pero aún NO se ha comunicado a los vecinos. Al recuperar señal podrás enviarlo sin volver a escribir.',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppTheme.amberWarning,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              OutlinedButton.icon(
                key: const Key('btn_result_ver_mis_actividades'),
                onPressed: () =>
                    widget.controller.navigateTo(AppSection.misActividades),
                icon: const Icon(Icons.list_alt),
                label: const Text('Ver en Mis actividades'),
              ),
              OutlinedButton.icon(
                key: const Key('btn_result_volver_inicio'),
                onPressed: widget.controller.goHome,
                icon: const Icon(Icons.home_outlined),
                label: const Text('Volver a Inicio'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
