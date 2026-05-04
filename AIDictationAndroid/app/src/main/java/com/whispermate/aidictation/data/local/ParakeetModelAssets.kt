package com.whispermate.aidictation.data.local

import android.content.Context
import android.util.Log
import com.google.android.gms.tasks.Task
import com.google.android.play.core.assetpacks.AssetPackManager
import com.google.android.play.core.assetpacks.AssetPackManagerFactory
import com.google.android.play.core.assetpacks.AssetPackStateUpdateListener
import com.google.android.play.core.assetpacks.model.AssetPackStatus
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeout
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

@Singleton
class ParakeetModelAssets @Inject constructor(
    @ApplicationContext private val context: Context
) {
    companion object {
        private const val TAG = "ParakeetModelAssets"
        private const val PACK_NAME = "parakeet_v3_pack"

        val REQUIRED_FILES = listOf(
            "nemo128.onnx",
            "encoder-model.int8.onnx",
            "decoder_joint-model.int8.onnx",
            "vocab.txt"
        )
    }

    private val assetPackManager: AssetPackManager by lazy {
        AssetPackManagerFactory.getInstance(context)
    }

    suspend fun requireModelDirectory(): File {
        findExistingModelDirectory()?.let { return it }

        runCatching { requestAssetPack() }
            .onFailure { Log.w(TAG, "Unable to fetch Parakeet asset pack", it) }

        return findExistingModelDirectory()
            ?: throw IllegalStateException(
                "Parakeet model files are not installed. Install the $PACK_NAME asset pack or push files to ${externalModelDir().absolutePath}."
            )
    }

    private fun findExistingModelDirectory(): File? {
        val localDirs = listOf(externalModelDir(), internalModelDir())
        localDirs.firstOrNull { hasRequiredFiles(it) }?.let { return it }

        val packDir = runCatching { assetPackManager.getPackLocation(PACK_NAME)?.assetsPath() }
            .getOrNull()
            ?.let(::File)
        return packDir?.takeIf { hasRequiredFiles(it) }
    }

    private fun externalModelDir(): File {
        return File(context.getExternalFilesDir(null) ?: context.filesDir, "parakeet")
    }

    private fun internalModelDir(): File = File(context.filesDir, "parakeet")

    private fun hasRequiredFiles(directory: File): Boolean {
        return directory.isDirectory && REQUIRED_FILES.all { File(directory, it).isFile }
    }

    private suspend fun requestAssetPack() {
        val states = assetPackManager.fetch(listOf(PACK_NAME)).await()
        when (val status = states.packStates()[PACK_NAME]?.status()) {
            AssetPackStatus.COMPLETED -> return
            AssetPackStatus.FAILED,
            AssetPackStatus.CANCELED,
            AssetPackStatus.WAITING_FOR_WIFI,
            AssetPackStatus.REQUIRES_USER_CONFIRMATION -> {
                throw IllegalStateException("Parakeet asset pack is not available, status=$status")
            }
            else -> withTimeout(10 * 60 * 1000L) {
                awaitPackCompletion()
            }
        }
    }

    private suspend fun awaitPackCompletion() = suspendCancellableCoroutine<Unit> { continuation ->
        lateinit var listener: AssetPackStateUpdateListener
        listener = AssetPackStateUpdateListener { state ->
            if (state.name() != PACK_NAME || !continuation.isActive) return@AssetPackStateUpdateListener
            when (state.status()) {
                AssetPackStatus.COMPLETED -> {
                    assetPackManager.unregisterListener(listener)
                    continuation.resume(Unit)
                }
                AssetPackStatus.FAILED,
                AssetPackStatus.CANCELED,
                AssetPackStatus.WAITING_FOR_WIFI,
                AssetPackStatus.REQUIRES_USER_CONFIRMATION -> {
                    assetPackManager.unregisterListener(listener)
                    continuation.resumeWithException(
                        IllegalStateException("Parakeet asset pack download failed with status ${state.status()}")
                    )
                }
            }
        }
        assetPackManager.registerListener(listener)
        continuation.invokeOnCancellation {
            assetPackManager.unregisterListener(listener)
        }
    }

    private suspend fun <T> Task<T>.await(): T = suspendCancellableCoroutine { continuation ->
        addOnSuccessListener { result ->
            if (continuation.isActive) continuation.resume(result)
        }
        addOnFailureListener { error ->
            if (continuation.isActive) continuation.resumeWithException(error)
        }
        addOnCanceledListener {
            if (continuation.isActive) continuation.cancel()
        }
    }
}
