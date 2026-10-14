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

## Universal promotion and first bootstrap

Routine `promote-wss.yml` retains **lib-only** bot PRs to `dev`. Dispatch it on `dev` with
`approval_json` and `correlation_id`. Schema 2 is illustrated by `.github/universal-bootstrap.json`:
producer repository/commit/run/artifact/archive/hash, plus both downstream source SHAs and
successful preflight run IDs. Future promotions supply fresh matching values, never a default.
Both preflight provenance records and the CLI checkout-verification log must match. Source
comparison allows only explicitly listed promotion/CI automation and documentation changes
from the tested source; application, reference and preflight changes require new evidence.

`New-WssLib.ps1` deterministically stages all 25 universal files plus `lib/wss-candidate.json`.
No DLL overlay or Ports runtime exclusion is used. Existing PR/branch reuse requires identical
bytes, source, approval and correlation. Native branch probing still distinguishes exit 2
(absence) from API/authentication failures. No force push or auto-merge is used.

### First coordinated migration

Do not merge source-only changes first or relax normal CI. Use
`Prepare-UniversalBootstrap.ps1` in a clean **separate worktree** descended from the validated
source plus reviewed automation. The script is pinned to the first verified candidate,
Integration `cd181c1f2abca8048fc2d1181dbf9beca9050e21`/run `38420209110`, and CLI
`a3b272b23fba4e566d7c1fe3bfafa048cca9806c`/run `38420541537`. It checks current `dev` ancestry,
exact source compatibility and an explicit bootstrap path allowlist. Without `-Stage` it
only verifies/stages temporary files; with `-Stage` it creates `bootstrap/universal-wss-378a489`
and stages dependencies/gitlink. It never commits, pushes, opens PRs or merges.

The two `.github/promotion-evidence/*.zip.b64` files preserve original provenance ZIP bytes
before one-day retention expires. Digests are pinned to official Actions metadata (Integration
artifact `11826726567`, CLI artifact `11825383860`). Only this fixed bootstrap can use them;
run success/source identity, the CLI checkout log and producer artifact remain live requirements.
Routine promotion has no expired-proof fallback.

Each retained proof is 480 Base64 characters representing a 358-byte ZIP whose only
entry is a 299-byte `candidate.json`. Inspection confirmed exactly the seven public
candidate provenance fields: no secrets, credentials, logs, WSS binaries or unrelated data.
Retain both files through the Integration and CLI bootstrap reviews/merges. They can be
removed in a separately reviewed cleanup after both coordinated migrations finish and
the pinned bootstrap path is retired. That cleanup must also retire/update its proof-specific
safety tests; deleting the archives alone would break normal Integration CI. Routine
promotion restrictions and live approval checks must remain intact.

After authorization to commit the reviewed automation, create a separate Integration worktree
from that automation commit. Run from the Integration tooling checkout:

```powershell
./.github/scripts/Prepare-UniversalBootstrap.ps1 -Repository Integration -Worktree <INTEGRATION_BOOTSTRAP_WORKTREE> -ScratchRoot <NEW_SCRATCH_DIRECTORY> -Stage
```

Inspect staged dependencies and the whole branch diff to `dev`. After separate authorization,
commit the lib delta, push the bootstrap branch and open an Integration `dev` PR using generated
`bootstrap-pr-body.md`. This PR includes validated source, reviewed automation and exact binaries.
Require all normal committed-state Integration CI jobs and human review before manual merge.

Bootstrap deliberately stays outside the routine bot/lib-only merge trigger. After Integration
merges, create a separate CLI worktree from its reviewed source/automation commit and run:

```powershell
./.github/scripts/Prepare-UniversalBootstrap.ps1 -Repository CLI -Worktree <CLI_BOOTSTRAP_WORKTREE> -ScratchRoot <ANOTHER_NEW_SCRATCH_DIRECTORY> -IntegrationPr <MERGED_INTEGRATION_PR_NUMBER> -Stage
```

It verifies the actual Integration merge SHA in `dev`, latest successful normal CI at the PR's
final head, approved source, committed provenance and universal bytes before staging the gitlink.
The preflight-only commit cannot be the final target. Publish/review the coordinated CLI PR only
after authorization; require normal CLI CI before manual merge. Incompatible `dev` advancement
or unavailable producer/log evidence stops preparation rather than overwriting/substituting.

### Routine updates after bootstrap

Integration uses `automation/wss-<run>-<hash>` with lib-only diffs. Manual merge triggers
`dispatch-cli-promotion.yml`, using trusted base code and checking bot origin, lib-only scope,
approval, merge SHA and normal CI. It dispatches CLI on `dev` with `integration_sha`,
`integration_pr`, `approval_json` and `correlation_id`. CLI validates with trusted Integration
`dev` tools before creating write credentials, retains gitlink-only PRs, and uses normal CI.

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
- The universal artifact provides platform backends for Windows and Linux; macOS supports Core/Serial only.
- The current WSS BLE path assumes an unpaired, unencrypted NUS connection and does not request BLE pairing.

## Runtime Ownership

- Library-owned: controller code and low-level WSS dependencies in `lib/`
- CLI-owned: app entrypoint, operator workflow, environment-variable handling, and `Config/` runtime JSON files

The WSS core, params layer, and model layer all receive `ConfigPath` during construction, so applications should resolve the final config directory before constructing `StimulationController`.
