# Common argument-safe native process boundary. Callers own capability/token scope.
function Invoke-WssCiProcess {
    param(
        [Parameter(Mandatory)][ValidateSet('gh','git','node')][string]$Executable,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments,
        [string]$FailureMessage='Native CI command failed'
    )
    $output = & $Executable @Arguments
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw "$FailureMessage (exit $code)." }
    $output
}
