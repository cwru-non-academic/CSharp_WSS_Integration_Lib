using System.Reflection;
using System.Runtime.Loader;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using NUnit.Framework;
using Wss.Transports;

namespace Wss.CSharpImplementation.Tests;

[TestFixture]
public sealed class BleBackendLoadingTests
{
    [Test]
    public void FacadeLoadsCurrentPlatformBackendAndDependencies()
    {
        bool declaresMacOS = DeclaresMacOSBackend();
        AssertMacOSPayloadPresence(declaresMacOS);
        if (OperatingSystem.IsMacOS() && !declaresMacOS)
        {
            Assert.Throws<PlatformNotSupportedException>(() =>
            {
                using var unsupported = new BleNusTransport(new BleNusTransportOptions { DeviceName = "ci-load-only" });
            }, "A legacy payload must explicitly reject macOS BLE; this is not runtime support.");
            TestContext.Progress.WriteLine("Legacy payload: macOS BLE explicitly unsupported (asserted); native BLE operation NOT EXECUTED.");
            return;
        }

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
        else if (OperatingSystem.IsMacOS())
        {
            Assert.That(backendAssembly.GetCustomAttribute<TargetFrameworkAttribute>()?.FrameworkName,
                Is.EqualTo(".NETStandard,Version=v2.0"));
            nint native = NativeLibrary.Load(Path.Combine(expectedBackendDirectory, "libwss_macos_ble.dylib"));
            try
            {
                foreach (string export in new[] { "wss_mac_abi", "wss_mac_create", "wss_mac_destroy", "wss_mac_submit", "wss_mac_cancel" })
                    Assert.That(NativeLibrary.GetExport(native, export), Is.Not.EqualTo(nint.Zero));
                var abi = Marshal.GetDelegateForFunctionPointer<MacAbi>(NativeLibrary.GetExport(native, "wss_mac_abi"));
                Assert.That(abi(), Is.EqualTo(0x00010000u), "macOS native ABI must match the managed adapter.");
                Type bootstrap = backendAssembly.GetType("Wss.Transports.Backends.MacOS.MacBleBackend", throwOnError: true)!;
                bootstrap.GetMethod("VerifyNativeAbi")!.Invoke(null, null); // Real managed P/Invoke create/destroy; no CBCentralManager.
                bootstrap.GetMethod("Register")!.Invoke(null, null);
                bootstrap.GetMethod("Register")!.Invoke(null, null);
                using var registered = new BleNusTransport(new BleNusTransportOptions { DeviceName = "ci-load-only" });
                Assert.That(registered.IsConnected, Is.False);
            }
            finally { NativeLibrary.Free(native); }
            TestContext.Progress.WriteLine("macOS BLE declared backend/native ABI/load/activation: PASS. Bluetooth authorization, adapter and peripheral I/O NOT EXECUTED.");
        }
    }

    private static bool DeclaresMacOSBackend()
    {
        // Read the facade's actual capability mapping. File absence alone cannot
        // turn a broken, declared macOS distribution into a legacy success.
        Type loader = typeof(BleNusTransport).Assembly.GetType("Wss.Transports.Backends.BleBackendLoader", throwOnError: true)!;
        MethodInfo identity = loader.GetMethod("GetBackendIdentity", BindingFlags.NonPublic | BindingFlags.Static)
            ?? throw new AssertionException("Unknown BLE facade capability contract; cannot infer unsupported macOS.");
        try
        {
            var mapping = ((string AssemblyName, string FactoryName))identity.Invoke(null, ["macos"])!;
            Assert.That(mapping.AssemblyName, Is.EqualTo("WSS.Transport.BLE.MacOS"));
            Assert.That(mapping.FactoryName, Is.EqualTo("Wss.Transports.Backends.MacOS.MacBleNusBackendFactory"));
            return true;
        }
        catch (TargetInvocationException exception) when
            (exception.InnerException is ArgumentOutOfRangeException argument && argument.ParamName == "platform")
        {
            return false;
        }
    }

    private static void AssertMacOSPayloadPresence(bool declared)
    {
        string directory = Path.Combine(AppContext.BaseDirectory, "backends", "macos");
        string[] files = Directory.Exists(directory)
            ? Directory.GetFiles(directory, "*", SearchOption.AllDirectories).Select(path => Path.GetRelativePath(directory, path)).ToArray()
            : [];
        Assert.That(files, Is.EquivalentTo(declared
            ? new[] { "WSS.Transport.BLE.MacOS.dll", "libwss_macos_ble.dylib" }
            : Array.Empty<string>()), "Declared macOS backend requires exactly its managed adapter and native dylib; legacy facades must not carry orphan macOS files.");
    }

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate uint MacAbi();

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
        if (OperatingSystem.IsMacOS())
            return ("macos", "WSS.Transport.BLE.MacOS", []);

        throw new PlatformNotSupportedException("The BLE integration smoke supports Windows, Linux and macOS only.");
    }
}
