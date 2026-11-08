$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
# Exercise the unchanged production assertion, not an extracted or reimplemented copy.
. "$PSScriptRoot/../WssPromotion.ps1"
$owner=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../WssPromotion.ps1'))
if([IO.Path]::GetFullPath((Get-Command Assert-WssSource).ScriptBlock.File) -cne $owner){throw 'History test must use the real wrapper-owned source assertion.'}
$git=(Get-Command git -CommandType Application | Select-Object -First 1).Source
function Invoke-HistoryGit([string[]]$Arguments){
    $result=& $git @Arguments
    if($LASTEXITCODE -ne 0){throw "Git fixture operation failed: $($Arguments -join ' ')"}
    $result
}
function Commit-HistoryFixture([string]$Root,[string]$Message){
    $null=Invoke-HistoryGit @('-C',$Root,'-c','user.name=Receipt Contract','-c','user.email=receipt-contract@example.invalid','-c','commit.gpgsign=false','commit','--quiet','-m',$Message)
    (Invoke-HistoryGit @('-C',$Root,'rev-parse','HEAD')).Trim()
}
$temporaryRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$workspace=Join-Path $temporaryRoot ('wss receipt history '+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $workspace
$positive=0;$shallowRejected=0;$sourceRejected=0
try {
    foreach($consumer in @('integration','cli')){
        $source=Join-Path $workspace "$consumer source"
        $null=Invoke-HistoryGit @('init','--quiet','--initial-branch=accepted',$source)
        $null=New-Item -ItemType Directory -Path (Join-Path $source 'src')
        [IO.File]::WriteAllText((Join-Path $source 'src/Program.cs'),'frozen application source')
        [IO.File]::WriteAllText((Join-Path $source 'README.md'),'frozen documentation')
        $null=Invoke-HistoryGit @('-C',$source,'add','--','src/Program.cs','README.md')
        $initial=Commit-HistoryFixture $source 'Initial fixture'
        if($consumer -ceq 'cli'){
            # Real mode-160000 entries, without checking out or executing a submodule.
            $null=Invoke-HistoryGit @('-C',$source,'update-index','--add','--cacheinfo',"160000,$initial,SubModules/HFI_WSS_Csharp_Implementation")
        } else {
            $null=New-Item -ItemType Directory -Path (Join-Path $source 'lib')
            [IO.File]::WriteAllText((Join-Path $source 'lib/fixture.txt'),'frozen payload fixture')
            $null=Invoke-HistoryGit @('-C',$source,'add','--','lib/fixture.txt')
        }
        $frozen=Commit-HistoryFixture $source 'Frozen preflight source'
        if($consumer -ceq 'cli'){
            $null=Invoke-HistoryGit @('-C',$source,'update-index','--cacheinfo',"160000,$frozen,SubModules/HFI_WSS_Csharp_Implementation")
        } else {
            [IO.File]::WriteAllText((Join-Path $source 'lib/fixture.txt'),'accepted payload fixture')
            [IO.File]::WriteAllText((Join-Path $source 'README.md'),'allowed documentation update')
            $null=Invoke-HistoryGit @('-C',$source,'add','--','lib/fixture.txt','README.md')
        }
        $accepted=Commit-HistoryFixture $source 'Accepted dependency change'
        $url=([Uri]::new($source+[IO.Path]::DirectorySeparatorChar)).AbsoluteUri
        $shallow=Join-Path $workspace "$consumer shallow"
        $null=Invoke-HistoryGit @('clone','--quiet','--no-local','--depth','1','--single-branch','--branch','accepted',$url,$shallow)
        if((Invoke-HistoryGit @('-C',$shallow,'rev-parse','--is-shallow-repository')).Trim() -cne 'true'){throw 'Depth-one fixture is not shallow.'}
        if((Invoke-HistoryGit @('-C',$shallow,'rev-parse','HEAD')).Trim() -cne $accepted){throw 'Shallow fixture has wrong accepted head.'}
        & $git -C $shallow cat-file -e "$frozen`^{commit}" 2>$null
        if($LASTEXITCODE -eq 0){throw 'Depth-one fixture unexpectedly contains frozen source history.'}
        $failed=$false
        try {Assert-WssSource $shallow $frozen -Consumer $consumer} catch {
            if($_.Exception.Message -cne 'Cannot compare approved source with promotion source.'){throw}
            $failed=$true
        }
        if(!$failed){throw 'Shallow accepted source bypassed historical comparison.'};$shallowRejected++
        $full=Join-Path $workspace "$consumer full"
        $null=Invoke-HistoryGit @('clone','--quiet','--no-local','--branch','accepted',$url,$full)
        if((Invoke-HistoryGit @('-C',$full,'rev-parse','--is-shallow-repository')).Trim() -cne 'false'){throw 'Full fixture is shallow.'}
        $null=Invoke-HistoryGit @('-C',$full,'cat-file','-e',"$frozen`^{commit}")
        Assert-WssSource $full $frozen -Consumer $consumer
        $positive++
        $null=Invoke-HistoryGit @('-C',$source,'switch','--quiet','-c','forbidden')
        [IO.File]::WriteAllText((Join-Path $source 'src/Program.cs'),'unapproved application source')
        $null=Invoke-HistoryGit @('-C',$source,'add','--','src/Program.cs')
        $null=Commit-HistoryFixture $source 'Forbidden source change'
        $bad=Join-Path $workspace "$consumer forbidden"
        $null=Invoke-HistoryGit @('clone','--quiet','--no-local','--branch','forbidden',$url,$bad)
        $null=Invoke-HistoryGit @('-C',$bad,'cat-file','-e',"$frozen`^{commit}")
        $expected=if($consumer -ceq 'cli'){'Unexpected CLI source path: src/Program.cs'}else{'Unexpected promotion path: src/Program.cs'}
        $failed=$false
        try {Assert-WssSource $bad $frozen -Consumer $consumer} catch {
            if($_.Exception.Message -cne $expected){throw}
            $failed=$true
        }
        if(!$failed){throw 'Full history accepted a forbidden source change.'};$sourceRejected++
    }
} finally {
    # Only remove this newly created fixture tree, never a checkout or caller path.
    $resolved=[IO.Path]::GetFullPath($workspace)
    $prefix=$temporaryRoot.TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    if(!$resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -cnotmatch '^wss receipt history [0-9a-f]{32}$'){throw 'Unsafe history fixture cleanup path.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
$global:LASTEXITCODE=0
"Native receipt history contracts passed ($positive full-history positives; $shallowRejected missing-history rejections; $sourceRejected forbidden-source rejections; real owner assertion, no native execution)."