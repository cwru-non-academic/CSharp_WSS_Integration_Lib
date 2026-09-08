# Agent Guide (WSS C# Implementation)

This repo is a .NET 8 integration library that hosts the WSS stimulation stack (core -> params -> model)
via the native WSS interface assembly in `lib/`.

No Cursor/Copilot instruction files were found (no `.cursor/rules/`, `.cursorrules`, or
`.github/copilot-instructions.md`).

## Repo Layout

- `Wss.CSharpImplementation.sln` - solution containing the library and NUnit integration tests
- `src/Wss.CSharpImplementation.csproj` - .NET 8 class library
- `src/StimulationController.cs` - wrapper around WSS modules + background tick loop
- `tests/Wss.CSharpImplementation.Tests/` - NUnit tests for released WSS artifact compatibility and conformance
- `lib/` - third-party/native `.dll` dependencies referenced by the project
- `temp/CLI_CSharp_WSS_Application/` - temporary copy of the CLI files to move into the separate app repo

## Build / Run / Test Commands

All commands assume you run them from the repo root.

Restore/build/run:
```bash
dotnet restore Wss.CSharpImplementation.sln
dotnet build Wss.CSharpImplementation.sln -c Release
dotnet build Wss.CSharpImplementation.sln -c Release -p:TreatWarningsAsErrors=true
```

Tests:
```bash
dotnet test Wss.CSharpImplementation.sln -c Release
dotnet test -c Release --list-tests
dotnet test -c Release --filter FullyQualifiedName~Namespace.ClassName.TestMethod
dotnet test -c Release --filter Name~SomeSubstring
```

Lint/format (no repo config present; use if available):
```bash
dotnet format Wss.CSharpImplementation.sln
dotnet format Wss.CSharpImplementation.sln --verify-no-changes
```

## Code Style Guidelines

### General

- Target `net8.0`; keep behavior deterministic/scriptable; prefer small explicit changes (this code touches hardware).
- Nullable reference types are enabled; avoid weakening nullability to "make warnings go away".
- Prefer minimal allocations and clear control flow in the tick path.

### Imports / Usings

- Keep `using` directives at the top; avoid mid-file usings.
- Rely on implicit usings; add explicit usings only when required.
- Remove unused usings.

### Formatting

- Use file-scoped namespaces (`namespace Wss.CSharpImplementation;`).
- 4-space indentation; keep braces for multi-line blocks.
- Prefer `switch` expressions and guard clauses when they improve clarity.

### Types / Nullability

- Treat `null` as a real state: model it with `T?` and handle it explicitly.
- Avoid `!` null-forgiving unless you can prove the invariant locally.
- Use `TryXxx` for parsing/validation of user input; keep exceptions for programmer errors.

### Naming

- Default to .NET naming:
  - `PascalCase` for types/methods/properties.
  - `camelCase` for locals/parameters.
  - `_camelCase` for private fields.
- Interop exception: `src/StimulationController.cs` intentionally exposes some Unity/WSS-legacy names
  (e.g., `releaseRadio`, `resetRadio`, `load`, `started`, `isModeValid`). Preserve these when compatibility matters.
  If you add new public surface area, prefer .NET naming.

### Error Handling

- Throw for programmer errors (`ArgumentException`, `ArgumentOutOfRangeException`, `InvalidOperationException`).
- Startup/host applications should fail fast with a clear message.
- Tick loop should log and continue on recoverable faults (see `EnsureTickLoop` in `src/StimulationController.cs`).
- Avoid broad `catch { }`; if you must ignore an exception, keep it narrowly scoped and intentional.

### Logging

- Use WSS `Log.Error(...)` for core/tick failures; keep messages actionable.
- Avoid logging secrets; avoid spamming logs in the tick loop (one failure per tick is already noisy).

### Concurrency / Threading

- Keep `_wss`, `_basicWss`, and tick-loop state mutations under `_gate`.
- Don't block the tick loop with long work; prefer async waits (already uses `Task.Delay`).
- Validate `TickIntervalMs` and keep it > 0.

### Shutdown / Dispose

- Prefer explicit `Shutdown()`; it stops ticking and tears down the connection.
- Host applications should ensure cancellation closes radio/serial cleanly.
- Avoid leaving background tasks running after shutdown.

### Host / CLI Integration

- Treat host input as untrusted; validate and provide usage hints instead of crashing.
- Resolve the final `ConfigPath` before constructing `StimulationController`; the core and layers receive it during construction.
- Keep CLI-specific parsing and REPL concerns in the separate application repo.

### Dependencies (`lib/` and NuGet)

- `src/Wss.CSharpImplementation.csproj` references binaries in `lib/` (e.g., `WSS_Core_Interface.dll`).
  Builds will fail if these files are missing.
- Prefer NuGet when possible; use `lib/` for vendor-provided binaries that must match the device stack.
- When adding a new `lib/` DLL, add a `<Reference>` with a `<HintPath>` and keep it relative.

## Hardware / Runtime Notes

- Default behavior in host apps is live hardware unless they opt into `StimulationOptions.TestMode`.
- Serial port names are OS-specific (e.g., `COM3` on Windows, `/dev/ttyUSB0` on Linux).
- `StimulationController.Initialize()` must be called before using most APIs; otherwise `EnsureWss()` throws.

## Running Focused Tests

```bash
dotnet test -c Release --filter FullyQualifiedName~Wss.CSharpImplementation.Tests.SomeClassTests.SomeTest
dotnet test -c Release --filter Name~SomeTestSubstring
```
