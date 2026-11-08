import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'entra_mobile_session.dart';

/// Comparte una conexión por sesión. La API HTTP conserva el historial.
class AzureChatSignals {
  AzureChatSignals(this._session);

  final EntraMobileSession _session;
  late final _events = StreamController<String>.broadcast(
    onListen: () => unawaited(_connect(++_generation)),
    onCancel: reset,
  );
  Stream<String> get events => _events.stream;

  int _generation = 0;
  Timer? _timer;
  WebSocketChannel? _socket;
  StreamSubscription<dynamic>? _messages;

  void reset() {
    ++_generation;
    _timer?.cancel();
    unawaited(_messages?.cancel());
    _messages = null;
    final socket = _socket;
    _socket = null;
    if (socket != null) unawaited(_close(socket));
  }

  Future<void> _close(WebSocketChannel socket) async {
    try {
      await socket.sink.close();
    } catch (_) {
      // Un socket desconectado puede haber cerrado su salida.
    }
  }

  Future<void> _connect(int generation) async {
    final owner = _session.profile?.id;
    if (owner == null || !_events.hasListener) return;
    try {
      final data = await _session.request('GET', 'chats/negotiate');
      if (generation != _generation || owner != _session.profile?.id) return;
      final raw = data['url'];
      if (raw == null) {
        _retry(generation, const Duration(seconds: 60));
        return;
      }
      final uri = Uri.tryParse(raw as String);
      if (uri == null || uri.scheme != 'wss' || uri.host.isEmpty) {
        throw const FormatException('Conexión de chat inválida.');
      }
      final socket = WebSocketChannel.connect(uri);
      _socket = socket;
      await socket.ready.timeout(const Duration(seconds: 8));
      if (generation != _generation) return;
      _messages = socket.stream.listen(
        (value) {
          if (generation != _generation ||
              owner != _session.profile?.id ||
              value is! String) {
            return;
          }
          try {
            final event = jsonDecode(value);
            final type = event is Map ? event['type'] : null;
            if (type == 'private_changed' || type == 'groups_changed') {
              _events.add(type as String);
            }
          } on FormatException {
            // Ignora mensajes que no sean señales de chat.
          }
        },
        onDone: () => _retry(generation, const Duration(seconds: 4)),
        onError: (Object _) => _retry(generation, const Duration(seconds: 4)),
        cancelOnError: true,
      );
      _events.add('connected');
      // Renegocia el distrito y la sesión antes de que venza el token.
      _timer = Timer(
        const Duration(minutes: 4),
        () => _retry(generation, Duration.zero),
      );
    } catch (_) {
      _retry(generation, const Duration(seconds: 15));
    }
  }

  void _retry(int generation, Duration delay) {
    if (generation != _generation) return;
    reset();
    final next = _generation;
    if (_events.hasListener) {
      _timer = Timer(delay, () => unawaited(_connect(next)));
    }
  }
}
