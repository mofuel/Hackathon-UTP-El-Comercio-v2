import '../../core/accessibility/text_input_support.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/models/domain_models.dart';
import '../../core/state/app_controller.dart';
import '../../core/theme/app_theme.dart';
import '../shared/civic_widgets.dart';
import 'message_bubble.dart';
import 'private_message_push_widgets.dart';

/// Conversaciones privadas del vecino y grupos de emergencia consultados.
class ChatListScreen extends StatefulWidget {
  const ChatListScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  AppController get controller => widget.controller;
  StreamSubscription<void>? _activityUpdates;
  Timer? _activityTimer;
  String? _owner;
  @override
  void initState() {
    super.initState();
    _watchActivity();
  }

  @override
  void didUpdateWidget(covariant ChatListScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_owner != controller.currentUser?.id) _watchActivity();
  }

  void _watchActivity() {
    _owner = controller.currentUser?.id;
    unawaited(_activityUpdates?.cancel());
    _activityTimer?.cancel();
    if (_owner == null || !controller.remoteGateway.isLiveSupabaseConnected) {
      return;
    }
    _activityUpdates = controller.remoteGateway.watchChatActivity().listen((_) {
      unawaited(_refresh());
    });
    _activityTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      unawaited(_refresh());
    });
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    try {
      await controller.refreshChatActivity();
    } catch (_) {
      /* La lista local permanece disponible. */
    }
  }

  @override
  void dispose() {
    _activityTimer?.cancel();
    unawaited(_activityUpdates?.cancel());
    super.dispose();
  }

  Future<void> _organize(
    BuildContext context,
    String chatKey,
    String action,
  ) async {
    final owner = controller.currentUser?.id;
    final wasPinned = controller.isChatPinned(chatKey);
    try {
      if (action == 'pin') {
        await controller.setChatPinned(chatKey, !wasPinned);
      } else {
        await controller.hideChat(chatKey);
        if (!context.mounted || controller.currentUser?.id != owner) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Chat quitado solo de tu lista en este teléfono. Los mensajes de los demás se conservan.',
            ),
            action: SnackBarAction(
              label: 'Deshacer',
              onPressed: () async {
                if (controller.currentUser?.id == owner) {
                  await controller.restoreChat(chatKey, pinned: wasPinned);
                }
              },
            ),
          ),
        );
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'No se pudo actualizar tu lista. Inténtalo de nuevo.',
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (controller.usesAzureBackend) {
      return const Center(child: Text('Los chats estarán disponibles en la siguiente etapa.'));
    }
    final entries = [
      for (final t in controller.userConversations)
        (
          chatKey: controller.chatKeyFor(t),
          title: t.peerAliasFor(controller.currentUser!.id),
          subtitle: 'Chat privado',
          updated: controller.chatLastActivity(
            controller.chatKeyFor(t),
            t.updatedAt,
          ),
          status: t.syncStatus as SyncStatus?,
          tileKey: 'card_conversation_${t.id}',
          open: () => controller.openConversation(t),
        ),
      for (final p in controller.emergencyGroupChats)
        (
          chatKey: 'group:${p.id}',
          title: p.title,
          subtitle: 'Grupo de emergencia · Vecinos del distrito',
          updated: controller.chatLastActivity('group:${p.id}', p.createdAt),
          status: null as SyncStatus?,
          tileKey: 'emergency_group_${p.id}',
          open: () => controller.openEmergencyGroup(p),
        ),
    ];
    entries.sort((a, b) {
      final aPinned = controller.isChatPinned(a.chatKey),
          bPinned = controller.isChatPinned(b.chatKey);
      if (aPinned != bPinned) return aPinned ? -1 : 1;
      final date = b.updated.compareTo(a.updated);
      return date != 0 ? date : a.chatKey.compareTo(b.chatKey);
    });
    return SingleChildScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Chats',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          const Text(
            'Tus conversaciones privadas y los grupos de emergencia que has abierto.',
          ),
          const SizedBox(height: 16),
          if (controller.currentUser case final user?
              when controller.remoteGateway.isLiveSupabaseConnected &&
                  !controller.remoteGateway.isTestDouble)
            PrivateMessagePushSettings(
              key: ValueKey(user.id),
              controller: controller,
              userId: user.id,
            ),
          if (entries.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text(
                'Aún no tienes chats en tu lista. Puedes abrir una conversación desde un servicio o una emergencia.',
              ),
            ),
          for (var i = 0; i < entries.length; i++) ...[
            if (i == 0 ||
                controller.isChatPinned(entries[i - 1].chatKey) !=
                    controller.isChatPinned(entries[i].chatKey))
              Padding(
                padding: const EdgeInsets.only(bottom: 8, top: 8),
                child: Text(
                  controller.isChatPinned(entries[i].chatKey)
                      ? 'Fijados'
                      : 'Conversaciones',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            Card(
              margin: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: InkWell(
                      key: ValueKey(entries[i].tileKey),
                      onTap: entries[i].open,
                      borderRadius: BorderRadius.circular(16),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  entries[i].chatKey.startsWith('group:')
                                      ? Icons.groups_outlined
                                      : Icons.chat_bubble_outline,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    entries[i].title,
                                    style: const TextStyle(
                                      fontSize: 19,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                                if (controller.isChatPinned(entries[i].chatKey))
                                  const Icon(
                                    Icons.push_pin,
                                    size: 20,
                                    semanticLabel: 'Chat fijado',
                                  ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(entries[i].subtitle),
                            if (entries[i].status != null) ...[
                              const SizedBox(height: 8),
                              SyncStatusBadge(status: entries[i].status!),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                  PopupMenuButton<String>(
                    key: ValueKey('chat_options_${entries[i].chatKey}'),
                    tooltip: 'Opciones de chat',
                    onSelected: (action) =>
                        _organize(context, entries[i].chatKey, action),
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'pin',
                        child: Text(
                          controller.isChatPinned(entries[i].chatKey)
                              ? 'Desfijar chat'
                              : 'Fijar chat',
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'hide',
                        child: Text('Eliminar de mi lista'),
                      ),
                    ],
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

/// Hilo de mensajes privados entre dos participantes autenticados.
/// Cumple estrictamente la regla del encargo:
/// "Mensajes offline no se envían: indica que requieren conexión y conserva el
/// texto como borrador si procede."
class ChatConversationScreen extends StatefulWidget {
  const ChatConversationScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<ChatConversationScreen> createState() => _ChatConversationScreenState();
}

class _ChatConversationScreenState extends State<ChatConversationScreen> {
  final TextEditingController _msgController = TextEditingController();
  final ScrollController _historyController = ScrollController();
  bool _sending = false;
  List<ChatMessage> _messages = const [];
  String? _offlineOrErrorNotice;
  StreamSubscription<ChatMessage>? _realtimeSub;

  @override
  void initState() {
    super.initState();
    _loadMessagesAndDraft(restoreDraft: true);
  }

  Future<void> _loadMessagesAndDraft({bool restoreDraft = false}) async {
    final conv = widget.controller.selectedConversation;
    final user = widget.controller.currentUser;
    if (conv == null || user == null) return;

    try {
      final list = await widget.controller.database.listMessagesForConversation(
        conversationId: conv.id,
        actingUserId: user.id,
      );
      final draft = restoreDraft
          ? await widget.controller.database.getDraft(
              ownerUserId: user.id,
              draftKey: 'chat_${conv.id}',
            )
          : null;
      if (!mounted) return;

      _realtimeSub ??= widget.controller.remoteGateway
          .watchConversationMessages(conv.id, peerId: conv.peerIdFor(user.id))
          .listen(
            (message) async {
              try {
                await widget.controller.database.recordOnlineMessage(
                  id: message.id,
                  clientMutationId: message.clientMutationId,
                  conversationId: message.conversationId,
                  senderId: message.senderId,
                  senderAlias: message.senderAlias,
                  body: message.body,
                  createdAt: message.createdAt,
                  syncStatus: SyncStatus.confirmado,
                );
                if (mounted) await _loadMessagesAndDraft();
              } catch (e) {
                if (mounted) {
                  setState(
                    () => _offlineOrErrorNotice = 'No se pudo actualizar la conversación. Reintenta al recuperar conexión.',
                  );
                }
              }
            },
            onError: (Object error) {
              if (mounted) {
                setState(
                  () => _offlineOrErrorNotice =
                      'No se pudo conectar al chat. Tu texto sigue disponible.',
                );
              }
            },
          );

      if (mounted) {
        setState(() {
          _messages = list;
          if (draft != null && _msgController.text.isEmpty) {
            _msgController.text = draft.description;
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _offlineOrErrorNotice = e.toString().replaceFirst('Bad state: ', '');
        });
      }
    }
  }

  @override
  void dispose() {
    _realtimeSub?.cancel();
    _msgController.dispose();
    _historyController.dispose();
    super.dispose();
  }

  Future<void> _handleSend() async {
    final conv = widget.controller.selectedConversation;
    if (conv == null || _sending) return;
    final text = _msgController.text;
    setState(() {
      _sending = true;
      _offlineOrErrorNotice = null;
    });
    try {
      await widget.controller.sendChatMessageInThread(thread: conv, text: text);
      if (!mounted) return;
      if (_msgController.text == text) _msgController.clear();
      await _loadMessagesAndDraft();
      if (mounted && _historyController.hasClients) {
        _historyController.jumpTo(0);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _offlineOrErrorNotice = e.toString().replaceFirst('Bad state: ', '');
        });
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final conv = c.selectedConversation;
    if (conv == null) {
      return const Center(child: Text('Selecciona una conversación privada.'));
    }

    final notice =
        _offlineOrErrorNotice ??
        (c.isOfflineMode
            ? 'Estás sin conexión. Tu mensaje se guardará como borrador.'
            : null);
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxHeight < 260;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!compact)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      conv.peerAliasFor(c.currentUser!.id),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      'Chat privado entre ${conv.publicationAuthorAlias} y ${conv.participantAlias}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            Expanded(
              child: CustomScrollView(
                key: const Key('chat_message_history'),
                controller: _historyController,
                reverse: true,
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                slivers: [
                  if (notice != null)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
                        child: Text(
                          notice,
                          key: const Key('banner_chat_offline_notice'),
                          style: const TextStyle(color: AppTheme.amberWarning),
                        ),
                      ),
                    ),
                  if (_messages.isEmpty)
                    const SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(
                        child: Padding(
                          padding: EdgeInsets.all(16),
                          child: Text(
                            'Aún no hay mensajes en esta conversación.',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    )
                  else
                    SliverPadding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      sliver: SliverList.builder(
                        itemCount: _messages.length,
                        itemBuilder: (context, index) {
                          final message =
                              _messages[_messages.length - 1 - index];
                          final isMine = message.senderId == c.currentUser?.id;
                          return ConversationMessageBubble(
                            key: ValueKey(message.id),
                            senderAlias: message.senderAlias,
                            body: message.body,
                            createdAt: message.createdAt,
                            isMine: isMine,
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
            Material(
              color: AppTheme.surfaceCard,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        contextMenuBuilder: buildTextSelectionToolbar,
                        onTapOutside: dismissTextInput,
                        key: const Key('input_chat_message_body'),
                        controller: _msgController,
                        minLines: 1,
                        maxLines: compact ? 1 : 2,
                        decoration: const InputDecoration(
                          hintMaxLines: 1,
                          hintText: 'Escribe tu mensaje',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      key: const Key('btn_send_chat_message'),
                      tooltip: 'Enviar mensaje',
                      onPressed: _sending ? null : _handleSend,
                      icon: const Icon(Icons.send_rounded),
                      style: IconButton.styleFrom(
                        minimumSize: const Size(48, 48),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
