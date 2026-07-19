using System;
using CommunityToolkit.Mvvm.ComponentModel;

namespace AIDictation.Services;

/// <summary>
/// Central state machine for the application, managing recording states,
/// transcription results, and audio visualization data.
/// </summary>
public partial class AppState : ObservableObject, IAudioAppState
{
    // MARK: - Singleton
    
    private static readonly Lazy<AppState> _instance = new(() => new AppState());
    public static AppState Shared => _instance.Value;
    
    // MARK: - Types
    
    public enum State
    {
        Idle,
        Starting,
        Recording,
        Finalizing,
        Processing,
        Result,
        Error
    }
    
    // MARK: - Constants
    
    private static class Constants
    {
        public const int MaxAudioLevelSamples = 50;
        public const float DefaultAudioLevel = 0f;
    }
    
    // MARK: - Observable Properties
    
    [ObservableProperty]
    private State _currentState = State.Idle;
    
    [ObservableProperty]
    private string _transcriptionText = string.Empty;
    
    [ObservableProperty]
    private TimeSpan _recordingDuration = TimeSpan.Zero;
    
    [ObservableProperty]
    private float _currentAudioLevel = Constants.DefaultAudioLevel;
    
    [ObservableProperty]
    private float _peakAudioLevel = Constants.DefaultAudioLevel;
    
    [ObservableProperty]
    private string _errorMessage = string.Empty;
    
    [ObservableProperty]
    private bool _isCommandMode = false;
    
    // MARK: - Events
    
    public event EventHandler<StateChangedEventArgs>? StateChanged;
    public event EventHandler<float>? AudioLevelUpdated;
    public event EventHandler<string>? TranscriptionCompleted;
    public event EventHandler<string>? ErrorOccurred;
    
    // MARK: - State Change Event Args
    
    public class StateChangedEventArgs : EventArgs
    {
        public State OldState { get; }
        public State NewState { get; }
        
        public StateChangedEventArgs(State oldState, State newState)
        {
            OldState = oldState;
            NewState = newState;
        }
    }
    
    // MARK: - Thread Safety
    
    private readonly object _stateLock = new();
    
    // MARK: - Initialization
    
    private AppState() { }
    
    // MARK: - Public API
    
    /// <summary>
    /// Allocates the UI attempt while the journal and microphone are prepared.
    /// The recording indicator is not shown until the first frame is durable.
    /// </summary>
    public bool StartPreparing(bool isCommandMode = false)
    {
        lock (_stateLock)
        {
            if (CurrentState != State.Idle && CurrentState != State.Result && CurrentState != State.Error)
                return false;
            var oldState = CurrentState;
            IsCommandMode = isCommandMode;
            TranscriptionText = string.Empty;
            ErrorMessage = string.Empty;
            RecordingDuration = TimeSpan.Zero;
            CurrentAudioLevel = Constants.DefaultAudioLevel;
            PeakAudioLevel = Constants.DefaultAudioLevel;
            CurrentState = State.Starting;
            OnStateChanged(oldState, CurrentState);
            return true;
        }
    }

    public bool RecordingBecameReady()
    {
        lock (_stateLock)
        {
            if (CurrentState != State.Starting) return false;
            var oldState = CurrentState;
            CurrentState = State.Recording;
            OnStateChanged(oldState, CurrentState);
            return true;
        }
    }

    /// <summary>
    /// Transitions to the recording state
    /// </summary>
    public bool StartRecording(bool isCommandMode = false)
    {
        lock (_stateLock)
        {
            if (CurrentState != State.Idle && CurrentState != State.Result && CurrentState != State.Error)
                return false;
            
            var oldState = CurrentState;
            IsCommandMode = isCommandMode;
            TranscriptionText = string.Empty;
            ErrorMessage = string.Empty;
            RecordingDuration = TimeSpan.Zero;
            CurrentAudioLevel = Constants.DefaultAudioLevel;
            PeakAudioLevel = Constants.DefaultAudioLevel;
            
            CurrentState = State.Recording;
            OnStateChanged(oldState, CurrentState);
            return true;
        }
    }
    
    /// <summary>
    /// Transitions to the processing state
    /// </summary>
    public bool StartProcessing()
    {
        lock (_stateLock)
        {
            if (CurrentState != State.Recording && CurrentState != State.Finalizing)
                return false;
            
            var oldState = CurrentState;
            CurrentState = State.Processing;
            OnStateChanged(oldState, CurrentState);
            return true;
        }
    }

    public bool StartFinalizing()
    {
        lock (_stateLock)
        {
            if (CurrentState != State.Recording) return false;
            var oldState = CurrentState;
            CurrentState = State.Finalizing;
            OnStateChanged(oldState, CurrentState);
            return true;
        }
    }

    public bool StartRetrying()
    {
        lock (_stateLock)
        {
            if (CurrentState is State.Starting or State.Recording or State.Finalizing or State.Processing)
                return false;
            var oldState = CurrentState;
            TranscriptionText = string.Empty;
            ErrorMessage = string.Empty;
            CurrentState = State.Processing;
            OnStateChanged(oldState, CurrentState);
            return true;
        }
    }
    
    /// <summary>
    /// Transitions to the result state with transcription text
    /// </summary>
    public bool SetResult(string text)
    {
        lock (_stateLock)
        {
            if (CurrentState != State.Processing)
                return false;
            
            var oldState = CurrentState;
            TranscriptionText = text;
            CurrentState = State.Result;
            OnStateChanged(oldState, CurrentState);
            TranscriptionCompleted?.Invoke(this, text);
            return true;
        }
    }
    
    /// <summary>
    /// Transitions to the error state
    /// </summary>
    public bool SetError(string message)
    {
        lock (_stateLock)
        {
            // A late error (e.g. a device callback) must not clobber an
            // already-delivered result.
            if (CurrentState == State.Result)
                return false;

            var oldState = CurrentState;
            ErrorMessage = message;
            CurrentState = State.Error;
            OnStateChanged(oldState, CurrentState);
            ErrorOccurred?.Invoke(this, message);
            return true;
        }
    }
    
    /// <summary>
    /// Resets to idle state
    /// </summary>
    public void Reset()
    {
        lock (_stateLock)
        {
            var oldState = CurrentState;
            CurrentState = State.Idle;
            IsCommandMode = false;
            RecordingDuration = TimeSpan.Zero;
            CurrentAudioLevel = Constants.DefaultAudioLevel;
            PeakAudioLevel = Constants.DefaultAudioLevel;
            
            if (oldState != State.Idle)
            {
                OnStateChanged(oldState, CurrentState);
            }
        }
    }
    
    /// <summary>
    /// Updates the current audio level for visualization
    /// </summary>
    public void UpdateAudioLevel(float level)
    {
        var normalizedLevel = Math.Clamp(level, 0f, 1f);
        CurrentAudioLevel = normalizedLevel;
        
        if (normalizedLevel > PeakAudioLevel)
        {
            PeakAudioLevel = normalizedLevel;
        }
        
        AudioLevelUpdated?.Invoke(this, normalizedLevel);
    }
    
    /// <summary>
    /// Updates the recording duration
    /// </summary>
    public void UpdateRecordingDuration(TimeSpan duration)
    {
        RecordingDuration = duration;
    }
    
    // MARK: - Computed Properties
    
    public bool IsRecording => CurrentState == State.Recording;
    public bool IsProcessing => CurrentState == State.Processing;
    public bool IsBusy => CurrentState is State.Starting or State.Recording or State.Finalizing or State.Processing;
    public bool HasError => CurrentState == State.Error;
    public bool HasResult => CurrentState == State.Result && !string.IsNullOrEmpty(TranscriptionText);
    
    // MARK: - Private Methods
    
    private void OnStateChanged(State oldState, State newState)
    {
        StateChanged?.Invoke(this, new StateChangedEventArgs(oldState, newState));
    }
}
