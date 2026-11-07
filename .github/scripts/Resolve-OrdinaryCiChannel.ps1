[CmdletBinding()]
param()

# Ordinary CI only. Candidate/preflight channels remain owned by their frozen plan.
# The production entrypoint takes no channel, repository, source or event override.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-WssOrdinaryCiChannel([Collections.IDictionary]$Runtime, [Collections.IDictionary]$Event) {
    $registered = @{
        'cwru-non-academic/CSharp_WSS_Integration_Lib' = @{ id = '1092676331'; workflow = 'wss-compatibility.yml' }
        'cwru-non-academic/CLI_CSharp_WSS_Application' = @{ id = '1207505563'; workflow = 'cli-ci.yml' }
    }
    $repository = $Runtime['GITHUB_REPOSITORY']
    if ($Runtime['GITHUB_ACTIONS'] -cne 'true' -or $repository -cnotin @($registered.Keys)) {
        throw 'Ordinary CI requires its registered GitHub repository runtime.'
    }
    $identity = $registered[$repository]
    $eventRepository = $Event['repository']
    if ($Runtime['GITHUB_REPOSITORY_ID'] -cne $identity.id -or
        $eventRepository -isnot [Collections.IDictionary] -or
        $eventRepository['full_name'] -cne $repository -or [string]$eventRepository['id'] -cne $identity.id) {
        throw 'Ordinary CI repository identities disagree.'
    }
    $source = $Runtime['GITHUB_SHA']
    $ref = $Runtime['GITHUB_REF']
    if ($source -cnotmatch '^[a-f0-9]{40}$' -or $Runtime['GITHUB_WORKFLOW_SHA'] -cne $source -or
        $Runtime['GITHUB_WORKFLOW_REF'] -cne "$repository/.github/workflows/$($identity.workflow)@$ref") {
        throw 'Ordinary CI workflow and execution source identities disagree.'
    }
    if ($Runtime['GITHUB_REF_TYPE'] -cne 'branch') { throw 'Ordinary CI requires a branch reference.' }
    $eventName = $Runtime['GITHUB_EVENT_NAME']
    if ($eventName -ceq 'pull_request') {
        $pr = $Event['pull_request']
        if ($pr -isnot [Collections.IDictionary] -or $pr['base'] -isnot [Collections.IDictionary] -or
            $pr['head'] -isnot [Collections.IDictionary] -or $pr['base']['repo'] -isnot [Collections.IDictionary]) {
            throw 'Ordinary CI requires a complete pull request identity.'
        }
        $number = [string]$Event['number']
        if ($number -cnotmatch '^[1-9][0-9]*$' -or [string]$pr['number'] -cne $number -or
            $ref -cne "refs/pull/$number/merge" -or $Runtime['GITHUB_REF_NAME'] -cne "$number/merge" -or
            $pr['merge_commit_sha'] -cne $source -or $pr['state'] -cne 'open' -or
            $pr['merged'] -isnot [bool] -or $pr['merged'] -or
            $Event['action'] -cnotin @('opened', 'reopened', 'synchronize')) {
            throw 'Ordinary CI requires the current open pull request merge source.'
        }
        $base = $pr['base']
        $head = $pr['head']
        $channel = $base['ref']
        if ($channel -cnotin @('dev', 'main') -or $Runtime['GITHUB_BASE_REF'] -cne $channel -or
            $base['repo']['full_name'] -cne $repository -or [string]$base['repo']['id'] -cne $identity.id -or
            $base['sha'] -cnotmatch '^[a-f0-9]{40}$' -or $head['sha'] -cnotmatch '^[a-f0-9]{40}$' -or
            !($head['ref'] -is [string]) -or !$head['ref'] -or $Runtime['GITHUB_HEAD_REF'] -cne $head['ref']) {
            throw 'Ordinary CI pull request base and source identities disagree.'
        }
    } elseif ($eventName -cin @('push', 'workflow_dispatch')) {
        if ($ref -cnotin @('refs/heads/dev', 'refs/heads/main')) {
            throw 'Ordinary CI requires an exact dev or main branch reference.'
        }
        $channel = $ref.Substring('refs/heads/'.Length)
        if ($Runtime['GITHUB_REF_NAME'] -cne $channel -or $Runtime['GITHUB_BASE_REF'] -or $Runtime['GITHUB_HEAD_REF'] -or
            $Event.Contains('pull_request')) { throw 'Ordinary CI branch and pull request contexts conflict.' }
        if ($eventName -ceq 'push') {
            # Covered as a helper contract. Registered ordinary workflows do not add a push trigger.
            $headCommit = $Event['head_commit']
            if ($Event['ref'] -cne $ref -or $Event['after'] -cne $source -or
                $Event['deleted'] -isnot [bool] -or $Event['deleted'] -or
                $headCommit -isnot [Collections.IDictionary] -or $headCommit['id'] -cne $source) {
                throw 'Ordinary CI push source identities disagree.'
            }
        } else {
            # No caller-defined inputs exist in either registered ordinary workflow.
            $inputs = $Event['inputs']
            if ($Event['ref'] -cnotin @($channel, $ref) -or
                ($null -ne $inputs -and ($inputs -isnot [Collections.IDictionary] -or $inputs.Count -ne 0))) {
                throw 'Ordinary CI dispatch must use its registered branch without caller inputs.'
            }
        }
    } else { throw 'Unsupported ordinary CI event.' }
    [pscustomobject]@{ channel = $channel; repository = $repository; workflow = $identity.workflow; source = $source; ref = $ref }
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
    $event = Get-Content -LiteralPath $env:GITHUB_EVENT_PATH -Raw | ConvertFrom-Json -AsHashtable
    if ($event -isnot [Collections.IDictionary]) { throw 'Ordinary CI requires a JSON event object.' }
    $resolved = Resolve-WssOrdinaryCiChannel $runtime $event
    $root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
    $head = & git --no-optional-locks -C $root rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or ($head -join '').Trim() -cne $resolved.source) {
        throw 'Ordinary CI checkout differs from the event source.'
    }
    $remote = & git --no-optional-locks -C $root remote get-url origin
    if ($LASTEXITCODE -ne 0 -or (($remote -join '').Trim().TrimEnd('/') -creplace '\.git$', '') -cne "https://github.com/$($resolved.repository)") {
        throw 'Ordinary CI checkout repository differs from the registered source.'
    }
    # Channel is emitted only after both hosted metadata and the actual checkout agree.
    "channel=$($resolved.channel)" >> $env:GITHUB_OUTPUT
    "Verified ordinary $($resolved.channel) source $($resolved.source) for $($resolved.repository)."
}

if ($MyInvocation.InvocationName -cne '.') { Initialize-WssOrdinaryCiChannel }
