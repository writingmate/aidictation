using System;
using System.Collections.Generic;

namespace AIDictation.Services;

/// <summary>
/// Arms a one-shot reset for one exact terminal state generation. Disarming,
/// re-arming, or observing a different current state invalidates an old timer.
/// </summary>
public sealed class TerminalStateResetFence<TState> where TState : notnull
{
    public readonly record struct Token(long Generation, TState State);

    private readonly object _lock = new();
    private long _generation;
    private Token? _armed;

    public Token Arm(TState state)
    {
        lock (_lock)
        {
            var token = new Token(++_generation, state);
            _armed = token;
            return token;
        }
    }

    public void Disarm()
    {
        lock (_lock)
        {
            _generation++;
            _armed = null;
        }
    }

    public bool TryConsume(Token token, TState currentState)
    {
        lock (_lock)
        {
            if (_armed != token) return false;
            _generation++;
            _armed = null;
            return EqualityComparer<TState>.Default.Equals(token.State, currentState);
        }
    }
}
