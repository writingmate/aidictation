package com.whispermate.aidictation.review

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.net.Uri
import com.google.android.play.core.review.ReviewManagerFactory
import kotlin.coroutines.resume
import kotlinx.coroutines.suspendCancellableCoroutine

private const val PLAY_PACKAGE = "com.aidictation.app"

/** Opens the Play listing. Used from Settings, never for the automatic prompt. */
fun openPlayListing(context: Context) {
    val market = Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=$PLAY_PACKAGE")).apply {
        setPackage("com.android.vending")
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }
    try {
        context.startActivity(market)
    } catch (_: ActivityNotFoundException) {
        context.startActivity(
            Intent(
                Intent.ACTION_VIEW,
                Uri.parse("https://play.google.com/store/apps/details?id=$PLAY_PACKAGE"),
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )
    }
}

internal fun Context.findActivity(): Activity? {
    var current: Context = this
    while (current is ContextWrapper) {
        if (current is Activity) return current
        current = current.baseContext
    }
    return null
}

/**
 * Asks Play to show its review dialog. Returns false when Play cannot show a
 * flow. The caller decides whether that consumes an attempt.
 */
internal suspend fun launchPlayReview(activity: Activity): Boolean {
    return suspendCancellableCoroutine { continuation ->
        val manager = ReviewManagerFactory.create(activity)
        manager.requestReviewFlow().addOnCompleteListener { task ->
            if (!continuation.isActive) return@addOnCompleteListener
            if (!task.isSuccessful) {
                continuation.resume(false)
                return@addOnCompleteListener
            }
            manager.launchReviewFlow(activity, task.result)
            continuation.resume(true)
        }
    }
}
