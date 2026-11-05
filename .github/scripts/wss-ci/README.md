# Common CI implementation

Core owns shared CI policy. Use Node 24 for new cross-repository orchestration.
Use an existing PowerShell helper when it already owns the relevant platform or
archive boundary. Do not independently translate common checks into another
language. Implement a change here or in `tools/release`, then copy the actual
files with `node tools/ci/sync-tooling.mjs copy <workspace>`.

The sync manifest names every managed file. Consumers keep byte-identical copies
under `.github/scripts/wss-ci`, inside their existing frozen trusted script path.
Each consumer records the exact Core source commit and SHA-256 file identities.
Hosted CI checks the copies against that immutable Core revision. A change is
complete only after all nine synchronization PRs have been reviewed; floating
`main` must never become an executable trust dependency.

Keep runtime tests, projection/importer rules, native evidence interpretation,
source pins, job names and application gitlinks in explicit receiver adapters.
Do not edit generated common files locally. Add new common files to the sync
manifest; do not introduce another implementation of an existing rule.
