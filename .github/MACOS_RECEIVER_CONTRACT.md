# Reviewed macOS universal receiver contract

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
reviewed-source synthetic data; its evidence is not a promotion approval. All 51
existing provenance/negative/replay/human-merge safety checks remain unchanged.

This is a preparatory source/CI PR dependent on fixture sync #23. It preserves every
committed `lib/` byte and approval. After the prerequisite PRs are human-merged,
fresh exact-source Integration and CLI preflights must succeed before a dependency
PR can be created. Existing failed correlated requests are inspected, never blindly
redispatched. No automatic approval/merge, credential or ruleset change, physical
BLE access, held Core publication or MATLAB activation is introduced.
