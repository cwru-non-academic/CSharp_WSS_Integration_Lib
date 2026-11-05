$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot/../WssReleaseReceipt.ps1"

# Hosted configuration contract: cross-repository evidence uses only the
# existing, explicitly scoped read-only WSS App token.
function Assert-WssReceiptEvidenceWorkflow([string] $Workflow, [string] $ExpectedRepository) {
    $tokens=[regex]::Matches($Workflow,'(?ms)^      - name: Create receipt evidence read token\r?\n(?<body>.*?)(?=^      - |\z)')
    $validation=[regex]::Match($Workflow,'(?ms)^      - name: Validate provenance,[^\r\n]*\r?\n(?<body>.*?)(?=^      - |\z)')
    if ($tokens.Count -ne 1 -or !$validation.Success -or $tokens[0].Index -ge $validation.Index -or
        [regex]::Matches($Workflow,'(?m)^\s+uses: actions/create-github-app-token@').Count -ne 1) { throw 'Receipt evidence token must be minted once before validation.' }
    $body=$tokens[0].Groups['body'].Value
    foreach ($line in @(
        '        id: receipt-evidence',
        '        uses: actions/create-github-app-token@v2',
        ('          app-id: '+'$'+'{{ vars.WSS_GITHUB_APP_ID }}'),
        ('          private-key: '+'$'+'{{ secrets.WSS_GITHUB_APP_PRIVATE_KEY }}'),
        '          owner: cwru-non-academic'
    )) { if (!(($body -split '\r?\n') -ccontains $line)) { throw 'Receipt token must use the existing WSS App configuration.' } }
    $repositories=[regex]::Matches($body,'(?m)^          repositories: \|\r?\n(?<items>(?:            \S+\r?\n)+)')
    if ($repositories.Count -ne 1) { throw 'Receipt token requires an explicit repository list.' }
    $actual=@($repositories[0].Groups['items'].Value.Trim() -split '\r?\n' | ForEach-Object { $_.Trim() })
    $required=@('WSSCore','CSharp_WSS_Integration_Lib','CLI_CSharp_WSS_Application')
    if ($actual.Count -ne 3 -or @(Compare-Object $required $actual -CaseSensitive).Count) { throw 'Receipt evidence token repository scope changed.' }
    $permissions=[regex]::Matches($body,'(?m)^\s+permission-(?<name>[a-z-]+): (?<level>\S+)\r?$')
    if ($permissions.Count -ne 3) { throw 'Receipt evidence token permissions must be exactly the three read permissions.' }
    foreach ($name in @('contents','actions','pull-requests')) {
        $matching=@($permissions | Where-Object { $_.Groups['name'].Value -ceq $name -and $_.Groups['level'].Value -ceq 'read' })
        if ($matching.Count -ne 1) { throw 'Receipt evidence token cannot request missing, duplicate or write permissions.' }
    }
    $expectedToken='          GH_TOKEN: '+'$'+'{{ steps.receipt-evidence.outputs.token }}'
    if (!(($validation.Groups['body'].Value -split '\r?\n') -ccontains $expectedToken) -or
        [regex]::Matches($Workflow,'(?m)^\s+GH_TOKEN:').Count -ne 1) { throw 'Receipt validation must use only the scoped evidence token.' }
    if (!$Workflow.Contains("    if: github.repository == '$ExpectedRepository' && github.ref == 'refs/heads/dev'")) { throw 'Receipt execution must remain canonical-repository and dev-only.' }
}
$receiptWorkflow=Get-Content "$PSScriptRoot/../../workflows/release-receipt.yml" -Raw
$receiptRepository=if ($receiptWorkflow.Contains('run-name: WSS acceptance csharp-wrapper ')) {
    'cwru-non-academic/CSharp_WSS_Integration_Lib'
} elseif ($receiptWorkflow.Contains('run-name: WSS acceptance csharp-cli ')) {
    'cwru-non-academic/CLI_CSharp_WSS_Application'
} else { throw 'Unknown C# receipt workflow target.' }
Assert-WssReceiptEvidenceWorkflow $receiptWorkflow $receiptRepository
$evidenceRejections=0
foreach ($mutate in @(
    {param($w)$w.Replace(('GH_TOKEN: '+'$'+'{{ steps.receipt-evidence.outputs.token }}'),('GH_TOKEN: '+'$'+'{{ github.token }}'))},
    {param($w)$w.Replace('          owner: cwru-non-academic','          owner: another-owner')},
    {param($w)$w.Replace('            WSSCore',('            OtherRepository'+[Environment]::NewLine+'            WSSCore'))},
    {param($w)$w.Replace('permission-actions: read','permission-actions: write')},
    {param($w)$w.Replace('permission-pull-requests: read','permission-issues: read')},
    {param($w)$w.Replace("github.ref == 'refs/heads/dev'","github.ref == 'refs/heads/main'")},
    {param($w)$token=[regex]::Match($w,'(?ms)^      - name: Create receipt evidence read token\r?\n.*?(?=^      - |\z)').Value; $w.Replace($token,'')+$token}
)) {
    $invalid=& $mutate $receiptWorkflow
    if ($invalid -ceq $receiptWorkflow) { throw 'Evidence-token regression fixture did not change the workflow.' }
    $rejected=$false
    try { Assert-WssReceiptEvidenceWorkflow $invalid $receiptRepository } catch { $rejected=$true }
    if (!$rejected) { throw 'Unsafe evidence-token workflow was accepted.' }
    $evidenceRejections++
}
"Hosted receipt evidence-token contracts passed ($evidenceRejections unsafe configurations rejected)."

$count = 0
function Reject([scriptblock] $Action) {
    $failed = $false
    try { & $Action } catch { $failed = $true }
    if (-not $failed) { throw 'Expected invalid receipt evidence to be rejected.' }
    $script:count++
}
$repo = 'cwru-non-academic/CSharp_WSS_Integration_Lib'
$sha = '1' * 40
function Pr { [pscustomobject]@{merged=$true;merged_by=@{type='User'};state='closed';merge_commit_sha=$sha;base=@{ref='dev';repo=@{full_name=$repo}};head=@{repo=@{full_name=$repo}};user=@{type='Bot'}} }
$p = Pr
Assert-WssReceiptPr $p $repo $sha
foreach ($mutate in @(
    { param($p) $p.merged=$false }, { param($p) $p.state='open' },
    { param($p) $p.merge_commit_sha='2'*40 }, { param($p) $p.base.ref='main' },
    { param($p) $p.head.repo.full_name='fork/test' }, { param($p) $p.user.type='User' }, { param($p) $p.merged_by.type='Bot' }
)) { $p=Pr; & $mutate $p; Reject { Assert-WssReceiptPr $p $repo $sha } }
$target = @{workflow='.github/workflows/wss-compatibility.yml';jobs=@('Integration behavioral tests','Integration compatibility (macOS)')}
function Run { [pscustomobject]@{status='completed';conclusion='success';head_branch='dev';head_sha=$sha;repository=@{full_name=$repo};head_repository=@{full_name=$repo};path=$target.workflow;event='workflow_dispatch'} }
function Jobs { @($target.jobs | ForEach-Object { [pscustomobject]@{name=$_;status='completed';conclusion='success'} }) }
Assert-WssReceiptNormalRun (Run) $repo $target $sha (Jobs)
foreach ($mutate in @(
    { param($r) $r.event='pull_request' }, { param($r) $r.status='in_progress' },
    { param($r) $r.conclusion='failure' }, { param($r) $r.head_branch='main' },
    { param($r) $r.head_sha='2'*40 }, { param($r) $r.path='.github/workflows/wss-preflight.yml' },
    { param($r) $r.head_repository.full_name='fork/test' }
)) { $r=Run; & $mutate $r; Reject { Assert-WssReceiptNormalRun $r $repo $target $sha (Jobs) } }
Reject { Assert-WssReceiptNormalRun (Run) $repo $target $sha @() }
$j=Jobs; $j[1].conclusion='skipped'; Reject { Assert-WssReceiptNormalRun (Run) $repo $target $sha $j }
$j=Jobs; $j+= $j[1]; Reject { Assert-WssReceiptNormalRun (Run) $repo $target $sha $j }
Assert-WssReceiptChangedFiles csharp-wrapper @(@{filename='lib/backends/macos/libwss_macos_ble.dylib'})
Assert-WssReceiptChangedFiles csharp-cli @(@{filename='SubModules/HFI_WSS_Csharp_Implementation'})
Reject { Assert-WssReceiptChangedFiles csharp-wrapper @() }
Reject { Assert-WssReceiptChangedFiles csharp-wrapper @(@{filename='.github/workflows/unrelated.yml'}) }
Reject { Assert-WssReceiptChangedFiles csharp-cli @(@{filename='SubModules/HFI_WSS_Csharp_Implementation'},@{filename='Program.cs'}) }
Reject { Assert-WssReceiptChangedFiles unknown @(@{filename='lib/test'}) }
$frozenSources = @{target_snapshots=@{'csharp-wrapper'=@{head_sha=('a'*40)};'csharp-cli'=@{head_sha=('b'*40)}}}
$sourceApproval = @{integration=@{source_sha=('a'*40)};cli=@{source_sha=('b'*40)}}
Assert-WssReceiptSources $sourceApproval $frozenSources
$sourceApproval.integration.source_sha='c'*40
Reject { Assert-WssReceiptSources $sourceApproval $frozenSources }
$sourceApproval.integration.source_sha='a'*40
$sourceApproval.cli.source_sha='c'*40
Reject { Assert-WssReceiptSources $sourceApproval $frozenSources }
"Receipt acceptance boundary tests passed ($count rejections; valid merged PR, exact normal CI, frozen preflight sources and allowed dependency scopes)."

# Exercise the production trust boundary without running the networked emitter.
$emitterPath = Join-Path $PSScriptRoot '../Write-ReleaseReceipt.ps1'
$parseErrors = $null
$emitterAst = [System.Management.Automation.Language.Parser]::ParseFile($emitterPath, [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Receipt emitter does not parse.' }
$definition = @($emitterAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Assert-WssReceiptTooling'
}, $true))
if ($definition.Count -ne 1) { throw 'Unique production receipt tooling guard required.' }
. ([scriptblock]::Create($definition[0].Extent.Text))
function Invoke-ReceiptGit([string] $Root, [string[]] $Arguments) {
    $key = "$Root|$($Arguments[-1])"
    if (-not $script:receiptObjects.ContainsKey($key)) { throw "Unexpected Git object lookup: $key" }
    $script:receiptObjects[$key]
}
function Check-Tooling {
    Assert-WssReceiptTooling $plan $targetId $target '.tools' '.validation-tools' '.accepted' '.integration'
}
function Reject-ToolingMutation([string] $Key, [string] $ExpectedMessage) {
    $before = $script:receiptObjects[$Key]
    $script:receiptObjects[$Key] = 'changed-object'
    $rejected = $false
    try { Check-Tooling } catch {
        if ($_.Exception.Message -cnotlike $ExpectedMessage) { throw }
        $rejected = $true
    } finally { $script:receiptObjects[$Key] = $before }
    if (-not $rejected) { throw "Changed trust object was accepted: $Key" }
    $script:toolingRejections++
}
$toolingRejections = 0
foreach ($targetId in @('csharp-wrapper', 'csharp-cli')) {
    $normal = if ($targetId -ceq 'csharp-wrapper') { '.github/workflows/wss-compatibility.yml' } else { '.github/workflows/cli-ci.yml' }
    $trusted = @('.github/scripts', '.github/workflows/release-receipt.yml', $normal)
    $target = @{ trusted_paths = $trusted }
    $snapshot = @{ '.github/scripts' = 'accepted-scripts'; '.github/workflows/release-receipt.yml' = 'receipt-workflow'; $normal = 'dev-normal-ci' }
    $plan = @{ target_snapshots = @{ 'csharp-wrapper' = @{ trusted = @{ '.github/scripts' = 'wrapper-scripts' } } } }
    $plan.target_snapshots[$targetId] = @{ trusted = $snapshot }
    $wrapperRoot = if ($targetId -ceq 'csharp-wrapper') { '.accepted' } else { '.integration' }
    $script:receiptObjects = @{}
    foreach ($path in $trusted) { $script:receiptObjects[".accepted|HEAD:$path"] = $snapshot[$path] }
    # Branch-specific CI and script trees intentionally differ on main.
    $script:receiptObjects[".tools|HEAD:$normal"] = 'main-normal-ci'
    $script:receiptObjects['.tools|HEAD:.github/scripts'] = 'main-other-scripts'
    $script:receiptObjects['.validation-tools|HEAD:.github/scripts'] = 'main-other-validator-scripts'
    foreach ($path in @('.github/workflows/release-receipt.yml', '.github/scripts/Write-ReleaseReceipt.ps1', '.github/scripts/WssReleaseReceipt.ps1', '.github/scripts/wss-ci')) {
        $value = if ($path -ceq '.github/workflows/release-receipt.yml') { 'receipt-workflow' } elseif ($path -ceq '.github/scripts/wss-ci') { "wrapper-file:$path" } else { "receiver-file:$path" }
        $script:receiptObjects[".accepted|HEAD:$path"] = $value
        $script:receiptObjects[".tools|HEAD:$path"] = $value
    }
    $script:receiptObjects["$wrapperRoot|HEAD:.github/scripts"] = $plan.target_snapshots.'csharp-wrapper'.trusted.'.github/scripts'
    foreach ($path in @('.github/scripts/WssPromotion.ps1', '.github/scripts/Universal-WssFiles.ps1', '.github/scripts/Resolve-WssRelease.ps1', '.github/scripts/wss-ci')) {
        $script:receiptObjects["$wrapperRoot|HEAD:$path"] = "wrapper-file:$path"
        $script:receiptObjects[".validation-tools|HEAD:$path"] = "wrapper-file:$path"
    }
    Check-Tooling
    foreach ($path in $trusted) {
        Reject-ToolingMutation ".accepted|HEAD:$path" 'Accepted receiver tooling differs:*'
    }
    foreach ($path in @('.github/workflows/release-receipt.yml', '.github/scripts/Write-ReleaseReceipt.ps1', '.github/scripts/WssReleaseReceipt.ps1', '.github/scripts/wss-ci')) {
        Reject-ToolingMutation ".tools|HEAD:$path" 'Trusted main receipt tooling differs:*'
    }
    foreach ($path in @('.github/scripts/WssPromotion.ps1', '.github/scripts/Universal-WssFiles.ps1', '.github/scripts/Resolve-WssRelease.ps1', '.github/scripts/wss-ci')) {
        Reject-ToolingMutation ".validation-tools|HEAD:$path" 'Shared C# validator differs from frozen code:*'
    }
    if ($targetId -ceq 'csharp-cli') {
        Reject-ToolingMutation '.integration|HEAD:.github/scripts' 'Accepted wrapper validators differ from frozen code.*'
    }
}
Remove-Item Function:Invoke-ReceiptGit
"Branch-aware receipt tooling tests passed (two divergent-CI targets; $toolingRejections exact-object rejections)."

# Receiver-owned policy cannot be weakened by a producer-supplied manifest.
foreach ($policyId in @('csharp-wrapper','csharp-cli')) {
    $isWrapper=$policyId -ceq 'csharp-wrapper'
    $policy=[pscustomobject]@{
        repository=$(if ($isWrapper) { 'cwru-non-academic/CSharp_WSS_Integration_Lib' } else { 'cwru-non-academic/CLI_CSharp_WSS_Application' })
        branch='dev'; kind=$(if ($isWrapper) { 'payload' } else { 'gitlink' })
        workflow=$(if ($isWrapper) { '.github/workflows/wss-compatibility.yml' } else { '.github/workflows/cli-ci.yml' })
        jobs=$(if ($isWrapper) { @('Integration behavioral tests','Integration compatibility (Windows)','Integration compatibility (Ubuntu)','Integration compatibility (macOS)') } else { @('CLI general conformance','CLI platform compatibility (Windows)','CLI platform compatibility (Ubuntu)','CLI platform compatibility (macOS)') })
        parents=$(if ($isWrapper) { [pscustomobject]@{} } else { [pscustomobject]@{'csharp-wrapper'='SubModules/HFI_WSS_Csharp_Implementation'} })
        trusted_paths=@('.github/scripts','.github/workflows/release-receipt.yml',$(if ($isWrapper) { '.github/workflows/wss-compatibility.yml' } else { '.github/workflows/cli-ci.yml' }))
        coverage=@('canonical-conformance','packaged-macos-ble-load')
    }
    Assert-WssReceiptPolicy $policyId $policy
    foreach ($mutation in @(
        {param($p)$p.jobs=@($p.jobs[0])}, {param($p)$p.workflow='.github/workflows/wss-preflight.yml'},
        {param($p)$p.branch='main'}, {param($p)$p.repository='other/repository'},
        {param($p)$p.coverage=@('canonical-conformance')}, {param($p)$p.trusted_paths=@('.github/scripts')},
        {param($p)$p.parents=[pscustomobject]@{'csharp-wrapper'='other/gitlink'}}
    )) {
        $bad=$policy | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        & $mutation $bad
        Reject { Assert-WssReceiptPolicy $policyId $bad }
    }
}
$normalTarget=@{workflow='.github/workflows/cli-ci.yml';jobs=@('CLI general conformance')}
$normalRepo='cwru-non-academic/CLI_CSharp_WSS_Application'
$normalSha='a'*40
$originalNormal=[pscustomobject]@{id=123;run_attempt=1}
$latestNormal=[pscustomobject]@{id=123;run_attempt=1}
$liveNormal=[pscustomobject]@{id=123;run_attempt=1;repository=@{full_name=$normalRepo};head_repository=@{full_name=$normalRepo};head_branch='dev';head_sha=$normalSha;path=$normalTarget.workflow;event='workflow_dispatch';status='completed';conclusion='success'}
$normalJobs=@([pscustomobject]@{name='CLI general conformance';status='completed';conclusion='success'})
Assert-WssReceiptNormalFresh $originalNormal $latestNormal $liveNormal $normalRepo $normalTarget $normalSha $normalJobs
$latestNormal.id=124
Reject { Assert-WssReceiptNormalFresh $originalNormal $latestNormal $liveNormal $normalRepo $normalTarget $normalSha $normalJobs }
$latestNormal.id=123; $latestNormal.run_attempt=2
Reject { Assert-WssReceiptNormalFresh $originalNormal $latestNormal $liveNormal $normalRepo $normalTarget $normalSha $normalJobs }
$latestNormal.run_attempt=1; $liveNormal.run_attempt=2
Reject { Assert-WssReceiptNormalFresh $originalNormal $latestNormal $liveNormal $normalRepo $normalTarget $normalSha $normalJobs }
$liveNormal.run_attempt=1; $liveNormal.conclusion='failure'
Reject { Assert-WssReceiptNormalFresh $originalNormal $latestNormal $liveNormal $normalRepo $normalTarget $normalSha $normalJobs }
"Receiver-owned policy and final CI identity tests passed (18 new rejections)."

# Exercise production command wrappers without network, credentials, or receipt emission.
& {
    $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../Write-ReleaseReceipt.ps1'),[ref]$null,[ref]$errors)
    if ($errors.Count) { throw 'Receipt emitter does not parse.' }
    foreach ($name in @('Invoke-ReceiptGh','Invoke-ReceiptGit','Api')) {
        $definitions=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true))
        if ($definitions.Count -ne 1) { throw "Unique production command helper required: $name" }
        . ([scriptblock]::Create($definitions[0].Extent.Text))
    }
    $collisions=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in @('gh','git')},$true))
    if ($collisions.Count) { throw 'Receipt helpers must not shadow native command names.' }
    $calls=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -in @('Invoke-ReceiptGh','Invoke-ReceiptGit')},$true))
    foreach ($call in $calls) {
        if (!@($call.CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -ceq 'Arguments' }).Count) {
            throw 'Receipt command arrays must be bound explicitly, not splatted into positional parameters.'
        }
    }
    $savedExitVariable=Get-Variable LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
    $hadExitCode=$null -ne $savedExitVariable
    $savedExitCode=if ($hadExitCode) { $savedExitVariable.Value } else { $null }
    try {
        function gh { $global:LASTEXITCODE=0; @{arguments=@($args)} | ConvertTo-Json -Compress }
        function git { $global:LASTEXITCODE=0; @{arguments=@($args)} | ConvertTo-Json -Compress }
        $api=Api 'repos/example/repo'
        if (($api.arguments -join '|') -cne 'api|repos/example/repo') { throw 'GitHub API arguments were lost.' }
        $download=Invoke-ReceiptGh -Arguments @('run','download','123','--repo','example/repo','--dir','path with spaces') | ConvertFrom-Json
        if (($download.arguments -join '|') -cne 'run|download|123|--repo|example/repo|--dir|path with spaces') { throw 'GitHub command arguments were changed.' }
        $object=Invoke-ReceiptGit 'root with spaces' -Arguments @('rev-parse','HEAD:.github/scripts') | ConvertFrom-Json
        if (($object.arguments -join '|') -cne '-C|root with spaces|rev-parse|HEAD:.github/scripts') { throw 'Git command arguments were changed.' }
        function gh { $global:LASTEXITCODE=17 }
        function git { $global:LASTEXITCODE=18 }
        foreach ($failure in @(
            @{action={Invoke-ReceiptGh -Arguments @('api','missing')};message='GitHub evidence request failed: api'},
            @{action={Invoke-ReceiptGit '.' -Arguments @('rev-parse','missing')};message='Git evidence request failed.'}
        )) {
            $rejected=$false
            try { & $failure.action } catch {
                if ($_.Exception.Message -cne $failure.message) { throw }
                $rejected=$true
            }
            if (!$rejected) { throw 'Native command failure was accepted.' }
        }
    } finally {
        if ($hadExitCode) { $global:LASTEXITCODE=$savedExitCode }
        else { Remove-Variable LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue }
    }
}
"Receipt command dispatch contracts passed (no native-name collision; complete argument arrays; fail-closed exit codes)."
