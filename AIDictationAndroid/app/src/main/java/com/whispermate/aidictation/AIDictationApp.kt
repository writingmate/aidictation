package com.whispermate.aidictation

import android.app.Application
import android.util.Log
import com.whispermate.aidictation.data.local.ParakeetModelAssets
import com.whispermate.aidictation.data.preferences.ApiConfigManager
import dagger.hilt.android.HiltAndroidApp
import java.io.File
import javax.inject.Inject

@HiltAndroidApp
class AIDictationApp : Application() {
    @Inject lateinit var apiConfigManager: ApiConfigManager

    override fun onCreate() {
        super.onCreate()
        removeStaleInternalParakeetCache()
    }

    private fun removeStaleInternalParakeetCache() {
        val externalDir = File(getExternalFilesDir(null) ?: return, "parakeet")
        val hasExternalModel = listOf(
            ParakeetModelAssets.REQUIRED_ONNX_FILES,
            ParakeetModelAssets.REQUIRED_LITERT_FILES
        ).any { requiredFiles ->
            requiredFiles.all { name ->
                File(externalDir, name).let { it.isFile && it.length() > 0L }
            }
        }
        if (!hasExternalModel) return

        val internalDir = File(filesDir, "parakeet")
        if (!internalDir.exists()) return

        Log.d("AIDictationApp", "Removing stale internal on-device model cache")
        internalDir.deleteRecursively()
    }
}
