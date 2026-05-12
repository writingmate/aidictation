package com.whispermate.aidictation.data.local

import android.content.Context
import android.util.Log
import com.whispermate.aidictation.BuildConfig
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

        val REQUIRED_ONNX_FILES = listOf(
            "nemo128.onnx",
            "encoder-model.int8.onnx",
            "decoder_joint-model.int8.onnx",
            "vocab.txt"
        )

        val REQUIRED_LITERT_FILES = listOf(
            "nemo128.onnx",
            "encoder-model.int8.onnx",
            "decoder_model_float32.tflite",
            "joint_model_float32.tflite",
            "vocab.txt"
        )
    }

    private val assetPackManager: AssetPackManager by lazy {
        AssetPackManagerFactory.getInstance(context)
    }

    suspend fun requireModelDirectory(runtime: ParakeetRuntime = ParakeetRuntime.ONNX): File {
        findExternalModelDirectory(runtime)?.let {
            removeStaleInternalModelDirectory()
            return it
        }

        if (BuildConfig.PACKAGE_OFFLINE_MODELS) {
            runCatching { installBundledModelDirectory(runtime) }
                .onSuccess { return it }
                .onFailure { Log.w(TAG, "Unable to install bundled Parakeet model", it) }
        }

        findInternalModelDirectory(runtime)?.let { return it }

        findAssetPackModelDirectory(runtime)?.let { return it }

        runCatching { requestAssetPack() }
            .onFailure { Log.w(TAG, "Unable to fetch Parakeet asset pack", it) }

        findAssetPackModelDirectory(runtime)?.let { return it }

        return findInternalModelDirectory(runtime)
            ?: throw IllegalStateException(
                "Parakeet ${runtime.displayName} model files are not installed. Install the $PACK_NAME asset pack, build with PACKAGE_OFFLINE_MODELS=true, or push files to ${externalModelDir().absolutePath}."
            )
    }

    private fun findInternalModelDirectory(runtime: ParakeetRuntime): File? {
        return internalModelDir().takeIf { hasRequiredFiles(it, runtime) }
    }

    private fun findExternalModelDirectory(runtime: ParakeetRuntime): File? {
        return externalModelDir().takeIf { hasRequiredFiles(it, runtime) }
    }

    private fun findAssetPackModelDirectory(runtime: ParakeetRuntime): File? {
        return runCatching { assetPackManager.getPackLocation(PACK_NAME)?.assetsPath() }
            .getOrNull()
            ?.let(::File)
            ?.takeIf { hasRequiredFiles(it, runtime) }
    }

    private fun externalModelDir(): File {
        return File(context.getExternalFilesDir(null) ?: context.filesDir, "parakeet")
    }

    private fun internalModelDir(): File = File(context.filesDir, "parakeet")

    private fun hasRequiredFiles(directory: File, runtime: ParakeetRuntime): Boolean {
        return directory.isDirectory && requiredFiles(runtime).all {
            File(directory, it).let { file -> file.isFile && file.length() > 0L }
        }
    }

    private fun requiredFiles(runtime: ParakeetRuntime): List<String> {
        return when (runtime) {
            ParakeetRuntime.ONNX -> REQUIRED_ONNX_FILES
            ParakeetRuntime.LITERT -> REQUIRED_LITERT_FILES
        }
    }

    private fun removeStaleInternalModelDirectory() {
        val internalDir = internalModelDir()
        if (!internalDir.exists()) return
        Log.d(TAG, "Removing stale internal Parakeet model cache at ${internalDir.absolutePath}")
        internalDir.deleteRecursively()
    }

    private fun installBundledModelDirectory(runtime: ParakeetRuntime): File {
        val destination = internalModelDir()
        val files = requiredFiles(runtime)
        if (bundledAssetsMatch(destination, files)) return destination

        Log.d(TAG, "Installing bundled Parakeet ${runtime.displayName} model to ${destination.absolutePath}")
        destination.deleteRecursively()
        destination.mkdirs()

        for (fileName in files) {
            context.assets.open(fileName).use { input ->
                File(destination, fileName).outputStream().use { output ->
                    input.copyTo(output)
                }
            }
        }

        return destination.takeIf { hasRequiredFiles(it, runtime) }
            ?: throw IllegalStateException("Bundled Parakeet ${runtime.displayName} model copy failed.")
    }

    private fun bundledAssetsMatch(directory: File, files: List<String>): Boolean {
        if (!directory.isDirectory) return false
        return files.all { fileName ->
            val destination = File(directory, fileName)
            destination.isFile && destination.length() > 0L && destination.length() == bundledAssetLength(fileName)
        }
    }

    private fun bundledAssetLength(fileName: String): Long {
        return context.assets.openFd(fileName).use { descriptor ->
            descriptor.length
        }
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
