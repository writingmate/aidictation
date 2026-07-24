using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Threading.Tasks;

namespace AIDictation.Services;

public sealed record NativeCloseRegistration<T>(
    T Resource,
    Task Completion,
    bool OwnsClose)
    where T : class;

public sealed record NativeShutdownSnapshot<T>(
    NativeCloseRegistration<T>? Current,
    IReadOnlyList<Task> CloseTasks)
    where T : class;

/// <summary>
/// Atomically transfers a native resource from current ownership into a
/// tracked retired-close slot. Shutdown snapshots can therefore never observe
/// the gap between clearing "current" and registering its eventual close.
/// </summary>
public sealed class RetiredNativeCloseRegistry<T> where T : class
{
    private sealed class ReferenceComparer : IEqualityComparer<T>
    {
        public static ReferenceComparer Instance { get; } = new();
        public bool Equals(T? x, T? y) => ReferenceEquals(x, y);
        public int GetHashCode(T obj) => RuntimeHelpers.GetHashCode(obj);
    }

    private readonly object _gate = new();
    private readonly Dictionary<T, TaskCompletionSource<bool>> _retired =
        new(ReferenceComparer.Instance);
    private T? _current;
    private bool _shutdown;

    public bool HasCurrent
    {
        get { lock (_gate) return _current != null; }
    }

    public bool TryInstall(T resource)
    {
        lock (_gate)
        {
            if (_shutdown || _current != null) return false;
            _current = resource;
            return true;
        }
    }

    public T? Current
    {
        get { lock (_gate) return _current; }
    }

    public bool IsCurrent(T resource)
    {
        lock (_gate) return ReferenceEquals(_current, resource);
    }

    public NativeCloseRegistration<T>? Retire(T resource)
    {
        lock (_gate)
        {
            if (_retired.TryGetValue(resource, out var existing))
                return new NativeCloseRegistration<T>(
                    resource,
                    existing.Task,
                    OwnsClose: false);
            if (!ReferenceEquals(_current, resource)) return null;

            var completion = NewCompletion();
            // The close placeholder is inserted before current ownership is
            // cleared. No shutdown observer can see neither owner.
            _retired.Add(resource, completion);
            _current = null;
            return new NativeCloseRegistration<T>(
                resource,
                completion.Task,
                OwnsClose: true);
        }
    }

    public NativeShutdownSnapshot<T> BeginShutdown()
    {
        lock (_gate)
        {
            _shutdown = true;
            NativeCloseRegistration<T>? current = null;
            if (_current != null)
            {
                var resource = _current;
                var completion = NewCompletion();
                _retired.Add(resource, completion);
                _current = null;
                current = new NativeCloseRegistration<T>(
                    resource,
                    completion.Task,
                    OwnsClose: true);
            }
            return new NativeShutdownSnapshot<T>(
                current,
                _retired.Values.Select(item => item.Task).ToArray());
        }
    }

    public IReadOnlyList<Task> SnapshotCloseTasks()
    {
        lock (_gate) return _retired.Values.Select(item => item.Task).ToArray();
    }

    public void Complete(T resource)
    {
        TaskCompletionSource<bool>? completion;
        lock (_gate)
        {
            if (!_retired.Remove(resource, out completion)) return;
        }
        completion.TrySetResult(true);
    }

    private static TaskCompletionSource<bool> NewCompletion() =>
        new(TaskCreationOptions.RunContinuationsAsynchronously);
}
