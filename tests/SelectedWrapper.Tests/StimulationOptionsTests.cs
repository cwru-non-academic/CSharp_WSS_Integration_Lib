using NUnit.Framework;

namespace Wss.CSharpImplementation.Tests;

[TestFixture]
public sealed class StimulationOptionsTests
{
    [Test]
    public void DefaultTransportIsSerial()
    {
        Assert.That(StimulationOptions.CreateDefault().Transport, Is.EqualTo(StimulationTransportKind.Serial));
    }

    [TestCase(StimulationTransportKind.Serial)]
    [TestCase(StimulationTransportKind.Test)]
    [TestCase(StimulationTransportKind.Conformance)]
    public void NonBleTransportDoesNotRequireBleSelector(StimulationTransportKind transport)
    {
        string directory = CreateTemporaryDirectory();
        try
        {
            Assert.DoesNotThrow(() =>
            {
                using var controller = new StimulationController(new StimulationOptions
                {
                    ConfigPath = directory,
                    Transport = transport
                });
            });
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Test]
    public void BleTransportRequiresDeviceSelection()
    {
        string directory = CreateTemporaryDirectory();
        try
        {
            Assert.That(
                () => new StimulationController(new StimulationOptions
                {
                    ConfigPath = directory,
                    Transport = StimulationTransportKind.Ble
                }),
                Throws.ArgumentException.With.Message.Contains("BLE transport requires"));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [TestCase(true, null, null)]
    [TestCase(false, "WSS", null)]
    [TestCase(false, null, "device-id")]
    public void BleTransportAcceptsConfiguredSelector(bool autoSelect, string? deviceName, string? deviceId)
    {
        string directory = CreateTemporaryDirectory();
        try
        {
            Assert.DoesNotThrow(() =>
            {
                using var controller = new StimulationController(new StimulationOptions
                {
                    ConfigPath = directory,
                    Transport = StimulationTransportKind.Ble,
                    BleAutoSelect = autoSelect,
                    BleDeviceName = deviceName,
                    BleDeviceId = deviceId
                });
            });
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Test]
    public void UndefinedTransportIsRejected()
    {
        string directory = CreateTemporaryDirectory();
        try
        {
            Assert.That(
                () => new StimulationController(new StimulationOptions
                {
                    ConfigPath = directory,
                    Transport = (StimulationTransportKind)int.MaxValue
                }),
                Throws.TypeOf<ArgumentOutOfRangeException>());
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    private static string CreateTemporaryDirectory()
    {
        string directory = Path.Combine(Path.GetTempPath(), $"wss-options-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        return directory;
    }
}
