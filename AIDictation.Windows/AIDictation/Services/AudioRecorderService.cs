using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace AIDictation.Services;

/// <summary>
/// Manages audio recording using WASAPI capture for voice dictation.
/// Provides device enumeration, recording controls, and audio level monitoring.
/// </summary>
public sealed class AudioRecorderService : IDisposable
{
    // MARK: - Singleton

    private static readonly Lazy<AudioRecorderService> _instance = new(() => new AudioRecorderService());
    public static AudioRecorderService Instance => _instance.Value;

    // MARK: - Events

    /// <summary>
    /// Fired when audio level changes during recording. Value is 0.0 to 1.0.
    /// </summary>
    public event EventHandler<float>? AudioLevelChanged;

    /// <summary>
    /// Fired when recording state changes.
    /// </summary>
    public event EventHandler<bool>? RecordingStateChanged;

    /// <summary>
    /// Fired when recording completes with the file path.
    /// </summary>
    public event EventHandler<string>? RecordingCompleted;

    /// <summary>
    /// Fired when an error occurs during recording.
    /// </summary>
    public event EventHandler<string>? RecordingError;

    // MARK: - Constants

    private static class Constants
    {
        public const int Channels = 1; // Mono
        public const int BitsPerSample = 16;
        public const string RecordingsFolderName = "Recordings";
        public const string AppFolderName = "AIDictation";
    }

    // MARK: - Private Properties

    private WasapiCapture? _capture;
    private WaveFileWriter? _writer;
    private string? _currentFilePath;
    private bool _isRecording;
    private bool _disposed;
    private string? _selectedDeviceId;
    private readonly object _lock = new();

    // MARK: - Public Properties

    public bool IsRecording
    {
        get
        {
            lock (_lock)
            {
                return _isRecording;
            }
        }
        private set
        {
            lock (_lock)
            {
                if (_isRecording != value)
                {
                    _isRecording = value;
                    RecordingStateChanged?.Invoke(this, value);
                }
            }
        }
    }

    public string? SelectedDeviceId
    {
        get => _selectedDeviceId;
        set => _selectedDeviceId = value;
    }

    public string RecordingsFolder { get; }

    // MARK: - Initialization

    private AudioRecorderService()
    {
        RecordingsFolder = GetRecordingsFolder();
        EnsureRecordingsFolderExists();
    }

    // MARK: - Public API

    /// <summary>
    /// Gets available audio input devices.
    /// </summary>
    public List<AudioDevice> GetInputDevices()
    {
        var devices = new List<AudioDevice>();

        try
        {
            using var enumerator = new MMDeviceEnumerator();
            var collection = enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active);

            foreach (var device in collection)
            {
                devices.Add(new AudioDevice
                {
                    Id = device.ID,
                    Name = device.FriendlyName,
                    IsDefault = IsDefaultDevice(device, enumerator)
                });
            }
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Error enumerating audio devices: {ex.Message}");
        }

        return devices;
    }

    /// <summary>
    /// Gets the default input device.
    /// </summary>
    public AudioDevice? GetDefaultDevice()
    {
        try
        {
            using var enumerator = new MMDeviceEnumerator();
            var device = enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications);
            return new AudioDevice
            {
                Id = device.ID,
                Name = device.FriendlyName,
                IsDefault = true
            };
        }
        catch
        {
            return null;
        }
    }

    /// <summary>
    /// Starts recording audio.
    /// </summary>
    /// <returns>True if recording started successfully.</returns>
    public bool StartRecording()
    {
        if (IsRecording) return false;

        try
        {
            var device = GetSelectedOrDefaultDevice();
            if (device == null)
            {
                RecordingError?.Invoke(this, "No audio input device available");
                return false;
            }

            _currentFilePath = GenerateFilePath();
            
            // Create WASAPI capture
            _capture = new WasapiCapture(device, true, 50); // 50ms buffer

            // The conversion below changes bit depth and channel count but never
            // resamples, so the WAV header must carry the device mix rate or the
            // file plays (and transcribes) pitch-shifted.
            var targetFormat = new WaveFormat(_capture.WaveFormat.SampleRate, Constants.BitsPerSample, Constants.Channels);

            _writer = new WaveFileWriter(_currentFilePath, targetFormat);

            _capture.DataAvailable += OnDataAvailable;
            _capture.RecordingStopped += OnRecordingStopped;

            _capture.StartRecording();
            IsRecording = true;

            return true;
        }
        catch (Exception ex)
        {
            Cleanup();
            RecordingError?.Invoke(this, $"Failed to start recording: {ex.Message}");
            return false;
        }
    }

    /// <summary>
    /// Stops the current recording.
    /// </summary>
    public void StopRecording()
    {
        if (!IsRecording) return;

        try
        {
            _capture?.StopRecording();
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Error stopping recording: {ex.Message}");
            Cleanup();
            IsRecording = false;
        }
    }

    /// <summary>
    /// Forcibly tears down a capture session that failed to stop cleanly.
    /// Fires no completion events.
    /// </summary>
    public void AbortRecording()
    {
        Cleanup();
        IsRecording = false;
    }

    /// <summary>
    /// Calculates RMS level from audio samples.
    /// </summary>
    /// <param name="buffer">Audio buffer</param>
    /// <param name="bytesRecorded">Number of bytes in buffer</param>
    /// <param name="bitsPerSample">Bits per sample (typically 16 or 32)</param>
    /// <returns>RMS level from 0.0 to 1.0</returns>
    public static float CalculateRmsLevel(byte[] buffer, int bytesRecorded, int bitsPerSample)
    {
        if (bytesRecorded == 0) return 0;

        double sumSquares = 0;
        int sampleCount = 0;

        if (bitsPerSample == 16)
        {
            for (int i = 0; i < bytesRecorded - 1; i += 2)
            {
                short sample = BitConverter.ToInt16(buffer, i);
                double normalized = sample / 32768.0;
                sumSquares += normalized * normalized;
                sampleCount++;
            }
        }
        else if (bitsPerSample == 32)
        {
            for (int i = 0; i < bytesRecorded - 3; i += 4)
            {
                float sample = BitConverter.ToSingle(buffer, i);
                sumSquares += sample * sample;
                sampleCount++;
            }
        }

        if (sampleCount == 0) return 0;

        double rms = Math.Sqrt(sumSquares / sampleCount);
        return (float)Math.Min(1.0, rms);
    }

    // MARK: - Private Methods

    private static string GetRecordingsFolder()
    {
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        return Path.Combine(appData, Constants.AppFolderName, Constants.RecordingsFolderName);
    }

    private void EnsureRecordingsFolderExists()
    {
        if (!Directory.Exists(RecordingsFolder))
        {
            Directory.CreateDirectory(RecordingsFolder);
        }
    }

    private string GenerateFilePath()
    {
        var timestamp = DateTime.Now.ToString("yyyyMMdd_HHmmss");
        var fileName = $"recording_{timestamp}.wav";
        return Path.Combine(RecordingsFolder, fileName);
    }

    private MMDevice? GetSelectedOrDefaultDevice()
    {
        try
        {
            using var enumerator = new MMDeviceEnumerator();

            if (!string.IsNullOrEmpty(_selectedDeviceId))
            {
                try
                {
                    return enumerator.GetDevice(_selectedDeviceId);
                }
                catch
                {
                    // Device not available, fall back to default
                }
            }

            return enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications);
        }
        catch
        {
            return null;
        }
    }

    private static bool IsDefaultDevice(MMDevice device, MMDeviceEnumerator enumerator)
    {
        try
        {
            var defaultDevice = enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Communications);
            return device.ID == defaultDevice.ID;
        }
        catch
        {
            return false;
        }
    }

    private void OnDataAvailable(object? sender, WaveInEventArgs e)
    {
        if (_writer == null || e.BytesRecorded == 0) return;

        try
        {
            // Get the capture format
            var captureFormat = _capture?.WaveFormat;
            if (captureFormat == null) return;

            // Convert to target format if needed
            byte[] convertedBuffer;
            int convertedBytes;

            if (captureFormat.Encoding == WaveFormatEncoding.IeeeFloat && captureFormat.BitsPerSample == 32)
            {
                // Convert 32-bit float to 16-bit PCM mono
                convertedBuffer = ConvertFloat32ToInt16Mono(e.Buffer, e.BytesRecorded, captureFormat.Channels);
                convertedBytes = convertedBuffer.Length;

                // Calculate level from original float data
                var level = CalculateRmsLevel(e.Buffer, e.BytesRecorded, 32);
                AudioLevelChanged?.Invoke(this, level);
            }
            else if (captureFormat.BitsPerSample == 16)
            {
                // Already 16-bit, just convert to mono if needed
                if (captureFormat.Channels > 1)
                {
                    convertedBuffer = ConvertToMono(e.Buffer, e.BytesRecorded, captureFormat.Channels);
                    convertedBytes = convertedBuffer.Length;
                }
                else
                {
                    convertedBuffer = e.Buffer;
                    convertedBytes = e.BytesRecorded;
                }

                var level = CalculateRmsLevel(e.Buffer, e.BytesRecorded, 16);
                AudioLevelChanged?.Invoke(this, level);
            }
            else
            {
                // Unsupported format, write raw
                convertedBuffer = e.Buffer;
                convertedBytes = e.BytesRecorded;

                var level = CalculateRmsLevel(e.Buffer, e.BytesRecorded, captureFormat.BitsPerSample);
                AudioLevelChanged?.Invoke(this, level);
            }

            _writer.Write(convertedBuffer, 0, convertedBytes);
        }
        catch (Exception ex)
        {
            System.Diagnostics.Debug.WriteLine($"Error writing audio data: {ex.Message}");
        }
    }

    private static byte[] ConvertFloat32ToInt16Mono(byte[] buffer, int bytesRecorded, int channels)
    {
        int floatSamples = bytesRecorded / 4;
        int monoSamples = floatSamples / channels;
        var output = new byte[monoSamples * 2];

        for (int i = 0; i < monoSamples; i++)
        {
            // Average channels for mono
            float sum = 0;
            for (int ch = 0; ch < channels; ch++)
            {
                int floatIndex = (i * channels + ch) * 4;
                sum += BitConverter.ToSingle(buffer, floatIndex);
            }
            float monoSample = sum / channels;

            // Clamp and convert to 16-bit
            monoSample = Math.Clamp(monoSample, -1.0f, 1.0f);
            short int16Sample = (short)(monoSample * 32767);

            byte[] int16Bytes = BitConverter.GetBytes(int16Sample);
            output[i * 2] = int16Bytes[0];
            output[i * 2 + 1] = int16Bytes[1];
        }

        return output;
    }

    private static byte[] ConvertToMono(byte[] buffer, int bytesRecorded, int channels)
    {
        int bytesPerSample = 2; // 16-bit
        int samplesPerChannel = bytesRecorded / (bytesPerSample * channels);
        var output = new byte[samplesPerChannel * bytesPerSample];

        for (int i = 0; i < samplesPerChannel; i++)
        {
            int sum = 0;
            for (int ch = 0; ch < channels; ch++)
            {
                int index = (i * channels + ch) * bytesPerSample;
                short sample = BitConverter.ToInt16(buffer, index);
                sum += sample;
            }
            short monoSample = (short)(sum / channels);

            byte[] monoBytes = BitConverter.GetBytes(monoSample);
            output[i * bytesPerSample] = monoBytes[0];
            output[i * bytesPerSample + 1] = monoBytes[1];
        }

        return output;
    }

    private void OnRecordingStopped(object? sender, StoppedEventArgs e)
    {
        // A stop event from a previous capture session (still tearing down
        // asynchronously) must not clean up the current one.
        if (sender is WasapiCapture stopped && !ReferenceEquals(stopped, _capture))
        {
            stopped.Dispose();
            return;
        }

        var filePath = _currentFilePath;
        
        Cleanup();
        IsRecording = false;

        if (e.Exception != null)
        {
            RecordingError?.Invoke(this, $"Recording stopped with error: {e.Exception.Message}");
            
            // Delete partial file
            if (!string.IsNullOrEmpty(filePath) && File.Exists(filePath))
            {
                try { File.Delete(filePath); } catch { }
            }
        }
        else if (!string.IsNullOrEmpty(filePath) && File.Exists(filePath))
        {
            RecordingCompleted?.Invoke(this, filePath);
        }
    }

    private void Cleanup()
    {
        if (_capture != null)
        {
            _capture.DataAvailable -= OnDataAvailable;
            _capture.RecordingStopped -= OnRecordingStopped;
            _capture.Dispose();
            _capture = null;
        }

        _writer?.Dispose();
        _writer = null;
        _currentFilePath = null;
    }

    // MARK: - IDisposable

    public void Dispose()
    {
        if (_disposed) return;
        
        StopRecording();
        Cleanup();
        _disposed = true;
    }
}

/// <summary>
/// Represents an audio input device.
/// </summary>
public class AudioDevice
{
    public string Id { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public bool IsDefault { get; set; }

    public override string ToString() => Name;
}
