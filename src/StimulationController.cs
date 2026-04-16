using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Wss.CoreModule;
using Wss.ModelModule;
using Wss.CalibrationModule;

namespace HFI.Wss;

/// <summary>
/// Host-agnostic wrapper around the full stimulation stack (core → params → model).
/// Provides the same API surface as the Unity <c>Stimulation</c> MonoBehaviour but manages
/// initialization, ticking, and shutdown inside a plain .NET application.
/// </summary>
/// <remarks>
/// This type starts a background tick loop when <see cref="Initialize"/> completes.
/// The public API is primarily intended for single-threaded use; avoid calling stimulation methods
/// concurrently with <see cref="Shutdown"/>.
/// </remarks>
public sealed class StimulationController : IAsyncDisposable, IDisposable
{
    private readonly StimulationOptions _options;
    private readonly object _gate = new();

    private IModelParamsCore? _wss;
    private IBasicStimulation? _basicWss;
    private bool _basicSupported;
    private CancellationTokenSource? _tickCts;
    private Task? _tickTask;

    /// <summary>True after this controller issues a successful <see cref="StartStimulation"/> request.</summary>
    /// <remarks>
    /// This is a controller-managed flag and may temporarily differ from <see cref="Started"/>, which
    /// queries the underlying WSS stack for its current state.
    /// </remarks>
    public bool started { get; private set; }

    /// <summary>True if the underlying core exposes basic-stimulation APIs.</summary>
    public bool BasicSupported => _basicSupported;

    /// <summary>
    /// Creates a controller instance with the provided stimulation configuration options.
    /// </summary>
    /// <param name="options">
    /// Options that control transport selection, config paths, and tick behavior without exposing
    /// transport implementation details to the caller.
    /// </param>
    /// <exception cref="ArgumentNullException">Thrown when <paramref name="options"/> is null.</exception>
    /// <exception cref="ArgumentException">Thrown when an option value is invalid.</exception>
    /// <exception cref="ArgumentOutOfRangeException">Thrown when an option value is out of range.</exception>
    public StimulationController(StimulationOptions options)
    {
        _options = options ?? throw new ArgumentNullException(nameof(options));
        _options.Validate();
        Directory.CreateDirectory(_options.ConfigPath);
    }

    /// <summary>
    /// Builds the full stimulation stack and initializes the hardware connection.
    /// Automatically starts the background tick loop.
    /// </summary>
    /// <remarks>
    /// The controller creates the transport internally based on <see cref="StimulationOptions.Transport"/>:
    /// test mode uses <see cref="TestModeTransport"/>, serial uses <see cref="SerialPortTransport"/>,
    /// and BLE uses <see cref="BleNusTransport"/>.
    /// This method is idempotent and returns immediately when the controller is already initialized.
    /// Initialization failures from the underlying WSS stack propagate to the caller.
    /// </remarks>
    public void Initialize()
    {
        lock (_gate)
        {
            if (_wss != null) return;

            ITransport transport = _options.Transport switch
            {
                StimulationTransportKind.Test => new TestModeTransport(new TestModeTransportOptions()),
                StimulationTransportKind.Ble => new BleNusTransport(new BleNusTransportOptions
                {
                    AutoSelectDevice = _options.BleAutoSelect,
                    DeviceId = _options.BleDeviceId,
                    DeviceName = _options.BleDeviceName
                }),
                _ => new SerialPortTransport(new SerialPortTransportOptions
                {
                    PortName = _options.SerialPort,
                    AutoSelectPort = string.IsNullOrWhiteSpace(_options.SerialPort)
                })
            };

            IStimulationCore core = new WssStimulationCore(transport, new WssStimulationCoreOptions
            {
                ConfigPath = _options.ConfigPath,
                MaxSetupTries = _options.MaxSetupTries
            });

            IStimParamsCore paramsLayer = new StimParamsLayer(core, _options.ConfigPath);
            var modelLayer = new ModelParamsLayer(paramsLayer, _options.ConfigPath);

            _wss = modelLayer;
            _wss.TryGetBasic(out _basicWss);
            _basicSupported = _basicWss != null;

            _wss.Initialize();
            EnsureTickLoop();
        }
    }

    /// <summary>Stops the background tick loop and tears down the active connection.</summary>
    /// <remarks>
    /// This method blocks until the current tick loop exits and then shuts down and disposes the active
    /// WSS stack. It is safe to call multiple times; calls made before initialization return without error.
    /// </remarks>
    public void Shutdown()
    {
        lock (_gate)
        {
            StopTickLoop();
            if (_wss != null)
            {
                try { _wss.Shutdown(); } catch (Exception ex) { Log.Error(ex, "Error during Shutdown"); }
                try { _wss.Dispose(); } catch (Exception ex) { Log.Error(ex, "Error disposing stimulation core"); }
            }

            _wss = null;
            _basicWss = null;
            _basicSupported = false;
            started = false;
        }
    }

    /// <summary>Explicitly releases the active radio connection.</summary>
    /// <remarks>
    /// This is equivalent to calling <see cref="Shutdown"/> and has the same blocking and idempotent
    /// behavior.
    /// </remarks>
    public void releaseRadio() => Shutdown();

    /// <summary>Performs a radio reset by shutting down and re-initializing the connection.</summary>
    /// <remarks>
    /// This method stops the current tick loop, reinitializes the underlying WSS stack in place, and then
    /// starts ticking again. If the controller has not been initialized yet, this method does nothing.
    /// </remarks>
    public void resetRadio()
    {
        lock (_gate)
        {
            if (_wss == null) return;
            StopTickLoop();
            _wss.Shutdown();
            _wss.Initialize();
            EnsureTickLoop();
        }
    }

    #region ==== Background ticking ====

    private void EnsureTickLoop()
    {
        if (_wss == null) return;
        if (_tickTask != null && !_tickTask.IsCompleted) return;

        StopTickLoop();

        _tickCts = new CancellationTokenSource();
        var token = _tickCts.Token;
        int interval = Math.Max(1, _options.TickIntervalMs);

        _tickTask = Task.Run(async () =>
        {
            while (!token.IsCancellationRequested)
            {
                try { _wss?.Tick(); }
                catch (Exception ex) { Log.Error(ex, "Tick loop failure"); }

                try { await Task.Delay(interval, token).ConfigureAwait(false); }
                catch (TaskCanceledException) { break; }
            }
        }, CancellationToken.None);
    }

    private void StopTickLoop()
    {
        var cts = _tickCts;
        var task = _tickTask;
        if (cts == null && task == null) return;

        _tickCts = null;
        _tickTask = null;

        try { cts?.Cancel(); } catch { }
        if (task != null)
        {
            try { task.Wait(); }
            catch (AggregateException ae) when (ae.InnerExceptions.All(e => e is TaskCanceledException)) { }
            catch (TaskCanceledException) { }
        }
        cts?.Dispose();
    }

    #endregion

    #region ==== Stimulation methods: basic and core ====

    /// <summary>
    /// Sends a direct (basic) analog stimulation request for a channel.
    /// </summary>
    /// <param name="finger">
    /// Finger name (e.g., "thumb", "index") or channel alias (e.g., "ch1").
    /// </param>
    /// <param name="PW">Pulse width (device-specific; commonly microseconds).</param>
    /// <param name="amp">Amplitude setting (device-specific).</param>
    /// <param name="IPI">Inter-pulse interval (device-specific; commonly milliseconds).</param>
    /// <exception cref="InvalidOperationException">Thrown when <see cref="Initialize"/> has not been called.</exception>
    public void StimulateAnalog(string finger, int PW, int amp = 3, int IPI = 10)
    {
        var wss = EnsureWss();
        int channel = FingerToChannel(finger);
        wss.StimulateAnalog(channel, PW, amp, IPI);
    }

    /// <summary>
    /// Broadcasts a start-stimulation command and marks <see cref="started"/> as true.
    /// </summary>
    /// <exception cref="InvalidOperationException">Thrown when <see cref="Initialize"/> has not been called.</exception>
    public void StartStimulation()
    {
        var wss = EnsureWss();
        wss.StartStim(WssTarget.Broadcast);
        started = true;
    }

    /// <summary>
    /// Broadcasts a stop-stimulation command and marks <see cref="started"/> as false.
    /// </summary>
    /// <exception cref="InvalidOperationException">Thrown when <see cref="Initialize"/> has not been called.</exception>
    public void StopStimulation()
    {
        var wss = EnsureWss();
        wss.StopStim(WssTarget.Broadcast);
        started = false;
    }

    /// <summary>
    /// Persists basic-stimulation configuration to the target device.
    /// </summary>
    /// <param name="targetWSS">0 = broadcast; 1-3 = specific device. Other values map to device 1.</param>
    /// <remarks>
    /// If the basic-stimulation API is unavailable, including before initialization, this method logs an
    /// error and returns without throwing.
    /// </remarks>
    public void Save(int targetWSS)
    {
        if (!TryGetBasic(out var basic)) { Log.Error("Basic stimulation not supported."); return; }
        basic.Save(IntToWssTarget(targetWSS));
    }

    /// <summary>
    /// Persists basic-stimulation configuration to all devices.
    /// </summary>
    /// <remarks>
    /// If the basic-stimulation API is unavailable, including before initialization, this method logs an
    /// error and returns without throwing.
    /// </remarks>
    public void Save()
    {
        if (!TryGetBasic(out var basic)) { Log.Error("Basic stimulation not supported."); return; }
        basic.Save(WssTarget.Broadcast);
    }

    /// <summary>
    /// Loads basic-stimulation configuration from the target device.
    /// </summary>
    /// <param name="targetWSS">0 = broadcast; 1-3 = specific device. Other values map to device 1.</param>
    /// <remarks>
    /// If the basic-stimulation API is unavailable, including before initialization, this method logs an
    /// error and returns without throwing.
    /// </remarks>
    public void load(int targetWSS)
    {
        if (!TryGetBasic(out var basic)) { Log.Error("Basic stimulation not supported."); return; }
        basic.Load(IntToWssTarget(targetWSS));
    }

    /// <summary>
    /// Loads basic-stimulation configuration from all devices.
    /// </summary>
    /// <remarks>
    /// If the basic-stimulation API is unavailable, including before initialization, this method logs an
    /// error and returns without throwing.
    /// </remarks>
    public void load()
    {
        if (!TryGetBasic(out var basic)) { Log.Error("Basic stimulation not supported."); return; }
        basic.Load(WssTarget.Broadcast);
    }

    /// <summary>
    /// Requests a configuration payload from the target device.
    /// </summary>
    /// <param name="targetWSS">0 = broadcast; 1-3 = specific device. Other values map to device 1.</param>
    /// <param name="command">Command identifier (device-specific).</param>
    /// <param name="id">Config identifier (device-specific).</param>
    /// <remarks>
    /// If the basic-stimulation API is unavailable, including before initialization, this method logs an
    /// error and returns without throwing.
    /// </remarks>
    public void request_Configs(int targetWSS, int command, int id)
    {
        if (!TryGetBasic(out var basic)) { Log.Error("Basic stimulation not supported."); return; }
        basic.Request_Configs(command, id, IntToWssTarget(targetWSS));
    }

    /// <summary>
    /// Updates a waveform definition on all devices.
    /// </summary>
    /// <param name="waveform">Waveform samples (device-specific representation).</param>
    /// <param name="eventID">Event identifier to update.</param>
    /// <remarks>
    /// If the basic-stimulation API is unavailable, including before initialization, this method logs an
    /// error and returns without throwing.
    /// </remarks>
    public void updateWaveform(int[] waveform, int eventID)
    {
        if (!TryGetBasic(out var basic)) { Log.Error("Basic stimulation not supported."); return; }
        basic.UpdateWaveform(waveform, eventID, WssTarget.Broadcast);
    }

    /// <summary>
    /// Updates a waveform definition on the target device.
    /// </summary>
    /// <param name="targetWSS">0 = broadcast; 1-3 = specific device. Other values map to device 1.</param>
    /// <param name="waveform">Waveform samples (device-specific representation).</param>
    /// <param name="eventID">Event identifier to update.</param>
    /// <remarks>
    /// If the basic-stimulation API is unavailable, including before initialization, this method logs an
    /// error and returns without throwing.
    /// </remarks>
    public void updateWaveform(int targetWSS, int[] waveform, int eventID)
    {
        if (!TryGetBasic(out var basic)) { Log.Error("Basic stimulation not supported."); return; }
        basic.UpdateWaveform(waveform, eventID, IntToWssTarget(targetWSS));
    }

    /// <summary>
    /// Updates an event shape using cathodic/anodic waveform identifiers on all devices.
    /// </summary>
    /// <param name="cathodicWaveform">Cathodic waveform identifier.</param>
    /// <param name="anodicWaveform">Anodic waveform identifier.</param>
    /// <param name="eventID">Event identifier to update.</param>
    /// <remarks>
    /// If the basic-stimulation API is unavailable, including before initialization, this method logs an
    /// error and returns without throwing.
    /// </remarks>
    public void updateWaveform(int cathodicWaveform, int anodicWaveform, int eventID)
    {
        if (!TryGetBasic(out var basic)) { Log.Error("Basic stimulation not supported."); return; }
        basic.UpdateEventShape(cathodicWaveform, anodicWaveform, eventID, WssTarget.Broadcast);
    }

    /// <summary>
    /// Updates an event shape using cathodic/anodic waveform identifiers on the target device.
    /// </summary>
    /// <param name="targetWSS">0 = broadcast; 1-3 = specific device. Other values map to device 1.</param>
    /// <param name="cathodicWaveform">Cathodic waveform identifier.</param>
    /// <param name="anodicWaveform">Anodic waveform identifier.</param>
    /// <param name="eventID">Event identifier to update.</param>
    /// <remarks>
    /// If the basic-stimulation API is unavailable, including before initialization, this method logs an
    /// error and returns without throwing.
    /// </remarks>
    public void updateWaveform(int targetWSS, int cathodicWaveform, int anodicWaveform, int eventID)
    {
        if (!TryGetBasic(out var basic)) { Log.Error("Basic stimulation not supported."); return; }
        basic.UpdateEventShape(cathodicWaveform, anodicWaveform, eventID, IntToWssTarget(targetWSS));
    }

    /// <summary>
    /// Updates a waveform definition on all devices.
    /// </summary>
    /// <param name="waveform">Waveform builder instance.</param>
    /// <param name="eventID">Event identifier to update.</param>
    /// <remarks>
    /// If the basic-stimulation API is unavailable, including before initialization, this method logs an
    /// error and returns without throwing.
    /// </remarks>
    public void updateWaveform(WaveformBuilder waveform, int eventID)
    {
        if (!TryGetBasic(out var basic)) { Log.Error("Basic stimulation not supported."); return; }
        basic.UpdateWaveform(waveform, eventID, WssTarget.Broadcast);
    }

    /// <summary>
    /// Updates a waveform definition on the target device.
    /// </summary>
    /// <param name="targetWSS">0 = broadcast; 1-3 = specific device. Other values map to device 1.</param>
    /// <param name="waveform">Waveform builder instance.</param>
    /// <param name="eventID">Event identifier to update.</param>
    /// <remarks>
    /// If the basic-stimulation API is unavailable, including before initialization, this method logs an
    /// error and returns without throwing.
    /// </remarks>
    public void updateWaveform(int targetWSS, WaveformBuilder waveform, int eventID)
    {
        if (!TryGetBasic(out var basic)) { Log.Error("Basic stimulation not supported."); return; }
        basic.UpdateWaveform(waveform, eventID, IntToWssTarget(targetWSS));
    }

    /// <summary>
    /// Loads a waveform file into the specified event slot.
    /// </summary>
    /// <param name="fileName">Waveform file path (as expected by the underlying WSS library).</param>
    /// <param name="eventID">Event identifier to update.</param>
    /// <remarks>
    /// If the basic-stimulation API is unavailable, including before initialization, this method logs an
    /// error and returns without throwing.
    /// </remarks>
    public void loadWaveform(string fileName, int eventID)
    {
        if (!TryGetBasic(out var basic)) { Log.Error("Basic stimulation not supported."); return; }
        basic.LoadWaveform(fileName, eventID);
    }

    /// <summary>
    /// Performs waveform setup for an event on all devices.
    /// </summary>
    /// <param name="wave">Waveform builder instance.</param>
    /// <param name="eventID">Event identifier to configure.</param>
    /// <remarks>
    /// If the basic-stimulation API is unavailable, including before initialization, this method logs an
    /// error and returns without throwing.
    /// </remarks>
    public void WaveformSetup(WaveformBuilder wave, int eventID)
    {
        if (!TryGetBasic(out var basic)) { Log.Error("Basic stimulation not supported."); return; }
        basic.WaveformSetup(wave, eventID, WssTarget.Broadcast);
    }

    /// <summary>
    /// Performs waveform setup for an event on the target device.
    /// </summary>
    /// <param name="targetWSS">0 = broadcast; 1-3 = specific device. Other values map to device 1.</param>
    /// <param name="wave">Waveform builder instance.</param>
    /// <param name="eventID">Event identifier to configure.</param>
    /// <remarks>
    /// If the basic-stimulation API is unavailable, including before initialization, this method logs an
    /// error and returns without throwing.
    /// </remarks>
    public void WaveformSetup(int targetWSS, WaveformBuilder wave, int eventID)
    {
        if (!TryGetBasic(out var basic)) { Log.Error("Basic stimulation not supported."); return; }
        basic.WaveformSetup(wave, eventID, IntToWssTarget(targetWSS));
    }

    /// <summary>
    /// Updates the inter-phase delay for an event on all devices.
    /// </summary>
    /// <param name="ipd">Inter-phase delay (device-specific; commonly microseconds).</param>
    /// <param name="eventID">Event identifier to update.</param>
    /// <remarks>
    /// If the basic-stimulation API is unavailable, including before initialization, this method logs an
    /// error and returns without throwing.
    /// </remarks>
    public void UpdateIPD(int ipd, int eventID)
    {
        if (!TryGetBasic(out var basic)) { Log.Error("Basic stimulation not supported."); return; }
        basic.UpdateIPD(ipd, eventID, WssTarget.Broadcast);
    }

    /// <summary>
    /// Updates the inter-phase delay for an event on the target device.
    /// </summary>
    /// <param name="targetWSS">0 = broadcast; 1-3 = specific device. Other values map to device 1.</param>
    /// <param name="ipd">Inter-phase delay (device-specific; commonly microseconds).</param>
    /// <param name="eventID">Event identifier to update.</param>
    /// <remarks>
    /// If the basic-stimulation API is unavailable, including before initialization, this method logs an
    /// error and returns without throwing.
    /// </remarks>
    public void UpdateIPD(int targetWSS, int ipd, int eventID)
    {
        if (!TryGetBasic(out var basic)) { Log.Error("Basic stimulation not supported."); return; }
        basic.UpdateIPD(ipd, eventID, IntToWssTarget(targetWSS));
    }

    #endregion

    #region ==== Stimulation methods: params and model layers ====

    /// <summary>
    /// Sends a normalized stimulation magnitude for the specified channel.
    /// </summary>
    /// <param name="finger">
    /// Finger name (e.g., "thumb", "index") or channel alias (e.g., "ch1").
    /// </param>
    /// <param name="magnitude">Normalized magnitude (device/model-specific convention).</param>
    /// <exception cref="InvalidOperationException">Thrown when <see cref="Initialize"/> has not been called.</exception>
    public void StimulateNormalized(string finger, float magnitude)
    {
        var wss = EnsureWss();
        int ch = FingerToChannel(finger);
        wss.StimulateNormalized(ch, magnitude);
    }

    /// <summary>
    /// Gets the current stimulation intensity for the specified channel.
    /// </summary>
    /// <param name="finger">
    /// Finger name (e.g., "thumb", "index") or channel alias (e.g., "ch1").
    /// </param>
    /// <returns>The current intensity value (device/model-specific units).</returns>
    /// <exception cref="InvalidOperationException">Thrown when <see cref="Initialize"/> has not been called.</exception>
    public int GetStimIntensity(string finger)
    {
        var wss = EnsureWss();
        int ch = FingerToChannel(finger);
        return (int)wss.GetStimIntensity(ch);
    }

    /// <summary>
    /// Persists stimulation parameters to the default JSON path.
    /// </summary>
    /// <exception cref="InvalidOperationException">Thrown when <see cref="Initialize"/> has not been called.</exception>
    public void SaveParamsJson() => EnsureWss().SaveParamsJson();

    /// <summary>
    /// Loads stimulation parameters from the default JSON path.
    /// </summary>
    /// <exception cref="InvalidOperationException">Thrown when <see cref="Initialize"/> has not been called.</exception>
    public void LoadParamsJson() => EnsureWss().LoadParamsJson();

    /// <summary>
    /// Loads stimulation parameters from a JSON file or directory.
    /// </summary>
    /// <param name="pathOrDir">File path or directory path; directory inputs use the library default filename.</param>
    /// <exception cref="InvalidOperationException">Thrown when <see cref="Initialize"/> has not been called.</exception>
    public void LoadParamsJson(string pathOrDir) => EnsureWss().LoadParamsJson(pathOrDir);

    /// <summary>
    /// Adds or updates a stimulation parameter value.
    /// </summary>
    /// <param name="key">Parameter key (e.g., "stim.ch.1.amp").</param>
    /// <param name="value">Parameter value (units depend on the key).</param>
    /// <exception cref="InvalidOperationException">Thrown when <see cref="Initialize"/> has not been called.</exception>
    public void AddOrUpdateStimParam(string key, float value) => EnsureWss().AddOrUpdateStimParam(key, value);

    /// <summary>
    /// Gets a stimulation parameter value.
    /// </summary>
    /// <param name="key">Parameter key.</param>
    /// <returns>The parameter value.</returns>
    /// <exception cref="InvalidOperationException">Thrown when <see cref="Initialize"/> has not been called.</exception>
    public float GetStimParam(string key) => EnsureWss().GetStimParam(key);

    /// <summary>
    /// Attempts to get a stimulation parameter value.
    /// </summary>
    /// <param name="key">Parameter key.</param>
    /// <param name="v">Receives the parameter value when present.</param>
    /// <returns><c>true</c> when the parameter exists; otherwise <c>false</c>.</returns>
    /// <exception cref="InvalidOperationException">Thrown when <see cref="Initialize"/> has not been called.</exception>
    public bool TryGetStimParam(string key, out float v) => EnsureWss().TryGetStimParam(key, out v);

    /// <summary>
    /// Gets a copy of all known stimulation parameters.
    /// </summary>
    /// <returns>A dictionary mapping parameter keys to their values.</returns>
    /// <exception cref="InvalidOperationException">Thrown when <see cref="Initialize"/> has not been called.</exception>
    public Dictionary<string, float> GetAllStimParams() => EnsureWss().GetAllStimParams();

    /// <summary>
    /// Sets the channel amplitude.
    /// </summary>
    /// <param name="finger">
    /// Finger name (e.g., "thumb", "index") or channel alias (e.g., "ch1").
    /// </param>
    /// <param name="mA">Amplitude in milliamps.</param>
    /// <exception cref="InvalidOperationException">Thrown when <see cref="Initialize"/> has not been called.</exception>
    public void SetChannelAmp(string finger, float mA)
    {
        var wss = EnsureWss();
        int ch = FingerToChannel(finger);
        wss.SetChannelAmp(ch, mA);
    }

    /// <summary>
    /// Sets the minimum pulse width for a channel.
    /// </summary>
    /// <param name="finger">
    /// Finger name (e.g., "thumb", "index") or channel alias (e.g., "ch1").
    /// </param>
    /// <param name="us">Pulse width in microseconds.</param>
    /// <exception cref="InvalidOperationException">Thrown when <see cref="Initialize"/> has not been called.</exception>
    public void SetChannelPWMin(string finger, int us)
    {
        var wss = EnsureWss();
        int ch = FingerToChannel(finger);
        wss.SetChannelPWMin(ch, us);
    }

    /// <summary>
    /// Sets the maximum pulse width for a channel.
    /// </summary>
    /// <param name="finger">
    /// Finger name (e.g., "thumb", "index") or channel alias (e.g., "ch1").
    /// </param>
    /// <param name="us">Pulse width in microseconds.</param>
    /// <exception cref="InvalidOperationException">Thrown when <see cref="Initialize"/> has not been called.</exception>
    public void SetChannelPWMax(string finger, int us)
    {
        var wss = EnsureWss();
        int ch = FingerToChannel(finger);
        wss.SetChannelPWMax(ch, us);
    }

    /// <summary>
    /// Sets the inter-pulse interval for a channel.
    /// </summary>
    /// <param name="finger">
    /// Finger name (e.g., "thumb", "index") or channel alias (e.g., "ch1").
    /// </param>
    /// <param name="ms">Inter-pulse interval in milliseconds.</param>
    /// <exception cref="InvalidOperationException">Thrown when <see cref="Initialize"/> has not been called.</exception>
    public void SetChannelIPI(string finger, int ms)
    {
        var wss = EnsureWss();
        int ch = FingerToChannel(finger);
        wss.SetChannelIPI(ch, ms);
    }

    /// <summary>
    /// Gets the channel amplitude.
    /// </summary>
    /// <param name="finger">
    /// Finger name (e.g., "thumb", "index") or channel alias (e.g., "ch1").
    /// </param>
    /// <returns>Amplitude in milliamps.</returns>
    /// <exception cref="InvalidOperationException">Thrown when <see cref="Initialize"/> has not been called.</exception>
    public float GetChannelAmp(string finger)
    {
        var wss = EnsureWss();
        int ch = FingerToChannel(finger);
        return wss.GetChannelAmp(ch);
    }

    /// <summary>
    /// Gets the minimum pulse width for a channel.
    /// </summary>
    /// <param name="finger">
    /// Finger name (e.g., "thumb", "index") or channel alias (e.g., "ch1").
    /// </param>
    /// <returns>Pulse width in microseconds.</returns>
    /// <exception cref="InvalidOperationException">Thrown when <see cref="Initialize"/> has not been called.</exception>
    public int GetChannelPWMin(string finger)
    {
        var wss = EnsureWss();
        int ch = FingerToChannel(finger);
        return wss.GetChannelPWMin(ch);
    }

    /// <summary>
    /// Gets the maximum pulse width for a channel.
    /// </summary>
    /// <param name="finger">
    /// Finger name (e.g., "thumb", "index") or channel alias (e.g., "ch1").
    /// </param>
    /// <returns>Pulse width in microseconds.</returns>
    /// <exception cref="InvalidOperationException">Thrown when <see cref="Initialize"/> has not been called.</exception>
    public int GetChannelPWMax(string finger)
    {
        var wss = EnsureWss();
        int ch = FingerToChannel(finger);
        return wss.GetChannelPWMax(ch);
    }

    /// <summary>
    /// Gets the inter-pulse interval for a channel.
    /// </summary>
    /// <param name="finger">
    /// Finger name (e.g., "thumb", "index") or channel alias (e.g., "ch1").
    /// </param>
    /// <returns>Inter-pulse interval in milliseconds.</returns>
    /// <exception cref="InvalidOperationException">Thrown when <see cref="Initialize"/> has not been called.</exception>
    public int GetChannelIPI(string finger)
    {
        var wss = EnsureWss();
        int ch = FingerToChannel(finger);
        return wss.GetChannelIPI(ch);
    }

    /// <summary>
    /// Checks whether a finger name or channel alias resolves to a valid channel for the current configuration.
    /// </summary>
    /// <param name="finger">
    /// Finger name (e.g., "thumb", "index") or channel alias (e.g., "ch1").
    /// </param>
    /// <returns><c>true</c> when the channel is in range; otherwise <c>false</c>.</returns>
    /// <exception cref="InvalidOperationException">Thrown when <see cref="Initialize"/> has not been called.</exception>
    public bool IsFingerValid(string finger)
    {
        var wss = EnsureWss();
        int ch = FingerToChannel(finger);
        return wss.IsChannelInRange(ch);
    }

    /// <summary>
    /// Sends a stimulation request interpreted by the active mode (model/params-dependent).
    /// </summary>
    /// <param name="finger">
    /// Finger name (e.g., "thumb", "index") or channel alias (e.g., "ch1").
    /// </param>
    /// <param name="magnitude">Magnitude value interpreted by the active mode.</param>
    /// <exception cref="InvalidOperationException">Thrown when <see cref="Initialize"/> has not been called.</exception>
    public void StimWithMode(string finger, float magnitude)
    {
        var wss = EnsureWss();
        int ch = FingerToChannel(finger);
        wss.StimWithMode(ch, magnitude);
    }

    /// <summary>
    /// Updates a channel's max/min pulse width and amplitude parameters using the conventional parameter keys.
    /// </summary>
    /// <param name="finger">
    /// Finger name (e.g., "thumb", "index") or channel alias (e.g., "ch1").
    /// </param>
    /// <param name="max">Maximum pulse width (units depend on the parameter schema; commonly microseconds).</param>
    /// <param name="min">Minimum pulse width (units depend on the parameter schema; commonly microseconds).</param>
    /// <param name="amp">Amplitude value (units depend on the parameter schema).</param>
    /// <exception cref="InvalidOperationException">Thrown when <see cref="Initialize"/> has not been called.</exception>
    /// <exception cref="ArgumentOutOfRangeException">Thrown when <paramref name="finger"/> resolves to an out-of-range channel.</exception>
    public void UpdateChannelParams(string finger, int max, int min, int amp)
    {
        var wss = EnsureWss();
        int ch = FingerToChannel(finger);
        if (!wss.IsChannelInRange(ch))
            throw new ArgumentOutOfRangeException(nameof(finger), $"Channel {ch} is not valid for current config.");

        string baseKey = $"stim.ch.{ch}";
        wss.AddOrUpdateStimParam($"{baseKey}.maxPW", max);
        wss.AddOrUpdateStimParam($"{baseKey}.minPW", min);
        wss.AddOrUpdateStimParam($"{baseKey}.amp", amp);
    }

    #endregion

    #region ==== Config and state ====

    /// <summary>
    /// Gets whether the current stimulation mode is valid for the loaded configuration.
    /// </summary>
    /// <returns><c>true</c> when the mode is valid; otherwise <c>false</c>.</returns>
    /// <exception cref="InvalidOperationException">Thrown when <see cref="Initialize"/> has not been called.</exception>
    public bool isModeValid() => EnsureWss().IsModeValid();

    /// <summary>
    /// Gets whether the underlying stack reports a ready state.
    /// </summary>
    /// <returns><c>true</c> when ready; otherwise <c>false</c>. Returns <c>false</c> before initialization.</returns>
    public bool Ready() => _wss?.Ready() ?? false;

    /// <summary>
    /// Gets whether the underlying stack reports stimulation started.
    /// </summary>
    /// <returns><c>true</c> when started; otherwise <c>false</c>. Returns <c>false</c> before initialization.</returns>
    public bool Started() => _wss?.Started() ?? false;

    /// <summary>
    /// Gets the model configuration controller.
    /// </summary>
    /// <returns>The model configuration controller instance.</returns>
    /// <exception cref="InvalidOperationException">Thrown when <see cref="Initialize"/> has not been called.</exception>
    public ModelConfigController GetModelConfigCTRL() => EnsureWss().GetModelConfigController();

    /// <summary>
    /// Gets the core configuration controller.
    /// </summary>
    /// <returns>The core configuration controller instance.</returns>
    /// <exception cref="InvalidOperationException">Thrown when <see cref="Initialize"/> has not been called.</exception>
    public CoreConfigController GetCoreConfigCTRL() => EnsureWss().GetCoreConfigController();

    /// <summary>
    /// Reloads the core configuration JSON.
    /// </summary>
    /// <exception cref="InvalidOperationException">Thrown when <see cref="Initialize"/> has not been called.</exception>
    public void LoadCoreConfigFile() => EnsureWss().LoadConfigFile();

    #endregion

    #region ==== Utility ====

    private IModelParamsCore EnsureWss()
    {
        if (_wss == null)
            throw new InvalidOperationException("Call Initialize() before using the stimulation controller.");
        return _wss;
    }

    private bool TryGetBasic(out IBasicStimulation basic)
    {
        basic = _basicWss!;
        return _basicSupported && basic != null;
    }

    private static WssTarget IntToWssTarget(int i) =>
        i switch
        {
            0 => WssTarget.Broadcast,
            1 => WssTarget.Wss1,
            2 => WssTarget.Wss2,
            3 => WssTarget.Wss3,
            _ => WssTarget.Wss1
        };

    private static int FingerToChannel(string fingerOrAlias)
    {
        if (string.IsNullOrWhiteSpace(fingerOrAlias)) return 0;

        if (fingerOrAlias.StartsWith("ch", StringComparison.OrdinalIgnoreCase) &&
            int.TryParse(fingerOrAlias.AsSpan(2), out var n))
            return n;

        return fingerOrAlias.ToLowerInvariant() switch
        {
            "thumb" => 1,
            "index" => 2,
            "middle" => 3,
            "ring" => 4,
            "pinky" or "little" => 5,
            _ => 0
        };
    }

    #endregion

    /// <summary>
    /// Shuts down the controller and releases any underlying resources.
    /// </summary>
    /// <remarks>
    /// This method performs synchronous shutdown and waits for the background tick loop to stop before
    /// returning.
    /// </remarks>
    public void Dispose()
    {
        Shutdown();
        GC.SuppressFinalize(this);
    }

    /// <summary>
    /// Shuts down the controller and releases any underlying resources.
    /// </summary>
    /// <remarks>
    /// Disposal is performed synchronously by calling <see cref="Shutdown"/>. The returned
    /// <see cref="ValueTask"/> is already complete when this method returns.
    /// </remarks>
    public ValueTask DisposeAsync()
    {
        Shutdown();
        return ValueTask.CompletedTask;
    }
}

/// <summary>
/// Configuration record for <see cref="StimulationController"/>.
/// </summary>
public enum StimulationTransportKind
{
    Serial,
    Ble,
    Test
}

/// <summary>
/// Configuration record for <see cref="StimulationController"/>.
/// </summary>
public sealed class StimulationOptions
{
    private string _configPath = Path.Combine(Environment.CurrentDirectory, "Config");

    /// <summary>
    /// Selects the transport implementation used for stimulation.
    /// </summary>
    public StimulationTransportKind Transport { get; init; } = StimulationTransportKind.Serial;

    /// <summary>
    /// Optional serial device name (e.g., "COM3" or "/dev/ttyUSB0"). Uses auto-detect when null.
    /// </summary>
    /// <remarks>Only used when <see cref="Transport"/> is <see cref="StimulationTransportKind.Serial"/>.</remarks>
    public string? SerialPort { get; init; }

    /// <summary>
    /// When true, the BLE transport scans for compatible devices and auto-selects the best candidate.
    /// </summary>
    public bool BleAutoSelect { get; init; }

    /// <summary>
    /// Exact BLE device name to connect to when auto-selection is disabled.
    /// </summary>
    public string? BleDeviceName { get; init; }

    /// <summary>
    /// Explicit BLE device identifier to connect to when auto-selection is disabled.
    /// </summary>
    public string? BleDeviceId { get; init; }

    /// <summary>Maximum number of setup retries before failing initialization.</summary>
    public int MaxSetupTries { get; init; } = 5;

    /// <summary>Directory that holds the JSON configs used by the WSS stack.</summary>
    public string ConfigPath
    {
        get => _configPath;
        init
        {
            if (string.IsNullOrWhiteSpace(value)) throw new ArgumentException("Config path cannot be empty.", nameof(ConfigPath));
            _configPath = value;
        }
    }

    /// <summary>Delay in milliseconds between background tick invocations.</summary>
    public int TickIntervalMs { get; init; } = 10;

    internal void Validate()
    {
        if (TickIntervalMs <= 0)
            throw new ArgumentOutOfRangeException(nameof(TickIntervalMs), "Tick interval must be positive.");

        if (Transport == StimulationTransportKind.Ble &&
            !BleAutoSelect &&
            string.IsNullOrWhiteSpace(BleDeviceId) &&
            string.IsNullOrWhiteSpace(BleDeviceName))
        {
            throw new ArgumentException("BLE transport requires --ble-auto, --ble-device-id, or --ble-device-name.");
        }

        Directory.CreateDirectory(ConfigPath);
    }

    /// <summary>
    /// Creates default options using a <c>Config</c> directory under the current working directory.
    /// </summary>
    public static StimulationOptions CreateDefault() => new();
}
