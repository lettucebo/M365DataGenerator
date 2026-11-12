#requires -Version 7.5
[CmdletBinding()]
param(
    [string]$CaseName = '.',
    [string]$ScratchRoot = (Join-Path $PSScriptRoot '..\.scratch')
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$script:Passed = 0; $script:Failed = 0; $script:NetworkAttempts = 0
function Invoke-RestMethod { $script:NetworkAttempts++; throw 'Integration prohibits live HTTP.' }
function Invoke-WebRequest { $script:NetworkAttempts++; throw 'Integration prohibits live HTTP.' }
function Connect-MgGraph { $script:NetworkAttempts++; throw 'Integration prohibits live authentication.' }
function Invoke-MgGraphRequest { $script:NetworkAttempts++; throw 'Integration prohibits live SDK requests.' }
function Assert-True($Value, [string]$Message = 'Assertion failed.') { if (-not $Value) { throw $Message } }
function Assert-Equal($Actual, $Expected) {
    if (($Actual | ConvertTo-Json -Depth 100 -Compress) -cne ($Expected | ConvertTo-Json -Depth 100 -Compress)) {
        throw "Expected [$Expected], got [$Actual]."
    }
}
function Assert-Throws([scriptblock]$Action, [string]$Pattern = '.') {
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_.Exception.Message }
    if ($null -eq $caught -or $caught -notmatch $Pattern) { throw "Expected '$Pattern'; received '$caught'." }
}
function Test-Case([string]$Name, [scriptblock]$Test) {
    if ($Name -notmatch $CaseName) { return }
    try { & $Test; $script:Passed++; Write-Host "PASS $Name" }
    catch { $script:Failed++; Write-Host "FAIL $Name :: $($_.Exception.Message)"; Write-Host $_.ScriptStackTrace }
}
foreach ($file in @('Seed-GraphRead','Seed-RunState','Seed-Idempotency','Connect-GraphApp',
    'Connect-GraphAdmin','Seed-Identity','Invoke-SeedPreflight','Seed-PersonaPlan',
    'Invoke-InspectUsers','Invoke-InitializePersonas','Seed-OneDriveOwnership',
    'Invoke-SeedSharePoint','Invoke-UploadFiles','Invoke-SeedEmails','Invoke-SeedTeamsChannel',
    'Seed-ResourceLinks','Seed-Console')) { . (Join-Path $root "engine\$file.ps1") }
. (Join-Path $PSScriptRoot 'Invoke-GraphStub.ps1')
if (-not ('SeedTestHost' -as [type])) {
    Add-Type -TypeDefinition (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Console.TestHost.cs') -Raw)
}
# Load only fixture function definitions, never their area test cases or top-level setup.
foreach ($area in @('Personas','Storage','Outlook','Teams','Console')) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot "$area.Tests.ps1"), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "Invalid fixture file: $area" }
    foreach ($node in $ast.EndBlock.Statements) {
        if ($node -is [Management.Automation.Language.FunctionDefinitionAst]) { . ([scriptblock]::Create($node.Extent.Text)) }
    }
}
$scratch = Join-Path ([IO.Path]::GetFullPath($ScratchRoot)) ('t8-test-only-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($scratch)
$personaScratch = $scratch; $storageScratch = $scratch; $outlookScratch = $scratch; $teamsScratch = $scratch

function New-IntegrationEnvironment([string]$Selection = 'all') {
    $e = New-PersonaTestEnvironment
    $e.Config.personas.bindingPath = Join-Path $e.Folder 'private\fixture.binding.json'
    $null = New-SeedPrivateDirectory (Split-Path $e.Config.personas.bindingPath -Parent)
    $e.ConfigPath = Join-Path $e.Folder 'config.json'
    $e.Config | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $e.ConfigPath -Encoding utf8
    Set-Content -LiteralPath (Join-Path $e.Folder 'TEST-ONLY.txt') -Value 'Synthetic offline fixture COPY. NOT portraits, NOT for release or live use.'
    $adminRecord = Get-SeedSessionRecord $e.Session
    $sdkTransport = $adminRecord.Transport
    $ctx = $e.Context; $trace = [Collections.Generic.List[string]]::new()
    $config = $e.Config; $model = $e.Model
    $adminRouter = {
        param($m,$p,$b,$raw)
        $presenterPath = '/users/' + [uri]::EscapeDataString($config.presenterUpn) + '?$select=id,userPrincipalName,accountEnabled,userType'
        if ($m -ceq 'GET' -and $p -ceq $presenterPath) {
            $model.Ledger.Add(@{ Method=$m; Path=$p; Body=$null })
            return @{ id=$model.PresenterId; userPrincipalName=$config.presenterUpn; accountEnabled=$true; userType='Member' }
        }
        & $sdkTransport $m $p $b $raw
    }.GetNewClosure()
    $e.AdminOptions = New-ConsoleAuth $e.Config $trace $adminRouter
    Close-SeedSession $e.Session
    $e.Trace = $trace
    $e.Selection = $Selection
    return $e
}
function Initialize-IntegrationPersonas($E, [switch]$Blocked, [switch]$AllowFailure) {
    $terminal = [SeedTestHost]::new()
    $terminal.Terminal.Answers.Add('')
    if (-not $Blocked) {
        $options = $E.AdminOptions
        $s = Connect-AdminSession -Config $E.Config -Mode InitializePersonas @options
        try { $preview = Get-SeedPersonaPlan -Session $s -Config $E.Config } finally { Close-SeedSession $s }
        $terminal.Terminal.Answers.Add($preview.Target)
        $terminal.Terminal.Answers.Add($preview.Fingerprint)
    }
    $terminal.Terminal.Answers.Add(''); $terminal.Terminal.Answers.CompleteAdding()
    $r = Invoke-SeedConsole -Mode InitializePersonas -ConfigPath $E.ConfigPath -ConsoleHost $terminal -InteractiveProbe { $true } -AdminOptions $E.AdminOptions
    if (-not $Blocked -and -not $AllowFailure) {
        Assert-ConsoleExit $r 0
        Assert-Equal $r.Summary.Status 'Provisioned'
        $E.Binding = Read-SeedConsoleJson $E.Config.personas.bindingPath
        Assert-Equal $E.Binding.status 'Provisioned'
        Assert-Equal $E.Binding.serviceStatus 'NotVerified'
        Assert-True (@($E.Model.Ledger | Where-Object Path -match 'mailFolders|/drive|/teams').Count -eq 0)
    }
    return $r
}
function Connect-IntegrationModels($E) {
    $storage = New-StorageEnvironment
    $outlook = New-OutlookEnvironment
    $teams = New-TeamsEnvironment
    $sr = Get-SeedSessionRecord $storage.Session
    $or = Get-SeedSessionRecord $outlook.Session
    $tr = Get-SeedSessionRecord $teams.Session
    $st = $sr.Transport; $ot = $or.Transport; $tt = $tr.Transport; $upload = $sr.UploadTransport
    foreach ($s in @($storage.Session,$outlook.Session,$teams.Session)) { Close-SeedSession $s }
    $E.Storage = $storage.Model; $E.Outlook = $outlook.Model; $E.Teams = $teams.Model
    $statePath = Join-Path $E.Folder "state\runs\$($E.Config.runId)\run-state.json"
    foreach ($m in @($E.Storage,$E.Outlook,$E.Teams)) { $m.StatePath = $statePath; $m.Ledger.Clear() }
    $scenario = Read-SeedConsoleJson (Join-Path (Split-Path $storage.PreparedPath -Parent) 'scenario.json')
    $base = Read-SeedConsoleJson (Join-Path $root 'tests\fixtures\scenario.json')
    $scenario.outlook = $base.outlook; $scenario.teams = $base.teams
    $scenario.teams.channels[0].messages[0].assetRefs = @('shared')
    $scenario.teams.channels[0].messages[0].bodyHtml += '<p><a href="{{asset:shared}}">Shared workbook</a></p>'
    if ($E.Selection -cne 'all') {
        foreach ($w in @('outlook','teams','onedrive','sharepoint')) {
            if ($w -cne $E.Selection) { $scenario.Remove($w) }
        }
        if ($E.Selection -in @('outlook','teams')) {
            $scenario.assets = @(); $scenario.Remove('workbooks')
            if ($E.Selection -eq 'outlook') {
                $scenario.outlook.threads[0].messages[0].bodyHtml = '<p>Review 12 fictional units.</p>'
                $scenario.outlook.threads[0].messages[0].assetRefs = @()
            } else {
                $scenario.teams.channels[0].messages[0].bodyHtml = '<p><at id="0">Analyst</at> review 12 fictional units.</p>'
                $scenario.teams.channels[0].messages[0].assetRefs = @()
            }
        } else {
            $scenario.assets = @($scenario.assets | Where-Object { $_.destination.workload -ceq $E.Selection })
        }
    }
    $E.PackPath = Join-Path $E.Folder 'scenario.json'
    $scenario | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $E.PackPath -Encoding utf8
    $E.Scenario = $scenario
    $ledger = [Collections.Generic.List[object]]::new()
    $E.AppLedger = $ledger
    $model = $E.Model; $presenter = $E.Config.presenterUpn
    $fault = @{ Service = $false }; $E.AppFault = $fault
    $router = {
        param($m,$p,$b,$raw)
        $ledger.Add(@{ Method=$m; Path=$p })
        if ($p -match '^/users/([^/?]+)(.*)$') {
            $id = [uri]::UnescapeDataString($Matches[1]); $tail = $Matches[2]
            if ($tail -match '^/(mailFolders|sendMail|messages/)') {
                if ($fault.Service) { throw (New-GraphStubError 404) }
                return & $ot $m $p $b $raw
            }
            if ($tail.StartsWith('/drive')) { return & $st $m $p $b $raw }
            if ($m -cne 'GET') { throw 'No normal persona writes are routed.' }
            if ($id -eq $presenter -or $id -eq $model.PresenterId) {
                return @{ id=$model.PresenterId; userPrincipalName=$presenter; displayName='Presenter'; accountEnabled=$true; userType='Member' }
            }
            if (-not $model.Users.ContainsKey($id)) {
                $known = @($model.Users.Keys | Where-Object { $model.Users[$_].Profile.userPrincipalName -ieq $id })
                if ($known.Count -ne 1) { throw (New-GraphStubError 404) }
                $id = $known[0]
            }
            $u = $model.Users[$id]
            if ($tail.StartsWith('/manager')) {
                if (-not $u.Manager) { throw (New-GraphStubError 404) }
                return @{ id=$u.Manager }
            }
            if (-not $tail.StartsWith('?')) { throw 'Unapproved offline identity path.' }
            return Copy-PersonaTestValue $u.Profile
        }
        if ($p.StartsWith('/teams')) { return & $tt $m $p $b $raw }
        if ($p -match '^/groups\?') {
            if ([uri]::UnescapeDataString($p).Contains('displayName eq')) { return & $tt $m $p $b $raw }
            return & $st $m $p $b $raw
        }
        if ($p -match '^/groups/eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee(?:/|\?|$)') { return & $tt $m $p $b $raw }
        if ($p -match '^/(groups|sites|drives)(?:/|\?|$)') { return & $st $m $p $b $raw }
        throw "Unconfigured offline integration request: $m $p"
    }.GetNewClosure()
    $uploadRouter = {
        param($url,$bytes,$headers)
        $ledger.Add(@{ Method=$(if ($null -eq $bytes) { 'GET' } else { 'PUT' }); Path='[private upload]' })
        & $upload $url $bytes $headers
    }.GetNewClosure()
    $roles = @('User.Read.All')
    foreach ($w in @('outlook','teams','onedrive','sharepoint')) {
        if ($scenario.Contains($w)) { $roles += @(Get-SeedRequiredAppRoles $w) }
    }
    if ($scenario.Contains('sharepoint') -and $scenario.assets.Count) { $roles += 'Files.ReadWrite.All' }
    $E.AppOptions = New-ConsoleAuth $E.Config $E.Trace $router @($roles | Sort-Object -Unique)
    $E.AppOptions.UploadTransport = $uploadRouter
}
function Invoke-IntegrationRun($E, [string]$Mode = 'RunAll', [switch]$WithoutConsent) {
    $args = @{ Mode=$Mode; ConfigPath=$E.ConfigPath; PackPath=$E.PackPath; NonInteractive=$true
        ConsoleHost=[SeedTestHost]::new(); AppOptions=$E.AppOptions }
    if (-not $WithoutConsent) { $args.ConfirmTarget = "$($E.Config.tenantId)/$($E.Config.runId)" }
    Invoke-SeedConsole @args
}
function Assert-IntegrationNoWrites($E) {
    Assert-Equal @($E.AppLedger | Where-Object Method -ne GET).Count 0
}
function New-ExistingIntegrationEnvironment([int]$Count = 2, [string]$PackFile = '', [string[]]$PersonaIds = @(), [string]$UpnDomain = 'example.invalid') {
    $e = New-ExistingPersonaTestEnvironment -Count $Count -PackFile $PackFile -PersonaIds $PersonaIds -UpnPrefix 'demo-' -UpnDomain $UpnDomain
    $e.Config.personas.bindingPath = Join-Path $e.Folder 'private\fixture.binding.json'
    $null = New-SeedPrivateDirectory (Split-Path $e.Config.personas.bindingPath -Parent)
    $e.ConfigPath = Join-Path $e.Folder 'config.json'
    $e.Config | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $e.ConfigPath -Encoding utf8
    $ctx = $e.Context; $trace = [Collections.Generic.List[string]]::new(); $request = (Get-SeedSessionRecord $e.Session).Transport
    $e.AdminOptions = New-ConsoleAuth $e.Config $trace $request
    Close-SeedSession $e.Session
    $e.Trace = $trace; $e.Selection = 'all'
    return $e
}
function Initialize-ExistingIntegrationPersonas($E, [switch]$AllowFailure) {
    $terminal = [SeedTestHost]::new()
    $terminal.Terminal.Answers.Add('')
    $options = $E.AdminOptions
    $s = Connect-AdminSession -Config $E.Config -Mode InitializePersonas @options
    try { $preview = Get-SeedPersonaPlan -Session $s -Config $E.Config } finally { Close-SeedSession $s }
    foreach ($answer in @($preview.Target, $preview.Fingerprint, 'DemoAccountAcknowledged', '')) { $terminal.Terminal.Answers.Add($answer) }
    $terminal.Terminal.Answers.CompleteAdding()
    $r = Invoke-SeedConsole -Mode InitializePersonas -ConfigPath $E.ConfigPath -ConsoleHost $terminal -InteractiveProbe { $true } -AdminOptions $E.AdminOptions
    if (-not $AllowFailure) {
        Assert-ConsoleExit $r 0
        Assert-Equal $r.Summary.Status 'ConfiguredExisting'
        $E.Binding = Read-SeedConsoleJson $E.Config.personas.bindingPath
        Assert-Equal $E.Binding.status 'ConfiguredExisting'; Assert-Equal $E.Binding.serviceStatus 'NotVerified'
        Assert-True (@($E.Model.Ledger | Where-Object { $_.Method -ne 'GET' -and ($_.Method -notin @('PATCH', 'PUT') -or $_.Path -notmatch '^/users/[0-9a-f-]{36}(?:/manager/\$ref)?$') }).Count -eq 0) 'Only profile and manager writes are allowed.'
        Assert-True (@($E.Model.Ledger | Where-Object Path -match 'mailFolders|/drive|/teams|subscribedSkus|/domains').Count -eq 0)
    }
    return $r
}
function Assert-IntegrationNoPersonaWrites($E) {
    Assert-True (@($E.AppLedger | Where-Object { $_.Method -ne 'GET' -and
        ($_.Path -eq '/users' -or $_.Path -match '^/users/[^/]+(?:$|/(?:photo|manager|assignLicense))') }).Count -eq 0)
}
try {
    Test-Case 'integration Initialize binding then all real adapters complete and exact second RunAll plus Verify write nothing' {
        $e = New-IntegrationEnvironment
        $init = Initialize-IntegrationPersonas $e
        Assert-Equal $init.Summary.Personas.Created 2
        Connect-IntegrationModels $e
        $pre = Invoke-IntegrationRun $e Preflight
        Assert-ConsoleExit $pre 0; Assert-IntegrationNoWrites $e
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $e.Folder 'state\runs\training01\run-state.json')))
        Assert-Equal @($pre.Summary.Plan.Workload | Sort-Object -Unique) @('onedrive','outlook','sharepoint','teams')
        $r = Invoke-IntegrationRun $e
        Assert-ConsoleExit $r 0
        Assert-Equal $r.Summary.Status 'Completed'
        Assert-Equal $r.Summary.ServiceStatus 'SelectedServicesReadBack'
        Assert-Equal $r.Summary.UiStatus 'NotVerified'
        Assert-True ($r.Summary.PresenterStatus -match 'RemoteAclNotProven')
        $state = Read-SeedConsoleJson $r.Summary.Reports.Journal
        Assert-Equal $state.status 'Completed'
        Assert-Equal @($state.results | Where-Object status -ne Verified).Count 0
        Assert-Equal $state.results.Count $pre.Summary.Plan.Count
        Assert-IntegrationNoPersonaWrites $e
        Assert-Equal @($e.Outlook.Sent.Actor | Sort-Object -Unique).Count 2
        Assert-Equal $e.Outlook.Mail[$e.Model.PresenterId].Count 2
        Assert-Equal $e.Outlook.Sent[1].Parent $e.Outlook.Sent[0].InternetMessageId
        Assert-Equal @($e.Teams.Messages.Values.from.user.id | Sort-Object -Unique).Count 2
        Assert-True $e.Teams.CompletedTeam
        Assert-Equal @($e.Teams.Members[$e.Model.PresenterId].roles) @('owner')
        Assert-Equal $e.Teams.Messages.Count 2
        $post = @($e.Teams.Messages.Values | Where-Object replyToId -eq $null)[0]
        Assert-Equal $post.mentions[0].mentioned.user.id $e.Binding.users.bob.objectId
        Assert-Equal $post.mentions[0].mentionText $e.Binding.users.bob.profile.displayName
        Assert-True (@($e.Storage.Items.Values | Where-Object { $_.ContainsKey('Bytes') }).Count -eq 2)
        Assert-True (($e.Outlook.Sent[0].Message.body.content) -match 'https://example.sharepoint.com/files/')
        Assert-True ((@($e.Teams.Messages.Values | Where-Object replyToId -eq $null)[0].body.content) -match 'https://example.sharepoint.com/files/')
        Assert-SeedResourceLinks -Links $r.Summary.ResourceLinkIndex -Scenario $e.Scenario
        foreach ($kind in @('site','documentLibrary','list','team','channel')) {
            Assert-True (@($r.Summary.ResourceLinkIndex | Where-Object kind -eq $kind).Count -gt 0) "Missing actual $kind link."
        }
        $journalHash = (Get-FileHash -LiteralPath $r.Summary.Reports.Journal).Hash
        $bindingHash = (Get-FileHash -LiteralPath $e.Config.personas.bindingPath).Hash
        $e.AppLedger.Clear()
        $again = Invoke-IntegrationRun $e
        Assert-ConsoleExit $again 0; Assert-IntegrationNoWrites $e
        foreach ($count in $again.Summary.Workloads.Values) { Assert-Equal $count.Created 0; Assert-True ($count.Skipped -gt 0) }
        $verified = Invoke-IntegrationRun $e Verify
        Assert-ConsoleExit $verified 0; Assert-IntegrationNoWrites $e
        Assert-Equal (Get-FileHash -LiteralPath $r.Summary.Reports.Journal).Hash $journalHash
        Assert-Equal (Get-FileHash -LiteralPath $e.Config.personas.bindingPath).Hash $bindingHash
        Assert-True ($again.Summary.Reports.Json -cne $r.Summary.Reports.Json)
        $evidence = Get-ChildItem -LiteralPath $e.Folder -Recurse -File | Where-Object Extension -in @('.json','.md','.txt')
        foreach ($file in $evidence) {
            $text = Get-Content -LiteralPath $file.FullName -Raw
            foreach ($value in $e.Model.InitialValues) { Assert-True (-not $text.Contains($value)) 'Initial password leaked.' }
            Assert-True ($text -notmatch 'passwordProfile|Bearer |\.offline|upload\?sig=')
        }
    }
    Test-Case 'integration selected workloads use only their own operations endpoints and application roles' {
        foreach ($selection in @('outlook','teams','onedrive','sharepoint')) {
            $e = New-IntegrationEnvironment $selection
            Initialize-IntegrationPersonas $e | Out-Null; Connect-IntegrationModels $e
            $r = Invoke-IntegrationRun $e
            Assert-ConsoleExit $r 0
            Assert-Equal @($r.Summary.Plan.Workload | Sort-Object -Unique) @($selection)
            Assert-IntegrationNoPersonaWrites $e
            if ($selection -ne 'teams') { Assert-True (@($e.AppLedger | Where-Object Path -like '/teams*').Count -eq 0) }
            if ($selection -ne 'outlook') { Assert-True (@($e.AppLedger | Where-Object Path -match '/mailFolders|/sendMail|/reply$').Count -eq 0) }
            if ($selection -notin @('onedrive','sharepoint')) { Assert-True (@($e.AppLedger | Where-Object Path -match '^/(drives|sites)/|/drive\?').Count -eq 0) }
        }
    }
    Test-Case 'integration unprovisioned services stop before content build and never repair personas' {
        $e = New-IntegrationEnvironment
        Initialize-IntegrationPersonas $e | Out-Null; Connect-IntegrationModels $e
        $e.AppFault.Service = $true
        $r = Invoke-IntegrationRun $e
        Assert-ConsoleExit $r 1
        Assert-Equal $r.Summary.ErrorCode 'Seed.Graph.404'
        Assert-IntegrationNoWrites $e
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $e.Folder 'runs\training01\prepared')))
        Assert-Equal $e.Binding.serviceStatus 'NotVerified'
    }
    Test-Case 'integration normal missing profile and drift block all workloads without initialization' {
        $e = New-IntegrationEnvironment
        Initialize-IntegrationPersonas $e | Out-Null; Connect-IntegrationModels $e
        $profile = $e.Model.Users['bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'].Profile
        $job = $profile.jobTitle; $department = $profile.department; $profile.Remove('jobTitle')
        $r = Invoke-IntegrationRun $e
        Assert-ConsoleExit $r 2; Assert-IntegrationNoWrites $e
        $profile.jobTitle = $job; $profile.department = 'Concurrent drift'
        $r = Invoke-IntegrationRun $e
        Assert-ConsoleExit $r 2; Assert-IntegrationNoWrites $e
        $profile.department = $department
        $e.Config.presenterUpn = $e.Binding.users.alice.upn
        $e.Config | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $e.ConfigPath -Encoding utf8
        $r = Invoke-IntegrationRun $e
        Assert-ConsoleExit $r 2; Assert-IntegrationNoWrites $e
        Assert-Equal $r.Summary.ErrorCode 'Seed.Binding.Identity'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $e.Folder 'runs\training01\prepared')))
    }
    Test-Case 'integration insufficient full-batch license budget blocks Initialize with no binding or writes' {
        $e = New-IntegrationEnvironment; $e.Model.Seats = 1
        $r = Initialize-IntegrationPersonas $e -Blocked
        Assert-ConsoleExit $r 2
        Assert-NoPersonaWrites $e
        Assert-True (-not (Test-Path -LiteralPath $e.Config.personas.bindingPath))
    }
    Test-Case 'integration missing fixture photo and unmanaged collision fail closed before persona writes' {
        foreach ($fault in @('Photo','Collision')) {
            $e = New-IntegrationEnvironment
            if ($fault -eq 'Photo') { Remove-Item -LiteralPath (Join-Path $e.Folder 'alice.jpg') }
            else { $e.Model.Users.foreign = @{ Profile=@{ id='ffffffff-ffff-4fff-8fff-ffffffffffff'; userPrincipalName='demo-alice@example.invalid'; userType='Member'; accountEnabled=$true } } }
            $r = Initialize-IntegrationPersonas $e -Blocked
            Assert-ConsoleExit $r 2; Assert-NoPersonaWrites $e
        }
    }
    Test-Case 'integration existing Presenter can never become managed even with matching alias' {
        $e = New-IntegrationEnvironment
        $e.Config.presenterUpn = 'demo-alice@example.invalid'
        $e.Config | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $e.ConfigPath -Encoding utf8
        $r = Initialize-IntegrationPersonas $e -Blocked
        Assert-ConsoleExit $r 2; Assert-NoPersonaWrites $e
        Assert-True (-not (Test-Path -LiteralPath $e.Config.personas.bindingPath))
    }
    Test-Case 'integration global Teams collision blocks otherwise valid Storage and Outlook before any write' {
        $e = New-IntegrationEnvironment
        Initialize-IntegrationPersonas $e | Out-Null; Connect-IntegrationModels $e
        $e.Teams.Group = @{ id='ffffffff-ffff-4fff-8fff-ffffffffffff'; displayName='Foreign collision' }
        $r = Invoke-IntegrationRun $e
        Assert-ConsoleExit $r 2; Assert-IntegrationNoWrites $e
        Assert-True (@($r.Summary.Plan | Where-Object { $_.Workload -eq 'teams' -and $_.Action -eq 'Block' }).Count -gt 0)
        Assert-True (@($r.Summary.Plan | Where-Object { $_.Workload -eq 'onedrive' -and $_.Action -eq 'Create' }).Count -gt 0)
    }
    Test-Case 'integration NonInteractive without exact approval never writes any selected workload' {
        $e = New-IntegrationEnvironment
        Initialize-IntegrationPersonas $e | Out-Null; Connect-IntegrationModels $e
        $r = Invoke-IntegrationRun $e -WithoutConsent
        Assert-ConsoleExit $r 2; Assert-IntegrationNoWrites $e
        Assert-True (@($r.Summary.Plan).Count -gt 0)
        Assert-True (-not (Test-Path -LiteralPath $e.Storage.StatePath))
    }
    Test-Case 'integration accepted mail POST lost response preserves partial storage and Unknown blocks second run' {
        $e = New-IntegrationEnvironment
        Initialize-IntegrationPersonas $e | Out-Null; Connect-IntegrationModels $e
        $e.Outlook.Fault = 'Lost'
        $r = Invoke-IntegrationRun $e
        Assert-ConsoleExit $r 3
        Assert-Equal $e.Outlook.Sent.Count 1
        Assert-Equal $e.Teams.Messages.Count 0
        $state = Read-SeedConsoleJson $e.Storage.StatePath
        Assert-Equal $state.status 'Blocked'
        Assert-Equal @($state.results | Where-Object { $_.workload -eq 'outlook' -and $_.status -eq 'Unknown' }).Count 1
        Assert-True (@($state.results | Where-Object { $_.workload -in @('onedrive','sharepoint') -and $_.status -eq 'Verified' }).Count -gt 0)
        $hash = (Get-FileHash -LiteralPath $e.Storage.StatePath).Hash
        $e.AppLedger.Clear(); $e.Outlook.Fault = ''
        $again = Invoke-IntegrationRun $e
        Assert-ConsoleExit $again 3; Assert-IntegrationNoWrites $e
        Assert-Equal $e.Outlook.Sent.Count 1
        Assert-Equal (Get-FileHash -LiteralPath $e.Storage.StatePath).Hash $hash
    }
    Test-Case 'integration unknown persona Create never publishes binding or retries submitted request' {
        $e = New-IntegrationEnvironment; $e.Model.Fault = 'UnknownCreate'
        $r = Initialize-IntegrationPersonas $e -AllowFailure
        Assert-ConsoleExit $r 3
        Assert-Equal $e.Model.Created 1
        Assert-True (-not (Test-Path -LiteralPath $e.Config.personas.bindingPath))
        $journal = $e.Config.personas.bindingPath + '.journal.json'
        $hash = (Get-FileHash -LiteralPath $journal).Hash
        $e.Model.Ledger.Clear(); $e.Model.Fault = ''
        $again = Initialize-IntegrationPersonas $e -Blocked
        Assert-ConsoleExit $again 3; Assert-NoPersonaWrites $e
        Assert-Equal (Get-FileHash -LiteralPath $journal).Hash $hash
        Assert-Equal $e.Model.Created 1
    }
    Test-Case 'integration Existing people are bound then app-only RunAll writes only content, never people, and exact rerun plus Verify write nothing' {
        $e = New-ExistingIntegrationEnvironment 2
        $init = Initialize-ExistingIntegrationPersonas $e
        Assert-Equal $init.Summary.Personas.Updated 2; Assert-Equal $init.Summary.Personas.Created 0
        Assert-Equal $e.Binding.users.Count 2
        Connect-IntegrationModels $e
        $pre = Invoke-IntegrationRun $e Preflight
        Assert-ConsoleExit $pre 0; Assert-IntegrationNoWrites $e
        $r = Invoke-IntegrationRun $e
        Assert-ConsoleExit $r 0
        Assert-Equal $r.Summary.Status 'Completed'
        Assert-IntegrationNoPersonaWrites $e
        Assert-Equal @($e.Outlook.Sent.Actor | Sort-Object -Unique).Count 2
        Assert-Equal $e.Outlook.Mail[$e.Model.PresenterId].Count 2
        Assert-Equal @($e.Teams.Messages.Values.from.user.id | Sort-Object -Unique).Count 2
        $post = @($e.Teams.Messages.Values | Where-Object replyToId -eq $null)[0]
        Assert-Equal $post.mentions[0].mentioned.user.id $e.Binding.users.bob.objectId
        Assert-Equal $post.mentions[0].mentionText $e.Binding.users.bob.profile.displayName
        Assert-Equal $e.Model.Users[$e.Model.Ids.bob].Profile.officeLocation $null
        $journalHash = (Get-FileHash -LiteralPath $r.Summary.Reports.Journal).Hash
        $bindingHash = (Get-FileHash -LiteralPath $e.Config.personas.bindingPath).Hash
        $e.AppLedger.Clear()
        $again = Invoke-IntegrationRun $e
        Assert-ConsoleExit $again 0; Assert-IntegrationNoWrites $e
        foreach ($count in $again.Summary.Workloads.Values) { Assert-Equal $count.Created 0; Assert-True ($count.Skipped -gt 0) }
        $verified = Invoke-IntegrationRun $e Verify
        Assert-ConsoleExit $verified 0; Assert-IntegrationNoWrites $e
        Assert-Equal (Get-FileHash -LiteralPath $r.Summary.Reports.Journal).Hash $journalHash
        Assert-Equal (Get-FileHash -LiteralPath $e.Config.personas.bindingPath).Hash $bindingHash
    }
    Test-Case 'integration Existing batch size is the explicit selection: one, four and the public sample pack all bind exactly their selected people' {
        foreach ($count in @(1, 4)) {
            $e = New-ExistingIntegrationEnvironment $count
            $r = Initialize-ExistingIntegrationPersonas $e
            Assert-Equal $r.Summary.Personas.Selected $count
            Assert-Equal $e.Binding.users.Count $count
            Assert-Equal @($e.Binding.users.Keys | Sort-Object) @($e.Model.Ids.Keys | Sort-Object)
        }
        $sample = Join-Path $root 'personas\m365-sample\personas.json'
        $e = New-ExistingIntegrationEnvironment -PackFile $sample -PersonaIds @('megan-bowen', 'adele-vance', 'alex-wilber')
        $r = Initialize-ExistingIntegrationPersonas $e
        Assert-Equal $r.Summary.Personas.Selected 3
        Assert-Equal @($e.Binding.users.Keys | Sort-Object) @('adele-vance', 'alex-wilber', 'megan-bowen')
        Assert-Equal $e.Binding.users.'adele-vance'.profile.managerObjectId $e.Binding.users.'megan-bowen'.objectId
        $validated = Invoke-SeedConsole -Mode Validate -PackPath (Join-Path $root 'examples\sample-minimal\scenario.json') -PersonaPackPath $sample -NonInteractive -ConsoleHost ([SeedTestHost]::new())
        Assert-ConsoleExit $validated 0
    }
    Test-Case 'integration Existing selection smaller than the Scenario blocks every workload before any content write' {
        $e = New-ExistingIntegrationEnvironment 1
        Initialize-ExistingIntegrationPersonas $e | Out-Null
        Connect-IntegrationModels $e
        $r = Invoke-IntegrationRun $e
        Assert-ConsoleExit $r 2
        Assert-Equal $r.Summary.ErrorCode 'Seed.Binding.Missing'
        Assert-IntegrationNoWrites $e
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $e.Folder 'runs\training01\prepared')))
    }
    Test-Case 'integration Existing profile drift or an absent field blocks RunAll and never repairs people' {
        $e = New-ExistingIntegrationEnvironment 2
        Initialize-ExistingIntegrationPersonas $e | Out-Null; Connect-IntegrationModels $e
        $profile = $e.Model.Users[$e.Model.Ids.bob].Profile
        $department = $profile.department; $profile.Remove('officeLocation')
        $r = Invoke-IntegrationRun $e
        Assert-ConsoleExit $r 2; Assert-IntegrationNoWrites $e
        $profile.officeLocation = $null; $profile.department = 'Concurrent drift'
        $r = Invoke-IntegrationRun $e
        Assert-ConsoleExit $r 2; Assert-IntegrationNoWrites $e
        $profile.department = $department
        $e.Model.Users[$e.Model.Ids.alice].Profile.userType = 'Guest'
        $r = Invoke-IntegrationRun $e
        Assert-ConsoleExit $r 2; Assert-IntegrationNoWrites $e
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $e.Folder 'runs\training01\prepared')))
    }
    Test-Case 'integration Existing RunAll rejects a binding whose completed journal evidence was removed or replaced by a fake Provisioned binding' {
        foreach ($fault in @('NoJournal', 'FakeProvisioned')) {
            $e = New-ExistingIntegrationEnvironment 2
            Initialize-ExistingIntegrationPersonas $e | Out-Null; Connect-IntegrationModels $e
            if ($fault -eq 'NoJournal') { Remove-Item -LiteralPath ($e.Config.personas.bindingPath + '.journal.json') }
            else { $b = Read-SeedConsoleJson $e.Config.personas.bindingPath; $b.status = 'Provisioned'; $b.version = '1.0'; $b | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $e.Config.personas.bindingPath -Encoding utf8 }
            $r = Invoke-IntegrationRun $e
            Assert-ConsoleExit $r 2; Assert-IntegrationNoWrites $e
            Assert-True ($r.Summary.ErrorCode -match '^Seed\.(Binding|Input)')
        }
    }
    Test-Case 'integration Existing corrected account: a unique alias match is proposed, confirmed and saved; the RunAll identity gate (Preflight) then passes with zero writes; a stale mapping is refused until the next Initialize saves it before login' {
        $e = New-ExistingIntegrationEnvironment 2
        $staleBytes = [IO.File]::ReadAllBytes($e.ConfigPath)
        # the same account, now under another UPN, still carries bob's public alias
        $bob = $e.Model.Users[$e.Model.Ids.bob].Profile
        $bob.userPrincipalName = 'bob.renamed@other.example.invalid'; $bob.mailNickname = 'bob'
        $options = $e.AdminOptions
        $s = Connect-AdminSession -Config $e.Config -Mode InitializePersonas @options
        try {
            $resolution = Resolve-SeedExistingAccountMappings -Session $s -Config $e.Config -Personas (Read-SeedConsoleJson $e.Config.personas.packPath)
            Assert-Equal @($resolution.Unresolved).Count 0
            Assert-Equal (@($resolution.Resolutions | Where-Object PersonaId -eq bob)[0].Method) 'UniqueExactHint'
            $preview = Get-SeedPersonaPlan -Session $s -Config $resolution.EffectiveConfig -AccountResolution $resolution
        } finally { Close-SeedSession $s }
        $terminal = [SeedTestHost]::new()
        foreach ($answer in @('', $preview.Target, $preview.Fingerprint, 'DemoAccountAcknowledged', '')) { $terminal.Terminal.Answers.Add($answer) }
        $terminal.Terminal.Answers.CompleteAdding()
        $init = Invoke-SeedConsole -Mode InitializePersonas -ConfigPath $e.ConfigPath -ConsoleHost $terminal -InteractiveProbe { $true } -AdminOptions $e.AdminOptions
        Assert-ConsoleExit $init 0
        Assert-Equal $init.Summary.Status 'ConfiguredExisting'; Assert-Equal $init.Summary.LocalConfigSync 'Saved'
        Assert-Equal (Read-SeedConsoleJson $e.ConfigPath).personas.accountMappings.bob 'bob.renamed@other.example.invalid'
        $binding = Read-SeedConsoleJson $e.Config.personas.bindingPath
        Assert-Equal $binding.users.bob.objectId $e.Model.Ids.bob; Assert-Equal $binding.users.bob.upn 'bob.renamed@other.example.invalid'
        Connect-IntegrationModels $e
        $pre = Invoke-IntegrationRun $e Preflight
        Assert-ConsoleExit $pre 0; Assert-IntegrationNoWrites $e; Assert-IntegrationNoPersonaWrites $e
        $syncedBytes = [IO.File]::ReadAllBytes($e.ConfigPath)
        [IO.File]::WriteAllBytes($e.ConfigPath, $staleBytes)
        $e.AppLedger.Clear()
        $stale = Invoke-IntegrationRun $e Preflight
        Assert-ConsoleExit $stale 2; Assert-Equal $stale.Summary.ErrorCode 'Seed.Binding.Identity'; Assert-IntegrationNoWrites $e
        $again = [SeedTestHost]::new()
        foreach ($answer in @('', '', '', '', '')) { $again.Terminal.Answers.Add($answer) }
        $again.Terminal.Answers.CompleteAdding()
        $e.Model.Ledger.Clear()
        $reinit = Invoke-SeedConsole -Mode InitializePersonas -ConfigPath $e.ConfigPath -ConsoleHost $again -InteractiveProbe { $true } -AdminOptions $e.AdminOptions
        Assert-Equal $reinit.Summary.LocalConfigSync 'Synced'
        Assert-Equal (Read-SeedConsoleJson $e.ConfigPath).personas.accountMappings.bob 'bob.renamed@other.example.invalid'
        Assert-Equal @($e.Model.Ledger | Where-Object { $_.Method -ne 'GET' -or $_.Path -match '^/users\?' }).Count 0 'The recovery must not write or search by name.'
        $e.AppLedger.Clear()
        Assert-ConsoleExit (Invoke-IntegrationRun $e Preflight) 0
        Assert-Equal (Get-FileHash -InputStream ([IO.MemoryStream]::new($syncedBytes))).Hash (Get-FileHash -LiteralPath $e.ConfigPath).Hash
    }
} finally {
    foreach ($record in @($script:SeedSessions.Values)) { Close-SeedSession $record.Handle }
    if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
}
if ($script:Passed + $script:Failed -eq 0) { $script:Failed++; Write-Host 'FAIL No integration cases selected.' }
Write-Host "RESULT Passed=$script:Passed Failed=$script:Failed Area=Integration NetworkAttempts=$script:NetworkAttempts"
if ($script:Failed -gt 0 -or $script:NetworkAttempts -gt 0) { exit 1 }
