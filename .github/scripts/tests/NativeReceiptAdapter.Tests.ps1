$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$path=Join-Path $PSScriptRoot '../Write-ReleaseReceipt.ps1'
$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$null,[ref]$errors)
if($errors.Count){throw 'Native receipt adapter must parse.'}
$parameters=@($ast.ParamBlock.Parameters.Name.VariablePath.UserPath)
$expected=@('TargetId','ProducerRunId','PlanId','ContextPath','WorkRoot','OutputPath')
if(@(Compare-Object $expected $parameters -CaseSensitive).Count){throw 'Adapter must expose only the common native invocation contract.'}
foreach($name in $expected){
    $parameter=@($ast.ParamBlock.Parameters | Where-Object {$_.Name.VariablePath.UserPath -ceq $name})[0]
    if($parameter.Extent.Text -cnotmatch '\[Parameter\(Mandatory\)\]'){throw "Required adapter parameter is optional: $name"}
}
$source=$ast.Extent.Text
if($source.Contains('receipt-config-') -or $source.Contains('& node') -or $source.Contains('if (!$ContextPath)')){throw 'Native adapter must not launch or reenter the common receipt engine.'}
# Execute real boundary statements up to the start of rich-proof work. All IO is stubbed.
$boundary=@()
foreach($statement in $ast.EndBlock.Statements){
    if($statement.Extent.Text.StartsWith("`$core=")){break}
    if($statement -is [Management.Automation.Language.PipelineAst] -and $statement.Extent.Text.StartsWith('. ')){continue}
    $boundary+=$statement.Extent.Text
}
$report='[pscustomobject]@{source=$AcceptedRoot;tools=$ToolsRoot;validator=$ValidatorRoot;integration=$IntegrationRoot;work=$WorkRoot;output=$OutputPath;target=$TargetId;producer=$ProducerRunId;plan=$PlanId}'
$probe=[scriptblock]::Create($ast.ParamBlock.Extent.Text+"`n"+($boundary -join "`n")+"`n"+$report)
$roles=if($source.Contains("'csharp-wrapper'")){@('csharp-wrapper','csharp-cli')}else{@('unity-wrapper','unity-gui')}
$keys=@('GITHUB_ACTIONS','GITHUB_EVENT_NAME','GITHUB_REF','GITHUB_SHA','GITHUB_REPOSITORY','GITHUB_WORKFLOW_SHA','GITHUB_WORKFLOW_REF','WSS_CI_CHANNEL')
$saved=@{};foreach($key in $keys){$saved[$key]=[Environment]::GetEnvironmentVariable($key)}
$rejections=0;$successes=0
try {
    function Get-WssCiChannel { $script:testChannel }
    function Get-WssCiChannelContext { @{ref="refs/heads/$script:testChannel"} }
    function Get-Content { param([string]$LiteralPath,[switch]$Raw) if($LiteralPath -cne 'context space λ.json'){throw 'Context path argument changed.'};$script:testJson }
    function gh { throw 'Boundary attempted GitHub access.' }
    function git { throw 'Boundary attempted Git access.' }
    function node { throw 'Boundary attempted Node execution.' }
    function New-Item { throw 'Boundary attempted filesystem mutation.' }
    foreach($channel in @('dev','main')){foreach($role in $roles){
        $script:testChannel=$channel
        $env:GITHUB_ACTIONS='true';$env:GITHUB_EVENT_NAME='workflow_dispatch';$env:GITHUB_REF="refs/heads/$channel"
        $env:GITHUB_SHA='a'*40;$env:GITHUB_REPOSITORY='example/accepted';$env:GITHUB_WORKFLOW_SHA=$env:GITHUB_SHA
        $env:GITHUB_WORKFLOW_REF="$env:GITHUB_REPOSITORY/.github/workflows/release-receipt.yml@refs/heads/$channel"
        $ctx=@{plan=@{channel=$channel};target=@{id=$role;branch=$channel;repository=$env:GITHUB_REPOSITORY};head=$env:GITHUB_SHA;pr=@{};paths=@{sourceRoot='accepted λ';toolsRoot='accepted λ';validatorRoot='frozen validator λ';integrationRoot='accepted wrapper λ';coreRoot='immutable core λ';engineRoot='immutable engine λ'}}
        $script:testJson=$ctx|ConvertTo-Json -Depth 10
        $arguments=@{TargetId=$role;ProducerRunId='123';PlanId=('b'*64);ContextPath='context space λ.json';WorkRoot='new work λ';OutputPath='output space λ.json'}
        $result=& $probe @arguments
        if($result.source -cne $ctx.paths.sourceRoot -or $result.tools -cne $ctx.paths.toolsRoot -or $result.validator -cne $ctx.paths.validatorRoot -or $result.integration -cne $ctx.paths.integrationRoot -or $result.work -cne $arguments.WorkRoot -or $result.output -cne $arguments.OutputPath -or $result.target -cne $role -or $result.producer -cne '123' -or $result.plan -cne ('b'*64)){throw 'Native boundary changed the common invocation arguments.'}
        $successes++
        foreach($mutation in @(
            {param($c)$c.plan.channel='other'}, {param($c)$c.target.branch='other'},
            {param($c)$c.target.id='other'}, {param($c)$c.head='c'*40},
            {param($c)$c.target.repository='other/repo'}
        )){
            $bad=$script:testJson|ConvertFrom-Json; & $mutation $bad
            $script:testJson=$bad|ConvertTo-Json -Depth 10
            $failed=$false;try{& $probe @arguments|Out-Null}catch{$failed=$true}
            if(!$failed){throw 'Native boundary accepted a mismatched context.'};$rejections++
            $script:testJson=$ctx|ConvertTo-Json -Depth 10
        }
        $environmentMutations=@('GITHUB_ACTIONS','GITHUB_EVENT_NAME','GITHUB_REF')
        if($channel -ceq 'main'){$environmentMutations+=@('GITHUB_WORKFLOW_SHA','GITHUB_WORKFLOW_REF')}
        foreach($key in $environmentMutations){
            $before=[Environment]::GetEnvironmentVariable($key)
            try {
                [Environment]::SetEnvironmentVariable($key,'invalid')
                $failed=$false;try{& $probe @arguments|Out-Null}catch{$failed=$true}
                if(!$failed){throw "Native boundary accepted invalid execution identity: $key"};$rejections++
            } finally {[Environment]::SetEnvironmentVariable($key,$before)}
        }
        foreach($name in @('ContextPath','WorkRoot','OutputPath')){
            $badArgs=$arguments.Clone();$badArgs[$name]=''
            $failed=$false;try{& $probe @badArgs|Out-Null}catch{$failed=$true}
            if(!$failed){throw "Native boundary accepted empty $name"};$rejections++
        }
    }}
} finally {foreach($key in $keys){[Environment]::SetEnvironmentVariable($key,$saved[$key])}}
"Native receipt adapter boundary passed ($successes role/channel positives, $rejections context/parameter rejections; no native execution)."
# Receipt execution must request authenticated snapshots, never legacy transport.
$proofCalls=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -in @('Assert-WssApproval','Assert-UnityApproval','Assert-UnityMergedGuiPreflight')},$true))
$expectedProofCalls=if($roles[0] -ceq 'csharp-wrapper'){1}else{2}
if($proofCalls.Count -ne $expectedProofCalls){throw 'Missing native receipt proof call.'}
foreach($call in $proofCalls){
 if(!@($call.CommandElements|Where-Object {$_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -ceq 'ReceiptSnapshots'}).Count){throw 'Receipt may not fall back to unbound native evidence.'}
}
if($source -cnotmatch '\$preflights=\[Collections.Generic.List\[object\]\]::new\(\)' -or $source -match 'preflights\s*\+='){throw 'Receipt must emit only collected authenticated native snapshots.'}
