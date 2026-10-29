# WSS C# Integration Library

Use WSS from a .NET application through `StimulationController`, which owns the
Core, parameter and model layers and their background update loop. For a ready-to-run
application, use the [C# CLI](https://github.com/cwru-non-academic/CLI_CSharp_WSS_Application#readme).

## Prerequisites

- .NET 9 SDK and access to NuGet for the first restore.
- Keep the complete committed `lib/` distribution, including `backends/` and
  `runtimes/`, with the library. Do not replace individual DLLs from another release.
- Serial and BLE are supported on Windows, Linux and macOS. Windows BLE uses an
  x64 process; Linux BLE requires BlueZ and system D-Bus. Configure the host's
  device access before selecting a physical transport.

## Add to an application

Run from your application's repository root (replace `MyApp.csproj` with your project):

```bash
git submodule add https://github.com/cwru-non-academic/CSharp_WSS_Integration_Lib.git external/wss-csharp
git submodule update --init --recursive
dotnet add MyApp.csproj reference external/wss-csharp/src/Wss.CSharpImplementation.csproj
```

If your application's project file is at the repository root, exclude the
submodule's source from its default SDK compile glob by adding this inside
`MyApp.csproj` before building:

```xml
<ItemGroup>
  <Compile Remove="external/wss-csharp/**/*.cs" />
</ItemGroup>
```

Alternatively, keep the application project in a sibling directory such as
`src/MyApp/`, outside `external/`, and use that project path in the commands.
The consuming project must target a framework compatible with `net9.0`.
Commit the submodule pointer so collaborators use the same library revision.
After cloning the application, run `git submodule update --init --recursive` to
restore that pinned revision.

Then build the application:

```bash
dotnet build MyApp.csproj
```

## First run without hardware

Use this as a console application's `Program.cs`. Test mode does not open Serial
or BLE devices. The example creates configuration in `Config/`, waits up to five
seconds for initialization, reports state, and disposes the controller.

```csharp
using System.Diagnostics;
using Wss.CSharpImplementation;

using var controller = new StimulationController(new StimulationOptions
{
    ConfigPath = Path.GetFullPath("Config"),
    Transport = StimulationTransportKind.Test
});
controller.Initialize();
var timeout = Stopwatch.StartNew();
while (!controller.Started() && timeout.Elapsed < TimeSpan.FromSeconds(5))
    await Task.Delay(10);
if (!controller.Started())
    throw new TimeoutException("WSS test initialization timed out.");
Console.WriteLine($"Started: {controller.Started()}, Ready: {controller.Ready()}");
```

Resolve the application-owned configuration directory before creating the
controller. `Initialize()` starts its background ticks; callers do not need their
own `Tick()` loop. Dispose the controller on exit. Test mode is a simulated
lifecycle; `Conformance` is the separate deterministic emulator used by the tests.

For hardware, select `StimulationTransportKind.Serial` with `SerialPort`, or
`StimulationTransportKind.Ble` with `BleDeviceName`, `BleDeviceId` or
`BleAutoSelect`. The default transport is Serial, so select Test explicitly for
software-only experiments. Review configuration and device setup before using
stimulation methods.

## Build and test the library

```bash
dotnet build Wss.CSharpImplementation.sln -c Release
dotnet test Wss.CSharpImplementation.sln -c Release
```

## Further guidance

- [Shared documentation](https://cwru-non-academic.github.io/WSS_Documentation/): architecture, lifecycle, configuration and API reference.
- [C# CLI README](https://github.com/cwru-non-academic/CLI_CSharp_WSS_Application#readme): interactive use and deterministic conformance startup.
- [Dependency validation and maintenance](docs/maintenance.md): universal artifact inputs, CI and promotion tooling.
