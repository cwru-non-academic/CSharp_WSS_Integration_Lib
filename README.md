# HFI WSS C# Integration Library

Reusable .NET wrapper around the HFI WSS stimulation stack.

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
dotnet restore HFI_WSS_Csharp_Implementation.sln
dotnet build HFI_WSS_Csharp_Implementation.sln -c Release
```

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
