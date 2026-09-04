package com.whispermate.aidictation.telemetry

import android.app.Application
import com.whispermate.aidictation.BuildConfig
import io.sentry.Sentry
import io.sentry.SentryLevel
import io.sentry.android.core.SentryAndroid
import io.sentry.protocol.User

/** Initializes Sentry crash reporting and captures high-value handled failures. */
object SentryTelemetry {
    private const val DEFAULT_DSN =
        "https://83e30144be9d9cdf212136edc6962f26@o4505732389470208.ingest.us.sentry.io/4512029576921088"
    private const val TRACES_SAMPLE_RATE = 0.05

    @Volatile
    private var started = false

    fun start(application: Application) {
        if (started) return

        val dsn = BuildConfig.SENTRY_DSN.ifBlank { DEFAULT_DSN }
        if (dsn.isBlank()) return

        SentryAndroid.init(application) { options ->
            options.dsn = dsn
            options.environment = if (BuildConfig.DEBUG) "debug" else "production"
            options.release =
                "${application.packageName}@${BuildConfig.VERSION_NAME}+${BuildConfig.VERSION_CODE}"
            options.maxBreadcrumbs = 100
            options.isEnableAutoSessionTracking = true
            options.tracesSampleRate = TRACES_SAMPLE_RATE
            options.setDiagnosticLevel(SentryLevel.WARNING)
            options.sessionReplay.sessionSampleRate = 0.0
            options.sessionReplay.onErrorSampleRate = 0.0
        }

        Sentry.configureScope { scope ->
            scope.setTag("platform", "android")
            scope.setTag("app.bundle_id", application.packageName)
        }
        started = true
        Sentry.addBreadcrumb("sentry_started")
    }

    fun captureError(message: String, context: String? = null, feature: String? = null) {
        if (!started || message.isBlank()) return
        Sentry.captureMessage(context?.let { "[$it] $message" } ?: message) { scope ->
            applyTags(scope, context, feature)
        }
    }

    fun captureException(error: Throwable, context: String? = null, feature: String? = null) {
        if (!started) return
        Sentry.captureException(error) { scope ->
            applyTags(scope, context, feature)
        }
    }

    fun setUser(userId: String?) {
        if (!started) return
        Sentry.setUser(userId?.takeIf { it.isNotBlank() }?.let { User().apply { id = it } })
    }

    private fun applyTags(
        scope: io.sentry.IScope,
        context: String?,
        feature: String?
    ) {
        scope.setTag("platform", "android")
        scope.setTag("feature", feature ?: featureName(context))
        if (!context.isNullOrBlank()) {
            scope.setTag("error.context", context)
        }
    }

    private fun featureName(context: String?): String {
        val lowered = context.orEmpty().lowercase()
        return when {
            "auth" in lowered || "sign" in lowered || "session" in lowered -> "auth"
            "transcri" in lowered || "audio" in lowered -> "transcription"
            "insert" in lowered || "clipboard" in lowered || "paste" in lowered -> "text_insert"
            context.isNullOrBlank() -> "app"
            else -> context
        }
    }
}
