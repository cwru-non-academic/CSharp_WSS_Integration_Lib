# Integration-owned, best-effort observational diagnostics. No validation or execution engine.
# Values are closed vocabularies, so there is no exception/CLI/API/environment serialization.
function Write-WssCiPhaseDiagnostic {
    param([string]$Family, [string]$Role, [string]$Operation, [string]$Status, [string]$ErrorCode, [switch]$Boundary)
    $exitVariable = Get-Variable LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
    $exitPresent = $null -ne $exitVariable
    $exitValue = if ($exitPresent) { $exitVariable.Value } else { $null }
    try {
        if ($Family -cnotin @('csharp','unity','python','matlab')) { return }
        $roles = @{csharp=@('cli');unity=@('gui');python=@('cli','ros','plan');matlab=@('cli')}
        if ($Role -cnotin $roles[$Family]) { return }
        if ($Operation -cnotin @('validate-baseline','plan-approval','resolve-stage','reconstruct-stage','validate-metadata','validate-family','prepare-intent','recheck-barrier','recheck-source','recheck-reuse','recheck-intent','validate-approval','inspect-reuse','validate-intent','write-intent','read-core-main','verify-barrier','read-reviewed-merge','validate-reviewed-merge','validate-producer','validate-staging-policy','resolve-roles','validate-family-evidence','validate-human-merge','write-ready-event')) { return }
        if ($Status -cnotin @('started','completed','failed')) { return }
        if ($ErrorCode -cnotin @('none','terminating-error','native-nonzero')) { return }
        if (($Status -ceq 'failed') -ne ($ErrorCode -cne 'none')) { return }
        # One family/role/operation slot, not a predicate or tracing stack.
        # Only an exact matching completion clears it. A new outer step starts fresh. Outer catch uses it
        # only when its started marker has no matching completed marker.
        $boundaryOperation = $Operation
        $active = Get-Variable WssCiDiagnosticActiveOperation -Scope Global -ValueOnly -ErrorAction SilentlyContinue
        $sameOwner = $active -is [System.Collections.IDictionary] -and $active.Contains('Family') -and $active.Contains('Role') -and $active.Contains('Operation') -and $active.Family -ceq $Family -and $active.Role -ceq $Role
        $sameOperation = $sameOwner -and $active.Operation -ceq $Operation
        if ($Boundary) {
            if ($Status -ceq 'failed' -and $sameOwner -and $active.Operation -cin @('validate-approval','inspect-reuse','validate-intent','write-intent','read-core-main','verify-barrier','read-reviewed-merge','validate-reviewed-merge','validate-producer','validate-staging-policy','resolve-roles','validate-family-evidence','validate-human-merge','write-ready-event','recheck-source','recheck-reuse','recheck-intent')) { $Operation = $active.Operation }
            if ($Status -ceq 'started' -or ($Status -ceq 'completed' -and $sameOperation)) { $global:WssCiDiagnosticActiveOperation = $null }
        } else {
            if ($Status -ceq 'started') { $global:WssCiDiagnosticActiveOperation = @{Family=$Family;Role=$Role;Operation=$Operation} }
            elseif ($Status -ceq 'completed' -and $sameOperation) { $global:WssCiDiagnosticActiveOperation = $null }
        }
        $scope = if ($Boundary) { 'step' } else { 'operation' }
        # Fixed ASCII keys/values only; neither arbitrary annotations nor paths can be injected.
        $record = "wss-ci-phase/v1 family=$Family role=$Role phase=validation scope=$scope boundary=$boundaryOperation operation=$Operation status=$Status error=$ErrorCode"
        Write-Host "::notice title=WSS CI phase::$record"
    } catch { }
    finally {
        if ($exitPresent) { $global:LASTEXITCODE = $exitValue }
        else { Remove-Variable LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue }
    }
}
