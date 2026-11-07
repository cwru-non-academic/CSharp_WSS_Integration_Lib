function Assert-WssMissingNativeEvidence([string] $TrxPath, [int] $ExitCode) {
    if ($ExitCode -ne 1) { throw "Expected dotnet test failure exit code 1, got $ExitCode." }
    [xml]$trx = Get-Content -LiteralPath $TrxPath -Raw
    $results = @($trx.SelectNodes("//*[local-name()='UnitTestResult']"))
    $diagnostic = 'Declared macOS backend requires exactly its managed adapter and native dylib; legacy facades must not carry orphan macOS files.'
    if ($results.Count -ne 1 -or
        $results[0].testName -cne 'FacadeLoadsCurrentPlatformBackendAndDependencies' -or
        $results[0].outcome -cne 'Failed') { throw 'Expected exactly the failed BLE backend load test.' }
    $message = $results[0].SelectSingleNode("*[local-name()='Output']/*[local-name()='ErrorInfo']/*[local-name()='Message']")
    if ($null -eq $message -or $diagnostic -cnotin @($message.InnerText -split "\r?\n" | ForEach-Object { $_.Trim() })) {
        throw 'Missing exact declared macOS native-payload diagnostic in TRX.'
    }
}
