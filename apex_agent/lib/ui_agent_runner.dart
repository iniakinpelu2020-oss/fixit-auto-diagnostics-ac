import 'dart:async';
import 'dart:convert';

import 'device_controller.dart';

/// System prompt that instructs the LLM to operate the real device UI.
const String uiAgentSystemPrompt = '''
You are an on-device Android UI automation agent. You must complete the user's task by actually operating the device UI with the provided tools.

Rules:
- Always use UI tools to do the work on screen: open_target, capture_ui, tap_ui, type_into_ui, scroll_ui, global_action, finish_task.
- Never simulate actions, never invent results, and never substitute external APIs for on-screen interaction.
- Open the target app or website first when needed. Use open_target for apps, domains, and URLs.
- After each action, you will receive fresh UI state from capture_ui. Base your next decision on that real screen state.
- Prefer tapping elements by visible text/content description. Use coordinates only when necessary.
- If the target element is off-screen, use scroll_ui and then inspect the new UI state.
- If you get stuck, try sensible recovery steps (scroll, back, reopen target) before giving up.
- Call finish_task with status "success" and a short summary when the task is done.
- Call finish_task with status "failed" and a clear reason when the task cannot be completed.
''';

/// Minimal chat message used by the agent loop.
class AgentMessage {
  AgentMessage({
    required this.role,
    this.content,
    this.toolCallId,
    this.toolCalls,
    this.name,
  });

  final String role; // system | user | assistant | tool
  final String? content;
  final String? toolCallId;
  final List<AgentToolCall>? toolCalls;
  final String? name;

  Map<String, dynamic> toJson() {
    return {
      'role': role,
      if (content != null) 'content': content,
      if (toolCallId != null) 'tool_call_id': toolCallId,
      if (name != null) 'name': name,
      if (toolCalls != null)
        'tool_calls': toolCalls!.map((c) => c.toJson()).toList(),
    };
  }
}

/// A tool call requested by the LLM.
class AgentToolCall {
  AgentToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });

  final String id;
  final String name;
  final Map<String, dynamic> arguments;

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': 'function',
        'function': {
          'name': name,
          // OpenAI expects a JSON-encoded string; adapters for other providers can decode if needed.
          'arguments': jsonEncode(arguments),
        },
      };
}

/// LLM response for one agent turn.
class AgentLlmResponse {
  AgentLlmResponse({
    this.content,
    this.toolCalls = const [],
  });

  final String? content;
  final List<AgentToolCall> toolCalls;

  bool get hasToolCalls => toolCalls.isNotEmpty;
}

/// Abstraction over the LLM provider used by [UiAgentRunner].
///
/// Implement this to connect OpenAI, Anthropic, Gemini, or any other provider.
/// The runner only depends on this interface.
abstract class UiAgentLlmClient {
  Future<AgentLlmResponse> complete({
    required List<AgentMessage> messages,
    required List<Map<String, dynamic>> tools,
  });
}

/// Event emitted by [UiAgentRunner] for UI/logging.
class AgentRunEvent {
  AgentRunEvent({
    required this.type,
    required this.message,
    this.toolName,
    this.toolArguments,
    this.toolResult,
    this.step,
  });

  final String type; // started | thinking | tool_call | tool_result | finished | cancelled | error
  final String message;
  final String? toolName;
  final Map<String, dynamic>? toolArguments;
  final Map<String, dynamic>? toolResult;
  final int? step;
}

/// Final result of an agent run.
class AgentRunResult {
  AgentRunResult({
    required this.status,
    required this.summary,
    required this.steps,
    required this.messages,
  });

  final String status; // success | failed | cancelled
  final String summary;
  final int steps;
  final List<AgentMessage> messages;
}

/// Runs an autonomous UI-first agent loop.
///
/// The loop executes tool calls, pauses briefly for UI transitions, captures
/// fresh UI state, feeds it back to the LLM, and repeats until `finish_task`,
/// cancellation, or the step limit is reached.
class UiAgentRunner {
  UiAgentRunner({
    required this.controller,
    required this.llmClient,
    this.maxSteps = 30,
    this.transitionDelay = const Duration(milliseconds: 1200),
    this.captureAfterAction = true,
    this.maxElementsInContext = 80,
    this.onEvent,
  });

  final DeviceController controller;
  final UiAgentLlmClient llmClient;
  final int maxSteps;
  final Duration transitionDelay;
  final bool captureAfterAction;
  final int maxElementsInContext;
  final void Function(AgentRunEvent event)? onEvent;

  bool _cancelled = false;
  bool get isCancelled => _cancelled;

  /// Requests immediate cancellation. The loop stops before the next LLM/tool step.
  void cancel() {
    _cancelled = true;
  }

  /// Runs the agent for [task]. Returns when the task finishes, fails, is cancelled,
  /// or reaches [maxSteps].
  Future<AgentRunResult> run(String task) async {
    _cancelled = false;
    final messages = <AgentMessage>[
      AgentMessage(role: 'system', content: uiAgentSystemPrompt),
      AgentMessage(role: 'user', content: task),
    ];

    _emit(AgentRunEvent(type: 'started', message: 'Starting task: $task', step: 0));

    // Initial screen capture gives the LLM real context before first action.
    final initialUi = await _safeCaptureUi();
    messages.add(
      AgentMessage(
        role: 'user',
        content: 'Current UI state (JSON):\n${_truncateUiForContext(initialUi)}',
      ),
    );

    var steps = 0;
    while (steps < maxSteps) {
      if (_cancelled) {
        return _cancelledResult(messages, steps);
      }

      steps += 1;
      _emit(AgentRunEvent(type: 'thinking', message: 'Requesting next action', step: steps));

      final AgentLlmResponse response;
      try {
        response = await llmClient.complete(
          messages: messages,
          tools: DeviceController.toolSchemas,
        );
      } catch (e) {
        _emit(AgentRunEvent(type: 'error', message: 'LLM error: $e', step: steps));
        return AgentRunResult(
          status: 'failed',
          summary: 'LLM request failed: $e',
          steps: steps,
          messages: messages,
        );
      }

      if (_cancelled) return _cancelledResult(messages, steps);

      messages.add(
        AgentMessage(
          role: 'assistant',
          content: response.content,
          toolCalls: response.toolCalls.isEmpty ? null : response.toolCalls,
        ),
      );

      if (!response.hasToolCalls) {
        // No tool call: nudge the model to use tools.
        messages.add(
          AgentMessage(
            role: 'user',
            content:
                'Use the UI tools to act on the device. If the task is done or impossible, call finish_task.',
          ),
        );
        continue;
      }

      for (final toolCall in response.toolCalls) {
        if (_cancelled) return _cancelledResult(messages, steps);

        _emit(AgentRunEvent(
          type: 'tool_call',
          message: 'Calling ${toolCall.name}',
          toolName: toolCall.name,
          toolArguments: toolCall.arguments,
          step: steps,
        ));

        Map<String, dynamic> toolResult;
        try {
          toolResult = await controller.executeTool(toolCall.name, toolCall.arguments);
        } catch (e) {
          toolResult = {'ok': false, 'error': e.toString()};
        }

        _emit(AgentRunEvent(
          type: 'tool_result',
          message: 'Result from ${toolCall.name}',
          toolName: toolCall.name,
          toolArguments: toolCall.arguments,
          toolResult: toolResult,
          step: steps,
        ));

        // Terminal tool.
        if (toolCall.name == 'finish_task') {
          final status = (toolResult['status'] ?? 'success').toString();
          final summary = (toolResult['summary'] ?? response.content ?? 'Task finished').toString();
          messages.add(
            AgentMessage(
              role: 'tool',
              toolCallId: toolCall.id,
              name: toolCall.name,
              content: _encodeForMessage(toolResult),
            ),
          );
          _emit(AgentRunEvent(
            type: 'finished',
            message: summary,
            toolName: toolCall.name,
            toolResult: toolResult,
            step: steps,
          ));
          return AgentRunResult(
            status: status == 'failed' ? 'failed' : 'success',
            summary: summary,
            steps: steps,
            messages: messages,
          );
        }

        // Wait briefly for UI/page transitions, then capture fresh UI state.
        if (captureAfterAction) {
          await Future<void>.delayed(transitionDelay);
        }
        if (_cancelled) return _cancelledResult(messages, steps);

        final freshUi = captureAfterAction ? await _safeCaptureUi() : const <Map<String, dynamic>>[];
        final enrichedResult = <String, dynamic>{
          ...toolResult,
          if (captureAfterAction) 'ui_state': _compactUiForContext(freshUi),
          if (captureAfterAction) 'ui_element_count': freshUi.length,
        };

        messages.add(
          AgentMessage(
            role: 'tool',
            toolCallId: toolCall.id,
            name: toolCall.name,
            content: _encodeForMessage(enrichedResult),
          ),
        );
      }
    }

    _emit(AgentRunEvent(
      type: 'finished',
      message: 'Reached step limit ($maxSteps)',
      step: steps,
    ));
    return AgentRunResult(
      status: 'failed',
      summary: 'Stopped after reaching the step limit of $maxSteps.',
      steps: steps,
      messages: messages,
    );
  }

  Future<List<Map<String, dynamic>>> _safeCaptureUi() async {
    try {
      final elements = await controller.captureUiState();
      return elements;
    } catch (e) {
      _emit(AgentRunEvent(type: 'error', message: 'Failed to capture UI: $e'));
      return const [];
    }
  }

  List<Map<String, dynamic>> _compactUiForContext(List<Map<String, dynamic>> elements) {
    final limited = elements.take(maxElementsInContext).toList();
    return limited.map(_compactElement).toList();
  }

  String _truncateUiForContext(List<Map<String, dynamic>> elements) {
    final compact = _compactUiForContext(elements);
    return _encodeForMessage({
      'count': elements.length,
      'shown': compact.length,
      'elements': compact,
    });
  }

  Map<String, dynamic> _compactElement(Map<String, dynamic> el) {
    // Keep only fields useful for decision-making to reduce token usage.
    final compact = <String, dynamic>{
      'index': el['index'],
      if (_nonEmpty(el['text'])) 'text': el['text'],
      if (_nonEmpty(el['contentDescription'])) 'contentDescription': el['contentDescription'],
      if (_nonEmpty(el['viewIdResourceName'])) 'viewIdResourceName': el['viewIdResourceName'],
      if (_nonEmpty(el['className'])) 'className': _shortClassName(el['className'].toString()),
      if (el['isClickable'] == true) 'isClickable': true,
      if (el['isEditable'] == true) 'isEditable': true,
      if (el['isScrollable'] == true) 'isScrollable': true,
      if (el['isCheckable'] == true) 'isCheckable': true,
      if (el['isEnabled'] == false) 'isEnabled': false,
      'centerX': el['centerX'],
      'centerY': el['centerY'],
    };
    return compact;
  }

  static bool _nonEmpty(dynamic value) {
    if (value == null) return false;
    if (value is String) return value.trim().isNotEmpty;
    return true;
  }

  static String _shortClassName(String className) {
    final parts = className.split('.');
    return parts.isEmpty ? className : parts.last;
  }

  static String _encodeForMessage(Object value) {
    try {
      return jsonEncode(value);
    } catch (_) {
      return value.toString();
    }
  }

  AgentRunResult _cancelledResult(List<AgentMessage> messages, int steps) {
    _emit(AgentRunEvent(type: 'cancelled', message: 'Cancelled by user', step: steps));
    return AgentRunResult(
      status: 'cancelled',
      summary: 'Task cancelled by user.',
      steps: steps,
      messages: messages,
    );
  }

  void _emit(AgentRunEvent event) {
    final cb = onEvent;
    if (cb != null) cb(event);
  }
}
