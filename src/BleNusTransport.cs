using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using InTheHand.Bluetooth;
using Wss.CoreModule;

namespace HFI.Wss;

/// <summary>
/// BLE transport backed by the Nordic UART Service (NUS).
/// </summary>
/// <remarks>
/// This is a low-level byte transport only. Outbound messages are written with response
/// to the NUS RX characteristic, inbound messages arrive as notifications from the NUS
/// TX characteristic, and writes are serialized so only one GATT write is in flight at a time.
/// Device selection follows <see cref="BleNusTransportOptions.AutoSelectDevice"/>:
/// when enabled, the transport scans for compatible BLE devices and chooses the best
/// valid candidate; otherwise it requires an explicit <see cref="BleNusTransportOptions.DeviceId"/>
/// or <see cref="BleNusTransportOptions.DeviceName"/>.
/// </remarks>
public sealed class BleNusTransport : ITransport, IDisposable
{
    public static readonly Guid DefaultServiceUuid = Guid.Parse("6E400001-B5A3-F393-E0A9-E50E24DCCA9E");
    public static readonly Guid DefaultWriteCharacteristicUuid = Guid.Parse("6E400002-B5A3-F393-E0A9-E50E24DCCA9E");
    public static readonly Guid DefaultNotifyCharacteristicUuid = Guid.Parse("6E400003-B5A3-F393-E0A9-E50E24DCCA9E");

    private readonly BleNusTransportOptions _options;
    private readonly SemaphoreSlim _sendGate = new(1, 1);
    private readonly object _gate = new();

    private BluetoothDevice? _device;
    private RemoteGattServer? _gatt;
    private GattCharacteristic? _writeCharacteristic;
    private GattCharacteristic? _notifyCharacteristic;
    private bool _disposed;

    public BleNusTransport(BleNusTransportOptions options)
    {
        _options = options ?? throw new ArgumentNullException(nameof(options));
        _options.Validate();
    }

    public BleNusTransport(string deviceName)
        : this(new BleNusTransportOptions { DeviceName = deviceName })
    {
    }

    public bool IsConnected
    {
        get
        {
            lock (_gate)
            {
                return _gatt != null && _writeCharacteristic != null && _notifyCharacteristic != null;
            }
        }
    }

    public event Action<byte[]>? BytesReceived;

    public async Task ConnectAsync(CancellationToken ct = default)
    {
        ThrowIfDisposed();

        if (IsConnected)
        {
            return;
        }

        if (_options.AutoSelectDevice)
        {
            BluetoothDevice? device = await SelectAutoDeviceAsync(ct).ConfigureAwait(false);
            if (device == null)
            {
                throw new InvalidOperationException("Unable to find a compatible BLE device exposing the required service and characteristics.");
            }

            await ConnectDeviceAsync(device, ct).ConfigureAwait(false);
            return;
        }

        BluetoothDevice configuredDevice = await ResolveConfiguredDeviceAsync(ct).ConfigureAwait(false);
        await ConnectDeviceAsync(configuredDevice, ct).ConfigureAwait(false);
    }

    public async Task DisconnectAsync(CancellationToken ct = default)
    {
        var (device, gatt, notifyCharacteristic) = TakeAndClearConnectionState();

        if (device != null)
        {
            device.GattServerDisconnected -= OnGattServerDisconnected;
        }

        if (notifyCharacteristic != null)
        {
            notifyCharacteristic.CharacteristicValueChanged -= OnCharacteristicValueChanged;

            try
            {
                await notifyCharacteristic.StopNotificationsAsync().WaitAsync(ct).ConfigureAwait(false);
            }
            catch (Exception ex)
            {
                Log.Error(ex, "Failed to stop BLE notifications.");
            }
        }

        try
        {
            gatt?.Disconnect();
        }
        catch (Exception ex)
        {
            Log.Error(ex, "Failed to disconnect BLE transport.");
        }
    }

    public async Task SendAsync(byte[] data, CancellationToken ct = default)
    {
        ThrowIfDisposed();

        ArgumentNullException.ThrowIfNull(data);

        GattCharacteristic? writeCharacteristic;
        lock (_gate)
        {
            writeCharacteristic = _writeCharacteristic;
        }

        if (writeCharacteristic == null)
        {
            throw new InvalidOperationException("BLE transport is not connected.");
        }

        await _sendGate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            await writeCharacteristic.WriteValueWithResponseAsync(data).WaitAsync(ct).ConfigureAwait(false);
        }
        finally
        {
            _sendGate.Release();
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;

        try
        {
            DisconnectAsync().GetAwaiter().GetResult();
        }
        catch (Exception ex)
        {
            Log.Error(ex, "Error disposing BLE transport.");
        }

        _sendGate.Dispose();
    }

    private async Task<BluetoothDevice> ResolveConfiguredDeviceAsync(CancellationToken ct)
    {
        if (!string.IsNullOrWhiteSpace(_options.DeviceId))
        {
            BluetoothDevice? device = await BluetoothDevice.FromIdAsync(_options.DeviceId!).WaitAsync(ct).ConfigureAwait(false);
            return device ?? throw new InvalidOperationException($"Unable to find BLE device with id '{_options.DeviceId}'.");
        }

        BluetoothDevice? namedDevice = await ScanForNamedDeviceAsync(ct).ConfigureAwait(false);
        return namedDevice ?? throw new InvalidOperationException($"Unable to find BLE device matching '{_options.DeviceName}'.");
    }

    private async Task<BluetoothDevice?> ScanForNamedDeviceAsync(CancellationToken ct)
    {
        var filter = new BluetoothLEScanFilter
        {
            Name = _options.DeviceName!
        };
        filter.Services.Add(_options.ServiceUuid);

        IReadOnlyCollection<BluetoothDevice> devices = await ScanForDevicesAsync(filter, ct).ConfigureAwait(false);
        return devices.FirstOrDefault(device => string.Equals(device.Name, _options.DeviceName, StringComparison.OrdinalIgnoreCase));
    }

    private async Task<BluetoothDevice?> SelectAutoDeviceAsync(CancellationToken ct)
    {
        var filter = new BluetoothLEScanFilter();
        filter.Services.Add(_options.ServiceUuid);

        IReadOnlyCollection<BluetoothDevice> devices = await ScanForDevicesAsync(filter, ct).ConfigureAwait(false);
        var candidates = new List<BleAutoSelectionCandidate>();

        foreach (BluetoothDevice device in devices)
        {
            ct.ThrowIfCancellationRequested();

            BleAutoSelectionCandidate? candidate = await TryCreateAutoSelectionCandidateAsync(device, ct).ConfigureAwait(false);
            if (candidate != null)
            {
                candidates.Add(candidate);
            }
        }

        return candidates
            .OrderByDescending(candidate => candidate.IsPaired)
            .ThenByDescending(candidate => candidate.Rssi)
            .Select(candidate => candidate.Device)
            .FirstOrDefault();
    }

    private async Task<IReadOnlyCollection<BluetoothDevice>> ScanForDevicesAsync(BluetoothLEScanFilter filter, CancellationToken ct)
    {
        var options = new RequestDeviceOptions
        {
            AcceptAllDevices = false,
            Timeout = _options.ScanTimeout
        };
        options.Filters.Add(filter);

        return await Bluetooth.ScanForDevicesAsync(options, ct).WaitAsync(ct).ConfigureAwait(false);
    }

    private void OnCharacteristicValueChanged(object? sender, GattCharacteristicValueChangedEventArgs args)
    {
        if (args.Error != null)
        {
            Log.Error(args.Error, "BLE notification error.");
            return;
        }

        byte[]? value = args.Value;
        if (value == null || value.Length == 0)
        {
            return;
        }

        try
        {
            BytesReceived?.Invoke(value);
        }
        catch (Exception ex)
        {
            Log.Error(ex, "BLE BytesReceived handler failed.");
        }
    }

    private void OnGattServerDisconnected(object? sender, EventArgs args)
    {
        lock (_gate)
        {
            ClearConnectionStateUnsafe();
        }
    }

    private async Task ConnectDeviceAsync(BluetoothDevice device, CancellationToken ct)
    {
        if (_options.PairBeforeConnect && !device.IsPaired)
        {
            await device.PairAsync().WaitAsync(ct).ConfigureAwait(false);
        }

        RemoteGattServer gatt = device.Gatt ?? throw new InvalidOperationException("Selected BLE device does not expose a GATT server.");

        await gatt.ConnectAsync().WaitAsync(ct).ConfigureAwait(false);
        (GattCharacteristic writeCharacteristic, GattCharacteristic notifyCharacteristic) =
            await ResolveTransportCharacteristicsAsync(device, gatt, ct).ConfigureAwait(false);

        notifyCharacteristic.CharacteristicValueChanged += OnCharacteristicValueChanged;

        try
        {
            await notifyCharacteristic.StartNotificationsAsync().WaitAsync(ct).ConfigureAwait(false);
        }
        catch
        {
            notifyCharacteristic.CharacteristicValueChanged -= OnCharacteristicValueChanged;
            gatt.Disconnect();
            throw;
        }

        device.GattServerDisconnected += OnGattServerDisconnected;

        lock (_gate)
        {
            _device = device;
            _gatt = gatt;
            _writeCharacteristic = writeCharacteristic;
            _notifyCharacteristic = notifyCharacteristic;
        }
    }

    private async Task<(GattCharacteristic WriteCharacteristic, GattCharacteristic NotifyCharacteristic)> ResolveTransportCharacteristicsAsync(
        BluetoothDevice device,
        RemoteGattServer gatt,
        CancellationToken ct)
    {
        GattService? service = await gatt.GetPrimaryServiceAsync(_options.ServiceUuid).WaitAsync(ct).ConfigureAwait(false);
        if (service == null)
        {
            throw new InvalidOperationException($"BLE device '{device.Name}' does not expose service '{_options.ServiceUuid}'.");
        }

        GattCharacteristic? writeCharacteristic = await service.GetCharacteristicAsync(_options.WriteCharacteristicUuid).WaitAsync(ct).ConfigureAwait(false);
        if (writeCharacteristic == null)
        {
            throw new InvalidOperationException($"BLE device '{device.Name}' is missing write characteristic '{_options.WriteCharacteristicUuid}'.");
        }

        GattCharacteristic? notifyCharacteristic = await service.GetCharacteristicAsync(_options.NotifyCharacteristicUuid).WaitAsync(ct).ConfigureAwait(false);
        if (notifyCharacteristic == null)
        {
            throw new InvalidOperationException($"BLE device '{device.Name}' is missing notify characteristic '{_options.NotifyCharacteristicUuid}'.");
        }

        if (!writeCharacteristic.Properties.HasFlag(GattCharacteristicProperties.Write))
        {
            throw new InvalidOperationException("BLE write characteristic does not support write-with-response.");
        }

        if (!notifyCharacteristic.Properties.HasFlag(GattCharacteristicProperties.Notify) &&
            !notifyCharacteristic.Properties.HasFlag(GattCharacteristicProperties.Indicate))
        {
            throw new InvalidOperationException("BLE notify characteristic does not support notifications or indications.");
        }

        return (writeCharacteristic, notifyCharacteristic);
    }

    private async Task<BleAutoSelectionCandidate?> TryCreateAutoSelectionCandidateAsync(BluetoothDevice device, CancellationToken ct)
    {
        RemoteGattServer? gatt = device.Gatt;
        if (gatt == null)
        {
            return null;
        }

        try
        {
            await gatt.ConnectAsync().WaitAsync(ct).ConfigureAwait(false);
            await ResolveTransportCharacteristicsAsync(device, gatt, ct).ConfigureAwait(false);

            int rssi;
            try
            {
                rssi = await gatt.ReadRssi().WaitAsync(ct).ConfigureAwait(false);
            }
            catch
            {
                rssi = int.MinValue;
            }

            return new BleAutoSelectionCandidate(device, device.IsPaired, rssi);
        }
        catch
        {
            return null;
        }
        finally
        {
            try
            {
                gatt.Disconnect();
            }
            catch
            {
            }
        }
    }

    private (BluetoothDevice? Device, RemoteGattServer? Gatt, GattCharacteristic? NotifyCharacteristic) TakeAndClearConnectionState()
    {
        lock (_gate)
        {
            var state = (_device, _gatt, _notifyCharacteristic);
            ClearConnectionStateUnsafe();
            return state;
        }
    }

    private void ClearConnectionStateUnsafe()
    {
        _device = null;
        _gatt = null;
        _writeCharacteristic = null;
        _notifyCharacteristic = null;
    }

    private void ThrowIfDisposed()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
    }

    public static BleNusTransportOptions CreateDefaultOptions(string deviceName) => new() { DeviceName = deviceName };

    private sealed record BleAutoSelectionCandidate(BluetoothDevice Device, bool IsPaired, int Rssi);
}

/// <summary>
/// Configuration for <see cref="BleNusTransport"/>.
/// </summary>
public sealed class BleNusTransportOptions
{
    /// <summary>
    /// Explicit BLE device identifier to connect to when <see cref="AutoSelectDevice"/> is disabled.
    /// When provided, it takes precedence over <see cref="DeviceName"/>.
    /// </summary>
    public string? DeviceId { get; init; }

    /// <summary>
    /// Exact BLE device name to scan for when <see cref="AutoSelectDevice"/> is disabled and
    /// <see cref="DeviceId"/> is not provided.
    /// </summary>
    public string? DeviceName { get; init; }

    /// <summary>
    /// Required BLE service UUID. Auto-select only considers devices that expose this service.
    /// </summary>
    public Guid ServiceUuid { get; init; } = BleNusTransport.DefaultServiceUuid;

    /// <summary>
    /// Required BLE write characteristic UUID. Auto-select rejects devices that do not expose it
    /// with write-with-response support.
    /// </summary>
    public Guid WriteCharacteristicUuid { get; init; } = BleNusTransport.DefaultWriteCharacteristicUuid;

    /// <summary>
    /// Required BLE notification characteristic UUID. Auto-select rejects devices that do not expose it
    /// with notify or indicate support.
    /// </summary>
    public Guid NotifyCharacteristicUuid { get; init; } = BleNusTransport.DefaultNotifyCharacteristicUuid;

    /// <summary>
    /// Maximum scan duration used for configured-name lookup and auto-selection.
    /// </summary>
    public TimeSpan? ScanTimeout { get; init; } = TimeSpan.FromSeconds(10);

    /// <summary>
    /// When true, attempts to pair the selected BLE device before connecting.
    /// </summary>
    public bool PairBeforeConnect { get; init; }

    /// <summary>
    /// When true, scans for compatible BLE devices and auto-selects the best valid candidate.
    /// Auto-selection only accepts devices that expose the configured service and both required
    /// characteristics with the expected properties, then prefers paired devices and stronger RSSI.
    /// When false, the caller must provide <see cref="DeviceId"/> or <see cref="DeviceName"/>.
    /// </summary>
    public bool AutoSelectDevice { get; init; }

    internal void Validate()
    {
        if (!AutoSelectDevice && string.IsNullOrWhiteSpace(DeviceId) && string.IsNullOrWhiteSpace(DeviceName))
        {
            throw new ArgumentException("A BLE device id or device name must be provided when AutoSelectDevice is disabled.");
        }

        if (ServiceUuid == Guid.Empty)
        {
            throw new ArgumentException("BLE service UUID must be provided.", nameof(ServiceUuid));
        }

        if (WriteCharacteristicUuid == Guid.Empty)
        {
            throw new ArgumentException("BLE write characteristic UUID must be provided.", nameof(WriteCharacteristicUuid));
        }

        if (NotifyCharacteristicUuid == Guid.Empty)
        {
            throw new ArgumentException("BLE notify characteristic UUID must be provided.", nameof(NotifyCharacteristicUuid));
        }
    }
}
