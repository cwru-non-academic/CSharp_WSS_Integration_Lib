# WSS C# Integration Library

Reusable .NET wrapper around the WSS stimulation stack.

Requires the .NET 9 SDK.

This repository now owns the integration/library layer only. The CLI application should live in a separate repo and consume this library as a git submodule.

All documentation about the API and other implementations can be found in [GitHub Pages](https://cwru-non-academic.github.io/WSS_Documentation/).

## Layout

- `src/` - library project containing `StimulationController` and `StimulationOptions`
- `lib/` - vendor-provided and compatibility `.dll` dependencies required by the library
- `temp/CLI_CSharp_WSS_Application/` - temporary handoff copy of the files that belong in the separate CLI repo

## Build

Install the .NET 9 SDK first. This library now targets `net9.0` so BLE transport support can use the Linux provider path from `InTheHand.BluetoothLE`.

```bash
dotnet restore Wss.CSharpImplementation.sln
dotnet build Wss.CSharpImplementation.sln -c Release
```

By default, the project resolves WSS assemblies from `lib/`. To build and test against an
extracted WSS release artifact instead, set `WSS_ARTIFACT_DIR`:

```bash
dotnet test tests/Wss.CSharpImplementation.Tests/Wss.CSharpImplementation.Tests.csproj -c Release \
  -p:WSS_ARTIFACT_DIR=/path/to/extracted/WSS-Serial-v0.3.0-rc.7
```

`WSS_ARTIFACT_DIR` overrides the Core and companion runtime artifacts. Serial and BLE transport
implementations come from `lib/WSS.Transport.BLE.dll` unless `WSS_BLE_ARTIFACT_DIR` is set to a
directory containing a matched consolidated transport artifact.

## Emulator Conformance Mode

`StimulationOptions.Transport` provides four distinct transport choices:

- `StimulationTransportKind.Serial` is the default and uses the Serial transport.
- `StimulationTransportKind.Ble` uses `BleNusTransport`.
- `StimulationTransportKind.Test` uses `TestModeTransport`.
- `StimulationTransportKind.Conformance` uses the deterministic in-memory `EmulatedWssTransport`.

The enum makes transport choices mutually exclusive. Applications using conformance mode can obtain
the WSS Core-owned conformance capability without accessing or replacing the transport:

```csharp
using var controller = new StimulationController(new StimulationOptions
{
    ConfigPath = configDirectory,
    Transport = StimulationTransportKind.Conformance
});

controller.Initialize();
if (controller.TryGetConformance(out var conformance))
{
    // Poll controller.Started() and conformance.StimulationHistory with a finite timeout first.
    var initialization = conformance.ValidateInitialization();
}
```

The C# integration library only exposes this capability. Validation rules and observations remain implemented
by WSS Core's `IWssConformance`.

## Transport support

- Serial transport remains available through the vendor serial stack.
- Test transport remains available for simulated runs.
- BLE transport is exposed through `BleNusTransport` and is intended for Nordic UART Service-compatible devices.
- The current WSS BLE path assumes an unpaired, unencrypted NUS connection and does not request BLE pairing.
- On Linux, BLE support depends on this `net9.0` target; the earlier `net8.0` target did not have the required Linux backend from `InTheHand.BluetoothLE`.

## Runtime Ownership

- Library-owned: controller code and low-level WSS dependencies in `lib/`
- CLI-owned: app entrypoint, operator workflow, environment-variable handling, and `Config/` runtime JSON files

The WSS core, params layer, and model layer all receive `ConfigPath` during construction, so applications should resolve the final config directory before constructing `StimulationController`.
