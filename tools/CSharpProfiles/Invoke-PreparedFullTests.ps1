param([string]$EvidencePath=$env:WSS_PROFILE_EVIDENCE,[string]$ResultsDirectory=(Join-Path ([IO.Path]::GetTempPath()) ('wss-full-'+[guid]::NewGuid().ToString('N'))))
$ErrorActionPreference='Stop'
. "$PSScriptRoot/../../.github/scripts/CSharpTestSource.ps1"
$state=Get-Content -LiteralPath $EvidencePath -Raw | ConvertFrom-Json
& dotnet build $state.project -c Release -p:TreatWarningsAsErrors=true -p:ImportDirectoryBuildProps=false -p:ImportDirectoryBuildTargets=false "-p:WSS_ARTIFACT_DIR=$($state.payload_root)" "-p:WSS_BLE_ARTIFACT_DIR=$($state.payload_root)"
if($LASTEXITCODE -ne 0){throw 'Prepared full-suite build failed.'}
& "$PSScriptRoot/Invoke-PreparedBehavior.ps1" -EvidencePath $EvidencePath -ResultsDirectory (Join-Path $ResultsDirectory 'behavior')
& dotnet test $state.project -c Release --no-build --no-restore -p:ImportDirectoryBuildProps=false -p:ImportDirectoryBuildTargets=false --logger 'trx;LogFileName=all.trx' --results-directory $ResultsDirectory
if($LASTEXITCODE -ne 0){throw 'Prepared full-suite tests failed.'}
Assert-CSharpFullTestResults (Join-Path $ResultsDirectory 'all.trx')
