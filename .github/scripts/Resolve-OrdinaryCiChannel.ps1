[CmdletBinding()]
param()

# Ordinary CI only. Candidate/preflight channels remain owned by their frozen plan.
# The production entrypoint takes no channel, repository, source or event override.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Do not coerce JSON identities or use collection comparisons as schema validation.
function Test-WssOrdinaryString($Value) {
    $Value -is [string] -and ![string]::IsNullOrWhiteSpace($Value)
}
function Test-WssOrdinaryInteger($Value) {
    ($Value -is [int] -or $Value -is [long]) -and $Value -gt 0
}
function Test-WssOrdinaryEmptyContext($Value) {
    $null -eq $Value -or ($Value -is [string] -and $Value.Length -eq 0)
}

function Resolve-WssOrdinaryCiChannel([Collections.IDictionary]$Runtime, [Collections.IDictionary]$Event) {
    $registered = @{
        'cwru-non-academic/CSharp_WSS_Integration_Lib' = @{ id = '1092676331'; workflow = 'wss-compatibility.yml' }
        'cwru-non-academic/CLI_CSharp_WSS_Application' = @{ id = '1207505563'; workflow = 'cli-ci.yml' }
    }
    $repository = $Runtime['GITHUB_REPOSITORY']
    if (!(Test-WssOrdinaryString $Runtime['GITHUB_ACTIONS']) -or !(Test-WssOrdinaryString $repository) -or
        $Runtime['GITHUB_ACTIONS'] -cne 'true' -or $repository -cnotin @($registered.Keys)) {
        throw 'Ordinary CI requires its registered GitHub repository runtime.'
    }
    $identity = $registered[$repository]
    $eventRepository = $Event['repository']
    if (!(Test-WssOrdinaryString $Runtime['GITHUB_REPOSITORY_ID']) -or $Runtime['GITHUB_REPOSITORY_ID'] -cne $identity.id -or
        $eventRepository -isnot [Collections.IDictionary] -or !(Test-WssOrdinaryString $eventRepository['full_name']) -or
        !(Test-WssOrdinaryInteger $eventRepository['id']) -or
        $eventRepository['full_name'] -cne $repository -or $eventRepository['id'] -ne [long]$identity.id) {
        throw 'Ordinary CI repository identities disagree.'
    }
    $source = $Runtime['GITHUB_SHA']
    $ref = $Runtime['GITHUB_REF']
    if (!(Test-WssOrdinaryString $source) -or !(Test-WssOrdinaryString $ref) -or
        !(Test-WssOrdinaryString $Runtime['GITHUB_WORKFLOW_SHA']) -or !(Test-WssOrdinaryString $Runtime['GITHUB_WORKFLOW_REF']) -or
        $source -cnotmatch '\A[a-f0-9]{40}\z' -or $Runtime['GITHUB_WORKFLOW_SHA'] -cne $source -or
        $Runtime['GITHUB_WORKFLOW_REF'] -cne "$repository/.github/workflows/$($identity.workflow)@$ref") {
        throw 'Ordinary CI workflow and execution source identities disagree.'
    }
    if (!(Test-WssOrdinaryString $Runtime['GITHUB_REF_TYPE']) -or $Runtime['GITHUB_REF_TYPE'] -cne 'branch') {
        throw 'Ordinary CI requires a branch reference.'
    }
    $eventName = $Runtime['GITHUB_EVENT_NAME']
    if (!(Test-WssOrdinaryString $eventName)) { throw 'Unsupported ordinary CI event.' }
    if ($eventName -ceq 'pull_request') {
        $pr = $Event['pull_request']
        if ($pr -isnot [Collections.IDictionary] -or $pr['base'] -isnot [Collections.IDictionary] -or
            $pr['head'] -isnot [Collections.IDictionary] -or $pr['base']['repo'] -isnot [Collections.IDictionary]) {
            throw 'Ordinary CI requires a complete pull request identity.'
        }
        if (!(Test-WssOrdinaryInteger $Event['number']) -or !(Test-WssOrdinaryInteger $pr['number']) -or
            !$pr.Contains('merge_commit_sha') -or
            ($null -ne $pr['merge_commit_sha'] -and !(Test-WssOrdinaryString $pr['merge_commit_sha'])) -or
            !(Test-WssOrdinaryString $pr['state']) -or
            !(Test-WssOrdinaryString $Event['action']) -or !(Test-WssOrdinaryString $Runtime['GITHUB_REF_NAME'])) {
            throw 'Ordinary CI requires the current open pull request merge source.'
        }
        $number = [string]$Event['number']
        if ($pr['number'] -ne $Event['number'] -or
            $ref -cne "refs/pull/$number/merge" -or $Runtime['GITHUB_REF_NAME'] -cne "$number/merge" -or
            ($null -ne $pr['merge_commit_sha'] -and $pr['merge_commit_sha'] -cne $source) -or $pr['state'] -cne 'open' -or
            $pr['merged'] -isnot [bool] -or $pr['merged'] -or
            $Event['action'] -cnotin @('opened', 'reopened', 'synchronize')) {
            throw 'Ordinary CI requires the current open pull request merge source.'
        }
        $base = $pr['base']
        $head = $pr['head']
        $channel = $base['ref']
        if (!(Test-WssOrdinaryString $channel) -or !(Test-WssOrdinaryString $Runtime['GITHUB_BASE_REF']) -or
            !(Test-WssOrdinaryString $Runtime['GITHUB_HEAD_REF']) -or !(Test-WssOrdinaryString $base['repo']['full_name']) -or
            !(Test-WssOrdinaryInteger $base['repo']['id']) -or !(Test-WssOrdinaryString $base['sha']) -or
            !(Test-WssOrdinaryString $head['sha']) -or !(Test-WssOrdinaryString $head['ref']) -or
            $channel -cnotin @('dev', 'main') -or $Runtime['GITHUB_BASE_REF'] -cne $channel -or
            $base['repo']['full_name'] -cne $repository -or $base['repo']['id'] -ne [long]$identity.id -or
            $base['sha'] -cnotmatch '\A[a-f0-9]{40}\z' -or $head['sha'] -cnotmatch '\A[a-f0-9]{40}\z' -or
            $Runtime['GITHUB_HEAD_REF'] -cne $head['ref']) {
            throw 'Ordinary CI pull request base and source identities disagree.'
        }
    } elseif ($eventName -cin @('push', 'workflow_dispatch')) {
        if ($ref -cnotin @('refs/heads/dev', 'refs/heads/main')) {
            throw 'Ordinary CI requires an exact dev or main branch reference.'
        }
        $channel = $ref.Substring('refs/heads/'.Length)
        if (!(Test-WssOrdinaryString $Runtime['GITHUB_REF_NAME']) -or $Runtime['GITHUB_REF_NAME'] -cne $channel -or
            !(Test-WssOrdinaryEmptyContext $Runtime['GITHUB_BASE_REF']) -or !(Test-WssOrdinaryEmptyContext $Runtime['GITHUB_HEAD_REF']) -or
            $Event.Contains('pull_request')) { throw 'Ordinary CI branch and pull request contexts conflict.' }
        if ($eventName -ceq 'push') {
            # Covered as a helper contract. Registered ordinary workflows do not add a push trigger.
            $headCommit = $Event['head_commit']
            if (!(Test-WssOrdinaryString $Event['ref']) -or !(Test-WssOrdinaryString $Event['after']) -or
                $headCommit -isnot [Collections.IDictionary] -or !(Test-WssOrdinaryString $headCommit['id']) -or
                $Event['ref'] -cne $ref -or $Event['after'] -cne $source -or $headCommit['id'] -cne $source -or
                $Event['deleted'] -isnot [bool] -or $Event['deleted']) {
                throw 'Ordinary CI push source identities disagree.'
            }
        } else {
            # No caller-defined inputs exist in either registered ordinary workflow.
            # get_Count() avoids treating a JSON object's "Count" key as its size.
            $inputs = $Event['inputs']
            if (!(Test-WssOrdinaryString $Event['ref']) -or $Event['ref'] -cnotin @($channel, $ref) -or
                ($null -ne $inputs -and ($inputs -isnot [Collections.IDictionary] -or $inputs.get_Count() -ne 0))) {
                throw 'Ordinary CI dispatch must use its registered branch without caller inputs.'
            }
        }
    } else { throw 'Unsupported ordinary CI event.' }
    [pscustomobject]@{ channel = $channel; repository = $repository; workflow = $identity.workflow; source = $source; ref = $ref }
}

# Diagnostic labels are fixed and values are never serialized. This helper has
# no authority role and runs only after the unchanged resolver has rejected.
function Get-WssOrdinaryPrDiagnostics([Collections.IDictionary]$Runtime, [Collections.IDictionary]$Event) {
    $pr = if ($Event['pull_request'] -is [Collections.IDictionary]) { $Event['pull_request'] } else { @{} }
    $number = if (Test-WssOrdinaryInteger $Event['number']) { [string]$Event['number'] } else { '' }
    $checks = @(
        @{ field = 'event.pull_request'; parent = $Event; key = 'pull_request'; valid = ($Event['pull_request'] -is [Collections.IDictionary]) },
        @{ field = 'event.number'; parent = $Event; key = 'number'; valid = (Test-WssOrdinaryInteger $Event['number']) },
        @{ field = 'event.pull_request.number'; parent = $pr; key = 'number'; valid = ((Test-WssOrdinaryInteger $Event['number']) -and (Test-WssOrdinaryInteger $pr['number']) -and $pr['number'] -eq $Event['number']) },
        @{ field = 'runtime.GITHUB_REF'; parent = $Runtime; key = 'GITHUB_REF'; valid = ((Test-WssOrdinaryString $Runtime['GITHUB_REF']) -and $Runtime['GITHUB_REF'] -ceq "refs/pull/$number/merge") },
        @{ field = 'runtime.GITHUB_REF_NAME'; parent = $Runtime; key = 'GITHUB_REF_NAME'; valid = ((Test-WssOrdinaryString $Runtime['GITHUB_REF_NAME']) -and $Runtime['GITHUB_REF_NAME'] -ceq "$number/merge") },
        @{ field = 'event.pull_request.merge_commit_sha'; parent = $pr; key = 'merge_commit_sha'; valid = ($pr.Contains('merge_commit_sha') -and ($null -eq $pr['merge_commit_sha'] -or ((Test-WssOrdinaryString $Runtime['GITHUB_SHA']) -and (Test-WssOrdinaryString $pr['merge_commit_sha']) -and $pr['merge_commit_sha'] -ceq $Runtime['GITHUB_SHA']))) },
        @{ field = 'event.pull_request.state'; parent = $pr; key = 'state'; valid = ((Test-WssOrdinaryString $pr['state']) -and $pr['state'] -ceq 'open') },
        @{ field = 'event.pull_request.merged'; parent = $pr; key = 'merged'; valid = ($pr['merged'] -is [bool] -and !$pr['merged']) },
        @{ field = 'event.action'; parent = $Event; key = 'action'; valid = ((Test-WssOrdinaryString $Event['action']) -and $Event['action'] -cin @('opened', 'reopened', 'synchronize')) }
    )
    foreach ($check in $checks) {
        if ($check.valid) { continue }
        $present = $check.parent.Contains($check.key)
        $value = $check.parent[$check.key]
        $type = if (!$present) { 'missing' } elseif ($null -eq $value) { 'null' }
            elseif ($value -is [string]) { 'string' } elseif ($value -is [bool]) { 'boolean' }
            elseif ($value -is [Collections.IDictionary]) { 'object' } elseif ($value -is [array]) { 'array' }
            elseif ($value -is [ValueType]) { 'number' } else { 'other' }
        "Ordinary CI rejected field=$($check.field) present=$present type=$type."
    }
}

# Opened webhooks may precede GitHub's mergeability computation, leaving
# merge_commit_sha null. The raw checked-out commit, not that nullable hint,
# proves the exact authenticated base/head pair. Raw headers work at depth 1.
function Assert-WssOrdinaryPullRequestMerge([string]$Root, [string]$Source, [string]$Base, [string]$Head) {
    $raw = & git --no-replace-objects --no-optional-locks -C $Root cat-file commit $Source 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Ordinary CI cannot read its raw pull request commit.' }
    $header = (($raw -join "`n") -split "`n`n", 2)[0]
    $parents = @($header -split "`n" | Where-Object { $_ -clike 'parent *' })
    if ($parents.Count -ne 2 -or $parents[0] -cne "parent $Base" -or $parents[1] -cne "parent $Head") {
        throw 'Ordinary CI raw merge parents differ from the event base/head sources.'
    }
}

function Initialize-WssOrdinaryCiChannel {
    [CmdletBinding()]
    param()
    $runtime = @{}
    foreach ($name in @('GITHUB_ACTIONS', 'GITHUB_REPOSITORY', 'GITHUB_REPOSITORY_ID', 'GITHUB_SHA',
        'GITHUB_WORKFLOW_SHA', 'GITHUB_WORKFLOW_REF', 'GITHUB_REF', 'GITHUB_REF_TYPE', 'GITHUB_REF_NAME',
        'GITHUB_EVENT_NAME', 'GITHUB_BASE_REF', 'GITHUB_HEAD_REF')) {
        $runtime[$name] = [Environment]::GetEnvironmentVariable($name)
    }
    if (!$env:GITHUB_EVENT_PATH -or !$env:GITHUB_OUTPUT) { throw 'Ordinary CI requires runner event and output files.' }
    $event = Get-Content -LiteralPath $env:GITHUB_EVENT_PATH -Raw | ConvertFrom-Json -AsHashtable -NoEnumerate
    if ($event -isnot [Collections.IDictionary]) { throw 'Ordinary CI requires a JSON event object.' }
    try { $resolved = Resolve-WssOrdinaryCiChannel $runtime $event } catch {
        if ($runtime['GITHUB_EVENT_NAME'] -ceq 'pull_request') {
            Get-WssOrdinaryPrDiagnostics $runtime $event | ForEach-Object { Write-Host $_ }
        }
        throw
    }
    $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $head = & git --no-optional-locks -C $root rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or ($head -join '').Trim() -cne $resolved.source) {
        throw 'Ordinary CI checkout differs from the event source.'
    }
    $remote = & git --no-optional-locks -C $root remote get-url origin
    if ($LASTEXITCODE -ne 0 -or (($remote -join '').Trim().TrimEnd('/') -creplace '\.git$', '') -cne "https://github.com/$($resolved.repository)") {
        throw 'Ordinary CI checkout repository differs from the registered source.'
    }
    if ($runtime['GITHUB_EVENT_NAME'] -ceq 'pull_request') {
        Assert-WssOrdinaryPullRequestMerge $root $resolved.source $event['pull_request']['base']['sha'] $event['pull_request']['head']['sha']
    }
    # Channel is emitted only after hosted metadata, checkout and raw PR parents agree.
    "channel=$($resolved.channel)" >> $env:GITHUB_OUTPUT
    "Verified ordinary $($resolved.channel) source $($resolved.source) for $($resolved.repository)."
}

if ($MyInvocation.InvocationName -cne '.') { Initialize-WssOrdinaryCiChannel }
