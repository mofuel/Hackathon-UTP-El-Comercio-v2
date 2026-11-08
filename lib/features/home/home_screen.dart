import '../publish/publication_owner_actions.dart';

import 'package:flutter/material.dart';

import '../../core/models/domain_models.dart';
import '../../core/state/app_controller.dart';
import '../../core/theme/app_theme.dart';
import '../shared/civic_widgets.dart';

/// Pantalla de Inicio compacta y pensada para lectura inmediata por personas
/// mayores. Expone las 6 acciones principales a 1 clic de distancia con botones
/// de mínimo 56dp de alto.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _resourcesExpanded = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final pendingCount = c.userOutbox.length;

    final feed = c.neighborhoodFeed;
    return NotificationListener<ScrollNotification>(
      onNotification: (event) {
        if (event.metrics.extentAfter < 500) c.loadMoreFeed();
        return false;
      },
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    c.currentUser == null
                        ? 'Tu barrio, más cerca'
                        : 'Hola, ${c.currentUser!.alias}',
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (!c.remoteGateway.isLiveSupabaseConnected &&
                      !c.remoteGateway.isTestDouble)
                    const Text(
                      'La conexión con el barrio está pendiente de configurar. Puedes usar las prácticas sin internet.',
                      style: TextStyle(fontSize: 16),
                    ),
                  const SizedBox(height: 12),
                  // 1. Reportar emergencia (2 clics total: Inicio -> escribir -> Enviar reporte)
                  _PrimaryCivicActionButton(
                    buttonKey: const Key('btn_home_reportar_emergencia'),
                    label: 'Reportar emergencia',
                    subtitle: 'Aviso urgente a vecinos de tu sector (2 pasos)',
                    icon: Icons.warning_amber_rounded,
                    backgroundColor: AppTheme.urgentRed,
                    foregroundColor: Colors.white,
                    onTap: () => c.openQuickPublish(
                      presetKind: PublicationKind.emergenciaSolicitud,
                      lockTypeForTwoClickFlow: true,
                    ),
                  ),
                  const SizedBox(height: 12),

                  // 2. Necesito ayuda (2 clics total: Inicio -> escribir -> Enviar solicitud)
                  _PrimaryCivicActionButton(
                    buttonKey: const Key('btn_home_necesito_ayuda'),
                    label: 'Necesito ayuda',
                    subtitle: 'Pedir un favor solidario o préstamo gratuito (2 pasos)',
                    icon: Icons.volunteer_activism,
                    backgroundColor: AppTheme.actionGreen,
                    foregroundColor: Colors.white,
                    onTap: () => c.openQuickPublish(
                      presetKind: PublicationKind.favorSolicitud,
                      lockTypeForTwoClickFlow: true,
                    ),
                  ),
                  const SizedBox(height: 12),

                  // 3. Publicar servicio o favor (3 clics total: Inicio -> elegir tipo -> escribir -> Publicar en mi barrio)
                  _PrimaryCivicActionButton(
                    buttonKey: const Key('btn_home_publicar_servicio_favor'),
                    label: 'Publicar en el barrio',
                    subtitle: 'Ofrecer un producto, oficio o favor (3 pasos)',
                    icon: Icons.add_circle_outline,
                    backgroundColor: AppTheme.surfaceCard,
                    foregroundColor: AppTheme.textPrimary,
                    borderColor: AppTheme.actionGreen,
                    onTap: () => c.openQuickPublish(
                      presetKind: PublicationKind.servicio,
                      lockTypeForTwoClickFlow: false,
                    ),
                  ),
                  const SizedBox(height: 12),

                  // 4. Buscar servicios (3 clics total para contactar o recomendar)
                  _PrimaryCivicActionButton(
                    buttonKey: const Key('btn_home_buscar_servicios'),
                    label: 'Buscar productos y servicios',
                    subtitle:
                        'Encuentra productos y oficios cerca de tu sector',
                    icon: Icons.search,
                    backgroundColor: AppTheme.surfaceCard,
                    foregroundColor: AppTheme.textPrimary,
                    borderColor: AppTheme.borderSoft,
                    onTap: () => c.navigateTo(AppSection.servicios),
                  ),
                  const SizedBox(height: 12),

                  _PrimaryCivicActionButton(
                    buttonKey: const Key('btn_home_explorar_mapa'),
                    label: 'Explorar mapa',
                    subtitle: 'Servicios, favores, recursos y avisos cercanos',
                    icon: Icons.map_outlined,
                    backgroundColor: AppTheme.surfaceCard,
                    foregroundColor: AppTheme.textPrimary,
                    borderColor: AppTheme.borderSoft,
                    onTap: () => c.navigateTo(AppSection.explorarMapa),
                  ),
                  const SizedBox(height: 12),

                  // 5. Ver favores y ayudar (3 clics total: Inicio -> abrir solicitud -> Enviar oferta de ayuda)
                  _PrimaryCivicActionButton(
                    buttonKey: const Key('btn_home_ver_favores'),
                    label: 'Ver favores y ayudar',
                    subtitle: 'Solicitudes gratuitas de vecinos que necesitan apoyo hoy',
                    icon: Icons.handshake_outlined,
                    backgroundColor: AppTheme.surfaceCard,
                    foregroundColor: AppTheme.textPrimary,
                    borderColor: AppTheme.borderSoft,
                    onTap: () => c.navigateTo(AppSection.favores),
                  ),
                  const SizedBox(height: 12),

                  // 6. Practicar una emergencia (Simulacro interactivo 100% offline)
                  _PrimaryCivicActionButton(
                    buttonKey: const Key('btn_home_practicar_emergencia'),
                    label: 'Practicar una emergencia',
                    subtitle: 'Simulacro guiado con datos ficticios sin riesgo ni internet',
                    icon: Icons.school_outlined,
                    backgroundColor: AppTheme.practiceBlue,
                    foregroundColor: Colors.white,
                    onTap: () => c.navigateTo(AppSection.practicaSimulacro),
                  ),

                  const SizedBox(height: 12),
                  _PrimaryCivicActionButton(
                    buttonKey: const Key('btn_home_ofrecer_recurso'),
                    label: 'Ofrecer recurso para emergencia',
                    subtitle: 'Con tu consentimiento explícito',
                    icon: Icons.inventory_2_outlined,
                    backgroundColor: AppTheme.surfaceCard,
                    foregroundColor: AppTheme.textPrimary,
                    borderColor: AppTheme.actionGreen,
                    onTap: () => c.openQuickPublish(
                      presetKind: PublicationKind.emergenciaOferta,
                      lockTypeForTwoClickFlow: true,
                    ),
                  ),
                  const SizedBox(height: 18),
                  if (c.statusBannerMessage != null) _buildStatusBanner(c),
                  if (c.showOnboardingTutorial) _buildTutorialCard(c),
                  _buildWelcomeAndConnectionBar(context, c, pendingCount),
                  const SizedBox(height: 12),
                  _buildExpandableNeighborhoodResources(context, c),
                  const SizedBox(height: 16),
                  const OfficialEmergencyChannelsCard(),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Avisos del barrio',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                  ),
                  Text(
                    c.isOfflineMode
                        ? 'Sin conexión: avisos guardados en este teléfono.'
                        : 'Del más reciente al más antiguo.',
                  ),
                  if (c.isAuthenticated && c.activeDistrictUbigeo == null)
                    const Text(
                      'Elige un distrito en tu perfil para ver los avisos de esa zona.',
                    ),
                  if (!c.isAuthenticated)
                    const Text(
                      'Inicia sesión para ver los avisos de tus vecinos.',
                    ),
                  if (c.isAuthenticated && feed.isEmpty)
                    const Text('Aún no hay avisos guardados para esta zona.'),
                ],
              ),
            ),
          ),
          SliverList.builder(
            itemCount: feed.length,
            itemBuilder: (context, index) {
              final p = feed[index];
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Card(
                  key: ValueKey('home_feed_${p.id}'),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          p.authorAlias,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                          ),
                        ),
                        Text(
                          '${p.kind.shortBadge} · ${p.createdAt.toLocal().toString().substring(0, 16)}',
                        ),
                        const SizedBox(height: 12),
                        Text(
                          p.title,
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          p.description,
                          style: const TextStyle(fontSize: 18, height: 1.4),
                        ),
                        const SizedBox(height: 8),
                        Text('${p.neighborhood} · ${p.sector}'),
                        PublicationStatusBadge(status: p.status),
                        PublicationOwnerActions(controller: c, publication: p),
                        OutlinedButton(
                          onPressed: () => p.kind.isService
                              ? c.openServiceDetail(p)
                              : c.openFavorDetail(p),
                          child: const Text('Ver aviso'),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
              child: c.feedLoading
                  ? const Center(child: CircularProgressIndicator())
                  : c.isAuthenticated && c.feedHasMore && !c.isOfflineMode
                  ? OutlinedButton(
                      onPressed: () => c.loadMoreFeed(),
                      child: const Text('Cargar más avisos'),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWelcomeAndConnectionBar(
    BuildContext context,
    AppController c,
    int pendingCount,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (pendingCount > 0)
          Text('$pendingCount envío(s) pendiente(s). Aún NO comunicados.'),
        OutlinedButton.icon(
          onPressed: () => c.retryOutboxSync(),
          icon: const Icon(Icons.refresh),
          label: const Text('Actualizar el barrio'),
        ),
      ],
    );
  }

  Widget _buildStatusBanner(AppController c) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.actionGreen),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline, color: AppTheme.actionGreen),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              c.statusBannerMessage!,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppTheme.textPrimary,
              ),
            ),
          ),
          IconButton(
            onPressed: c.clearStatusBanner,
            icon: const Icon(Icons.close),
            tooltip: 'Cerrar aviso',
          ),
        ],
      ),
    );
  }

  Widget _buildTutorialCard(AppController c) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.practiceSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.practiceBlue, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.menu_book, color: AppTheme.practiceBlue, size: 24),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Guía breve para vecinos (3 pasos máximo)',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.practiceBlue,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            '1. Para pedir ayuda o reportar una emergencia: toca el botón grande, escribe qué ocurre y toca Enviar (solo 2 clics).\n'
            '2. Si no hay internet: tu aviso se guarda en tu teléfono como "Pendiente de sincronizar" y puedes reintentarlo cuando vuelva la señal.\n'
            '3. Para aprender sin miedo: usa "Practicar una emergencia" con datos 100% ficticios.',
            style: TextStyle(
              fontSize: 17,
              height: 1.4,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: ElevatedButton(
              onPressed: () => c.toggleOnboardingTutorial(false),
              child: const Text('Entendido, cerrar guía'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExpandableNeighborhoodResources(
    BuildContext context,
    AppController c,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surfaceCard,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.borderSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            key: const Key('btn_expand_recursos_barrio'),
            borderRadius: BorderRadius.circular(14),
            onTap: () =>
                setState(() => _resourcesExpanded = !_resourcesExpanded),
            child: Container(
              constraints: const BoxConstraints(minHeight: 56),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  const Icon(
                    Icons.folder_shared_outlined,
                    color: AppTheme.actionGreen,
                    size: 26,
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Recursos del barrio, mensajes y mis actividades',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                  ),
                  Icon(
                    _resourcesExpanded ? Icons.expand_less : Icons.expand_more,
                    size: 28,
                    color: AppTheme.textPrimary,
                  ),
                ],
              ),
            ),
          ),
          if (_resourcesExpanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Divider(),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      OutlinedButton.icon(
                        key: const Key('btn_home_mis_actividades'),
                        onPressed: () =>
                            c.navigateTo(AppSection.misActividades),
                        icon: const Icon(Icons.assignment_ind_outlined),
                        label: Text(
                          'Mis actividades y cola (${c.userOutbox.length})',
                        ),
                      ),
                      OutlinedButton.icon(
                        key: const Key('btn_home_mensajes'),
                        onPressed: () => c.navigateTo(AppSection.chatLista),
                        icon: const Icon(Icons.chat_bubble_outline),
                        label: Text(
                          'Conversaciones privadas (${c.userConversations.length})',
                        ),
                      ),
                      OutlinedButton.icon(
                        key: const Key('btn_home_cambiar_cuenta'),
                        onPressed: () => c.navigateTo(AppSection.autenticacion),
                        icon: const Icon(Icons.switch_account_outlined),
                        label: const Text('Cuenta y ubicación'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Puntos de referencia y brigadas en tu sector:',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (final res in c.communityResources)
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
                              res.title,
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                                color: AppTheme.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              res.description,
                              style: const TextStyle(
                                fontSize: 16,
                                color: AppTheme.textSecondary,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Fuente: ${res.sourceLabel}',
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: AppTheme.actionGreen,
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

class _PrimaryCivicActionButton extends StatelessWidget {
  const _PrimaryCivicActionButton({
    required this.buttonKey,
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.backgroundColor,
    required this.foregroundColor,
    required this.onTap,
    this.borderColor,
  });

  final Key buttonKey;
  final String label;
  final String subtitle;
  final IconData icon;
  final Color backgroundColor;
  final Color foregroundColor;
  final Color? borderColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '$label. $subtitle',
      child: Material(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          key: buttonKey,
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 68),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: borderColor ?? backgroundColor,
                width: 2,
              ),
            ),
            child: Row(
              children: [
                Icon(icon, size: 30, color: foregroundColor),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: foregroundColor,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.arrow_forward_ios, size: 20, color: foregroundColor),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
