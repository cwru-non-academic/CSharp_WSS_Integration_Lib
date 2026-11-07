$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot/../Resolve-OrdinaryCiChannel.ps1"
$script:passed = 0
$source = 'a' * 40

function New-OrdinaryFixture([string]$Repository, [string]$EventName, [string]$Ref, [string]$Base) {
    $cli = $Repository -ceq 'cwru-non-academic/CLI_CSharp_WSS_Application'
    $id = if ($cli) { '1207505563' } else { '1092676331' }
    $workflow = if ($cli) { 'cli-ci.yml' } else { 'wss-compatibility.yml' }
    $name = $Ref -creplace '^refs/(heads|tags|pull)/', ''
    $runtime = @{
        GITHUB_ACTIONS = 'true'; GITHUB_REPOSITORY = $Repository; GITHUB_REPOSITORY_ID = $id
        GITHUB_SHA = $source; GITHUB_WORKFLOW_SHA = $source
        GITHUB_WORKFLOW_REF = "$Repository/.github/workflows/$workflow@$Ref"
        GITHUB_REF = $Ref; GITHUB_REF_NAME = $name; GITHUB_REF_TYPE = 'branch'
        GITHUB_EVENT_NAME = $EventName; GITHUB_BASE_REF = $Base; GITHUB_HEAD_REF = ''
    }
    $event = @{ repository = @{ full_name = $Repository; id = [long]$id } }
    if ($EventName -ceq 'pull_request') {
        $runtime.GITHUB_HEAD_REF = 'feature/main-is-not-the-base'
        $event.number = 1; $event.action = 'synchronize'
        $event.pull_request = @{
            number = 1; merge_commit_sha = $source; state = 'open'; merged = $false
            base = @{ ref = $Base; sha = ('b' * 40); repo = @{ full_name = $Repository; id = [long]$id } }
            head = @{ ref = $runtime.GITHUB_HEAD_REF; sha = ('c' * 40); repo = @{ full_name = 'fork/contribution'; id = 10 } }
        }
    } elseif ($EventName -ceq 'push') {
        $event.ref = $Ref; $event.after = $source; $event.deleted = $false; $event.head_commit = @{ id = $source }
    } else { $event.ref = $name; $event.inputs = @{} }
    @{ runtime = $runtime; event = $event }
}
function Expect-Channel($Fixture, [string]$Expected) {
    $r = Resolve-WssOrdinaryCiChannel $Fixture.runtime $Fixture.event
    if ($r.channel -cne $Expected -or $r.repository -cne $Fixture.runtime.GITHUB_REPOSITORY -or
        $r.source -cne $Fixture.runtime.GITHUB_SHA -or $r.ref -cne $Fixture.runtime.GITHUB_REF) { throw 'Wrong ordinary channel/source result.' }
    $script:passed++
}
function Expect-Rejection($Fixture, [string]$Reason) {
    $errorText = ''
    try { $null = Resolve-WssOrdinaryCiChannel $Fixture.runtime $Fixture.event } catch { $errorText = $_.Exception.Message }
    if ($errorText -cne $Reason) { throw "Expected '$Reason', got '$errorText'." }
    $script:passed++
}
$repositories = @('cwru-non-academic/CSharp_WSS_Integration_Lib', 'cwru-non-academic/CLI_CSharp_WSS_Application')
$events = @('push', 'pull_request', 'workflow_dispatch', 'pull_request_target', 'workflow_call', 'workflow_run', 'repository_dispatch', 'schedule', 'release', '', 'PUSH')
$refs = @('refs/heads/dev', 'refs/heads/main', 'refs/heads/feature', 'refs/heads/Main', 'refs/tags/main', 'refs/tags/dev', 'refs/pull/1/merge', 'refs/pull/1/head', 'refs/pull/2/merge', 'dev', 'main', '')
foreach ($repository in $repositories) {
    foreach ($eventName in $events) {
        foreach ($ref in $refs) {
            foreach ($base in @('', 'dev', 'main', 'feature', 'Main')) {
                $f = New-OrdinaryFixture $repository $eventName $ref $base
                if (!$ref) { Expect-Rejection $f 'Ordinary CI workflow and execution source identities disagree.' }
                elseif ($eventName -ceq 'pull_request') {
                    if ($ref -cne 'refs/pull/1/merge') { Expect-Rejection $f 'Ordinary CI requires the current open pull request merge source.' }
                    elseif ($base -cnotin @('dev', 'main')) { Expect-Rejection $f 'Ordinary CI pull request base and source identities disagree.' }
                    else { Expect-Channel $f $base }
                } elseif ($eventName -cin @('push', 'workflow_dispatch')) {
                    if ($ref -cnotin @('refs/heads/dev', 'refs/heads/main')) { Expect-Rejection $f 'Ordinary CI requires an exact dev or main branch reference.' }
                    elseif ($base) { Expect-Rejection $f 'Ordinary CI branch and pull request contexts conflict.' }
                    else { Expect-Channel $f ($ref.Substring('refs/heads/'.Length)) }
                } else { Expect-Rejection $f 'Unsupported ordinary CI event.' }
            }
        }
    }
}
$matrixCount = $passed
foreach ($repository in $repositories) {
    foreach ($eventName in @('pull_request', 'push', 'workflow_dispatch')) {
        foreach ($channel in @('dev', 'main')) {
            $ref = if ($eventName -ceq 'pull_request') { 'refs/pull/1/merge' } else { "refs/heads/$channel" }
            $base = if ($eventName -ceq 'pull_request') { $channel } else { '' }
            foreach ($mutation in @(
                @{ path = 'GITHUB_ACTIONS'; value = 'false'; reason = 'Ordinary CI requires its registered GitHub repository runtime.' },
                @{ path = 'GITHUB_REPOSITORY'; value = 'fork/unregistered'; reason = 'Ordinary CI requires its registered GitHub repository runtime.' },
                @{ path = 'GITHUB_REPOSITORY'; value = $repository.ToUpperInvariant(); reason = 'Ordinary CI requires its registered GitHub repository runtime.' },
                @{ path = 'GITHUB_REPOSITORY_ID'; value = '1092676332'; reason = 'Ordinary CI repository identities disagree.' },
                @{ path = 'GITHUB_SHA'; value = 'short'; reason = 'Ordinary CI workflow and execution source identities disagree.' },
                @{ path = 'GITHUB_SHA'; value = ('A' * 40); reason = 'Ordinary CI workflow and execution source identities disagree.' },
                @{ path = 'GITHUB_SHA'; value = ('d' * 40); reason = 'Ordinary CI workflow and execution source identities disagree.' },
                @{ path = 'GITHUB_WORKFLOW_SHA'; value = ('d' * 40); reason = 'Ordinary CI workflow and execution source identities disagree.' },
                @{ path = 'GITHUB_WORKFLOW_REF'; value = "$repository/.github/workflows/wss-preflight.yml@$ref"; reason = 'Ordinary CI workflow and execution source identities disagree.' },
                @{ path = 'GITHUB_WORKFLOW_REF'; value = "$repository/.github/workflows/cli-ci.yml@refs/tags/main"; reason = 'Ordinary CI workflow and execution source identities disagree.' },
                @{ path = 'GITHUB_REF_TYPE'; value = 'tag'; reason = 'Ordinary CI requires a branch reference.' }
            )) {
                $f = New-OrdinaryFixture $repository $eventName $ref $base
                $f.runtime[$mutation.path] = $mutation.value
                Expect-Rejection $f $mutation.reason
            }
            foreach ($key in @('GITHUB_ACTIONS', 'GITHUB_REPOSITORY', 'GITHUB_REPOSITORY_ID', 'GITHUB_SHA', 'GITHUB_WORKFLOW_SHA', 'GITHUB_WORKFLOW_REF', 'GITHUB_REF_TYPE')) {
                $f = New-OrdinaryFixture $repository $eventName $ref $base
                $f.runtime.Remove($key)
                $reason = if ($key -cin @('GITHUB_ACTIONS', 'GITHUB_REPOSITORY')) { 'Ordinary CI requires its registered GitHub repository runtime.' }
                    elseif ($key -ceq 'GITHUB_REPOSITORY_ID') { 'Ordinary CI repository identities disagree.' }
                    elseif ($key -ceq 'GITHUB_REF_TYPE') { 'Ordinary CI requires a branch reference.' }
                    else { 'Ordinary CI workflow and execution source identities disagree.' }
                Expect-Rejection $f $reason
            }
            foreach ($change in @({param($f) $f.event.repository.id = 10}, {param($f) $f.event.repository.full_name = 'fork/other'}, {param($f) $f.event.repository = $null})) {
                $f = New-OrdinaryFixture $repository $eventName $ref $base
                & $change $f
                Expect-Rejection $f 'Ordinary CI repository identities disagree.'
            }
            $f = New-OrdinaryFixture $repository $eventName $ref $base
            $f.runtime.WSS_CI_CHANNEL = if ($channel -ceq 'main') { 'dev' } else { 'main' }
            $f.runtime.WSS_PIN_TEST_REPOSITORY = 'untrusted/tests'; $f.runtime.WSS_PIN_TEST_COMMIT = 'd' * 40
            Expect-Channel $f $channel
            if ($eventName -ceq 'pull_request') {
                foreach ($action in @('opened', 'reopened', 'synchronize')) {
                    $f = New-OrdinaryFixture $repository $eventName $ref $base; $f.event.action = $action
                    $f.event.pull_request.head.ref = if ($channel -ceq 'main') { 'dev' } else { 'main' }
                    $f.runtime.GITHUB_HEAD_REF = $f.event.pull_request.head.ref
                    Expect-Channel $f $channel
                }
                foreach ($change in @(
                    {param($f) $f.event.number = 2}, {param($f) $f.event.pull_request.number = 2},
                    {param($f) $f.event.pull_request.merge_commit_sha = 'd' * 40},
                    {param($f) $f.event.pull_request.state = 'closed'}, {param($f) $f.event.pull_request.merged = $true},
                    {param($f) $f.event.pull_request.merged = 'false'}, {param($f) $f.event.action = 'closed'},
                    {param($f) $f.runtime.GITHUB_REF_NAME = '2/merge'}
                )) {
                    $f = New-OrdinaryFixture $repository $eventName $ref $base; & $change $f
                    Expect-Rejection $f 'Ordinary CI requires the current open pull request merge source.'
                }
                foreach ($change in @(
                    {param($f) $f.runtime.GITHUB_BASE_REF = 'other'}, {param($f) $f.runtime.GITHUB_HEAD_REF = 'other'},
                    {param($f) $f.event.pull_request.base.repo.id = 10}, {param($f) $f.event.pull_request.base.repo.full_name = 'fork/other'},
                    {param($f) $f.event.pull_request.base.sha = 'short'}, {param($f) $f.event.pull_request.head.sha = 'short'},
                    {param($f) $f.event.pull_request.head.ref = ''}
                )) {
                    $f = New-OrdinaryFixture $repository $eventName $ref $base; & $change $f
                    Expect-Rejection $f 'Ordinary CI pull request base and source identities disagree.'
                }
                foreach ($change in @({param($f) $f.event.pull_request = $null}, {param($f) $f.event.pull_request.base = $null}, {param($f) $f.event.pull_request.head = $null}, {param($f) $f.event.pull_request.base.repo = $null})) {
                    $f = New-OrdinaryFixture $repository $eventName $ref $base; & $change $f
                    Expect-Rejection $f 'Ordinary CI requires a complete pull request identity.'
                }
            } else {
                foreach ($change in @({param($f) $f.runtime.GITHUB_HEAD_REF = 'other'}, {param($f) $f.runtime.GITHUB_REF_NAME = 'other'}, {param($f) $f.event.pull_request = @{}})) {
                    $f = New-OrdinaryFixture $repository $eventName $ref $base; & $change $f
                    Expect-Rejection $f 'Ordinary CI branch and pull request contexts conflict.'
                }
                if ($eventName -ceq 'push') {
                    foreach ($change in @({param($f) $f.event.ref = 'refs/heads/other'}, {param($f) $f.event.after = 'd' * 40}, {param($f) $f.event.deleted = $true}, {param($f) $f.event.deleted = 'false'}, {param($f) $f.event.head_commit = $null}, {param($f) $f.event.head_commit.id = 'd' * 40})) {
                        $f = New-OrdinaryFixture $repository $eventName $ref $base; & $change $f
                        Expect-Rejection $f 'Ordinary CI push source identities disagree.'
                    }
                } else {
                    foreach ($inputs in @($null, @{})) {
                        $f = New-OrdinaryFixture $repository $eventName $ref $base; $f.event.inputs = $inputs; $f.event.ref = $ref
                        Expect-Channel $f $channel
                    }
                    foreach ($change in @({param($f) $f.event.ref = 'other'}, {param($f) $f.event.inputs = @{channel = 'main'}}, {param($f) $f.event.inputs = @{source = ('d' * 40)}}, {param($f) $f.event.inputs = 'dev'})) {
                        $f = New-OrdinaryFixture $repository $eventName $ref $base; & $change $f
                        Expect-Rejection $f 'Ordinary CI dispatch must use its registered branch without caller inputs.'
                    }
                }
            }
        }
    }
}
$identityCount = $passed - $matrixCount
# Every consumed payload field is mutated through actual JSON serialization/parsing.
# Collections must stay collections: comparisons and casts are not schema validators.
function Set-OrdinaryJsonField($Object, [string]$Path, $Value, [switch]$Missing) {
    $keys = $Path.Split('.')
    $parent = $Object
    for ($i = 0; $i -lt $keys.Length - 1; $i++) { $parent = $parent[$keys[$i]] }
    if ($Missing) { $null = $parent.Remove($keys[-1]) } else { $parent[$keys[-1]] = $Value }
}
function Get-OrdinaryJsonField($Object, [string]$Path) {
    $value = $Object
    foreach ($key in $Path.Split('.')) { $value = $value[$key] }
    # Preserve arrays as one value, including empty/single-element arrays.
    Write-Output -NoEnumerate $value
}
function Convert-OrdinaryJsonFixture($Fixture) {
    $Fixture.event = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $Fixture.event -Depth 20 -Compress) -AsHashtable -NoEnumerate
    $Fixture
}
$repositoryReason = 'Ordinary CI repository identities disagree.'
$prShapeReason = 'Ordinary CI requires a complete pull request identity.'
$prSourceReason = 'Ordinary CI requires the current open pull request merge source.'
$prBaseReason = 'Ordinary CI pull request base and source identities disagree.'
$pushReason = 'Ordinary CI push source identities disagree.'
$dispatchReason = 'Ordinary CI dispatch must use its registered branch without caller inputs.'
foreach ($repository in $repositories) {
    foreach ($eventName in @('pull_request', 'push', 'workflow_dispatch')) {
        foreach ($channel in @('dev', 'main')) {
            $ref = if ($eventName -ceq 'pull_request') { 'refs/pull/1/merge' } else { "refs/heads/$channel" }
            $base = if ($eventName -ceq 'pull_request') { $channel } else { '' }
            Expect-Channel (Convert-OrdinaryJsonFixture (New-OrdinaryFixture $repository $eventName $ref $base)) $channel
            $fields = @(
                @{ path = 'repository'; type = 'object'; reason = $repositoryReason },
                @{ path = 'repository.full_name'; type = 'string'; reason = $repositoryReason },
                @{ path = 'repository.id'; type = 'integer'; reason = $repositoryReason }
            )
            if ($eventName -ceq 'pull_request') {
                $fields += @(
                    @{ path = 'pull_request'; type = 'object'; reason = $prShapeReason },
                    @{ path = 'pull_request.base'; type = 'object'; reason = $prShapeReason },
                    @{ path = 'pull_request.head'; type = 'object'; reason = $prShapeReason },
                    @{ path = 'pull_request.base.repo'; type = 'object'; reason = $prShapeReason },
                    @{ path = 'number'; type = 'integer'; reason = $prSourceReason },
                    @{ path = 'action'; type = 'string'; reason = $prSourceReason },
                    @{ path = 'pull_request.number'; type = 'integer'; reason = $prSourceReason },
                    @{ path = 'pull_request.merge_commit_sha'; type = 'string'; reason = $prSourceReason },
                    @{ path = 'pull_request.state'; type = 'string'; reason = $prSourceReason },
                    @{ path = 'pull_request.merged'; type = 'boolean'; reason = $prSourceReason },
                    @{ path = 'pull_request.base.ref'; type = 'string'; reason = $prBaseReason },
                    @{ path = 'pull_request.base.repo.full_name'; type = 'string'; reason = $prBaseReason },
                    @{ path = 'pull_request.base.repo.id'; type = 'integer'; reason = $prBaseReason },
                    @{ path = 'pull_request.base.sha'; type = 'string'; reason = $prBaseReason },
                    @{ path = 'pull_request.head.sha'; type = 'string'; reason = $prBaseReason },
                    @{ path = 'pull_request.head.ref'; type = 'string'; reason = $prBaseReason }
                )
            } elseif ($eventName -ceq 'push') {
                $fields += @(
                    @{ path = 'ref'; type = 'string'; reason = $pushReason },
                    @{ path = 'after'; type = 'string'; reason = $pushReason },
                    @{ path = 'head_commit'; type = 'object'; reason = $pushReason },
                    @{ path = 'head_commit.id'; type = 'string'; reason = $pushReason },
                    @{ path = 'deleted'; type = 'boolean'; reason = $pushReason }
                )
            } else { $fields += @{ path = 'ref'; type = 'string'; reason = $dispatchReason } }
            foreach ($field in $fields) {
                $original = New-OrdinaryFixture $repository $eventName $ref $base
                $valid = Get-OrdinaryJsonField $original.event $field.path
                $validJson = ConvertTo-Json -InputObject $valid -Depth 20 -Compress
                $invalid = @(
                    @{ name = 'missing'; json = 'null' }, @{ name = 'null'; json = 'null' },
                    @{ name = 'empty-array'; json = '[]' }, @{ name = 'singleton-array'; json = "[$validJson]" },
                    @{ name = 'duplicate-array'; json = "[$validJson,$validJson]" },
                    @{ name = 'mixed-array'; json = "[null,$validJson]" },
                    @{ name = 'number'; json = '0' }, @{ name = 'float'; json = '1.5' },
                    @{ name = 'empty-string'; json = '""' }, @{ name = 'whitespace-string'; json = '" "' }
                )
                if ($field.type -cne 'boolean') { $invalid += @{ name = 'false'; json = 'false' } }
                $invalid += @{ name = 'true'; json = 'true' }
                if ($field.type -cne 'object') {
                    $invalid += @{ name = 'empty-object'; json = '{}' }
                    $invalid += @{ name = 'value-object'; json = "{`"value`":$validJson}" }
                }
                if ($field.type -ceq 'string') {
                    # Regex end-of-line anchors must not accept a trailing newline in a SHA.
                    foreach ($suffix in @("`n", "`r`n")) {
                        $invalid += @{ name = 'trailing-newline'; json = (ConvertTo-Json -InputObject ([string]$valid + $suffix) -Compress) }
                    }
                }
                if ($field.type -ceq 'integer') {
                    $invalid += @{ name = 'numeric-string'; json = "`"$valid`"" }
                    $invalid += @{ name = 'integral-float'; json = '1.0' }
                    $invalid += @{ name = 'negative'; json = '-1' }
                } elseif ($field.type -ceq 'boolean') {
                    $invalid += @{ name = 'boolean-string'; json = '"false"' }
                }
                foreach ($case in $invalid) {
                    $f = New-OrdinaryFixture $repository $eventName $ref $base
                    $value = ConvertFrom-Json -InputObject $case.json -AsHashtable -NoEnumerate
                    Set-OrdinaryJsonField $f.event $field.path $value -Missing:($case.name -ceq 'missing')
                    $f = Convert-OrdinaryJsonFixture $f
                    Expect-Rejection $f $field.reason
                }
            }
            if ($eventName -ceq 'workflow_dispatch') {
                # Omitted/null/empty object remain valid; every other JSON input shape is forbidden.
                foreach ($json in @('[]', '[{}]', 'false', 'true', '0', '""', '{"Count":0}', '{"get_Count":0}', '{"channel":"main"}')) {
                    $f = New-OrdinaryFixture $repository $eventName $ref $base
                    $f.event.inputs = ConvertFrom-Json -InputObject $json -AsHashtable -NoEnumerate
                    Expect-Rejection (Convert-OrdinaryJsonFixture $f) $dispatchReason
                }
                foreach ($kind in @('missing', 'null', 'empty-object')) {
                    $f = New-OrdinaryFixture $repository $eventName $ref $base
                    if ($kind -ceq 'missing') { $null = $f.event.Remove('inputs') }
                    elseif ($kind -ceq 'null') { $f.event.inputs = $null }
                    Expect-Channel (Convert-OrdinaryJsonFixture $f) $channel
                }
            }
        }
    }
}
$jsonCount = $passed - $matrixCount - $identityCount

# Lock the original mandatory workflow execution while reviewing this channel-only change.
# A future intentional baseline/workflow change must update its reviewed fingerprint too.
function Assert-OrdinaryWorkflow([string]$Text, [string]$Workflow) {
    $text = $Text.Replace("`r`n", "`n")
    $resolver = @'
  resolve-channel:
    name: Verified ordinary CI channel
    runs-on: ubuntu-latest
    outputs:
      channel: ${{ steps.channel.outputs.channel }}
    steps:
      - uses: actions/checkout@v4
        with:
          persist-credentials: false
      - name: Bind the channel to the actual event and workflow source
        id: channel
        shell: pwsh
        run: ./.github/scripts/Resolve-OrdinaryCiChannel.ps1
      - name: Exercise ordinary channel and workflow contracts
        shell: pwsh
        run: ./.github/scripts/tests/OrdinaryCiChannel.Tests.ps1

'@
    $ordinary = @'
    needs: resolve-channel
    env:
      WSS_CI_CHANNEL: ${{ needs.resolve-channel.outputs.channel }}
'@
    $aggregate = @'
    needs: [resolve-channel, macos_architecture]
    env:
      WSS_CI_CHANNEL: ${{ needs.resolve-channel.outputs.channel }}
'@
    $guard = @'
      - name: Require successful channel resolution
        if: always()
        shell: pwsh
        env:
          CHANNEL_RESULT: ${{ needs.resolve-channel.result }}
        run: |
          if ($env:CHANNEL_RESULT -cne 'success' -or $env:WSS_CI_CHANNEL -cnotin @('dev', 'main')) { throw 'Ordinary channel resolution did not succeed.' }
'@
    $fixture = @'
        # Dev here is only the synthetic contract fixture, never the execution channel.
        env:
          WSS_CI_CHANNEL: dev
'@
    if (!$text.Contains("jobs:`n$resolver`n")) { throw 'Channel resolver must remain the first complete job.' }
    $jobText = ($text -split "jobs:`n", 2)[1]
    $jobs = [regex]::Matches($jobText, '(?ms)^  (?<name>[a-zA-Z0-9_-]+):\n(?<body>.*?)(?=^  [a-zA-Z0-9_-]+:\n|\z)')
    foreach ($job in $jobs) {
        $name = $job.Groups['name'].Value
        $body = $job.Groups['body'].Value
        if ($name -ceq 'resolve-channel') { continue }
        if ($name -ceq 'macos_compatibility') {
            if ($body -cnotmatch ('^    name: [^\n]+\n' + [regex]::Escape($aggregate) + '\n    if: always\(\)\n') -or
                !$body.Contains("    steps:`n$guard`n")) { throw 'Aggregate must fail on channel failure/skips and preserve native workers.' }
        } elseif (!$body.StartsWith("$ordinary`n", [StringComparison]::Ordinal)) { throw 'Every ordinary job must consume only the verified channel.' }
    }
    $receipt = "      - name: Exercise canonical policy through the actual PowerShell adapter`n        shell: pwsh`n$fixture`n        run: ./.github/scripts/tests/WssReleaseReceipt.Tests.ps1"
    $second = if ($Workflow -ceq 'cli-ci.yml') { "      - shell: pwsh`n$fixture`n        run: ./.github/scripts/tests/WssReleaseReceipt.Tests.ps1" }
        else { "      - name: Validate promotion safety contracts`n        shell: pwsh`n$fixture`n        run: |" }
    if (!$text.Contains($receipt) -or !$text.Contains($second) -or [regex]::Matches($text, [regex]::Escape($fixture)).Count -ne 2) { throw 'Synthetic dev fixtures must remain scoped only to their contract steps.' }
    $count = if ($Workflow -ceq 'cli-ci.yml') { 6 } else { 5 }
    foreach ($part in @(@{ text = $resolver; count = 1 }, @{ text = $ordinary; count = $count }, @{ text = $aggregate; count = 1 }, @{ text = $guard; count = 1 })) {
        if ([regex]::Matches($text, [regex]::Escape($part.text)).Count -ne $part.count) { throw 'Ordinary workflow channel wiring changed.' }
    }
    $restored = $text.Replace("$resolver`n", '').Replace("$ordinary`n", '').Replace($aggregate, '    needs: macos_architecture').Replace("$guard`n", '').Replace("$fixture`n", '')
    $restored = $restored.Replace("permissions:`n", "env:`n  WSS_CI_CHANNEL: dev`npermissions:`n")
    $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($restored))).ToLowerInvariant()
    $expected = if ($Workflow -ceq 'cli-ci.yml') { 'ac030fa6fe5c253a1c04e264bccea3803ec610f3ab988e1a533a0c2cb0e5a3e0' } else { '5ef0c1081535fd290d0ca925cfc989ed237e5daa610ad567ce3c21b4bf15b0be' }
    if ($digest -cne $expected) { throw 'Ordinary workflow triggers, permissions or mandatory baseline jobs changed.' }
}
$workflow = if (Test-Path "$PSScriptRoot/../../workflows/cli-ci.yml") { 'cli-ci.yml' } else { 'wss-compatibility.yml' }
$text = [IO.File]::ReadAllText("$PSScriptRoot/../../workflows/$workflow").Replace("`r`n", "`n")
Assert-OrdinaryWorkflow $text $workflow; $passed++
foreach ($change in @(
    {param($t) $t.Replace('needs: resolve-channel', 'needs: []')},
    {param($t) $t.Replace('needs: [resolve-channel, macos_architecture]', 'needs: [macos_architecture]')},
    {param($t) $t.Replace('needs: [resolve-channel, macos_architecture]', 'needs: [resolve-channel]')},
    {param($t) $t.Replace('WSS_CI_CHANNEL: ${{ needs.resolve-channel.outputs.channel }}', 'WSS_CI_CHANNEL: dev')},
    {param($t) $t.Replace('WSS_CI_CHANNEL: ${{ needs.resolve-channel.outputs.channel }}', 'WSS_CI_CHANNEL: ${{ github.ref_name }}')},
    {param($t) $t.Replace('steps.channel.outputs.channel', 'inputs.channel')},
    {param($t) $t.Replace('-cne ''success''', '-ceq ''failure''')},
    {param($t) $t.Replace('macos-15-intel', 'macos-15')},
    {param($t) $t.Replace('contents: read', 'contents: write')},
    {param($t) $t.Replace("  workflow_dispatch:", "  push:`n    branches: [dev, main]`n  workflow_dispatch:")},
    {param($t) $t.Replace('./.github/scripts/Resolve-OrdinaryCiChannel.ps1', './.github/scripts/Resolve-OrdinaryCiChannel.ps1 -Channel dev')},
    {param($t) $t.Replace('./.github/scripts/tests/OrdinaryCiChannel.Tests.ps1', 'echo skipped')},
    {param($t) $t.Replace('shell: pwsh', 'shell: bash')},
    {param($t) $t.Replace('if: always()', 'if: success()')},
    {param($t) $t.Replace('          WSS_CI_CHANNEL: dev', '          WSS_CI_CHANNEL: main')},
    {param($t) $t.Replace('        # Dev here is only the synthetic contract fixture, never the execution channel.', '    # Dev here is only the synthetic contract fixture, never the execution channel.')}
)) {
    $changed = & $change $text
    if ($changed -ceq $text) { throw 'Workflow mutation did not change its fixture.' }
    $rejected = $false
    try { Assert-OrdinaryWorkflow $changed $workflow } catch { $rejected = $true }
    if (!$rejected) { throw 'Unsafe ordinary workflow mutation was accepted.' }
    $passed++
}
$workflowCount = $passed - $matrixCount - $identityCount - $jsonCount
"Ordinary CI channel contracts passed: $passed ($matrixCount event/ref/base cases, $identityCount identity/override cases, $jsonCount JSON-roundtrip cases, $workflowCount workflow-preservation cases). Push resolution is helper-only; registered workflow triggers are unchanged."

# Exercise the real entrypoint's runner-file read, Git source binding and atomic output.
# These synthetic local contexts prove rejection/selection behavior, not hosted acceptance.
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$actualSha = (& git --no-optional-locks -C $root rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Unable to read contract checkout identity.' }
$repository = if ($workflow -ceq 'cli-ci.yml') { $repositories[1] } else { $repositories[0] }
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('wss-channel-contract-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $scratch
$saved = @{}
try {
    $entrypointCount = 0
    # Real entrypoint parsing must reject non-object JSON roots without unwrapping arrays.
    # Also repeat the reviewed array bypasses through the event file, not only the pure helper.
    foreach ($channel in @('dev', 'main')) {
        foreach ($eventName in @('pull_request', 'push', 'workflow_dispatch')) {
            $ref = if ($eventName -ceq 'pull_request') { 'refs/pull/1/merge' } else { "refs/heads/$channel" }
            $base = if ($eventName -ceq 'pull_request') { $channel } else { '' }
            $f = New-OrdinaryFixture $repository $eventName $ref $base
            $f.runtime.GITHUB_SHA = $actualSha; $f.runtime.GITHUB_WORKFLOW_SHA = $actualSha
            if ($eventName -ceq 'pull_request') { $f.event.pull_request.merge_commit_sha = $actualSha }
            elseif ($eventName -ceq 'push') { $f.event.after = $actualSha; $f.event.head_commit.id = $actualSha }
            $validJson = ConvertTo-Json -InputObject $f.event -Depth 20 -Compress
            $cases = @(@{ json = $validJson; reason = '' })
            foreach ($json in @('null', 'false', 'true', '123', '"object"', '[]', "[$validJson]", "[$validJson,$validJson]")) {
                $cases += @{ json = $json; reason = 'Ordinary CI requires a JSON event object.' }
            }
            $fields = @(@{ path = 'repository.full_name'; reason = $repositoryReason })
            if ($eventName -ceq 'pull_request') {
                $fields += @(
                    @{ path = 'pull_request.merge_commit_sha'; reason = $prSourceReason },
                    @{ path = 'pull_request.state'; reason = $prSourceReason },
                    @{ path = 'pull_request.base.repo.full_name'; reason = $prBaseReason },
                    @{ path = 'pull_request.base.sha'; reason = $prBaseReason },
                    @{ path = 'pull_request.head.sha'; reason = $prBaseReason }
                )
            } elseif ($eventName -ceq 'push') {
                $fields += @(@{ path = 'ref'; reason = $pushReason }, @{ path = 'after'; reason = $pushReason }, @{ path = 'head_commit.id'; reason = $pushReason })
            } else { $fields += @{ path = 'ref'; reason = $dispatchReason } }
            foreach ($field in $fields) {
                $valid = Get-OrdinaryJsonField $f.event $field.path
                $valueJson = ConvertTo-Json -InputObject $valid -Compress
                foreach ($json in @('[]', "[$valueJson]", "[$valueJson,$valueJson]")) {
                    $event = ConvertFrom-Json -InputObject $validJson -AsHashtable -NoEnumerate
                    Set-OrdinaryJsonField $event $field.path (ConvertFrom-Json -InputObject $json -AsHashtable -NoEnumerate)
                    $cases += @{ json = (ConvertTo-Json -InputObject $event -Depth 20 -Compress); reason = $field.reason }
                }
            }
            $f.runtime.GITHUB_EVENT_PATH = Join-Path $scratch 'schema-event.json'
            $f.runtime.GITHUB_OUTPUT = Join-Path $scratch 'schema-output.txt'
            foreach ($key in $f.runtime.Keys) {
                if (!$saved.ContainsKey($key)) { $saved[$key] = [Environment]::GetEnvironmentVariable($key) }
                [Environment]::SetEnvironmentVariable($key, $f.runtime[$key])
            }
            foreach ($case in $cases) {
                [IO.File]::WriteAllText($env:GITHUB_EVENT_PATH, $case.json, [Text.UTF8Encoding]::new($false))
                [IO.File]::WriteAllText($env:GITHUB_OUTPUT, '', [Text.UTF8Encoding]::new($false))
                $errorText = ''
                try { $null = & "$PSScriptRoot/../Resolve-OrdinaryCiChannel.ps1" } catch { $errorText = $_.Exception.Message }
                if ($errorText -cne $case.reason) { throw "JSON entrypoint expected '$($case.reason)', got '$errorText'." }
                $expectedOutput = if ($case.reason) { '' } else { "channel=$channel`n" }
                if ([IO.File]::ReadAllText($env:GITHUB_OUTPUT).Replace("`r`n", "`n") -cne $expectedOutput) { throw 'Malformed JSON entrypoint emitted a channel.' }
                $entrypointCount++
            }
        }
    }
    foreach ($channel in @('dev', 'main')) {
        foreach ($kind in @('valid', 'checkout-mismatch', 'dispatch-override', 'repository-mismatch')) {
            $f = New-OrdinaryFixture $repository 'workflow_dispatch' "refs/heads/$channel" ''
            $f.runtime.GITHUB_SHA = $actualSha; $f.runtime.GITHUB_WORKFLOW_SHA = $actualSha
            $expectedError = ''
            if ($kind -ceq 'checkout-mismatch') {
                $f.runtime.GITHUB_SHA = 'd' * 40; $f.runtime.GITHUB_WORKFLOW_SHA = 'd' * 40
                $expectedError = 'Ordinary CI checkout differs from the event source.'
            } elseif ($kind -ceq 'dispatch-override') {
                $f.event.inputs = @{channel = 'main'}
                $expectedError = 'Ordinary CI dispatch must use its registered branch without caller inputs.'
            } elseif ($kind -ceq 'repository-mismatch') {
                $other = if ($workflow -ceq 'cli-ci.yml') { $repositories[0] } else { $repositories[1] }
                $f = New-OrdinaryFixture $other 'workflow_dispatch' "refs/heads/$channel" ''
                $f.runtime.GITHUB_SHA = $actualSha; $f.runtime.GITHUB_WORKFLOW_SHA = $actualSha
                $expectedError = 'Ordinary CI checkout repository differs from the registered source.'
            }
            $f.runtime.GITHUB_EVENT_PATH = Join-Path $scratch 'event.json'
            $f.runtime.GITHUB_OUTPUT = Join-Path $scratch 'output.txt'
            foreach ($key in $f.runtime.Keys) {
                if (!$saved.ContainsKey($key)) { $saved[$key] = [Environment]::GetEnvironmentVariable($key) }
                [Environment]::SetEnvironmentVariable($key, $f.runtime[$key])
            }
            [IO.File]::WriteAllText($env:GITHUB_EVENT_PATH, ($f.event | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
            [IO.File]::WriteAllText($env:GITHUB_OUTPUT, '', [Text.UTF8Encoding]::new($false))
            $errorText = ''
            try { $null = & "$PSScriptRoot/../Resolve-OrdinaryCiChannel.ps1" } catch { $errorText = $_.Exception.Message }
            if ($errorText -cne $expectedError) { throw "Entrypoint expected '$expectedError', got '$errorText'." }
            $output = [IO.File]::ReadAllText($env:GITHUB_OUTPUT).Replace("`r`n", "`n")
            $expectedOutput = if ($expectedError) { '' } else { "channel=$channel`n" }
            if ($output -cne $expectedOutput) { throw 'Entrypoint emitted a channel before successful identity validation.' }
            $entrypointCount++
        }
    }
    # Registered scripts have no command-line channel override, including direct invocation.
    $rejected = $false
    try { $null = & "$PSScriptRoot/../Resolve-OrdinaryCiChannel.ps1" -Channel main } catch {
        if ($_.Exception.Message -notmatch 'parameter.*Channel') { throw }
        $rejected = $true
    }
    if (!$rejected) { throw 'Ordinary entrypoint accepted a caller-supplied channel.' }
    $entrypointCount++
} finally {
    foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key]) }
    $resolved = [IO.Path]::GetFullPath($scratch)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (!$resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -cnotmatch '^wss-channel-contract-[a-f0-9]{32}$') { throw 'Unsafe contract scratch cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
"Ordinary CI entrypoint contracts passed: $entrypointCount; total $($passed + $entrypointCount). No selected C# executable was run."
