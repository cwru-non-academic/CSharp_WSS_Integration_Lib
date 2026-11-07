# Trusted bootstrap only. Core must authenticate the frozen selection before invocation.
# This helper validates local checkout binding; an ID alone is not authorization.
Set-StrictMode -Version Latest
function Invoke-TestBundleGit([string]$Root,[string[]]$Arguments) {
    $out=& git -C $Root @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Git failed: $($out -join '`n')" }
    @($out)
}
function Assert-TestBundleSha([string]$Sha) { if ($Sha -cnotmatch '^[a-f0-9]{40}$') { throw 'Expected an immutable full source SHA.' } }
function Get-TestBundleFileHash([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }
function Get-CanonicalCSharpFixtureHash([string]$Path) {
    $text=[IO.File]::ReadAllText($Path,[Text.UTF8Encoding]::new($false,$true))
    $text=$text.Replace(([string][char]13+[char]10),[string][char]10)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes($text))).ToLowerInvariant()
}

function Assert-TestBundleCheckout([string]$Root,[string]$Sha,[string[]]$Paths=@(),[switch]$AllowBuildOutputs) {
    Assert-TestBundleSha $Sha
    $full=[IO.Path]::GetFullPath($Root)
    $top=[IO.Path]::GetFullPath((Invoke-TestBundleGit $full @('rev-parse','--show-toplevel') -join '').Trim())
    if ($full -cne $top -or ((Invoke-TestBundleGit $full @('rev-parse','HEAD')) -join '').Trim() -cne $Sha) { throw 'Checkout root or source SHA differs from the frozen source.' }
    if (@(Invoke-TestBundleGit $full (@('ls-files','-v','--')+$Paths) | Where-Object { $_ -cnotmatch '^H ' }).Count) { throw 'Source index flags may hide changes.' }
    $ignored=@(Invoke-TestBundleGit $full (@('ls-files','--others','--ignored','--exclude-standard','--')+$Paths) | Where-Object { !$AllowBuildOutputs -or $_ -cnotmatch '(^|/)(bin|obj)/' })
    if ($ignored.Count) { throw 'Ignored source overrides are forbidden.' }
    if (@(Invoke-TestBundleGit $full (@('status','--porcelain','--untracked-files=all','--')+$Paths)).Count) { throw 'Selected source contains changed or untracked files.' }
}
function Resolve-CSharpTestBundle([string]$Role,[string]$ProductRoot,[string]$TestRoot,[string]$TestSha,[string]$TestRepository,[string]$TestSelectionId,[string]$Profile='layered-v1') {
    if (!$TestRoot -or !$TestSha -or !$TestRepository -or !$TestSelectionId) { throw 'TestRoot, TestSha, TestRepository and TestSelectionId must be supplied together.' }
    if ($Role -cnotin @('wrapper','cli') -or $TestSelectionId -cnotmatch '^[a-f0-9]{64}$') { throw 'Invalid test role or frozen selection ID.' }
    $expectedRepo=if ($Role -ceq 'wrapper') { 'cwru-non-academic/CSharp_WSS_Integration_Lib' } else { 'cwru-non-academic/CLI_CSharp_WSS_Application' }
    if ($TestRepository -cne $expectedRepo) { throw 'Test repository does not match the registered target.' }
    $root=[IO.Path]::GetFullPath($TestRoot)
    if ($root -ceq [IO.Path]::GetFullPath($ProductRoot)) { throw 'Selected tests require a separate checkout from product source.' }
    Assert-TestBundleCheckout $root $TestSha
    $dir=if ($Role -ceq 'wrapper') {'tests/Wss.CSharpImplementation.Tests'} else {'tests/Wss.Cli.Tests'}
    $contractPath=Join-Path $root 'tests/test-contract.json'
    $contract=Get-Content -LiteralPath $contractPath -Raw | ConvertFrom-Json
    if (@(Compare-Object @('schema','role','test_directory') @($contract.PSObject.Properties.Name) -CaseSensitive).Count -ne 0 -or $contract.schema -cne 'wss-csharp-tests/v1' -or $contract.role -cne $Role -or $contract.test_directory -cne $dir) { throw 'Invalid test-only contract; product config and executable paths are not selectable.' }
    $tracked=@(Invoke-TestBundleGit $root @('ls-files','--stage','--',$dir,'tests/test-contract.json'))
    if (@($tracked | Where-Object { $_ -cnotmatch '^100644 ' }).Count) { throw 'Selected tests must be regular tracked files, not symlinks or submodules.' }
    if (@(Invoke-TestBundleGit $root @('status','--porcelain','--untracked-files=all','--ignored','--',$dir,'tests/test-contract.json')).Count) { throw 'Selected test directory contains ignored or untracked overrides.' }
    $sources=@(Get-ChildItem -LiteralPath (Join-Path $root $dir) -Filter '*.cs' -Recurse -File | Sort-Object FullName)
    if ($sources.Count -eq 0) { throw 'Selected test bundle contains no C# tests.' }
    if ($Role -ceq 'wrapper') {
        $canonical=Join-Path $root "$dir/StimulationControllerConformanceTests.cs"
        if ((Get-CanonicalCSharpFixtureHash $canonical) -cne '96812ab33be7ede8840ddb78131a50796fd3f797d9627f958251b3e58796baf8') { throw 'Selected bundle cannot replace the reviewed canonical assertions.' }
    }
    [pscustomobject]@{root=$root;sha=$TestSha;repository=$TestRepository;selection_id=$TestSelectionId;contract_sha256=(Get-TestBundleFileHash $contractPath);role=$Role;directory=$dir;sources=@($sources.FullName);hashes=@($sources | ForEach-Object { @{path=$_.FullName;sha256=(Get-TestBundleFileHash $_.FullName)} })}
}
function Assert-CSharpTestBundle($Bundle) {
    Assert-TestBundleCheckout $Bundle.root $Bundle.sha
    if ((Get-TestBundleFileHash (Join-Path $Bundle.root 'tests/test-contract.json')) -cne $Bundle.contract_sha256) { throw 'Test contract changed during execution.' }
    if (@(Invoke-TestBundleGit $Bundle.root @('status','--porcelain','--untracked-files=all','--ignored','--',$Bundle.directory,'tests/test-contract.json')).Count) { throw 'Test source changed during execution.' }
    foreach ($file in $Bundle.hashes) { if ((Get-TestBundleFileHash $file.path) -cne $file.sha256) { throw 'Selected test bytes changed during execution.' } }
}
function Assert-CSharpTestWorkRoot([string]$WorkRoot,[string[]]$InputRoots) {
    $work=[IO.Path]::GetFullPath($WorkRoot)
    $comparison=if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    foreach ($inputRoot in $InputRoots) {
        $root=[IO.Path]::GetFullPath($inputRoot).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
        if ($work.Equals($root,$comparison) -or $work.StartsWith($root+[IO.Path]::DirectorySeparatorChar,$comparison)) { throw 'Selected test work directory must be outside immutable input roots.' }
    }
    $parent=[IO.DirectoryInfo]::new($work).Parent
    while ($null -ne $parent) {
        if ($parent.Exists -and ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Selected test work directory cannot descend through a symlink or junction.' }
        $parent=$parent.Parent
    }
}
function Assert-CSharpFullTestResults([string]$TrxPath) {
    [xml]$trx=Get-Content -LiteralPath $TrxPath -Raw
    $results=@($trx.TestRun.Results.UnitTestResult)
    if ($results.Count -eq 0 -or @($results | Where-Object outcome -cne 'Passed').Count) { throw 'Selected full suite contains missing, skipped or non-passing results.' }
}