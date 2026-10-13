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

By default, the project resolves WSS assemblies from `lib/`. Updated source requires the
complete final universal distribution. For downloaded-candidate builds, verify the single
`WSS-Universal-<name>.zip` and extract its nested `WSS-Universal/` root:

```bash
dotnet test tests/Wss.CSharpImplementation.Tests/Wss.CSharpImplementation.Tests.csproj -c Release \
  -p:WSS_ARTIFACT_DIR=/path/to/extracted/WSS-Universal \
  -p:WSS_BLE_ARTIFACT_DIR=/path/to/extracted/WSS-Universal
```

Both artifact properties must identify the same root. The project references Core, Serial,
and the Standard 2.0 BLE facade directly. System.IO.Ports NuGet 8.0.0 selects the runnable
host implementation; the root net462 alternate is not copied over it. Both backend trees,
the Windows native wrapper/production DLL, shared dependencies, and all runtime trees
propagate to build and publish outputs. Preflight verifies their hashes against the candidate.

### Exact candidate preflight

Dispatch the existing `wss-preflight.yml` on the updated Integration source with these inputs:

- `wss_producer_repository`: `cwru-non-academic/WSSCore`
- `wss_run_id`: exact successful `artifacts.yml` run (manual dispatch or tag push, not a PR merge-ref run)
- `wss_commit`: full expected producer SHA
- `wss_archive`: `WSS-Universal-ci.zip` for an untagged run
- `wss_sha256`: expected archive SHA-256, obtained from that run's `SHA256SUMS.txt`
- `correlation_id`: optional single-line identifier

Alternatively set `wss_release_tag` instead of `wss_run_id`, with the matching universal
archive name, expected tag commit, and SHA-256. Tag selection resolves exactly one successful
authoritative tag-push run and downloads its retained Actions artifact, not manually attached
release assets; expired/missing artifacts fail closed. There is no release/default fallback and
no support for the old two-archive format. The resolver verifies run/workflow/repository,
successful completion, exact commit, artifact availability, checksum and exact ZIP inventory
before extraction. All jobs consume one verified tree; `wss-candidate-provenance` retains
the producer run/artifact ID, commit and archive hash.

Use exactly the same candidate inputs for CLI preflight, with `integration_sha` selecting
the updated Integration source. No submodule promotion is required for this test.

**Transition coordination:** committed `lib/` still contains the old distribution. Normal
Integration CI cannot pass with that payload and the new references/tests; preflight must
use the explicit universal candidate. Do not overlay old DLLs or add compatibility shims.
After preflights pass, a separate promotion phase must update committed artifacts and the
promotion scripts. The shared resolver now requires candidate provenance, so existing
promotion calls supplying only a release tag are intentionally not runnable unchanged.

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
- The universal artifact provides platform backends for Windows and Linux; macOS supports Core/Serial only.
- The current WSS BLE path assumes an unpaired, unencrypted NUS connection and does not request BLE pairing.

## Runtime Ownership

- Library-owned: controller code and low-level WSS dependencies in `lib/`
- CLI-owned: app entrypoint, operator workflow, environment-variable handling, and `Config/` runtime JSON files

The WSS core, params layer, and model layer all receive `ConfigPath` during construction, so applications should resolve the final config directory before constructing `StimulationController`.
