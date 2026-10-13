import 'dart:async';
import 'dart:developer' as dev;

import 'package:flutter/material.dart';
import 'package:flutter_floatwing/flutter_floatwing.dart';

import 'floatwing_bridge.dart';

/// The window the data handler has been installed on. [Window.onData] can only
/// be called once per window instance, so keep track of it here to survive a
/// rebuild of this widget on a reused engine.
Window? _handledWindow;

class MyOverlayWindow extends StatefulWidget {
  const MyOverlayWindow({super.key});

  @override
  State<MyOverlayWindow> createState() => _MyOverlayWindowState();
}

class _MyOverlayWindowState extends State<MyOverlayWindow> {
  final _outbox = WindowOutbox();

  Window? _window;
  String _fromApp = '还没有收到 App 的消息';
  Color _color = Colors.red;
  int _count = 0;
  bool _readySent = false;
  Timer? _attachTimer;

  @override
  void initState() {
    super.initState();
    // FloatwingContainer only builds its child once the window object has been
    // synced from Android, so Window.of(context) is there on the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) => _attachWindow());
    // Safety net: if the first frame did not have the window yet, keep trying.
    _attachTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _handledWindow != null) {
        _attachTimer?.cancel();
        return;
      }
      _attachWindow();
    });
  }

  void _attachWindow() {
    final window = Window.of(context);
    if (!mounted || window == null) return;

    if (_handledWindow != window) {
      window.onData(_onData);
      // the window is brought back with start(), let the app know we are here
      window.on(EventType.WindowResumed, (_, _) => _outbox.add(kActionReady));
      _handledWindow = window;
      dev.log('[overlay] data handler installed for ${window.id}');
    }

    if (_window != window) setState(() => _window = window);

    if (!_readySent) {
      // Tell the app the window is able to receive messages now.
      _outbox.add(kActionReady);
      _readySent = true;
    }
  }

  /// Handles everything the app sends and hands the queued messages back with
  /// the reply, this is what makes the exchange bidirectional.
  Future<dynamic> _onData(String? source, String? name, dynamic data) async {
    final payload = data is Map ? Map<String, dynamic>.from(data) : <String, dynamic>{};

    Object? result;
    switch (payload['action'] as String?) {
      case kActionSetText:
        _fromApp = payload['value']?.toString() ?? '';
        result = 'text updated';
        break;
      case kActionSetColor:
        final value = payload['value'] as int?;
        if (value != null) _color = Color(value);
        result = 'color updated';
        break;
      case kActionPing:
        result = <String, dynamic>{
          'pong': true,
          'at': DateTime.now().toIso8601String(),
        };
        break;
      case kActionDrain:
        // nothing to do, the queue below is drained for every request
        break;
      default:
        result = 'unknown action: ${payload['action']}';
    }

    if (mounted) setState(() {});

    return <String, dynamic>{
      'ok': true,
      'result': result,
      'messages': _outbox.drain(),
    };
  }

  void _sendCounter() {
    setState(() => _count++);
    _outbox.add(kActionCounter, <String, dynamic>{'value': _count});
  }

  void _closeSelf() {
    final window = _window;
    if (window == null) return;
    // force: false only hides the window and pauses this engine, the app can
    // bring it back with start(). Destroying the engine here would leave the
    // plugin unable to create a working window again.
    unawaited(window.close(force: false));
  }

  @override
  void dispose() {
    _attachTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 240,
      child: Card(
        elevation: 8,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: .min,
            crossAxisAlignment: .start,
            children: [
              Row(
                children: [
                  CircleAvatar(backgroundColor: _color, radius: 12),
                  const SizedBox(width: 8),
                  const Text('悬浮窗', style: TextStyle(fontWeight: FontWeight.w600)),
                ],
              ),
              const Divider(),
              Text(_fromApp),
              const SizedBox(height: 8),
              Text('计数: $_count'),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: _sendCounter,
                child: const Text('计数 +1 发给 App'),
              ),
              TextButton(
                onPressed: _closeSelf,
                child: const Text('关闭悬浮窗'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
