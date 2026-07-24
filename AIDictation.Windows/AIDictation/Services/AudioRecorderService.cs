using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace AIDictation.Services;

/// <summary>
/// Owns exactly one WASAPI capture session. Every callback closes over its
/// immutable session token, and only one stop callback/deadline may finalize it.
/// </summary>
public sealed class AudioRecorderService : IAudioRecorderService, IDisposable
{
    private sealed class CaptureSession
    {
        public required AudioAttemptLease Lease { get; init; }
        public required string PartialSourcePath { get; init; }
        public readonly object WriterLock = new();
        public readonly TaskCompletionSource<bool> FirstWrite =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        public readonly TaskCompletionSource<RecorderFinalizationResult> Finalized =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        public readonly TaskCompletionSource<bool> WriterClosed =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        public readonly TaskCompletionSource<bool> SetupCompleted =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        public WasapiCapture? Capture;
        public WaveFileWriter? Writer;
        public EventHandler<WaveInEventArgs>? DataHandler;
        public EventHandler<StoppedEventArgs>? StoppedHandler;
        public Exception? WriteFailure;
        public AudioCaptureTerminalFence TerminalFence { get; } = new();
    }

    private static readonly TimeSpan FirstWriteDeadline = TimeSpan.FromSeconds(5);
    private static readonly TimeSpan DefaultFinalizationDeadline = TimeSpan.FromSeconds(10);
    private readonly object _lifetimeLock = new();
    private readonly RetiredNativeCloseRegistry<CaptureSession> _closeRegistry = new();
    private bool _disposed;

    public static AudioRecorderService Instance { get; } = new();

    public event EventHandler<float>? AudioLevelChanged;
    public event EventHandler<RecorderCaptureFailedEventArgs>? CaptureTerminatedUnexpectedly;

    private AudioRecorderService() { }

    public bool IsCapturing
    {
        get
        {
            return _closeRegistry.HasCurrent;
        }
    }

    public Task<List<AudioDevice>> GetInputDevicesAsync(CancellationToken cancellationToken = default) =>
        Task.Run(GetInputDevicesCore, cancellationToken);

    // Kept for non-UI callers. UI code uses GetInputDevicesAsync.
    public List<AudioDevice> GetInputDevices() => GetInputDevicesCore();

    public Task<AudioDevice?> GetDefaultDeviceAsync(CancellationToken cancellationToken = default) =>
        Task.Run(() =>
        {
            try
            {
                using var enumerator = new MMDeviceEnumerator();
                using var device = GetDefaultCaptureDevice(enumerator);
                return device == null
                    ? null
                    : new AudioDevice { Id = device.ID, Name = device.FriendlyName, IsDefault = true };
            }
            catch { return null; }
        }, cancellationToken);

    public async Task<RecorderStartResult> StartRecordingAsync(
        AudioAttemptLease lease,
        string partialSourcePath,
        string? selectedDeviceId,
        CancellationToken cancellationToken)
    {
        ThrowIfDisposed();
        var session = new CaptureSession { Lease = lease, PartialSourcePath = partialSourcePath };
        if (!_closeRegistry.TryInstall(session))
            return RecorderStartResult.Failure("Another recording is already active.");

        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            var setupTask = Task.Run(() =>
            {
                try { StartWasapiSession(session, selectedDeviceId); }
                finally { session.SetupCompleted.TrySetResult(true); }
            }, CancellationToken.None);
            try
            {
                await setupTask.WaitAsync(FirstWriteDeadline, cancellationToken).ConfigureAwait(false);
            }
            catch (TimeoutException)
            {
                ObserveLateTask(setupTask);
                await AbandonSessionAsync(
                    session,
                    "The microphone took too long to start.",
                    timedOut: true).ConfigureAwait(false);
                return RecorderStartResult.Failure("The microphone took too long to start. Check the selected input and try again.");
            }

            try
            {
                await session.FirstWrite.Task
                    .WaitAsync(FirstWriteDeadline, cancellationToken)
                    .ConfigureAwait(false);
            }
            catch (TimeoutException)
            {
                await AbandonSessionAsync(
                    session,
                    "The microphone did not provide audio in time.",
                    timedOut: true).ConfigureAwait(false);
                return RecorderStartResult.Failure("The microphone did not provide audio. Check the selected input and try again.");
            }

            if (session.TerminalFence.IsTerminal || session.WriteFailure != null)
            {
                return RecorderStartResult.Failure(
                    session.WriteFailure == null
                        ? "Recording stopped before audio was ready."
                        : "Audio could not be saved. Check available storage and try again.");
            }

            return RecorderStartResult.Ready();
        }
        catch (OperationCanceledException)
        {
            await AbandonSessionAsync(session, "Recording was cancelled.").ConfigureAwait(false);
            throw;
        }
        catch (Exception ex)
        {
            await AbandonSessionAsync(session, ex.Message).ConfigureAwait(false);
            return RecorderStartResult.Failure(
                "Unable to start the microphone. Check Windows microphone access and the selected input.");
        }
    }

    public async Task<RecorderFinalizationResult> StopRecordingAsync(
        AudioAttemptLease lease,
        TimeSpan? deadline = null,
        CancellationToken cancellationToken = default)
    {
        var session = CurrentMatchingSession(lease);
        if (session == null)
            return new RecorderFinalizationResult(false, string.Empty, "This recording attempt is no longer active.");

        var finalizationDeadline = deadline ?? DefaultFinalizationDeadline;
        var stopwatch = Stopwatch.StartNew();
        session.TerminalFence.MarkStopRequested();
        try
        {
            var stopTask = Task.Run(() => session.Capture?.StopRecording(), cancellationToken);
            try
            {
                await stopTask.WaitAsync(finalizationDeadline, cancellationToken).ConfigureAwait(false);
            }
            catch (TimeoutException)
            {
                ObserveLateTask(stopTask);
                await AbandonSessionAsync(
                    session,
                    "The microphone did not finish closing the recording.",
                    timedOut: true).ConfigureAwait(false);
                return await session.Finalized.Task.ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            await AbandonSessionAsync(session, "Recording finalization was cancelled.").ConfigureAwait(false);
            throw;
        }
        catch (Exception ex)
        {
            await AbandonSessionAsync(session, ex.Message).ConfigureAwait(false);
        }

        try
        {
            var remaining = finalizationDeadline - stopwatch.Elapsed;
            if (remaining <= TimeSpan.Zero)
            {
                await AbandonSessionAsync(
                    session,
                    "The microphone did not finish closing the recording.",
                    timedOut: true).ConfigureAwait(false);
                return await session.Finalized.Task.ConfigureAwait(false);
            }
            return await session.Finalized.Task
                .WaitAsync(remaining, cancellationToken)
                .ConfigureAwait(false);
        }
        catch (TimeoutException)
        {
            await AbandonSessionAsync(
                session,
                "The microphone did not finish closing the recording.",
                timedOut: true).ConfigureAwait(false);
            return await session.Finalized.Task.ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            await AbandonSessionAsync(session, "Recording finalization was cancelled.").ConfigureAwait(false);
            throw;
        }
    }

    public async Task AbortRecordingAsync(
        AudioAttemptLease lease,
        string reason,
        CancellationToken cancellationToken = default)
    {
        var session = CurrentMatchingSession(lease);
        if (session == null) return;
        await AbandonSessionAsync(session, reason).WaitAsync(cancellationToken).ConfigureAwait(false);
    }

    public async Task<RecorderFinalizationResult?> ShutdownAsync(
        AudioAttemptLease? activeLease,
        TimeSpan deadline,
        CancellationToken cancellationToken = default)
    {
        lock (_lifetimeLock) _disposed = true;
        var stopwatch = Stopwatch.StartNew();
        var snapshot = _closeRegistry.BeginShutdown();
        var session = snapshot.Current?.Resource;
        if (session != null)
        {
            _ = session.TerminalFence.TryClaimTerminal();
            session.FirstWrite.TrySetCanceled();
            _ = StartTrackedClose(session, snapshot.Current);
        }

        RecorderFinalizationResult? result = null;
        if (session != null)
        {
            var matchesLease = activeLease != null &&
                               session.Lease.RecordingId == activeLease.RecordingId &&
                               session.Lease.AttemptId == activeLease.AttemptId &&
                               session.Lease.DeletionGeneration == activeLease.DeletionGeneration &&
                               session.Lease.ClearGeneration == activeLease.ClearGeneration;
            try
            {
                await session.WriterClosed.Task
                    .WaitAsync(Remaining(deadline, stopwatch), cancellationToken)
                    .ConfigureAwait(false);
                var validation = AudioContainerValidator.ValidateFinalizedWave(session.PartialSourcePath);
                result = new RecorderFinalizationResult(
                    matchesLease && session.WriteFailure == null && validation.IsValid,
                    session.PartialSourcePath,
                    matchesLease && session.WriteFailure == null && validation.IsValid
                        ? null
                        : validation.ErrorMessage ??
                          "The recording did not finish closing before the app exited.");
            }
            catch (TimeoutException)
            {
                result = new RecorderFinalizationResult(
                    false,
                    session.PartialSourcePath,
                    "The microphone did not finish closing before the app exited.",
                    TimedOut: true);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                result = new RecorderFinalizationResult(
                    false,
                    session.PartialSourcePath,
                    "Recording finalization was cancelled while the app was exiting.",
                    TimedOut: true);
            }
            session.Finalized.TrySetResult(result);
        }

        try
        {
            if (snapshot.CloseTasks.Count > 0)
            {
                await Task.WhenAll(snapshot.CloseTasks)
                    .WaitAsync(Remaining(deadline, stopwatch), cancellationToken)
                    .ConfigureAwait(false);
            }
        }
        catch (TimeoutException) { }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { }
        return result;
    }

    public static float CalculateRmsLevel(byte[] buffer, int bytesRecorded, int bitsPerSample)
    {
        if (bytesRecorded == 0) return 0;
        double sumSquares = 0;
        var sampleCount = 0;
        if (bitsPerSample == 16)
        {
            for (var index = 0; index < bytesRecorded - 1; index += 2)
            {
                var sample = BitConverter.ToInt16(buffer, index) / 32768.0;
                sumSquares += sample * sample;
                sampleCount++;
            }
        }
        else if (bitsPerSample == 32)
        {
            for (var index = 0; index < bytesRecorded - 3; index += 4)
            {
                var sample = BitConverter.ToSingle(buffer, index);
                sumSquares += sample * sample;
                sampleCount++;
            }
        }
        return sampleCount == 0 ? 0 : (float)Math.Min(1, Math.Sqrt(sumSquares / sampleCount));
    }

    private void StartWasapiSession(CaptureSession session, string? selectedDeviceId)
    {
        using var device = GetSelectedOrDefaultDevice(selectedDeviceId);
        if (device == null)
            throw new InvalidOperationException("No microphone is available.");

        WasapiCapture? capture = null;
        WaveFileWriter? writer = null;
        FileStream? outputStream = null;
        try
        {
            capture = new WasapiCapture(device, true, 50);
            var targetFormat = new WaveFormat(capture.WaveFormat.SampleRate, 16, 1);
            outputStream = new FileStream(
                session.PartialSourcePath,
                FileMode.Create,
                FileAccess.Write,
                FileShare.Read,
                64 * 1024,
                FileOptions.WriteThrough);
            writer = new WaveFileWriter(outputStream, targetFormat);
            outputStream = null; // WaveFileWriter owns the stream after construction.
            if (session.TerminalFence.IsTerminal || !IsCurrent(session))
            {
                writer.Dispose();
                capture.Dispose();
                return;
            }
            session.Capture = capture;
            session.Writer = writer;
            session.DataHandler = (_, args) => OnDataAvailable(session, args);
            session.StoppedHandler = (_, args) => OnRecordingStopped(session, args);
            capture.DataAvailable += session.DataHandler;
            capture.RecordingStopped += session.StoppedHandler;
            capture.StartRecording();
            if (session.TerminalFence.IsTerminal || !IsCurrent(session))
            {
                capture.DataAvailable -= session.DataHandler;
                capture.RecordingStopped -= session.StoppedHandler;
                try { capture.StopRecording(); } catch { }
                lock (session.WriterLock)
                {
                    try { writer.Dispose(); } catch { }
                    session.Writer = null;
                }
                try { capture.Dispose(); } catch { }
                session.Capture = null;
            }
        }
        catch
        {
            if (capture != null)
            {
                if (session.DataHandler != null) capture.DataAvailable -= session.DataHandler;
                if (session.StoppedHandler != null) capture.RecordingStopped -= session.StoppedHandler;
            }
            lock (session.WriterLock)
            {
                try { writer?.Dispose(); } catch { }
                try { outputStream?.Dispose(); } catch { }
                session.Writer = null;
            }
            try { capture?.Dispose(); } catch { }
            session.Capture = null;
            throw;
        }
    }

    private void OnDataAvailable(CaptureSession session, WaveInEventArgs args)
    {
        if (args.BytesRecorded <= 0 || !session.TerminalFence.IsAcceptingFrames ||
            session.TerminalFence.IsTerminal || !IsCurrent(session))
            return;

        try
        {
            var format = session.Capture?.WaveFormat;
            if (format == null) throw new InvalidOperationException("The microphone format became unavailable.");
            var (buffer, count, level) = ConvertCaptureBuffer(args.Buffer, args.BytesRecorded, format);
            lock (session.WriterLock)
            {
                if (!session.TerminalFence.IsAcceptingFrames ||
                    session.TerminalFence.IsTerminal || !IsCurrent(session))
                    return;
                session.Writer?.Write(buffer, 0, count);
                if (!session.FirstWrite.Task.IsCompleted)
                    session.Writer?.Flush();
            }
            session.FirstWrite.TrySetResult(true);
            if (IsCurrent(session)) AudioLevelChanged?.Invoke(this, level);
        }
        catch (Exception ex)
        {
            session.WriteFailure ??= ex;
            session.FirstWrite.TrySetException(ex);
            _ = HandleCaptureWriteFailureAsync(session, ex);
        }
    }

    private async Task HandleCaptureWriteFailureAsync(CaptureSession session, Exception error)
    {
        var wonTerminal = await AbandonSessionAsync(
            session,
            "Audio could not be saved. The recoverable source was kept.").ConfigureAwait(false);
        if (wonTerminal && !session.TerminalFence.StopWasRequested)
        {
            CaptureTerminatedUnexpectedly?.Invoke(this, new RecorderCaptureFailedEventArgs(
                session.Lease,
                "The microphone or storage stopped during recording. The recoverable source was kept."));
        }
        _ = error; // retained on the session for finalization diagnostics.
    }

    private void OnRecordingStopped(CaptureSession session, StoppedEventArgs args)
    {
        _ = Task.Run(async () =>
        {
            if (!session.TerminalFence.TryClaimTerminal()) return;
            _ = StartTrackedClose(session);
            await session.WriterClosed.Task.ConfigureAwait(false);
            var failure = session.WriteFailure ?? args.Exception;
            session.Finalized.TrySetResult(new RecorderFinalizationResult(
                failure == null,
                session.PartialSourcePath,
                failure == null
                    ? null
                    : "The recording could not be finalized. The recoverable source was kept."));
            if (failure != null) session.FirstWrite.TrySetException(failure);
            if (!session.TerminalFence.StopWasRequested)
            {
                CaptureTerminatedUnexpectedly?.Invoke(this, new RecorderCaptureFailedEventArgs(
                    session.Lease,
                    failure == null
                        ? "The microphone stopped unexpectedly. The recoverable source was kept."
                        : "The microphone or storage stopped during recording. The recoverable source was kept."));
            }
        });
    }

    private async Task<bool> AbandonSessionAsync(CaptureSession session, string message, bool timedOut = false)
    {
        var wonTerminal = session.TerminalFence.TryClaimTerminal();
        if (wonTerminal) _ = StartTrackedClose(session);
        session.FirstWrite.TrySetCanceled();
        // Complete the UI-facing deadline immediately even when native WASAPI
        // teardown ignores cancellation or stalls. Resource cleanup is fenced
        // and detached; it cannot win a later attempt.
        session.Finalized.TrySetResult(new RecorderFinalizationResult(
            false,
            session.PartialSourcePath,
            message,
            timedOut));
        await Task.CompletedTask;
        return wonTerminal;
    }

    private Task StartTrackedClose(
        CaptureSession session,
        NativeCloseRegistration<CaptureSession>? registration = null)
    {
        registration ??= _closeRegistry.Retire(session);
        if (registration == null) return Task.CompletedTask;
        if (!registration.OwnsClose) return registration.Completion;

        _ = Task.Run(async () =>
        {
            try
            {
                DisposeSessionResourcesCore(session);
                await session.SetupCompleted.Task.ConfigureAwait(false);
                // A setup that observed retirement disposes its locals itself.
                // Run once more in case it published a resource immediately
                // before observing the terminal fence.
                DisposeSessionResourcesCore(session);
            }
            finally
            {
                session.WriterClosed.TrySetResult(session.WriteFailure == null);
                _closeRegistry.Complete(session);
            }
        });
        return registration.Completion;
    }

    private static void DisposeSessionResourcesCore(CaptureSession session)
    {
        var capture = session.Capture;
        if (capture != null)
        {
            if (session.DataHandler != null) capture.DataAvailable -= session.DataHandler;
            if (session.StoppedHandler != null) capture.RecordingStopped -= session.StoppedHandler;
        }
        var hadWriter = false;
        lock (session.WriterLock)
        {
            hadWriter = session.Writer != null;
            try { session.Writer?.Dispose(); }
            catch (Exception ex) { session.WriteFailure ??= ex; }
            session.Writer = null;
        }
        // A durable WAV header no longer depends on potentially wedged native
        // capture disposal. Signal it before disposing the WASAPI generation.
        if (hadWriter || session.SetupCompleted.Task.IsCompleted)
            session.WriterClosed.TrySetResult(session.WriteFailure == null);
        if (capture != null)
        {
            try { capture.Dispose(); } catch { }
            session.Capture = null;
        }
    }

    private CaptureSession? CurrentMatchingSession(AudioAttemptLease lease)
    {
        var session = _closeRegistry.Current;
        return session != null && session.Lease.RecordingId == lease.RecordingId &&
               session.Lease.AttemptId == lease.AttemptId &&
               session.Lease.DeletionGeneration == lease.DeletionGeneration &&
               session.Lease.ClearGeneration == lease.ClearGeneration
            ? session
            : null;
    }

    private bool IsCurrent(CaptureSession session) => _closeRegistry.IsCurrent(session);

    private static List<AudioDevice> GetInputDevicesCore()
    {
        var devices = new List<AudioDevice>();
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            var collection = enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active);
            foreach (var device in collection)
            {
                using (device)
                {
                    devices.Add(new AudioDevice
                    {
                        Id = device.ID,
                        Name = device.FriendlyName,
                        IsDefault = IsDefaultDevice(device, enumerator)
                    });
                }
            }
        }
        catch { }
        return devices;
    }

    private static MMDevice? GetSelectedOrDefaultDevice(string? selectedDeviceId)
    {
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            if (!string.IsNullOrWhiteSpace(selectedDeviceId))
            {
                try
                {
                    var selected = enumerator.GetDevice(selectedDeviceId);
                    if (selected.State == DeviceState.Active) return selected;
                    selected.Dispose();
                }
                catch { }
            }
            return GetDefaultCaptureDevice(enumerator);
        }
        catch { return null; }
    }

    private static MMDevice? GetDefaultCaptureDevice(MMDeviceEnumerator enumerator)
    {
        foreach (var role in new[] { Role.Multimedia, Role.Console, Role.Communications })
        {
            try
            {
                var device = enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, role);
                if (device.State == DeviceState.Active) return device;
                device.Dispose();
            }
            catch { }
        }
        try { return enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active).FirstOrDefault(); }
        catch { return null; }
    }

    private static bool IsDefaultDevice(MMDevice device, MMDeviceEnumerator enumerator)
    {
        try
        {
            using var defaultDevice = enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Multimedia);
            return device.ID == defaultDevice.ID;
        }
        catch { return false; }
    }

    private static (byte[] Buffer, int Count, float Level) ConvertCaptureBuffer(
        byte[] source,
        int count,
        WaveFormat format)
    {
        // WASAPI commonly exposes ordinary PCM/IEEE-float mix formats through
        // WAVE_FORMAT_EXTENSIBLE. Normalize its SubFormat before dispatch so a
        // valid first buffer is not rejected solely because of the wrapper.
        var normalizedFormat = format is WaveFormatExtensible extensible
            ? extensible.ToStandardWaveFormat()
            : format;
        if (normalizedFormat.Encoding == WaveFormatEncoding.IeeeFloat &&
            normalizedFormat.BitsPerSample == 32)
            return (ConvertFloat32ToInt16Mono(source, count, normalizedFormat.Channels),
                (count / 4 / normalizedFormat.Channels) * 2,
                CalculateRmsLevel(source, count, 32));
        if (normalizedFormat.Encoding == WaveFormatEncoding.Pcm &&
            normalizedFormat.BitsPerSample == 16)
        {
            var buffer = normalizedFormat.Channels > 1
                ? ConvertToMono(source, count, normalizedFormat.Channels)
                : source;
            return (buffer,
                normalizedFormat.Channels > 1 ? buffer.Length : count,
                CalculateRmsLevel(source, count, 16));
        }
        throw new InvalidOperationException("The selected microphone uses an unsupported audio format.");
    }

    private static byte[] ConvertFloat32ToInt16Mono(byte[] buffer, int bytesRecorded, int channels)
    {
        var monoSamples = bytesRecorded / 4 / channels;
        var output = new byte[monoSamples * 2];
        for (var sampleIndex = 0; sampleIndex < monoSamples; sampleIndex++)
        {
            float sum = 0;
            for (var channel = 0; channel < channels; channel++)
                sum += BitConverter.ToSingle(buffer, (sampleIndex * channels + channel) * 4);
            var value = (short)(Math.Clamp(sum / channels, -1f, 1f) * 32767);
            output[sampleIndex * 2] = (byte)(value & 0xff);
            output[sampleIndex * 2 + 1] = (byte)((value >> 8) & 0xff);
        }
        return output;
    }

    private static byte[] ConvertToMono(byte[] buffer, int bytesRecorded, int channels)
    {
        var sampleCount = bytesRecorded / 2 / channels;
        var output = new byte[sampleCount * 2];
        for (var sampleIndex = 0; sampleIndex < sampleCount; sampleIndex++)
        {
            var sum = 0;
            for (var channel = 0; channel < channels; channel++)
                sum += BitConverter.ToInt16(buffer, (sampleIndex * channels + channel) * 2);
            var value = (short)(sum / channels);
            output[sampleIndex * 2] = (byte)(value & 0xff);
            output[sampleIndex * 2 + 1] = (byte)((value >> 8) & 0xff);
        }
        return output;
    }

    private void ThrowIfDisposed()
    {
        lock (_lifetimeLock)
        {
            if (_disposed) throw new ObjectDisposedException(nameof(AudioRecorderService));
        }
    }

    private static TimeSpan Remaining(TimeSpan deadline, Stopwatch stopwatch)
    {
        var remaining = deadline - stopwatch.Elapsed;
        if (remaining <= TimeSpan.Zero) throw new TimeoutException();
        return remaining;
    }

    private static void ObserveLateTask(Task task)
    {
        _ = task.ContinueWith(
            completed => _ = completed.Exception,
            CancellationToken.None,
            TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.Default);
    }

    public void Dispose()
    {
        lock (_lifetimeLock)
        {
            if (_disposed) return;
            _disposed = true;
        }
        var snapshot = _closeRegistry.BeginShutdown();
        if (snapshot.Current != null)
        {
            var session = snapshot.Current.Resource;
            _ = session.TerminalFence.TryClaimTerminal();
            session.FirstWrite.TrySetCanceled();
            session.Finalized.TrySetResult(new RecorderFinalizationResult(
                false,
                session.PartialSourcePath,
                "The app closed during recording."));
            _ = StartTrackedClose(session, snapshot.Current);
        }
    }
}

public sealed class AudioDevice
{
    public string Id { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public bool IsDefault { get; set; }
    public override string ToString() => Name;
}
