package com.apex.agent

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Path
import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.util.Log
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Accessibility service that lets the Apex Agent read and interact with the
 * current UI across apps and websites.
 */
class AgentAccessibilityService : AccessibilityService() {

    companion object {
        private const val TAG = "ApexA11yService"

        @Volatile
        var instance: AgentAccessibilityService? = null
            private set

        /** Returns true when this accessibility service is enabled in system settings. */
        fun isServiceEnabled(context: Context): Boolean {
            val expectedComponent = ComponentName(context, AgentAccessibilityService::class.java)
            val expectedFlat = expectedComponent.flattenToString()
            val expectedShort = expectedComponent.flattenToShortString()
            val enabled = Settings.Secure.getInt(
                context.contentResolver,
                Settings.Secure.ACCESSIBILITY_ENABLED,
                0,
            ) == 1
            if (!enabled) return false

            val enabledServices = Settings.Secure.getString(
                context.contentResolver,
                Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
            ) ?: return false

            return enabledServices.split(':').any { entry ->
                entry.equals(expectedFlat, ignoreCase = true) ||
                    entry.equals(expectedShort, ignoreCase = true) ||
                    entry.equals(expectedComponent.className, ignoreCase = true)
            }
        }

        /** Alias for clarity when called from permission/setup flows. */
        fun isAccessibilityEnabled(context: Context): Boolean = isServiceEnabled(context)

        /** Opens Android Accessibility settings so the user can enable the service. */
        fun openServiceSettings(context: Context) {
            val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(intent)
        }

        /** Alias matching the permission-helper naming used by the Flutter bridge. */
        fun openAccessibilitySettings(context: Context) = openServiceSettings(context)
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
        Log.i(TAG, "Accessibility service connected")
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // No-op: UI state is captured on demand via captureUiState().
    }

    override fun onInterrupt() {
        Log.w(TAG, "Accessibility service interrupted")
    }

    override fun onUnbind(intent: Intent?): Boolean {
        instance = null
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    // ---------------------------------------------------------------------
    // Screen capture
    // ---------------------------------------------------------------------

    /**
     * Traverses the active window and returns a compact list of interactive/readable
     * elements. Each element includes index, text, contentDescription, viewIdResourceName,
     * className, isClickable, isEditable, isScrollable, bounds, and center coordinates.
     */
    fun captureUiState(): List<Map<String, Any?>> {
        val root = rootInActiveWindow ?: return emptyList()
        val elements = mutableListOf<Map<String, Any?>>()
        try {
            traverseNode(root, elements, depth = 0, maxDepth = 60)
        } finally {
            recycleSafe(root)
        }
        // Re-index sequentially after filtering.
        return elements.mapIndexed { index, item ->
            item.toMutableMap().apply { this["index"] = index }
        }
    }

    /**
     * Backward-compatible alias that returns the same screen state shape.
     */
    fun getScreenContent(): List<Map<String, Any?>> = captureUiState()

    private fun traverseNode(
        node: AccessibilityNodeInfo,
        out: MutableList<Map<String, Any?>>,
        depth: Int,
        maxDepth: Int,
    ) {
        if (depth > maxDepth) return

        val rect = Rect()
        node.getBoundsInScreen(rect)
        val text = node.text?.toString()?.trim().orEmpty()
        val desc = node.contentDescription?.toString()?.trim().orEmpty()
        val viewId = node.viewIdResourceName?.trim().orEmpty()
        val className = node.className?.toString().orEmpty()

        val isClickable = node.isClickable
        val isEditable = node.isEditable
        val isScrollable = node.isScrollable
        val isCheckable = node.isCheckable
        val isFocusable = node.isFocusable
        val isLongClickable = node.isLongClickable
        val hasText = text.isNotEmpty() || desc.isNotEmpty()

        val isMeaningful = hasText || isClickable || isEditable || isScrollable ||
            isCheckable || isFocusable || isLongClickable

        if (isMeaningful && rect.width() > 0 && rect.height() > 0) {
            out.add(
                linkedMapOf(
                    "index" to out.size,
                    "text" to text,
                    "contentDescription" to desc,
                    "viewIdResourceName" to viewId,
                    "className" to className,
                    "isClickable" to isClickable,
                    "isEditable" to isEditable,
                    "isScrollable" to isScrollable,
                    "isCheckable" to isCheckable,
                    "isFocusable" to isFocusable,
                    "isEnabled" to node.isEnabled,
                    "bounds" to mapOf(
                        "left" to rect.left,
                        "top" to rect.top,
                        "right" to rect.right,
                        "bottom" to rect.bottom,
                    ),
                    "centerX" to rect.centerX().toFloat(),
                    "centerY" to rect.centerY().toFloat(),
                ),
            )
        }

        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            try {
                traverseNode(child, out, depth + 1, maxDepth)
            } finally {
                recycleSafe(child)
            }
        }
    }

    // ---------------------------------------------------------------------
    // Tap / click
    // ---------------------------------------------------------------------

    /**
     * Taps a UI element by visible text/contentDescription/resourceId, or by explicit
     * screen coordinates. When a node is found but not clickable, or when it belongs to
     * a web/custom view where ACTION_CLICK is unreliable, a gesture tap is dispatched.
     */
    fun tapUi(textOrDesc: String?, x: Float?, y: Float?): Map<String, Any?> {
        val root = rootInActiveWindow ?: return errorResult("No active window is available")

        try {
            val query = textOrDesc?.trim().orEmpty()
            val targetNode = if (query.isNotEmpty()) findBestNode(root, query) else null

            if (targetNode != null) {
                try {
                    val rect = Rect()
                    targetNode.getBoundsInScreen(rect)
                    val cx = rect.centerX().toFloat()
                    val cy = rect.centerY().toFloat()
                    val inWebView = isInWebView(targetNode)

                    if (targetNode.isClickable && !inWebView) {
                        val clicked = targetNode.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                        if (clicked) {
                            return okResult("Clicked element via ACTION_CLICK", cx, cy)
                        }
                    }

                    // Fallback: tap by gesture at the node center.
                    val gestureOk = dispatchTap(cx, cy)
                    return if (gestureOk) {
                        okResult("Tapped element via gesture", cx, cy)
                    } else {
                        errorResult("Found element but failed to click/tap it")
                    }
                } finally {
                    recycleSafe(targetNode)
                }
            }

            if (x != null && y != null) {
                val gestureOk = dispatchTap(x, y)
                return if (gestureOk) {
                    okResult("Tapped coordinates via gesture", x, y)
                } else {
                    errorResult("Failed to tap coordinates ($x, $y)")
                }
            }

            return errorResult(
                if (query.isNotEmpty()) "No element found matching '$query'" else "No target text or coordinates provided",
            )
        } finally {
            recycleSafe(root)
        }
    }

    /** Alias for first-spec compatibility. */
    fun clickElement(targetText: String): Map<String, Any?> = tapUi(targetText, null, null)

    // ---------------------------------------------------------------------
    // Text input
    // ---------------------------------------------------------------------

    /**
     * Types text into a target editable node or the currently focused node.
     * Uses ACTION_SET_TEXT first, then clipboard + ACTION_PASTE fallback.
     */
    fun typeIntoUi(textOrDesc: String?, text: String, pressEnter: Boolean): Map<String, Any?> {
        val root = rootInActiveWindow ?: return errorResult("No active window is available")
        try {
            val query = textOrDesc?.trim().orEmpty()
            val targetNode = when {
                query.isNotEmpty() -> findEditableNode(root, query) ?: findBestNode(root, query)
                else -> findFocusedEditableNode(root) ?: root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
            }

            val node = targetNode ?: return errorResult(
                if (query.isNotEmpty()) "No editable element found matching '$query'" else "No focused input field found",
            )

            try {
                if (!node.isEditable) {
                    // Try to focus it and locate an editable descendant/parent.
                    node.performAction(AccessibilityNodeInfo.ACTION_FOCUS)
                }

                val setOk = setNodeText(node, text)
                if (!setOk) {
                    return errorResult("Failed to set text on the target field")
                }

                var enterOk = true
                if (pressEnter) {
                    enterOk = performEnter(node)
                }

                val msg = buildString {
                    append("Typed text into element")
                    if (pressEnter) append(if (enterOk) " and pressed enter" else " but failed to press enter")
                }
                return okResult(msg)
            } finally {
                recycleSafe(node)
            }
        } finally {
            recycleSafe(root)
        }
    }

    /** Alias for first-spec compatibility. */
    fun inputText(text: String): Map<String, Any?> = typeIntoUi(null, text, false)

    private fun setNodeText(node: AccessibilityNodeInfo, text: String): Boolean {
        val args = Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
        }
        val setOk = node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
        if (setOk) return true

        // Clipboard + paste fallback.
        return try {
            val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            clipboard.setPrimaryClip(ClipData.newPlainText("apex_agent_input", text))
            node.performAction(AccessibilityNodeInfo.ACTION_FOCUS)
            node.performAction(AccessibilityNodeInfo.ACTION_PASTE)
        } catch (e: Exception) {
            Log.e(TAG, "Clipboard paste fallback failed", e)
            false
        }
    }

    private fun performEnter(node: AccessibilityNodeInfo): Boolean {
        // API 30+: ACTION_IME_ENTER is the clean path.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                val imeEnter = AccessibilityNodeInfo.AccessibilityAction.ACTION_IME_ENTER
                if (node.actionList.contains(imeEnter) || node.isEditable) {
                    val ok = node.performAction(imeEnter.id)
                    if (ok) return true
                }
            } catch (e: Exception) {
                Log.w(TAG, "ACTION_IME_ENTER failed", e)
            }
        }

        // Fallback: try to find and click a submit/search button nearby.
        val root = rootInActiveWindow ?: return false
        try {
            val submit = findNodeByPredicate(root) { n ->
                val t = (n.text?.toString() ?: "").lowercase()
                val d = (n.contentDescription?.toString() ?: "").lowercase()
                val id = (n.viewIdResourceName ?: "").lowercase()
                n.isClickable && (
                    t in setOf("search", "go", "send", "submit", "done", "next") ||
                        d in setOf("search", "go", "send", "submit", "done", "next") ||
                        id.contains("search") || id.contains("send") || id.contains("submit") || id.contains("go")
                    )
            }
            if (submit != null) {
                try {
                    val clicked = submit.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                    if (clicked) return true
                    val rect = Rect()
                    submit.getBoundsInScreen(rect)
                    return dispatchTap(rect.centerX().toFloat(), rect.centerY().toFloat())
                } finally {
                    recycleSafe(submit)
                }
            }
        } finally {
            recycleSafe(root)
        }
        return false
    }

    // ---------------------------------------------------------------------
    // Scroll / swipe
    // ---------------------------------------------------------------------

    /**
     * Scrolls the screen in the requested direction by dispatching a gesture swipe.
     * Direction refers to content movement: "down" reveals lower content (swipe up).
     */
    fun scrollUi(direction: String): Map<String, Any?> {
        val dir = direction.trim().lowercase()
        val metrics = resources.displayMetrics
        val width = metrics.widthPixels.toFloat()
        val height = metrics.heightPixels.toFloat()
        val cx = width / 2f
        val cy = height / 2f
        val dx = width * 0.25f
        val dy = height * 0.25f

        val (startX, startY, endX, endY) = when (dir) {
            "down", "forward" -> listOf(cx, cy + dy, cx, cy - dy)       // swipe up
            "up", "backward" -> listOf(cx, cy - dy, cx, cy + dy)        // swipe down
            "left" -> listOf(cx + dx, cy, cx - dx, cy)                   // swipe left
            "right" -> listOf(cx - dx, cy, cx + dx, cy)                  // swipe right
            else -> return errorResult("Unsupported scroll direction '$direction'. Use up, down, left, or right.")
        }

        val ok = dispatchSwipe(startX, startY, endX, endY, durationMs = 350L)
        return if (ok) okResult("Scrolled $dir") else errorResult("Failed to scroll $dir")
    }

    // ---------------------------------------------------------------------
    // Global actions
    // ---------------------------------------------------------------------

    fun globalAction(action: String): Map<String, Any?> {
        val actionId = when (action.trim().lowercase()) {
            "back" -> GLOBAL_ACTION_BACK
            "home" -> GLOBAL_ACTION_HOME
            "recents", "recent", "overview" -> GLOBAL_ACTION_RECENTS
            "notifications", "notification" -> GLOBAL_ACTION_NOTIFICATIONS
            else -> return errorResult(
                "Unsupported global action '$action'. Use back, home, recents, or notifications.",
            )
        }
        val ok = performGlobalAction(actionId)
        return if (ok) okResult("Performed global action '$action'") else errorResult("Global action '$action' failed")
    }

    /** Alias for first-spec compatibility. */
    fun performGlobalActionAlias(action: String): Map<String, Any?> = globalAction(action)

    // ---------------------------------------------------------------------
    // Node search helpers
    // ---------------------------------------------------------------------

    private fun findBestNode(root: AccessibilityNodeInfo, query: String): AccessibilityNodeInfo? {
        val q = query.lowercase()
        // Pass 1: exact match on text/desc/resourceId.
        findNodeByPredicate(root) { node ->
            node.text?.toString()?.trim()?.lowercase() == q ||
                node.contentDescription?.toString()?.trim()?.lowercase() == q ||
                node.viewIdResourceName?.lowercase() == q ||
                node.viewIdResourceName?.substringAfterLast('/')?.lowercase() == q
        }?.let { return it }

        // Pass 2: contains match.
        return findNodeByPredicate(root) { node ->
            val t = node.text?.toString()?.trim()?.lowercase().orEmpty()
            val d = node.contentDescription?.toString()?.trim()?.lowercase().orEmpty()
            val id = node.viewIdResourceName?.lowercase().orEmpty()
            (t.isNotEmpty() && t.contains(q)) ||
                (d.isNotEmpty() && d.contains(q)) ||
                (id.isNotEmpty() && id.contains(q))
        }
    }

    private fun findEditableNode(root: AccessibilityNodeInfo, query: String): AccessibilityNodeInfo? {
        val q = query.lowercase()
        return findNodeByPredicate(root) { node ->
            if (!node.isEditable) return@findNodeByPredicate false
            val t = node.text?.toString()?.trim()?.lowercase().orEmpty()
            val d = node.contentDescription?.toString()?.trim()?.lowercase().orEmpty()
            val id = node.viewIdResourceName?.lowercase().orEmpty()
            t == q || d == q || id == q || id.substringAfterLast('/') == q ||
                (t.isNotEmpty() && t.contains(q)) ||
                (d.isNotEmpty() && d.contains(q)) ||
                (id.isNotEmpty() && id.contains(q))
        }
    }

    private fun findFocusedEditableNode(root: AccessibilityNodeInfo): AccessibilityNodeInfo? {
        return findNodeByPredicate(root) { it.isEditable && it.isFocused }
    }

    /**
     * Depth-first search that returns a fresh node reference for the match.
     * Caller is responsible for recycling the returned node.
     */
    private fun findNodeByPredicate(
        root: AccessibilityNodeInfo,
        predicate: (AccessibilityNodeInfo) -> Boolean,
    ): AccessibilityNodeInfo? {
        if (predicate(root)) {
            return AccessibilityNodeInfo.obtain(root)
        }
        for (i in 0 until root.childCount) {
            val child = root.getChild(i) ?: continue
            try {
                val found = findNodeByPredicate(child, predicate)
                if (found != null) return found
            } finally {
                recycleSafe(child)
            }
        }
        return null
    }

    private fun isInWebView(node: AccessibilityNodeInfo): Boolean {
        var current: AccessibilityNodeInfo? = AccessibilityNodeInfo.obtain(node)
        try {
            while (current != null) {
                val cls = current.className?.toString().orEmpty()
                if (cls.contains("WebView", ignoreCase = true) ||
                    cls.contains("webkit", ignoreCase = true)
                ) {
                    return true
                }
                val parent = current.parent
                if (current !== node) recycleSafe(current)
                current = parent
            }
            return false
        } finally {
            if (current != null && current !== node) {
                recycleSafe(current)
            }
        }
    }

    // ---------------------------------------------------------------------
    // Gesture helpers
    // ---------------------------------------------------------------------

    private fun dispatchTap(x: Float, y: Float, durationMs: Long = 100L): Boolean {
        val path = Path().apply { moveTo(x, y) }
        val stroke = GestureDescription.StrokeDescription(path, 0, durationMs)
        val gesture = GestureDescription.Builder().addStroke(stroke).build()
        return dispatchGestureSync(gesture)
    }

    private fun dispatchSwipe(
        startX: Float,
        startY: Float,
        endX: Float,
        endY: Float,
        durationMs: Long,
    ): Boolean {
        val path = Path().apply {
            moveTo(startX, startY)
            lineTo(endX, endY)
        }
        val stroke = GestureDescription.StrokeDescription(path, 0, durationMs)
        val gesture = GestureDescription.Builder().addStroke(stroke).build()
        return dispatchGestureSync(gesture)
    }

    private fun dispatchGestureSync(gesture: GestureDescription, timeoutMs: Long = 3000L): Boolean {
        val latch = CountDownLatch(1)
        val ok = AtomicBoolean(false)
        val dispatched = dispatchGesture(
            gesture,
            object : GestureResultCallback() {
                override fun onCompleted(gestureDescription: GestureDescription?) {
                    ok.set(true)
                    latch.countDown()
                }

                override fun onCancelled(gestureDescription: GestureDescription?) {
                    ok.set(false)
                    latch.countDown()
                }
            },
            null,
        )
        if (!dispatched) return false
        return try {
            latch.await(timeoutMs, TimeUnit.MILLISECONDS)
            ok.get()
        } catch (e: InterruptedException) {
            Thread.currentThread().interrupt()
            false
        }
    }

    // ---------------------------------------------------------------------
    // Utilities
    // ---------------------------------------------------------------------

    private fun recycleSafe(node: AccessibilityNodeInfo?) {
        try {
            @Suppress("DEPRECATION")
            node?.recycle()
        } catch (_: Exception) {
            // recycle() is a no-op on newer Android; ignore any runtime edge case.
        }
    }

    private fun okResult(message: String, x: Float? = null, y: Float? = null): Map<String, Any?> {
        return linkedMapOf<String, Any?>("ok" to true, "message" to message).apply {
            if (x != null) this["x"] = x
            if (y != null) this["y"] = y
        }
    }

    private fun errorResult(message: String): Map<String, Any?> {
        return mapOf("ok" to false, "error" to message)
    }
}
