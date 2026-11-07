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
