package com.whispermate.aidictation.data.local

import android.content.Context
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.Paths

/**
 * Resolves durable audio only below the OS-provided files directory. Persisted paths are decoded
 * data, not authority: every operation compares the exact lexical path and inspects each
 * app-owned descendant without following links.
 */
internal class ManagedAudioSourceFiles(context: Context) {
    private enum class DirectoryState {
        READY,
        MISSING,
        UNSAFE
    }

    private val filesDirectory: Path =
        context.filesDir.toPath().toAbsolutePath().normalize()
    private val audioDirectory: Path = filesDirectory.resolve("audio")
    private val recordingsDirectory: Path = audioDirectory.resolve("recordings")
    private val legacyRecordingsDirectory: Path = filesDirectory.resolve("recordings")

    val managedAudioDirectory: File
        get() = recordingsDirectory.toFile()

    fun sourceForRecording(recordingId: String): File {
        require(recordingId.matches(RECORDING_ID_PATTERN)) { "The recording ID is invalid" }
        return recordingsDirectory.resolve("$recordingId.m4a").toFile()
    }

    /**
     * Creates only the two known owned directories and refuses to reuse any existing output entry.
     * The database row is not written until this succeeds.
     */
    @Throws(IOException::class)
    fun prepareCaptureSource(recordingId: String, encodedPath: String): File {
        val expected = sourceForRecording(recordingId).toPath()
        if (decodeExactAbsolutePath(encodedPath) != expected) {
            throw IOException("The recording source is outside managed storage")
        }
        createManagedDirectories()
        requireMissingEntry(expected)
        return expected.toFile()
    }

    /**
     * Rechecks the caller-provided output immediately before native recording starts.
     */
    @Throws(IOException::class)
    fun requireRecorderTarget(output: File): File {
        val path = decodeExactAbsolutePath(output.path)
            ?: throw IOException("The recording output path is not normalized")
        if (path.parent != recordingsDirectory || !path.fileName.toString().matches(SOURCE_NAME_PATTERN)) {
            throw IOException("The recording output is outside managed storage")
        }
        if (managedDirectoryState() != DirectoryState.READY) {
            throw IOException("The recording directory is unavailable")
        }
        requireMissingEntry(path)
        return path.toFile()
    }

    fun existingCurrentSource(recordingId: String, encodedPath: String): File? {
        val expected = runCatching { sourceForRecording(recordingId).toPath() }.getOrNull()
            ?: return null
        val path = decodeExactAbsolutePath(encodedPath) ?: return null
        if (path != expected || managedDirectoryState() != DirectoryState.READY) return null
        if (!Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS)) return null
        return path.toFile()
    }

    fun visibleSource(recordingId: String, encodedPath: String?): String? {
        val rawPath = encodedPath ?: return null
        existingCurrentSource(recordingId, rawPath)?.let { return it.absolutePath }

        val path = decodeExactAbsolutePath(rawPath) ?: return null
        if (!isExactLegacySource(path) || legacyDirectoryState() != DirectoryState.READY) return null
        return path.toFile().takeIf {
            Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS)
        }?.absolutePath
    }

    /**
     * Unowned decoded paths are forgotten without touching the filesystem. A lexically owned path
     * whose ancestor or final entry is a link/non-file fails closed so its database path remains
     * available for a later safe cleanup.
     */
    fun removePersistedSource(recordingId: String, encodedPath: String): Boolean {
        val path = decodeExactAbsolutePath(encodedPath) ?: return true
        val expectedCurrent = runCatching { sourceForRecording(recordingId).toPath() }.getOrNull()

        return when {
            path == expectedCurrent -> removeCurrentSource(path)
            isExactLegacySource(path) -> removeLegacySource(path)
            else -> true
        }
    }

    fun retireAndSweepAllTemporaryFiles(): Boolean =
        when (managedDirectoryState()) {
            DirectoryState.READY ->
                ManagedAudioTemporaryFiles.retireAndSweepAll(managedAudioDirectory)
            DirectoryState.MISSING -> true
            DirectoryState.UNSAFE -> false
        }

    private fun removeCurrentSource(path: Path): Boolean {
        when (managedDirectoryState()) {
            DirectoryState.UNSAFE -> return false
            DirectoryState.MISSING -> return true
            DirectoryState.READY -> Unit
        }
        when {
            Files.notExists(path, LinkOption.NOFOLLOW_LINKS) -> Unit
            Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS) -> Unit
            else -> return false
        }

        val source = path.toFile()
        val temporaryRemoved = ManagedAudioTemporaryFiles.retireAndSweepForSource(source)
        val markerRemoved = removeDirectEntry(path.resolveSibling("${path.fileName}.finalized"))
        val sourceRemoved = removeDirectEntry(path)
        return temporaryRemoved && markerRemoved && sourceRemoved
    }

    private fun removeLegacySource(path: Path): Boolean {
        when (legacyDirectoryState()) {
            DirectoryState.UNSAFE -> return false
            DirectoryState.MISSING -> return true
            DirectoryState.READY -> Unit
        }
        when {
            Files.notExists(path, LinkOption.NOFOLLOW_LINKS) -> Unit
            Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS) -> Unit
            else -> return false
        }
        return removeDirectEntry(path)
    }

    private fun removeDirectEntry(path: Path): Boolean = runCatching {
        Files.deleteIfExists(path)
        !Files.exists(path, LinkOption.NOFOLLOW_LINKS)
    }.getOrDefault(false)

    @Throws(IOException::class)
    private fun createManagedDirectories() {
        requireTrustedFilesDirectory()
        createDirectoryWithoutLinks(audioDirectory)
        createDirectoryWithoutLinks(recordingsDirectory)
    }

    @Throws(IOException::class)
    private fun requireTrustedFilesDirectory() {
        if (!Files.isDirectory(filesDirectory, LinkOption.NOFOLLOW_LINKS)) {
            throw IOException("The app storage directory is unavailable")
        }
    }

    @Throws(IOException::class)
    private fun createDirectoryWithoutLinks(path: Path) {
        if (!Files.notExists(path, LinkOption.NOFOLLOW_LINKS)) {
            if (!Files.isDirectory(path, LinkOption.NOFOLLOW_LINKS)) {
                throw IOException("The managed audio directory is unavailable")
            }
        } else {
            Files.createDirectory(path)
        }
        if (!Files.isDirectory(path, LinkOption.NOFOLLOW_LINKS)) {
            throw IOException("The managed audio directory is unavailable")
        }
    }

    @Throws(IOException::class)
    private fun requireMissingEntry(path: Path) {
        if (!Files.notExists(path, LinkOption.NOFOLLOW_LINKS)) {
            throw IOException("The recording output already exists")
        }
    }

    private fun managedDirectoryState(): DirectoryState {
        if (!Files.isDirectory(filesDirectory, LinkOption.NOFOLLOW_LINKS)) {
            return DirectoryState.UNSAFE
        }
        val audioState = existingDirectoryState(audioDirectory)
        if (audioState != DirectoryState.READY) return audioState
        return existingDirectoryState(recordingsDirectory)
    }

    private fun legacyDirectoryState(): DirectoryState {
        if (!Files.isDirectory(filesDirectory, LinkOption.NOFOLLOW_LINKS)) {
            return DirectoryState.UNSAFE
        }
        return existingDirectoryState(legacyRecordingsDirectory)
    }

    private fun existingDirectoryState(path: Path): DirectoryState =
        when {
            Files.notExists(path, LinkOption.NOFOLLOW_LINKS) -> DirectoryState.MISSING
            Files.isDirectory(path, LinkOption.NOFOLLOW_LINKS) -> DirectoryState.READY
            else -> DirectoryState.UNSAFE
        }

    private fun isExactLegacySource(path: Path): Boolean =
        path.parent == legacyRecordingsDirectory &&
            path.fileName.toString().matches(LEGACY_SOURCE_NAME_PATTERN)

    private fun decodeExactAbsolutePath(rawPath: String): Path? = runCatching {
        val parsed = Paths.get(rawPath)
        if (!parsed.isAbsolute) return@runCatching null
        val absolute = parsed.toAbsolutePath()
        if (absolute != absolute.normalize() || rawPath != absolute.toString()) {
            return@runCatching null
        }
        absolute
    }.getOrNull()

    private companion object {
        val RECORDING_ID_PATTERN = Regex("[A-Za-z0-9][A-Za-z0-9_-]{0,127}")
        val SOURCE_NAME_PATTERN = Regex("[A-Za-z0-9][A-Za-z0-9_-]{0,127}\\.m4a")
        val LEGACY_SOURCE_NAME_PATTERN = Regex("recording_[0-9]+\\.m4a")
    }
}
