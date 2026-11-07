# Selected suites have no authentication environment or parent PowerShell scope.
function Invoke-CredentialFreeSelectedProcess([string]$FilePath,[string[]]$Arguments,[int]$TimeoutSeconds=1800) {
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=$FilePath
    $start.UseShellExecute=$false
    $start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true
    $start.RedirectStandardError=$true
    foreach($argument in $Arguments){$start.ArgumentList.Add([string]$argument)}
    $handles=@('GITHUB_ENV','GITHUB_OUTPUT','GITHUB_PATH','GITHUB_STATE','SSH_AUTH_SOCK','SSH_AGENT_PID','GIT_ASKPASS','GIT_SSH_COMMAND')
    foreach($name in @($start.Environment.Keys)){
        if($name -match '(?i)TOKEN|SECRET|PASSWORD|PRIVATE.?KEY|CREDENTIAL' -or $name -cin $handles){$null=$start.Environment.Remove($name)}
    }
    $process=[Diagnostics.Process]::new()
    $process.StartInfo=$start
    try{
        if(!$process.Start()){throw 'Could not start isolated selected suite.'}
        $stdout=$process.StandardOutput.ReadToEndAsync()
        $stderr=$process.StandardError.ReadToEndAsync()
        if(!$process.WaitForExit($TimeoutSeconds*1000)){$process.Kill($true);$process.WaitForExit();throw 'Isolated selected suite timed out; no evidence emitted.'}
        $out=$stdout.GetAwaiter().GetResult();$err=$stderr.GetAwaiter().GetResult()
        if($out){Write-Host $out}
        if($err){Write-Host $err}
        if($process.ExitCode -ne 0){throw "Isolated selected suite failed ($($process.ExitCode)); no evidence emitted."}
    } finally {$process.Dispose()}
}
function Invoke-CredentialFreeSelectedPowerShell([string]$Runner,[hashtable]$Options) {
    $arguments=@('-NoLogo','-NoProfile','-NonInteractive','-File',$Runner)
    foreach($key in $Options.Keys){$arguments+="-$key";$arguments+=[string]$Options[$key]}
    Invoke-CredentialFreeSelectedProcess (Get-Command pwsh -ErrorAction Stop).Source $arguments
}
