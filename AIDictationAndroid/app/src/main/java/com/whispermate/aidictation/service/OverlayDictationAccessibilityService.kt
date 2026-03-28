package com.whispermate.aidictation.service

import android.Manifest
import android.accessibilityservice.AccessibilityService
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import androidx.core.content.ContextCompat
import com.whispermate.aidictation.R
import com.squareup.moshi.Moshi
import com.whispermate.aidictation.data.preferences.AppPreferences
import com.whispermate.aidictation.data.remote.CommandClient
import com.whispermate.aidictation.data.remote.TranscriptionClient
import com.whispermate.aidictation.domain.model.Command
import com.whispermate.aidictation.ui.views.CircularMicButtonView
import com.whispermate.aidictation.util.AudioRecorder
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
class OverlayDictationAccessibilityService : AccessibilityService() {

    companion object {
        const val ACTION_START_DICTATION = "com.whispermate.aidictation.action.START_DICTATION"
        private const val TAG = "OverlayDictationSvc"
        private const val BUBBLE_PREFS = "overlay_bubble"
        private const val BUBBLE_X_KEY = "bubble_x"
        private const val BUBBLE_Y_KEY = "bubble_y"
        private const val MIN_RECORDING_MS = 500L
        private const val BUBBLE_SIZE_DP = 44
        private const val BUBBLE_MARGIN_DP = 8
        private const val BUBBLE_VISIBILITY_DELAY_MS = 80L
        private const val BUBBLE_ANIMATION_MS = 140L
        private const val COMMAND_ACTION_HORIZONTAL_MARGIN_DP = 8
        private const val COMMAND_ACTION_GAP_DP = 8
        private const val COMMAND_ACTION_ESTIMATED_WIDTH_DP = 220
        private const val COMMAND_ACTION_ESTIMATED_HEIGHT_DP = 40
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

    private lateinit var appPreferences: AppPreferences
    private val transcriptionRepository by lazy {
        com.whispermate.aidictation.data.repository.TranscriptionRepository(appPreferences)
    }
    private lateinit var windowManager: WindowManager

    private var bubbleView: CircularMicButtonView? = null
    private var bubbleParams: WindowManager.LayoutParams? = null
    private var isBubbleAttached = false
    private var bubbleVisibilityToken = 0L
    private var bubbleShouldBeVisible = false
    private var commandActionsView: LinearLayout? = null
    private var commandActionsParams: WindowManager.LayoutParams? = null
    private var isCommandActionsAttached = false

    private var recordingState: RecordingState = RecordingState.Idle
    private var recordingMode: RecordingMode = RecordingMode.Dictation
    private var audioRecorder: AudioRecorder? = null
    private var vadJob: Job? = null
    private var focusLossJob: Job? = null
    private var bubbleAnimationJob: Job? = null

    private var activeCommandAction: CommandAction? = null
    private var pendingRewriteTarget: SelectionCommandTarget? = null
    private var fixGrammarButton: TextView? = null
    private var rewriteButton: TextView? = null

    private var bubbleIdleColor: Int = 0xFF2196F3.toInt()
    private var bubbleDictationActiveColor: Int = 0xFFFF9500.toInt()
    private var bubbleRewriteActiveColor: Int = 0xFF4F46E5.toInt()
    private var bubbleFixActiveColor: Int = 0xFF0D9488.toInt()
    private var commandChipIdleTextColor: Int = Color.WHITE
    private var commandChipIdleBackgroundColor: Int = 0x24FFFFFF
    private var commandChipFixTextColor: Int = Color.WHITE
    private var commandChipFixBackgroundColor: Int = 0xFF0D9488.toInt()
    private var commandChipRewriteTextColor: Int = Color.WHITE
    private var commandChipRewriteBackgroundColor: Int = 0xFF4F46E5.toInt()

    private var lastFocusedPackage: String? = null
    private var lastDictatedText: String = ""

    private val bubblePrefs by lazy { getSharedPreferences(BUBBLE_PREFS, Context.MODE_PRIVATE) }

    override fun onServiceConnected() {
        super.onServiceConnected()
        appPreferences = AppPreferences(applicationContext, Moshi.Builder().build())
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
        
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
        hideBubble(animated = false)
        hideCommandActions(animated = false)
        stopBubbleAnimation()
    }

    override fun onDestroy() {
        super.onDestroy()
        stopRecording(discard = true)
        hideBubble(animated = false)
        hideCommandActions(animated = false)
        stopBubbleAnimation()
        serviceScope.cancel()
    }

    private fun refreshOverlayVisibility(source: AccessibilityNodeInfo?) {
        focusLossJob?.cancel()
        if (shouldShowBubble(source)) {
            bubbleShouldBeVisible = true
            showBubble()
            updateCommandActionsVisibility(source)
            return
        }

        focusLossJob = serviceScope.launch {
            delay(BUBBLE_VISIBILITY_DELAY_MS)
            if (!shouldShowBubble(null)) {
                bubbleShouldBeVisible = false
                if (recordingState == RecordingState.Recording) {
                    stopRecording(discard = true)
                }
                hideBubble(animated = true)
                hideCommandActions(animated = true)
            } else {
                bubbleShouldBeVisible = true
                showBubble()
                updateCommandActionsVisibility(null)
            }
        }
    }

    private fun shouldShowBubble(source: AccessibilityNodeInfo?): Boolean {
        // We check for eligibility even if keyboard is hidden, 
        // especially for cover screen shortcuts on foldables.
        val focusedNode = resolveFocusedEditableNode(source) ?: return false
        return true
    }

    private fun isInputMethodVisible(): Boolean {
        return windows.any { window ->
            window.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD
        }
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
        return true
    }
    private fun showBubble() {
        ensureBubbleCreated()
        val bubble = bubbleView ?: return
        val params = bubbleParams ?: return

        bubbleShouldBeVisible = true
        val token = ++bubbleVisibilityToken
        bubble.animate().cancel()
        if (isBubbleAttached) {
            bubble.alpha = 1f
            updateCommandActionsPosition()
            updateBubbleUi()
            return
        }

        try {
            bubble.alpha = 0f
            windowManager.addView(bubble, params)
            isBubbleAttached = true
            updateCommandActionsPosition()
            bubble.animate()
                .alpha(1f)
                .setDuration(BUBBLE_ANIMATION_MS)
                .withEndAction {
                    if (token != bubbleVisibilityToken) return@withEndAction
                    bubble.alpha = 1f
                }
                .start()
            updateBubbleUi()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to attach bubble overlay", e)
        }
    }

    private fun hideBubble(animated: Boolean = true) {
        bubbleShouldBeVisible = false
        if (!isBubbleAttached) return
        val bubble = bubbleView ?: return
        val token = ++bubbleVisibilityToken
        bubble.animate().cancel()

        if (!animated) {
            removeBubbleView()
            return
        }

        bubble.animate()
            .alpha(0f)
            .setDuration(BUBBLE_ANIMATION_MS)
            .withEndAction {
                if (token != bubbleVisibilityToken) return@withEndAction
                if (bubbleShouldBeVisible || shouldShowBubble(null)) {
                    showBubble()
                    return@withEndAction
                }
                removeBubbleView()
            }
            .start()
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
            hideCommandActions(animated = false)
            stopBubbleAnimation()
        }
    }

    private fun ensureBubbleCreated() {
        if (bubbleView != null) return

        val size = dp(BUBBLE_SIZE_DP)
        bubbleIdleColor = resolveThemeColor(
            android.R.attr.colorPrimary,
            0xFF2196F3.toInt()
        )
        bubbleDictationActiveColor = resolveThemeColor(
            android.R.attr.colorSecondary,
            0xFFFF9500.toInt()
        )
        bubbleRewriteActiveColor = resolveThemeColor(
            android.R.attr.colorAccent,
            0xFF4F46E5.toInt()
        )
        bubbleFixActiveColor = bubbleDictationActiveColor

        bubbleView = CircularMicButtonView(this).apply {
            elevation = dp(8).toFloat()
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
            setColors(bubbleIdleColor, resolveBubbleActiveColor())
            setState(CircularMicButtonView.State.Idle)
        }

        val startX = bubblePrefs.getInt(BUBBLE_X_KEY, defaultBubbleX())
        val startY = bubblePrefs.getInt(BUBBLE_Y_KEY, defaultBubbleY())

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
            0xFF0D9488.toInt()
        )
        val rewriteAccent = resolveThemeColor(
            android.R.attr.colorAccent,
            0xFF4F46E5.toInt()
        )
        commandChipFixBackgroundColor = withAlpha(fixAccent, 0.9f)
        commandChipFixTextColor = preferredOnColor(commandChipFixBackgroundColor)
        commandChipRewriteBackgroundColor = withAlpha(rewriteAccent, 0.9f)
        commandChipRewriteTextColor = preferredOnColor(commandChipRewriteBackgroundColor)
        bubbleFixActiveColor = fixAccent
        bubbleRewriteActiveColor = rewriteAccent

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
            hideCommandActions(animated = true)
            return
        }

        if (recordingState != RecordingState.Idle) {
            if (activeCommandAction != null) {
                showCommandActions()
            } else {
                hideCommandActions(animated = true)
            }
            updateCommandActionButtons()
            return
        }

        val node = resolveFocusedEditableNode(source)
        if (node == null) {
            hideCommandActions(animated = true)
            return
        }

        val snapshot = captureEditableTextSnapshot(node)

        val hasSelection = snapshot.selectionEnd > snapshot.selectionStart && snapshot.text.isNotBlank()
        if (hasSelection) {
            showCommandActions()
        } else {
            hideCommandActions(animated = true)
        }
        updateCommandActionButtons()
    }

    private fun showCommandActions() {
        ensureCommandActionsCreated()
        val actions = commandActionsView ?: return
        val params = commandActionsParams ?: return
        if (!isBubbleAttached) return

        actions.animate().cancel()
        if (isCommandActionsAttached) {
            actions.alpha = 1f
            updateCommandActionsPosition()
            updateCommandActionButtons()
            return
        }

        try {
            actions.alpha = 0f
            windowManager.addView(actions, params)
            isCommandActionsAttached = true
            updateCommandActionsPosition()
            updateCommandActionButtons()
            actions.animate()
                .alpha(1f)
                .setDuration(BUBBLE_ANIMATION_MS)
                .start()
        } catch (e: Exception) {
            Log.w(TAG, "Failed to attach command actions overlay", e)
        }
    }

    private fun hideCommandActions(animated: Boolean = true) {
        if (!isCommandActionsAttached) return
        val actions = commandActionsView ?: return
        actions.animate().cancel()

        if (!animated) {
            removeCommandActionsView()
            return
        }

        actions.animate()
            .alpha(0f)
            .setDuration(BUBBLE_ANIMATION_MS)
            .withEndAction { removeCommandActionsView() }
            .start()
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

        val leftX = bubble.x - estimatedWidth - margin
        val rightX = bubble.x + dp(BUBBLE_SIZE_DP) + margin
        val maxX = (screenWidth - estimatedWidth - margin).coerceAtLeast(margin)
        val targetX = if (leftX >= margin) leftX else rightX

        val centeredY = bubble.y + (dp(BUBBLE_SIZE_DP) - estimatedHeight) / 2
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
                    }

                    if (dragging) {
                        params.x = downX + deltaX
                        params.y = downY + deltaY
                        updateBubblePosition()
                    }
                    true
                }

                MotionEvent.ACTION_UP -> {
                    if (dragging) {
                        persistBubblePosition(params.x, params.y)
                    } else {
                        onBubbleTapped()
                    }
                    true
                }

                else -> false
            }
        }
    }

    private fun onBubbleTapped() {
        when (recordingState) {
            RecordingState.Idle -> startRecording(mode = RecordingMode.Dictation)
            RecordingState.Recording -> stopRecording(discard = false)
            RecordingState.Processing -> Unit
        }
    }

    private fun updateBubblePosition() {
        if (!isBubbleAttached) return
        val bubble = bubbleView ?: return
        val params = bubbleParams ?: return

        try {
            windowManager.updateViewLayout(bubble, params)
            updateCommandActionsPosition()
        } catch (e: Exception) {
            Log.w(TAG, "Failed to update bubble position", e)
        }
    }

    private fun persistBubblePosition(x: Int, y: Int) {
        bubblePrefs.edit()
            .putInt(BUBBLE_X_KEY, x)
            .putInt(BUBBLE_Y_KEY, y)
            .apply()
    }

    private fun executeSelectionCommand(commandId: String, action: CommandAction) {
        if (recordingState != RecordingState.Idle) return

        val target = resolveSelectionCommandTarget()
        if (target == null) {
            hideCommandActions(animated = true)
            return
        }

        activeCommandAction = action
        recordingMode = RecordingMode.Dictation
        recordingState = RecordingState.Processing
        updateBubbleUi()
        showCommandActions()

        serviceScope.launch {
            try {
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

    private fun replaceSelectionOrMatchedText(
        targetText: String,
        replacement: String
    ): Boolean {
        val node = resolveFocusedEditableNode(null) ?: return false
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
            hideCommandActions(animated = true)
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
            hideCommandActions(animated = true)
        } else {
            showCommandActions()
            updateCommandActionButtons()
        }

        val focusedNode = resolveFocusedEditableNode(null)
        if (focusedNode == null) {
            if (mode == RecordingMode.RewriteInstruction) {
                activeCommandAction = null
                pendingRewriteTarget = null
                updateBubbleUi()
            }
            Toast.makeText(this, "Focus a text field first", Toast.LENGTH_SHORT).show()
            return
        }

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

        val recorder = AudioRecorder(this, enableVAD = true)
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
            return
        }

        val focusedNode = resolveFocusedEditableNode(null)
        if (focusedNode == null) {
            audioFile.delete()
            recordingState = RecordingState.Idle
            if (mode == RecordingMode.RewriteInstruction) {
                activeCommandAction = null
                pendingRewriteTarget = null
            }
            recordingMode = RecordingMode.Dictation
            updateBubbleUi()
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
        val node = resolveFocusedEditableNode(null)
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

        result.onSuccess { transcription ->
            if (transcription.text.isBlank()) return@onSuccess

            val applied = if (transcription.executedCommand != null) {
                applyCommandResult(transcription.text)
            } else {
                insertDictationText(transcription.text)
            }

            if (applied) {
                lastDictatedText = transcription.text
            }
        }.onFailure { error ->
            Log.e(TAG, "Transcription failed", error)
            Toast.makeText(this@OverlayDictationAccessibilityService, "Transcription failed", Toast.LENGTH_SHORT).show()
        }
    }

    private suspend fun processRewriteInstructionRecording(
        audioFile: java.io.File,
        target: SelectionCommandTarget?
    ) {
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

    private fun applyCommandResult(transformedText: String): Boolean {
        val node = resolveFocusedEditableNode(null) ?: return false
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

    private fun insertDictationText(text: String): Boolean {
        val node = resolveFocusedEditableNode(null) ?: return false
        try {
            val snapshot = captureEditableTextSnapshot(node)
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
            val hintNfc = java.text.Normalizer.normalize(hint, java.text.Normalizer.Form.NFC)
            val rawNfc = java.text.Normalizer.normalize(rawText.trim(), java.text.Normalizer.Form.NFC)

            if (rawNfc.equals(hintNfc, ignoreCase = true)) {
                return NormalizedText("", rawText.length)
            }

            val hintPrefixRegex = Regex("^\\Q$hint\\E[\\s\\u00A0]*")
            val hintPrefix = hintPrefixRegex.find(rawText)
            if (hintPrefix != null && hintPrefix.range.first == 0) {
                val prefixLength = hintPrefix.range.last + 1
                return NormalizedText(rawText.substring(prefixLength), prefixLength)
            }
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

        when (recordingState) {
            RecordingState.Idle -> {
                stopBubbleAnimation()
                bubble.setState(CircularMicButtonView.State.Idle)
            }

            RecordingState.Recording -> {
                bubble.setState(CircularMicButtonView.State.Recording)
                startBubbleAnimation()
            }

            RecordingState.Processing -> {
                stopBubbleAnimation()
                bubble.setState(CircularMicButtonView.State.Processing)
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
}
