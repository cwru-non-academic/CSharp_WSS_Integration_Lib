# HFI WSS C# Integration Library

Reusable .NET wrapper around the HFI WSS stimulation stack.

This repository now owns the integration/library layer only. The CLI application should live in a separate repo and consume this library as a git submodule.

All documentation about the API and other implementations can be found in [GitHub Pages](https://cwru-non-academic.github.io/WSS_Documentation/).

## Layout

- `src/` - library project containing `StimulationController` and `StimulationOptions`
- `lib/` - vendor-provided and compatibility `.dll` dependencies required by the library
- `temp/CLI_CSharp_WSS_Application/` - temporary handoff copy of the files that belong in the separate CLI repo

## Build

```bash
dotnet restore HFI_WSS_Csharp_Implementation.sln
dotnet build HFI_WSS_Csharp_Implementation.sln -c Release
```

## Runtime Ownership

- Library-owned: controller code and low-level WSS dependencies in `lib/`
- CLI-owned: app entrypoint, operator workflow, environment-variable handling, and `Config/` runtime JSON files

The WSS core, params layer, and model layer all receive `ConfigPath` during construction, so applications should resolve the final config directory before constructing `StimulationController`.
