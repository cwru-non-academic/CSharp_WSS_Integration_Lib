# Reviewed dual-profile bootstrap

Ordinary workflows prepare a provenance-bound test project before compiling.
Selected-suite bridges remain inactive until the coordinated Core lock and workflow
activation. This does not change shared CI source identity guards or activate a campaign.

`Profile.ps1` reads PE metadata without loading or executing the candidate assembly.
The six baseline catalog getters and baseline conformance API must exist. A legacy
profile requires all six modern type sentinels to be absent. A layered profile
requires complete sequence, layered catalog, reload, window/result and configuration
snapshot APIs. Any partial profile fails. Test counts, test roots, mutable test
contracts and environment profile selectors are never authority.

The historical main legacy producer allowlist entry is Core
76803c03c7aa55b8951499053641ad9ce83504b8, run 42230527501, artifact 13507483694,
archive SHA256 856566f5710a5662254373cc8c5d3ecf3527b89506f0df140824261ca50d2167,
and Core DLL SHA256 738691490a76ceb56b38aa580148116db1a46601117246890a129eb0e6bfed20.
The historical CLI dev producer Core 50afc280a6c591bc0adec8dda5fe5ce72ba8708d
is also explicitly pinned by producer, archive and DLL identity in Profile.ps1.
Any future already-authenticated producer must supply the complete layered API.
A selection-enabled campaign requires layered; merely supplying a run-level
selection context does not opt an old producer policy into a new campaign.

## Trust boundary

`Resolve-WssReviewedProfile` is not an authenticator. Invoke it only after the
unchanged producer/run/archive verification and full payload projection comparison.
The caller owns that boundary. Neither a local JSON record nor a caller-selected
verified directory independently proves provenance. Production integration must
keep these records outside the credential-free selected-test process and retain
all package, platform, native and release gates. Never accept result evidence
written by selected test code as proof that a trusted baseline gate passed.

The local `Invoke-BaselineProfileTests.ps1` harness takes immutable ProductRoot and
ProductSha plus the trusted resolver's VerifiedReleaseRoot. It checks all projected
payload bytes before classification, exports exact product source with git archive,
uses fresh external outputs, disables ambient Directory.Build imports, compiles
fixed bootstrap fixture bytes, and rejects skipped/non-passing full-suite tests.
The shared selected-source guards remain unchanged. Native-load failures are not
suppressed. No physical transport is opened by this harness's emulator scenarios.

## Fixtures and evidence

`fixture-sources.json` records exact source commits and byte hashes. `Profile.ps1`
hardcodes fixture hashes independently; the JSON file cannot select a profile or
change executable assertions. `.gitattributes` preserves these exact bytes.
The legacy fixture retains all ten canonical cases. The layered fixture retains
all sixteen cases in each single/multi stage. Additional suites do not replace
these catalogs. Evidence records profile, exact producer identity, Core DLL hash,
product commit, payload digest and fixed fixture hash.

## Validation

Run `Profile.Tests.ps1 -MainRoot <exact-main-checkout> -DevRoot <exact-dev-checkout>`.
The baseline test harness additionally requires a new WorkRoot and the existing
trusted resolver output via `-VerifiedReleaseRoot`; use `-SelectionEnabledCampaign`
only for an authenticated opted-in campaign.

On 2026-11-07, actual main aafeef78536fe06094c6a694dd64d9a9e1433b21 and dev
1a710fc02059bede61c91aff8b09e330549e5763 passed independent trusted producer
verification and all 27 payload-file comparisons. Profile contracts: 79 passes.
Legacy runtime: canonical 10 plus 10 options/testmode passed; full suite 21 passed,
1 blocked by Windows App Control loading the legacy native WssBleWindows.dll
(0x800711C7). This remains a failure, not a waiver. Modern runtime: canonical 16+16
passed; full suite 33 passed without skips. Both actual wrong-profile runtime
attempts failed as expected. Bridge activation, ordinary workflow replacement,
CLI adapter adoption and hosted cross-platform CI remain pending coordinated review.

## Prepared workflow and selected bridge

Prepare-CSharpProfile authenticates the producer and all payload bytes before
classification, exports exact product sources, and substitutes only the reviewed
canonical fixture. Protected .github entrypoints hash-bind executable helpers.
For selected execution, pass an external OutputRoot: original product roots must
remain pristine. The parent captures proof before credential-free child execution
and checks source, payload, baseline results and output hashes afterward.
Selection-enabled campaigns reject legacy payloads. Selected suites are additive;
Core alone freezes pinned or latest test identities and authenticates acceptance.
