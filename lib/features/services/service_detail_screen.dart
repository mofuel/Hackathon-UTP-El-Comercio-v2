import '../publish/publication_owner_actions.dart';
import '../../core/accessibility/text_input_support.dart';

import 'package:flutter/material.dart';

import '../../core/models/domain_models.dart';
import '../../core/state/app_controller.dart';
import '../../core/theme/app_theme.dart';
import '../shared/civic_widgets.dart';

/// Ficha detallada de servicio u oficio que permite completar las dos tareas
/// clave del directorio en el clic #3 desde Inicio:
/// - Solicitar contacto con prestador: escribir mensaje y tocar `Enviar solicitud de contacto`.
/// - Recomendar servicio: tocar `He usado este servicio y lo recomiendo`.
class ServiceDetailScreen extends StatefulWidget {
  const ServiceDetailScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<ServiceDetailScreen> createState() => _ServiceDetailScreenState();
}

class _ServiceDetailScreenState extends State<ServiceDetailScreen> {
  final TextEditingController _contactMsgController = TextEditingController();
  final TextEditingController _recCommentController = TextEditingController(
    text: 'Excelente atención vecinal, puntual y de confianza en el barrio.',
  );

  List<ServiceRecommendation> _recommendations = const [];
  bool _recommendationsLoading = true;
  bool _savingRecommendation = false;
  String? _feedbackMessage;
  bool _isErrorFeedback = false;

  @override
  void initState() {
    super.initState();
    if (widget.controller.selectedPublication?.isProduct == true) {
      _recCommentController.clear();
    }
    _loadRecommendations();
  }

  @override
  void didUpdateWidget(covariant ServiceDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller.selectedPublication?.isProduct == true) {
      _loadRecommendations(restoreComment: false);
    }
  }

  Future<void> _loadRecommendations({bool restoreComment = true}) async {
    final srv = widget.controller.selectedPublication;
    if (srv == null) return;
    final list = await widget.controller.database.listRecommendationsForService(
      srv.id,
    );
    if (mounted && widget.controller.selectedPublication?.id == srv.id) {
      setState(() {
        _recommendations = list;
        _recommendationsLoading = false;
        final userId = widget.controller.currentUser?.id;
        final mine = list.where((r) => r.userId == userId).firstOrNull;
        if (restoreComment && mine != null) {
          _recCommentController.text = mine.comment;
        }
      });
    }
  }

  @override
  void dispose() {
    _contactMsgController.dispose();
    _recCommentController.dispose();
    super.dispose();
  }

  Future<void> _handleContactRequest(Publication srv) async {
    setState(() {
      _feedbackMessage = null;
      _isErrorFeedback = false;
    });
    try {
      await widget.controller.requestContactWithProvider(
        publication: srv,
        initialMessage: _contactMsgController.text,
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _isErrorFeedback = true;
          _feedbackMessage = e.toString().replaceFirst('Bad state: ', '');
        });
      }
    }
  }

  Future<void> _handleRecommend(
    Publication srv, {
    required bool allowUpdate,
  }) async {
    setState(() {
      _savingRecommendation = true;
      _feedbackMessage = null;
      _isErrorFeedback = false;
    });
    try {
      await widget.controller.recommendService(
        service: srv,
        comment: _recCommentController.text,
        allowUpdateExisting: allowUpdate,
      );
      await _loadRecommendations();
    } catch (e) {
      if (mounted) {
        setState(() {
          _isErrorFeedback = true;
          _feedbackMessage = e.toString().replaceFirst('Bad state: ', '');
        });
      }
    } finally {
      if (mounted) setState(() => _savingRecommendation = false);
    }
  }

  Future<void> _handleWithdrawRecommendation(Publication srv) async {
    setState(() {
      _savingRecommendation = true;
      _feedbackMessage = null;
    });
    try {
      await widget.controller.withdrawServiceRecommendation(srv);
      await _loadRecommendations();
    } catch (e) {
      if (mounted) {
        setState(() {
          _isErrorFeedback = true;
          _feedbackMessage = e.toString().replaceFirst('Bad state: ', '');
        });
      }
    } finally {
      if (mounted) setState(() => _savingRecommendation = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final srv = c.selectedPublication;
    if (srv == null) {
      return const Center(
        child: Text('Selecciona un servicio del directorio.'),
      );
    }

    final user = c.currentUser;
    final myRec = _recommendations
        .where((r) => r.userId == user?.id)
        .firstOrNull;
    final hasMyRecommendation = myRec != null;
    final confirmedCount = _recommendations
        .where((r) => r.syncStatus.isConfirmed)
        .length;
    final productRestriction = !srv.isProduct || user == null
        ? null
        : user.id == srv.authorId
        ? 'El autor no puede recomendar su propio producto.'
        : !srv.isInSameZoneAs(user)
        ? 'Solo los vecinos del mismo distrito y sector pueden recomendar este producto.'
        : null;

    return SingleChildScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PublicationOwnerActions(controller: c, publication: srv),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.surfaceCard,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppTheme.borderSoft, width: 1.5),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    PublicationStatusBadge(status: srv.status),
                    SyncStatusBadge(status: srv.syncStatus),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  srv.title,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${srv.isProduct ? 'Publicado por' : 'Prestador vecinal'}: ${srv.authorAlias}',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AppTheme.actionGreen,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Zona aproximada: ${srv.neighborhood} · ${srv.sector} (${srv.distanceLabelFrom(lat: c.activeLat, lng: c.activeLng)})',
                  style: const TextStyle(
                    fontSize: 16,
                    color: AppTheme.textSecondary,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  srv.description,
                  style: const TextStyle(
                    fontSize: 18,
                    color: AppTheme.textPrimary,
                    height: 1.4,
                  ),
                ),
                if (srv.shareServiceLocation) ...[
                  const SizedBox(height: 12),
                  const Text('Punto de atención compartido por el autor'),
                  if (srv.serviceAddress.isNotEmpty) Text(srv.serviceAddress),
                ],
                if (!srv.isProduct) const SizedBox(height: 10),
                if (!srv.isProduct)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppTheme.surfaceContainer,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.schedule, color: AppTheme.actionGreen),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Disponibilidad: ${srv.availabilityText}',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.textPrimary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),

          if (_feedbackMessage != null) ...[
            const SizedBox(height: 12),
            Container(
              key: const Key('banner_service_detail_feedback'),
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

          // Bloque 1: Solicitar contacto con prestador (Clic 3 desde Inicio)
          if (!c.usesAzureBackend) Container(
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
                  srv.isProduct
                      ? 'Contactar a quien publica en chat privado'
                      : 'Contactar al prestador en chat privado',
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(
                  'Escribe un mensaje para coordinar horario o consulta y envíalo en un toque:',
                  style: TextStyle(fontSize: 16, color: AppTheme.textSecondary),
                ),
                const SizedBox(height: 10),
                TextField(
                  contextMenuBuilder: buildTextSelectionToolbar,
                  onTapOutside: dismissTextInput,
                  key: const Key('input_service_contact_message'),
                  controller: _contactMsgController,
                  maxLines: 2,
                  style: const TextStyle(fontSize: 18),
                  decoration: InputDecoration(
                    labelText: 'Mensaje para ${srv.authorAlias}',
                    hintText: 'Hola, soy vecino del barrio y necesito consultar disponibilidad…',
                  ),
                ),
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 58),
                  child: ElevatedButton.icon(
                    key: const Key('btn_enviar_solicitud_contacto'),
                    onPressed: () => _handleContactRequest(srv),
                    icon: const Icon(Icons.chat_outlined, size: 24),
                    label: const Text('Enviar solicitud de contacto'),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Bloque 2: Recomendar la publicación (Clic 3 desde Inicio).
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.surfaceCard,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppTheme.borderSoft, width: 1.5),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  srv.isProduct
                      ? 'Vistos buenos ($confirmedCount)'
                      : 'Recomendaciones y opiniones de vecinos',
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    srv.isProduct
                        ? 'El Visto Bueno cuenta cuando se confirma que viene de un vecino del mismo distrito y sector.'
                        : 'Nota comunitaria: Las recomendaciones son opiniones personales de vecinos del barrio, NO certificaciones técnicas ni avales oficiales.',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ),
                if (productRestriction != null) ...[
                  const SizedBox(height: 8),
                  Text(productRestriction),
                ],
                if (srv.isProduct &&
                    myRec != null &&
                    !myRec.syncStatus.isConfirmed) ...[
                  const SizedBox(height: 8),
                  SyncStatusBadge(status: myRec.syncStatus),
                ],
                const SizedBox(height: 12),
                TextField(
                  contextMenuBuilder: buildTextSelectionToolbar,
                  onTapOutside: dismissTextInput,
                  key: const Key('input_service_recommendation_comment'),
                  controller: _recCommentController,
                  style: const TextStyle(fontSize: 18),
                  decoration: const InputDecoration(
                    labelText: 'Tu opinión vecinal (opcional)',
                  ),
                ),
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 58),
                  child: ElevatedButton.icon(
                    key: srv.isProduct
                        ? const Key('btn_recomendar_producto')
                        : const Key('btn_recomendar_servicio'),
                    onPressed:
                        _recommendationsLoading ||
                            _savingRecommendation ||
                            hasMyRecommendation ||
                            productRestriction != null
                        ? null
                        : () => _handleRecommend(srv, allowUpdate: false),
                    icon: const Icon(Icons.thumb_up_alt_outlined, size: 24),
                    label: Text(
                      srv.isProduct
                          ? 'Recomiendo este producto'
                          : 'He usado este servicio y lo recomiendo',
                    ),
                  ),
                ),
                if (hasMyRecommendation) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      OutlinedButton.icon(
                        key: const Key('btn_modificar_recomendacion'),
                        onPressed:
                            _savingRecommendation || productRestriction != null
                            ? null
                            : () => _handleRecommend(srv, allowUpdate: true),
                        icon: const Icon(Icons.edit_outlined),
                        label: const Text('Modificar mi recomendación'),
                      ),
                      OutlinedButton.icon(
                        key: const Key('btn_retirar_recomendacion'),
                        onPressed: _savingRecommendation
                            ? null
                            : () => _handleWithdrawRecommendation(srv),
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('Retirar mi recomendación'),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 16),
                if (!srv.isProduct)
                  Text(
                    'Opiniones registradas (${_recommendations.length}):',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                const SizedBox(height: 8),
                for (final rec in _recommendations)
                  if (!srv.isProduct || rec.syncStatus.isConfirmed)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppTheme.surfaceContainer,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              rec.userAlias,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                                color: AppTheme.actionGreen,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              rec.comment.isEmpty
                                  ? srv.isProduct
                                        ? 'Recomienda este producto en el barrio.'
                                        : 'Recomienda este servicio en el barrio.'
                                  : rec.comment,
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
            ),
          ),
        ],
      ),
    );
  }
}
