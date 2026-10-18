using System.IO.Ports;
using System.Security.Cryptography;
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
            "net8.0",
            "System.IO.Ports.dll");

        Assert.That(
            typeof(SerialPort).Assembly.Location,
            Does.EndWith(expectedSuffix).IgnoreCase,
            "System.IO.Ports must be loaded from the platform-specific NuGet runtime asset.");
        Assert.That(typeof(SerialPort).Assembly.GetName().Version!.Major, Is.EqualTo(8));
        string? artifactRoot = Environment.GetEnvironmentVariable("WSS_ARTIFACT_DIR");
        if (!string.IsNullOrEmpty(artifactRoot))
        {
            string candidateRuntime = Path.Combine(artifactRoot, expectedSuffix);
            Assert.That(File.Exists(candidateRuntime), Is.True, candidateRuntime);
            Assert.That(SHA256.HashData(File.ReadAllBytes(typeof(SerialPort).Assembly.Location)),
                Is.EqualTo(SHA256.HashData(File.ReadAllBytes(candidateRuntime))),
                "The loaded Ports runtime must match the verified candidate.");
        }
    }
}
