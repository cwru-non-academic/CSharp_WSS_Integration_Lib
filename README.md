# WSS C# Integration Library

Reusable .NET wrapper around the WSS stimulation stack.

Requires the .NET 9 SDK.

This repository owns the integration/library layer. The [CLI application](https://github.com/cwru-non-academic/CLI_CSharp_WSS_Application) consumes it as a git submodule.

All documentation about the API and other implementations can be found in [GitHub Pages](https://cwru-non-academic.github.io/WSS_Documentation/).

## Layout

- `src/` - library project containing `StimulationController` and `StimulationOptions`
- `lib/` - vendor-provided and compatibility `.dll` dependencies required by the library
- `tests/` - NUnit behavior, conformance and platform compatibility tests
- `.github/` - CI, verification, promotion tooling and machine-readable evidence

## Build

Install the .NET 9 SDK first. The library targets `net9.0`. The unified BLE distribution has Windows, Linux and macOS backends; the macOS adapter requires a 64-bit macOS 11 or newer host and its matching universal native library.

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
host implementation; the root net462 alternate is not copied over it. All declared backend trees,
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

## Universal promotion

Routine `promote-wss.yml` retains **lib-only** bot PRs to `dev`. Dispatch it on `dev` with
`approval_json` and `correlation_id`. Schema 2 is illustrated by `.github/universal-bootstrap.json`:
producer repository/commit/run/artifact/archive/hash, plus both downstream source SHAs and
successful preflight run IDs. Future promotions supply fresh matching values, never a default.
Both preflight provenance records and the CLI checkout-verification log must match. Source
comparison allows only explicitly listed promotion/CI automation and documentation changes
from the tested source; application, reference and preflight changes require new evidence.

`New-WssLib.ps1` deterministically stages the exact selected universal inventory plus `lib/wss-candidate.json` (25 legacy files or those files plus the two macOS backend files).
No DLL overlay or Ports runtime exclusion is used. Existing PR/branch reuse requires identical
bytes, source, approval and correlation. Native branch probing still distinguishes exit 2
(absence) from API/authentication failures. No force push or auto-merge is used.

<details>
<summary>Maintainer reference: historical bootstrap provenance</summary>

The universal bootstrap was merged in commit `00d8567` (#12).
`.github/universal-bootstrap.json` records that frozen approval, not a current candidate.
`Prepare-UniversalBootstrap.ps1` is restricted to the original migration. Its tested
Integration source was `cd181c1f2abca8048fc2d1181dbf9beca9050e21`/run `38420209110`,
and CLI source `a3b272b23fba4e566d7c1fe3bfafa048cca9806c`/run `38420541537`.
These identifiers bind the original preflights to the exact sources used in the migration.

The two `.github/promotion-evidence/*.zip.b64` files preserve original provenance ZIP
bytes before one-day retention expired. Their digests are pinned to official Actions
metadata (Integration artifact `11826726567`, CLI artifact `11825383860`).
Only this fixed bootstrap can use them; run success/source identity, the CLI checkout
log and producer artifact remain live requirements. Routine promotion has no expired-proof fallback.

Each proof is 480 Base64 characters representing a 358-byte ZIP containing only a
299-byte `candidate.json` with seven public candidate provenance fields. They contain
no secrets, credentials, logs, WSS binaries or unrelated data. The archives are still
referenced by bootstrap tooling and promotion safety tests. Retiring them requires a
coordinated code/test cleanup; deleting the archives alone breaks normal Integration CI.
Routine promotion restrictions and live approval checks remain in force.

</details>

### Routine updates after bootstrap

An ordinary WSSCore `dev` push now builds the existing universal ZIP once. After all
producer tests and packaged consumers pass, its final gated job automatically dispatches
this repository's existing `promote-wss.yml` on `dev`, passing the producer commit, run ID,
artifact ID and ZIP SHA-256. Integration waits for the **entire producer run** to finish
successfully, checks its trusted `push`/`dev` identity and all required job results, and
uses the existing candidate resolver to verify `WSS-Universal-ci.zip`.

The same workflow resolves current Integration and CLI `dev` source SHAs, automatically
dispatches their existing preflights, and pins CLI's selected Integration source to the
Integration preflight SHA. A branch move during dispatch is rejected, not silently accepted.
Both preflights must finish successfully with matching candidate provenance before the
existing schema-2 approval validator permits promotion. The deterministic correlation ID
is `wss-<producer-run>-<artifact-id>`. Replays reuse uniquely correlated runs and the exact
approval rather than dispatching new preflights; failed, missing, ambiguous, expired or
mismatched evidence stops promotion. GitHub/API errors are never interpreted as absence.

Integration uses `automation/wss-<run>-<hash>` with lib-only diffs. A human merge is
evaluated by `dispatch-cli-promotion.yml`, using trusted base code and checking bot
origin, lib-only scope, approval, merge SHA and normal CI. For producers with staged
propagation policy, Core's complete integration barrier must authorize application
fanout before CLI write credentials are created; merging this Integration alone is
not sufficient. Producers without that policy retain the verified legacy path.
The authorized dispatch passes `integration_sha`, `integration_pr`, `approval_json`
and `correlation_id` to CLI on `dev`. CLI validates with trusted Integration `dev`
tools before creating write credentials, retains gitlink-only PRs, and uses normal CI.

An identical complete dependency payload is a verified no-op: no metadata-only PR is
created, existing committed provenance is retained, and the freshly verified schema-2
approval is retained in the promotion run's `wss-automatic-approval` artifact. An open
matching PR is reused; an already merged/closed candidate cannot create a replacement or
rollback PR. Existing branches and unrelated changes are not overwritten or force-pushed.

The existing `WSS_GITHUB_APP_ID` / `WSS_GITHUB_APP_PRIVATE_KEY` must be accessible
in WSSCore as well as downstream repositories. The Core handoff needs Integration Actions
write only. Integration needs producer/evidence Actions and Contents read, downstream
Contents read/Actions write for dispatch, and its existing Contents/PR write for authoring.
Dispatch/write tokens are created only after their corresponding trust checks. These
Integration and CLI workflows do not merge PRs, write `dev` directly, bypass protections,
invoke bootstrap, tag or publish a release. Human review of dependency PRs remains mandatory.

Dev release acceptance is separate from promotion and green PR checks. Receipt validation
requires the actual reviewed bot dependency merge, its exact current `dev` source, frozen
tooling, paired candidate preflights and fresh committed-state normal CI. Normal C# CI
supports PR and manual runs; acceptance requires a successful manual run at the accepted
merge, not a synthetic PR checkout. A promotion no-op does not establish an accepted
release receipt. Finish coherent trusted-main/dev tooling deployment before freezing a
new plan; do not edit or reuse an old frozen plan to accommodate tooling changes.

The orchestration has a 60-minute bound; timeouts and missing permissions fail explicitly.
Existing Actions artifact/log retention still applies, including CLI preflight provenance's
one-day retention: complete the reviewed cascade while its evidence remains available.
Expired evidence must be investigated/revalidated; no archived bootstrap proof or stale
committed dependencies are substituted. Hosted Windows/Linux/macOS checks retain their
existing scope and do not establish physical Linux BLE or stimulation operation.

Focused safety checks (normal Integration behavioral CI also runs metadata/scope cases):

```powershell
./.github/scripts/tests/WssPromotion.Tests.ps1 -ArtifactRoot <VERIFIED_EXTRACTED_WSS_UNIVERSAL_ROOT>
```

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
- The universal artifact provides Windows, Linux and macOS BLE backends. A facade that declares macOS support must ship both `backends/macos/WSS.Transport.BLE.MacOS.dll` and `libwss_macos_ble.dylib`; a missing declared backend is a failure, not an unsupported-platform skip.
- The current WSS BLE path assumes an unpaired, unencrypted NUS connection and does not request BLE pairing.

## Runtime Ownership

- Library-owned: controller code and low-level WSS dependencies in `lib/`
- CLI-owned: app entrypoint, operator workflow, environment-variable handling, and `Config/` runtime JSON files

The WSS core, params layer, and model layer all receive `ConfigPath` during construction, so applications should resolve the final config directory before constructing `StimulationController`.

## macOS BLE shared compatibility fixture

`BleBackendLoadingTests` is shared by C#, Python and other consumers. It reads the
loaded BLE facade's existing backend capability mapping before choosing behavior.
A legacy facade that does not declare `macos` must have no orphan macOS files and,
on macOS, must throw `PlatformNotSupportedException`. That is an asserted legacy
unsupported contract, never a skip or a claim of operational BLE support.

A facade declaring `macos` must carry exactly the managed adapter
`backends/macos/WSS.Transport.BLE.MacOS.dll` and native
`backends/macos/libwss_macos_ble.dylib`. Missing either fails on every platform.
On macOS the existing compatibility test also requires actual native load, ABI
`0x00010000`, all five production C exports, managed P/Invoke context creation and
destruction, automatic backend activation and idempotent explicit registration.
The original shared identity/ALC and Windows/Linux assertions remain in place.

`Verify-WssOutput.ps1` hashes both macOS files whenever they are present in the
source, rejects partial/stale propagation, and preserves the original legacy
inventory verification. Existing recursive project copy rules already include
dylibs.

Normal dev CI and candidate preflight each run native Intel x64 and Apple Silicon
arm64 workers. The existing macOS compatibility check requires both architecture
records for the same run attempt and source, and reports each failure separately.
Normal CI records canonical packaged-load evidence before running its separate
synthetic fixture.

<details>
<summary>Maintainer reference: synthetic fixture source and evidence limits</summary>

The fixture SHA below pins reviewed synthetic test source so a moving Core branch
cannot silently change the test. Each normal macOS worker first tests the committed
payload. It then builds the reviewed Core
source `0ac18df22a1371e5ff94d5485c6d3fa4b3e6538f` as **synthetic test data**,
exercises the declared-native path, and verifies that removing the output dylib
fails instead of becoming an unsupported/skip result. Its evidence explicitly
marks this as test data; it is not a universal release or eligible producer tuple.
No Core or receiver promotion provenance is relaxed to run this test.

No fixture code initializes CBCentralManager, scans, connects a peripheral or writes
data. TCC authorization, Bluetooth adapter state and physical BLE I/O remain real
Mac/peripheral acceptance work; this fixture proves package/runtime compatibility.

</details>

## macOS universal receiver contract

The receiver accepts exactly one of two inventories: the original 25 universal
files, or those same files plus exactly:

* `backends/macos/WSS.Transport.BLE.MacOS.dll`
* `backends/macos/libwss_macos_ble.dylib`

ZIP entries must use the exact `WSS-Universal/` prefix and canonical case. Duplicate
or case-colliding paths, partial pairs, traversal paths and any additional files
fail. Committed payloads additionally require the unchanged `wss-candidate.json`
approval schema. There is no general extension allowlist or directory wildcard.

After the existing producer/run/commit/artifact/checksum verification, the new
inventory requires the managed adapter identity/version and two nonoverlapping,
matching 64-bit Mach-O dylib slices for x86_64 and arm64. It also requires unique
successful producer jobs `Build macOS universal BLE bridge`, `BLE consumer (macOS
arm64)` and `BLE consumer (macOS x86_64)`. The macOS preflight's existing shared
fixture checks actual exports, ABI `0x00010000`, native load and managed activation.
A declared facade with missing native files fails; it cannot become legacy success.

Resolution, fresh staging, committed-payload validation, no-op comparison and output
verification use the same exact inventory selector. Both new files participate in
byte-for-byte comparisons and output hashing. No-op detection preserves existing
valid provenance instead of creating metadata-only dependency updates.

The new inventory tests cover both allowed sets, rejected unknown/partial/duplicate
sets, required producer gates, actual universal binary structure and identity,
staging/no-op preservation and native-byte tampering. The macOS CI fixture supplies
reviewed-source synthetic data; its evidence is not a promotion approval. Provenance, negative, replay and human-merge safety checks remain in force.

## Development guide

This repo is a .NET 9 integration library that hosts the WSS stimulation stack (core -> params -> model)
via the native WSS interface assembly in `lib/`.

### Repo Layout

- `Wss.CSharpImplementation.sln` - solution containing the library and NUnit integration tests
- `src/Wss.CSharpImplementation.csproj` - .NET 9 class library
- `src/StimulationController.cs` - wrapper around WSS modules + background tick loop
- `tests/Wss.CSharpImplementation.Tests/` - NUnit tests for released WSS artifact compatibility and conformance
- `lib/` - third-party/native `.dll` dependencies referenced by the project

### Build / Run / Test Commands

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

### Code Style Guidelines

#### General

- Target `net9.0`; keep behavior deterministic/scriptable; prefer small explicit changes (this code touches hardware).
- Nullable reference types are enabled; avoid weakening nullability to "make warnings go away".
- Prefer minimal allocations and clear control flow in the tick path.

#### Imports / Usings

- Keep `using` directives at the top; avoid mid-file usings.
- Rely on implicit usings; add explicit usings only when required.
- Remove unused usings.

#### Formatting

- Use file-scoped namespaces (`namespace Wss.CSharpImplementation;`).
- 4-space indentation; keep braces for multi-line blocks.
- Prefer `switch` expressions and guard clauses when they improve clarity.

#### Types / Nullability

- Treat `null` as a real state: model it with `T?` and handle it explicitly.
- Avoid `!` null-forgiving unless you can prove the invariant locally.
- Use `TryXxx` for parsing/validation of user input; keep exceptions for programmer errors.

#### Naming

- Default to .NET naming:
  - `PascalCase` for types/methods/properties.
  - `camelCase` for locals/parameters.
  - `_camelCase` for private fields.
- Interop exception: `src/StimulationController.cs` intentionally exposes some Unity/WSS-legacy names
  (e.g., `releaseRadio`, `resetRadio`, `load`, `started`, `isModeValid`). Preserve these when compatibility matters.
  If you add new public surface area, prefer .NET naming.

#### Error Handling

- Throw for programmer errors (`ArgumentException`, `ArgumentOutOfRangeException`, `InvalidOperationException`).
- Startup/host applications should fail fast with a clear message.
- Tick loop should log and continue on recoverable faults (see `EnsureTickLoop` in `src/StimulationController.cs`).
- Avoid broad `catch { }`; if you must ignore an exception, keep it narrowly scoped and intentional.

#### Logging

- Use WSS `Log.Error(...)` for core/tick failures; keep messages actionable.
- Avoid logging secrets; avoid spamming logs in the tick loop (one failure per tick is already noisy).

#### Concurrency / Threading

- Keep `_wss`, `_basicWss`, and tick-loop state mutations under `_gate`.
- Don't block the tick loop with long work; prefer async waits (already uses `Task.Delay`).
- Validate `TickIntervalMs` and keep it > 0.

#### Shutdown / Dispose

- Prefer explicit `Shutdown()`; it stops ticking and tears down the connection.
- Host applications should ensure cancellation closes radio/serial cleanly.
- Avoid leaving background tasks running after shutdown.

#### Host / CLI Integration

- Treat host input as untrusted; validate and provide usage hints instead of crashing.
- Resolve the final `ConfigPath` before constructing `StimulationController`; the core and layers receive it during construction.
- Keep CLI-specific parsing and REPL concerns in the separate application repo.

#### Dependencies (`lib/` and NuGet)

- `src/Wss.CSharpImplementation.csproj` references binaries in `lib/` (e.g., `WSS_Core_Interface.dll`).
  Builds will fail if these files are missing.
- Prefer NuGet when possible; use `lib/` for vendor-provided binaries that must match the device stack.
- When adding a new `lib/` DLL, add a `<Reference>` with a `<HintPath>` and keep it relative.

### Hardware / Runtime Notes

- Default behavior in host apps is live Serial hardware unless they select another `StimulationOptions.Transport` value.
- Serial port names are OS-specific (e.g., `COM3` on Windows, `/dev/ttyUSB0` on Linux).
- `StimulationController.Initialize()` must be called before using most APIs; otherwise `EnsureWss()` throws.

### Running Focused Tests

```bash
dotnet test -c Release --filter FullyQualifiedName~Wss.CSharpImplementation.Tests.SomeClassTests.SomeTest
dotnet test -c Release --filter Name~SomeTestSubstring
```


## Coordinated configuration reload

`LoadParamsJson()` rereads all three files (`stimConfig.json`, `stimParams.json`,
`modelConfig.json`) from the original startup configuration directory, including
after a profile override. Startup paths are anchored once, so changing the
working directory does not move these defaults.

- `LoadParamsJson(directory)` selects all three standard filenames in that directory.
- `LoadParamsJson(parameterFile)` selects that calibration file and the startup-default
  Core and model files. It does **not** select sibling Core/model files.
- `LoadCoreConfigFile()` and `resetRadio()` reread the active Core file and keep
  currently applied calibration/model values and paths.

Every bundle is validated before changing the working connection. Any Core
configuration change uses the host reset path: stop ticking, dispose the old
stack (Core zeros output and disconnects), build the validated snapshot, then
resume initialization/ticking. Unchanged Core applies calibration/model updates
without reconnecting. A reset does not replay previous stimulation values.
Wait for `Started()` before sending new stimulation commands.

Invalid JSON leaves the active stack unchanged. Cleanup/construction failure
is exposed through `LastReloadError` and the host stays unavailable rather than
publishing an unverified replacement. `RetryReload()` retries the retained
snapshot without rereading files. `Shutdown()` cancels a pending reload.

`UpdateChannelParams` writes amplitude to `stim.ch.<channel>.defaultPA`, the key
consumed by calibrated stimulation, and saves it using the existing parameter API.

The reload regressions use the packaged Core emulator and verify model and
calibration input reaches emitted stimulation, profile/file/default paths,
retired-stack quiescence, and invalid-bundle behavior. They do not validate
physical hardware.

## Independent selected test bundle

The additional selected-test runner keeps product checkout SHAs and the selected
payload fixed. Core must authenticate the frozen test selection before invoking
it. A syntactically valid selection ID is only a local binding, not approval.

For C#, invoke the trusted `.github/scripts/Invoke-SelectedCSharpTests.ps1` with
`Role`, `ProductRoot`, `ProductSha`, `PayloadRoot`, a new `WorkRoot`, and the complete
`TestRoot`, `TestSha`, `TestRepository`, `TestSelectionId` tuple. The CLI also takes
its unchanged `IntegrationRoot` and `IntegrationSha`. The selected checkout must
contain `tests/test-contract.json` and be clean. The trusted generated project
compiles selected C# test files against explicit product sources; selected
projects, build overrides and release validators are never executed.

This suite is additional to the existing mandatory CI gates. It does not change
product readiness, package provenance, native-platform requirements, release
approval or receipt verification. The wrapper retains the reviewed canonical
assertions and both 16-case stages; the CLI retains its ten command cases.
`test-source-evidence.json` records the selected source, contract hash and product
identities only after source and payload postchecks pass. Workflow selection and
campaign evidence adoption must land separately before repository variables are
advertised as active.
Selected C# runs require fresh product checkouts without prior bin/obj outputs. This prevents stale NuGet intermediate imports from affecting the build; generated outputs from this run are allowed only during postchecks.
The product project is built from a trusted git archive at the declared integration SHA in the new work directory. Original product checkouts remain pristine for Core evidence verification; staged source hashes are rechecked after execution.
