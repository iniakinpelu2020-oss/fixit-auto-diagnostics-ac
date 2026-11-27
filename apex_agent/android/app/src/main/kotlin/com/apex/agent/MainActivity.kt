package com.apex.agent

import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {

    companion object {
        private const val TAG = "ApexMainActivity"
        private const val CHANNEL = "com.apex.agent/device_control"
        private val DOMAIN_REGEX =
            Regex("^(?i)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,}(?:[/:?#].*)?$")
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor: ExecutorService = Executors.newSingleThreadExecutor { r ->
        Thread(r, "apex-agent-device-control").apply { isDaemon = true }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                handleMethodCall(call, result)
            }
    }

    override fun onDestroy() {
        executor.shutdown()
        super.onDestroy()
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "openTarget" -> {
                val target = call.argument<String>("target")?.trim().orEmpty()
                executor.execute { runResult(result) { openTarget(target) } }
            }

            "openApp" -> {
                val appNameOrPackage = call.argument<String>("appNameOrPackage")
                    ?: call.argument<String>("target")
                    ?: ""
                executor.execute { runResult(result) { openApp(appNameOrPackage.trim()) } }
            }

            "listInstalledApps", "getInstalledApps" -> {
                executor.execute { runResult(result) { listInstalledApps() } }
            }

            "captureUiState", "getScreenContent", "readScreen", "read_screen", "capture_ui" -> {
                executor.execute {
                    runResult(result) {
                        withService { it.captureUiState() }
                    }
                }
            }

            "tapUi", "clickElement", "tap_element", "tap_ui" -> {
                val textOrDesc = call.argument<String>("textOrDesc")
                    ?: call.argument<String>("targetText")
                    ?: call.argument<String>("text")
                val x = call.argument<Number>("x")?.toFloat()
                val y = call.argument<Number>("y")?.toFloat()
                executor.execute {
                    runResult(result) {
                        withService { it.tapUi(textOrDesc, x, y) }
                    }
                }
            }

            "typeIntoUi", "inputText", "type_text", "type_into_ui" -> {
                val textOrDesc = call.argument<String>("textOrDesc")
                    ?: call.argument<String>("targetText")
                val text = call.argument<String>("text") ?: ""
                val pressEnter = call.argument<Boolean>("pressEnter") ?: false
                executor.execute {
                    runResult(result) {
                        withService { it.typeIntoUi(textOrDesc, text, pressEnter) }
                    }
                }
            }

            "scrollUi", "scroll_ui" -> {
                val direction = call.argument<String>("direction") ?: "down"
                executor.execute {
                    runResult(result) {
                        withService { it.scrollUi(direction) }
                    }
                }
            }

            "globalAction", "performGlobalAction", "system_action", "global_action" -> {
                val action = call.argument<String>("action") ?: ""
                executor.execute {
                    runResult(result) {
                        withService { it.globalAction(action) }
                    }
                }
            }

            "isAccessibilityEnabled", "isServiceEnabled" -> {
                runResult(result) { AgentAccessibilityService.isServiceEnabled(this) }
            }

            "openAccessibilitySettings", "openServiceSettings" -> {
                runResult(result) {
                    AgentAccessibilityService.openServiceSettings(this)
                    true
                }
            }

            else -> result.notImplemented()
        }
    }

    // ---------------------------------------------------------------------
    // App / URL launching
    // ---------------------------------------------------------------------

    private fun openTarget(target: String): Map<String, Any?> {
        val trimmed = target.trim()
        if (trimmed.isEmpty()) {
            return error("Target is empty. Provide an app name, package name, or URL.")
        }

        // Explicit URL scheme (http/https or other schemes like mailto:, tel:, intent:).
        if (hasExplicitScheme(trimmed)) {
            return openUrl(normalizeUrl(trimmed))
        }

        // Exact installed package name takes precedence over domain-like heuristics.
        val installedApps = queryLaunchableApps()
        val exactPackageMatch = installedApps.firstOrNull {
            it.packageName.equals(trimmed, ignoreCase = true)
        }
        if (exactPackageMatch != null) {
            return launchInstalledApp(exactPackageMatch)
        }

        // URL/domain heuristic.
        if (looksLikeDomain(trimmed)) {
            return openUrl(normalizeUrl(trimmed))
        }

        // Otherwise treat as app name or package name.
        return openApp(trimmed, installedApps)
    }

    private fun openApp(appNameOrPackage: String, preloadedApps: List<AppEntry>? = null): Map<String, Any?> {
        val query = appNameOrPackage.trim()
        if (query.isEmpty()) {
            return error("App name or package name is empty.")
        }

        val apps = preloadedApps ?: queryLaunchableApps()
        val match = findBestAppMatch(query, apps)
            ?: return error(
                "No installed app matched '$query'. Use listInstalledApps to see available apps.",
            )

        return launchInstalledApp(match)
    }

    private fun openUrl(url: String): Map<String, Any?> {
        return try {
            val uri = Uri.parse(url)
            val intent = Intent(Intent.ACTION_VIEW, uri).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            mapOf("ok" to true, "message" to "Opened URL", "url" to url)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to open URL: $url", e)
            error("Failed to open URL '$url': ${e.message ?: "unknown error"}")
        }
    }

    private fun launchInstalledApp(app: AppEntry): Map<String, Any?> {
        return try {
            val launchIntent = packageManager.getLaunchIntentForPackage(app.packageName)
                ?: return error("App '${app.label}' (${app.packageName}) has no launchable activity.")
            launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(launchIntent)
            mapOf(
                "ok" to true,
                "message" to "Opened app '${app.label}'",
                "appName" to app.label,
                "packageName" to app.packageName,
            )
        } catch (e: Exception) {
            Log.e(TAG, "Failed to launch app: ${app.packageName}", e)
            error("Failed to launch '${app.label}': ${e.message ?: "unknown error"}")
        }
    }

    // ---------------------------------------------------------------------
    // Installed apps
    // ---------------------------------------------------------------------

    private fun listInstalledApps(): List<Map<String, String>> {
        return queryLaunchableApps()
            .sortedBy { it.label.lowercase(Locale.getDefault()) }
            .map { mapOf("appName" to it.label, "packageName" to it.packageName) }
    }

    private fun queryLaunchableApps(): List<AppEntry> {
        val intent = Intent(Intent.ACTION_MAIN).apply {
            addCategory(Intent.CATEGORY_LAUNCHER)
        }
        val resolved = packageManager.queryIntentActivities(intent, PackageManager.MATCH_ALL)
        return resolved.mapNotNull { info ->
            val packageName = info.activityInfo?.packageName ?: return@mapNotNull null
            val label = info.loadLabel(packageManager)?.toString()?.trim().orEmpty()
            if (label.isEmpty()) return@mapNotNull null
            AppEntry(label = label, packageName = packageName)
        }.distinctBy { it.packageName.lowercase(Locale.getDefault()) }
    }

    private fun findBestAppMatch(query: String, apps: List<AppEntry>): AppEntry? {
        val q = query.lowercase(Locale.getDefault()).trim()
        if (q.isEmpty()) return null

        // 1) Exact package name.
        apps.firstOrNull { it.packageName.lowercase(Locale.getDefault()) == q }?.let { return it }
        // 2) Exact label.
        apps.firstOrNull { it.label.lowercase(Locale.getDefault()) == q }?.let { return it }
        // 3) Label starts with query.
        apps.firstOrNull { it.label.lowercase(Locale.getDefault()).startsWith(q) }?.let { return it }
        // 4) Label contains query.
        apps.firstOrNull { it.label.lowercase(Locale.getDefault()).contains(q) }?.let { return it }
        // 5) Package contains query.
        apps.firstOrNull { it.packageName.lowercase(Locale.getDefault()).contains(q) }?.let { return it }
        // 6) Fuzzy token overlap.
        return apps.maxByOrNull { scoreAppMatch(q, it) }?.takeIf { scoreAppMatch(q, it) > 0 }
    }

    private fun scoreAppMatch(query: String, app: AppEntry): Int {
        val qTokens = query.split(Regex("[^a-z0-9]+")).filter { it.isNotBlank() }
        if (qTokens.isEmpty()) return 0
        val label = app.label.lowercase(Locale.getDefault())
        val pkg = app.packageName.lowercase(Locale.getDefault())
        var score = 0
        for (token in qTokens) {
            if (label.contains(token)) score += 2
            if (pkg.contains(token)) score += 1
        }
        return score
    }

    // ---------------------------------------------------------------------
    // URL / domain helpers
    // ---------------------------------------------------------------------

    private fun hasExplicitScheme(value: String): Boolean {
        return Regex("^[a-zA-Z][a-zA-Z0-9+.-]*://").containsMatchIn(value)
    }

    private fun looksLikeDomain(value: String): Boolean {
        if (value.contains(' ')) return false
        if (value.startsWith("www.", ignoreCase = true)) return true
        return DOMAIN_REGEX.matches(value)
    }

    private fun normalizeUrl(value: String): String {
        val trimmed = value.trim()
        if (hasExplicitScheme(trimmed)) return trimmed
        return "https://$trimmed"
    }

    // ---------------------------------------------------------------------
    // Accessibility service bridge
    // ---------------------------------------------------------------------

    private fun <T> withService(block: (AgentAccessibilityService) -> T): T {
        val service = AgentAccessibilityService.instance
            ?: throw ServiceUnavailableException(
                "Accessibility service is not enabled. Enable Apex Agent in Android Accessibility settings.",
            )
        return block(service)
    }

    // ---------------------------------------------------------------------
    // Result helpers
    // ---------------------------------------------------------------------

    private fun runResult(result: MethodChannel.Result, block: () -> Any?) {
        try {
            val value = block()
            postSuccess(result, value)
        } catch (e: ServiceUnavailableException) {
            postError(result, "ACCESSIBILITY_DISABLED", e.message, null)
        } catch (e: Exception) {
            Log.e(TAG, "MethodChannel error", e)
            postError(result, "DEVICE_CONTROL_ERROR", e.message ?: "Unknown error", null)
        }
    }

    private fun postSuccess(result: MethodChannel.Result, value: Any?) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            result.success(value)
        } else {
            mainHandler.post { result.success(value) }
        }
    }

    private fun postError(result: MethodChannel.Result, code: String, message: String?, details: Any?) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            result.error(code, message, details)
        } else {
            mainHandler.post { result.error(code, message, details) }
        }
    }

    private fun error(message: String): Map<String, Any?> = mapOf("ok" to false, "error" to message)

    private data class AppEntry(val label: String, val packageName: String)

    private class ServiceUnavailableException(message: String) : RuntimeException(message)
}
