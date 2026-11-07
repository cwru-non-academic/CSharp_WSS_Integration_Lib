# Parent-owned baseline protection. Never load this code from selected test sources.
function Assert-BaselineRegularPath([string]$Path) {
    $item=Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    while($null -ne $item){
        if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Trusted baseline contains a redirected/reparse path.'}
        $parent=[IO.Path]::GetDirectoryName($item.FullName)
        if(!$parent -or $parent -ceq $item.FullName){break}
        $item=Get-Item -LiteralPath $parent -Force -ErrorAction Stop
    }
}
function Get-TrustedBaselineInventory([string[]]$Roots) {
    $entries=[Collections.Generic.List[string]]::new()
    foreach($root in $Roots){
        $root=[IO.Path]::GetFullPath($root)
        Assert-BaselineRegularPath $root
        if(!(Get-Item -LiteralPath $root -Force).PSIsContainer){throw 'Trusted baseline root must be a directory.'}
        $queue=[Collections.Generic.Queue[string]]::new();$queue.Enqueue($root)
        while($queue.Count){
            $directory=$queue.Dequeue()
            foreach($item in Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop){
                if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Trusted baseline contains a redirected/reparse path.'}
                $relative=[IO.Path]::GetRelativePath($root,$item.FullName).Replace('\','/')
                if($item.PSIsContainer){$entries.Add("$root|D|$relative");$queue.Enqueue($item.FullName)}
                else{$hash=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256 -ErrorAction Stop).Hash;$entries.Add("$root|F|$relative|$hash")}
            }
        }
    }
    @($entries | Sort-Object -CaseSensitive)
}
function New-TrustedBaselineSnapshot([string[]]$Roots) {
    @{roots=@($Roots | ForEach-Object {[IO.Path]::GetFullPath($_)});inventory=@(Get-TrustedBaselineInventory $Roots)}
}
function Assert-TrustedBaselineSnapshot($Snapshot) {
    $current=@(Get-TrustedBaselineInventory $Snapshot.roots)
    if($current.Count -ne $Snapshot.inventory.Count){throw 'Selected suite changed trusted baseline inventory/content.'}
    for($i=0;$i -lt $current.Count;$i++){if($current[$i] -cne $Snapshot.inventory[$i]){throw 'Selected suite changed trusted baseline inventory/content.'}}
}
function Invoke-TrustedCliBaseline([hashtable]$Options,[string]$BaselineRoot) {
    $tests=$BaselineRoot+'-sources'
    Assert-CSharpTestWorkRoot $BaselineRoot @($Options.ProductRoot,$Options.IntegrationRoot,$Options.TestRoot,$Options.PayloadRoot)
    Assert-CSharpTestWorkRoot $tests @($Options.ProductRoot,$Options.IntegrationRoot,$Options.TestRoot,$Options.PayloadRoot)
    if((Test-Path -LiteralPath $BaselineRoot) -or (Test-Path -LiteralPath $tests)){throw 'Trusted CLI baseline directories must be new.'}
    # Local immutable clone, without copying checkout credentials or selected sources.
    $null=Invoke-TestBundleGit $Options.ProductRoot @('clone','--quiet','--no-hardlinks','--no-checkout',$Options.ProductRoot,$tests)
    $null=Invoke-TestBundleGit $tests @('checkout','--quiet','--detach',$Options.ProductSha)
    Assert-TestBundleCheckout $tests $Options.ProductSha
    $trusted=$Options.Clone();$trusted.TestRoot=$tests;$trusted.TestSha=$Options.ProductSha;$trusted.WorkRoot=$BaselineRoot
    Invoke-CredentialFreeSelectedPowerShell "$PSScriptRoot/Invoke-SelectedCSharpTests.ps1" $trusted
    $trxPath=Join-Path $BaselineRoot 'commands/commands.trx'
    Assert-CSharpFullTestResults $trxPath
    [xml]$trx=Get-Content -LiteralPath $trxPath -Raw
    if(@($trx.TestRun.Results.UnitTestResult).Count -ne 10){throw 'Trusted product-owned CLI baseline must contain exactly ten command tests.'}
    Assert-TestBundleCheckout $tests $Options.ProductSha
    @($BaselineRoot,$tests)
}
