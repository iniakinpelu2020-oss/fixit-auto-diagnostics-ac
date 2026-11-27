import 'package:flutter/material.dart';

import 'device_controller.dart';
import 'ui_agent_runner.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ApexAgentApp());
}

class ApexAgentApp extends StatelessWidget {
  const ApexAgentApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Apex Agent',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1A73E8),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
      ),
      home: const DeviceControlHomePage(),
    );
  }
}

class DeviceControlHomePage extends StatefulWidget {
  const DeviceControlHomePage({
    super.key,
    this.llmClient,
  });

  /// Optional LLM client. When provided, the UI can run the autonomous UI agent loop.
  final UiAgentLlmClient? llmClient;

  @override
  State<DeviceControlHomePage> createState() => _DeviceControlHomePageState();
}

class _DeviceControlHomePageState extends State<DeviceControlHomePage>
    with WidgetsBindingObserver {
  final DeviceController _controller = DeviceController();
  final TextEditingController _taskController = TextEditingController();
  final ScrollController _logScrollController = ScrollController();

  bool _checkingPermission = true;
  bool _accessibilityEnabled = false;
  bool _isRunning = false;
  String _status = 'Ready';
  final List<String> _logs = <String>[];
  UiAgentRunner? _runner;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshPermissionStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _taskController.dispose();
    _logScrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshPermissionStatus();
    }
  }

  Future<void> _refreshPermissionStatus() async {
    setState(() => _checkingPermission = true);
    try {
      final enabled = await _controller.isAccessibilityEnabled();
      if (!mounted) return;
      setState(() {
        _accessibilityEnabled = enabled;
        _checkingPermission = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _checkingPermission = false;
        _status = 'Failed to check accessibility permission: $e';
      });
      _appendLog('Permission check error: $e');
    }
  }

  Future<void> _openAccessibilitySettings() async {
    try {
      await _controller.openAccessibilitySettings();
      _appendLog('Opened Accessibility Settings.');
    } catch (e) {
      _appendLog('Failed to open Accessibility Settings: $e');
    }
  }

  Future<void> _runTask() async {
    final task = _taskController.text.trim();
    if (task.isEmpty) {
      _appendLog('Enter a task first.');
      return;
    }
    if (!_accessibilityEnabled) {
      _appendLog('Accessibility service is disabled. Enable it before running the agent.');
      return;
    }
    final llmClient = widget.llmClient;
    if (llmClient == null) {
      _appendLog(
        'No LLM client configured. Wire a UiAgentLlmClient into DeviceControlHomePage.llmClient to run autonomous tasks.',
      );
      return;
    }
    if (_isRunning) return;

    final runner = UiAgentRunner(
      controller: _controller,
      llmClient: llmClient,
      onEvent: (event) {
        if (!mounted) return;
        setState(() {
          _status = event.message;
          _logs.add('[${event.type}] ${event.message}');
          if (_logs.length > 300) {
            _logs.removeRange(0, _logs.length - 300);
          }
        });
        _scrollLogsToBottom();
      },
    );

    setState(() {
      _runner = runner;
      _isRunning = true;
      _status = 'Running task...';
    });
    _appendLog('Task started: $task');

    try {
      final result = await runner.run(task);
      if (!mounted) return;
      setState(() {
        _status = '${result.status.toUpperCase()}: ${result.summary}';
      });
      _appendLog('Task finished (${result.status}): ${result.summary}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Agent error: $e');
      _appendLog('Agent error: $e');
    } finally {
      if (!mounted) return;
      setState(() {
        _isRunning = false;
        _runner = null;
      });
    }
  }

  void _stopTask() {
    final runner = _runner;
    if (runner == null) return;
    runner.cancel();
    _appendLog('Stop requested by user.');
    setState(() => _status = 'Stopping...');
  }

  Future<void> _captureUi() async {
    try {
      final elements = await _controller.captureUiState();
      _appendLog('Captured ${elements.length} UI elements.');
      if (elements.isNotEmpty) {
        final preview = elements.take(10).map((e) {
          final text = (e['text'] ?? '').toString();
          final desc = (e['contentDescription'] ?? '').toString();
          final label = text.isNotEmpty ? text : desc;
          return '- ${label.isEmpty ? '(no label)' : label} @ (${e['centerX']}, ${e['centerY']})';
        }).join('\n');
        _appendLog('Preview:\n$preview');
      }
    } catch (e) {
      _appendLog('captureUi failed: $e');
    }
  }

  Future<void> _listApps() async {
    try {
      final apps = await _controller.listInstalledApps();
      _appendLog('Found ${apps.length} launchable apps.');
      final preview = apps.take(15).map((a) => '- ${a['appName']} (${a['packageName']})').join('\n');
      if (preview.isNotEmpty) _appendLog('Preview:\n$preview');
    } catch (e) {
      _appendLog('listInstalledApps failed: $e');
    }
  }

  void _appendLog(String message) {
    if (!mounted) return;
    setState(() {
      _logs.add(message);
      if (_logs.length > 300) {
        _logs.removeRange(0, _logs.length - 300);
      }
    });
    _scrollLogsToBottom();
  }

  void _scrollLogsToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_logScrollController.hasClients) return;
      _logScrollController.animateTo(
        _logScrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Apex Agent'),
        actions: [
          IconButton(
            tooltip: 'Refresh permission status',
            onPressed: _checkingPermission ? null : _refreshPermissionStatus,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (!_checkingPermission && !_accessibilityEnabled)
              _AccessibilitySetupBanner(
                onOpenSettings: _openAccessibilitySettings,
              ),
            if (_checkingPermission)
              const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _StatusCard(
                    accessibilityEnabled: _accessibilityEnabled,
                    checking: _checkingPermission,
                    status: _status,
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: _taskController,
                    minLines: 2,
                    maxLines: 4,
                    textInputAction: TextInputAction.done,
                    decoration: const InputDecoration(
                      labelText: 'Task for the agent',
                      hintText: 'e.g. Open YouTube and search for Flutter tutorials',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: _isRunning ? null : _runTask,
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('Run task'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _isRunning ? _stopTask : null,
                        icon: const Icon(Icons.stop),
                        label: const Text('Stop'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _isRunning ? null : _captureUi,
                        icon: const Icon(Icons.screenshot_monitor),
                        label: const Text('Capture UI'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _isRunning ? null : _listApps,
                        icon: const Icon(Icons.apps),
                        label: const Text('List apps'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Activity log',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Container(
                    height: 280,
                    decoration: BoxDecoration(
                      border: Border.all(color: theme.colorScheme.outlineVariant),
                      borderRadius: BorderRadius.circular(12),
                      color: theme.colorScheme.surfaceContainerLowest,
                    ),
                    child: ListView.builder(
                      controller: _logScrollController,
                      padding: const EdgeInsets.all(12),
                      itemCount: _logs.length,
                      itemBuilder: (context, index) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text(
                            _logs[index],
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontFamily: 'monospace',
                              height: 1.35,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AccessibilitySetupBanner extends StatelessWidget {
  const _AccessibilitySetupBanner({required this.onOpenSettings});

  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.accessibility_new, color: theme.colorScheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Accessibility service required',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Enable Apex Agent in Android Accessibility settings so it can read the screen, tap, type, and scroll for you.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.tonal(
                    onPressed: onOpenSettings,
                    child: const Text('Open Accessibility Settings'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.accessibilityEnabled,
    required this.checking,
    required this.status,
  });

  final bool accessibilityEnabled;
  final bool checking;
  final String status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = checking
        ? theme.colorScheme.secondary
        : accessibilityEnabled
            ? Colors.green.shade700
            : theme.colorScheme.error;
    final label = checking
        ? 'Checking...'
        : accessibilityEnabled
            ? 'Enabled'
            : 'Disabled';

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.security, color: color),
                const SizedBox(width: 8),
                Text(
                  'Accessibility Service: $label',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(status, style: theme.textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}
