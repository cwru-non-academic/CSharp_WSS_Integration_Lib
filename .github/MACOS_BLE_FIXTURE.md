# macOS BLE shared compatibility fixture

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
dylibs. No committed dependency binaries or approval records change in this PR.

The existing four normal CI check names are unchanged. The macOS compatibility
job first tests the committed legacy payload. It then builds the reviewed Core
source `0ac18df22a1371e5ff94d5485c6d3fa4b3e6538f` as **synthetic test data**,
exercises the declared-native path, and verifies that removing the output dylib
fails instead of becoming an unsupported/skip result. Its evidence explicitly
marks this as test data; it is not a universal release or eligible producer tuple.
No Core or receiver promotion provenance is relaxed to run this test.

Python should pin the reviewed/merged fixture SHA and use the actual immutable
candidate produced by the genuine Core dev push after the main-to-dev sync merge.
Its receiver inventory/schema preparations remain separate. The narrow C# receiver
inventory migration is described in `MACOS_RECEIVER_CONTRACT.md`; it accepts only
the exact legacy set or its two-file macOS extension and preserves promotion gates.

No fixture code initializes CBCentralManager, scans, connects a peripheral or writes
data. TCC authorization, Bluetooth adapter state and physical BLE I/O remain real
Mac/peripheral acceptance work; this fixture proves package/runtime compatibility.
