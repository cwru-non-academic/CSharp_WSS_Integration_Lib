$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot/../MissingNativeEvidence.ps1"
$root = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $path = Join-Path $root 'result.trx'
    $diagnostic = 'Declared macOS backend requires exactly its managed adapter and native dylib; legacy facades must not carry orphan macOS files.'
    $valid = "<TestRun xmlns='http://microsoft.com/schemas/VisualStudio/TeamTest/2010'><Results><UnitTestResult testName='FacadeLoadsCurrentPlatformBackendAndDependencies' outcome='Failed'><Output><ErrorInfo><Message>  $diagnostic`nExpected: equivalent collection</Message></ErrorInfo></Output></UnitTestResult></Results></TestRun>"
    Set-Content -LiteralPath $path -Value $valid
    Assert-WssMissingNativeEvidence $path 1
    $cases = @(
        @{xml=$valid; code=0}, @{xml=$valid; code=2},
        @{xml=$valid.Replace('Failed','Passed'); code=1},
        @{xml=$valid.Replace('FacadeLoadsCurrentPlatformBackendAndDependencies','OtherTest'); code=1},
        @{xml=$valid.Replace($diagnostic,'Unrelated native load failure'); code=1},
        @{xml=$valid.Replace($diagnostic,"prefix $diagnostic"); code=1},
        @{xml=$valid.Replace('</Results>',"<UnitTestResult testName='OtherTest' outcome='Failed'/></Results>"); code=1}
    )
    foreach ($case in $cases) {
        Set-Content -LiteralPath $path -Value $case.xml
        $rejected = $false
        try { Assert-WssMissingNativeEvidence $path $case.code } catch { $rejected = $true }
        if (!$rejected) { throw 'Unrelated or incomplete negative evidence was accepted.' }
    }
    'PASS: exact missing-native TRX diagnostic and seven invalid evidence cases.'
} finally {
    # This directory was created by this test under the system temp directory.
    Remove-Item -LiteralPath (Join-Path $root 'result.trx') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $root -Force
}
