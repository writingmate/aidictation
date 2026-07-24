using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace AIDictation.Services;

public sealed class ManagedAudioPathException : IOException
{
    public ManagedAudioPathException(string message) : base(message) { }
    public ManagedAudioPathException(string message, Exception inner) : base(message, inner) { }
}

/// <summary>
/// Validates app-owned directories a component at a time and refuses every
/// symbolic-link, junction, mount-point, or other reparse-point component.
/// The checks deliberately fail closed before ordinary File/Directory APIs are
/// allowed to touch a managed source or workspace.
/// </summary>
public static class ManagedAudioPathPolicy
{
    public static string Normalize(string path) =>
        Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));

    public static void EnsureDirectoryChain(
        string trustedAnchor,
        string targetDirectory,
        bool create)
    {
        var anchor = Normalize(trustedAnchor);
        var target = Normalize(targetDirectory);
        if (!IsSameOrDescendant(anchor, target))
            throw new ManagedAudioPathException("Managed audio storage escaped its trusted root.");

        EnsureExistingOrdinaryDirectory(anchor);
        if (PathEquals(anchor, target)) return;

        var relative = Path.GetRelativePath(anchor, target);
        var current = anchor;
        foreach (var component in SplitRelative(relative))
        {
            current = Path.Combine(current, component);
            if (!EntryExistsNoFollow(current))
            {
                if (!create)
                    throw new ManagedAudioPathException("Managed audio storage is missing.");
                try
                {
                    Directory.CreateDirectory(current);
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                    throw new ManagedAudioPathException(
                        "Managed audio storage could not be created safely.", ex);
                }
            }
            EnsureExistingOrdinaryDirectory(current);
        }
    }

    public static string EnsureDirectRegularFile(
        string parentDirectory,
        string path,
        bool mustExist)
    {
        var parent = Normalize(parentDirectory);
        var fullPath = Path.GetFullPath(path);
        if (!PathEquals(parent, Path.GetDirectoryName(fullPath) ?? string.Empty))
            throw new ManagedAudioPathException("Managed audio file escaped its owned directory.");
        if (IsReparsePoint(fullPath))
            throw new ManagedAudioPathException("Managed audio file was replaced by a link.");

        var exists = EntryExistsNoFollow(fullPath);
        if (exists && !File.Exists(fullPath))
            throw new ManagedAudioPathException("Managed audio file is not a regular file.");
        if (mustExist && !exists)
            throw new ManagedAudioPathException("Managed audio file is missing.");
        return fullPath;
    }

    public static bool IsReparsePoint(string path)
    {
        try
        {
            if (new FileInfo(path).LinkTarget != null) return true;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or
                                   PlatformNotSupportedException) { }
        try
        {
            if (new DirectoryInfo(path).LinkTarget != null) return true;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or
                                   PlatformNotSupportedException) { }
        try
        {
            return (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
        return false;
    }

    public static bool EntryExistsNoFollow(string path)
    {
        if (IsReparsePoint(path)) return true;
        try
        {
            return File.Exists(path) || Directory.Exists(path);
        }
        catch
        {
            return false;
        }
    }

    public static bool IsSameOrDescendant(string parent, string candidate)
    {
        var normalizedParent = Normalize(parent);
        var normalizedCandidate = Normalize(candidate);
        if (PathEquals(normalizedParent, normalizedCandidate)) return true;
        return normalizedCandidate.StartsWith(
            normalizedParent + Path.DirectorySeparatorChar,
            PathComparison);
    }

    public static bool PathEquals(string first, string second) =>
        string.Equals(Normalize(first), Normalize(second), PathComparison);

    private static void EnsureExistingOrdinaryDirectory(string path)
    {
        if (IsReparsePoint(path))
            throw new ManagedAudioPathException("Managed audio storage contains a link or junction.");
        if (!Directory.Exists(path))
            throw new ManagedAudioPathException("Managed audio storage is not an ordinary directory.");
    }

    private static IEnumerable<string> SplitRelative(string relative) =>
        relative.Split(
            new[] { Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar },
            StringSplitOptions.RemoveEmptyEntries)
            .Where(component => component != ".");

    private static StringComparison PathComparison =>
        OperatingSystem.IsWindows()
            ? StringComparison.OrdinalIgnoreCase
            : StringComparison.Ordinal;
}

/// <summary>
/// One flat, app-owned temporary workspace. Cleanup never recursively follows
/// an unexpected child directory or reparse point.
/// </summary>
public sealed class ManagedAudioWorkspace : IDisposable
{
    private readonly string _trustedAnchor;
    private readonly string _workspacesRoot;
    private int _disposed;

    private ManagedAudioWorkspace(
        string trustedAnchor,
        string workspacesRoot,
        string directoryPath)
    {
        _trustedAnchor = ManagedAudioPathPolicy.Normalize(trustedAnchor);
        _workspacesRoot = ManagedAudioPathPolicy.Normalize(workspacesRoot);
        DirectoryPath = ManagedAudioPathPolicy.Normalize(directoryPath);
    }

    public string DirectoryPath { get; }

    public static ManagedAudioWorkspace CreateDefault(string kind)
    {
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var root = Path.Combine(appData, "AIDictation", "AudioProcessing", "Workspaces");
        return Create(appData, root, kind);
    }

    public static ManagedAudioWorkspace Create(
        string trustedAnchor,
        string workspacesRoot,
        string kind)
    {
        if (string.IsNullOrWhiteSpace(kind) ||
            kind.Any(character => !char.IsAsciiLetterOrDigit(character) && character != '-'))
            throw new ArgumentException("Workspace kind must be a simple product-owned name.", nameof(kind));

        ManagedAudioPathPolicy.EnsureDirectoryChain(trustedAnchor, workspacesRoot, create: true);
        var directory = Path.Combine(workspacesRoot, $"{kind}-{Guid.NewGuid():N}");
        ManagedAudioPathPolicy.EnsureDirectoryChain(workspacesRoot, directory, create: true);
        return new ManagedAudioWorkspace(trustedAnchor, workspacesRoot, directory);
    }

    public string FilePath(string fileName)
    {
        ObjectDisposedException.ThrowIf(_disposed != 0, this);
        if (string.IsNullOrWhiteSpace(fileName) ||
            !string.Equals(fileName, Path.GetFileName(fileName), StringComparison.Ordinal) ||
            fileName is "." or "..")
            throw new ArgumentException("Workspace files must use a direct child name.", nameof(fileName));
        EnsureOwnedDirectory();
        return ManagedAudioPathPolicy.EnsureDirectRegularFile(
            DirectoryPath,
            Path.Combine(DirectoryPath, fileName),
            mustExist: false);
    }

    public void EnsureOwnedDirectory()
    {
        ManagedAudioPathPolicy.EnsureDirectoryChain(
            _trustedAnchor,
            _workspacesRoot,
            create: false);
        ManagedAudioPathPolicy.EnsureDirectoryChain(
            _workspacesRoot,
            DirectoryPath,
            create: false);
    }

    public void Dispose()
    {
        System.Threading.Interlocked.Exchange(ref _disposed, 1);
        // Repeated disposal is also the detached-export completion retry. The
        // first call fences new files; a later call can remove a file that was
        // still open when the deadline fired.
        DeleteFlatWorkspace(_workspacesRoot, DirectoryPath);
    }

    public static void Sweep(
        string trustedAnchor,
        string workspacesRoot)
    {
        ManagedAudioPathPolicy.EnsureDirectoryChain(trustedAnchor, workspacesRoot, create: true);
        foreach (var entry in new DirectoryInfo(workspacesRoot).EnumerateFileSystemInfos())
        {
            if (ManagedAudioPathPolicy.IsReparsePoint(entry.FullName))
            {
                DeleteLinkOnly(entry);
                continue;
            }
            if (entry is DirectoryInfo directory &&
                IsOwnedWorkspaceName(directory.Name))
            {
                DeleteFlatWorkspace(workspacesRoot, directory.FullName);
            }
        }
    }

    private static void DeleteFlatWorkspace(string workspacesRoot, string directoryPath)
    {
        try
        {
            ManagedAudioPathPolicy.EnsureDirectoryChain(
                workspacesRoot,
                directoryPath,
                create: false);
            foreach (var entry in new DirectoryInfo(directoryPath).EnumerateFileSystemInfos())
            {
                if (ManagedAudioPathPolicy.IsReparsePoint(entry.FullName))
                {
                    DeleteLinkOnly(entry);
                    continue;
                }
                if (entry is DirectoryInfo)
                {
                    // Workspaces are intentionally flat. Never recurse into an
                    // unexpected directory that could have been swapped.
                    continue;
                }
                File.Delete(entry.FullName);
            }
            if (!Directory.EnumerateFileSystemEntries(directoryPath).Any())
                Directory.Delete(directoryPath, recursive: false);
        }
        catch
        {
            // A stale ordinary workspace is safe to retry on next launch. The
            // important property here is never following it outside our root.
        }
    }

    private static void DeleteLinkOnly(FileSystemInfo entry)
    {
        try
        {
            if ((entry.Attributes & FileAttributes.Directory) != 0)
                Directory.Delete(entry.FullName, recursive: false);
            else
                File.Delete(entry.FullName);
        }
        catch { }
    }

    private static bool IsOwnedWorkspaceName(string name)
    {
        var separator = name.LastIndexOf('-');
        return separator > 0 &&
               Guid.TryParseExact(name[(separator + 1)..], "N", out _);
    }
}
