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

Install the .NET 9 SDK first. The library targets `net9.0` and supports the WSS unified BLE distribution on Windows and Linux.

```bash
dotnet restore Wss.CSharpImplementation.sln
dotnet build Wss.CSharpImplementation.sln -c Release
```

By default, the project resolves WSS assemblies from `lib/`. To build and test against an
official WSS release, extract the Core and Unified BLE artifacts separately and set both artifact roots:

```bash
dotnet test tests/Wss.CSharpImplementation.Tests/Wss.CSharpImplementation.Tests.csproj -c Release \
  -p:WSS_ARTIFACT_DIR=/path/to/extracted/WSS-Core \
  -p:WSS_BLE_ARTIFACT_DIR=/path/to/extracted/WSS-BLE-Unified
```

`WSS_ARTIFACT_DIR` identifies the Core artifact root. `WSS_BLE_ARTIFACT_DIR` identifies the matched
Unified BLE artifact root. The integration project automatically propagates the BLE facade, both
Windows and Linux backend trees, and the `win`, `unix`, and `linux-x64` runtime trees to downstream
consumer build and publish outputs. No manual DLL copying is required.

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
- The Unified BLE artifact provides platform backends for Windows and Linux; compatibility for both is checked in CI.
- The current WSS BLE path assumes an unpaired, unencrypted NUS connection and does not request BLE pairing.

## Runtime Ownership

- Library-owned: controller code and low-level WSS dependencies in `lib/`
- CLI-owned: app entrypoint, operator workflow, environment-variable handling, and `Config/` runtime JSON files

The WSS core, params layer, and model layer all receive `ConfigPath` during construction, so applications should resolve the final config directory before constructing `StimulationController`.
