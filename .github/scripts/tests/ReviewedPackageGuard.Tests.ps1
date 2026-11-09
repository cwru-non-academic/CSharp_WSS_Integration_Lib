param([string]$RepositoryRoot = (Join-Path $PSScriptRoot '../../..'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# A deliberately narrow drift contract, not a YAML parser or runtime authority.
# Require the complete contiguous checkout/admission/setup/execution sequence,
# not an isolated guard line that comments, strings or dead code can spoof.
$contractTemplate = @'
      - uses: actions/checkout@v4
        with:
          repository: cwru-non-academic/WSSCore
          ref: __CORE_COMMIT__
          path: workflow-guard
          token: ${{ steps.core-token.outputs.token }}
          persist-credentials: false
      - name: Admit reviewed package verifier checkout before executing Core code
        shell: pwsh
        run: |
          $ErrorActionPreference = 'Stop'
          $lock = Get-Content .github/scripts/wss-ci.lock.json -Raw | ConvertFrom-Json -AsHashtable -NoEnumerate
          if ($lock -isnot [System.Collections.IDictionary] -or $lock['source_repository'] -isnot [string] -or $lock['source_repository'] -cne 'cwru-non-academic/WSSCore' -or $lock['source_commit'] -isnot [string] -or $lock['source_commit'] -cnotmatch '^[a-f0-9]{40}$' -or $lock['source_ref'] -isnot [string] -or $lock['source_ref'] -cne "refs/heads/ci/tooling/$($lock['source_commit'])") { throw 'Invalid reviewed package source lock.' }
          $head = & git --no-optional-locks -C workflow-guard rev-parse HEAD
          if ($LASTEXITCODE -ne 0) { throw 'Reviewed package HEAD query failed.' }
          if (($head -join '').Trim() -cne $lock['source_commit']) { throw 'Reviewed package checkout differs from source lock.' }
          $remote = & git --no-optional-locks -C workflow-guard remote get-url origin
          if ($LASTEXITCODE -ne 0) { throw 'Reviewed package origin query failed.' }
          if (($remote -join '').Trim() -cnotmatch '^(https://github.com/|git@github.com:)cwru-non-academic/WSSCore(\.git)?$') { throw 'Reviewed package checkout repository differs.' }
          $status = @(& git --no-optional-locks -C workflow-guard status --porcelain --untracked-files=all --ignored)
          if ($LASTEXITCODE -ne 0) { throw 'Reviewed package status query failed.' }
          $tracked = @(& git --no-optional-locks -C workflow-guard ls-files -v)
          if ($LASTEXITCODE -ne 0) { throw 'Reviewed package index query failed.' }
          if ($status.Count -or @($tracked | Where-Object { $_ -cnotmatch '^H ' }).Count) { throw 'Reviewed package checkout is not pristine.' }
      - uses: actions/setup-dotnet@v4
        with:
          dotnet-version: 9.0.x
      - uses: actions/setup-python@v5
        with:
          python-version: '3.x'
      - name: Run unchanged Core package contracts on the full selected universal payload
        shell: pwsh
        run: |
          & dotnet build workflow-guard/tools/ArtifactBuild/ArtifactBuild.csproj -p:RestoreLockedMode=true
          if ($LASTEXITCODE -ne 0) { throw 'Reviewed ArtifactBuild build failed.' }
          & python workflow-guard/tests/Packaging/verify_universal.py "$env:RUNNER_TEMP/wss-release/extracted/WSS-Universal"
          if ($LASTEXITCODE -ne 0) { throw 'Selected universal package contracts failed.' }
'@
$contractTemplate = $contractTemplate.Replace([string][char]13, '')
function Assert-ReviewedPackageGuard([string]$Text, $Lock) {
    if ($Lock.source_repository -cne 'cwru-non-academic/WSSCore' -or
        $Lock.source_commit -cnotmatch '^[a-f0-9]{40}$' -or
        $Lock.source_ref -cne "refs/heads/ci/tooling/$($Lock.source_commit)") {
        throw 'Invalid reviewed package source lock.'
    }
    $text = $Text.Replace([string][char]13, '')
    $expected = $contractTemplate.Replace('__CORE_COMMIT__', $Lock.source_commit)
    if ([regex]::Matches($text, [regex]::Escape($expected)).Count -ne 1 -or
        [regex]::Matches($text, '(?m)^          path: workflow-guard$').Count -ne 1 -or
        [regex]::Matches($text, '(?m)^      - name: Admit reviewed package verifier checkout before executing Core code$').Count -ne 1 -or
        $text.Contains('steps.package-tools.outputs.commit')) {
        throw 'Reviewed package checkout/admission contract differs.'
    }
    $start = $expected.IndexOf("          " + '$ErrorActionPreference')
    $end = $expected.IndexOf('      - uses: actions/setup-dotnet@v4', $start)
    $script = (($expected.Substring($start, $end - $start) -split [char]10) | ForEach-Object { $_ -replace '^          ', '' }) -join [char]10
    [scriptblock]::Create($script)
}
function Expect-GuardRejection([scriptblock]$Action, [string]$Expected, [string]$Name) {
    $actual = ''
    try { $null = & $Action } catch { $actual = $_.Exception.Message }
    if ($actual -cne $Expected) { throw "$Name expected '$Expected', got '$actual'." }
    $script:guardContracts++
}
function Invoke-ReviewedGuard([scriptblock]$Guard, $Fixture) {
    # Only these bounded doubles execute. No network, builds, package/native code
    # or real checkout mutations are involved in admission regressions.
    function Get-Content([string]$Path, [switch]$Raw) {
        if ($Path -cne '.github/scripts/wss-ci.lock.json' -or !$Raw) { throw 'Unexpected lock read in fixture.' }
        if ($Fixture.readFailure) { throw 'Synthetic lock read failed.' }
        $Fixture.json
    }
    function git {
        $command = $args -join ' '
        $prefix = '--no-optional-locks -C workflow-guard '
        if (!$command.StartsWith($prefix, [StringComparison]::Ordinal)) { throw 'Unexpected git target in fixture.' }
        $operation = $command.Substring($prefix.Length)
        if ($operation -cnotin @('rev-parse HEAD', 'remote get-url origin', 'status --porcelain --untracked-files=all --ignored', 'ls-files -v')) { throw 'Unexpected git operation in fixture.' }
        $Fixture.calls.Add($operation)
        Set-Variable -Name LASTEXITCODE -Value $(if ($operation -ceq $Fixture.fail) { 128 } else { 0 }) -Scope 1
        switch -CaseSensitive ($operation) {
            'rev-parse HEAD' { $Fixture.head }
            'remote get-url origin' { $Fixture.remote }
            'status --porcelain --untracked-files=all --ignored' { $Fixture.status }
            'ls-files -v' { $Fixture.tracked }
        }
    }
    & $Guard
}
function New-Fixture($Lock) {
    @{
        json = $Lock | ConvertTo-Json -Depth 30 -Compress
        head = $Lock.source_commit
        remote = 'https://github.com/cwru-non-academic/WSSCore'
        status = @()
        tracked = @('H tools/ArtifactBuild/ArtifactBuild.csproj')
        readFailure = $false
        fail = ''
        calls = [Collections.Generic.List[string]]::new()
    }
}
$sourceLock = Get-Content (Join-Path $RepositoryRoot '.github/scripts/wss-ci.lock.json') -Raw | ConvertFrom-Json -AsHashtable
$script:guardContracts = 0
foreach ($workflow in @('wss-compatibility.yml', 'wss-preflight.yml')) {
    $text = (Get-Content (Join-Path $RepositoryRoot ".github/workflows/$workflow") -Raw).Replace([string][char]13, '')
    $guard = Assert-ReviewedPackageGuard $text $sourceLock
    $fixture = New-Fixture $sourceLock
    Invoke-ReviewedGuard $guard $fixture
    if ($fixture.calls.Count -ne 4) { throw 'Positive admission did not exercise all git checks.' }
    $script:guardContracts++
    foreach ($mutation in @(
        @{ field = 'source_repository'; value = 'other/WSSCore' },
        @{ field = 'source_repository'; value = 'cwru-non-academic/wsscore' },
        @{ field = 'source_repository'; value = @('cwru-non-academic/WSSCore') },
        @{ field = 'source_ref'; value = @($sourceLock.source_ref) },
        @{ field = 'source_commit'; value = 'short' },
        @{ field = 'source_commit'; value = $sourceLock.source_commit.ToUpperInvariant() },
        @{ field = 'source_commit'; value = $null },
        @{ field = 'source_commit'; value = @($sourceLock.source_commit) },
        @{ field = 'source_ref'; value = 'refs/heads/dev' },
        @{ field = 'source_ref'; value = "refs/tags/ci/tooling/$($sourceLock.source_commit)" }
    )) {
        $changed = $sourceLock | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
        $changed[$mutation.field] = $mutation.value
        $fixture = New-Fixture $sourceLock
        $fixture.json = $changed | ConvertTo-Json -Depth 30 -Compress
        Expect-GuardRejection { Invoke-ReviewedGuard $guard $fixture } 'Invalid reviewed package source lock.' "$workflow/$($mutation.field)"
        if ($fixture.calls.Count) { throw 'Malformed lock reached checkout inspection.' }
    }
    foreach ($json in @('{}', 'null', '[]', '{"source_repository":"cwru-non-academic/WSSCore"}')) {
        $fixture = New-Fixture $sourceLock
        $fixture.json = $json
        Expect-GuardRejection { Invoke-ReviewedGuard $guard $fixture } 'Invalid reviewed package source lock.' "$workflow/missing lock fields"
    }
    $fixture = New-Fixture $sourceLock
    $fixture.json = '[' + $fixture.json + ']'
    Expect-GuardRejection { Invoke-ReviewedGuard $guard $fixture } 'Invalid reviewed package source lock.' "$workflow/array-wrapped lock"
    $fixture = New-Fixture $sourceLock
    $fixture.readFailure = $true
    Expect-GuardRejection { Invoke-ReviewedGuard $guard $fixture } 'Synthetic lock read failed.' "$workflow/unreadable lock"
    $fixture = New-Fixture $sourceLock
    $fixture.json = '{'
    $jsonError = ''
    try { $null = ConvertFrom-Json -InputObject $fixture.json -AsHashtable -ErrorAction Stop } catch { $jsonError = $_.Exception.Message }
    if (!$jsonError.StartsWith('Conversion from JSON failed with error:', [StringComparison]::Ordinal)) { throw 'Malformed JSON fixture did not reach the JSON parser.' }
    Expect-GuardRejection { Invoke-ReviewedGuard $guard $fixture } $jsonError "$workflow/malformed JSON"
    $changed = $sourceLock | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
    $changed.source_commit = 'e' * 40
    $changed.source_ref = "refs/heads/ci/tooling/$($changed.source_commit)"
    $fixture = New-Fixture $sourceLock
    $fixture.json = $changed | ConvertTo-Json -Depth 30 -Compress
    Expect-GuardRejection { Invoke-ReviewedGuard $guard $fixture } 'Reviewed package checkout differs from source lock.' "$workflow/coherently altered lock"
    Expect-GuardRejection { Assert-ReviewedPackageGuard $text $changed } 'Reviewed package checkout/admission contract differs.' "$workflow/lock cannot select verifier"
    $fixture = New-Fixture $sourceLock
    $fixture.head = 'd' * 40
    Expect-GuardRejection { Invoke-ReviewedGuard $guard $fixture } 'Reviewed package checkout differs from source lock.' "$workflow/wrong HEAD"
    $fixture = New-Fixture $sourceLock
    $fixture.remote = 'https://github.com/other/WSSCore'
    Expect-GuardRejection { Invoke-ReviewedGuard $guard $fixture } 'Reviewed package checkout repository differs.' "$workflow/wrong origin"
    foreach ($failure in @(
        @{ command = 'rev-parse HEAD'; message = 'Reviewed package HEAD query failed.' },
        @{ command = 'remote get-url origin'; message = 'Reviewed package origin query failed.' },
        @{ command = 'status --porcelain --untracked-files=all --ignored'; message = 'Reviewed package status query failed.' },
        @{ command = 'ls-files -v'; message = 'Reviewed package index query failed.' }
    )) {
        $fixture = New-Fixture $sourceLock
        $fixture.fail = $failure.command
        Expect-GuardRejection { Invoke-ReviewedGuard $guard $fixture } $failure.message "$workflow/git failure $($failure.command)"
    }
    foreach ($dirty in @(' M tracked', '?? untracked', '!! ignored')) {
        $fixture = New-Fixture $sourceLock
        $fixture.status = @($dirty)
        Expect-GuardRejection { Invoke-ReviewedGuard $guard $fixture } 'Reviewed package checkout is not pristine.' "$workflow/$dirty"
    }
    foreach ($flag in @('h assumed-unchanged', 'S skip-worktree')) {
        $fixture = New-Fixture $sourceLock
        $fixture.tracked = @($flag)
        Expect-GuardRejection { Invoke-ReviewedGuard $guard $fixture } 'Reviewed package checkout is not pristine.' "$workflow/$flag"
    }
    $contract = $contractTemplate.Replace('__CORE_COMMIT__', $sourceLock.source_commit)
    $admissionStart = $contract.IndexOf('      - name: Admit reviewed package verifier checkout')
    $setupStart = $contract.IndexOf('      - uses: actions/setup-dotnet@v4')
    $admission = $contract.Substring($admissionStart, $setupStart - $admissionStart)
    $checkout = $contract.Substring(0, $admissionStart)
    $execution = $contract.Substring($setupStart)
    $guardLine = @($admission -split [char]10 | Where-Object { $_.Contains("throw 'Invalid reviewed package source lock.'") })[0]
    foreach ($mutated in @(
        $text.Replace($contract, $admission + $checkout + $execution),
        $text.Replace($contract, $checkout + $execution + $admission),
        $text.Replace($admission, ''),
        $text.Replace($checkout, ''),
        $text.Replace('      - uses: actions/setup-dotnet@v4', ''),
        $text.Replace('      - uses: actions/setup-python@v5', ''),
        $text.Replace('        shell: pwsh', '        shell: bash'),
        $text.Replace($admission, $admission + $admission),
        $text.Replace($checkout, $checkout + $checkout),
        $text.Replace("ref: $($sourceLock.source_commit)", 'ref: ${{ steps.package-tools.outputs.commit }}'),
        $text.Replace("ref: $($sourceLock.source_commit)", ('ref: ' + ('d' * 40))),
        $text.Replace('repository: cwru-non-academic/WSSCore', 'repository: other/WSSCore'),
        $text.Replace('          persist-credentials: false', '          persist-credentials: true'),
        $text.Replace($guardLine, ('          # ' + $guardLine.Trim())),
        $text.Replace($guardLine, ('          if ($false) { ' + $guardLine.Trim() + ' }')),
        $text.Replace($guardLine, ('          $spoof = @' + "'" + [char]10 + $guardLine + [char]10 + "          '@")),
        $text.Replace('if ($LASTEXITCODE -ne 0)', 'if ($false)'),
        $text.Replace('-cne', '-ne')
    )) {
        Expect-GuardRejection { Assert-ReviewedPackageGuard $mutated $sourceLock } 'Reviewed package checkout/admission contract differs.' "$workflow/altered sequence"
    }
}
"Reviewed package guard contracts passed: $script:guardContracts. Direct checkout authority and pre-execution admission are independent of receiver lock selection."
