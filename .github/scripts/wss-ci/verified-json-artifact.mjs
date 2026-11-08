import {execFileSync} from 'node:child_process';
import {mkdtempSync,writeFileSync,rmSync} from 'node:fs';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import {bytesDigest,requireThat} from './verify.mjs';
// Bound JSON-only archive reader. No extraction, executable files or archive paths.
export function downloadVerifiedJsonArtifact(g,repository,artifact,files) {
  requireThat(/^[A-Za-z0-9_-]+\/[A-Za-z0-9_.-]+$/.test(repository)&&/^[1-9][0-9]*$/.test(String(artifact.id))&&/^sha256:[a-f0-9]{64}$/.test(artifact.digest)&&files.length===1&&/^[a-z-]+\.json$/.test(files[0]),'Invalid verified JSON archive request');
  const bytes=downloadVerifiedArtifactBytes(g,repository,artifact,4*1024*1024);
  return readVerifiedJsonArchive(bytes,artifact.digest,files);
}
export function readVerifiedJsonArchive(bytes,expectedDigest,files) {
  requireThat(Buffer.isBuffer(bytes)&&bytes.length<=4*1024*1024&&files.length===1&&/^[a-z-]+\.json$/.test(files[0]),'Invalid bounded archive');
  requireThat(`sha256:${bytesDigest(bytes)}`===expectedDigest,'Snapshot ZIP digest mismatch');
  const dir=mkdtempSync(join(tmpdir(),'wss-verified-json-'));
  try {
    const archive=join(dir,'artifact.zip'),script=join(dir,'read.ps1');
    writeFileSync(archive,bytes,{flag:'wx'});
    writeFileSync(script,`param([string]$Archive,[string]$Expected)\n$ErrorActionPreference='Stop'\n$zip=[IO.Compression.ZipFile]::OpenRead($Archive)\ntry {\n if($zip.Entries.Count -ne 1){throw 'Unexpected archive entries'}\n $entry=$zip.Entries[0]\n if($entry.FullName -cne $Expected -or $entry.Length -gt 1048576){throw 'Invalid archive entry'}\n $inputStream=$entry.Open();$outputStream=[IO.MemoryStream]::new()\n try {$buffer=[byte[]]::new(8192);$total=0;while(($count=$inputStream.Read($buffer,0,$buffer.Length)) -gt 0){$total+=$count;if($total -gt 1048576){throw 'Expanded JSON exceeds bound'};$outputStream.Write($buffer,0,$count)};[Convert]::ToBase64String($outputStream.ToArray())} finally {$inputStream.Dispose();$outputStream.Dispose()}\n} finally {$zip.Dispose()}\n`,{flag:'wx'});
    const encoded=execFileSync('pwsh',['-NoProfile','-NonInteractive','-File',script,archive,files[0]],{encoding:'utf8',maxBuffer:2*1024*1024}).trim();
    requireThat(/^[A-Za-z0-9+/]*={0,2}$/.test(encoded),'Invalid JSON archive transport');
    return {[files[0]]:Buffer.from(encoded,'base64')};
  } finally {rmSync(dir,{recursive:true,force:true});}
}

// Shared exact-ID transport. Callers own archive format and expanded-byte bounds.
export function downloadVerifiedArtifactBytes(g,repository,artifact,maxBytes=64*1024*1024) {
  requireThat(/^[A-Za-z0-9_-]+\/[A-Za-z0-9_.-]+$/.test(repository)&&/^[1-9][0-9]*$/.test(String(artifact.id))&&/^sha256:[a-f0-9]{64}$/.test(artifact.digest)&&Number.isSafeInteger(maxBytes)&&maxBytes>0&&maxBytes<=64*1024*1024,'Invalid bounded exact artifact request');
  const bytes=g.artifactBytes?g.artifactBytes(repository,String(artifact.id),maxBytes):execFileSync('gh',['api',`repos/${repository}/actions/artifacts/${artifact.id}/zip`],{env:g.environment,maxBuffer:maxBytes});
  requireThat(Buffer.isBuffer(bytes)&&bytes.length<=maxBytes&&`sha256:${bytesDigest(bytes)}`===artifact.digest,'Artifact ZIP digest mismatch');
  return bytes;
}
// Rich native proof archives: bounded safe extraction; native owners still check
// their exact file inventory, hashes and runtime semantics after this transport.
export function extractVerifiedProofArchive(bytes,destination) {
  requireThat(Buffer.isBuffer(bytes)&&bytes.length<=64*1024*1024&&typeof destination==='string','Invalid rich proof archive');
  const dir=mkdtempSync(join(tmpdir(),'wss-native-proof-'));
  try {
    const archive=join(dir,'artifact.zip'),script=join(dir,'extract.ps1');writeFileSync(archive,bytes,{flag:'wx'});
    writeFileSync(script,`param([string]$Archive,[string]$Destination)
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath $Destination){throw 'Native evidence destination must be new'}
$root=[IO.Path]::GetFullPath($Destination)
$zip=[IO.Compression.ZipFile]::OpenRead($Archive)
try {
 if($zip.Entries.Count -lt 1 -or $zip.Entries.Count -gt 512){throw 'Native archive entry bound'}
 $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
 $total=0L
 foreach($entry in $zip.Entries){
  $name=$entry.FullName
  if(!$name -or $name.Contains('\\') -or $name.Contains(':') -or $name.StartsWith('/') -or $name.TrimEnd('/') -match '(^|/)(\\.\\.?|)(/|$)' -or (($entry.ExternalAttributes -shr 16) -band 61440) -eq 40960){throw 'Unsafe native archive path/type'}
  foreach($part in $name.TrimEnd('/').Split('/')){if($part -match '[. ]$|[<>\"|?*\\x00-\\x1f]' -or $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\\.|$)'){throw 'Unsafe native archive component'}}
  $path=[IO.Path]::GetFullPath((Join-Path $root $name))
  if(!$path.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or !$seen.Add($path)){throw 'Duplicate/escaping native archive path'}
  if($entry.Length -gt 67108864){throw 'Native archive per-file bound'}
  $total+=$entry.Length;if($total -gt 268435456){throw 'Native archive expanded bound'}
 }
 $null=[IO.Directory]::CreateDirectory($root);$actual=0L
 foreach($entry in $zip.Entries){
  $path=[IO.Path]::GetFullPath((Join-Path $root $entry.FullName))
  if($entry.FullName.EndsWith('/')){$null=[IO.Directory]::CreateDirectory($path);continue}
  $null=[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
  $inputStream=$entry.Open();$outputStream=[IO.File]::Open($path,[IO.FileMode]::CreateNew);$counted=0L
  try{$buffer=[byte[]]::new(81920);while(($count=$inputStream.Read($buffer,0,$buffer.Length)) -gt 0){$counted+=$count;$actual+=$count;if($counted -gt 67108864 -or $actual -gt 268435456){throw 'Native archive streamed bound'};$outputStream.Write($buffer,0,$count)}}finally{$inputStream.Dispose();$outputStream.Dispose()}
 }
}finally{$zip.Dispose()}
`,{flag:'wx'});
    execFileSync('pwsh',['-NoProfile','-NonInteractive','-File',script,archive,destination],{maxBuffer:1024*1024});
  }finally{rmSync(dir,{recursive:true,force:true});}
}
