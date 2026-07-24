package com.whispermate.aidictation.data.local

import java.io.File
import java.io.IOException
import java.nio.file.FileVisitResult
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.Path
import java.nio.file.SimpleFileVisitor
import java.nio.file.attribute.BasicFileAttributes
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
        val managedAudioDirectory = source.parentFile ?: return@synchronized false
        activeWorkspaces.filter { it.recordingDirectory == recordingDirectory }.forEach {
            it.isActive = false
            activeWorkspaces.remove(it)
        }
        removeRecursively(managedAudioDirectory, recordingDirectory).also {
            removeIfEmpty(recordingDirectory.parentFile)
        }
    }

    fun retireAndSweepAll(managedAudioDirectory: File): Boolean = synchronized(lock) {
        val root = temporaryRoot(managedAudioDirectory)
        activeWorkspaces.filter { it.directory.isWithin(root) }.forEach {
            it.isActive = false
            activeWorkspaces.remove(it)
        }
        removeRecursively(managedAudioDirectory, root)
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
        createOwnedWorkspaceDirectory(workspace)
        File.createTempFile(prefix, suffix, workspace.directory)
    }

    internal fun retire(workspace: ManagedAudioTemporaryWorkspace): Boolean = synchronized(lock) {
        workspace.isActive = false
        activeWorkspaces.remove(workspace)
        val managedAudioDirectory = workspace.recordingDirectory.parentFile?.parentFile
            ?: return@synchronized false
        removeRecursively(managedAudioDirectory, workspace.directory).also {
            removeIfEmpty(workspace.recordingDirectory)
            removeIfEmpty(workspace.recordingDirectory.parentFile)
        }
    }

    /**
     * Deletes only entries beneath the lexical managed root. Every ancestor is inspected without
     * following links first. If a corrupt owned ancestor is itself a link, delete that link and
     * stop; never append descendants through it.
     */
    private fun removeRecursively(managedAudioDirectory: File, file: File): Boolean = runCatching {
        val managedRoot = managedAudioDirectory.toPath().toAbsolutePath().normalize()
        val root = file.toPath().toAbsolutePath().normalize()
        if (!root.startsWith(managedRoot) || root == managedRoot) {
            return@runCatching false
        }
        val managedParent = managedRoot.parent ?: return@runCatching false
        if (Files.notExists(managedParent, LinkOption.NOFOLLOW_LINKS)) return@runCatching true
        if (!Files.isDirectory(managedParent, LinkOption.NOFOLLOW_LINKS)) return@runCatching false
        if (Files.notExists(managedRoot, LinkOption.NOFOLLOW_LINKS)) return@runCatching true
        if (!Files.isDirectory(managedRoot, LinkOption.NOFOLLOW_LINKS)) return@runCatching false

        var current = managedRoot
        for (component in managedRoot.relativize(root)) {
            current = current.resolve(component)
            if (!Files.exists(current, LinkOption.NOFOLLOW_LINKS)) return@runCatching true
            if (Files.isSymbolicLink(current)) {
                Files.deleteIfExists(current)
                return@runCatching !Files.exists(current, LinkOption.NOFOLLOW_LINKS)
            }
            if (current != root && !Files.isDirectory(current, LinkOption.NOFOLLOW_LINKS)) {
                Files.deleteIfExists(current)
                return@runCatching !Files.exists(current, LinkOption.NOFOLLOW_LINKS)
            }
        }

        Files.walkFileTree(root, object : SimpleFileVisitor<Path>() {
            override fun visitFile(path: Path, attributes: BasicFileAttributes): FileVisitResult {
                Files.deleteIfExists(path)
                return FileVisitResult.CONTINUE
            }

            override fun visitFileFailed(path: Path, error: IOException): FileVisitResult {
                throw error
            }

            override fun postVisitDirectory(directory: Path, error: IOException?): FileVisitResult {
                if (error != null) throw error
                Files.deleteIfExists(directory)
                return FileVisitResult.CONTINUE
            }
        })
        !Files.exists(root, LinkOption.NOFOLLOW_LINKS)
    }.getOrDefault(false)

    private fun createOwnedWorkspaceDirectory(workspace: ManagedAudioTemporaryWorkspace) {
        val recordingDirectory = workspace.recordingDirectory
        val temporaryRoot = recordingDirectory.parentFile
            ?: throw IOException("The audio export root is unavailable")
        val managedAudioDirectory = temporaryRoot.parentFile
            ?: throw IOException("The managed audio directory is unavailable")

        requireExistingDirectoryWithoutLinks(managedAudioDirectory.parentFile
            ?: throw IOException("The managed audio parent is unavailable"))
        requireExistingDirectoryWithoutLinks(managedAudioDirectory)
        createDirectoryWithoutLinks(temporaryRoot)
        createDirectoryWithoutLinks(recordingDirectory)
        createDirectoryWithoutLinks(workspace.directory)
    }

    private fun requireExistingDirectoryWithoutLinks(directory: File) {
        val path = directory.toPath()
        if (!Files.isDirectory(path, LinkOption.NOFOLLOW_LINKS)) {
            throw IOException("The managed audio directory is unavailable")
        }
    }

    private fun createDirectoryWithoutLinks(directory: File) {
        val path = directory.toPath()
        if (Files.exists(path, LinkOption.NOFOLLOW_LINKS)) {
            if (!Files.isDirectory(path, LinkOption.NOFOLLOW_LINKS)) {
                throw IOException("The audio export workspace is not a directory")
            }
            return
        }
        Files.createDirectory(path)
    }

    private fun removeIfEmpty(directory: File?) {
        runCatching {
            val path = directory?.toPath() ?: return@runCatching
            if (!Files.isDirectory(path, LinkOption.NOFOLLOW_LINKS)) return@runCatching
            Files.newDirectoryStream(path).use { entries ->
                if (!entries.iterator().hasNext()) Files.deleteIfExists(path)
            }
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
