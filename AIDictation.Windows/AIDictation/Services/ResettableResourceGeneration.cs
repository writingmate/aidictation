using System;
using System.Threading;

namespace AIDictation.Services;

/// <summary>
/// Gives each logical generation its own disposable native resource. Reset
/// immediately routes new callers to a fresh generation while an abandoned
/// caller may finish against its retired resource without touching the retry.
/// </summary>
public sealed class ResettableResourceGeneration<T> : IDisposable where T : class, IDisposable
{
    internal sealed class Generation
    {
        public required Lazy<T> Resource;
        public int References;
        public bool Retired;
    }

    public sealed class Lease : IDisposable
    {
        private ResettableResourceGeneration<T>? _owner;
        private Generation? _generation;

        internal Lease(ResettableResourceGeneration<T> owner, Generation generation)
        {
            _owner = owner;
            _generation = generation;
        }

        public T Resource
        {
            get
            {
                var owner = _owner ?? throw new ObjectDisposedException(nameof(Lease));
                var generation = _generation ?? throw new ObjectDisposedException(nameof(Lease));
                try
                {
                    // Factory/native setup runs outside the generation lock, so
                    // Reset and a new retry can proceed if this call stalls.
                    return generation.Resource.Value;
                }
                catch
                {
                    owner.RetireFailedGeneration(generation);
                    throw;
                }
            }
        }

        public void Dispose()
        {
            var owner = Interlocked.Exchange(ref _owner, null);
            var generation = Interlocked.Exchange(ref _generation, null);
            if (owner != null && generation != null) owner.Release(generation);
        }
    }

    private readonly object _lock = new();
    private readonly Func<T> _factory;
    private Generation? _current;
    private bool _disposed;

    public ResettableResourceGeneration(Func<T> factory)
    {
        _factory = factory;
    }

    public Lease Acquire()
    {
        lock (_lock)
        {
            if (_disposed) throw new ObjectDisposedException(nameof(ResettableResourceGeneration<T>));
            _current ??= new Generation
            {
                Resource = new Lazy<T>(_factory, LazyThreadSafetyMode.ExecutionAndPublication)
            };
            _current.References++;
            return new Lease(this, _current);
        }
    }

    public void Reset()
    {
        T? dispose = null;
        lock (_lock)
        {
            if (_current == null) return;
            _current.Retired = true;
            if (_current.References == 0 && _current.Resource.IsValueCreated)
                dispose = _current.Resource.Value;
            _current = null;
        }
        dispose?.Dispose();
    }

    private void Release(Generation generation)
    {
        T? dispose = null;
        lock (_lock)
        {
            generation.References--;
            if (generation.References == 0 && generation.Retired && generation.Resource.IsValueCreated)
                dispose = generation.Resource.Value;
        }
        dispose?.Dispose();
    }

    private void RetireFailedGeneration(Generation generation)
    {
        lock (_lock)
        {
            generation.Retired = true;
            if (ReferenceEquals(_current, generation)) _current = null;
        }
    }

    public void Dispose()
    {
        lock (_lock)
        {
            if (_disposed) return;
            _disposed = true;
        }
        Reset();
    }
}
