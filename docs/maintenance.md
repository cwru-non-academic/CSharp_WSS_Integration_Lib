# C# integration maintenance

[README](../README.md) | [Shared CI guides](https://cwru-non-academic.github.io/WSS_Documentation/apiDocs/ci.html)

## Validate a universal artifact

Normal builds use the complete committed `lib/` distribution. To test an extracted
candidate, set both artifact properties to the same nested `WSS-Universal/` root:

```bash
dotnet test tests/Wss.CSharpImplementation.Tests/Wss.CSharpImplementation.Tests.csproj -c Release -p:WSS_ARTIFACT_DIR="/absolute/path/to/WSS-Universal" -p:WSS_BLE_ARTIFACT_DIR="/absolute/path/to/WSS-Universal"
```

The project references Core, Serial and the BLE facade. It copies backend and
runtime trees to build and publish output. System.IO.Ports NuGet 8.0.0 chooses
the host runtime; do not overwrite it with the portable root net462 alternate.

## CI and coordinated updates

The authoritative workflow inputs and trust checks live in
[`wss-preflight.yml`](../.github/workflows/wss-preflight.yml) and
[`promote-wss.yml`](../.github/workflows/promote-wss.yml).
Preflight selects an exact successful producer run or release tag, full producer
commit, archive name and SHA-256. Integration and CLI must test the same candidate.
CLI's `integration_sha` identifies the tested integration source.

Routine Core dev promotion verifies the complete producer run and the archive
before dispatching both downstream preflights. Schema-2 approval records bind
source revisions and successful evidence to one candidate. The resulting
Integration PR changes dependencies only. Its reviewed merge dispatches a
gitlink-only CLI PR. Normal committed-state CI and review remain required.
Replays must match the existing candidate and correlation exactly. Missing,
expired or mismatched evidence fails validation; there is no default-release
fallback or automatic merge.

For the exact schemas and rejection rules, see the scripts and tests in
[`.github/scripts/`](../.github/scripts/) and
[`universal-bootstrap.json`](../.github/universal-bootstrap.json).
The bootstrap helper is a pinned historical migration tool, not a routine update
procedure. Its retained proof files must remain consistent with its tests; retire
the helper and proofs together through a separately reviewed change.

## Software checks

```bash
dotnet test Wss.CSharpImplementation.sln -c Release
```

The suite covers Test transport lifecycle, deterministic emulator conformance,
artifact propagation and runtime loading. It does not establish physical BLE
communication or stimulation performance.

Release sign-off belongs to the shared
[1.0 readiness checklist](https://github.com/cwru-non-academic/WSS_Documentation/blob/main/apiDocs/conceptual/release-readiness.md).
