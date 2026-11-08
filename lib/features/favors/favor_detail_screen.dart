import '../publish/publication_owner_actions.dart';
import '../../core/accessibility/text_input_support.dart';

import 'package:flutter/material.dart';

import '../../core/models/domain_models.dart';
import '../../core/state/app_controller.dart';
import '../../core/theme/app_theme.dart';
import '../shared/civic_widgets.dart';

/// Detalle de favor solidario o solicitud de emergencia.
/// Permite completar la tarea "Ofrecer ayuda" en el clic #3 desde Inicio:
/// `Ver favores y ayudar` (1) -> abrir solicitud (2) -> nota opcional y
/// `Enviar oferta de ayuda` (3).
class FavorDetailScreen extends StatefulWidget {
  const FavorDetailScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<FavorDetailScreen> createState() => _FavorDetailScreenState();
}

class _FavorDetailScreenState extends State<FavorDetailScreen> {
  final TextEditingController _noteController = TextEditingController();
  final TextEditingController _resourceController = TextEditingController();

  bool _explicitShareConsent = false;
  List<HelpOffer> _offers = const [];
  String? _feedbackMessage;
  bool _isErrorFeedback = false;

  @override
  void initState() {
    super.initState();
    _loadOffers();
  }

  Future<void> _loadOffers() async {
    final fav = widget.controller.selectedPublication;
    if (fav == null) return;
    final list = await widget.controller.database.listOffersForPublication(
      fav.id,
    );
    if (mounted) {
      setState(() {
        _offers = list;
      });
    }
  }

  @override
  void dispose() {
    _noteController.dispose();
    _resourceController.dispose();
    super.dispose();
  }

  Future<void> _handleSendOffer(Publication fav) async {
    setState(() {
      _feedbackMessage = null;
      _isErrorFeedback = false;
    });
    try {
      await widget.controller.submitOfferToHelp(
        publication: fav,
        note: _noteController.text,
        resourceShared: _resourceController.text,
        explicitShareConsent: _explicitShareConsent,
      );
      await _loadOffers();
      if (mounted) {
        setState(() {
          _isErrorFeedback = false;
          _feedbackMessage =
              'Tu oferta solidaria fue registrada para ${fav.authorAlias}.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isErrorFeedback = true;
          _feedbackMessage = e.toString().replaceFirst('Bad state: ', '');
        });
      }
    }
  }

  Future<void> _handleStatusTransition(
    Publication fav,
    PublicationStatus next,
  ) async {
    try {
      await widget.controller.updatePublicationStatus(
        publicationId: fav.id,
        newStatus: next,
      );
      if (mounted) {
        setState(() {
          _isErrorFeedback = false;
          _feedbackMessage = 'Estado cambiado a "${next.label}".';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isErrorFeedback = true;
          _feedbackMessage = e.toString().replaceFirst('Bad state: ', '');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final fav = c.selectedPublication;
    if (fav == null) {
      return const Center(child: Text('Selecciona una solicitud de ayuda.'));
    }

    final isAuthor = c.currentUser?.id == fav.authorId;

    return SingleChildScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PublicationOwnerActions(controller: c, publication: fav),
          if (fav.kind.isEmergency && !c.usesAzureBackend) ...[
            FilledButton.icon(
              key: const Key('open_emergency_group'),
              onPressed: () async {
                try {
                  await c.openEmergencyGroup(fav);
                } catch (_) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Inicia sesión y elige el distrito de esta emergencia en tu perfil para participar.',
                        ),
                      ),
                    );
                  }
                }
              },
              icon: const Icon(Icons.groups_outlined),
              label: const Text('Chat grupal de la emergencia'),
            ),
            const Text(
              'Visible para vecinos del distrito. Las conversaciones privadas se mantienen aparte.',
            ),
            const SizedBox(height: 12),
          ],
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.surfaceCard,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: fav.kind.isEmergency
                    ? AppTheme.urgentRed
                    : AppTheme.borderSoft,
                width: 1.5,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    PublicationStatusBadge(status: fav.status),
                    SyncStatusBadge(
                      status: fav.syncStatus,
                      isEmergency: fav.kind.isEmergency,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  fav.title,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Solicitado por: ${fav.authorAlias}',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.actionGreen,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Sector aproximado: ${fav.neighborhood} · ${fav.sector} (sin exponer domicilio exacto)',
                  style: const TextStyle(
                    fontSize: 16,
                    color: AppTheme.textSecondary,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  fav.description,
                  style: const TextStyle(
                    fontSize: 18,
                    color: AppTheme.textPrimary,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Horario / referencia: ${fav.availabilityText}',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),

          if (_feedbackMessage != null) ...[
            const SizedBox(height: 12),
            Container(
              key: const Key('banner_favor_detail_feedback'),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: _isErrorFeedback
                    ? const Color(0xFFFEE2E2)
                    : const Color(0xFFDDF7E8),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: _isErrorFeedback
                      ? AppTheme.urgentRed
                      : AppTheme.actionGreen,
                ),
              ),
              child: Text(
                _feedbackMessage!,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: _isErrorFeedback
                      ? AppTheme.urgentRed
                      : AppTheme.actionGreen,
                ),
              ),
            ),
          ],

          const SizedBox(height: 16),

          // Si el usuario es el autor, puede cambiar el estado de su solicitud
          if (isAuthor)
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
                  const Text(
                    'Eres el autor de esta solicitud · Actualizar estado:',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (final next in fav.status.allowedNextStatuses)
                        ElevatedButton.icon(
                          key: Key('btn_transition_${next.dbValue}'),
                          onPressed: () => _handleStatusTransition(fav, next),
                          icon: const Icon(Icons.check_circle_outline),
                          label: Text('Marcar como ${next.label}'),
                        ),
                    ],
                  ),
                ],
              ),
            )
          else if (!fav.isGuestReport)
            // Clic 3 desde Inicio: Nota opcional y `Enviar oferta de ayuda`
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
                  const Text(
                    'Ofrecer ayuda gratuita a este vecino',
                    style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Escribe una nota opcional y toca "Enviar oferta de ayuda" (sin pagos ni cobros):',
                    style: TextStyle(
                      fontSize: 16,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    contextMenuBuilder: buildTextSelectionToolbar,
                    onTapOutside: dismissTextInput,
                    key: const Key('input_favor_offer_note'),
                    controller: _noteController,
                    maxLines: 2,
                    style: const TextStyle(fontSize: 18),
                    decoration: InputDecoration(
                      labelText: 'Nota para ${fav.authorAlias} (opcional)',
                      hintText: 'Ej. Vivo cerca del parque y puedo llevarte la escalera a las 4 pm.',
                    ),
                  ),
                  if (fav.kind.isEmergency) ...[
                    const SizedBox(height: 10),
                    TextField(
                      contextMenuBuilder: buildTextSelectionToolbar,
                      onTapOutside: dismissTextInput,
                      key: const Key('input_favor_resource_shared'),
                      controller: _resourceController,
                      onChanged: (_) => setState(() {}),
                      style: const TextStyle(fontSize: 18),
                      decoration: const InputDecoration(
                        labelText: 'Recurso compartido en emergencia (opcional, ej. Botiquín / Linterna)',
                      ),
                    ),
                    if (_resourceController.text.trim().isNotEmpty)
                      Material(
                        type: MaterialType.transparency,
                        child: CheckboxListTile(
                          key: const Key('checkbox_offer_resource_consent'),
                          contentPadding: EdgeInsets.zero,
                          value: _explicitShareConsent,
                          onChanged: (v) => setState(
                            () => _explicitShareConsent = v ?? false,
                          ),
                          title: const Text(
                            'Confirmo explícitamente mi consentimiento para compartir este recurso con mi vecino.',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                  ],
                  const SizedBox(height: 14),
                  ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 58),
                    child: ElevatedButton.icon(
                      key: const Key('btn_enviar_oferta_ayuda'),
                      onPressed: () => _handleSendOffer(fav),
                      icon: const Icon(Icons.volunteer_activism, size: 24),
                      label: const Text('Enviar oferta de ayuda'),
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (!c.usesAzureBackend) OutlinedButton.icon(
                    key: const Key('btn_favor_open_private_chat'),
                    onPressed: () => c.requestContactWithProvider(
                      publication: fav,
                      initialMessage: _noteController.text,
                    ),
                    icon: const Icon(Icons.chat_bubble_outline),
                    label: Text('Abrir chat privado con ${fav.authorAlias}'),
                  ),
                ],
              ),
            ),

          if (fav.isGuestReport)
            const Text('Reporte de invitado sin contacto privado.'),
          if (!fav.isGuestReport) ...[
            const SizedBox(height: 16),
            Text(
              'Ofertas de ayuda registradas (${_offers.length}):',
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: AppTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            if (_offers.isEmpty)
              const Text(
                'Aún no hay ofertas registradas. ¡Sé el primer vecino en apoyar!',
                style: TextStyle(fontSize: 16, color: AppTheme.textSecondary),
              )
            else
              for (final off in _offers)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppTheme.surfaceCard,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppTheme.borderSoft),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              off.helperAlias,
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                                color: AppTheme.actionGreen,
                              ),
                            ),
                            SyncStatusBadge(status: off.syncStatus),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          off.note,
                          style: const TextStyle(
                            fontSize: 16,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
          ],
        ],
      ),
    );
  }
}
