using System.Reflection;
using System.Runtime.Loader;
using NUnit.Framework;
using Wss.Transports;

namespace Wss.CSharpImplementation.Tests;

[TestFixture]
public sealed class BleBackendLoadingTests
{
    [Test]
    public void FacadeLoadsCurrentPlatformBackendAndDependencies()
    {
        if (OperatingSystem.IsMacOS())
            Assert.Ignore("macOS BLE backend is not implemented yet.");

        (string platform, string backendName, string[] dependencyNames) = GetPlatformExpectation();
        string expectedBackendDirectory = Path.GetFullPath(
            Path.Combine(AppContext.BaseDirectory, "backends", platform));

        using var facade = new BleNusTransport(new BleNusTransportOptions
        {
            DeviceName = "ci-load-only"
        });

        Assembly backendAssembly = AssemblyLoadContext.All
            .SelectMany(context => context.Assemblies)
            .Single(assembly => assembly.GetName().Name == backendName);
        AssemblyLoadContext? backendLoadContext = AssemblyLoadContext.GetLoadContext(backendAssembly);

        Assert.Multiple(() =>
        {
            Assert.That(backendLoadContext, Is.Not.Null);
            Assert.That(backendLoadContext, Is.Not.SameAs(AssemblyLoadContext.Default));
            Assert.That(Path.GetDirectoryName(backendAssembly.Location),
                Is.EqualTo(expectedBackendDirectory).IgnoreCase);
        });

        foreach (string dependencyName in dependencyNames)
        {
            Assembly dependency = backendLoadContext!.LoadFromAssemblyName(new AssemblyName(dependencyName));
            Assert.Multiple(() =>
            {
                Assert.That(dependency.GetName().Name, Is.EqualTo(dependencyName));
                Assert.That(Path.GetDirectoryName(dependency.Location),
                    Is.EqualTo(expectedBackendDirectory).IgnoreCase);
            });
        }
    }

    private static (string Platform, string BackendName, string[] DependencyNames) GetPlatformExpectation()
    {
        if (OperatingSystem.IsWindows())
        {
            return (
                "windows",
                "WSS.Transport.BLE.Windows",
                ["Microsoft.Windows.SDK.NET", "WinRT.Runtime"]);
        }

        if (OperatingSystem.IsLinux())
        {
            return (
                "linux",
                "WSS.Transport.BLE.Linux",
                ["Linux.Bluetooth", "Tmds.DBus"]);
        }

        throw new PlatformNotSupportedException("The BLE integration smoke supports Windows and Linux only.");
    }
}
