# WSS C# Integration Library

Reusable .NET wrapper around the WSS stimulation stack.

This repository now owns the integration/library layer only. The CLI application should live in a separate repo and consume this library as a git submodule.

All documentation about the API and other implementations can be found in [GitHub Pages](https://cwru-non-academic.github.io/WSS_Documentation/).

## Layout

- `src/` - library project containing `StimulationController` and `StimulationOptions`
- `lib/` - vendor-provided and compatibility `.dll` dependencies required by the library
- `temp/CLI_CSharp_WSS_Application/` - temporary handoff copy of the files that belong in the separate CLI repo

## Build

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

## Emulator Conformance Mode

`StimulationOptions` provides three distinct transport choices:

- Default options use the Serial transport.
- `TestMode = true` uses the existing `TestModeTransport`.
- `EmulatedConformanceMode = true` uses the deterministic in-memory `EmulatedWssTransport`.

The testing modes are mutually exclusive. Applications using emulator mode can obtain the
WSS Core-owned conformance capability without accessing or replacing the transport:

```csharp
using var controller = new StimulationController(new StimulationOptions
{
    ConfigPath = configDirectory,
    EmulatedConformanceMode = true
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

## Runtime Ownership

- Library-owned: controller code and low-level WSS dependencies in `lib/`
- CLI-owned: app entrypoint, operator workflow, environment-variable handling, and `Config/` runtime JSON files

The WSS core, params layer, and model layer all receive `ConfigPath` during construction, so applications should resolve the final config directory before constructing `StimulationController`.
