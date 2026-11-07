$ErrorActionPreference='Stop'
. "$PSScriptRoot/../TrustedBaseline.ps1"
$root=Join-Path ([IO.Path]::GetTempPath()) ('wss-baseline-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root
if(!$IsWindows){Push-Location $root;try{$root=(& /bin/pwd -P).Trim()}finally{Pop-Location}}
$tree=Join-Path $root 'tree';$null=New-Item -ItemType Directory -Path $tree
$file=Join-Path $tree 'original.txt';[IO.File]::WriteAllText($file,'baseline')
$snapshot=New-TrustedBaselineSnapshot @($tree)
function Reject([scriptblock]$Action){$rejected=$false;try{& $Action}catch{$rejected=$true};if(!$rejected){throw 'Unsafe baseline was accepted'}}
Assert-TrustedBaselineSnapshot $snapshot
[IO.File]::WriteAllText($file,'changed');Reject {Assert-TrustedBaselineSnapshot $snapshot};[IO.File]::WriteAllText($file,'baseline')
Remove-Item -LiteralPath $file;Reject {Assert-TrustedBaselineSnapshot $snapshot};[IO.File]::WriteAllText($file,'baseline')
$extra=Join-Path $tree '.hidden-evidence';[IO.File]::WriteAllText($extra,'added');Reject {Assert-TrustedBaselineSnapshot $snapshot};Remove-Item -LiteralPath $extra -Force
$empty=Join-Path $tree 'empty';$null=New-Item -ItemType Directory -Path $empty;Reject {Assert-TrustedBaselineSnapshot $snapshot};Remove-Item -LiteralPath $empty
# Case-distinct names remain distinct inventory entries on case-sensitive filesystems.
$caseFile=Join-Path $tree 'ORIGINAL.txt'
if(!(Test-Path -LiteralPath $caseFile)){
    [IO.File]::WriteAllText($caseFile,'baseline')
    Reject {Assert-TrustedBaselineSnapshot $snapshot}
    Remove-Item -LiteralPath $caseFile
}
# Windows junctions need no symlink privilege; Unix symlinks exercise the same reparse guard.
$outside=Join-Path $root 'outside';$null=New-Item -ItemType Directory -Path $outside
$link=Join-Path $tree 'redirect'
$type=if($IsWindows){'Junction'}else{'SymbolicLink'}
$null=New-Item -ItemType $type -Path $link -Target $outside
Reject {New-TrustedBaselineSnapshot @($tree)};Reject {Assert-TrustedBaselineSnapshot $snapshot}
Remove-Item -LiteralPath $link
Assert-TrustedBaselineSnapshot $snapshot
# A root replaced by an identical-content redirect must fail, not hash through it.
$moved=Join-Path $root 'moved';Move-Item -LiteralPath $tree -Destination $moved
$null=New-Item -ItemType $type -Path $tree -Target $moved
Reject {Assert-TrustedBaselineSnapshot $snapshot}
Remove-Item -LiteralPath $tree;Move-Item -LiteralPath $moved -Destination $tree
Assert-TrustedBaselineSnapshot $snapshot
Write-Output 'Baseline unchanged positive and content/deletion/addition/empty-directory/nested-redirect/root-redirect negatives passed.'

# Authentication inputs and Core executable bytes are frozen independently of Git metadata.
$authority=Join-Path $root 'authority';$tools=Join-Path $authority 'tools'
$null=New-Item -ItemType Directory -Path $tools -Force
$files=@((Join-Path $tools 'core.mjs'),(Join-Path $authority 'lock.json'),(Join-Path $authority 'context.json'),(Join-Path $authority 'roots.json'))
foreach($path in $files){[IO.File]::WriteAllText($path,'original-authority')}
$authoritySnapshot=New-TrustedBaselineSnapshot (@($tools)+@($files | Select-Object -Skip 1))
foreach($path in $files){
    [IO.File]::WriteAllText($path,'shifted-authority')
    Reject {Assert-TrustedBaselineSnapshot $authoritySnapshot}
    [IO.File]::WriteAllText($path,'original-authority')
    Assert-TrustedBaselineSnapshot $authoritySnapshot
}
Write-Output 'Core code, lock, context and roots byte-mutation negatives passed.'

# Root/module configuration and Git identity are outside tools but still authority.
. "$PSScriptRoot/../SelectedTestContext.ps1"
$core=Join-Path $root 'core-checkout';$null=New-Item -ItemType Directory -Path $core
$null=Invoke-SelectedContextGit $core @('init','--quiet')
$null=Invoke-SelectedContextGit $core @('config','user.name','Synthetic fixture')
$null=Invoke-SelectedContextGit $core @('config','user.email','fixture@example.invalid')
$package=Join-Path $core 'package.json';[IO.File]::WriteAllText($package,'{}')
$null=Invoke-SelectedContextGit $core @('add','package.json')
$null=Invoke-SelectedContextGit $core @('commit','--quiet','-m','Synthetic authority fixture')
$coreSnapshot=New-TrustedBaselineSnapshot @(Get-ReviewedCoreAuthorityRoots $core)
$null=Invoke-SelectedContextGit $core @('status','--porcelain','--untracked-files=all','--ignored')
Assert-TrustedBaselineSnapshot $coreSnapshot
foreach($path in @($package,(Join-Path $core '.git/config'),(Join-Path $core '.git/HEAD'))){
    $original=[IO.File]::ReadAllBytes($path)
    [IO.File]::AppendAllText($path,'shifted-authority')
    Reject {Assert-TrustedBaselineSnapshot $coreSnapshot}
    [IO.File]::WriteAllBytes($path,$original)
    Assert-TrustedBaselineSnapshot $coreSnapshot
}
$module=Join-Path $core 'node_modules';$null=New-Item -ItemType Directory -Path $module
Reject {Assert-TrustedBaselineSnapshot $coreSnapshot};Remove-Item -LiteralPath $module
Assert-TrustedBaselineSnapshot $coreSnapshot
Write-Output 'Complete Core checkout package/module/Git authority negatives and read-only Git positive passed.'
