param([string] $ArtifactRoot = '')
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/../WssPromotion.ps1"
$temp = Join-Path ([IO.Path]::GetTempPath()) ([IO.Path]::GetRandomFileName())
New-Item -ItemType Directory -Path $temp | Out-Null
$count = 0
function Assert-Rejected([scriptblock] $Action, [string] $Message) {
    $rejected = $false
    try { & $Action } catch { $rejected = $true; if ($_.Exception.Message -notlike $Message) { throw } }
    if (-not $rejected) { throw "Expected rejection: $Message" }
    $script:count++
}
try {
    $approval = Read-WssApproval "$PSScriptRoot/../../universal-bootstrap.json"
    $marker = Get-WssApprovalMarker $approval
    $roundTrip = Read-WssApprovalMarker $marker (Join-Path $temp 'roundtrip.json')
    if ((Get-WssApprovalMarker $roundTrip) -cne $marker) { throw 'Approval marker round trip changed provenance.' }
    $count++
    foreach ($consumer in @('integration', 'cli')) {
        $record = Read-WssBootstrapProof "$PSScriptRoot/../../promotion-evidence" $consumer $approval (Join-Path $temp $consumer)
        Assert-WssCandidateRecord $record $approval
        $count++
    }
    $otherApproval = $approval | ConvertTo-Json -Depth 5 | ConvertFrom-Json
    $otherApproval.cli.preflight_run_id = '1'
    Assert-Rejected { Read-WssBootstrapProof "$PSScriptRoot/../../promotion-evidence" 'cli' $otherApproval (Join-Path $temp 'wrong-proof') } 'Archived proof is restricted*'
    Assert-Rejected { Read-WssApprovalMarker "$marker`n$marker" (Join-Path $temp 'duplicate.json') } 'Missing or ambiguous*'
    Assert-Rejected { Assert-WssCandidateRecord ([pscustomobject]@{ repository='other/repo' }) $approval } 'Candidate provenance mismatch*'
    foreach ($field in @('run_id', 'artifact_id', 'commit', 'archive', 'sha256')) {
        $record = $approval.candidate | ConvertTo-Json | ConvertFrom-Json
        $record.$field = 'wrong'
        Assert-Rejected { Assert-WssCandidateRecord $record $approval } 'Candidate provenance mismatch*'
    }
    Assert-WssPaths @('lib/WSS.Transport.Serial.dll', 'lib/wss-candidate.json')
    $count++
    Assert-Rejected { Assert-WssPaths @('lib/a.dll', 'src/StimulationController.cs') } 'Unexpected promotion path*'
    Assert-Rejected { Assert-WssPaths @() } 'Promotion diff is empty*'
    Assert-WssPaths @('lib/a.dll', 'src/Wss.CSharpImplementation.csproj') @('src/Wss.CSharpImplementation.csproj')
    Assert-Rejected { Assert-WssPaths @('lib/a.dll', 'src/StimulationController.cs') @('src/Wss.CSharpImplementation.csproj') } 'Unexpected promotion path*'
    $count++

    $originalProject = 'ac4ca9ca0371f2896f4a29b4f3ec1db55025f363'
    $alignedProject = 'e7bcaa356b22dc7b213c90d8ff2f6c5a8e5d6155'
    $candidateNewtonsoft = '8c1dd5c184b4e2e7ead06971ff3ebcb46783be972292d1deb1061744369b4d80'
    Assert-WssNewtonsoftTestAlignment $originalProject $alignedProject $candidateNewtonsoft
    $count++
    Assert-Rejected { Assert-WssNewtonsoftTestAlignment ('0'*40) $alignedProject $candidateNewtonsoft } 'Test dependency change is not*'
    Assert-Rejected { Assert-WssNewtonsoftTestAlignment $originalProject ('0'*40) $candidateNewtonsoft } 'Test dependency change is not*'
    Assert-Rejected { Assert-WssNewtonsoftTestAlignment $originalProject $alignedProject ('0'*64) } 'Test dependency change is not*'

    # Real Git regression: validate the postmerge CLI tree against its preflight
    # source. The only accepted dependency change is the exact wrapper gitlink.
    $sourceFixture = Join-Path $temp 'source-scope'
    New-Item -ItemType Directory -Path $sourceFixture | Out-Null
    function Fixture-Git {
        $output = & git -c user.name=ReceiptSourceTests -c user.email=receipt-source-tests@example.invalid -C $sourceFixture @args
        if ($LASTEXITCODE -ne 0) { throw 'Source-scope Git fixture command failed.' }
        $output
    }
    $null = Fixture-Git init --quiet -b main
    New-Item -ItemType Directory -Path (Join-Path $sourceFixture 'src') | Out-Null
    'validated CLI source' | Set-Content (Join-Path $sourceFixture 'src/Program.cs')
    'baseline' | Set-Content (Join-Path $sourceFixture 'README.md')
    $null = Fixture-Git add -- src/Program.cs README.md
    $null = Fixture-Git commit --quiet -m 'Initial fixture source'
    $oldPin = (Fixture-Git rev-parse HEAD).Trim()
    $null = Fixture-Git update-index --add --cacheinfo "160000,$oldPin,SubModules/HFI_WSS_Csharp_Implementation"
    $null = Fixture-Git commit --quiet -m 'Validated CLI preflight state'
    $preflightSource = (Fixture-Git rev-parse HEAD).Trim()
    $null = Fixture-Git switch --quiet -c dependency
    $null = Fixture-Git update-index --cacheinfo "160000,$preflightSource,SubModules/HFI_WSS_Csharp_Implementation"
    $null = Fixture-Git commit --quiet -m 'Update exact wrapper gitlink'
    $null = Fixture-Git switch --quiet main
    $null = Fixture-Git merge --quiet --no-ff dependency -m 'Reviewed dependency merge'
    $acceptedMerge = (Fixture-Git rev-parse HEAD).Trim()
    if (@((Fixture-Git rev-list --parents -n 1 HEAD) -split ' ').Count -ne 3) { throw 'Fixture must exercise an actual two-parent merge.' }
    if ((Fixture-Git ls-tree HEAD SubModules/HFI_WSS_Csharp_Implementation) -cnotmatch '^160000 commit ') { throw 'Fixture dependency must be a real gitlink.' }
    Assert-WssSource $sourceFixture $preflightSource -Consumer cli
    $count++
    Assert-Rejected { Assert-WssSource $sourceFixture $preflightSource } 'Unexpected promotion path: SubModules/HFI_WSS_Csharp_Implementation'

    # Preserve the existing documentation allowance for CLI, alongside its pin.
    'documented promotion' | Set-Content (Join-Path $sourceFixture 'README.md')
    $null = Fixture-Git add -- README.md
    $null = Fixture-Git commit --quiet -m 'Document the merge'
    Assert-WssSource $sourceFixture $preflightSource -Consumer cli
    $count++
    'unreviewed CLI source' | Set-Content (Join-Path $sourceFixture 'src/Program.cs')
    $null = Fixture-Git add -- src/Program.cs
    $null = Fixture-Git commit --quiet -m 'Unrelated source change'
    Assert-Rejected { Assert-WssSource $sourceFixture $preflightSource -Consumer cli } 'Unexpected CLI source path: src/Program.cs'

    $null = Fixture-Git switch --quiet -c unexpected-payload $acceptedMerge
    New-Item -ItemType Directory -Path (Join-Path $sourceFixture 'lib') | Out-Null
    'not a CLI dependency payload' | Set-Content (Join-Path $sourceFixture 'lib/unrelated.dll')
    $null = Fixture-Git add -- lib/unrelated.dll
    $null = Fixture-Git commit --quiet -m 'Unrelated payload change'
    Assert-Rejected { Assert-WssSource $sourceFixture $preflightSource -Consumer cli } 'Unexpected CLI source path: lib/unrelated.dll'

    $null = Fixture-Git switch --quiet -c unexpected-gitlink $acceptedMerge
    $null = Fixture-Git update-index --add --cacheinfo "160000,$oldPin,SubModules/unrelated"
    $null = Fixture-Git commit --quiet -m 'Unrelated gitlink change'
    Assert-Rejected { Assert-WssSource $sourceFixture $preflightSource -Consumer cli } 'Unexpected CLI source path: SubModules/unrelated'
    Remove-Item Function:Fixture-Git

    # Execute the production checkout bookkeeping and lib status boundary, not
    # an independently maintained allowlist. All Git repositories are fixtures.
    $promotionWorkflow = Get-Content "$PSScriptRoot/../../workflows/promote-wss.yml" -Raw
    function Get-PromotionStep([string] $Name) {
        $matches = [regex]::Matches($promotionWorkflow, "(?ms)^      - name: $([regex]::Escape($Name))\r?\n(?<body>.*?)(?=^      - |\z)")
        if ($matches.Count -ne 1) { throw "Expected exactly one production step: $Name" }
        $matches[0].Groups['body'].Value
    }
    $authoring = Get-PromotionStep 'Bind authoring checkout to the validated promotion base'
    if (!$authoring.Contains('uses: actions/checkout@v4') -or !$authoring.Contains('clean: false') -or
        !$authoring.Contains('ref: ${{ steps.source.outputs.sha }}') -or
        !$authoring.Contains('token: ${{ steps.integration-token.outputs.token }}')) { throw 'Authoring checkout must preserve the locked guard and exact validated source.' }
    $initialCheckout = Get-PromotionStep 'Check out current Integration dev'
    if (!$initialCheckout.Contains('ref: ${{ github.sha }}') -or $initialCheckout.Contains('clean: false') -or
        !$promotionWorkflow.Contains('ref: ${{ steps.guard.outputs.commit }}') -or !$promotionWorkflow.Contains('path: workflow-guard')) { throw 'Source and immutable guard checkout identities changed.' }
    $exclusionStep = Get-PromotionStep 'Keep the immutable guard outside the payload status scope'
    $exclusionMatch = [regex]::Match($exclusionStep, '(?ms)^        run: \|\r?\n(?<command>.*)\z')
    if (!$exclusionMatch.Success) { throw 'Guard bookkeeping command missing.' }
    $exclusionCode = $exclusionMatch.Groups['command'].Value -replace '(?m)^          ', ''
    $stageStep = Get-PromotionStep 'Validate and stage the lib-only diff'
    $stageMatch = [regex]::Match($stageStep, '(?ms)^        run: \|\r?\n(?<command>.*?)^          \. \./\.github/scripts/WssPromotion\.ps1')
    if (!$stageMatch.Success) { throw 'Production lib status/staging boundary missing.' }
    $stageCode = $stageMatch.Groups['command'].Value -replace '(?m)^          ', ''
    $fixtureRoot = Join-Path $temp 'guard checkout with spaces'
    New-Item -ItemType Directory -Path "$fixtureRoot/lib","$fixtureRoot/.github/scripts","$fixtureRoot/workflow-guard" | Out-Null
    function Guard-Git([string] $Root, [string[]] $GitArguments) {
        $result = & git -c user.name=GuardFixture -c user.email=guard@example.invalid -C $Root @GitArguments
        if ($LASTEXITCODE -ne 0) { throw "Guard fixture Git failed: $($GitArguments[0])" }
        $result
    }
    $guardRoot = Join-Path $fixtureRoot 'workflow-guard'
    $null = Guard-Git $guardRoot @('init','--quiet','-b','main')
    'locked guard' | Set-Content "$guardRoot/tracked.txt"
    $null = Guard-Git $guardRoot @('add','tracked.txt')
    $null = Guard-Git $guardRoot @('commit','--quiet','-m','Locked guard fixture')
    $guardSha = (Guard-Git $guardRoot @('rev-parse','HEAD')).Trim()
    @{source_repository='cwru-non-academic/WSSCore';source_commit=$guardSha} | ConvertTo-Json | Set-Content "$fixtureRoot/.github/scripts/wss-ci.lock.json"
    'old payload' | Set-Content "$fixtureRoot/lib/payload.txt"
    'tracked source' | Set-Content "$fixtureRoot/source.txt"
    $null = Guard-Git $fixtureRoot @('init','--quiet','-b','main')
    $null = Guard-Git $fixtureRoot @('add','lib','.github','source.txt')
    $null = Guard-Git $fixtureRoot @('commit','--quiet','-m','Validated receiver fixture')
    $sourceSha = (Guard-Git $fixtureRoot @('rev-parse','HEAD')).Trim()
    $stageFile = Join-Path $temp 'production-stage.ps1'
    $writerSentinel = Join-Path $temp 'would-enter-publisher.txt'
    $stageCode + "`n'boundary passed' | Set-Content -LiteralPath '$($writerSentinel.Replace("'","''"))'" | Set-Content $stageFile
    $savedOutput = $env:GITHUB_OUTPUT; $savedSummary = $env:GITHUB_STEP_SUMMARY
    $env:GITHUB_OUTPUT = Join-Path $temp 'guard-output'; $env:GITHUB_STEP_SUMMARY = Join-Path $temp 'guard-summary'
    function Invoke-StageFixture([bool] $Accepted) {
        Remove-Item -LiteralPath $writerSentinel -ErrorAction SilentlyContinue
        Push-Location $fixtureRoot
        try { $output = & pwsh -NoProfile -File $stageFile 2>&1; $exitCode = $LASTEXITCODE } finally { Pop-Location }
        if (($exitCode -eq 0) -ne $Accepted) { throw "Production status fixture unexpected exit $exitCode : $output" }
        if (!$Accepted -and (Test-Path $writerSentinel)) { throw 'Rejected status entered publication boundary.' }
    }
    try {
        # Preservation alone must fail on the untracked nested guard.
        Invoke-StageFixture $false
        $sourceBlob = (Guard-Git $fixtureRoot @('rev-parse','HEAD:source.txt')).Trim()
        $null = Guard-Git $fixtureRoot @('update-index','--add','--cacheinfo',"100644,$sourceBlob,workflow-guard/tracked-file")
        Push-Location $fixtureRoot
        try { Assert-Rejected { & ([scriptblock]::Create($exclusionCode)) } 'Workflow guard must not be tracked receiver payload.' } finally { Pop-Location }
        $null = Guard-Git $fixtureRoot @('reset','--quiet',$sourceSha)
        Push-Location $fixtureRoot
        try { & ([scriptblock]::Create($exclusionCode)) } finally { Pop-Location }
        $excludePath = (Guard-Git $fixtureRoot @('rev-parse','--git-path','info/exclude')).Trim()
        if (![IO.Path]::IsPathRooted($excludePath)) { $excludePath = Join-Path $fixtureRoot $excludePath }
        $customExclusions = @(Get-Content $excludePath | Where-Object { $_ -and !($_.StartsWith('#')) })
        if ($customExclusions.Count -ne 1 -or $customExclusions[0] -cne '/workflow-guard/') { throw 'Guard exclusion is not narrowly anchored.' }
        Invoke-StageFixture $true
        if ((Test-Path $writerSentinel) -or !(Get-Content $env:GITHUB_OUTPUT).Contains('no_change=true')) { throw 'Unchanged payload must exit without publication.' }
        'unrelated' | Set-Content "$fixtureRoot/unrelated.txt"
        Invoke-StageFixture $false
        Remove-Item -LiteralPath "$fixtureRoot/unrelated.txt"
        'changed source' | Set-Content "$fixtureRoot/source.txt"
        Invoke-StageFixture $false
        $null = Guard-Git $fixtureRoot @('checkout','--','source.txt')
        'new payload' | Set-Content "$fixtureRoot/lib/payload.txt"
        Invoke-StageFixture $true
        if (!(Test-Path $writerSentinel) -or (Guard-Git $fixtureRoot @('diff','--cached','--name-only')) -cne 'lib/payload.txt') { throw 'Only reviewed lib payload may be staged.' }
        $null = Guard-Git $fixtureRoot @('reset','--quiet','--hard',$sourceSha)
        if ((Guard-Git $guardRoot @('rev-parse','HEAD')) -cne $guardSha) { throw 'Preserved checkout changed the guard source.' }

        # Invoke the actual assertion-only canonical export with real Git. The
        # proof executor is fixture-only; no network, receipt CLI or writer runs.
        $authorityFile = Join-Path $temp 'guard-authority.mjs'
        @'
import {pathToFileURL} from 'node:url';
import {execFileSync} from 'node:child_process';
const [modulePath,root,guard,mode]=process.argv.slice(2);
const {mainWorkflowAuthority}=await import(pathToFileURL(modulePath));
const c={repository_root:root,target_id:'csharp-wrapper',candidate:{run_id:'123'}};
const env={WSS_CORE_TOOLS_ROOT:guard,GITHUB_REPOSITORY:'cwru-non-academic/CSharp_WSS_Integration_Lib'};
let proofs=0;
const git=(cwd,args)=>execFileSync('git',['-C',cwd,...args],{encoding:'utf8',stdio:['ignore','pipe','pipe']}).trim();
try {
  mainWorkflowAuthority(c,env,git,()=>{proofs++;return JSON.stringify({schema:'wss-receiver-workflow-authorization/v1',channel:'main',repository:env.GITHUB_REPOSITORY,target_id:mode==='bad-proof'?'wrong':c.target_id,plan_id:'a'.repeat(64),candidate:c.candidate});});
  if(mode!=='valid')throw Error('Invalid fixture passed canonical authority');
} catch(error) {
  if(mode==='valid'||error.message==='Invalid fixture passed canonical authority')throw error;
  if(proofs!==(mode==='bad-proof'?1:0))throw Error('Invalid guard executed frozen proof');
}
if(mode==='valid'&&proofs!==1)throw Error('Valid guard did not execute frozen proof');
'@ | Set-Content $authorityFile
        $modulePath = [IO.Path]::GetFullPath("$PSScriptRoot/../wss-ci/promotion.mjs")
        foreach ($mode in @('valid','bad-proof')) {
            & node $authorityFile $modulePath $fixtureRoot $guardRoot $mode
            if ($LASTEXITCODE -ne 0) { throw "Canonical guard fixture failed: $mode" }
        }
        'dirty tracked guard' | Set-Content "$guardRoot/tracked.txt"
        & node $authorityFile $modulePath $fixtureRoot $guardRoot 'dirty'
        if ($LASTEXITCODE -ne 0) { throw 'Tracked-dirty guard rejection failed.' }
        $null = Guard-Git $guardRoot @('add','tracked.txt')
        $null = Guard-Git $guardRoot @('commit','--quiet','-m','Wrong guard revision')
        & node $authorityFile $modulePath $fixtureRoot $guardRoot 'wrong-head'
        if ($LASTEXITCODE -ne 0) { throw 'Wrong guard SHA rejection failed.' }
        # Exclusion alone does not prevent checkout@v4's default -ffdx cleanup.
        $resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot)
        if (!$resolvedFixture.StartsWith([IO.Path]::GetFullPath($temp) + [IO.Path]::DirectorySeparatorChar)) { throw 'Cleanup fixture escaped its temporary root.' }
        $null = Guard-Git $resolvedFixture @('clean','-ffdx')
        if (Test-Path $guardRoot) { throw 'Default checkout cleanup did not reproduce missing guard.' }
        & node $authorityFile $modulePath $fixtureRoot $guardRoot 'missing'
        if ($LASTEXITCODE -ne 0) { throw 'Missing guard rejection failed.' }
    } finally {
        $env:GITHUB_OUTPUT=$savedOutput; $env:GITHUB_STEP_SUMMARY=$savedSummary
        Remove-Item Function:Guard-Git,Function:Get-PromotionStep,Function:Invoke-StageFixture
        $global:LASTEXITCODE=0
    }
    $count++

    # Metadata-only fakes: no candidate binaries, workflow dispatches or PRs are created.
    function Invoke-WssGh([string[]] $Arguments) {
        if ($Arguments[1] -like '*/pulls/*') {
            @{ merged=$script:merged; merge_commit_sha=$script:mergeSha; base=@{ref='dev';repo=@{full_name='cwru-non-academic/CSharp_WSS_Integration_Lib'}};
                head=@{sha='1'*40;ref='automation/wss-test';repo=@{full_name='cwru-non-academic/CSharp_WSS_Integration_Lib'}} } | ConvertTo-Json -Depth 5
        } elseif ($Arguments[1] -like '*/compare/*') {
            @{status=$script:comparison} | ConvertTo-Json
        } elseif ($Arguments[-1] -like '*/workflows/wss-compatibility.yml/runs?*') {
            ConvertTo-Json -InputObject @(@{workflow_runs=$script:normalRuns}) -Depth 8
        } elseif ($Arguments[-1] -like '*/actions/runs/*/jobs?*') {
            ConvertTo-Json -InputObject @(@{jobs=$script:normalJobs}) -Depth 5
        } elseif ($Arguments[1] -like '*/contents/lib/wss-candidate.json?*') {
            @{content=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($approval | ConvertTo-Json -Depth 5)))} | ConvertTo-Json
        } else { throw 'Unexpected API call in rejection test.' }
    }
    $script:merged = $false
    $script:mergeSha = '2'*40
    Assert-Rejected { Assert-WssMergedIntegration $script:mergeSha '1' $approval } 'Gitlink must target*'
    $script:merged = $true
    Assert-Rejected { Assert-WssMergedIntegration ('3'*40) '1' $approval } 'Gitlink must target*'
    $script:comparison = 'diverged'
    Assert-Rejected { Assert-WssMergedIntegration $script:mergeSha '1' $approval } 'Integration merge is not contained*'
    # GitHub may omit PR associations after merge; exact run identity remains required.
    $script:comparison = 'identical'
    $normalRun = [pscustomobject]@{
        id=10; repository=@{full_name='cwru-non-academic/CSharp_WSS_Integration_Lib'}
        head_repository=@{full_name='cwru-non-academic/CSharp_WSS_Integration_Lib'}
        path='.github/workflows/wss-compatibility.yml'; event='pull_request'
        head_sha='1'*40; head_branch='automation/wss-test'
        status='completed'; conclusion='success'; pull_requests=@()
    }
    $script:normalRuns = @($normalRun)
    $script:normalJobs = @('Integration behavioral tests', 'Integration compatibility (Windows)',
        'Integration compatibility (Ubuntu)', 'Integration compatibility (macOS)') | ForEach-Object {
        [pscustomobject]@{name=$_;conclusion='success'}
    }
    $validated = Assert-WssMergedIntegration $script:mergeSha '1' $approval
    if ($validated.head.sha -cne ('1'*40)) { throw 'Merged PR final head changed.' }
    $count++
    foreach ($field in @('head_sha', 'head_branch', 'event', 'path', 'repository', 'head_repository', 'pull_requests')) {
        $bad = $normalRun | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        if ($field -in @('repository', 'head_repository')) { $bad.$field.full_name = 'other/repository' }
        elseif ($field -ceq 'pull_requests') { $bad.pull_requests = @(@{number=2}) }
        else { $bad.$field = 'wrong' }
        $script:normalRuns = @($bad)
        Assert-Rejected { Assert-WssMergedIntegration $script:mergeSha '1' $approval } 'Merged Integration PR lacks successful latest*'
    }
    $mixed = $normalRun | ConvertTo-Json -Depth 5 | ConvertFrom-Json
    $mixed.pull_requests = @(@{number=1}, @{number=2})
    $script:normalRuns = @($mixed)
    Assert-Rejected { Assert-WssMergedIntegration $script:mergeSha '1' $approval } 'Merged Integration PR lacks successful latest*'
    $normalRun.pull_requests = @(@{number=1})
    $script:normalRuns = @($normalRun)
    $null = Assert-WssMergedIntegration $script:mergeSha '1' $approval
    $count++
    $normalRun.pull_requests = @()
    foreach ($state in @('in_progress', 'completed')) {
        $latest = $normalRun | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        $latest.id = 11; $latest.status = $state; $latest.conclusion = 'failure'
        $script:normalRuns = @($normalRun, $latest)
        Assert-Rejected { Assert-WssMergedIntegration $script:mergeSha '1' $approval } 'Merged Integration PR lacks successful latest*'
    }
    $script:normalRuns = @($normalRun)
    $script:normalJobs[0].conclusion = 'failure'
    Assert-Rejected { Assert-WssMergedIntegration $script:mergeSha '1' $approval } 'Required normal Integration CI job did not succeed*'
    Remove-Item Function:Invoke-WssGh
    . "$PSScriptRoot/../WssPromotion.ps1"

    # Automatic handoff contracts: fake only the GitHub transport, never dispatch remotely.
    . "$PSScriptRoot/../WssAutomatic.ps1"
    $producer = [pscustomobject]@{ repository=@{full_name='cwru-non-academic/WSSCore'}; head_repository=@{full_name='cwru-non-academic/WSSCore'}; path='.github/workflows/artifacts.yml'; event='push'; head_branch='dev'; head_sha=$approval.candidate.commit }
    Assert-WssAutomaticProducer $producer $approval.candidate.commit
    $badProducer=$producer | ConvertTo-Json -Depth 5 | ConvertFrom-Json
    $badProducer.head_repository.full_name='fork/repo'
    Assert-Rejected { Assert-WssAutomaticProducer $badProducer $approval.candidate.commit } 'Automatic promotion requires*'
    foreach ($field in @('event', 'head_branch', 'head_sha')) {
        $bad = $producer | ConvertTo-Json | ConvertFrom-Json
        $bad.$field = 'untrusted'
        Assert-Rejected { Assert-WssAutomaticProducer $bad $approval.candidate.commit } 'Automatic promotion requires*'
    }
    # Shared Node contracts own request serialization, ambiguity, source races,
    # failed-run selection and uncertain POST behavior. Check this adapter's
    # candidate/source binding without replacing or invoking the real network.
    $script:adapterRequests=@();$script:adapterWaitFailure=$false
    function Start-WssCiPreflight([string]$Repository,$Candidate,[string]$WrapperSha,[string]$CorrelationId,[int]$DiscoverySeconds,[string]$DispatchToken) {
        $script:adapterRequests+=@{repository=$Repository;candidate=$Candidate;wrapper_sha=$WrapperSha;correlation=$CorrelationId;token=$DispatchToken}
        $sha=if($Repository -like '*/CLI_*'){'4'*40}else{'3'*40}
        [pscustomobject]@{id=$(if($Repository -like '*/CLI_*'){'42'}else{'41'});head_sha=$sha;status='completed';conclusion='success'}
    }
    function Wait-WssCiRun($Repository,$RunId,$SourceSha,$Workflow,$Event,$TimeoutSeconds) {
        if($script:adapterWaitFailure){throw 'Shared fixture required run failed.'}
        $expected=if($Repository -like '*/CLI_*'){'4'*40}else{'3'*40}
        if($SourceSha -cne $expected -or $Workflow -cne 'wss-preflight.yml' -or $Event -cne 'workflow_dispatch'){throw 'Adapter changed the exact expected run identity.'}
        [pscustomobject]@{id=$RunId;head_sha=$SourceSha;status='completed';conclusion='success'}
    }
    $automatic=New-WssAutomaticApproval $approval.candidate 'wss-test-candidate'
    if($script:adapterRequests.Count -ne 2 -or $automatic.integration.source_sha -cne ('3'*40) -or $automatic.cli.source_sha -cne ('4'*40)){throw 'Automatic adapter source binding failed.'}
    if($script:adapterRequests[1].wrapper_sha -cne $automatic.integration.source_sha){throw 'CLI adapter lost the exact integration source.'}
    foreach($request in $script:adapterRequests){
        if($request.candidate.run_id -cne $approval.candidate.run_id -or $request.candidate.sha256 -cne $approval.candidate.sha256 -or $request.correlation -cne 'wss-test-candidate'){throw 'Adapter mixed immutable candidate inputs.'}
    }
    $count++
    $script:adapterWaitFailure=$true
    Assert-Rejected {New-WssAutomaticApproval $approval.candidate 'wss-test-candidate'} 'Shared fixture required run failed*'
    $script:adapterWaitFailure=$false
    $before=$script:adapterRequests.Count
    Assert-Rejected {Start-WssCorrelatedPreflight 'foreign/repository' $approval.candidate 'wss-foreign'} 'Unknown C# preflight repository*'
    if($script:adapterRequests.Count -ne $before){throw 'Unknown repository reached the shared boundary.'}
    $secondCandidate=$approval.candidate|ConvertTo-Json|ConvertFrom-Json
    $secondCandidate.run_id='99';$secondCandidate.artifact_id='100';$secondCandidate.commit='7'*40;$secondCandidate.sha256='8'*64
    $second=New-WssAutomaticApproval $secondCandidate 'wss-second-candidate'
    foreach($request in @($script:adapterRequests[-2],$script:adapterRequests[-1])){
        if($request.candidate.run_id -cne '99' -or $request.candidate.sha256 -cne ('8'*64) -or $request.candidate.commit -cne ('7'*40)){throw 'Nearby candidates mixed adapter data.'}
    }
    Assert-WssCandidateRecord $secondCandidate $second
    $count++
    Remove-Item Function:Start-WssCiPreflight,Function:Wait-WssCiRun
    . "$PSScriptRoot/../WssAutomatic.ps1"
    # A green but mismatched preflight and expired producer artifact are not authority.
    $script:expiredArtifact = $false
    function Invoke-WssGh([string[]] $Arguments) {
        $c = $approval.candidate
        if ($Arguments[0] -ceq 'run') {
            $destination = $Arguments[-1]
            New-Item -ItemType Directory -Path $destination | Out-Null
            $wrong = $c | ConvertTo-Json | ConvertFrom-Json
            $wrong.sha256 = '0'*64
            $wrong | ConvertTo-Json | Set-Content (Join-Path $destination 'candidate.json')
            return
        }
        if ($Arguments[1] -like '*/actions/artifacts/*') {
            return (@{name='universal-release-assets';expired=$script:expiredArtifact;workflow_run=@{id=$c.run_id;head_sha=$c.commit}} | ConvertTo-Json)
        }
        $repo = if ($Arguments[1] -like '*/WSSCore/*') { $c.repository } else { 'cwru-non-academic/CSharp_WSS_Integration_Lib' }
        $isProducer = $repo -ceq $c.repository
        return (@{repository=@{full_name=$repo};path=$(if ($isProducer) { '.github/workflows/artifacts.yml' } else { '.github/workflows/wss-preflight.yml' });
            head_sha=$(if ($isProducer) { $c.commit } else { $approval.integration.source_sha });status='completed';conclusion='success';
            event=$(if ($isProducer) { 'push' } else { 'workflow_dispatch' })} | ConvertTo-Json)
    }
    Assert-Rejected { Assert-WssApproval $approval (Join-Path $temp 'wrong-preflight-evidence') } 'Candidate provenance mismatch: sha256'
    $script:expiredArtifact = $true
    Assert-Rejected { Assert-WssApproval $approval (Join-Path $temp 'expired-evidence') } 'Artifact ID is not the approved producer artifact*'
    Remove-Item Function:Invoke-WssGh
    . "$PSScriptRoot/../WssAutomatic.ps1"

    # Payload-only no-op detection, independent of promotion metadata. Not runtime DLL fakes.
    . "$PSScriptRoot/../Universal-WssFiles.ps1"
    $payload = Join-Path $temp 'payload'
    $lib = Join-Path $temp 'lib'
    foreach ($root in @($payload, $lib)) {
        foreach ($relative in $WssUniversalFiles) {
            $path = Join-Path $root $relative
            New-Item -ItemType Directory -Path (Split-Path $path) -Force | Out-Null
            'test payload bytes' | Set-Content -LiteralPath $path
        }
    }
    Write-WssApproval $approval (Join-Path $lib 'wss-candidate.json')
    if (-not (Test-WssPayloadEqual $lib $payload)) { throw 'Identical payload with old approval did not produce a no-op.' }
    'different payload bytes' | Set-Content (Join-Path $payload 'WSS_Core_Interface.dll')
    if (Test-WssPayloadEqual $lib $payload) { throw 'Different universal candidate was treated as a no-op.' }
    Copy-Item (Join-Path $lib 'WSS_Core_Interface.dll') (Join-Path $payload 'WSS_Core_Interface.dll') -Force
    'stale' | Set-Content (Join-Path $lib 'obsolete.dll')
    if (Test-WssPayloadEqual $lib $payload) { throw 'Incomplete/extra committed dependencies were treated as a no-op.' }
    $count++

    # Exercise the actual late workflow command with metadata-only API stubs.
    # These checks authorize no token, remote request or runtime acceptance.
    $workflow = Get-Content "$PSScriptRoot/../../workflows/dispatch-cli-promotion.yml" -Raw
    $stepName = 'Recheck integration barrier immediately before CLI writes'
    $step = [regex]::Match($workflow, "(?ms)^      - name: $stepName\r?\n(?<body>.*?)(?=^      - )")
    $validateAt = $workflow.IndexOf('name: Validate promotion metadata')
    $checkAt = $workflow.IndexOf("name: $stepName")
    $tokenAt = $workflow.IndexOf('name: Create CLI Actions token')
    $postAt = $workflow.IndexOf('name: Dispatch CLI promotion workflow')
    if (!$step.Success -or $validateAt -lt 0 -or $checkAt -le $validateAt -or $tokenAt -le $checkAt -or $postAt -le $tokenAt -or
        !$step.Groups['body'].Value.Contains("if: github.event_name == 'workflow_dispatch' && steps.intent.outputs.dispatch_needed == 'true'")) {
        throw 'The staged recheck must gate write credentials after metadata validation, preserving the legacy path.'
    }
    $command = [regex]::Match($step.Groups['body'].Value, '(?m)^        run: (?<command>.+)\r?$')
    if (!$command.Success) { throw 'Late barrier command missing.' }
    $lateCheck = [scriptblock]::Create($command.Groups['command'].Value)
    $savedEnvironment = @{}
    foreach ($key in @('GITHUB_ACTIONS','GITHUB_REPOSITORY','GITHUB_EVENT_NAME','GITHUB_REF','PRODUCER_RUN_ID','BARRIER_RUN_ID','BARRIER_ATTEMPT','EXPECTED_MERGE_SHA','GITHUB_OUTPUT','RUNNER_TEMP')) {
        $savedEnvironment[$key] = [Environment]::GetEnvironmentVariable($key)
    }
    $global:wssTestlateMain = 'a'*40; $global:wssTestlateInvalid = $false; $global:wssTestlateDenied = $false
    $global:wssTestlateCalls = 0; $global:wssTestlateWrites = 0
    function gh {
        $global:LASTEXITCODE = 0
        if ('POST' -cin $args) { $global:wssTestlateWrites++; throw 'Metadata fixture must never write.' }
        if ($global:wssTestlateDenied) { $global:LASTEXITCODE = 1; return '{}' }
        switch ($args[-1]) {
            'repos/cwru-non-academic/WSSCore/git/ref/heads/main' { @{object=@{sha=$global:wssTestlateMain}} | ConvertTo-Json -Depth 4 }
            'repos/cwru-non-academic/CSharp_WSS_Integration_Lib/pulls/40' {
                @{merged=$true;state='closed';merge_commit_sha=('b'*40);user=@{type='Bot'};
                    base=@{ref='dev';repo=@{full_name=$env:GITHUB_REPOSITORY}};
                    head=@{repo=@{full_name=$env:GITHUB_REPOSITORY}}} | ConvertTo-Json -Depth 6
            }
            default { throw "Unexpected late-check read: $($args[-1])" }
        }
    }
    function git { $global:LASTEXITCODE = 0; $global:wssTestlateMain }
    function Get-LateBarrierNativeNode {
        $nativeNodePath=@(& node --print process.execPath)
        if($LASTEXITCODE -ne 0 -or $nativeNodePath.Count -ne 1 -or $nativeNodePath[0] -isnot [string] -or
           ![IO.Path]::IsPathFullyQualified($nativeNodePath[0]) -or !(Test-Path -LiteralPath $nativeNodePath[0] -PathType Leaf)){
            throw 'Late-barrier fixture requires one successfully resolved absolute Node executable.'
        }
        $nativeNodePath[0]
    }
    $baseNode=Get-LateBarrierNativeNode
    $nodeAliases=@((Join-Path ([IO.Path]::GetTempPath()) ('wss first Node path '+[guid]::NewGuid())),(Join-Path ([IO.Path]::GetTempPath()) ('wss second Node path '+[guid]::NewGuid())))
    $originalNodeSearchPath=$env:PATH
    try {
        foreach($alias in $nodeAliases){
            $kind=if($IsWindows){'Junction'}else{'SymbolicLink'}
            New-Item -ItemType $kind -Path $alias -Target (Split-Path -Parent $baseNode)|Out-Null
        }
        $env:PATH=($nodeAliases -join [IO.Path]::PathSeparator)+[IO.Path]::PathSeparator+$originalNodeSearchPath
        if(@(Get-Command node -CommandType Application -All).Count -lt 2){throw 'Duplicate-PATH regression did not expose multiple Node applications.'}
        $duplicatePathNode=Get-LateBarrierNativeNode
        $literalArguments=@('path with spaces','a;b','$(literal)')
        $probe=@(& $duplicatePathNode -e 'process.stdout.write(JSON.stringify(process.argv.slice(1)))' -- @literalArguments)
        if($LASTEXITCODE -ne 0 -or $probe.Count -ne 1){throw 'Duplicate-PATH Node executable did not run exactly once successfully.'}
        $receivedArguments=@($probe[0]|ConvertFrom-Json)
        if($receivedArguments.Count -ne $literalArguments.Count -or @(Compare-Object $literalArguments $receivedArguments -CaseSensitive -SyncWindow 0).Count){throw 'Duplicate-PATH invocation changed literal arguments.'}
    } finally {
        $env:PATH=$originalNodeSearchPath
        foreach($alias in $nodeAliases){if(Test-Path -LiteralPath $alias){Remove-Item -LiteralPath $alias -Force}}
    }
    $global:wssTestlateRealNode=Get-LateBarrierNativeNode
    function node {
        if($args[0] -cmatch '(channels|staging)\.mjs$'){ & $global:wssTestlateRealNode @args;return }
        $global:wssTestlateCalls++
        if (($args[1..4] -join ',') -cne 'verify-barrier,123,456,1') { throw 'Late check changed exact correlation inputs.' }
        $global:LASTEXITCODE = if ($global:wssTestlateInvalid) { 1 } else { 0 }
        @{integrations=@{csharp=@{repository=$env:GITHUB_REPOSITORY;pr_number='40';head_sha=('b'*40)}}} | ConvertTo-Json -Depth 6
    }
    Push-Location "$PSScriptRoot/../../.."
    try {
        $env:GITHUB_ACTIONS='true'; $env:GITHUB_REPOSITORY='cwru-non-academic/CSharp_WSS_Integration_Lib'
        $env:GITHUB_EVENT_NAME='workflow_dispatch'; $env:GITHUB_REF='refs/heads/main'
        $env:PRODUCER_RUN_ID='123'; $env:BARRIER_RUN_ID='456'; $env:BARRIER_ATTEMPT='1'
        $env:EXPECTED_MERGE_SHA='b'*40
        $env:GITHUB_OUTPUT=Join-Path $temp 'late-output'; $env:RUNNER_TEMP=Join-Path $temp 'late-valid'
        $null = & $lateCheck
        if (!(Test-Path (Join-Path $env:RUNNER_TEMP 'cli-stage-recheck/fanout-event.json'))) { throw 'Valid late barrier did not retain the authorized merge event.' }
        $env:EXPECTED_MERGE_SHA='c'*40; $env:RUNNER_TEMP=Join-Path $temp 'late-replaced-merge'
        Assert-Rejected { & $lateCheck } 'Shared barrier integration changed*'
        $env:EXPECTED_MERGE_SHA='b'*40
        $global:wssTestlateInvalid=$true; $env:RUNNER_TEMP=Join-Path $temp 'late-moved'
        Assert-Rejected { & $lateCheck } 'Trusted Core integration barrier verification failed*'
        if (Test-Path (Join-Path $env:RUNNER_TEMP 'cli-stage-recheck/fanout-event.json')) { throw 'A moved barrier emitted a dispatch event.' }
        $global:wssTestlateInvalid=$false; $global:wssTestlateDenied=$true
        Assert-Rejected { & $lateCheck } 'Read-only GitHub lookup failed*'
        if ($global:wssTestlateCalls -ne 3 -or $global:wssTestlateWrites -ne 0) { throw 'Rejection retried the verifier or attempted a write.' }
    } finally {
        Pop-Location
        Remove-Item Function:gh, Function:git, Function:node
        foreach ($key in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($key,$savedEnvironment[$key]) }
        $global:LASTEXITCODE=0
    }
    $count++

    if ($ArtifactRoot) {
        Write-WssApproval $approval (Join-Path $temp 'approval.json')
        & "$PSScriptRoot/../New-WssLib.ps1" -ArtifactRoot $ArtifactRoot -ApprovalFile (Join-Path $temp 'approval.json') -Destination (Join-Path $temp 'first')
        & "$PSScriptRoot/../New-WssLib.ps1" -ArtifactRoot $ArtifactRoot -ApprovalFile (Join-Path $temp 'approval.json') -Destination (Join-Path $temp 'second')
        & git diff --no-index --quiet -- (Join-Path $temp 'first') (Join-Path $temp 'second')
        if ($LASTEXITCODE -ne 0) { throw 'Universal staging is not deterministic.' }
        Assert-Rejected { & "$PSScriptRoot/../New-WssLib.ps1" -ArtifactRoot $ArtifactRoot -ApprovalFile (Join-Path $temp 'approval.json') -Destination (Join-Path $temp 'first') } 'Destination must be new*'
        'wrong' | Set-Content (Join-Path $temp 'first/WSS.Transport.Serial.dll')
        Assert-Rejected { Assert-WssLib (Join-Path $temp 'first') $ArtifactRoot $approval } 'Committed universal bytes differ*'
        $count++
    }
    "PASS: $count focused promotion safety checks (ArtifactRoot supplied: $([bool]$ArtifactRoot))."
} finally { Remove-Item -LiteralPath $temp -Recurse -Force }
