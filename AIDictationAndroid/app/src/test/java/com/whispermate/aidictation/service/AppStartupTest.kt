package com.whispermate.aidictation.service

import android.app.Application
import android.content.pm.ProviderInfo
import io.sentry.android.core.SentryInitProvider
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class AppStartupTest {
    @Test
    fun contentProvidersCanStartBeforeTheApplicationConfiguresTelemetry() {
        val application = RuntimeEnvironment.getApplication()
        val provider = SentryInitProvider()
        provider.attachInfo(application, ProviderInfo().apply {
            authority = "${application.packageName}.SentryInitProvider"
            packageName = application.packageName
        })
        provider.shutdown()
    }
}
