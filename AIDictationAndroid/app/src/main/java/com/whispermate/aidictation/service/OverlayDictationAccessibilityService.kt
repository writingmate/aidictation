package com.whispermate.aidictation.service

import android.Manifest
import android.accessibilityservice.AccessibilityService
import android.content.ClipData
import android.content.ClipboardManager
import android.content.res.ColorStateList
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.InsetDrawable
import android.graphics.drawable.RippleDrawable
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import android.view.ViewTreeObserver
import android.view.animation.AccelerateInterpolator
import android.widget.ImageView
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
import com.whispermate.aidictation.domain.model.AudioAttemptLease
import com.whispermate.aidictation.ui.views.OverlayMicButtonView
import com.whispermate.aidictation.ui.views.OverlayRewritePanelView
import com.whispermate.aidictation.ui.views.RewriteAction
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout

internal enum class OverlayRecordingState {
    Idle,
    Recording,
    Processing
}

internal enum class OverlayBubblePresentation {
    Idle,
    Recording,
    Processing
}

internal fun OverlayRecordingState.bubblePresentation(): OverlayBubblePresentation = when (this) {
    OverlayRecordingState.Idle -> OverlayBubblePresentation.Idle
    OverlayRecordingState.Recording -> OverlayBubblePresentation.Recording
    OverlayRecordingState.Processing -> OverlayBubblePresentation.Processing
}

internal val OverlayRecordingState.streamsAudioLevels: Boolean
    get() = this == OverlayRecordingState.Recording

internal fun canStartSelectionCommand(
    recordingState: OverlayRecordingState,
    workflowActive: Boolean
): Boolean = recordingState == OverlayRecordingState.Idle && !workflowActive

/**
 * The wand button is either shown and tappable, or not shown at all: there is no
 * disabled state. It appears beside an idle bubble, with no dictation delivery in
 * flight, while the focused field has a non-blank selection and its panel is closed.
 */
/**
 * The bubble belongs with the keyboard: without one there is nothing to dictate into.
 * The exceptions are while dictation is under way (recording, processing or delivering)
 * and while the edit panel is open, so a keyboard that hides mid-task never tears the
 * task down.
 */
internal fun bubbleNeedsKeyboard(
    recordingState: OverlayRecordingState,
    workflowActive: Boolean,
    panelOpen: Boolean
): Boolean = recordingState == OverlayRecordingState.Idle && !workflowActive && !panelOpen

internal fun shouldShowWandButton(
    recordingState: OverlayRecordingState,
    workflowActive: Boolean,
    hasSelection: Boolean,
    panelOpen: Boolean
): Boolean = hasSelection && !panelOpen && canStartSelectionCommand(recordingState, workflowActive)

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
        private const val ACCESS_CHECK_TIMEOUT_MS = 15_000L
        private const val SETTINGS_SNAPSHOT_TIMEOUT_MS = 5_000L
        /** Whole bubble window while idle: the 55 dp circle plus its shadow margin on every side. */
        private const val BUBBLE_SIZE_DP = OverlayMicButtonView.IDLE_SIZE_DP
        /**
         * Gap between the bubble window and the screen edges or the keyboard. The window already
         * carries a transparent shadow margin, so the visible circle sits a little further in.
         */
        private const val BUBBLE_MARGIN_DP = 8
        private const val BUBBLE_SNOOZE_MS = 10 * 60 * 1000L
        private const val BUBBLE_HIDE_DEBOUNCE_MS = 250L
        /** IME window reports lag and flap while the keyboard animates; wait this long before trusting an absence. */
        private const val KEYBOARD_HIDE_GRACE_MS = 700L
        private const val EVENT_COALESCE_MS = 120L
        private const val FOCUS_RECOVERY_ATTEMPTS = 15
        private const val FOCUS_RECOVERY_RETRY_MS = 200L
        private const val INSERT_RESOLVE_ATTEMPTS = 3
        private const val INSERT_RESOLVE_RETRY_MS = 250L
        private const val INSERT_VERIFY_ATTEMPTS = 5
        private const val INSERT_VERIFY_RETRY_MS = 150L
        private const val BUBBLE_DISMISS_DROP_HEIGHT_DP = 180
        /** Both the wand and the bubble windows carry transparent shadow margins, so the gap stays small. */
        private const val COMMAND_ACTION_HORIZONTAL_MARGIN_DP = 2
        private const val COMMAND_ACTION_GAP_DP = 8
        private const val COMMAND_ACTION_BUTTON_SIZE_DP = 55
        private const val COMMAND_ACTION_CONTAINER_PADDING_DP = 6
        private const val COMMAND_ACTION_ESTIMATED_WIDTH_DP = 67
        private const val COMMAND_ACTION_ESTIMATED_HEIGHT_DP = 67
        private const val DISMISS_ACTION_HEIGHT_DP = 104
        private const val COMMAND_ACTION_ICON_PADDING_DP = 15
        private const val COMMAND_ACTION_ELEVATION_DP = 6
        /** Material pressed state layer. */
        private const val COMMAND_ACTION_RIPPLE_ALPHA = 0.12f
        private const val COMMAND_ACTIONS_FADE_IN_MS = 150L
        private const val WAND_ABSORB_MS = 220L
        private const val WAND_ABSORB_SCALE = 1.6f
        private const val REWRITE_PANEL_MARGIN_DP = 12
        private const val COMMAND_CLEANUP_ID = "cleanup"

        private val TRACKED_EVENT_TYPES = setOf(
            AccessibilityEvent.TYPE_VIEW_FOCUSED,
            AccessibilityEvent.TYPE_VIEW_ACCESSIBILITY_FOCUSED,
            AccessibilityEvent.TYPE_VIEW_CLICKED,
            AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED,
            AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED,
            AccessibilityEvent.TYPE_WINDOWS_CHANGED,
            AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED,
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED
        )

        /**
         * Events caused directly by the user touching or focusing a field. These are rare
         * and the overlay should react to them at once. Everything else in
         * [TRACKED_EVENT_TYPES] (window and content changes) arrives in bursts during
         * animations, scrolling and WebView tree rebuilds and is coalesced instead.
         */
        private val IMMEDIATE_EVENT_TYPES = setOf(
            AccessibilityEvent.TYPE_VIEW_FOCUSED,
            AccessibilityEvent.TYPE_VIEW_ACCESSIBILITY_FOCUSED,
            AccessibilityEvent.TYPE_VIEW_CLICKED,
            AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED
        )

        private val FOCUS_EVENT_TYPES = setOf(
            AccessibilityEvent.TYPE_VIEW_FOCUSED,
            AccessibilityEvent.TYPE_VIEW_ACCESSIBILITY_FOCUSED,
            AccessibilityEvent.TYPE_VIEW_CLICKED
        )

        /** Windows that never host a dictation target and are not worth a round trip. */
        private val SKIPPED_WINDOW_TYPES = setOf(
            AccessibilityWindowInfo.TYPE_SYSTEM,
            AccessibilityWindowInfo.TYPE_ACCESSIBILITY_OVERLAY,
            AccessibilityWindowInfo.TYPE_SPLIT_SCREEN_DIVIDER
        )
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

    /** The text being edited in the rewrite panel, from the wand tap to apply or close. */
    private class RewriteSession(
        val originalText: String,
        val contextBefore: String,
        val targetNode: AccessibilityNodeInfo?,
        var workingText: String,
        var job: Job? = null
    )

    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    @Inject lateinit var appPreferences: AppPreferences
    @Inject lateinit var transcriptionRepository: com.whispermate.aidictation.data.repository.TranscriptionRepository
    @Inject lateinit var subscriptionRepository: SubscriptionRepository
    @Inject lateinit var audioProcessingCoordinator: AndroidAudioProcessingCoordinator
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

    private var recordingState: OverlayRecordingState = OverlayRecordingState.Idle
    private var stopRequestedDuringStart = false
    private val overlayWorkflowFence = ReplaceableDeliveryFence()
    private var audioWorkflowLease: AudioAttemptLease? = null
    private var audioWorkflowJob: Job? = null
    private var deliveryJob: Job? = null
    private var vadJob: Job? = null
    private var autoStopOnSilenceEnabled = false
    private var bubbleAnimationJob: Job? = null
    private var pendingHideJob: Job? = null
    private var overlayRefreshJob: Job? = null
    private var focusRecoveryJob: Job? = null
    private var isServiceDestroyed = false
    private var stickyEditableFocusArmed = false
    private var dictationTargetNode: AccessibilityNodeInfo? = null
    private var wandButton: ImageView? = null
    private var wandAbsorbing = false
    private var rewritePanel: OverlayRewritePanelView? = null
    private var rewritePanelParams: WindowManager.LayoutParams? = null
    private var isRewritePanelAttached = false
    private var rewriteSession: RewriteSession? = null

    private var lastFocusedPackage: String? = null
    private var lastDictatedText: String = ""
    /** Exact keyboard signal when "display over other apps" is granted; null reports fall back to the window list. */
    private var keyboardProbe: KeyboardProbeWindow? = null
    /** Last keyboard state seen in the accessibility window list, to spot changes between coalesced passes. */
    private var lastInputMethodWindowVisible = false

    private val bubblePrefs by lazy { OverlayBubblePreferences.prefs(this) }

    override fun onServiceConnected() {
        super.onServiceConnected()
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
        keyboardProbe = KeyboardProbeWindow(this, windowManager, ::onKeyboardProbeChanged).also { it.attach() }

        serviceScope.launch {
            appPreferences.autoStopOnSilenceEnabled.collectLatest { enabled ->
                autoStopOnSilenceEnabled = enabled
            }
        }
        serviceScope.launch {
            audioProcessingCoordinator.failureEvents.collect { event ->
                val failedToken = overlayWorkflowFence.currentToken()
                if (event.matches(
                        AndroidAudioAttemptOwner.OVERLAY,
                        audioWorkflowLease,
                        failedToken
                    ) &&
                    recordingState != OverlayRecordingState.Idle
                ) {
                    failedToken ?: return@collect
                    Toast.makeText(
                        this@OverlayDictationAccessibilityService,
                        event.message,
                        Toast.LENGTH_LONG
                    ).show()
                    resetAfterRecording(failedToken)
                }
            }
        }

        prewarmCapturePath()
        refreshOverlayVisibility(null)
        scheduleFocusRecoveryIfNeeded(force = true)
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
        val eventType = event.eventType
        if (eventType !in TRACKED_EVENT_TYPES) return

        lastFocusedPackage = event.packageName?.toString()

        // Every overlay refresh makes synchronous round trips into the focused app, and
        // this service runs on the app's main thread. Reacting to each event of a burst
        // stalls both the queried app and our own UI, so only direct user interaction is
        // handled immediately; window and content changes are coalesced into one pass.
        if (eventType in IMMEDIATE_EVENT_TYPES) {
            overlayRefreshJob?.cancel()
            overlayRefreshJob = null
            val source = event.source
            refreshOverlayVisibility(source)
            scheduleFocusRecoveryIfNeeded(
                force = eventType in FOCUS_EVENT_TYPES && source?.isEditable == true
            )
            return
        }

        // The keyboard window coming or going is the one window change the bubble must
        // follow at once; other window bursts still wait for the coalesced pass.
        if (eventType == AccessibilityEvent.TYPE_WINDOWS_CHANGED && keyboardProbe?.keyboardVisible == null) {
            val inputMethodVisible = inputMethodBounds() != null
            if (inputMethodVisible != lastInputMethodWindowVisible) {
                lastInputMethodWindowVisible = inputMethodVisible
                overlayRefreshJob?.cancel()
                overlayRefreshJob = null
                refreshOverlayVisibility(null)
                scheduleFocusRecoveryIfNeeded()
                return
            }
        }

        if (overlayRefreshJob?.isActive == true) return
        overlayRefreshJob = serviceScope.launch {
            delay(EVENT_COALESCE_MS)
            overlayRefreshJob = null
            refreshOverlayVisibility(null)
            scheduleFocusRecoveryIfNeeded()
        }
    }

    override fun onInterrupt() {
        cancelOverlayAudio("Dictation was interrupted")
        dictationTargetNode = null
        dismissRewritePanel()
        hideBubble()
        hideCommandActions()
        hideDismissActions()
        stopBubbleAnimation()
        overlayRefreshJob?.cancel()
        overlayRefreshJob = null
        focusRecoveryJob?.cancel()
        focusRecoveryJob = null
    }

    override fun onDestroy() {
        isServiceDestroyed = true
        super.onDestroy()
        val workflowToken = overlayWorkflowFence.currentToken()
        workflowToken?.let(overlayWorkflowFence::finish)
        audioProcessingCoordinator.cancelCaptureFromLifecycle(
            AndroidAudioAttemptOwner.OVERLAY,
            "Dictation service stopped",
            expectedLease = audioWorkflowLease,
            expectedWorkflowToken = workflowToken
        )
        serviceScope.cancel()
        dictationTargetNode = null
        dismissRewritePanel()
        hideBubble()
        hideCommandActions()
        hideDismissActions()
        stopBubbleAnimation()
        focusRecoveryJob?.cancel()
        focusRecoveryJob = null
        keyboardProbe?.detach()
        keyboardProbe = null
    }

    /** The probe saw the keyboard appear or leave: refresh at once, no coalescing. */
    private fun onKeyboardProbeChanged() {
        if (isServiceDestroyed) return
        overlayRefreshJob?.cancel()
        overlayRefreshJob = null
        refreshOverlayVisibility(null)
        scheduleFocusRecoveryIfNeeded()
    }

    /**
     * Whether the keyboard is showing: the probe window when it has proven itself on this
     * device, else the accessibility window list.
     */
    private fun isKeyboardVisible(): Boolean {
        val probe = keyboardProbe
        // The permission can be granted after the service connected; attach lazily.
        if (probe != null && !probe.isAttached) probe.attach()
        return probe?.keyboardVisible ?: (inputMethodBounds() != null)
    }

    private fun refreshOverlayVisibility(source: AccessibilityNodeInfo?) {
        if (isServiceDestroyed) return
        // Resolve the focused field once per pass; the bubble and the wand both decide
        // from the same node.
        val node = resolveFocusedEditableNode(source)
        val keyboardVisible = isKeyboardVisible()
        if (shouldShowBubble(source, node, keyboardVisible)) {
            bubbleShouldBeVisible = true
            showBubble()
            // IME window-list updates can arrive after the accessibility event.
            // Reposition only when fresh keyboard bounds are available.
            if (keyboardVisible) updateBubblePosition()
            // The panel follows the keyboard in both directions, including when it hides.
            updateRewritePanelPosition()
            updateCommandActionsVisibility(node)
            return
        }

        scheduleDeferredHide()
    }

    /**
     * Focus and IME visibility reports flap during keyboard animations and
     * accessibility-tree rebuilds. A missing IME window is therefore not a
     * reason to destroy the bubble: the bubble follows the editable target,
     * while the IME only affects its position.
     */
    private fun scheduleDeferredHide() {
        if (!isBubbleAttached && !isCommandActionsAttached && !hasOverlayWorkflow()) {
            bubbleShouldBeVisible = false
            return
        }

        if (pendingHideJob?.isActive == true) return
        // A field that still has focus while the keyboard is gone gets a longer grace
        // period: the IME window in the accessibility list often disappears briefly while
        // it animates or switches. The probe window does not flap, so it needs only the
        // normal debounce.
        val keyboardGone = !isKeyboardVisible()
        val hideDelayMs = when {
            keyboardGone && keyboardProbe?.keyboardVisible != null -> BUBBLE_HIDE_DEBOUNCE_MS
            keyboardGone && resolveFocusedEditableNode(null) != null -> KEYBOARD_HIDE_GRACE_MS
            else -> BUBBLE_HIDE_DEBOUNCE_MS
        }
        pendingHideJob = serviceScope.launch {
            delay(hideDelayMs)
            if (shouldShowBubble(null)) {
                showBubble()
                return@launch
            }

            bubbleShouldBeVisible = false
            if (hasOverlayWorkflow()) cancelOverlayAudio("The target text field was closed")
            hideBubble()
            hideCommandActions()
        }
    }

    private fun cancelPendingHide() {
        pendingHideJob?.cancel()
        pendingHideJob = null
    }

    private fun shouldShowBubble(
        source: AccessibilityNodeInfo?,
        node: AccessibilityNodeInfo? = resolveFocusedEditableNode(source),
        keyboardVisible: Boolean = isKeyboardVisible()
    ): Boolean {
        if (!hasEditableDictationTarget(source, node, keyboardVisible)) return false
        if (isBubbleSuppressed()) return false
        // The IME window may disappear briefly while it animates or switches, so this
        // is never acted on immediately: hides go through scheduleDeferredHide's grace.
        if (!keyboardVisible && bubbleNeedsKeyboard(recordingState, hasOverlayWorkflow(), rewriteSession != null)) {
            return false
        }
        return true
    }

    private fun scheduleFocusRecoveryIfNeeded(force: Boolean = false) {
        if ((!force && !stickyEditableFocusArmed) || isBubbleAttached) return
        if (isBubbleSuppressed()) return
        if (focusRecoveryJob?.isActive == true) return

        focusRecoveryJob = serviceScope.launch {
            repeat(FOCUS_RECOVERY_ATTEMPTS) { attempt ->
                if (isBubbleAttached || isBubbleSuppressed()) return@launch
                if (shouldShowBubble(null)) {
                    refreshOverlayVisibility(null)
                    return@launch
                }
                if (attempt < FOCUS_RECOVERY_ATTEMPTS - 1) {
                    delay(FOCUS_RECOVERY_RETRY_MS)
                }
            }
        }
    }

    /**
     * Editable-focus check with a sticky fallback. WebView-backed fields (LinkedIn,
     * Chrome, in-app browsers) drop FOCUS_INPUT for seconds while their virtual
     * accessibility tree rebuilds, so a failed lookup is not evidence the field was
     * left. Once an eligible field has been seen, the target is considered present while
     * the keyboard is still up. The keyboard closing or a password field taking focus
     * ends the fallback; without that, a bubble that has appeared once would never leave.
     */
    private fun hasEditableDictationTarget(
        source: AccessibilityNodeInfo?,
        node: AccessibilityNodeInfo? = resolveFocusedEditableNode(source),
        keyboardVisible: Boolean = isKeyboardVisible()
    ): Boolean {
        if (node != null) {
            stickyEditableFocusArmed = true
            return true
        }
        if (isPasswordFieldFocused(source) || !keyboardVisible) {
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

    private fun prewarmCapturePath() {
        serviceScope.launch(Dispatchers.Default) {
            kotlinx.coroutines.coroutineScope {
                launch {
                    runCatching { audioProcessingCoordinator.awaitCaptureReadiness() }
                        .onFailure { error ->
                            Log.w(TAG, "Unable to prewarm audio startup recovery", error)
                        }
                }
                launch {
                    runCatching { appPreferences.getInstructionsForApp(null) }
                        .onFailure { error ->
                            Log.w(TAG, "Unable to prewarm context rules", error)
                        }
                }
                launch {
                    runCatching { transcriptionRepository.prewarmCaptureSettings() }
                        .onFailure { error ->
                            Log.w(TAG, "Unable to prewarm transcription settings", error)
                        }
                    transcriptionRepository.prewarmOnDeviceIfEnabled()
                        .onFailure { error ->
                            Log.w(TAG, "Unable to prewarm on-device transcription", error)
                        }
                }
            }
        }
    }

    private fun keyboardTop(): Int {
        return inputMethodBounds()?.top
            ?: keyboardProbe?.keyboardTop
            ?: resources.displayMetrics.heightPixels
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
                    .takeIf { bounds -> isVisibleInputMethodWindow(bounds) }
            }
            .minByOrNull { bounds -> bounds.top }
    }

    /**
     * An input-method window with real bounds is a keyboard on screen. Keyboards are
     * neither active nor focused windows, and many expose no accessibility tree at all
     * (incognito and password modes, floating layouts, some third-party keyboards), so
     * neither of those is evidence either way; asking for the root was a round trip that
     * hid the bubble exactly when such a keyboard was up.
     */
    private fun isVisibleInputMethodWindow(bounds: Rect): Boolean {
        return bounds.height() > 0 && bounds.width() > 0
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
        if (hasOverlayWorkflow()) cancelOverlayAudio("Dictation bubble was hidden")
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

        // The active window answers with a single round trip; try it before fetching
        // the root of every window on screen.
        val activeFocused = rootInActiveWindow?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
        if (activeFocused != null && isEligibleEditableNode(activeFocused)) {
            return activeFocused
        }
        @Suppress("DEPRECATION")
        activeFocused?.recycle()

        // Search across the remaining windows. On foldables (Flip/Fold), the target app
        // might be in a different window type when closed/on cover screen.
        val windows = windows
        for (window in windows) {
            if (window.type in SKIPPED_WINDOW_TYPES) continue
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
            dismissRewritePanel()
            hideCommandActions()
            stopBubbleAnimation()
        }
    }

    private fun ensureBubbleCreated() {
        if (bubbleView != null) return

        bubbleView = OverlayMicButtonView(this).apply {
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            isHapticFeedbackEnabled = true
            setPalette(overlaySurfaceColor(), overlayOnSurfaceColor())
            setState(OverlayMicButtonView.State.Idle)
        }

        val width = currentBubbleWidthPx()
        val height = currentBubbleHeightPx()
        // A position saved with an older window size or margin is pulled back inside the edges.
        val startX = bubblePrefs.getInt(OverlayBubblePreferences.X_KEY, defaultBubbleX())
            .coerceIn(dp(BUBBLE_MARGIN_DP), maxBubbleX(width))
        val startY = bubblePrefs.getInt(OverlayBubblePreferences.Y_KEY, defaultBubbleY())

        bubbleParams = WindowManager.LayoutParams(
            width,
            height,
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

        val containerPadding = dp(COMMAND_ACTION_CONTAINER_PADDING_DP)
        val buttonSize = dp(COMMAND_ACTION_BUTTON_SIZE_DP)
        val label = getString(R.string.overlay_action_edit_with_ai)

        val wand = ImageView(this).apply {
            styleWandButton(this)
            contentDescription = label
            tooltipText = label
            isClickable = true
            isFocusable = true
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
            isHapticFeedbackEnabled = true
            setOnClickListener {
                performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
                openRewritePanel()
            }
        }
        wandButton = wand

        commandActionsView = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(containerPadding, containerPadding, containerPadding, containerPadding)
            clipChildren = false
            clipToPadding = false
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            addView(wand, LinearLayout.LayoutParams(buttonSize, buttonSize))
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
    }

    /**
     * Borderless secondary button: slightly translucent themed surface fill (same as the bubble),
     * themed-black wand icon, standard shadow underneath.
     */
    private fun styleWandButton(view: ImageView) {
        val padding = dp(COMMAND_ACTION_ICON_PADDING_DP)
        val glyph = overlayOnSurfaceColor()
        view.setImageResource(R.drawable.ic_command_mic)
        view.imageTintList = ColorStateList.valueOf(glyph)
        view.scaleType = ImageView.ScaleType.CENTER
        view.setPadding(padding, padding, padding, padding)
        view.elevation = dp(COMMAND_ACTION_ELEVATION_DP).toFloat()
        view.background = circleBackground(
            fillColor = withAlpha(overlaySurfaceColor(), OverlayMicButtonView.SURFACE_ALPHA),
            contentColor = glyph
        )
    }

    private fun circleBackground(fillColor: Int, contentColor: Int): RippleDrawable {
        val content = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(fillColor)
        }
        val mask = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(Color.WHITE)
        }
        val surfaceInset = dp(4)
        return RippleDrawable(
            ColorStateList.valueOf(withAlpha(contentColor, COMMAND_ACTION_RIPPLE_ALPHA)),
            InsetDrawable(content, surfaceInset),
            InsetDrawable(mask, surfaceInset)
        )
    }

    private fun overlaySurfaceColor(): Int = resolveThemeColor(
        android.R.attr.colorBackgroundFloating,
        resolveThemeColor(android.R.attr.colorBackground, 0xFF1A1A1A.toInt())
    )

    /** Themed black for glyphs: the theme's primary text colour made opaque over the surface. */
    private fun overlayOnSurfaceColor(): Int {
        val text = resolveThemeColor(android.R.attr.textColorPrimary, Color.WHITE)
        val surface = overlaySurfaceColor()
        val alpha = Color.alpha(text) / 255f
        fun mix(channel: (Int) -> Int) = (channel(text) * alpha + channel(surface) * (1f - alpha)).toInt().coerceIn(0, 255)
        return Color.rgb(mix(Color::red), mix(Color::green), mix(Color::blue))
    }


    private fun updateCommandActionsVisibility(node: AccessibilityNodeInfo?) {
        if (!isBubbleAttached) {
            hideCommandActions()
            return
        }
        // The wand is mid-absorb into the panel; let that animation finish.
        if (wandAbsorbing) return

        val workflowActive = hasOverlayWorkflow()
        val panelOpen = rewriteSession != null
        // Only inspect the field when the wand could be shown at all.
        val hasSelection = !panelOpen &&
            canStartSelectionCommand(recordingState, workflowActive) &&
            hasSelectedEditableText(node)
        if (shouldShowWandButton(recordingState, workflowActive, hasSelection, panelOpen)) {
            showCommandActions()
        } else {
            hideCommandActions()
        }
    }

    private fun hasSelectedEditableText(node: AccessibilityNodeInfo?): Boolean {
        node ?: return false
        val snapshot = captureEditableTextSnapshot(node)
        if (snapshot.selectionEnd <= snapshot.selectionStart) return false
        return snapshot.text.substring(snapshot.selectionStart, snapshot.selectionEnd).isNotBlank()
    }

    private fun showCommandActions() {
        ensureCommandActionsCreated()
        val actions = commandActionsView ?: return
        val params = commandActionsParams ?: return
        if (!isBubbleAttached) return

        if (isCommandActionsAttached) {
            updateCommandActionsPosition()
            return
        }

        try {
            actions.alpha = 0f
            wandButton?.let(::styleWandButton)
            windowManager.addView(actions, params)
            isCommandActionsAttached = true
            updateCommandActionsPosition()
            actions.post { updateCommandActionsPosition() }
            actions.animate().alpha(1f).setDuration(COMMAND_ACTIONS_FADE_IN_MS).start()
        } catch (e: Exception) {
            actions.alpha = 1f
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
            actions.animate().cancel()
            wandButton?.animate()?.cancel()
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
            selectedColor = overlayOnSurfaceColor(),
            idleColor = idleZoneColor,
            idleTextColor = onSurfaceColor
        )
        setDismissZoneState(
            view = dismissHideZone,
            selected = target == BubbleDismissTarget.Hide,
            selectedColor = overlayOnSurfaceColor(),
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
                            recordingState == OverlayRecordingState.Recording -> Unit
                            else -> {
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

    private fun performRecordingReadyHaptic() {
        val effect = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            HapticFeedbackConstants.CONFIRM
        } else {
            HapticFeedbackConstants.VIRTUAL_KEY
        }
        bubbleView?.performHapticFeedback(effect)
    }

    private fun onBubbleTapped() {
        hideDismissActions()
        when (recordingState) {
            OverlayRecordingState.Idle -> startRecording()
            OverlayRecordingState.Recording -> stopRecording(discard = false)
            OverlayRecordingState.Processing -> Unit
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
            updateRewritePanelPosition()
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

    private suspend fun replaceCurrentSelection(replacement: String): Boolean {
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
        replacement: String,
        requiredDeliveryToken: Long? = null
    ): Boolean {
        val node = acquireInsertTarget() ?: return false
        if (!deliveryAllows(requiredDeliveryToken)) return false
        try {
            val snapshot = captureEditableTextSnapshot(node)
            val selStart = snapshot.selectionStart
            val selEnd = snapshot.selectionEnd
            if (selEnd > selStart) {
                return replaceRange(
                    node,
                    snapshot.text,
                    selStart,
                    selEnd,
                    replacement,
                    requiredDeliveryToken
                )
            }

            val matchStart = snapshot.text.lastIndexOf(targetText)
            if (matchStart >= 0) {
                return replaceRange(
                    node = node,
                    currentText = snapshot.text,
                    start = matchStart,
                    end = matchStart + targetText.length,
                    replacement = replacement,
                    requiredDeliveryToken = requiredDeliveryToken
                )
            }

            return false
        } finally {
        }
    }

    private fun startRecording() {
        if (recordingState != OverlayRecordingState.Idle) return

        // Starting dictation is how the user ignores an open edit panel.
        dismissRewritePanel()
        hideCommandActions()

        val focusedNode = resolveFocusedEditableNode(null)
        if (focusedNode == null && !stickyEditableFocusArmed) {
            Toast.makeText(this, "Focus a text field first", Toast.LENGTH_SHORT).show()
            return
        }
        // focusedNode may be null while a WebView tree rebuilds (sticky focus armed);
        // insert-time acquisition re-resolves with retries.
        dictationTargetNode = focusedNode

        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED
        ) {
            Toast.makeText(this, "Microphone permission is required", Toast.LENGTH_SHORT).show()
            return
        }

        val startSnapshot = focusedNode?.let { captureEditableTextSnapshot(it) }
        val cursorContext = startSnapshot
            ?.text
            ?.take(startSnapshot.selectionStart)
            ?.takeLast(200)
            ?.ifEmpty { null }
        val contextPackageAtStart = lastFocusedPackage

        cancelDeliveryForReplacement()
        val token = overlayWorkflowFence.beginAudio()
        stopRequestedDuringStart = false
        // Show recording immediately. Recorder initialization and settings
        // loading happen asynchronously below and must not present as a
        // processing/loading state to the user.
        recordingState = OverlayRecordingState.Recording
        updateBubbleUi()

        audioWorkflowJob = serviceScope.launch {
            try {
                val contextRules = try {
                        withTimeout(SETTINGS_SNAPSHOT_TIMEOUT_MS) {
                            appPreferences.getInstructionsForApp(contextPackageAtStart)
                        }
                    } catch (error: CancellationException) {
                        if (error is kotlinx.coroutines.TimeoutCancellationException) {
                            Toast.makeText(
                                this@OverlayDictationAccessibilityService,
                                "Your transcription settings could not be loaded. Try again.",
                                Toast.LENGTH_LONG
                            ).show()
                            resetAfterRecording(token)
                            return@launch
                        }
                        throw error
                    } catch (error: Throwable) {
                        Toast.makeText(
                            this@OverlayDictationAccessibilityService,
                            "Your transcription settings could not be loaded. Try again.",
                            Toast.LENGTH_LONG
                        ).show()
                        resetAfterRecording(token)
                        return@launch
                    }
                val started = audioProcessingCoordinator.startCapture(
                    owner = AndroidAudioAttemptOwner.OVERLAY,
                    workflowToken = token,
                    autoStopOnSilence = autoStopOnSilenceEnabled,
                    additionalPrompt = cursorContext,
                    contextRules = contextRules
                )
                if (!ownsAudioPhase(token)) {
                    started.getOrNull()?.let { staleLease ->
                        audioProcessingCoordinator.cancelCapture(
                            AndroidAudioAttemptOwner.OVERLAY,
                            "Dictation was replaced before recording started",
                            expectedLease = staleLease,
                            expectedWorkflowToken = token
                        )
                    }
                    return@launch
                }
                started.onFailure {
                    Toast.makeText(
                        this@OverlayDictationAccessibilityService,
                        R.string.dictation_recording_not_saved,
                        Toast.LENGTH_LONG
                    ).show()
                    resetAfterRecording(token)
                    return@launch
                }
                val lease = started.getOrThrow()
                audioWorkflowLease = lease
                val captureIsCurrent = audioProcessingCoordinator.isCaptureCurrent(
                    AndroidAudioAttemptOwner.OVERLAY,
                    lease
                )
                if (!captureIsCurrent || !ownsAudioPhase(token)) {
                    if (captureIsCurrent) {
                        audioProcessingCoordinator.cancelCapture(
                            AndroidAudioAttemptOwner.OVERLAY,
                            "Dictation was replaced before its UI became active",
                            expectedLease = lease,
                            expectedWorkflowToken = token
                        )
                    }
                    resetAfterRecording(token)
                    return@launch
                }

                recordingState = OverlayRecordingState.Recording
                updateBubbleUi()
                performRecordingReadyHaptic()
                if (stopRequestedDuringStart && ownsAudioPhase(token)) {
                    stopRequestedDuringStart = false
                    stopRecording(discard = false)
                    return@launch
                }
                vadJob?.cancel()
                vadJob = serviceScope.launch {
                    audioProcessingCoordinator.shouldAutoStop.collectLatest { shouldStop ->
                        if (shouldStop && ownsAudioPhase(token) &&
                            recordingState == OverlayRecordingState.Recording
                        ) {
                            stopRecording(discard = false)
                        }
                    }
                }
            } catch (error: CancellationException) {
                if (ownsAudioPhase(token)) {
                    audioProcessingCoordinator.cancelCaptureFromLifecycle(
                        AndroidAudioAttemptOwner.OVERLAY,
                        "Dictation startup was cancelled",
                        expectedLease = audioWorkflowLease,
                        expectedWorkflowToken = token
                    )
                    resetAfterRecording(token)
                }
                throw error
            }
        }
    }

    private fun stopRecording(discard: Boolean) {
        if (recordingState != OverlayRecordingState.Recording) return
        val token = overlayWorkflowFence.currentToken() ?: return
        if (!ownsAudioPhase(token)) return

        // The UI enters Recording before the recorder lease is available so the
        // first tap has no loading state. Preserve stop/cancel semantics during
        // that short initialization window.
        if (audioWorkflowLease == null) {
            stopRequestedDuringStart = true
            if (discard) {
                audioWorkflowJob?.cancel()
                resetAfterRecording(token)
            }
            return
        }

        vadJob?.cancel()
        vadJob = null

        if (discard) {
            audioProcessingCoordinator.cancelCaptureFromLifecycle(
                AndroidAudioAttemptOwner.OVERLAY,
                "Dictation discarded",
                expectedLease = audioWorkflowLease,
                expectedWorkflowToken = token
            )
            resetAfterRecording(token)
            return
        }

        // MediaRecorder.stop() can block while Android finalizes the audio container. Move that
        // work off the accessibility service's main thread and change state first so auto-stop
        // cannot trigger a second stop while finalization is in progress.
        recordingState = OverlayRecordingState.Processing
        updateBubbleUi()

        audioWorkflowJob = serviceScope.launch {
            val finalized = audioProcessingCoordinator.stopCapture(AndroidAudioAttemptOwner.OVERLAY)
                .getOrElse { error ->
                    Log.e(TAG, "Unable to finalize recording", error)
                    Toast.makeText(
                        this@OverlayDictationAccessibilityService,
                        R.string.dictation_recording_not_saved,
                        Toast.LENGTH_LONG
                    ).show()
                    resetAfterRecording(token)
                    return@launch
                }
            audioWorkflowLease = finalized.lease

            if (finalized.durationMs < MIN_RECORDING_MS || !finalized.speechDetected) {
                audioProcessingCoordinator.failBeforeRecognition(
                    finalized,
                    "No speech was heard. The saved audio is available in History."
                )
                Toast.makeText(
                    this@OverlayDictationAccessibilityService,
                    R.string.dictation_no_speech_heard,
                    Toast.LENGTH_LONG
                ).show()
                resetAfterRecording(token)
                return@launch
            }

            val focusedNode = currentDictationNode()
            if (focusedNode == null && !stickyEditableFocusArmed) {
                audioProcessingCoordinator.failBeforeRecognition(
                    finalized,
                    "The target text field was lost. The saved audio is available in History."
                )
                Toast.makeText(
                    this@OverlayDictationAccessibilityService,
                    R.string.dictation_text_field_lost,
                    Toast.LENGTH_LONG
                ).show()
                resetAfterRecording(token)
                return@launch
            }

            try {
                processRecording(finalized, token)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                Log.e(TAG, "Unable to finish dictation", error)
                Toast.makeText(
                    this@OverlayDictationAccessibilityService,
                    R.string.dictation_failed_try_again,
                    Toast.LENGTH_LONG
                ).show()
            } finally {
                resetAfterRecording(token)
            }
        }
    }

    private fun hasOverlayWorkflow(): Boolean =
        overlayWorkflowFence.currentPhase() != ReplaceableDeliveryFence.Phase.IDLE

    private fun ownsAudioPhase(token: Long): Boolean =
        overlayWorkflowFence.ownsAudio(token)

    private fun ownsDelivery(token: Long): Boolean =
        overlayWorkflowFence.ownsDelivery(token)

    private suspend fun beginDeliveryPhase(token: Long): Boolean {
        if (!overlayWorkflowFence.beginDelivery(token)) return false
        val currentJob = kotlin.coroutines.coroutineContext[Job] ?: return false
        audioWorkflowJob = null
        deliveryJob = currentJob
        recordingState = OverlayRecordingState.Idle
        updateBubbleUi()
        refreshOverlayVisibility(null)
        return true
    }

    private fun cancelDeliveryForReplacement() {
        val previous = deliveryJob
        deliveryJob = null
        previous?.cancel(CancellationException("A new dictation replaced the previous delivery"))
    }

    private fun resetAfterRecording(token: Long) {
        if (!overlayWorkflowFence.finish(token)) return
        audioWorkflowJob = null
        deliveryJob = null
        audioWorkflowLease = null
        recordingState = OverlayRecordingState.Idle
        dictationTargetNode = null
        updateBubbleUi()
        refreshOverlayVisibility(null)
    }

    private fun cancelOverlayAudio(reason: String) {
        val token = overlayWorkflowFence.currentToken() ?: return
        val lease = audioWorkflowLease
        val wasAudio = overlayWorkflowFence.currentPhase() == ReplaceableDeliveryFence.Phase.AUDIO
        audioWorkflowJob?.cancel()
        audioWorkflowJob = null
        deliveryJob?.cancel(CancellationException(reason))
        deliveryJob = null
        vadJob?.cancel()
        vadJob = null
        if (wasAudio) {
            audioProcessingCoordinator.cancelCaptureFromLifecycle(
                AndroidAudioAttemptOwner.OVERLAY,
                reason,
                expectedLease = lease,
                expectedWorkflowToken = token
            )
        }
        resetAfterRecording(token)
    }

    private suspend fun processRecording(finalized: FinalizedAndroidCapture, token: Long) {
        val access = checkAccessForFinalizedRecording(finalized)
        access.onFailure { error ->
            audioProcessingCoordinator.failBeforeRecognition(
                finalized,
                error.message ?: "Transcription is not available right now. Your audio was saved."
            )
            Toast.makeText(
                this@OverlayDictationAccessibilityService,
                error.message ?: getString(R.string.usage_limit_reached),
                Toast.LENGTH_LONG
            ).show()
            return
        }

        val contextRules = finalized.transcriptionConfiguration.contextRules

        Log.d(
            "OverlayDictation",
            "Using captured transcription context: " +
                "promptLength=${finalized.transcriptionConfiguration.transcriptionPrompt?.length ?: 0}, " +
                "rulesLength=${contextRules?.length ?: 0}"
        )

        val processed = audioProcessingCoordinator.processRecognition(finalized)
            .getOrElse { e ->
                Log.e("OverlayDictation", "Transcription failed", e)
                Toast.makeText(
                    this@OverlayDictationAccessibilityService,
                    e.message ?: getString(R.string.dictation_transcription_failed),
                    Toast.LENGTH_LONG
                ).show()
                return
            }
        subscriptionRepository.recordUsageClaim(processed.usageClaimId)
        if (!beginDeliveryPhase(token)) return

        // Command detection and execution (separate from transcription)
        val enabledCommands = runCatching {
            withTimeout(SETTINGS_SNAPSHOT_TIMEOUT_MS) { appPreferences.getEnabledCommands() }
        }.getOrDefault(emptyList())
        val result: Result<com.whispermate.aidictation.data.remote.TranscriptionResult> =
            TranscriptionClient.detectAndExecuteCommands(processed.text, lastDictatedText, enabledCommands, contextRules)
        if (!ownsDelivery(token)) return

        val transcription = result.getOrElse { error ->
            if (!ownsDelivery(token)) return
            Log.e(TAG, "Transcription failed", error)
            Toast.makeText(this@OverlayDictationAccessibilityService, "Transcription failed", Toast.LENGTH_SHORT).show()
            return
        }
        if (transcription.text.isBlank()) {
            Toast.makeText(
                this@OverlayDictationAccessibilityService,
                R.string.dictation_no_speech_recognized,
                Toast.LENGTH_LONG
            ).show()
            return
        }

        val finalText = transcription.text
        if (!ownsDelivery(token)) return

        val applied = if (transcription.executedCommand != null) {
            applyCommandResult(finalText, token)
        } else {
            insertDictationText(finalText, token)
        }
        if (!ownsDelivery(token)) return

        if (applied) {
            lastDictatedText = finalText
        } else {
            copyTextForManualPaste(finalText)
            Toast.makeText(
                this@OverlayDictationAccessibilityService,
                R.string.dictation_text_not_inserted,
                Toast.LENGTH_LONG
            ).show()
        }
    }

    private suspend fun checkAccessForFinalizedRecording(
        finalized: FinalizedAndroidCapture
    ): Result<Unit> = try {
        withTimeout(ACCESS_CHECK_TIMEOUT_MS) {
            subscriptionRepository.checkCanTranscribe()
        }
    } catch (error: kotlinx.coroutines.TimeoutCancellationException) {
        Result.failure(IllegalStateException("Access check timed out. Your audio was saved.", error))
    } catch (error: CancellationException) {
        withContext(NonCancellable) {
            audioProcessingCoordinator.failBeforeRecognition(
                finalized,
                "Transcription was cancelled. Your audio was saved."
            )
        }
        throw error
    } catch (error: Throwable) {
        Result.failure(
            IllegalStateException(
                "Transcription access could not be checked. Your audio was saved.",
                error
            )
        )
    }

    private fun deliveryAllows(requiredDeliveryToken: Long?): Boolean =
        requiredDeliveryToken == null || ownsDelivery(requiredDeliveryToken)

    private suspend fun applyCommandResult(
        transformedText: String,
        requiredDeliveryToken: Long? = null
    ): Boolean {
        val node = acquireInsertTarget() ?: return false
        if (!deliveryAllows(requiredDeliveryToken)) return false
        try {
            val snapshot = captureEditableTextSnapshot(node)
            val current = snapshot.text
            val selStart = snapshot.selectionStart
            val selEnd = snapshot.selectionEnd

            if (selEnd > selStart) {
                return replaceRange(
                    node,
                    current,
                    selStart,
                    selEnd,
                    transformedText,
                    requiredDeliveryToken
                )
            }

            if (lastDictatedText.isNotBlank()) {
                val start = current.lastIndexOf(lastDictatedText)
                if (start >= 0) {
                    return replaceRange(
                        node = node,
                        currentText = current,
                        start = start,
                        end = start + lastDictatedText.length,
                        replacement = transformedText,
                        requiredDeliveryToken = requiredDeliveryToken
                    )
                }
            }

            return insertDictationText(transformedText, requiredDeliveryToken)
        } finally {
        }
    }

    private suspend fun insertDictationText(
        text: String,
        requiredDeliveryToken: Long? = null
    ): Boolean {
        val node = acquireInsertTarget() ?: return false
        if (!deliveryAllows(requiredDeliveryToken)) return false
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
            return replaceRange(
                node,
                current,
                selStart,
                selEnd,
                insertText,
                requiredDeliveryToken
            )
        } finally {
        }
    }

    private suspend fun replaceRange(
        node: AccessibilityNodeInfo,
        currentText: String,
        start: Int,
        end: Int,
        replacement: String,
        requiredDeliveryToken: Long? = null
    ): Boolean {
        if (!deliveryAllows(requiredDeliveryToken)) return false
        val safeStart = start.coerceIn(0, currentText.length)
        val safeEnd = end.coerceIn(safeStart, currentText.length)

        val updated = buildString {
            append(currentText.substring(0, safeStart))
            append(replacement)
            append(currentText.substring(safeEnd))
        }

        val setTextAccepted = setNodeText(node, updated)
        if (setTextAccepted && verifyInsertedText(node, updated, requiredDeliveryToken)) {
            if (!deliveryAllows(requiredDeliveryToken)) return false
            val cursor = safeStart + replacement.length
            setNodeSelection(node, cursor, cursor)
            return true
        }

        if (!deliveryAllows(requiredDeliveryToken)) return false

        if (setTextAccepted) {
            // The editor may have applied the action while its accessibility tree is still
            // stale. A second mutation could duplicate the dictation, so leave a clipboard
            // fallback and let the user decide whether a manual paste is needed.
            copyTextForManualPaste(replacement)
            Log.w(TAG, "Target accepted ACTION_SET_TEXT but its result could not be verified")
            return false
        }

        // Editors can occasionally mutate text even when they report that ACTION_SET_TEXT
        // failed. Only try a paste after a fresh compatible snapshot proves that the original
        // text is still present.
        val refreshedText = readCompatibleEditableText(node)
        if (!deliveryAllows(requiredDeliveryToken)) return false
        if (refreshedText != currentText) {
            copyTextForManualPaste(replacement)
            Log.w(TAG, "Target text changed after ACTION_SET_TEXT; skipping paste fallback")
            return false
        }

        var pasteStart = safeStart
        var pasteEnd = safeEnd
        if (currentText.isEmpty()) {
            val rawLen = node.text?.length ?: 0
            if (rawLen > 0) {
                pasteStart = 0
                pasteEnd = rawLen
            }
        }

        return pasteFallback(
            node,
            replacement,
            pasteStart,
            pasteEnd,
            updated,
            requiredDeliveryToken
        )
    }

    private suspend fun readCompatibleEditableText(
        originalNode: AccessibilityNodeInfo
    ): String? {
        repeat(INSERT_VERIFY_ATTEMPTS) { attempt ->
            val candidate = when {
                refreshNode(originalNode) && isEligibleEditableNode(originalNode) -> originalNode
                else -> resolveFocusedEditableNode(null)
            }
            if (candidate != null && isCompatibleInsertTarget(originalNode, candidate)) {
                return captureEditableTextSnapshot(candidate).text
            }
            if (attempt < INSERT_VERIFY_ATTEMPTS - 1) delay(INSERT_VERIFY_RETRY_MS)
        }
        return null
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

    private suspend fun pasteFallback(
        node: AccessibilityNodeInfo,
        text: String,
        start: Int,
        end: Int,
        expectedText: String,
        requiredDeliveryToken: Long? = null
    ): Boolean {
        if (!deliveryAllows(requiredDeliveryToken)) return false
        copyTextForManualPaste(text)

        if (!deliveryAllows(requiredDeliveryToken)) return false
        setNodeSelection(node, start, end)
        val pasteAccepted = node.performAction(AccessibilityNodeInfo.ACTION_PASTE)
        if (!pasteAccepted) return false

        val verified = verifyInsertedText(node, expectedText, requiredDeliveryToken)
        if (!verified) {
            Log.w(TAG, "Target accepted ACTION_PASTE but did not expose the updated text")
        }
        return verified
    }

    private suspend fun verifyInsertedText(
        originalNode: AccessibilityNodeInfo,
        expectedText: String,
        requiredDeliveryToken: Long? = null
    ): Boolean {
        repeat(INSERT_VERIFY_ATTEMPTS) { attempt ->
            if (!deliveryAllows(requiredDeliveryToken)) return false
            val candidate = when {
                refreshNode(originalNode) && isEligibleEditableNode(originalNode) -> originalNode
                else -> resolveFocusedEditableNode(null)
            }
            if (candidate != null && isCompatibleInsertTarget(originalNode, candidate)) {
                val actualText = captureEditableTextSnapshot(candidate).text
                if (actualText == expectedText) return true
            }
            if (attempt < INSERT_VERIFY_ATTEMPTS - 1) delay(INSERT_VERIFY_RETRY_MS)
        }
        return false
    }

    private fun copyTextForManualPaste(text: String) {
        val clipboard = getSystemService(CLIPBOARD_SERVICE) as ClipboardManager
        clipboard.setPrimaryClip(ClipData.newPlainText(getString(R.string.dictation_clipboard_label), text))
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

    // MARK: - Rewrite panel

    /**
     * Opens the panel from the wand: the wand swells and fades while the panel blooms
     * out of the wand's centre. The selection is captured now; the panel then edits its
     * own working copy until the user applies or closes it.
     */
    private fun openRewritePanel() {
        if (rewriteSession != null || !isBubbleAttached) return
        if (!canStartSelectionCommand(recordingState, hasOverlayWorkflow())) return

        val target = resolveSelectionCommandTarget()
        if (target == null) {
            hideCommandActions()
            return
        }

        val session = RewriteSession(
            originalText = target.selectedText,
            contextBefore = target.contextBefore,
            targetNode = resolveFocusedEditableNode(null),
            workingText = target.selectedText
        )
        rewriteSession = session
        val wandCenter = wandCenterOnScreen()

        val panel = OverlayRewritePanelView(this).apply {
            setText(session.workingText, animate = false)
            onAction = { action -> runRewriteAction(action) }
            onClose = { closeRewritePanel() }
            onApply = { applyRewritePanel() }
        }
        val margin = dp(REWRITE_PANEL_MARGIN_DP)
        val params = WindowManager.LayoutParams(
            (resources.displayMetrics.widthPixels - 2 * margin).coerceAtLeast(margin),
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = margin
            y = margin
            windowAnimations = 0
        }
        rewritePanel = panel
        rewritePanelParams = params
        updateRewritePanelPosition()

        try {
            panel.alpha = 0f
            windowManager.addView(panel, params)
            isRewritePanelAttached = true
        } catch (e: Exception) {
            Log.w(TAG, "Failed to attach rewrite panel overlay", e)
            rewritePanel = null
            rewritePanelParams = null
            rewriteSession = null
            return
        }

        absorbWandButton()
        // Bloom once the panel has a size: the pivot is the wand's centre in panel coordinates.
        panel.viewTreeObserver.addOnPreDrawListener(object : ViewTreeObserver.OnPreDrawListener {
            override fun onPreDraw(): Boolean {
                panel.viewTreeObserver.removeOnPreDrawListener(this)
                if (rewritePanel !== panel) return true
                updateRewritePanelPosition()
                panel.playOpen(
                    pivotX = (wandCenter[0] - params.x).toFloat().coerceIn(0f, panel.width.toFloat()),
                    pivotY = (wandCenter[1] - params.y).toFloat().coerceIn(0f, panel.height.toFloat())
                )
                return true
            }
        })
        announceOverlayState(getString(R.string.overlay_panel_opened))
    }

    private fun wandCenterOnScreen(): IntArray {
        val location = IntArray(2)
        val wand = wandButton
        if (wand != null && isCommandActionsAttached && wand.width > 0) {
            wand.getLocationOnScreen(location)
            location[0] += wand.width / 2
            location[1] += wand.height / 2
        } else {
            val bubble = bubbleParams
            location[0] = (bubble?.x ?: 0) + currentBubbleWidthPx() / 2
            location[1] = (bubble?.y ?: 0) + currentBubbleHeightPx() / 2
        }
        return location
    }

    /** The wand swells and fades as the panel takes over, then its window goes away. */
    private fun absorbWandButton() {
        val wand = wandButton
        if (wand == null || !isCommandActionsAttached) {
            hideCommandActions()
            return
        }
        wandAbsorbing = true
        wand.animate().cancel()
        wand.animate()
            .scaleX(WAND_ABSORB_SCALE)
            .scaleY(WAND_ABSORB_SCALE)
            .alpha(0f)
            .setDuration(WAND_ABSORB_MS)
            .setInterpolator(AccelerateInterpolator())
            .withEndAction {
                wandAbsorbing = false
                hideCommandActions()
                wand.scaleX = 1f
                wand.scaleY = 1f
                wand.alpha = 1f
            }
            .start()
    }

    /** Runs one action on the panel's working text. Actions chain on the current text. */
    private fun runRewriteAction(action: RewriteAction) {
        val session = rewriteSession ?: return
        val panel = rewritePanel ?: return
        if (session.job?.isActive == true) return

        val label = getString(action.labelRes)
        panel.setWorking(action)
        announceOverlayState(getString(R.string.overlay_panel_working, label))
        session.job = serviceScope.launch {
            val result = try {
                transformWorkingText(action, session)
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                Result.failure(error)
            }
            if (rewriteSession !== session || rewritePanel !== panel) return@launch

            val transformed = result.getOrNull()
            if (transformed.isNullOrBlank()) {
                val error = result.exceptionOrNull()
                Log.e(TAG, "Rewrite action $action failed", error)
                Toast.makeText(
                    this@OverlayDictationAccessibilityService,
                    error?.message ?: getString(R.string.overlay_command_failed, label),
                    Toast.LENGTH_SHORT
                ).show()
                panel.setWorking(null)
                return@launch
            }

            session.workingText = transformed
            panel.setWorking(null)
            panel.setText(transformed, animate = true)
            panel.nod(action)
            announceOverlayState(getString(R.string.overlay_panel_updated))
        }
    }

    private suspend fun transformWorkingText(action: RewriteAction, session: RewriteSession): Result<String> {
        subscriptionRepository.checkCanTranscribe().onFailure { error ->
            return Result.failure(IllegalStateException(error.message ?: getString(R.string.usage_limit_reached), error))
        }
        val contextRules = appPreferences.getInstructionsForApp(lastFocusedPackage)
        return when (action) {
            RewriteAction.FixGrammar -> {
                val command = resolveCommand(COMMAND_CLEANUP_ID)
                    ?: return Result.failure(IllegalStateException(getString(R.string.overlay_command_unavailable)))
                CommandClient.execute(
                    command = command,
                    targetText = session.workingText,
                    context = session.contextBefore,
                    additionalInstructions = contextRules
                )
            }
            RewriteAction.Rephrase,
            RewriteAction.Shorter,
            RewriteAction.Longer -> CommandClient.executeInstruction(
                instruction = rewriteInstruction(action),
                targetText = session.workingText,
                context = session.contextBefore,
                additionalInstructions = contextRules
            )
        }
    }

    private fun rewriteInstruction(action: RewriteAction): String = when (action) {
        RewriteAction.FixGrammar -> "Fix grammar, spelling and punctuation. Keep the wording and meaning."
        RewriteAction.Rephrase -> "Rephrase the text naturally. Keep its meaning, tone and roughly its length."
        RewriteAction.Shorter -> "Make the text noticeably shorter while keeping its meaning and tone."
        RewriteAction.Longer -> "Make the text longer by expanding it naturally, keeping its meaning and tone."
    }

    /** Apply: the panel settles towards the field while the working text replaces the selection. */
    private fun applyRewritePanel() {
        val session = rewriteSession ?: return
        val panel = rewritePanel ?: return
        if (session.job?.isActive == true) return
        if (session.workingText == session.originalText) {
            closeRewritePanel()
            return
        }

        rewriteSession = null
        if (isRewritePanelAttached) {
            panel.playApply { removeRewritePanel() }
        } else {
            removeRewritePanel()
        }

        serviceScope.launch {
            dictationTargetNode = session.targetNode
            try {
                val applied = replaceSelectionOrMatchedText(session.originalText, session.workingText)
                if (applied) {
                    lastDictatedText = session.workingText
                    subscriptionRepository.recordWords(session.workingText)
                } else {
                    Toast.makeText(
                        this@OverlayDictationAccessibilityService,
                        R.string.overlay_command_apply_failed,
                        Toast.LENGTH_SHORT
                    ).show()
                }
            } finally {
                if (recordingState == OverlayRecordingState.Idle) dictationTargetNode = null
                refreshOverlayVisibility(null)
            }
        }
    }

    /** Close: wither back towards the wand's place without touching the field. */
    private fun closeRewritePanel() {
        val session = rewriteSession ?: return
        session.job?.cancel()
        rewriteSession = null
        val panel = rewritePanel
        val params = rewritePanelParams
        if (panel == null || params == null || !isRewritePanelAttached) {
            removeRewritePanel()
            refreshOverlayVisibility(null)
            return
        }
        val center = wandCenterOnScreen()
        panel.playClose(
            pivotX = (center[0] - params.x).toFloat().coerceIn(0f, panel.width.toFloat()),
            pivotY = (center[1] - params.y).toFloat().coerceIn(0f, panel.height.toFloat())
        ) {
            removeRewritePanel()
            refreshOverlayVisibility(null)
        }
    }

    /** Immediate teardown, no animation: bubble hidden, dictation starting, service stopping. */
    private fun dismissRewritePanel() {
        rewriteSession?.job?.cancel()
        rewriteSession = null
        removeRewritePanel()
    }

    private fun removeRewritePanel() {
        val panel = rewritePanel
        rewritePanel = null
        rewritePanelParams = null
        panel ?: return
        panel.cancelAnimations()
        if (!isRewritePanelAttached) return
        try {
            windowManager.removeViewImmediate(panel)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to remove rewrite panel overlay", e)
        } finally {
            isRewritePanelAttached = false
        }
    }

    /** Keeps the panel just above the keyboard, or at the bottom of the screen without one. */
    private fun updateRewritePanelPosition() {
        val panel = rewritePanel ?: return
        val params = rewritePanelParams ?: return
        val margin = dp(REWRITE_PANEL_MARGIN_DP)
        val panelHeight = panel.height.takeIf { it > 0 } ?: run {
            panel.measure(
                View.MeasureSpec.makeMeasureSpec(params.width, View.MeasureSpec.EXACTLY),
                View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED)
            )
            panel.measuredHeight
        }
        params.y = (keyboardTop() - panelHeight - margin).coerceAtLeast(margin)
        if (!isRewritePanelAttached) return
        try {
            windowManager.updateViewLayout(panel, params)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to update rewrite panel position", e)
        }
    }

    /**
     * The bubble is hidden from accessibility services, so overlay state changes are
     * announced explicitly.
     */
    private fun announceOverlayState(message: String) {
        // Deprecated in favour of live regions, which need an accessible host view; the
        // bubble deliberately has none, so a one-off announcement is the right tool here.
        @Suppress("DEPRECATION")
        (rewritePanel ?: bubbleView)?.announceForAccessibility(message)
    }

    /** Content colour for an accent-filled surface, matching the app theme. */
    private fun preferredOnColor(backgroundColor: Int): Int {
        fun linearChannel(channel: Int): Double {
            val normalized = channel / 255.0
            return if (normalized <= 0.04045) {
                normalized / 12.92
            } else {
                Math.pow((normalized + 0.055) / 1.055, 2.4)
            }
        }

        val luminance =
            0.2126 * linearChannel(Color.red(backgroundColor)) +
                0.7152 * linearChannel(Color.green(backgroundColor)) +
                0.0722 * linearChannel(Color.blue(backgroundColor))
        // Same rule as the app theme's onColorFor: only light accents get dark content.
        // Choosing by WCAG ratio instead would put black on the default orange, unlike
        // the bubble and every themed screen, which draw white on it.
        return if (luminance > 0.5) Color.BLACK else Color.WHITE
    }

    private fun updateBubbleUi() {
        val bubble = bubbleView ?: return
        bubble.setPalette(overlaySurfaceColor(), overlayOnSurfaceColor())
        // Keep the screen awake while dictation is recording or processing
        bubble.keepScreenOn = recordingState != OverlayRecordingState.Idle

        when (recordingState.bubblePresentation()) {
            OverlayBubblePresentation.Idle -> {
                stopBubbleAnimation()
                bubble.setState(OverlayMicButtonView.State.Idle)
                updateBubbleLayoutSize()
            }

            OverlayBubblePresentation.Recording -> {
                bubble.setState(OverlayMicButtonView.State.Recording)
                updateBubbleLayoutSize()
                startBubbleAnimation()
            }

            OverlayBubblePresentation.Processing -> {
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
            while (recordingState.streamsAudioLevels) {
                bubbleView?.setAudioLevel(audioProcessingCoordinator.audioLevel.value)
                bubbleView?.setFrequencyBands(audioProcessingCoordinator.frequencyBands.value)
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

    private fun defaultBubbleX(): Int = maxBubbleX(dp(BUBBLE_SIZE_DP))

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
