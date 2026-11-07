$ErrorActionPreference='Stop'
. "$PSScriptRoot/../CSharpTestSource.ps1"
$root=Join-Path ([IO.Path]::GetTempPath()) ('wss-test-source-contract-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path "$root/tests/Wss.Cli.Tests" -Force
[IO.File]::WriteAllText("$root/tests/Wss.Cli.Tests/Example.cs",'class Example {}')
[IO.File]::WriteAllText("$root/tests/test-contract.json",'{"schema":"wss-csharp-tests/v1","role":"cli","test_directory":"tests/Wss.Cli.Tests"}')
$null=& git -C $root init --quiet
# macOS temporary paths can enter through /var, while Git reports /private/var.
$root=(& git -C $root rev-parse --show-toplevel).Trim()
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
Expect-Rejection { Assert-CSharpTestWorkRoot (Join-Path $root 'new-work') @($root) } 'work root beneath selected source'
[IO.File]::WriteAllText("$root/tests/test-contract.json",'{"schema":"wss-csharp-tests/v1","role":"cli","test_directory":"tests/Wss.Cli.Tests"}')
$null=& git -C $root add tests/test-contract.json
$null=& git -C $root -c user.name=Test -c user.email=test@example.invalid commit --quiet -m valid-contract
$injected=(& git -C $root rev-parse HEAD).Trim()
$null=& git -C $root update-index --assume-unchanged tests/Wss.Cli.Tests/Example.cs
Expect-Rejection { Resolve-CSharpTestBundle cli $product $root $injected $repo $id } 'assume-unchanged index'
$null=& git -C $root update-index --no-assume-unchanged tests/Wss.Cli.Tests/Example.cs
$null=& git -C $root update-index --skip-worktree tests/Wss.Cli.Tests/Example.cs
Expect-Rejection { Resolve-CSharpTestBundle cli $product $root $injected $repo $id } 'skip-worktree index'
$null=& git -C $root update-index --no-skip-worktree tests/Wss.Cli.Tests/Example.cs
[IO.File]::WriteAllText("$root/passed.trx",'<TestRun><Results><UnitTestResult outcome="Passed" /></Results></TestRun>')
Assert-CSharpFullTestResults "$root/passed.trx"
$count++
[IO.File]::WriteAllText("$root/skipped.trx",'<TestRun><Results><UnitTestResult outcome="NotExecuted" /></Results></TestRun>')
Expect-Rejection { Assert-CSharpFullTestResults "$root/skipped.trx" } 'skipped added selected test'
$null=New-Item -ItemType Directory -Force "$root/src/obj"
Add-Content "$root/.git/info/exclude" 'src/obj/'
[IO.File]::WriteAllText("$root/src/obj/Fixture.csproj.nuget.g.targets",'<Project><Target Name="Untrusted" BeforeTargets="Build"><Error Text="stale import" /></Target></Project>')
Expect-Rejection { Assert-TestBundleCheckout $root $injected @('src') } 'stale ignored NuGet intermediate import'
$lf=Join-Path $root 'lf.fixture';$crlf=Join-Path $root 'crlf.fixture'
[IO.File]::WriteAllText($lf,"canonical`nassertion",[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($crlf,"canonical`r`nassertion",[Text.UTF8Encoding]::new($false))
if((Get-CanonicalCSharpFixtureHash $lf) -cne (Get-CanonicalCSharpFixtureHash $crlf)){throw 'Canonical fixture line endings differ'}
$count++
[IO.File]::WriteAllText($crlf,"changed`nassertion",[Text.UTF8Encoding]::new($false))
if((Get-CanonicalCSharpFixtureHash $lf) -ceq (Get-CanonicalCSharpFixtureHash $crlf)){throw 'Canonical fixture mutation was hidden'}
$count++
Remove-Item -LiteralPath $lf,$crlf

# Fixed v2 wrapper bundle is separate from ordinary legacy test inputs.
$wrapper=Join-Path (Split-Path $root) ('wss-wrapper-v2-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path "$wrapper/tests/SelectedWrapper.Tests" -Force
Copy-Item -LiteralPath "$PSScriptRoot/../../../tools/CSharpProfiles/fixtures/layered-v1/StimulationControllerConformanceTests.cs" -Destination "$wrapper/tests/SelectedWrapper.Tests/StimulationControllerConformanceTests.cs"
$null=& git -C $wrapper init --quiet
$wrapper=(& git -C $wrapper rev-parse --show-toplevel).Trim()
function Commit-WrapperContract([string]$Schema,[string]$Directory,[string]$Role='wrapper') {
    @{schema=$Schema;role=$Role;test_directory=$Directory} | ConvertTo-Json | Set-Content "$wrapper/tests/test-contract.json"
    $null=& git -C $wrapper add .
    $null=& git -C $wrapper -c user.name=Test -c user.email=test@example.invalid commit --quiet -m contract
    (& git -C $wrapper rev-parse HEAD).Trim()
}
$wrapperRepo='cwru-non-academic/CSharp_WSS_Integration_Lib'
$wrapperSha=Commit-WrapperContract 'wss-csharp-tests/v2' 'tests/SelectedWrapper.Tests'
$v2=Resolve-CSharpTestBundle wrapper $product $wrapper $wrapperSha $wrapperRepo $id
Assert-CSharpTestBundle $v2
if($v2.directory -cne 'tests/SelectedWrapper.Tests'){throw 'Wrong v2 bundle directory'}
$count++
foreach($badDirectory in @('tests/Wss.CSharpImplementation.Tests','../outside','tests/Other')) {
    $wrapperSha=Commit-WrapperContract 'wss-csharp-tests/v2' $badDirectory
    Expect-Rejection {Resolve-CSharpTestBundle wrapper $product $wrapper $wrapperSha $wrapperRepo $id} "v2 arbitrary directory $badDirectory"
}
$wrapperSha=Commit-WrapperContract 'wss-csharp-tests/v3' 'tests/SelectedWrapper.Tests'
Expect-Rejection {Resolve-CSharpTestBundle wrapper $product $wrapper $wrapperSha $wrapperRepo $id} 'unknown schema'
$wrapperSha=Commit-WrapperContract 'wss-csharp-tests/v2' 'tests/SelectedWrapper.Tests' 'cli'
Expect-Rejection {Resolve-CSharpTestBundle cli $product $wrapper $wrapperSha $repo $id} 'v2 cannot extend CLI paths'
$wrapperSha=Commit-WrapperContract 'wss-csharp-tests/v2' 'tests/SelectedWrapper.Tests'
Add-Content "$wrapper/tests/SelectedWrapper.Tests/StimulationControllerConformanceTests.cs" '// mutated mandatory fixture'
$null=& git -C $wrapper add .
$null=& git -C $wrapper -c user.name=Test -c user.email=test@example.invalid commit --quiet -m mutation
$wrapperSha=(& git -C $wrapper rev-parse HEAD).Trim()
Expect-Rejection {Resolve-CSharpTestBundle wrapper $product $wrapper $wrapperSha $wrapperRepo $id} 'v2 canonical mutation'

Write-Output "$count selected-test binding checks passed. Fixture: $root"