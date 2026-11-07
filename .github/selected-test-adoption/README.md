# Inactive selected-test workflow integration

The bridge is committed but no production workflow invokes it yet. Do not activate
until a published, reviewed Core source lock contains ci-test-selection.mjs, all
immutable parent workflow pins match, compatible payload/test bundles exist, and
ordinary legacy plus candidate layered coverage is preserved on both branches.

1. In the existing registered workflow prerequisite, check out the immutable Core
   revision from its verified wss-ci.lock.json with persist-credentials:false.
   Preserve literal full-SHA external reusable-workflow uses.
2. Obtain separate read-only source/plan and repository Variables-read tokens.
   Verify the App already has Variables read for this target before activation;
   never expand installation permissions automatically. Do not use inherited vars
   context as a substitute for repository-only variable reads.
3. Invoke select TARGET CANDIDATE_OR_DASH OUTPUT [committed|candidate] once.
   GH_TOKEN is the read-only source/plan token. WSS_TEST_VARIABLE_READ_TOKEN is
   scoped to Variables read for this target only. Use actual GITHUB_* identity and
   WSS_CI_CHANNEL. Upload context.json once in this workflow and expose its exact
   scope/selection_id/test_repository/test_commit prerequisite outputs.
4. After all existing mandatory jobs succeed, run the additional selected suite
   against fresh product checkouts plus a separate selected-test checkout at those
   frozen coordinates. Keep test submodules uninitialized. Give no write tokens
   to selected test execution. Initialize product submodules only when each one is
   independently declared in roots.products with exact repository, commit, path.
5. Write roots.json {selection_id,test_root,products:[{repository,commit,path},...]}
   using the prerequisite selection ID and exact original product SHAs. The own
   product SHA remains GITHUB_SHA. Restore authenticated context.json from the
   prerequisite artifact; set WSS_TEST_SELECTION_ID from its job output, not file.
6. Invoke the trusted WithContext bridge from the reviewed bootstrap checkout,
   not the selected test checkout. Supply exact payload/projection and a new
   external work directory. Inspect and evidence are both authenticated by Core;
   the latter runs only after the family suite succeeds and products revalidate.
7. Upload WORK/selection/evidence.json as the sole file in artifact
   wss-selected-tests-TARGET-a${github.run_attempt}. Retain detailed local suite
   evidence separately. Matrix adoption must require every selected job and every
   original mandatory platform/native gate before publishing this final artifact.

C# bridge: Invoke-SelectedCSharpTestsWithContext.ps1 -TargetId csharp-wrapper or
csharp-cli. Python CLI bridge: Invoke-SelectedPythonCliTestsWithContext.ps1.
All take CoreRoot, ContextPath, RootsPath, PayloadRoot, WorkRoot. The Core checkout
must match the checked-in reviewed lock, so the current old lock intentionally
prevents premature activation. Default CI and release authorization are unchanged.
Before the C# WithContext bridge, run trusted Prepare-CSharpProfile with an external
OutputRoot and WorkRoot against the same immutable integration root and payload.
Pass ProfileEvidencePath to the bridge. Keep preparation credentials in that step
only. Campaign selection requires layered-v1; ordinary legacy remains supported.
