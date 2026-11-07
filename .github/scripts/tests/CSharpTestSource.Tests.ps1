$ErrorActionPreference='Stop'
. "$PSScriptRoot/../CSharpTestSource.ps1"
$root=Join-Path ([IO.Path]::GetTempPath()) ('wss-test-source-contract-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path "$root/tests/Wss.Cli.Tests" -Force
[IO.File]::WriteAllText("$root/tests/Wss.Cli.Tests/Example.cs",'class Example {}')
[IO.File]::WriteAllText("$root/tests/test-contract.json",'{"schema":"wss-csharp-tests/v1","role":"cli","test_directory":"tests/Wss.Cli.Tests"}')
$null=& git -C $root init --quiet
$null=& git -C $root -c user.name=Test -c user.email=test@example.invalid add .
$null=& git -C $root -c user.name=Test -c user.email=test@example.invalid commit --quiet -m fixture
$sha=(& git -C $root rev-parse HEAD).Trim()
$product=Join-Path $root '../unchanged-product'
$id='a'*64
$repo='cwru-non-academic/CLI_CSharp_WSS_Application'
$count=0
function Expect-Rejection([scriptblock]$Action,[string]$Name) {
    $rejected=$false
    try { $null=& $Action } catch { $rejected=$true }
    if (!$rejected) { throw "Contract unexpectedly accepted: $Name" }
    $script:count++
}
$bundle=Resolve-CSharpTestBundle cli $product $root $sha $repo $id
Assert-CSharpTestBundle $bundle
$count++
Expect-Rejection { Resolve-CSharpTestBundle cli $product $root '' $repo $id } 'partial tuple'
Expect-Rejection { Resolve-CSharpTestBundle cli $product $root ('f'*40) $repo $id } 'wrong source'
Expect-Rejection { Resolve-CSharpTestBundle cli $product $root $sha 'other/repository' $id } 'wrong repository'
Expect-Rejection { Resolve-CSharpTestBundle cli $product $root $sha $repo 'mutable' } 'invalid selection'
Expect-Rejection { Resolve-CSharpTestBundle cli $root $root $sha $repo $id } 'product/test coupling'
Expect-Rejection { Resolve-CSharpTestBundle cli $product "$root/tests" $sha $repo $id } 'nested root'
Add-Content "$root/tests/Wss.Cli.Tests/Example.cs" '// changed'
Expect-Rejection { Assert-CSharpTestBundle $bundle } 'modified tracked tests'
$null=& git -C $root restore tests/Wss.Cli.Tests/Example.cs
[IO.File]::WriteAllText("$root/tests/Wss.Cli.Tests/Extra.cs",'class Extra {}')
Expect-Rejection { Resolve-CSharpTestBundle cli $product $root $sha $repo $id } 'untracked tests'
$resolved=[IO.Path]::GetFullPath("$root/tests/Wss.Cli.Tests/Extra.cs")
if (!$resolved.StartsWith([IO.Path]::GetFullPath($root)+[IO.Path]::DirectorySeparatorChar)) { throw 'Unsafe test fixture path.' }
Remove-Item -LiteralPath $resolved
Add-Content "$root/.git/info/exclude" 'tests/Wss.Cli.Tests/Ignored.cs'
[IO.File]::WriteAllText("$root/tests/Wss.Cli.Tests/Ignored.cs",'class Ignored {}')
Expect-Rejection { Resolve-CSharpTestBundle cli $product $root $sha $repo $id } 'ignored tests'
$resolved=[IO.Path]::GetFullPath("$root/tests/Wss.Cli.Tests/Ignored.cs")
if (!$resolved.StartsWith([IO.Path]::GetFullPath($root)+[IO.Path]::DirectorySeparatorChar)) { throw 'Unsafe test fixture path.' }
Remove-Item -LiteralPath $resolved
[IO.File]::WriteAllText("$root/tests/test-contract.json",'{"schema":"wss-csharp-tests/v1","role":"cli","test_directory":"tests/Wss.Cli.Tests","baseline_ready":true}')
$null=& git -C $root add tests/test-contract.json
$null=& git -C $root -c user.name=Test -c user.email=test@example.invalid commit --quiet -m injected-product-setting
$injected=(& git -C $root rev-parse HEAD).Trim()
Expect-Rejection { Resolve-CSharpTestBundle cli $product $root $injected $repo $id } 'product setting in test contract'
Write-Output "$count selected-test binding checks passed. Fixture: $root"