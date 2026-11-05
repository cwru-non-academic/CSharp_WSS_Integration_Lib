# Common CI implementation

Shared CI has one implementation per feature, owned by the highest tier that
actually needs it. Use Node 24 for cross-repository orchestration.
Use an existing PowerShell helper when it already owns the relevant platform or
archive boundary. Do not independently translate common checks into another
language. Core owns candidate/producer/acceptance validation and archive policy
used by Core and receivers. Python_WSS_Integration_Lib owns the receipt writer,
dependency publication, integration fanout and evidence primitives used only by
integrations and applications, under `.github/scripts/wss-ci`. Implement a new
application-only feature in one application and copy it horizontally when the
need arises; do not create an artificial Core dependency for it.

Verify a feature in its reference repository first. Record its immutable source
commit in Core's synchronization manifest, then copy the actual files with
`node tools/ci/sync-tooling.mjs copy <workspace>`. The workspace contains all nine
receivers and each referenced source commit. The copier changes local files;
reviewed repository PRs and hosted CI deploy them. It does not dispatch or merge.

The sync manifest names every managed file. Consumers keep byte-identical copies
under `.github/scripts/wss-ci`, inside their existing frozen trusted script path.
Each consumer records the synchronization revision, each tier's retained source
commit, and per-file origin and SHA-256 identity. Hosted CI checks the copies
against those exact source revisions. A change is
complete only after all nine synchronization PRs have been reviewed; floating
`main` must never become an executable trust dependency.

Keep runtime tests, projection/importer rules, native evidence interpretation,
source pins, job names and application gitlinks in explicit receiver adapters.
Edit common files only in their declared reference repository. Receiver copies
are generated. Add new common files to the sync manifest with the correct origin;
do not introduce another implementation of an existing rule.
