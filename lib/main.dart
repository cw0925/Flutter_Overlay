import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_floatwing/flutter_floatwing.dart';

import 'floatwing_bridge.dart';
import 'my_overlay_window.dart';

void main() {
  runApp(const MyApp());
}

/// Entrypoint of the overlay window.
///
/// It has to be a top level function marked with `vm:entry-point` and it must
/// build the overlay UI only. Running `main` here would also build the app page
/// inside the window isolate, and the [Window] object that page creates would
/// take over the shared method channel, silently dropping every message sent
/// by the app.
@pragma('vm:entry-point')
void floatwing() {
  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    // .floatwing() is required: it wraps the widget into a FloatwingContainer
    // that syncs the window instance and reports the measured size back to the
    // native window (otherwise the overlay stays 0x0 and is invisible).
    home: MyOverlayWindow().floatwing(debug: false),
  ));
}

/// Logical size of the overlay, only used as the initial size of the native
/// window, the plugin resizes it to the measured size on the first frame.
const double _overlayWidth = 240;
const double _overlayHeight = 260;

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        colorScheme: .fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const MyHomePage(title: 'Flutter Demo Home Page'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final _textController = TextEditingController(text: '来自 App 的问候');
  final _palette = <Color>[
    Colors.red,
    Colors.orange,
    Colors.green,
    Colors.blue,
    Colors.purple,
  ];
  final _fromWindow = <String>[];

  /// One single window instance for the lifetime of the page. Reusing it keeps
  /// the event listeners registered only once.
  Window? _window;
  WindowLink? _link;

  String _status = '未创建';
  String? _lastReply;
  bool _created = false;
  bool _shown = false;
  bool _ready = false;
  bool _busy = false;
  int _colorIndex = 0;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    final ratio = PlatformDispatcher.instance.implicitView?.devicePixelRatio ?? 3.0;
    final window = WindowConfig(
      id: kWindowId,
      entry: kOverlayEntry,
      draggable: true,
      width: (_overlayWidth * ratio).round(),
      height: (_overlayHeight * ratio).round(),
    ).to();

    window
      ..on(EventType.WindowCreated, (_, _) {
        _created = true;
        _setStatus('已创建');
      })
      ..on(EventType.WindowStarted, (_, _) {
        _shown = true;
        _setStatus('已显示');
      })
      ..on(EventType.WindowPaused, (_, _) => _onWindowHidden())
      ..on(EventType.WindowDestroy, (_, _) => _onWindowDestroyed());

    _window = window;
    _link = WindowLink(window, onMessage: _onWindowMessage);

    if (!await FloatwingPlugin().checkPermission()) {
      await FloatwingPlugin().openPermissionSetting();
      _setStatus('等待悬浮窗权限');
      return;
    }
    await FloatwingPlugin().initialize();

    _setStatus(FloatwingPlugin().windows.containsKey(kWindowId)
        ? '发现已存在的悬浮窗，可点击打开'
        : '未打开');
  }

  void _setStatus(String value) {
    if (!mounted) return;
    setState(() => _status = value);
  }

  Future<void> _openWindow() async {
    final window = _window;
    if (_busy || window == null) return;
    _busy = true;
    try {
      if (!await FloatwingPlugin().isServiceRunning()) {
        await FloatwingPlugin().startService();
      }

      if (_created) {
        // the window still exists, just show it again instead of creating a
        // new flutter engine
        await window.start();
      } else {
        final created = await window.create(start: true);
        if (created == null) {
          _setStatus('创建失败');
          return;
        }
        _created = true;
      }

      _link?.startPolling();
      _setStatus('已显示，等待悬浮窗就绪');
      // give the window a chance to report "ready" immediately
      await _link?.send(kActionDrain);
      _scheduleReadyCheck();
    } catch (e) {
      _setStatus('打开失败: $e');
    } finally {
      _busy = false;
    }
  }

  /// Surfaced in the UI so a window engine that never answers is visible
  /// instead of leaving every button disabled with no explanation.
  void _scheduleReadyCheck() {
    Future<void>.delayed(const Duration(seconds: 6), () {
      if (!mounted || _ready || !_shown) return;
      setState(() => _status = '悬浮窗未就绪：窗口引擎没有应答 data.share');
    });
  }

  Future<void> _closeWindow() async {
    final window = _window;
    if (window == null || !_created) return;
    // force: false keeps the flutter engine alive so start() works afterwards,
    // destroying it leaves the plugin unable to create a working window again
    await window.close(force: false);
    _onWindowHidden();
  }

  void _onWindowHidden() {
    _link?.stopPolling();
    if (!mounted) return;
    setState(() {
      _shown = false;
      _ready = false;
      _status = '已关闭（可重新打开）';
    });
  }

  void _onWindowDestroyed() {
    _link?.stopPolling();
    _created = false;
    if (!mounted) return;
    setState(() {
      _shown = false;
      _ready = false;
      _status = '已销毁';
    });
  }

  void _onWindowMessage(Map<String, dynamic> message) {
    if (!mounted) return;
    switch (message['action'] as String?) {
      case kActionReady:
        setState(() {
          _ready = true;
          _status = '悬浮窗已就绪';
        });
        break;
      case kActionCounter:
        setState(() => _fromWindow.insert(0, '计数 => ${message['value']}'));
        break;
    }
  }

  Future<void> _sendText() async {
    _runRequest(kActionSetText, {'value': _textController.text});
  }

  Future<void> _changeColor() async {
    _colorIndex = (_colorIndex + 1) % _palette.length;
    _runRequest(kActionSetColor, {'value': _palette[_colorIndex].toARGB32()});
  }

  Future<void> _ping() async {
    _runRequest(kActionPing);
  }

  Future<void> _runRequest(String action, [Map<String, dynamic>? data]) async {
    final reply = await _link?.send(action, data);
    if (!mounted) return;
    setState(() {
      _lastReply = reply == null ? '$action -> 无回复（悬浮窗未就绪）' : '$action -> $reply';
    });
  }

  @override
  void dispose() {
    _link?.dispose();
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: .start,
          children: [
            Text('悬浮窗状态: $_status'),
            Text('双向通道: ${_ready ? "已就绪" : "未就绪"}'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  onPressed: _shown ? null : _openWindow,
                  child: const Text('打开悬浮窗'),
                ),
                OutlinedButton(
                  onPressed: _shown ? _closeWindow : null,
                  child: const Text('关闭悬浮窗'),
                ),
              ],
            ),
            const Divider(height: 28),
            TextField(
              controller: _textController,
              decoration: const InputDecoration(
                labelText: '发给悬浮窗的文字',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: _shown ? _sendText : null,
                  child: const Text('发送文字'),
                ),
                FilledButton.tonal(
                  onPressed: _shown ? _changeColor : null,
                  child: const Text('换个颜色'),
                ),
                FilledButton.tonal(
                  onPressed: _shown ? _ping : null,
                  child: const Text('Ping'),
                ),
              ],
            ),
            if (_lastReply != null) ...[
              const SizedBox(height: 12),
              Text('悬浮窗回复: $_lastReply'),
            ],
            const Divider(height: 28),
            Text('来自悬浮窗的消息', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            Expanded(
              child: _fromWindow.isEmpty
                  ? const Text('（暂无）')
                  : ListView.builder(
                      itemCount: _fromWindow.length,
                      itemBuilder: (context, index) => ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(_fromWindow[index]),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
