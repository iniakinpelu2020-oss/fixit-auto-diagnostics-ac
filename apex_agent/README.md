# Apex Agent

Flutter + Android scaffold for on-device AI UI automation.

## What's included

- `android/app/src/main/kotlin/com/apex/agent/MainActivity.kt` - Flutter `MethodChannel` (`com.apex.agent/device_control`) for app/URL launching, installed app listing, and accessibility bridge calls.
- `android/app/src/main/kotlin/com/apex/agent/AgentAccessibilityService.kt` - Accessibility service that captures UI state, taps, types, scrolls, and performs global actions.
- `android/app/src/main/res/xml/accessibility_service_config.xml` - Accessibility service configuration.
- `android/app/src/main/AndroidManifest.xml` - Package visibility queries, service registration, and permissions.
- `lib/device_controller.dart` - Dart bridge with typed methods, LLM tool schemas, and a `executeTool` dispatcher.
- `lib/ui_agent_runner.dart` - UI-first autonomous agent loop with stop/cancel control and fresh UI capture after each action.
- `lib/main.dart` - Minimal Flutter UI with an Accessibility permission setup banner/button.

## MethodChannel

Channel: `com.apex.agent/device_control`

Primary methods:

| Method | Args | Description |
|---|---|---|
| `openTarget` | `{target: String}` | Opens a URL/domain in browser or an installed app by name/package. |
| `listInstalledApps` | - | Returns installed launchable apps (`appName`, `packageName`). |
| `captureUiState` | - | Returns compact visible UI elements with bounds and center coordinates. |
| `tapUi` | `{textOrDesc?, x?, y?}` | Taps by text/description/resource id, or by screen coordinates. |
| `typeIntoUi` | `{textOrDesc?, text, pressEnter?}` | Types into a target/focused editable field; optional Enter/Search. |
| `scrollUi` | `{direction}` | Swipes `up`, `down`, `left`, or `right`. |
| `globalAction` | `{action}` | Performs `back`, `home`, `recents`, or `notifications`. |
| `isAccessibilityEnabled` | - | Returns whether the accessibility service is enabled. |
| `openAccessibilitySettings` | - | Opens Android Accessibility settings. |

Compatibility aliases are also supported (`openApp`, `getInstalledApps`, `getScreenContent`, `clickElement`, `inputText`, `performGlobalAction`, etc.).

## LLM tool schemas

`DeviceController.toolSchemas` exposes OpenAI-style function schemas for:

- `open_target`
- `list_installed_apps`
- `capture_ui`
- `tap_ui`
- `type_into_ui`
- `scroll_ui`
- `global_action`
- `finish_task`

## Agent loop

`UiAgentRunner` runs a UI-first loop:

1. Send the task + tool schemas to the LLM.
2. Execute the returned tool call through `DeviceController.executeTool`.
3. Pause briefly for UI/page transitions.
4. Capture fresh UI state with `capture_ui`.
5. Feed tool result + fresh UI state back to the LLM.
6. Repeat until `finish_task`, stop/cancel, or max steps.

Wire an `UiAgentLlmClient` implementation into `DeviceControlHomePage(llmClient: ...)` to enable autonomous runs.

## Android notes

- Requires Android Accessibility permission to read/interact with other apps and web content.
- `AndroidManifest.xml` includes package visibility queries for launcher apps and http/https VIEW intents.
- The accessibility service is declared with `android.permission.BIND_ACCESSIBILITY_SERVICE`.
- Gestures and UI reads operate on the currently active window; behavior depends on the target app's accessibility tree.
