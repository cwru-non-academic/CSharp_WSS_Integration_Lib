using System.IO.Ports;
using NUnit.Framework;
using Wss.Transports;

namespace Wss.CSharpImplementation.Tests;

[TestFixture]
public sealed class SerialRuntimeSelectionTests
{
    [Test]
    public void SerialTransportUsesPlatformRuntimeImplementation()
    {
        string portName = OperatingSystem.IsWindows() ? "COM1" : "/dev/ttyWssIntegrationSmoke";

        Assert.DoesNotThrow(() =>
        {
            using var transport = new SerialPortTransport(new SerialPortTransportOptions
            {
                PortName = portName,
                AutoSelectPort = false
            });
        });

        string platformDirectory = OperatingSystem.IsWindows() ? "win" : "unix";
        string expectedSuffix = Path.Combine(
            "runtimes",
            platformDirectory,
            "lib",
            "net9.0",
            "System.IO.Ports.dll");

        Assert.That(
            typeof(SerialPort).Assembly.Location,
            Does.EndWith(expectedSuffix).IgnoreCase,
            "System.IO.Ports must be loaded from the platform-specific NuGet runtime asset.");
    }
}
