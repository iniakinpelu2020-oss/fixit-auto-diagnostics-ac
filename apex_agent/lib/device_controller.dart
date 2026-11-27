import 'dart:async';

import 'package:flutter/services.dart';

/// Bridge to the native Android device-control layer.
///
/// All methods call the `com.apex.agent/device_control` MethodChannel exposed
/// by `MainActivity.kt` and `AgentAccessibilityService.kt`.
class DeviceController {
  DeviceController({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'com.apex.agent/device_control';
  final MethodChannel _channel;

  // ---------------------------------------------------------------------------
  // Tool schemas (OpenAI function-calling format)
  // ---------------------------------------------------------------------------

  /// JSON tool schemas for an LLM agent. These follow the OpenAI
  /// function-calling shape (`type: function`, `function: {...}`) and can be
  /// adapted to other providers.
  static List<Map<String, dynamic>> get toolSchemas => [
        _functionSchema(
          name: 'open_target',
          description:
              'Open an app or website on the device. Pass an app name, package name, '
              'domain, or full URL. URLs/domains open in the browser; app names open the installed app.',
          parameters: {
            'type': 'object',
            'properties': {
              'target': {
                'type': 'string',
                'description':
                    'App name, package name, domain, or URL to open (e.g. "YouTube", "com.whatsapp", "google.com").',
              },
            },
            'required': ['target'],
          },
        ),
        _functionSchema(
          name: 'list_installed_apps',
          description:
              'List launchable apps installed on the device. Returns app names and package names so you can pick the right target.',
          parameters: {
            'type': 'object',
            'properties': {},
          },
        ),
        _functionSchema(
          name: 'capture_ui',
          description:
              'Capture the current on-screen UI state. Returns a compact list of visible elements with '
              'index, text, contentDescription, viewIdResourceName, className, isClickable, isEditable, '
              'isScrollable, bounds, and centerX/centerY. Call this after every action to see the new screen state.',
          parameters: {
            'type': 'object',
            'properties': {},
          },
        ),
        _functionSchema(
          name: 'tap_ui',
          description:
              'Tap a UI element by visible text/content description/resource id, or by screen coordinates. '
              'Prefer textOrDesc when the element is visible; use x/y for icons or unlabeled controls.',
          parameters: {
            'type': 'object',
            'properties': {
              'textOrDesc': {
                'type': 'string',
                'description': 'Visible text, content description, or resource id of the element to tap.',
              },
              'x': {
                'type': 'number',
                'description': 'Screen X coordinate to tap when textOrDesc is not available.',
              },
              'y': {
                'type': 'number',
                'description': 'Screen Y coordinate to tap when textOrDesc is not available.',
              },
            },
          },
        ),
        _functionSchema(
          name: 'type_into_ui',
          description:
              'Type text into an input field. Targets a field by text/content description/resource id, '
              'or uses the currently focused field when textOrDesc is omitted. Set pressEnter to true to submit/search.',
          parameters: {
            'type': 'object',
            'properties': {
              'textOrDesc': {
                'type': 'string',
                'description': 'Label, hint, content description, or resource id of the target input field.',
              },
              'text': {
                'type': 'string',
                'description': 'The text to enter into the field.',
              },
              'pressEnter': {
                'type': 'boolean',
                'description': 'Whether to press Enter/Search after typing.',
              },
            },
            'required': ['text'],
          },
        ),
        _functionSchema(
          name: 'scroll_ui',
          description:
              'Scroll the current screen. Direction is content direction: "down" reveals lower content, "up" reveals higher content.',
          parameters: {
            'type': 'object',
            'properties': {
              'direction': {
                'type': 'string',
                'enum': ['up', 'down', 'left', 'right'],
                'description': 'Direction to scroll the content.',
              },
            },
            'required': ['direction'],
          },
        ),
        _functionSchema(
          name: 'global_action',
          description: 'Perform an Android global system action.',
          parameters: {
            'type': 'object',
            'properties': {
              'action': {
                'type': 'string',
                'enum': ['back', 'home', 'recents', 'notifications'],
                'description': 'The system action to perform.',
              },
            },
            'required': ['action'],
          },
        ),
        _functionSchema(
          name: 'finish_task',
          description:
              'Call this when the user\'s task is complete, or when you cannot complete it and need to report why.',
          parameters: {
            'type': 'object',
            'properties': {
              'status': {
                'type': 'string',
                'enum': ['success', 'failed'],
                'description': 'Whether the task completed successfully.',
              },
              'summary': {
                'type': 'string',
                'description': 'Short summary of what was done or why it failed.',
              },
            },
            'required': ['status', 'summary'],
          },
        ),
      ];

  static Map<String, dynamic> _functionSchema({
    required String name,
    required String description,
    required Map<String, dynamic> parameters,
  }) {
    return {
      'type': 'function',
      'function': {
        'name': name,
        'description': description,
        'parameters': parameters,
      },
    };
  }

  // ---------------------------------------------------------------------------
  // App / URL launching
  // ---------------------------------------------------------------------------

  /// Opens an app or website. Accepts an app name, package name, domain, or URL.
  Future<Map<String, dynamic>> openTarget(String target) async {
    final result = await _invokeMap('openTarget', {'target': target});
    return result;
  }

  /// Alias for [openTarget] kept for first-spec compatibility.
  Future<Map<String, dynamic>> openApp(String appNameOrPackage) async {
    final result = await _invokeMap('openApp', {'appNameOrPackage': appNameOrPackage});
    return result;
  }

  /// Returns installed launchable apps as `{appName, packageName}` maps.
  Future<List<Map<String, dynamic>>> listInstalledApps() async {
    final result = await _channel.invokeMethod<List<dynamic>>('listInstalledApps');
    return _castListOfMaps(result);
  }

  /// Alias for [listInstalledApps].
  Future<List<Map<String, dynamic>>> getInstalledApps() => listInstalledApps();

  // ---------------------------------------------------------------------------
  // Accessibility / screen interaction
  // ---------------------------------------------------------------------------

  /// Captures the current UI state as a compact list of elements.
  Future<List<Map<String, dynamic>>> captureUiState() async {
    final result = await _channel.invokeMethod<List<dynamic>>('captureUiState');
    return _castListOfMaps(result);
  }

  /// Alias for [captureUiState].
  Future<List<Map<String, dynamic>>> getScreenContent() => captureUiState();

  /// Taps an element by visible text/contentDescription/resourceId, or by coordinates.
  Future<Map<String, dynamic>> tapUi({String? textOrDesc, double? x, double? y}) async {
    return _invokeMap('tapUi', {
      if (textOrDesc != null) 'textOrDesc': textOrDesc,
      if (x != null) 'x': x,
      if (y != null) 'y': y,
    });
  }

  /// Alias for [tapUi].
  Future<Map<String, dynamic>> clickElement(String targetText) {
    return tapUi(textOrDesc: targetText);
  }

  /// Types text into a target field or the currently focused field.
  Future<Map<String, dynamic>> typeIntoUi({
    String? textOrDesc,
    required String text,
    bool pressEnter = false,
  }) async {
    return _invokeMap('typeIntoUi', {
      if (textOrDesc != null) 'textOrDesc': textOrDesc,
      'text': text,
      'pressEnter': pressEnter,
    });
  }

  /// Alias for [typeIntoUi].
  Future<Map<String, dynamic>> inputText(String text) {
    return typeIntoUi(text: text);
  }

  /// Scrolls the screen in the given content direction: up, down, left, or right.
  Future<Map<String, dynamic>> scrollUi(String direction) async {
    return _invokeMap('scrollUi', {'direction': direction});
  }

  /// Performs a global system action: back, home, recents, or notifications.
  Future<Map<String, dynamic>> globalAction(String action) async {
    return _invokeMap('globalAction', {'action': action});
  }

  /// Alias for [globalAction].
  Future<Map<String, dynamic>> performGlobalAction(String action) => globalAction(action);

  // ---------------------------------------------------------------------------
  // Permissions / settings
  // ---------------------------------------------------------------------------

  /// Returns true when the Apex Agent accessibility service is enabled.
  Future<bool> isAccessibilityEnabled() async {
    final result = await _channel.invokeMethod<bool>('isAccessibilityEnabled');
    return result ?? false;
  }

  /// Alias for [isAccessibilityEnabled].
  Future<bool> isServiceEnabled() => isAccessibilityEnabled();

  /// Opens Android Accessibility Settings so the user can enable the service.
  Future<void> openAccessibilitySettings() async {
    await _channel.invokeMethod<void>('openAccessibilitySettings');
  }

  /// Alias for [openAccessibilitySettings].
  Future<void> openServiceSettings() => openAccessibilitySettings();

  // ---------------------------------------------------------------------------
  // Tool execution
  // ---------------------------------------------------------------------------

  /// Executes a tool call by name and returns a JSON-serializable result.
  ///
  /// This is the single entry point used by the agent loop. Unknown tools or
  /// invalid arguments return an error map instead of throwing.
  Future<Map<String, dynamic>> executeTool(String name, Map<String, dynamic> args) async {
    try {
      switch (name) {
        case 'open_target':
        case 'open_app':
          final target = (args['target'] ?? args['appNameOrPackage'] ?? '').toString();
          return await openTarget(target);

        case 'list_installed_apps':
        case 'get_installed_apps':
          final apps = await listInstalledApps();
          return {'ok': true, 'apps': apps, 'count': apps.length};

        case 'capture_ui':
        case 'read_screen':
        case 'get_screen_content':
          final elements = await captureUiState();
          return {'ok': true, 'elements': elements, 'count': elements.length};

        case 'tap_ui':
        case 'click_element':
        case 'tap_element':
          final textOrDesc = _optionalString(args['textOrDesc'] ?? args['targetText'] ?? args['text']);
          final x = _optionalDouble(args['x']);
          final y = _optionalDouble(args['y']);
          return await tapUi(textOrDesc: textOrDesc, x: x, y: y);

        case 'type_into_ui':
        case 'input_text':
        case 'type_text':
          final textOrDesc = _optionalString(args['textOrDesc'] ?? args['targetText']);
          final text = (args['text'] ?? '').toString();
          final pressEnter = args['pressEnter'] == true;
          return await typeIntoUi(textOrDesc: textOrDesc, text: text, pressEnter: pressEnter);

        case 'scroll_ui':
          final direction = (args['direction'] ?? 'down').toString();
          return await scrollUi(direction);

        case 'global_action':
        case 'perform_global_action':
        case 'system_action':
          final action = (args['action'] ?? '').toString();
          return await globalAction(action);

        case 'is_accessibility_enabled':
        case 'is_service_enabled':
          final enabled = await isAccessibilityEnabled();
          return {'ok': true, 'enabled': enabled};

        case 'open_accessibility_settings':
        case 'open_service_settings':
          await openAccessibilitySettings();
          return {'ok': true, 'message': 'Opened accessibility settings'};

        case 'finish_task':
          return {
            'ok': true,
            'status': (args['status'] ?? 'success').toString(),
            'summary': (args['summary'] ?? '').toString(),
          };

        default:
          return {'ok': false, 'error': 'Unknown tool: $name'};
      }
    } on PlatformException catch (e) {
      return {
        'ok': false,
        'error': e.message ?? e.code,
        'code': e.code,
        'details': e.details,
      };
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> _invokeMap(String method, Map<String, dynamic> args) async {
    final result = await _channel.invokeMethod<dynamic>(method, args);
    return _castMap(result);
  }

  static Map<String, dynamic> _castMap(dynamic value) {
    if (value is Map) {
      return value.map((key, v) => MapEntry(key.toString(), _normalize(v)));
    }
    return {'ok': false, 'error': 'Unexpected response type: ${value.runtimeType}'};
  }

  static List<Map<String, dynamic>> _castListOfMaps(dynamic value) {
    if (value is! List) return const [];
    return value.whereType<Map>().map((m) {
      return m.map((key, v) => MapEntry(key.toString(), _normalize(v)));
    }).toList();
  }

  static dynamic _normalize(dynamic value) {
    if (value is Map) {
      return value.map((k, v) => MapEntry(k.toString(), _normalize(v)));
    }
    if (value is List) {
      return value.map(_normalize).toList();
    }
    return value;
  }

  static String? _optionalString(dynamic value) {
    if (value == null) return null;
    final s = value.toString().trim();
    return s.isEmpty ? null : s;
  }

  static double? _optionalDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString());
  }
}
