import 'dart:async';
import 'dart:developer' as dev;

import 'package:flutter/services.dart';
import 'package:flutter_floatwing/flutter_floatwing.dart';

/// Id of the overlay window used by this app.
const String kWindowId = 'default';

/// Dart entrypoint of the overlay window.
///
/// The window must run its own entrypoint: if it ran `main` the app page would
/// be built inside the window isolate as well, and creating a second [Window]
/// object there takes over the shared method channel, which silently drops
/// every message the app sends.
const String kOverlayEntry = 'floatwing';

/// Name carried by every payload the app sends to the window.
const String kMsgAppToWindow = 'app.to.window';

/// Actions the app can ask the window to perform.
const String kActionSetText = 'set_text';
const String kActionSetColor = 'set_color';
const String kActionPing = 'ping';

/// Ask the window to hand over everything it queued for the app.
const String kActionDrain = 'drain';

/// Actions the window reports back to the app.
const String kActionReady = 'ready';
const String kActionCounter = 'counter';

/// Messages the window wants to deliver to the app.
///
/// The plugin only supports a request/response call from the app to the window
/// ([Window.share] -> [Window.onData]). Sharing from the window with a null
/// target makes the native side answer the platform channel twice, which ends
/// up in `IllegalStateException: Reply already submitted`. So the window
/// queues what it wants to say and the app picks it up from the reply of its
/// own requests, plus a short timer so nothing has to wait for a request.
class WindowOutbox {
  final List<Map<String, dynamic>> _pending = [];

  void add(String action, [Map<String, dynamic>? data]) {
    _pending.add(<String, dynamic>{'action': action, ...?data});
  }

  List<Map<String, dynamic>> drain() {
    final items = List<Map<String, dynamic>>.of(_pending);
    _pending.clear();
    return items;
  }
}

/// App side of the link: sends requests to the window and collects the
/// messages the window left for the app.
class WindowLink {
  WindowLink(
    this.window, {
    required this.onMessage,
    this.pollInterval = const Duration(milliseconds: 300),
  });

  final Window window;
  final void Function(Map<String, dynamic> message) onMessage;
  final Duration pollInterval;

  Timer? _timer;
  bool _disposed = false;

  /// Send [action] to the window and return what its handler replied.
  ///
  /// A [MissingPluginException] means the window engine did not install its
  /// `data.share` handler yet, it is expected while the overlay is still
  /// booting and is not an error.
  Future<dynamic> send(String action, [Map<String, dynamic>? data]) async {
    if (_disposed) return null;
    try {
      final reply = await window.share(
        <String, dynamic>{'action': action, ...?data},
        name: kMsgAppToWindow,
      );
      _collect(reply);
      return reply is Map ? reply['result'] : reply;
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      dev.log('[link] $action failed: ${e.code} ${e.message}');
      return null;
    }
  }

  void _collect(dynamic reply) {
    final messages = reply is Map ? reply['messages'] : null;
    if (messages is! List) return;
    for (final m in messages) {
      if (m is Map) onMessage(Map<String, dynamic>.from(m));
    }
  }

  /// Keep draining the window so window -> app messages arrive even when the
  /// app itself has nothing to send.
  void startPolling() {
    _timer ??= Timer.periodic(pollInterval, (_) => send(kActionDrain));
  }

  /// Stop draining, used while the window is hidden.
  void stopPolling() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() {
    _disposed = true;
    stopPolling();
  }
}
