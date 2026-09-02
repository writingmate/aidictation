package com.whispermate.aidictation.service

import android.Manifest
import android.accessibilityservice.AccessibilityService
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ClipboardManager
import android.content.res.ColorStateList
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.drawable.Drawable
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
import android.view.animation.PathInterpolator
import android.widget.FrameLayout
import android.widget.ImageButton
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
import kotlinx.coroutines.withTimeoutOrNull

internal enum class OverlayRecordingState {
    Idle,
    Recording,
    Processing
}

internal enum class OverlayBubblePresentation {
    Idle,
    Recording,
    Processing,
    /** A selection command (Fix grammar / Rewrite with AI) is transforming text. */
    CommandProcessing
}

internal fun OverlayRecordingState.bubblePresentation(): OverlayBubblePresentation =
    resolveBubblePresentation(this, commandActive = false, commandSlideInProgress = false)

/**
 * Bubble presentation invariants:
 * - While a pressed command button is still sliding into the bubble's place the bubble
 *   keeps its idle look, so the button visibly lands on the speak button before the
 *   bubble morphs.
 * - Recording looks the same for dictation and rewrite instructions (cancel / waveform /
 *   accept).
 * - Processing with an active command shows that command's icon plus a progress bar
 *   instead of the dictation spinner.
 */
internal fun resolveBubblePresentation(
    recordingState: OverlayRecordingState,
    commandActive: Boolean,
    commandSlideInProgress: Boolean
): OverlayBubblePresentation {
    if (commandSlideInProgress) return OverlayBubblePresentation.Idle
    return when (recordingState) {
        OverlayRecordingState.Idle -> OverlayBubblePresentation.Idle
        OverlayRecordingState.Recording -> OverlayBubblePresentation.Recording
        OverlayRecordingState.Processing -> if (commandActive) {
            OverlayBubblePresentation.CommandProcessing
        } else {
            OverlayBubblePresentation.Processing
        }
    }
}

internal val OverlayRecordingState.streamsAudioLevels: Boolean
    get() = this == OverlayRecordingState.Recording

internal fun canStartSelectionCommand(
    recordingState: OverlayRecordingState,
    workflowActive: Boolean
): Boolean = recordingState == OverlayRecordingState.Idle && !workflowActive

/**
 * The command buttons are either shown and tappable, or not shown at all: there is no
 * disabled or highlighted button state. They appear only next to an idle bubble, with no
 * dictation delivery in flight, while the focused field has a non-blank selection.
 */
internal fun shouldShowCommandActions(
    recordingState: OverlayRecordingState,
    workflowActive: Boolean,
    hasSelection: Boolean
): Boolean = hasSelection && canStartSelectionCommand(recordingState, workflowActive)

/**
 * Dictation hands the bubble back as soon as transcription finishes so a new dictation
 * can replace the pending insertion. A rewrite keeps the bubble busy until the rewritten
 * text is applied: the command icon and progress bar stay until the selection changes.
 */
internal fun deliveryKeepsBubbleBusy(rewriteInstruction: Boolean): Boolean = rewriteInstruction

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
        private const val BUBBLE_SIZE_DP = 55
        private const val BUBBLE_MARGIN_DP = 20
        private const val BUBBLE_SNOOZE_MS = 10 * 60 * 1000L
        private const val BUBBLE_HIDE_DEBOUNCE_MS = 250L
        private const val FOCUS_RECOVERY_ATTEMPTS = 15
        private const val FOCUS_RECOVERY_RETRY_MS = 200L
        private const val INSERT_RESOLVE_ATTEMPTS = 3
        private const val INSERT_RESOLVE_RETRY_MS = 250L
        private const val INSERT_VERIFY_ATTEMPTS = 5
        private const val INSERT_VERIFY_RETRY_MS = 150L
        private const val BUBBLE_DISMISS_DROP_HEIGHT_DP = 180
        private const val COMMAND_ACTION_HORIZONTAL_MARGIN_DP = 8
        private const val COMMAND_ACTION_GAP_DP = 8
        private const val COMMAND_ACTION_BUTTON_SIZE_DP = 55
        private const val COMMAND_ACTION_CONTAINER_PADDING_DP = 6
        private const val COMMAND_ACTION_ESTIMATED_WIDTH_DP = 130
        private const val COMMAND_ACTION_ESTIMATED_HEIGHT_DP = 67
        private const val COMMAND_ACTION_ICON_PADDING_DP = 15
        private const val COMMAND_ACTION_ELEVATION_DP = 6
        private const val COMMAND_ACTIONS_FADE_IN_MS = 150L
        private const val COMMAND_SLIDE_DURATION_MS = 220L
        private const val DISMISS_ACTION_HEIGHT_DP = 104
        private const val COMMAND_CLEANUP_ID = "cleanup"
        private const val COMMAND_REWRITE_ID = "rewrite"

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
    }

    private enum class RecordingMode {
        Dictation,
        RewriteInstruction
    }

    private enum class CommandAction(val iconRes: Int, val labelRes: Int) {
        FixGrammar(R.drawable.ic_cleanup, R.string.overlay_action_fix_grammar),
        RewriteWithAi(R.drawable.ic_command_mic, R.string.overlay_action_rewrite_ai)
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
    private var recordingMode: RecordingMode = RecordingMode.Dictation
    private val overlayWorkflowFence = ReplaceableDeliveryFence()
    private var audioWorkflowLease: AudioAttemptLease? = null
    private var audioWorkflowJob: Job? = null
    private var deliveryJob: Job? = null
    private var vadJob: Job? = null
    private var autoStopOnSilenceEnabled = false
    private var bubbleAnimationJob: Job? = null
    private var pendingHideJob: Job? = null
    private var focusRecoveryJob: Job? = null
    private var isServiceDestroyed = false
    private var stickyEditableFocusArmed = false
    private var dictationTargetNode: AccessibilityNodeInfo? = null
    private var activeCommandAction: CommandAction? = null
    private var pendingRewriteTarget: SelectionCommandTarget? = null
    private var fixGrammarButton: ImageButton? = null
    private var rewriteButton: ImageButton? = null
    /** Transient window hosting the copy of a pressed command button as it slides into the bubble. */
    private var commandSlideView: View? = null
    private var commandSlideInProgress = false
    private val commandIcons = mutableMapOf<CommandAction, Drawable>()

    /** Single accent colour shared by the bubble and the command buttons. */
    private var bubbleAccentColor: Int = OverlayBubblePreferences.DEFAULT_COLOR
    private var commandChipTextColor: Int = Color.WHITE
    private var commandChipBackgroundColor: Int = OverlayBubblePreferences.DEFAULT_COLOR

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
                    val failedMode = recordingMode
                    Toast.makeText(
                        this@OverlayDictationAccessibilityService,
                        event.message,
                        Toast.LENGTH_LONG
                    ).show()
                    resetAfterRecording(failedMode, failedToken)
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
        if (event.eventType !in TRACKED_EVENT_TYPES) return

        lastFocusedPackage = event.packageName?.toString()
        refreshOverlayVisibility(event.source)
        scheduleFocusRecoveryIfNeeded(force = isPotentialEditableFocusEvent(event))
    }

    override fun onInterrupt() {
        cancelOverlayAudio("Dictation was interrupted")
        dictationTargetNode = null
        cancelCommandSlide()
        hideBubble()
        hideCommandActions()
        hideDismissActions()
        stopBubbleAnimation()
        focusRecoveryJob?.cancel()
        focusRecoveryJob = null
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
        bubbleAccentColor = color
        commandChipTextColor = preferredOnColor(color)
        commandChipBackgroundColor = color
        updateCommandActionButtons()
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
        cancelCommandSlide()
        hideBubble()
        hideCommandActions()
        hideDismissActions()
        stopBubbleAnimation()
        focusRecoveryJob?.cancel()
        focusRecoveryJob = null
        unregisterBubblePreferenceListener()
    }

    private fun refreshOverlayVisibility(source: AccessibilityNodeInfo?) {
        if (isServiceDestroyed) return
        if (shouldShowBubble(source)) {
            bubbleShouldBeVisible = true
            showBubble()
            // IME window-list updates can arrive after the accessibility event.
            // Reposition only when fresh keyboard bounds are available; never
            // remove the bubble just because the IME is temporarily absent.
            if (inputMethodBounds() != null) updateBubblePosition()
            updateCommandActionsVisibility(source)
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
        pendingHideJob = serviceScope.launch {
            delay(BUBBLE_HIDE_DEBOUNCE_MS)
            if (hasEditableDictationTarget(null) && !isBubbleSuppressed()) {
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

    private fun shouldShowBubble(source: AccessibilityNodeInfo?): Boolean {
        // The editable target owns bubble visibility. The IME is an independent
        // window and may disappear briefly while it animates or switches; using
        // it as a hard visibility gate causes the bubble to flicker or vanish.
        if (!hasEditableDictationTarget(source)) return false
        if (isBubbleSuppressed()) return false
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

    private fun isPotentialEditableFocusEvent(event: AccessibilityEvent): Boolean {
        if (
            event.eventType != AccessibilityEvent.TYPE_VIEW_FOCUSED &&
            event.eventType != AccessibilityEvent.TYPE_VIEW_ACCESSIBILITY_FOCUSED &&
            event.eventType != AccessibilityEvent.TYPE_VIEW_CLICKED
        ) {
            return false
        }
        return event.source?.isEditable == true
    }

    /**
     * Editable-focus check with a sticky fallback. WebView-backed fields (LinkedIn,
     * Chrome, in-app browsers) drop FOCUS_INPUT for seconds while their virtual
     * accessibility tree rebuilds, so a failed lookup is not evidence the field was
     * left. Once an eligible field has been seen, the target is considered present while
     * the keyboard catches up, until the keyboard closes or a password field takes focus.
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
            cancelCommandSlide()
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
            setColors(bubbleAccentColor, bubbleAccentColor)
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

        val containerPadding = dp(COMMAND_ACTION_CONTAINER_PADDING_DP)
        val buttonGap = dp(COMMAND_ACTION_GAP_DP)
        val buttonSize = dp(COMMAND_ACTION_BUTTON_SIZE_DP)

        fixGrammarButton = createCommandActionButton(
            action = CommandAction.FixGrammar,
            onClick = { executeSelectionCommand(COMMAND_CLEANUP_ID, CommandAction.FixGrammar) }
        )
        rewriteButton = createCommandActionButton(
            action = CommandAction.RewriteWithAi,
            onClick = { startRewriteInstructionRecording() }
        )

        commandActionsView = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(containerPadding, containerPadding, containerPadding, containerPadding)
            clipChildren = false
            clipToPadding = false
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO

            addView(fixGrammarButton, LinearLayout.LayoutParams(buttonSize, buttonSize))
            addView(rewriteButton, LinearLayout.LayoutParams(
                buttonSize,
                buttonSize
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
        action: CommandAction,
        onClick: () -> Unit
    ): ImageButton {
        val label = getString(action.labelRes)
        return ImageButton(this).apply {
            styleCommandActionImage(this, action)
            contentDescription = label
            tooltipText = label
            minimumWidth = 0
            minimumHeight = 0
            isFocusable = true
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
            isHapticFeedbackEnabled = true
            setOnClickListener {
                performHapticFeedback(HapticFeedbackConstants.CONTEXT_CLICK)
                onClick()
            }
        }
    }

    /**
     * Shared look for a command button and for the copy of it that slides into the
     * bubble, so the two are indistinguishable during the hand-off.
     */
    private fun styleCommandActionImage(view: ImageView, action: CommandAction) {
        val padding = dp(COMMAND_ACTION_ICON_PADDING_DP)
        view.setImageResource(action.iconRes)
        view.imageTintList = ColorStateList.valueOf(commandChipTextColor)
        view.scaleType = ImageView.ScaleType.CENTER
        view.setPadding(padding, padding, padding, padding)
        view.elevation = dp(COMMAND_ACTION_ELEVATION_DP).toFloat()
        view.background = commandActionBackground(commandChipBackgroundColor, commandChipTextColor)
    }

    private fun commandButtonFor(action: CommandAction): ImageButton? = when (action) {
        CommandAction.FixGrammar -> fixGrammarButton
        CommandAction.RewriteWithAi -> rewriteButton
    }

    private fun commandIcon(action: CommandAction): Drawable? {
        return commandIcons.getOrPut(action) {
            val drawable = ContextCompat.getDrawable(this, action.iconRes)?.mutate() ?: return null
            drawable.setTint(Color.WHITE)
            drawable
        }
    }

    private fun commandActionBackground(backgroundColor: Int, rippleColor: Int): RippleDrawable {
        val content = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(backgroundColor)
        }
        val mask = GradientDrawable().apply {
            shape = GradientDrawable.OVAL
            setColor(Color.WHITE)
        }
        val surfaceInset = dp(4)
        return RippleDrawable(
            ColorStateList.valueOf(withAlpha(rippleColor, 0.24f)),
            InsetDrawable(content, surfaceInset),
            InsetDrawable(mask, surfaceInset)
        )
    }

    private fun updateCommandActionsVisibility(source: AccessibilityNodeInfo?) {
        if (!isBubbleAttached || commandSlideInProgress) {
            hideCommandActions()
            return
        }

        val workflowActive = hasOverlayWorkflow()
        // Only inspect the field when the buttons could be shown at all.
        val hasSelection = canStartSelectionCommand(recordingState, workflowActive) &&
            hasSelectedEditableText(source)
        if (shouldShowCommandActions(recordingState, workflowActive, hasSelection)) {
            showCommandActions()
        } else {
            hideCommandActions()
        }
    }

    private fun hasSelectedEditableText(source: AccessibilityNodeInfo?): Boolean {
        val node = resolveFocusedEditableNode(source) ?: return false
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
            actions.alpha = 1f
            updateCommandActionsPosition()
            actions.post { updateCommandActionsPosition() }
            updateCommandActionButtons()
            return
        }

        try {
            actions.alpha = 0f
            windowManager.addView(actions, params)
            isCommandActionsAttached = true
            updateCommandActionsPosition()
            actions.post { updateCommandActionsPosition() }
            updateCommandActionButtons()
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
            selectedColor = bubbleAccentColor,
            idleColor = idleZoneColor,
            idleTextColor = onSurfaceColor
        )
        setDismissZoneState(
            view = dismissHideZone,
            selected = target == BubbleDismissTarget.Hide,
            selectedColor = bubbleAccentColor,
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
            OverlayRecordingState.Idle -> startRecording(mode = RecordingMode.Dictation)
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
        if (!canStartSelectionCommand(recordingState, hasOverlayWorkflow())) return

        val target = resolveSelectionCommandTarget()
        if (target == null) {
            hideCommandActions()
            return
        }

        dictationTargetNode = resolveFocusedEditableNode(null)
        activeCommandAction = action
        recordingMode = RecordingMode.Dictation
        recordingState = OverlayRecordingState.Processing
        slideCommandButtonIntoBubble(action)
        announceCommandState(R.string.overlay_action_fix_grammar_state_active)

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
                recordingState = OverlayRecordingState.Idle
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

    private fun startRewriteInstructionRecording() {
        if (!canStartSelectionCommand(recordingState, hasOverlayWorkflow())) return

        val target = resolveSelectionCommandTarget()
        if (target == null) {
            hideCommandActions()
            return
        }

        pendingRewriteTarget = target
        activeCommandAction = CommandAction.RewriteWithAi
        startRecording(mode = RecordingMode.RewriteInstruction)

        // startRecording clears the command when it cannot start (no field, no mic
        // permission); the buttons then simply stay where they are.
        if (recordingState == OverlayRecordingState.Recording &&
            activeCommandAction == CommandAction.RewriteWithAi
        ) {
            slideCommandButtonIntoBubble(CommandAction.RewriteWithAi)
            announceCommandState(R.string.overlay_action_rewrite_ai_state_listening)
        }
    }

    private fun startRecording(mode: RecordingMode) {
        if (recordingState != OverlayRecordingState.Idle) return

        if (mode == RecordingMode.Dictation) {
            pendingRewriteTarget = null
            activeCommandAction = null
            hideCommandActions()
        }

        val focusedNode = resolveFocusedEditableNode(null)
        if (focusedNode == null && !stickyEditableFocusArmed) {
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

        val startSnapshot = if (mode == RecordingMode.Dictation) {
            focusedNode?.let { captureEditableTextSnapshot(it) }
        } else {
            null
        }
        val cursorContext = startSnapshot
            ?.text
            ?.take(startSnapshot.selectionStart)
            ?.takeLast(200)
            ?.ifEmpty { null }
        val contextPackageAtStart = lastFocusedPackage

        cancelDeliveryForReplacement()
        val token = overlayWorkflowFence.beginAudio()
        recordingMode = mode
        stopRequestedDuringStart = false
        // Show recording immediately. Recorder initialization and settings
        // loading happen asynchronously below and must not present as a
        // processing/loading state to the user.
        recordingState = OverlayRecordingState.Recording
        updateBubbleUi()

        audioWorkflowJob = serviceScope.launch {
            try {
                val contextRules = if (mode == RecordingMode.Dictation) {
                    try {
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
                            resetAfterRecording(mode, token)
                            return@launch
                        }
                        throw error
                    } catch (error: Throwable) {
                        Toast.makeText(
                            this@OverlayDictationAccessibilityService,
                            "Your transcription settings could not be loaded. Try again.",
                            Toast.LENGTH_LONG
                        ).show()
                        resetAfterRecording(mode, token)
                        return@launch
                    }
                } else {
                    null
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
                    resetAfterRecording(mode, token)
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
                    resetAfterRecording(mode, token)
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
                    resetAfterRecording(mode, token)
                }
                throw error
            }
        }
    }

    private fun stopRecording(discard: Boolean) {
        if (recordingState != OverlayRecordingState.Recording) return
        val mode = recordingMode
        val token = overlayWorkflowFence.currentToken() ?: return
        if (!ownsAudioPhase(token)) return

        // The UI enters Recording before the recorder lease is available so the
        // first tap has no loading state. Preserve stop/cancel semantics during
        // that short initialization window.
        if (audioWorkflowLease == null) {
            stopRequestedDuringStart = true
            if (discard) {
                audioWorkflowJob?.cancel()
                resetAfterRecording(mode, token)
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
            resetAfterRecording(mode, token)
            return
        }

        // MediaRecorder.stop() can block while Android finalizes the audio container. Move that
        // work off the accessibility service's main thread and change state first so auto-stop
        // cannot trigger a second stop while finalization is in progress.
        recordingState = OverlayRecordingState.Processing
        updateBubbleUi()
        if (mode == RecordingMode.RewriteInstruction) {
            announceCommandState(R.string.overlay_action_rewrite_ai_state_processing)
        }

        audioWorkflowJob = serviceScope.launch {
            val finalized = audioProcessingCoordinator.stopCapture(AndroidAudioAttemptOwner.OVERLAY)
                .getOrElse { error ->
                    Log.e(TAG, "Unable to finalize recording", error)
                    Toast.makeText(
                        this@OverlayDictationAccessibilityService,
                        R.string.dictation_recording_not_saved,
                        Toast.LENGTH_LONG
                    ).show()
                    resetAfterRecording(mode, token)
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
                    if (mode == RecordingMode.RewriteInstruction) {
                        R.string.overlay_command_no_instruction
                    } else {
                        R.string.dictation_no_speech_heard
                    },
                    Toast.LENGTH_LONG
                ).show()
                resetAfterRecording(mode, token)
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
                resetAfterRecording(mode, token)
                return@launch
            }

            try {
                when (mode) {
                    RecordingMode.Dictation -> processRecording(finalized, token)
                    RecordingMode.RewriteInstruction -> processRewriteInstructionRecording(
                        finalized = finalized,
                        target = pendingRewriteTarget,
                        token = token
                    )
                }
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
                resetAfterRecording(mode, token)
            }
        }
    }

    private fun hasOverlayWorkflow(): Boolean =
        overlayWorkflowFence.currentPhase() != ReplaceableDeliveryFence.Phase.IDLE

    private fun ownsAudioPhase(token: Long): Boolean =
        overlayWorkflowFence.ownsAudio(token)

    private fun ownsDelivery(token: Long): Boolean =
        overlayWorkflowFence.ownsDelivery(token)

    private suspend fun beginDeliveryPhase(token: Long, rewriteInstruction: Boolean): Boolean {
        if (!overlayWorkflowFence.beginDelivery(token)) return false
        val currentJob = kotlin.coroutines.coroutineContext[Job] ?: return false
        audioWorkflowJob = null
        deliveryJob = currentJob
        if (!deliveryKeepsBubbleBusy(rewriteInstruction)) {
            recordingState = OverlayRecordingState.Idle
        }
        updateBubbleUi()
        refreshOverlayVisibility(null)
        return true
    }

    private fun cancelDeliveryForReplacement() {
        val previous = deliveryJob
        deliveryJob = null
        previous?.cancel(CancellationException("A new dictation replaced the previous delivery"))
    }

    private fun resetAfterRecording(mode: RecordingMode, token: Long) {
        if (!overlayWorkflowFence.finish(token)) return
        audioWorkflowJob = null
        deliveryJob = null
        audioWorkflowLease = null
        recordingState = OverlayRecordingState.Idle
        dictationTargetNode = null
        if (mode == RecordingMode.RewriteInstruction) {
            activeCommandAction = null
            pendingRewriteTarget = null
        }
        recordingMode = RecordingMode.Dictation
        updateBubbleUi()
        refreshOverlayVisibility(null)
    }

    private fun cancelOverlayAudio(reason: String) {
        val token = overlayWorkflowFence.currentToken() ?: return
        val lease = audioWorkflowLease
        val wasAudio = overlayWorkflowFence.currentPhase() == ReplaceableDeliveryFence.Phase.AUDIO
        val mode = recordingMode
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
        resetAfterRecording(mode, token)
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
        if (!beginDeliveryPhase(token, rewriteInstruction = false)) return

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

    private suspend fun processRewriteInstructionRecording(
        finalized: FinalizedAndroidCapture,
        target: SelectionCommandTarget?,
        token: Long
    ) {
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

        if (target == null) {
            audioProcessingCoordinator.failBeforeRecognition(
                finalized,
                "The selected text was no longer available. Your audio was saved."
            )
            Toast.makeText(
                this@OverlayDictationAccessibilityService,
                R.string.overlay_command_apply_failed,
                Toast.LENGTH_SHORT
            ).show()
            return
        }

        val processing = audioProcessingCoordinator.processRecognition(finalized)
            .getOrElse { error ->
                Log.e(TAG, "Instruction transcription failed", error)
                Toast.makeText(
                    this@OverlayDictationAccessibilityService,
                    error.message ?: "Transcription failed. Your audio is available in History.",
                    Toast.LENGTH_LONG
                ).show()
                return
            }
        subscriptionRepository.recordUsageClaim(processing.usageClaimId)
        if (!beginDeliveryPhase(token, rewriteInstruction = true)) return

        val instruction = processing.text
        if (instruction.isBlank()) {
            Toast.makeText(
                this@OverlayDictationAccessibilityService,
                R.string.overlay_command_no_instruction,
                Toast.LENGTH_SHORT
            ).show()
            return
        }

        val contextRules = appPreferences.getInstructionsForApp(lastFocusedPackage)
        if (!ownsDelivery(token)) return
        val commandResult = CommandClient.executeInstruction(
            instruction = instruction,
            targetText = target.selectedText,
            context = target.contextBefore,
            additionalInstructions = contextRules
        )
        if (!ownsDelivery(token)) return

        val transformed = commandResult.getOrElse { error ->
            if (!ownsDelivery(token)) return
            Log.e(TAG, "Rewrite instruction failed", error)
            Toast.makeText(
                this@OverlayDictationAccessibilityService,
                getString(R.string.overlay_command_failed, getString(R.string.overlay_action_rewrite_ai)),
                Toast.LENGTH_SHORT
            ).show()
            return
        }
        if (transformed.isBlank() || !ownsDelivery(token)) return

        val applied = replaceSelectionOrMatchedText(
            targetText = target.selectedText,
            replacement = transformed,
            requiredDeliveryToken = token
        )
        if (!ownsDelivery(token)) return
        if (!applied) {
            Toast.makeText(
                this@OverlayDictationAccessibilityService,
                R.string.overlay_command_apply_failed,
                Toast.LENGTH_SHORT
            ).show()
        } else {
            lastDictatedText = transformed
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

    /**
     * The buttons have a single visual state. Whether they are tappable is decided by
     * [updateCommandActionsVisibility]: a button that cannot be tapped is not on screen.
     */
    private fun updateCommandActionButtons() {
        fixGrammarButton?.let { styleCommandActionImage(it, CommandAction.FixGrammar) }
        rewriteButton?.let { styleCommandActionImage(it, CommandAction.RewriteWithAi) }
    }

    /**
     * The bubble is hidden from accessibility services, so state changes that used to be
     * exposed as button state descriptions are announced explicitly instead.
     */
    private fun announceCommandState(messageRes: Int) {
        // Deprecated in favour of live regions, which need an accessible host view; the
        // overlay deliberately has none, so a one-off announcement is the right tool here.
        @Suppress("DEPRECATION")
        bubbleView?.announceForAccessibility(getString(messageRes))
    }

    /**
     * Moves a copy of the pressed command button from its position to the bubble's
     * position in a transient, non-touchable overlay window. Both overlay windows clip
     * to their own bounds, so the copy lives in a window that spans both. The real
     * buttons are removed once the copy is on screen and the bubble keeps its idle look
     * until the copy lands; [finishCommandSlide] then applies the busy presentation.
     */
    private fun slideCommandButtonIntoBubble(action: CommandAction) {
        cancelCommandSlide()
        val button = commandButtonFor(action)
        val bubble = bubbleView
        if (button == null || bubble == null || !isCommandActionsAttached || !isBubbleAttached ||
            button.width <= 0 || bubble.width <= 0
        ) {
            hideCommandActions()
            updateBubbleUi()
            return
        }

        val buttonLocation = IntArray(2).also(button::getLocationOnScreen)
        val bubbleLocation = IntArray(2).also(bubble::getLocationOnScreen)
        val shadowPadding = dp(COMMAND_ACTION_CONTAINER_PADDING_DP)
        val left = minOf(buttonLocation[0], bubbleLocation[0]) - shadowPadding
        val top = minOf(buttonLocation[1], bubbleLocation[1]) - shadowPadding
        val right = maxOf(buttonLocation[0] + button.width, bubbleLocation[0] + bubble.width) + shadowPadding
        val bottom = maxOf(buttonLocation[1] + button.height, bubbleLocation[1] + bubble.height) + shadowPadding

        val ghost = ImageView(this).apply {
            styleCommandActionImage(this, action)
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }
        val container = FrameLayout(this).apply {
            clipChildren = false
            clipToPadding = false
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            addView(
                ghost,
                FrameLayout.LayoutParams(button.width, button.height).apply {
                    leftMargin = buttonLocation[0] - left
                    topMargin = buttonLocation[1] - top
                }
            )
        }
        val params = WindowManager.LayoutParams(
            right - left,
            bottom - top,
            WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = left
            y = top
            windowAnimations = 0
        }

        try {
            windowManager.addView(container, params)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to attach command slide overlay", e)
            hideCommandActions()
            updateBubbleUi()
            return
        }
        commandSlideView = container
        commandSlideInProgress = true
        updateBubbleUi()
        // Swap the real button for its copy only once the copy has been drawn.
        container.post { hideCommandActions() }

        ghost.animate()
            .translationX((bubbleLocation[0] - buttonLocation[0]).toFloat())
            .translationY((bubbleLocation[1] - buttonLocation[1]).toFloat())
            .setDuration(COMMAND_SLIDE_DURATION_MS)
            .setInterpolator(PathInterpolator(0.4f, 0f, 0.2f, 1f))
            .withEndAction { finishCommandSlide() }
            .start()
    }

    private fun finishCommandSlide() {
        if (!commandSlideInProgress) return
        commandSlideInProgress = false
        removeCommandSlideView()
        updateBubbleUi()
        refreshOverlayVisibility(null)
    }

    private fun cancelCommandSlide() {
        commandSlideInProgress = false
        removeCommandSlideView()
    }

    private fun removeCommandSlideView() {
        val view = commandSlideView ?: return
        commandSlideView = null
        try {
            windowManager.removeViewImmediate(view)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to remove command slide overlay", e)
        }
    }

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
        val whiteContrast = 1.05 / (luminance + 0.05)
        val blackContrast = (luminance + 0.05) / 0.05
        return if (whiteContrast >= blackContrast) Color.WHITE else Color.BLACK
    }

    private fun updateBubbleUi() {
        val bubble = bubbleView ?: return
        bubble.setColors(bubbleAccentColor, bubbleAccentColor)
        bubble.setCommandIcon(activeCommandAction?.let(::commandIcon))
        // Keep the screen awake while dictation is recording or processing
        bubble.keepScreenOn = recordingState != OverlayRecordingState.Idle

        val presentation = resolveBubblePresentation(
            recordingState = recordingState,
            commandActive = activeCommandAction != null,
            commandSlideInProgress = commandSlideInProgress
        )
        when (presentation) {
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

            OverlayBubblePresentation.CommandProcessing -> {
                stopBubbleAnimation()
                bubble.setState(OverlayMicButtonView.State.CommandProcessing)
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
