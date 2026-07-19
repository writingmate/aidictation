package com.whispermate.aidictation.data.local

import java.io.File
import java.io.IOException
import java.util.UUID

private const val TEMPORARY_AUDIO_DIRECTORY = ".transcription-work"

/**
 * Owns disposable audio exports. Retirement is synchronized with file creation so cancellation,
 * Delete, and Clear can prevent a late native worker from creating another named file afterward.
 */
internal object ManagedAudioTemporaryFiles {
    private val lock = Any()
    private val activeWorkspaces = linkedSetOf<ManagedAudioTemporaryWorkspace>()

    fun openWorkspace(source: File): ManagedAudioTemporaryWorkspace {
        val recordingDirectory = recordingDirectory(source)
        val workspace = ManagedAudioTemporaryWorkspace(
            directory = File(recordingDirectory, UUID.randomUUID().toString()),
            recordingDirectory = recordingDirectory
        )
        synchronized(lock) {
            activeWorkspaces += workspace
        }
        return workspace
    }

    fun retireAndSweepForSource(source: File): Boolean = synchronized(lock) {
        val recordingDirectory = recordingDirectory(source)
        activeWorkspaces.filter { it.recordingDirectory == recordingDirectory }.forEach {
            it.isActive = false
            activeWorkspaces.remove(it)
        }
        removeRecursively(recordingDirectory).also {
            removeIfEmpty(recordingDirectory.parentFile)
        }
    }

    fun retireAndSweepAll(managedAudioDirectory: File): Boolean = synchronized(lock) {
        val root = temporaryRoot(managedAudioDirectory)
        activeWorkspaces.filter { it.directory.isWithin(root) }.forEach {
            it.isActive = false
            activeWorkspaces.remove(it)
        }
        removeRecursively(root)
    }

    internal fun temporaryRoot(managedAudioDirectory: File): File =
        File(managedAudioDirectory, TEMPORARY_AUDIO_DIRECTORY)

    internal fun recordingDirectory(source: File): File =
        File(temporaryRoot(checkNotNull(source.parentFile)), source.name)

    internal fun createTemporaryFile(
        workspace: ManagedAudioTemporaryWorkspace,
        prefix: String,
        suffix: String
    ): File = synchronized(lock) {
        if (!workspace.isActive || workspace !in activeWorkspaces) {
            throw IOException("The audio export workspace is no longer active")
        }
        if (!workspace.directory.exists() && !workspace.directory.mkdirs()) {
            throw IOException("The audio export workspace could not be created")
        }
        File.createTempFile(prefix, suffix, workspace.directory)
    }

    internal fun retire(workspace: ManagedAudioTemporaryWorkspace): Boolean = synchronized(lock) {
        workspace.isActive = false
        activeWorkspaces.remove(workspace)
        removeRecursively(workspace.directory).also {
            removeIfEmpty(workspace.recordingDirectory)
            removeIfEmpty(workspace.recordingDirectory.parentFile)
        }
    }

    private fun removeRecursively(file: File): Boolean = runCatching {
        !file.exists() || file.deleteRecursively() || !file.exists()
    }.getOrDefault(false)

    private fun removeIfEmpty(directory: File?) {
        if (directory?.isDirectory == true && directory.list()?.isEmpty() == true) {
            directory.delete()
        }
    }

    private fun File.isWithin(parent: File): Boolean {
        val parentPath = parent.absoluteFile.toPath().normalize()
        return absoluteFile.toPath().normalize().startsWith(parentPath)
    }
}

internal class ManagedAudioTemporaryWorkspace internal constructor(
    internal val directory: File,
    internal val recordingDirectory: File
) {
    @Volatile internal var isActive: Boolean = true

    fun createTemporaryFile(prefix: String, suffix: String): File =
        ManagedAudioTemporaryFiles.createTemporaryFile(this, prefix, suffix)

    fun retire(): Boolean = ManagedAudioTemporaryFiles.retire(this)
}
