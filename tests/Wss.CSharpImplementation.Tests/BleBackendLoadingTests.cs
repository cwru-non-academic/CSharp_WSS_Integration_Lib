using System.Reflection;
using System.Runtime.Loader;
using System.Runtime.InteropServices;
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
            Assert.That(backendLoadContext, Is.SameAs(AssemblyLoadContext.Default));
            Assert.That(Path.GetDirectoryName(backendAssembly.Location),
                Is.EqualTo(expectedBackendDirectory).IgnoreCase);
        });

        foreach (string dependencyName in dependencyNames)
        {
            Assembly dependency = Assembly.LoadFrom(Path.Combine(expectedBackendDirectory, dependencyName + ".dll"));
            Assert.Multiple(() =>
            {
                Assert.That(dependency.GetName().Name, Is.EqualTo(dependencyName));
                Assert.That(AssemblyLoadContext.GetLoadContext(dependency), Is.SameAs(AssemblyLoadContext.Default));
                // System facades may unify with the host BCL; package backends must not.
                if (!dependencyName.StartsWith("System.", StringComparison.Ordinal))
                    Assert.That(Path.GetDirectoryName(dependency.Location),
                        Is.EqualTo(expectedBackendDirectory).IgnoreCase);
            });
        }

        foreach (Assembly shared in new[] { typeof(ITransport).Assembly, typeof(SerialPortTransport).Assembly, typeof(BleNusTransport).Assembly })
        {
            Assert.That(AssemblyLoadContext.GetLoadContext(shared), Is.SameAs(AssemblyLoadContext.Default));
            Assert.That(AppDomain.CurrentDomain.GetAssemblies().Count(a => a.GetName().Name == shared.GetName().Name), Is.EqualTo(1));
        }
        Assert.That(typeof(SerialPortTransport).Assembly.GetName().Name, Is.EqualTo("WSS.Transport.Serial"));
        Assert.That(typeof(BleNusTransport).Assembly.GetForwardedTypes(), Is.Empty);
        Assert.That(AppDomain.CurrentDomain.GetAssemblies().Select(a => a.GetName().Name),
            Has.None.EqualTo("WinRT.Runtime").And.None.EqualTo("Microsoft.Windows.SDK.NET"));
        if (OperatingSystem.IsWindows())
        {
            nint native = NativeLibrary.Load(Path.Combine(expectedBackendDirectory, "WssBleWindows.dll"));
            try
            {
                Assert.That(NativeLibrary.TryGetExport(native, "wss_test_mode", out _), Is.False,
                    "The distributed DLL must be production, not the test shim.");
                foreach (string export in new[] { "wss_ble_get_abi_info", "wss_ble_nus_connect", "wss_ble_nus_write", "wss_ble_nus_disconnect" })
                    Assert.That(NativeLibrary.GetExport(native, export), Is.Not.EqualTo(nint.Zero));
            }
            finally { NativeLibrary.Free(native); }
        }
    }

    private static (string Platform, string BackendName, string[] DependencyNames) GetPlatformExpectation()
    {
        if (OperatingSystem.IsWindows())
        {
            return (
                "windows",
                "WSS.Transport.BLE.Windows",
                ["WSS.Transport.BLE.Windows.Native"]);
        }

        if (OperatingSystem.IsLinux())
        {
            return (
                "linux",
                "WSS.Transport.BLE.Linux",
                ["Linux.Bluetooth", "Tmds.DBus", "Microsoft.Bcl.AsyncInterfaces",
                 "System.Reflection.Emit", "System.Reflection.Emit.ILGeneration", "System.Threading.Tasks.Extensions"]);
        }

        throw new PlatformNotSupportedException("The BLE integration smoke supports Windows and Linux only.");
    }
}
