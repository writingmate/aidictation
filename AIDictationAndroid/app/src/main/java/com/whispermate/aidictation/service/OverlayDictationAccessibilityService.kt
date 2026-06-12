package com.whispermate.aidictation.service

import android.Manifest
import android.accessibilityservice.AccessibilityService
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowInsets
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.core.content.ContextCompat
import com.whispermate.aidictation.R
import com.whispermate.aidictation.data.preferences.AppPreferences
import com.whispermate.aidictation.data.preferences.OverlayBubblePreferences
import com.whispermate.aidictation.data.remote.CommandClient
import com.whispermate.aidictation.data.remote.TranscriptionClient
import com.whispermate.aidictation.data.repository.SubscriptionRepository
import com.whispermate.aidictation.domain.model.Command
import com.whispermate.aidictation.ui.views.OverlayMicButtonView
import com.whispermate.aidictation.util.AudioRecorder
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

/**
 * Accessibility-based dictation service that shows a draggable bubble overlay when an editable
 * text field is focused, while keeping the user's regular keyboard (e.g. Gboard).
 */
@AndroidEntryPoint
class OverlayDictationAccessibilityService : AccessibilityService() {

    companion object {
        const val ACTION_START_DICTATION = "com.aidictation.app.action.START_DICTATION"
        private const val TAG = "OverlayDictationSvc"
        private const val MIN_RECORDING_MS = 500L
        private const val BUBBLE_SIZE_DP = 55
        private const val BUBBLE_MARGIN_DP = 20
        private const val BUBBLE_SNOOZE_MS = 10 * 60 * 1000L
        private const val BUBBLE_HIDE_DEBOUNCE_MS = 250L
        private const val INSERT_RESOLVE_ATTEMPTS = 3
        private const val INSERT_RESOLVE_RETRY_MS = 250L
        private const val BUBBLE_DISMISS_DROP_HEIGHT_DP = 180
        private const val COMMAND_ACTION_HORIZONTAL_MARGIN_DP = 8
        private const val COMMAND_ACTION_GAP_DP = 8
        private const val COMMAND_ACTION_ESTIMATED_WIDTH_DP = 220
        private const val COMMAND_ACTION_ESTIMATED_HEIGHT_DP = 40
        private const val DISMISS_ACTION_HEIGHT_DP = 104
        private const val COMMAND_CLEANUP_ID = "cleanup"
        private const val COMMAND_REWRITE_ID = "rewrite"

        private val TRACKED_EVENT_TYPES = setOf(
            AccessibilityEvent.TYPE_VIEW_FOCUSED,
            AccessibilityEvent.TYPE_VIEW_CLICKED,
            AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED,
            AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED,
            AccessibilityEvent.TYPE_WINDOWS_CHANGED,
            AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED,
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED
        )
    }

    private enum class RecordingState {
        Idle,
        Recording,
        Processing
    }

    private enum class RecordingMode {
        Dictation,
        RewriteInstruction
    }

    private enum class CommandAction {
        FixGrammar,
        RewriteWithAi
    }

    private enum class BubbleDismissTarget {
        Snooze,
        Hide
    }

    private data class EditableTextSnapshot(
        val text: String,
        val selectionStart: Int,
        val selectionEnd: Int
    )

    private data class SelectionCommandTarget(
        val selectedText: String,
        val contextBefore: String
    )

    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    @Inject lateinit var appPreferences: AppPreferences
    @Inject lateinit var transcriptionRepository: com.whispermate.aidictation.data.repository.TranscriptionRepository
    @Inject lateinit var subscriptionRepository: SubscriptionRepository
    private lateinit var windowManager: WindowManager

    private var bubbleView: OverlayMicButtonView? = null
    private var bubbleParams: WindowManager.LayoutParams? = null
    private var isBubbleAttached = false
    private var bubbleShouldBeVisible = false
    private var commandActionsView: LinearLayout? = null
    private var commandActionsParams: WindowManager.LayoutParams? = null
    private var isCommandActionsAttached = false
    private var dismissActionsView: LinearLayout? = null
    private var dismissActionsParams: WindowManager.LayoutParams? = null
    private var isDismissActionsAttached = false
    private var dismissSnoozeZone: TextView? = null
    private var dismissHideZone: TextView? = null

    private var recordingState: RecordingState = RecordingState.Idle
    private var recordingMode: RecordingMode = RecordingMode.Dictation
    private var audioRecorder: AudioRecorder? = null
    private var vadJob: Job? = null
    private var autoStopOnSilenceEnabled = false
    private var bubbleAnimationJob: Job? = null
    private var pendingHideJob: Job? = null
    private var stickyEditableFocusArmed = false
    private var dictationTargetNode: AccessibilityNodeInfo? = null
    private var activeCommandAction: CommandAction? = null
    private var pendingRewriteTarget: SelectionCommandTarget? = null
    private var fixGrammarButton: TextView? = null
    private var rewriteButton: TextView? = null

    private var bubbleIdleColor: Int = OverlayBubblePreferences.DEFAULT_COLOR
    private var bubbleDictationActiveColor: Int = OverlayBubblePreferences.DEFAULT_COLOR
    private var bubbleRewriteActiveColor: Int = OverlayBubblePreferences.DEFAULT_COLOR
    private var bubbleFixActiveColor: Int = OverlayBubblePreferences.DEFAULT_COLOR
    private var commandChipIdleTextColor: Int = Color.WHITE
    private var commandChipIdleBackgroundColor: Int = 0x24FFFFFF
    private var commandChipFixTextColor: Int = Color.WHITE
    private var commandChipFixBackgroundColor: Int = 0xFFFF6300.toInt()
    private var commandChipRewriteTextColor: Int = Color.WHITE
    private var commandChipRewriteBackgroundColor: Int = 0xFFFF6300.toInt()

    private var lastFocusedPackage: String? = null
    private var lastDictatedText: String = ""

    private val bubblePrefs by lazy { OverlayBubblePreferences.prefs(this) }
    private var bubblePrefsListener: SharedPreferences.OnSharedPreferenceChangeListener? = null

    override fun onServiceConnected() {
        super.onServiceConnected()
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
        registerBubblePreferenceListener()

        serviceScope.launch {
            appPreferences.autoStopOnSilenceEnabled.collectLatest { enabled ->
                autoStopOnSilenceEnabled = enabled
            }
        }

        prewarmOnDeviceTranscriber()
        refreshOverlayVisibility(null)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_START_DICTATION) {
            // We add a delay to ensure that the ShortcutActivity (if any) has 
            // finished and focus has returned to the previously active app.
            serviceScope.launch {
                delay(300)
                onBubbleTapped()
            }
        }
        return START_STICKY
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        event ?: return
        if (event.eventType !in TRACKED_EVENT_TYPES) return

        lastFocusedPackage = event.packageName?.toString()
        refreshOverlayVisibility(event.source)
    }

    override fun onInterrupt() {
        stopRecording(discard = true)
        dictationTargetNode = null
        hideBubble()
        hideCommandActions()
        hideDismissActions()
        stopBubbleAnimation()
    }

    private fun registerBubblePreferenceListener() {
        if (bubblePrefsListener != null) return

        bubblePrefsListener = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
            if (key == OverlayBubblePreferences.COLOR_KEY) {
                serviceScope.launch {
                    refreshBubbleBrandColor()
                    updateBubbleUi()
                }
            }
        }
        bubblePrefs.registerOnSharedPreferenceChangeListener(bubblePrefsListener)
    }

    private fun unregisterBubblePreferenceListener() {
        val listener = bubblePrefsListener ?: return
        bubblePrefs.unregisterOnSharedPreferenceChangeListener(listener)
        bubblePrefsListener = null
    }

    private fun refreshBubbleBrandColor() {
        val color = OverlayBubblePreferences.getResolvedBubbleColor(this)
        bubbleIdleColor = color
        bubbleDictationActiveColor = color
        bubbleRewriteActiveColor = color
        bubbleFixActiveColor = color
    }

    override fun onDestroy() {
        super.onDestroy()
        stopRecording(discard = true)
        dictationTargetNode = null
        hideBubble()
        hideCommandActions()
        hideDismissActions()
        stopBubbleAnimation()
        unregisterBubblePreferenceListener()
    }

    private fun refreshOverlayVisibility(source: AccessibilityNodeInfo?) {
        if (shouldShowBubble(source)) {
            bubbleShouldBeVisible = true
            showBubble()
            updateCommandActionsVisibility(source)
            return
        }

        scheduleDeferredHide()
    }

    /**
     * Hides the bubble only when the hide condition still holds after a debounce window.
     * Focus and IME visibility reports flap for single events during keyboard animations
     * and in WebView/Compose fields; hiding immediately would remove and re-add the
     * overlay window between consecutive events, which shows up as flicker.
     */
    private fun scheduleDeferredHide() {
        if (pendingHideJob?.isActive == true) return

        if (!isBubbleAttached && !isCommandActionsAttached && recordingState != RecordingState.Recording) {
            bubbleShouldBeVisible = false
            return
        }

        pendingHideJob = serviceScope.launch {
            delay(BUBBLE_HIDE_DEBOUNCE_MS)
            if (shouldShowBubble(null)) return@launch

            bubbleShouldBeVisible = false
            if (recordingState == RecordingState.Recording) {
                stopRecording(discard = true)
            }
            hideBubble()
            hideCommandActions()
        }
    }

    private fun cancelPendingHide() {
        pendingHideJob?.cancel()
        pendingHideJob = null
    }

    private fun shouldShowBubble(source: AccessibilityNodeInfo?): Boolean {
        if (!isKeyboardVisible()) return false
        if (!hasEditableDictationTarget(source)) return false
        if (isBubbleSuppressed()) return false
        return true
    }

    /**
     * Editable-focus check with a sticky fallback. WebView-backed fields (LinkedIn,
     * Chrome, in-app browsers) drop FOCUS_INPUT for seconds while their virtual
     * accessibility tree rebuilds, so a failed lookup is not evidence the field was
     * left. Once an eligible field has been seen with the keyboard up, the target is
     * considered present until the keyboard closes or a password field takes focus.
     */
    private fun hasEditableDictationTarget(source: AccessibilityNodeInfo?): Boolean {
        if (resolveFocusedEditableNode(source) != null) {
            stickyEditableFocusArmed = true
            return true
        }
        if (isPasswordFieldFocused(source)) {
            stickyEditableFocusArmed = false
            return false
        }
        return stickyEditableFocusArmed
    }

    private fun isPasswordFieldFocused(source: AccessibilityNodeInfo?): Boolean {
        val focused = source?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
            ?: rootInActiveWindow?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
        return focused?.isPassword == true
    }

    private fun prewarmOnDeviceTranscriber() {
        serviceScope.launch(Dispatchers.Default) {
            transcriptionRepository.prewarmOnDeviceIfEnabled()
                .onFailure { error ->
                    Log.w(TAG, "Unable to prewarm on-device transcription", error)
                }
        }
    }

    private fun isKeyboardVisible(): Boolean {
        if (inputMethodBounds() != null) return true
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            bubbleView?.rootWindowInsets?.let { insets ->
                if (insets.isVisible(WindowInsets.Type.ime())) return true
            }
        }
        return false
    }

    private fun keyboardTop(): Int {
        return inputMethodBounds()?.top ?: resources.displayMetrics.heightPixels
    }

    private fun dismissAreaTop(): Int {
        return (keyboardTop() - dp(DISMISS_ACTION_HEIGHT_DP)).coerceAtLeast(0)
    }

    private fun inputMethodBounds(): Rect? {
        return windows
            .asSequence()
            .filter { window -> window.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD }
            .mapNotNull { window ->
                Rect().also { window.getBoundsInScreen(it) }
                    .takeIf { bounds -> isVisibleInputMethodWindow(window, bounds) }
            }
            .minByOrNull { bounds -> bounds.top }
    }

    private fun isVisibleInputMethodWindow(window: AccessibilityWindowInfo, bounds: Rect): Boolean {
        if (bounds.height() <= 0 || bounds.width() <= 0) return false
        if (window.isActive || window.isFocused) return true

        val root = window.root ?: return false
        @Suppress("DEPRECATION")
        root.recycle()
        return true
    }

    private fun isBubbleSuppressed(): Boolean {
        if (bubblePrefs.getBoolean(OverlayBubblePreferences.HIDDEN_KEY, false)) return true

        val snoozeUntil = bubblePrefs.getLong(OverlayBubblePreferences.SNOOZE_UNTIL_MS_KEY, 0L)
        if (snoozeUntil <= 0L) return false
        if (System.currentTimeMillis() < snoozeUntil) return true

        bubblePrefs.edit().remove(OverlayBubblePreferences.SNOOZE_UNTIL_MS_KEY).apply()
        return false
    }

    private fun hideBubblePermanently() {
        bubblePrefs.edit()
            .putBoolean(OverlayBubblePreferences.HIDDEN_KEY, true)
            .remove(OverlayBubblePreferences.SNOOZE_UNTIL_MS_KEY)
            .apply()
        suppressBubbleNow(R.string.overlay_hidden_permanently)
    }

    private fun snoozeBubble() {
        bubblePrefs.edit()
            .putLong(OverlayBubblePreferences.SNOOZE_UNTIL_MS_KEY, System.currentTimeMillis() + BUBBLE_SNOOZE_MS)
            .apply()
        suppressBubbleNow(R.string.overlay_snoozed)
    }

    private fun suppressBubbleNow(messageRes: Int) {
        hideDismissActions()
        if (recordingState == RecordingState.Recording) {
            stopRecording(discard = true)
        }
        hideBubble()
        hideCommandActions()
        Toast.makeText(this, messageRes, Toast.LENGTH_SHORT).show()
    }

    private fun resolveFocusedEditableNode(source: AccessibilityNodeInfo?): AccessibilityNodeInfo? {
        if (source != null && isEligibleEditableNode(source)) {
            return source
        }

        val sourceFocused = source?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
        if (sourceFocused != null && isEligibleEditableNode(sourceFocused)) {
            return sourceFocused
        }
        @Suppress("DEPRECATION")
        sourceFocused?.recycle()

        // Search across all windows. On foldables (Flip/Fold), the target app
        // might be in a different window type when closed/on cover screen.
        val windows = windows
        for (window in windows) {
            val root = window.root ?: continue
            val focused = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
            if (focused != null && isEligibleEditableNode(focused)) {
                @Suppress("DEPRECATION")
                root.recycle()
                return focused
            }
            @Suppress("DEPRECATION")
            root.recycle()
            @Suppress("DEPRECATION")
            focused?.recycle()
        }

        val focused = rootInActiveWindow?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
        if (focused != null && isEligibleEditableNode(focused)) {
            return focused
        }

        return null
    }

    private fun isEligibleEditableNode(node: AccessibilityNodeInfo): Boolean {
        if (!node.isEditable) return false
        // isVisibleToUser and isFocused can be unreliable on foldable cover screens
        // or when an overlay/routine is starting up.
        if (!node.isEnabled) return false
        if (node.isPassword) return false
        // A field showing its hint with no caret is not an active edit target. Chrome's
        // omnibox keeps reporting input focus in this state while the user is actually
        // editing web page content.
        if (node.isShowingHintText && node.textSelectionStart == -1 && node.textSelectionEnd == -1) {
            return false
        }
        return true
    }

    private fun refreshNode(node: AccessibilityNodeInfo): Boolean {
        return try {
            node.refresh()
        } catch (e: Exception) {
            false
        }
    }

    private fun currentDictationNode(): AccessibilityNodeInfo? {
        return dictationTargetNode?.takeIf { refreshNode(it) && isEligibleEditableNode(it) }
            ?: resolveFocusedEditableNode(null)
    }

    /**
     * Returns the node dictation output should be written into. Prefers the field
     * captured when recording started: WebView trees (Chrome) rebuild while
     * transcription is in flight, and re-resolving input focus afterwards can land on
     * an unrelated editable such as the browser omnibox. Falls back to re-resolution
     * with brief retries, rejecting candidates that do not match the original field.
     */
    private suspend fun acquireInsertTarget(): AccessibilityNodeInfo? {
        val preferred = dictationTargetNode
        if (preferred != null && refreshNode(preferred) && isEligibleEditableNode(preferred)) {
            return preferred
        }
        repeat(INSERT_RESOLVE_ATTEMPTS) { attempt ->
            val candidate = resolveFocusedEditableNode(null)
            if (candidate != null && isCompatibleInsertTarget(preferred, candidate)) {
                return candidate
            }
            if (attempt < INSERT_RESOLVE_ATTEMPTS - 1) delay(INSERT_RESOLVE_RETRY_MS)
        }
        return null
    }

    private fun isCompatibleInsertTarget(
        original: AccessibilityNodeInfo?,
        candidate: AccessibilityNodeInfo
    ): Boolean {
        original ?: return true
        return original.packageName?.toString() == candidate.packageName?.toString() &&
            original.viewIdResourceName == candidate.viewIdResourceName
    }
    private fun showBubble() {
        cancelPendingHide()
        ensureBubbleCreated()
        val bubble = bubbleView ?: return
        val params = bubbleParams ?: return

        bubbleShouldBeVisible = true
        if (isBubbleAttached) {
            bubble.alpha = 1f
            updateCommandActionsPosition()
            updateBubbleUi()
            return
        }

        try {
            bubble.alpha = 1f
            windowManager.addView(bubble, params)
            isBubbleAttached = true
            updateCommandActionsPosition()
            updateBubbleUi()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to attach bubble overlay", e)
        }
    }

    private fun hideBubble() {
        cancelPendingHide()
        stickyEditableFocusArmed = false
        bubbleShouldBeVisible = false
        if (!isBubbleAttached) return

        removeBubbleView()
    }

    private fun removeBubbleView() {
        if (!isBubbleAttached) return
        val bubble = bubbleView ?: return
        try {
            windowManager.removeView(bubble)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to remove bubble overlay", e)
        } finally {
            isBubbleAttached = false
            bubble.alpha = 1f
            hideCommandActions()
            stopBubbleAnimation()
        }
    }

    private fun ensureBubbleCreated() {
        if (bubbleView != null) return

        refreshBubbleBrandColor()

        bubbleView = OverlayMicButtonView(this).apply {
            elevation = dp(8).toFloat()
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            isHapticFeedbackEnabled = true
            setColors(bubbleIdleColor, resolveBubbleActiveColor())
            setState(OverlayMicButtonView.State.Idle)
        }

        val size = dp(BUBBLE_SIZE_DP)
        val startX = bubblePrefs.getInt(OverlayBubblePreferences.X_KEY, defaultBubbleX())
        val startY = bubblePrefs.getInt(OverlayBubblePreferences.Y_KEY, defaultBubbleY())

        bubbleParams = WindowManager.LayoutParams(
            size,
            size,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = startX
            y = startY
            windowAnimations = 0
        }

        attachDragAndTapHandler()
    }

    private fun ensureCommandActionsCreated() {
        if (commandActionsView != null) return

        val horizontalPadding = dp(12)
        val verticalPadding = dp(8)
        val buttonGap = dp(COMMAND_ACTION_GAP_DP)
        val surfaceColor = resolveThemeColor(
            android.R.attr.colorBackgroundFloating,
            resolveThemeColor(android.R.attr.colorBackground, 0xFF1A1A1A.toInt())
        )
        val onSurfaceColor = resolveThemeColor(android.R.attr.textColorPrimary, Color.WHITE)
        val containerColor = withAlpha(surfaceColor, 0.92f)
        commandChipIdleTextColor = onSurfaceColor
        commandChipIdleBackgroundColor = withAlpha(onSurfaceColor, 0.14f)

        val fixAccent = resolveThemeColor(
            android.R.attr.colorSecondary,
            0xFFFF6300.toInt()
        )
        val rewriteAccent = resolveThemeColor(
            android.R.attr.colorAccent,
            0xFFFF6300.toInt()
        )
        commandChipFixBackgroundColor = withAlpha(fixAccent, 0.9f)
        commandChipFixTextColor = preferredOnColor(commandChipFixBackgroundColor)
        commandChipRewriteBackgroundColor = withAlpha(rewriteAccent, 0.9f)
        commandChipRewriteTextColor = preferredOnColor(commandChipRewriteBackgroundColor)
        bubbleFixActiveColor = bubbleDictationActiveColor
        bubbleRewriteActiveColor = bubbleDictationActiveColor

        fixGrammarButton = createCommandActionButton(
            label = getString(R.string.overlay_action_fix_grammar),
            textColor = commandChipIdleTextColor,
            backgroundColor = commandChipIdleBackgroundColor,
            onClick = { executeSelectionCommand(COMMAND_CLEANUP_ID, CommandAction.FixGrammar) }
        )
        rewriteButton = createCommandActionButton(
            label = getString(R.string.overlay_action_rewrite_ai),
            textColor = commandChipIdleTextColor,
            backgroundColor = commandChipIdleBackgroundColor,
            onClick = { startRewriteInstructionRecording() }
        )

        commandActionsView = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(horizontalPadding, verticalPadding, horizontalPadding, verticalPadding)
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
            elevation = dp(6).toFloat()
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dp(22).toFloat()
                setColor(containerColor)
            }

            addView(fixGrammarButton)
            addView(rewriteButton, LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply {
                leftMargin = buttonGap
            })
        }

        commandActionsParams = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = defaultBubbleX()
            y = defaultBubbleY()
            windowAnimations = 0
        }

        updateCommandActionButtons()
        updateBubbleUi()
    }

    private fun createCommandActionButton(
        label: String,
        textColor: Int,
        backgroundColor: Int,
        onClick: () -> Unit
    ): TextView {
        return TextView(this).apply {
            text = label
            setTextColor(textColor)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            isAllCaps = false
            minHeight = dp(32)
            gravity = Gravity.CENTER
            setPadding(dp(12), dp(6), dp(12), dp(6))
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dp(16).toFloat()
                setColor(backgroundColor)
            }
            setOnClickListener { onClick() }
        }
    }

    private fun updateCommandActionsVisibility(source: AccessibilityNodeInfo?) {
        if (!isBubbleAttached) {
            hideCommandActions()
            return
        }

        if (recordingState != RecordingState.Idle) {
            if (activeCommandAction != null) {
                showCommandActions()
            } else {
                hideCommandActions()
            }
            updateCommandActionButtons()
            return
        }

        val node = resolveFocusedEditableNode(source)
        if (node == null) {
            hideCommandActions()
            return
        }

        val snapshot = captureEditableTextSnapshot(node)

        val hasSelection = snapshot.selectionEnd > snapshot.selectionStart && snapshot.text.isNotBlank()
        if (hasSelection) {
            showCommandActions()
        } else {
            hideCommandActions()
        }
        updateCommandActionButtons()
    }

    private fun showCommandActions() {
        ensureCommandActionsCreated()
        val actions = commandActionsView ?: return
        val params = commandActionsParams ?: return
        if (!isBubbleAttached) return

        if (isCommandActionsAttached) {
            actions.alpha = 1f
            updateCommandActionsPosition()
            updateCommandActionButtons()
            return
        }

        try {
            actions.alpha = 1f
            windowManager.addView(actions, params)
            isCommandActionsAttached = true
            updateCommandActionsPosition()
            updateCommandActionButtons()
        } catch (e: Exception) {
            Log.w(TAG, "Failed to attach command actions overlay", e)
        }
    }

    private fun hideCommandActions() {
        if (!isCommandActionsAttached) return

        removeCommandActionsView()
    }

    private fun removeCommandActionsView() {
        if (!isCommandActionsAttached) return
        val actions = commandActionsView ?: return
        try {
            windowManager.removeView(actions)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to remove command actions overlay", e)
        } finally {
            isCommandActionsAttached = false
            actions.alpha = 1f
        }
    }

    private fun ensureDismissActionsCreated() {
        if (dismissActionsView != null) return

        val surfaceColor = resolveThemeColor(
            android.R.attr.colorBackgroundFloating,
            resolveThemeColor(android.R.attr.colorBackground, 0xFF1A1A1A.toInt())
        )
        val onSurfaceColor = resolveThemeColor(android.R.attr.textColorPrimary, Color.WHITE)
        val idleZoneColor = withAlpha(surfaceColor, 0.88f)

        dismissSnoozeZone = createDismissDropZone(
            label = getString(R.string.overlay_dismiss_snooze),
            textColor = onSurfaceColor,
            backgroundColor = idleZoneColor
        )
        dismissHideZone = createDismissDropZone(
            label = getString(R.string.overlay_dismiss_hide),
            textColor = onSurfaceColor,
            backgroundColor = idleZoneColor
        )

        dismissActionsView = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
            elevation = dp(8).toFloat()

            addView(dismissSnoozeZone, LinearLayout.LayoutParams(
                0,
                LinearLayout.LayoutParams.MATCH_PARENT,
                1f
            ))
            addView(dismissHideZone, LinearLayout.LayoutParams(
                0,
                LinearLayout.LayoutParams.MATCH_PARENT,
                1f
            ))
        }

        dismissActionsParams = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            dp(DISMISS_ACTION_HEIGHT_DP),
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.BOTTOM or Gravity.START
            x = 0
            y = 0
            windowAnimations = 0
        }
    }

    private fun createDismissDropZone(
        label: String,
        textColor: Int,
        backgroundColor: Int
    ): TextView {
        return TextView(this).apply {
            text = label
            setTextColor(textColor)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            gravity = Gravity.CENTER
            isAllCaps = false
            setPadding(dp(12), dp(16), dp(12), dp(16))
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = 0f
                setColor(backgroundColor)
            }
        }
    }

    private fun showDismissActions() {
        ensureDismissActionsCreated()
        val actions = dismissActionsView ?: return
        val params = dismissActionsParams ?: return

        hideCommandActions()
        updateDismissActionsPosition()
        if (isDismissActionsAttached) return

        try {
            actions.alpha = 1f
            windowManager.addView(actions, params)
            isDismissActionsAttached = true
            updateDismissActionsPosition()
        } catch (e: Exception) {
            Log.w(TAG, "Failed to attach dismiss actions overlay", e)
        }
    }

    private fun hideDismissActions() {
        if (!isDismissActionsAttached) return
        val actions = dismissActionsView ?: return
        try {
            windowManager.removeView(actions)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to remove dismiss actions overlay", e)
        } finally {
            isDismissActionsAttached = false
            actions.alpha = 1f
        }
    }

    private fun updateDismissActionsPosition() {
        val params = dismissActionsParams ?: return
        val actions = dismissActionsView ?: return
        params.x = 0
        params.y = 0
        if (!isDismissActionsAttached) return
        try {
            windowManager.updateViewLayout(actions, params)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to update dismiss actions position", e)
        }
    }

    private fun updateDismissDropTarget(target: BubbleDismissTarget?) {
        val surfaceColor = resolveThemeColor(
            android.R.attr.colorBackgroundFloating,
            resolveThemeColor(android.R.attr.colorBackground, 0xFF1A1A1A.toInt())
        )
        val onSurfaceColor = resolveThemeColor(android.R.attr.textColorPrimary, Color.WHITE)
        val idleZoneColor = withAlpha(surfaceColor, 0.88f)

        setDismissZoneState(
            view = dismissSnoozeZone,
            selected = target == BubbleDismissTarget.Snooze,
            selectedColor = bubbleRewriteActiveColor,
            idleColor = idleZoneColor,
            idleTextColor = onSurfaceColor
        )
        setDismissZoneState(
            view = dismissHideZone,
            selected = target == BubbleDismissTarget.Hide,
            selectedColor = bubbleDictationActiveColor,
            idleColor = idleZoneColor,
            idleTextColor = onSurfaceColor
        )
    }

    private fun setDismissZoneState(
        view: TextView?,
        selected: Boolean,
        selectedColor: Int,
        idleColor: Int,
        idleTextColor: Int
    ) {
        view ?: return
        val backgroundColor = if (selected) selectedColor else idleColor
        view.setTextColor(if (selected) preferredOnColor(selectedColor) else idleTextColor)
        view.background = GradientDrawable().apply {
            shape = GradientDrawable.RECTANGLE
            setColor(backgroundColor)
        }
    }

    private fun updateCommandActionsPosition() {
        if (!isCommandActionsAttached) return
        val params = commandActionsParams ?: return
        val actions = commandActionsView ?: return
        val bubble = bubbleParams ?: return

        val margin = dp(COMMAND_ACTION_HORIZONTAL_MARGIN_DP)
        val estimatedWidth = actions.width.takeIf { it > 0 } ?: dp(COMMAND_ACTION_ESTIMATED_WIDTH_DP)
        val estimatedHeight = actions.height.takeIf { it > 0 } ?: dp(COMMAND_ACTION_ESTIMATED_HEIGHT_DP)
        val screenWidth = resources.displayMetrics.widthPixels
        val screenHeight = resources.displayMetrics.heightPixels
        val bubbleWidth = currentBubbleWidthPx()
        val bubbleHeight = currentBubbleHeightPx()

        val leftX = bubble.x - estimatedWidth - margin
        val rightX = bubble.x + bubbleWidth + margin
        val maxX = (screenWidth - estimatedWidth - margin).coerceAtLeast(margin)
        val targetX = if (leftX >= margin) leftX else rightX

        val centeredY = bubble.y + (bubbleHeight - estimatedHeight) / 2
        val maxY = (screenHeight - estimatedHeight - margin).coerceAtLeast(margin)

        params.x = targetX.coerceIn(margin, maxX)
        params.y = centeredY.coerceIn(margin, maxY)

        try {
            windowManager.updateViewLayout(actions, params)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to update command actions position", e)
        }
    }

    private fun attachDragAndTapHandler() {
        val bubble = bubbleView ?: return
        val params = bubbleParams ?: return

        val touchSlop = ViewConfiguration.get(this).scaledTouchSlop
        var downRawX = 0f
        var downRawY = 0f
        var downX = 0
        var downY = 0
        var dragging = false

        bubble.setOnTouchListener { _, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downRawX = event.rawX
                    downRawY = event.rawY
                    downX = params.x
                    downY = params.y
                    dragging = false
                    true
                }

                MotionEvent.ACTION_MOVE -> {
                    val deltaX = (event.rawX - downRawX).toInt()
                    val deltaY = (event.rawY - downRawY).toInt()

                    if (!dragging && (kotlin.math.abs(deltaX) > touchSlop || kotlin.math.abs(deltaY) > touchSlop)) {
                        dragging = true
                        performDragHaptic(start = true)
                    }

                    if (dragging) {
                        params.x = downX + deltaX
                        params.y = downY + deltaY
                        updateBubblePosition()
                        if (shouldRevealDismissZones(params)) {
                            showDismissActions()
                            updateDismissDropTarget(resolveDismissTarget(params))
                        } else {
                            hideDismissActions()
                        }
                    }
                    true
                }

                MotionEvent.ACTION_UP -> {
                    if (dragging) {
                        performDragHaptic(start = false)
                        when (resolveDismissTarget(params)) {
                            BubbleDismissTarget.Snooze -> snoozeBubble()
                            BubbleDismissTarget.Hide -> hideBubblePermanently()
                            null -> {
                                hideDismissActions()
                                snapBubbleToNearestHorizontalEdge(params.x, params.y)
                            }
                        }
                    } else {
                        hideDismissActions()
                        val circularBubble = bubble as? OverlayMicButtonView
                        when {
                            circularBubble?.isCancelHit(event.x, event.y) == true -> {
                                performClickHaptic()
                                stopRecording(discard = true)
                            }
                            circularBubble?.isAcceptHit(event.x, event.y) == true -> {
                                performClickHaptic()
                                stopRecording(discard = false)
                            }
                            recordingState == RecordingState.Recording -> Unit
                            else -> {
                                performClickHaptic()
                                onBubbleTapped()
                            }
                        }
                    }
                    true
                }

                MotionEvent.ACTION_CANCEL -> {
                    if (dragging) {
                        performDragHaptic(start = false)
                    }
                    hideDismissActions()
                    true
                }

                else -> false
            }
        }
    }

    private fun performDragHaptic(start: Boolean) {
        val effect = if (start) {
            HapticFeedbackConstants.LONG_PRESS
        } else {
            HapticFeedbackConstants.CONTEXT_CLICK
        }
        bubbleView?.performHapticFeedback(effect)
    }

    private fun performClickHaptic() {
        bubbleView?.performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
    }

    private fun onBubbleTapped() {
        hideDismissActions()
        when (recordingState) {
            RecordingState.Idle -> startRecording(mode = RecordingMode.Dictation)
            RecordingState.Recording -> stopRecording(discard = false)
            RecordingState.Processing -> Unit
        }
    }

    private fun snapBubbleToNearestHorizontalEdge(currentX: Int, currentY: Int) {
        val screenWidth = resources.displayMetrics.widthPixels
        val margin = dp(BUBBLE_MARGIN_DP)
        val bubbleWidth = currentBubbleWidthPx()
        val bubbleHeight = currentBubbleHeightPx()
        val leftX = margin
        val rightX = (screenWidth - bubbleWidth - margin).coerceAtLeast(leftX)
        val bubbleCenterX = currentX + bubbleWidth / 2
        val targetX = if (bubbleCenterX < screenWidth / 2) leftX else rightX
        val maxY = (keyboardTop() - bubbleHeight - margin).coerceAtLeast(margin)
        val targetY = currentY.coerceIn(margin, maxY)

        moveBubbleTo(targetX, targetY)
    }

    private fun moveBubbleTo(targetX: Int, targetY: Int) {
        val params = bubbleParams ?: return
        params.x = targetX
        params.y = targetY
        updateBubblePosition()
        persistBubblePosition(targetX, targetY)
    }

    private fun updateBubblePosition() {
        if (!isBubbleAttached) return
        val bubble = bubbleView ?: return
        val params = bubbleParams ?: return

        try {
            windowManager.updateViewLayout(bubble, params)
            updateCommandActionsPosition()
            updateDismissActionsPosition()
        } catch (e: Exception) {
            Log.w(TAG, "Failed to update bubble position", e)
        }
    }

    private fun shouldRevealDismissZones(params: WindowManager.LayoutParams): Boolean {
        val bubbleCenterY = params.y + currentBubbleHeightPx() / 2
        val revealTop = (resources.displayMetrics.heightPixels - dp(BUBBLE_DISMISS_DROP_HEIGHT_DP)).coerceAtLeast(0)
        return bubbleCenterY >= revealTop
    }

    private fun resolveDismissTarget(params: WindowManager.LayoutParams): BubbleDismissTarget? {
        val screenWidth = resources.displayMetrics.widthPixels
        val bubbleCenterX = params.x + currentBubbleWidthPx() / 2
        val bubbleCenterY = params.y + currentBubbleHeightPx() / 2

        if (bubbleCenterY < resources.displayMetrics.heightPixels - dp(DISMISS_ACTION_HEIGHT_DP)) return null
        return if (bubbleCenterX < screenWidth / 2) {
            BubbleDismissTarget.Snooze
        } else {
            BubbleDismissTarget.Hide
        }
    }

    private fun persistBubblePosition(x: Int, y: Int) {
        bubblePrefs.edit()
            .putInt(OverlayBubblePreferences.X_KEY, x)
            .putInt(OverlayBubblePreferences.Y_KEY, y)
            .apply()
    }

    private fun executeSelectionCommand(commandId: String, action: CommandAction) {
        if (recordingState != RecordingState.Idle) return

        val target = resolveSelectionCommandTarget()
        if (target == null) {
            hideCommandActions()
            return
        }

        dictationTargetNode = resolveFocusedEditableNode(null)
        activeCommandAction = action
        recordingMode = RecordingMode.Dictation
        recordingState = RecordingState.Processing
        updateBubbleUi()
        showCommandActions()

        serviceScope.launch {
            try {
                subscriptionRepository.checkCanTranscribe().onFailure { error ->
                    Toast.makeText(
                        this@OverlayDictationAccessibilityService,
                        error.message ?: getString(R.string.usage_limit_reached),
                        Toast.LENGTH_LONG
                    ).show()
                    return@launch
                }

                val command = resolveCommand(commandId)
                if (command == null) {
                    Toast.makeText(
                        this@OverlayDictationAccessibilityService,
                        R.string.overlay_command_unavailable,
                        Toast.LENGTH_SHORT
                    ).show()
                    return@launch
                }

                val contextRules = appPreferences.getInstructionsForApp(lastFocusedPackage)
                val result = CommandClient.execute(
                    command = command,
                    targetText = target.selectedText,
                    context = target.contextBefore,
                    additionalInstructions = contextRules
                )
                result.onSuccess { transformed ->
                    if (transformed.isBlank()) return@onSuccess
                    val applied = replaceSelectionOrMatchedText(target.selectedText, transformed)
                    if (!applied) {
                        Toast.makeText(
                            this@OverlayDictationAccessibilityService,
                            R.string.overlay_command_apply_failed,
                            Toast.LENGTH_SHORT
                        ).show()
                    } else {
                        lastDictatedText = transformed
                        subscriptionRepository.recordWords(transformed)
                    }
                }.onFailure { error ->
                    Log.e(TAG, "Command '${command.name}' failed", error)
                    Toast.makeText(
                        this@OverlayDictationAccessibilityService,
                        getString(R.string.overlay_command_failed, command.name),
                        Toast.LENGTH_SHORT
                    ).show()
                }
            } finally {
                recordingState = RecordingState.Idle
                activeCommandAction = null
                dictationTargetNode = null
                updateBubbleUi()
                refreshOverlayVisibility(null)
            }
        }
    }

    private suspend fun resolveCommand(commandId: String): Command? {
        return appPreferences.getEnabledCommands().find { it.id == commandId }
            ?: AppPreferences.defaultCommands.find { it.id == commandId }
    }

    private fun resolveSelectionCommandTarget(): SelectionCommandTarget? {
        val node = resolveFocusedEditableNode(null) ?: return null
        try {
            val snapshot = captureEditableTextSnapshot(node)
            if (snapshot.selectionEnd <= snapshot.selectionStart) {
                return null
            }

            val selectedText = snapshot.text.substring(snapshot.selectionStart, snapshot.selectionEnd)
            if (selectedText.isBlank()) {
                return null
            }

            val contextBefore = snapshot.text.take(snapshot.selectionStart).takeLast(200)
            return SelectionCommandTarget(
                selectedText = selectedText,
                contextBefore = contextBefore
            )
        } finally {
        }
    }

    private fun replaceCurrentSelection(replacement: String): Boolean {
        val node = resolveFocusedEditableNode(null) ?: return false
        try {
            val snapshot = captureEditableTextSnapshot(node)
            val start = snapshot.selectionStart
            val end = snapshot.selectionEnd
            if (end <= start) return false
            return replaceRange(node, snapshot.text, start, end, replacement)
        } finally {
        }
    }

    private suspend fun replaceSelectionOrMatchedText(
        targetText: String,
        replacement: String
    ): Boolean {
        val node = acquireInsertTarget() ?: return false
        try {
            val snapshot = captureEditableTextSnapshot(node)
            val selStart = snapshot.selectionStart
            val selEnd = snapshot.selectionEnd
            if (selEnd > selStart) {
                return replaceRange(node, snapshot.text, selStart, selEnd, replacement)
            }

            val matchStart = snapshot.text.lastIndexOf(targetText)
            if (matchStart >= 0) {
                return replaceRange(
                    node = node,
                    currentText = snapshot.text,
                    start = matchStart,
                    end = matchStart + targetText.length,
                    replacement = replacement
                )
            }

            return false
        } finally {
        }
    }

    private fun startRewriteInstructionRecording() {
        if (recordingState != RecordingState.Idle) return

        val target = resolveSelectionCommandTarget()
        if (target == null) {
            hideCommandActions()
            return
        }

        pendingRewriteTarget = target
        activeCommandAction = CommandAction.RewriteWithAi
        startRecording(mode = RecordingMode.RewriteInstruction)
    }

    private fun startRecording(mode: RecordingMode) {
        if (recordingState != RecordingState.Idle) return

        if (mode == RecordingMode.Dictation) {
            pendingRewriteTarget = null
            activeCommandAction = null
            hideCommandActions()
        } else {
            showCommandActions()
            updateCommandActionButtons()
        }

        val focusedNode = resolveFocusedEditableNode(null)
        if (focusedNode == null && !(stickyEditableFocusArmed && isKeyboardVisible())) {
            if (mode == RecordingMode.RewriteInstruction) {
                activeCommandAction = null
                pendingRewriteTarget = null
                updateBubbleUi()
            }
            Toast.makeText(this, "Focus a text field first", Toast.LENGTH_SHORT).show()
            return
        }
        // focusedNode may be null while a WebView tree rebuilds (sticky focus armed);
        // insert-time acquisition re-resolves with retries.
        dictationTargetNode = focusedNode

        if (mode == RecordingMode.RewriteInstruction && pendingRewriteTarget == null) {
            activeCommandAction = null
            Toast.makeText(this, R.string.overlay_command_apply_failed, Toast.LENGTH_SHORT).show()
            updateBubbleUi()
            return
        }

        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED
        ) {
            if (mode == RecordingMode.RewriteInstruction) {
                activeCommandAction = null
                pendingRewriteTarget = null
                updateBubbleUi()
            }
            Toast.makeText(this, "Microphone permission is required", Toast.LENGTH_SHORT).show()
            return
        }

        val recorder = AudioRecorder(
            context = this,
            autoStopOnSilenceEnabled = autoStopOnSilenceEnabled
        )
        val file = recorder.start()
        if (file == null) {
            if (mode == RecordingMode.RewriteInstruction) {
                activeCommandAction = null
                pendingRewriteTarget = null
                updateBubbleUi()
            }
            Toast.makeText(this, "Could not start recording", Toast.LENGTH_SHORT).show()
            recorder.release()
            return
        }

        audioRecorder = recorder
        recordingMode = mode
        recordingState = RecordingState.Recording
        updateBubbleUi()

        vadJob?.cancel()
        vadJob = serviceScope.launch {
            recorder.shouldAutoStop.collectLatest { shouldStop ->
                if (shouldStop && recordingState == RecordingState.Recording) {
                    stopRecording(discard = false)
                }
            }
        }
    }

    private fun stopRecording(discard: Boolean) {
        if (recordingState != RecordingState.Recording) return
        val mode = recordingMode

        vadJob?.cancel()
        vadJob = null

        val recorder = audioRecorder ?: run {
            recordingState = RecordingState.Idle
            if (mode == RecordingMode.RewriteInstruction) {
                activeCommandAction = null
                pendingRewriteTarget = null
            }
            recordingMode = RecordingMode.Dictation
            updateBubbleUi()
            refreshOverlayVisibility(null)
            return
        }

        val speechDetected = recorder.hasSpeechBeenDetected()
        val result = recorder.stop()
        val audioFile = result?.first
        val duration = result?.second ?: 0L
        audioRecorder = null

        if (discard) {
            audioFile?.delete()
            recordingState = RecordingState.Idle
            if (mode == RecordingMode.RewriteInstruction) {
                activeCommandAction = null
                pendingRewriteTarget = null
            }
            recordingMode = RecordingMode.Dictation
            updateBubbleUi()
            refreshOverlayVisibility(null)
            return
        }

        if (audioFile == null || !audioFile.exists()) {
            recordingState = RecordingState.Idle
            if (mode == RecordingMode.RewriteInstruction) {
                activeCommandAction = null
                pendingRewriteTarget = null
            }
            recordingMode = RecordingMode.Dictation
            updateBubbleUi()
            refreshOverlayVisibility(null)
            return
        }

        if (duration < MIN_RECORDING_MS || !speechDetected) {
            audioFile.delete()
            recordingState = RecordingState.Idle
            if (mode == RecordingMode.RewriteInstruction) {
                activeCommandAction = null
                pendingRewriteTarget = null
                Toast.makeText(this, R.string.overlay_command_no_instruction, Toast.LENGTH_SHORT).show()
            }
            recordingMode = RecordingMode.Dictation
            updateBubbleUi()
            refreshOverlayVisibility(null)
            return
        }

        val focusedNode = currentDictationNode()
        if (focusedNode == null && !stickyEditableFocusArmed) {
            audioFile.delete()
            recordingState = RecordingState.Idle
            if (mode == RecordingMode.RewriteInstruction) {
                activeCommandAction = null
                pendingRewriteTarget = null
            }
            recordingMode = RecordingMode.Dictation
            updateBubbleUi()
            refreshOverlayVisibility(null)
            return
        }

        recordingState = RecordingState.Processing
        updateBubbleUi()

        serviceScope.launch {
            try {
                when (mode) {
                    RecordingMode.Dictation -> processRecording(audioFile)
                    RecordingMode.RewriteInstruction -> processRewriteInstructionRecording(
                        audioFile = audioFile,
                        target = pendingRewriteTarget
                    )
                }
            } finally {
                audioFile.delete()
                recordingState = RecordingState.Idle
                dictationTargetNode = null
                if (mode == RecordingMode.RewriteInstruction) {
                    activeCommandAction = null
                    pendingRewriteTarget = null
                }
                recordingMode = RecordingMode.Dictation
                updateBubbleUi()
                refreshOverlayVisibility(null)
            }
        }
    }

    private suspend fun processRecording(audioFile: java.io.File) {
        subscriptionRepository.checkCanTranscribe().onFailure { error ->
            Toast.makeText(
                this@OverlayDictationAccessibilityService,
                error.message ?: getString(R.string.usage_limit_reached),
                Toast.LENGTH_LONG
            ).show()
            return
        }

        val node = currentDictationNode()
        val snapshot = node?.let { captureEditableTextSnapshot(it) } ?: EditableTextSnapshot("", 0, 0)

        val contextText = snapshot.text.take(snapshot.selectionStart).takeLast(200)
        val contextRules = appPreferences.getInstructionsForApp(lastFocusedPackage)
        val enabledCommands = appPreferences.getEnabledCommands()

        // Build Whisper prompt: dictionary/shortcut hints + cursor context (NO context rules)
        val repoPrompt = transcriptionRepository.buildPrompt()
        val whisperPrompt = listOfNotNull(
            contextText.ifEmpty { null },
            repoPrompt.ifEmpty { null }
        ).joinToString("\n\n").ifEmpty { null }

        Log.d("OverlayDictation", "Whisper prompt: $whisperPrompt, contextRules: $contextRules")

        // Transcription + LLM post-processing (context rules go to LLM, not Whisper)
        val rawText = transcriptionRepository.transcribe(audioFile, whisperPrompt, contextRules)
            .getOrElse { e ->
                Log.e("OverlayDictation", "Transcription failed", e)
                return
            }

        // Command detection and execution (separate from transcription)
        val result: Result<com.whispermate.aidictation.data.remote.TranscriptionResult> =
            TranscriptionClient.detectAndExecuteCommands(rawText, lastDictatedText, enabledCommands, contextRules)

        val transcription = result.getOrElse { error ->
            Log.e(TAG, "Transcription failed", error)
            Toast.makeText(this@OverlayDictationAccessibilityService, "Transcription failed", Toast.LENGTH_SHORT).show()
            return
        }
        if (transcription.text.isBlank()) return

        val finalText = if (transcription.executedCommand != null) {
            transcription.text
        } else {
            transcriptionRepository.applyPostProcessing(transcription.text)
        }

        val applied = if (transcription.executedCommand != null) {
            applyCommandResult(finalText)
        } else {
            insertDictationText(finalText)
        }

        if (applied) {
            lastDictatedText = finalText
            subscriptionRepository.recordWords(finalText)
        }
    }

    private suspend fun processRewriteInstructionRecording(
        audioFile: java.io.File,
        target: SelectionCommandTarget?
    ) {
        subscriptionRepository.checkCanTranscribe().onFailure { error ->
            Toast.makeText(
                this@OverlayDictationAccessibilityService,
                error.message ?: getString(R.string.usage_limit_reached),
                Toast.LENGTH_LONG
            ).show()
            return
        }

        if (target == null) {
            Toast.makeText(
                this@OverlayDictationAccessibilityService,
                R.string.overlay_command_apply_failed,
                Toast.LENGTH_SHORT
            ).show()
            return
        }

        val selectedLangs = appPreferences.selectedLanguages.first()
        val rewriteLang = if (selectedLangs.size == 1) selectedLangs.first() else null
        val transcriptionResult = TranscriptionClient.transcribe(audioFile = audioFile, prompt = null, language = rewriteLang)
        transcriptionResult.onSuccess { instruction ->
            if (instruction.isBlank()) {
                Toast.makeText(
                    this@OverlayDictationAccessibilityService,
                    R.string.overlay_command_no_instruction,
                    Toast.LENGTH_SHORT
                ).show()
                return@onSuccess
            }

            val contextRules = appPreferences.getInstructionsForApp(lastFocusedPackage)
            val commandResult = CommandClient.executeInstruction(
                instruction = instruction,
                targetText = target.selectedText,
                context = target.contextBefore,
                additionalInstructions = contextRules
            )

            commandResult.onSuccess { transformed ->
                if (transformed.isBlank()) return@onSuccess

                val applied = replaceSelectionOrMatchedText(
                    targetText = target.selectedText,
                    replacement = transformed
                )
                if (!applied) {
                    Toast.makeText(
                        this@OverlayDictationAccessibilityService,
                        R.string.overlay_command_apply_failed,
                        Toast.LENGTH_SHORT
                    ).show()
                } else {
                    lastDictatedText = transformed
                    subscriptionRepository.recordWords(transformed)
                }
            }.onFailure { error ->
                Log.e(TAG, "Rewrite instruction failed", error)
                Toast.makeText(
                    this@OverlayDictationAccessibilityService,
                    getString(R.string.overlay_command_failed, getString(R.string.overlay_action_rewrite_ai)),
                    Toast.LENGTH_SHORT
                ).show()
            }
        }.onFailure { error ->
            Log.e(TAG, "Instruction transcription failed", error)
            Toast.makeText(
                this@OverlayDictationAccessibilityService,
                "Transcription failed",
                Toast.LENGTH_SHORT
            ).show()
        }
    }

    private suspend fun applyCommandResult(transformedText: String): Boolean {
        val node = acquireInsertTarget() ?: return false
        try {
            val snapshot = captureEditableTextSnapshot(node)
            val current = snapshot.text
            val selStart = snapshot.selectionStart
            val selEnd = snapshot.selectionEnd

            if (selEnd > selStart) {
                return replaceRange(node, current, selStart, selEnd, transformedText)
            }

            if (lastDictatedText.isNotBlank()) {
                val start = current.lastIndexOf(lastDictatedText)
                if (start >= 0) {
                    return replaceRange(
                        node = node,
                        currentText = current,
                        start = start,
                        end = start + lastDictatedText.length,
                        replacement = transformedText
                    )
                }
            }

            return insertDictationText(transformedText)
        } finally {
        }
    }

    private suspend fun insertDictationText(text: String): Boolean {
        val node = acquireInsertTarget() ?: return false
        try {
            var snapshot = captureEditableTextSnapshot(node)
            Log.i(
                TAG,
                "Insert target: pkg=${node.packageName} class=${node.className} " +
                    "sel=${node.textSelectionStart}..${node.textSelectionEnd} " +
                    "hintShowing=${node.isShowingHintText} hint=${node.hintText} " +
                    "desc=${node.contentDescription?.toString()?.take(60)} " +
                    "text=${node.text?.toString()?.take(60)} " +
                    "normalized=${snapshot.text.take(60)} normalizedSel=${snapshot.selectionStart}..${snapshot.selectionEnd} " +
                    "extras=${node.extras?.keySet()?.joinToString(",")}"
            )
            if (snapshot.text.isNotEmpty() && isPhantomPlaceholderText(node)) {
                Log.i(TAG, "Field text is a phantom placeholder; treating field as empty")
                snapshot = EditableTextSnapshot("", 0, 0)
            }
            val current = snapshot.text
            val selStart = snapshot.selectionStart
            val selEnd = snapshot.selectionEnd

            val insertText = withLeadingSpaceIfNeeded(current, selStart, text)
            return replaceRange(node, current, selStart, selEnd, insertText)
        } finally {
        }
    }

    private fun replaceRange(
        node: AccessibilityNodeInfo,
        currentText: String,
        start: Int,
        end: Int,
        replacement: String
    ): Boolean {
        val safeStart = start.coerceIn(0, currentText.length)
        val safeEnd = end.coerceIn(safeStart, currentText.length)

        val updated = buildString {
            append(currentText.substring(0, safeStart))
            append(replacement)
            append(currentText.substring(safeEnd))
        }

        if (setNodeText(node, updated)) {
            val cursor = safeStart + replacement.length
            setNodeSelection(node, cursor, cursor)
            return true
        }

        if (currentText.isEmpty()) {
            val rawLen = node.text?.length ?: 0
            if (rawLen > 0) setNodeSelection(node, 0, rawLen)
        }

        return pasteFallback(node, replacement, safeStart, safeEnd)
    }

    /**
     * Chrome exposes CSS/ARIA placeholders of web editors (e.g. LinkedIn's composer) as
     * the node's text with a caret at the end and no hint metadata, indistinguishable
     * from real content. Such text does not actually exist in the field, so selecting
     * it fails - probe with ACTION_SET_SELECTION before preserving it on insert.
     */
    private fun isPhantomPlaceholderText(node: AccessibilityNodeInfo): Boolean {
        val rawLength = node.text?.length ?: 0
        if (rawLength == 0) return false

        if (!setNodeSelection(node, 0, rawLength)) {
            Log.i(TAG, "Placeholder probe: select-all rejected")
            return true
        }
        if (!refreshNode(node)) return false

        val selected = node.textSelectionStart == 0 && node.textSelectionEnd == rawLength
        if (selected) {
            // Real text: collapse the probe selection back to the end.
            setNodeSelection(node, rawLength, rawLength)
            return false
        }
        Log.i(
            TAG,
            "Placeholder probe: select-all did not take " +
                "(sel=${node.textSelectionStart}..${node.textSelectionEnd}, len=$rawLength)"
        )
        return true
    }

    private fun setNodeText(node: AccessibilityNodeInfo, text: String): Boolean {
        val args = Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, text)
        }
        return node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
    }

    private fun setNodeSelection(node: AccessibilityNodeInfo, start: Int, end: Int): Boolean {
        val args = Bundle().apply {
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, start)
            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, end)
        }
        return node.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, args)
    }

    private fun pasteFallback(
        node: AccessibilityNodeInfo,
        text: String,
        start: Int,
        end: Int
    ): Boolean {
        val clipboard = getSystemService(CLIPBOARD_SERVICE) as ClipboardManager
        clipboard.setPrimaryClip(ClipData.newPlainText("dictation", text))

        setNodeSelection(node, start, end)
        return node.performAction(AccessibilityNodeInfo.ACTION_PASTE)
    }

    private fun withLeadingSpaceIfNeeded(currentText: String, index: Int, text: String): String {
        if (currentText.isEmpty() || index <= 0) return text
        if (text.startsWith(" ")) return text

        val previous = currentText[index - 1]
        if (previous.isWhitespace()) return text

        val startsWithPunctuation = text.startsWith(",") ||
            text.startsWith(".") ||
            text.startsWith("!") ||
            text.startsWith("?") ||
            text.startsWith(":") ||
            text.startsWith(";")

        return if (startsWithPunctuation) text else " $text"
    }

    private fun resolveSelectionStart(node: AccessibilityNodeInfo?, default: Int): Int {
        val value = node?.textSelectionStart ?: -1
        if (value < 0) return default.coerceAtLeast(0)
        return value.coerceIn(0, default.coerceAtLeast(0))
    }

    private fun resolveSelectionEnd(node: AccessibilityNodeInfo?, start: Int, max: Int): Int {
        val value = node?.textSelectionEnd ?: -1
        if (value < 0) return start
        return value.coerceIn(start, max)
    }

    private fun captureEditableTextSnapshot(node: AccessibilityNodeInfo): EditableTextSnapshot {
        val rawText = node.text?.toString().orEmpty()
        val rawSelStart = resolveSelectionStart(node, rawText.length)
        val rawSelEnd = resolveSelectionEnd(node, rawSelStart, rawText.length)

        val normalized = normalizeEditableText(node, rawText)
        val selStart = (rawSelStart - normalized.removedPrefix).coerceIn(0, normalized.text.length)
        val selEnd = (rawSelEnd - normalized.removedPrefix).coerceIn(selStart, normalized.text.length)

        return EditableTextSnapshot(
            text = normalized.text,
            selectionStart = selStart,
            selectionEnd = selEnd
        )
    }

    private fun normalizeEditableText(
        node: AccessibilityNodeInfo,
        rawText: String
    ): NormalizedText {
        if (rawText.isEmpty()) return NormalizedText("", 0)
        if (node.isShowingHintText) return NormalizedText("", rawText.length)

        // if both selection endpoints are -1, the field has no cursor position,
        // which means it's likely showing placeholder text. Apps like Telegram don't set
        // isShowingHintText=true or hintText when displaying their placeholder.
        if (node.textSelectionStart == -1 && node.textSelectionEnd == -1) {
            return NormalizedText("", rawText.length)
        }

        val hint = node.hintText?.toString()?.trim().orEmpty()
        if (hint.isNotEmpty()) {
            if (matchesPlaceholderLabel(rawText, hint)) {
                return NormalizedText("", rawText.length)
            }

            val hintPrefixRegex = Regex("^\\Q$hint\\E[\\s\\u00A0]*")
            val hintPrefix = hintPrefixRegex.find(rawText)
            if (hintPrefix != null && hintPrefix.range.first == 0) {
                val prefixLength = hintPrefix.range.last + 1
                return NormalizedText(rawText.substring(prefixLength), prefixLength)
            }
        }

        // WebView fields (e.g. LinkedIn's comment box) expose their placeholder as the
        // node text with the label mirrored in contentDescription and no hintText. Only
        // trust this when the caret has not moved into the text, so a real value that
        // happens to match an accessibility label is not mistaken for a placeholder.
        val description = node.contentDescription?.toString()?.trim().orEmpty()
        if (
            description.isNotEmpty() &&
            node.textSelectionStart <= 0 &&
            node.textSelectionEnd <= 0 &&
            matchesPlaceholderLabel(rawText, description)
        ) {
            return NormalizedText("", rawText.length)
        }

        val packageName = node.packageName?.toString().orEmpty()
        val viewId = node.viewIdResourceName.orEmpty()
        if (packageName == "com.android.chrome" && viewId == "com.android.chrome:id/url_bar") {
            val chromeHints = listOf("Search Google or type URL", "Search or type URL")
            for (prefix in chromeHints) {
                if (!rawText.startsWith(prefix)) continue

                var prefixLength = prefix.length
                while (prefixLength < rawText.length && rawText[prefixLength].isWhitespace()) {
                    prefixLength++
                }
                return NormalizedText(rawText.substring(prefixLength), prefixLength)
            }
        }

        return NormalizedText(rawText, 0)
    }

    private data class NormalizedText(
        val text: String,
        val removedPrefix: Int
    )

    /**
     * True when the field's visible text is just its own placeholder label, tolerating
     * case and trailing ellipsis/punctuation differences ("Share your thoughts…" vs
     * "Share your thoughts").
     */
    private fun matchesPlaceholderLabel(rawText: String, label: String): Boolean {
        val text = normalizeForPlaceholderComparison(rawText)
        return text.isNotEmpty() && text == normalizeForPlaceholderComparison(label)
    }

    private fun normalizeForPlaceholderComparison(value: String): String {
        return java.text.Normalizer.normalize(value.trim(), java.text.Normalizer.Form.NFC)
            .trimEnd('.', '…', ':', ' ', ' ')
            .lowercase()
    }

    private fun resolveBubbleActiveColor(): Int {
        return when (activeCommandAction) {
            CommandAction.FixGrammar -> bubbleFixActiveColor
            CommandAction.RewriteWithAi -> bubbleRewriteActiveColor
            null -> bubbleDictationActiveColor
        }
    }

    private fun updateCommandActionButtons() {
        val hasActiveCommand = activeCommandAction != null
        val isBusy = recordingState != RecordingState.Idle
        val canTap = recordingState == RecordingState.Idle

        val fixActive = hasActiveCommand && activeCommandAction == CommandAction.FixGrammar
        val rewriteActive = hasActiveCommand && activeCommandAction == CommandAction.RewriteWithAi

        applyCommandButtonStyle(
            button = fixGrammarButton,
            textColor = if (fixActive) commandChipFixTextColor else commandChipIdleTextColor,
            backgroundColor = if (fixActive) commandChipFixBackgroundColor else commandChipIdleBackgroundColor,
            enabled = canTap,
            subdued = isBusy && !fixActive
        )
        applyCommandButtonStyle(
            button = rewriteButton,
            textColor = if (rewriteActive) commandChipRewriteTextColor else commandChipIdleTextColor,
            backgroundColor = if (rewriteActive) commandChipRewriteBackgroundColor else commandChipIdleBackgroundColor,
            enabled = canTap,
            subdued = isBusy && !rewriteActive
        )
    }

    private fun applyCommandButtonStyle(
        button: TextView?,
        textColor: Int,
        backgroundColor: Int,
        enabled: Boolean,
        subdued: Boolean
    ) {
        button ?: return
        button.isEnabled = enabled
        button.alpha = if (subdued) 0.55f else 1f
        button.setTextColor(textColor)
        button.background = GradientDrawable().apply {
            shape = GradientDrawable.RECTANGLE
            cornerRadius = dp(16).toFloat()
            setColor(backgroundColor)
        }
    }

    private fun preferredOnColor(backgroundColor: Int): Int {
        val red = Color.red(backgroundColor) / 255f
        val green = Color.green(backgroundColor) / 255f
        val blue = Color.blue(backgroundColor) / 255f
        val luma = (0.299f * red) + (0.587f * green) + (0.114f * blue)
        return if (luma > 0.62f) Color.BLACK else Color.WHITE
    }

    private fun updateBubbleUi() {
        updateCommandActionButtons()
        val bubble = bubbleView ?: return
        bubble.setColors(bubbleIdleColor, resolveBubbleActiveColor())
        // Keep the screen awake while dictation is recording or processing
        bubble.keepScreenOn = recordingState != RecordingState.Idle

        when (recordingState) {
            RecordingState.Idle -> {
                stopBubbleAnimation()
                bubble.setState(OverlayMicButtonView.State.Idle)
                updateBubbleLayoutSize()
            }

            RecordingState.Recording -> {
                bubble.setState(OverlayMicButtonView.State.Recording)
                updateBubbleLayoutSize()
                startBubbleAnimation()
            }

            RecordingState.Processing -> {
                stopBubbleAnimation()
                bubble.setState(OverlayMicButtonView.State.Processing)
                updateBubbleLayoutSize()
            }
        }
    }

    private fun updateBubbleLayoutSize() {
        val bubble = bubbleView ?: return
        val params = bubbleParams ?: return
        val targetWidth = currentBubbleWidthPx()
        val targetHeight = currentBubbleHeightPx()
        if (params.width == targetWidth && params.height == targetHeight) return

        val startWidth = params.width.takeIf { it > 0 } ?: dp(BUBBLE_SIZE_DP)
        val startX = params.x
        val anchoredRight = startX + (startWidth / 2) >= resources.displayMetrics.widthPixels / 2
        val anchoredEdgeX = if (anchoredRight) startX + startWidth else startX
        val margin = dp(BUBBLE_MARGIN_DP)
        val targetX = if (anchoredRight) {
            (anchoredEdgeX - targetWidth).coerceIn(margin, maxBubbleX(targetWidth))
        } else {
            startX.coerceIn(margin, maxBubbleX(targetWidth))
        }
        val targetY = params.y.coerceIn(margin, maxBubbleY(targetHeight))

        params.width = targetWidth
        params.height = targetHeight
        params.x = targetX
        params.y = targetY
        if (isBubbleAttached) {
            try {
                windowManager.removeViewImmediate(bubble)
                windowManager.addView(bubble, params)
                updateCommandActionsPosition()
            } catch (e: Exception) {
                Log.w(TAG, "Failed to update bubble overlay size", e)
            }
        }
    }

    private fun startBubbleAnimation() {
        bubbleAnimationJob?.cancel()
        bubbleAnimationJob = serviceScope.launch {
            while (recordingState == RecordingState.Recording) {
                val recorder = audioRecorder
                if (recorder == null) {
                    break
                }
                bubbleView?.setAudioLevel(recorder.audioLevel.value)
                bubbleView?.setFrequencyBands(recorder.frequencyBands.value)
                delay(50)
            }
        }
    }

    private fun stopBubbleAnimation() {
        bubbleAnimationJob?.cancel()
        bubbleAnimationJob = null
    }

    private fun resolveThemeColor(attrResId: Int, fallback: Int): Int {
        val typedArray = theme.obtainStyledAttributes(intArrayOf(attrResId))
        return try {
            typedArray.getColor(0, fallback)
        } finally {
            typedArray.recycle()
        }
    }

    private fun withAlpha(color: Int, alphaFraction: Float): Int {
        val alpha = (alphaFraction.coerceIn(0f, 1f) * 255f).toInt()
        return (color and 0x00FFFFFF) or (alpha shl 24)
    }

    private fun defaultBubbleX(): Int {
        val screenWidth = resources.displayMetrics.widthPixels
        return (screenWidth - dp(BUBBLE_SIZE_DP + BUBBLE_MARGIN_DP)).coerceAtLeast(dp(BUBBLE_MARGIN_DP))
    }

    private fun defaultBubbleY(): Int {
        val screenHeight = resources.displayMetrics.heightPixels
        return screenHeight / 2
    }

    private fun dp(value: Int): Int {
        return (value * resources.displayMetrics.density).toInt()
    }

    private fun currentBubbleWidthPx(): Int {
        return dp(bubbleView?.preferredWidthDp() ?: BUBBLE_SIZE_DP)
    }

    private fun currentBubbleHeightPx(): Int {
        return dp(bubbleView?.preferredHeightDp() ?: BUBBLE_SIZE_DP)
    }

    private fun maxBubbleX(widthPx: Int = currentBubbleWidthPx()): Int {
        return (resources.displayMetrics.widthPixels - widthPx - dp(BUBBLE_MARGIN_DP))
            .coerceAtLeast(dp(BUBBLE_MARGIN_DP))
    }

    private fun maxBubbleY(heightPx: Int = currentBubbleHeightPx()): Int {
        return (keyboardTop() - heightPx - dp(BUBBLE_MARGIN_DP))
            .coerceAtLeast(dp(BUBBLE_MARGIN_DP))
    }
}
