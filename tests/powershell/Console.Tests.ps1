$consoleScratch = Join-Path $root ('tests\.scratch\t7-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $consoleScratch -Force | Out-Null
if (-not ('SeedTestHost' -as [type])) {
    $hostCode = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Console.TestHost.cs') -Raw
    Add-Type -TypeDefinition $hostCode
}
foreach ($file in @('Seed-OneDriveOwnership', 'Invoke-SeedSharePoint', 'Invoke-UploadFiles', 'Invoke-SeedEmails', 'Invoke-SeedTeamsChannel', 'Seed-ResourceLinks', 'Seed-Console')) {
    $path = Join-Path $root "engine\$file.ps1"
    if (Test-Path -LiteralPath $path) { . $path }
}
foreach ($fixtureArea in @('Outlook','Teams','Storage','Personas')) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot "$fixtureArea.Tests.ps1"), [ref]$tokens, [ref]$errors)
    foreach ($node in $ast.EndBlock.Statements) {
        if ($node -is [Management.Automation.Language.FunctionDefinitionAst]) { . ([scriptblock]::Create($node.Extent.Text)) }
    }
}
function New-ConsoleConfig {
    $dir = Join-Path $consoleScratch ('中文 [demo] ' + [guid]::NewGuid().ToString('N'))
    $null = [IO.Directory]::CreateDirectory($dir)
    $c = Get-Content -LiteralPath (Join-Path $root 'tests\fixtures\managed-config.json') -Raw | ConvertFrom-Json -AsHashtable
    $c.personas.packPath = Join-Path $root 'tests\fixtures\personas.json'
    $c.personas.bindingPath = 'private\training01.binding.json'
    $path = Join-Path $dir 'config [local].json'
    $c | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $path -Encoding utf8
    @{ Path = $path; Config = $c; Directory = $dir }
}
function New-ConsoleAuth($Config, $Trace, $Transport, [string[]]$Roles = @()) {
    $claims = @{ tid = $Config.tenantId; appid = $Config.clientId; aud = 'https://graph.microsoft.com'; iss = "https://sts.windows.net/$($Config.tenantId)/"; exp = [DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds(); roles = @('User.Read.All','User.ReadWrite.All','Domain.Read.All','LicenseAssignment.Read.All','Mail.Read','Mail.Send','Files.ReadWrite.All','Sites.ReadWrite.All','Group.ReadWrite.All','Team.Create','Teamwork.Migrate.All','TeamMember.ReadWrite.All','Team.ReadBasic.All','Channel.ReadBasic.All','ChannelMessage.Read.All') }
    if ($Roles.Count -gt 0) { $claims.roles = $Roles }
    $segment = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($claims | ConvertTo-Json -Compress))).TrimEnd('=').Replace('+','-').Replace('/','_')
    $value = "e30.$segment.offline"
    @{ TokenProvider = { param($t,$c,$e) $Trace.Add('Auth'); $value }.GetNewClosure(); Transport = $Transport; Delay = { param($s) } }
}
function Assert-ConsoleExit($Result, [int]$Expected) {
    if ($Result.ExitCode -ne $Expected) {
        throw "Expected exit $Expected, got $($Result.ExitCode); $($Result.Summary.ErrorCode); offline diagnostic: $($Error[0].Exception.Message) $($Error[0].ScriptStackTrace)"
    }
}
function New-ConsoleLifecycle([string]$Workload = 'Outlook', [switch]$WithAssets) {
    # Reuse the frozen adapters' offline service models without executing their test cases.
    $outlookScratch = $consoleScratch; $teamsScratch = $consoleScratch; $storageScratch = $consoleScratch
    if ($Workload -eq 'Outlook') { $e = New-OutlookEnvironment -WithAssets:$WithAssets }
    elseif ($Workload -eq 'Teams') { $e = New-TeamsEnvironment -WithAssets:$WithAssets }
    else {
        $e = New-StorageEnvironment
        $e.Model.Ids = @{ alice='aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'; bob='bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'; Presenter='cccccccc-cccc-4ccc-8ccc-cccccccccccc' }
        $e.Model.Upns = @{ $e.Model.Ids.alice='demo-alice@example.invalid'; $e.Model.Ids.bob='demo-bob@example.invalid'; $e.Model.Ids.Presenter=$e.Config.presenterUpn }
        foreach ($name in @('personas.json','alice.jpg','bob.jpg','rights.txt')) { Copy-Item -LiteralPath (Join-Path $root "tests\fixtures\$name") -Destination (Split-Path $e.PreparedPath -Parent) }
    }
    $dir = Split-Path $e.PreparedPath -Parent
    $pack = Get-Content -LiteralPath (Join-Path $dir 'personas.json') -Raw | ConvertFrom-Json -AsHashtable
    $manifest = Get-Content -LiteralPath (Join-Path $e.PreparedPath 'prepared-manifest.json') -Raw | ConvertFrom-Json -AsHashtable
    $binding = @{ tenantId=$e.Config.tenantId; packId=$pack.packId; version='1.0'; fingerprint=$manifest.personaPackFingerprint; instanceId='training01'; users=@{}; status='Provisioned'; serviceStatus='NotVerified' }
    foreach ($person in $pack.people) {
        $id = $e.Model.Ids[$person.personaId]
        $photo = @($pack.avatarAssets | Where-Object id -eq $person.avatarAssetId)[0]
        $profile = ConvertTo-SeedMap $e.Model.Profiles[$id]
        if (-not $profile.Contains('sha256')) { $profile.sha256=Get-SeedFingerprint $profile; $profile.verifiedAt='2026-10-29T00:00:00Z' }
        $binding.users[$person.personaId] = @{ objectId=$id; upn=$e.Model.Upns[$id]; profile=$profile
            photo=@{ avatarAssetId=$photo.id; sourceSha256=$photo.sha256; verifiedSha256=('a'*64); verifiedAt='2026-10-29T00:00:00Z' }
            license=@{ profileId='standard'; skuIds=$e.Config.personas.licenseProfiles.standard.skuIds; verifiedAt='2026-10-29T00:00:00Z' }
            status='Provisioned'; serviceStatus='NotVerified' }
    }
    $c = $e.Config
    $c.personas.packPath = 'personas.json'; $c.personas.bindingPath = 'binding.json'
    $binding | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath (Join-Path $dir 'binding.json')
    $c | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath (Join-Path $dir 'config.json')
    $record = Get-SeedSessionRecord $e.Session
    $trace = [Collections.Generic.List[string]]::new()
    $original = $record.Transport
    $transport = {
        param($m,$p,$b,$r)
        if ($m -ceq 'GET' -and $p -like '/users/presenter%40*') { return @{ id='cccccccc-cccc-4ccc-8ccc-cccccccccccc'; userPrincipalName='presenter@example.invalid'; accountEnabled=$true; userType='Member' } }
        & $original $m $p $b $r
    }.GetNewClosure()
    $auth = New-ConsoleAuth $c $trace $transport
    $auth.UploadTransport = $record.UploadTransport
    Close-SeedSession $e.Session
    $e.Model.Ledger.Clear()
    $e.Model.StatePath = Join-Path $dir 'state\runs\training01\run-state.json'
    @{ Model=$e.Model; Config=$c; ConfigPath=(Join-Path $dir 'config.json'); PackPath=(Join-Path $dir 'scenario.json'); Directory=$dir; Auth=$auth; Trace=$trace }
}
try {
    Test-Case 'app-only actual HTTP connector resource callbacks produce Create without callback wrapping' {
        $e = New-ConsoleLifecycle Outlook
        $provider = $e.Auth.TokenProvider; $original = $e.Auth.Transport
        $name = $e.Config.clientSecretEnvironmentVariable
        $prior = [Environment]::GetEnvironmentVariable($name,'Process')
        [Environment]::SetEnvironmentVariable($name,'offline-fixture-not-a-credential','Process')
        try {
            $send = {
                param($options)
                if ($options.Uri -like 'https://login.microsoftonline.com/*') { return @{ access_token = (& $provider) } }
                if ($options.Method -cne 'GET') { throw 'Preflight must remain read-only.' }
                $path = ([uri]$options.Uri).PathAndQuery -creplace '^/v1\.0',''
                & $original GET $path $null $null
            }.GetNewClosure()
            $r = Invoke-SeedConsole -Mode Preflight -ConfigPath $e.ConfigPath -PackPath $e.PackPath -NonInteractive -ConsoleHost ([SeedTestHost]::new()) -AppOptions @{ Send = $send }
            Assert-ConsoleExit $r 0
            Assert-True (@($r.Summary.Plan | Where-Object Action -eq Block).Count -eq 0)
            $run = Invoke-SeedConsole -Mode RunAll -ConfigPath $e.ConfigPath -PackPath $e.PackPath -NonInteractive -ConsoleHost ([SeedTestHost]::new()) -AppOptions @{ Send = $send }
            Assert-ConsoleExit $run 2
            Assert-Equal $run.Summary.ErrorCode 'Seed.Input.Confirmation'
            Assert-True (@($run.Summary.Plan | Where-Object Action -eq Create).Count -gt 0)
            Assert-Equal @($run.Summary.Plan | Where-Object Action -eq Block).Count 0
            Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count 0
        } finally { [Environment]::SetEnvironmentVariable($name,$prior,'Process') }
    }
    Test-Case 'same-client Console authenticated Outlook and Teams accept existing roles without inventing permissions' {
        $roles = @('User.Read.All', 'Mail.ReadWrite', 'Mail.Send', 'Files.ReadWrite.All', 'Sites.ReadWrite.All',
            'Group.ReadWrite.All', 'Teamwork.Migrate.All', 'TeamMember.ReadWrite.All', 'ChannelMessage.Read.All')
        foreach ($workload in @('Outlook', 'Teams')) {
            $e = New-ConsoleLifecycle $workload
            $auth = New-ConsoleAuth $e.Config $e.Trace $e.Auth.Transport $roles
            $terminal = [SeedTestHost]::new()
            $r = Invoke-SeedConsole -Mode RunAll -ConfigPath $e.ConfigPath -PackPath $e.PackPath -NonInteractive -ConfirmTarget "$($e.Config.tenantId)/training01" -ConsoleHost $terminal -AppOptions $auth
            Assert-ConsoleExit $r 0
            Assert-Equal $r.Summary.Status 'Completed'
            Assert-True (@($e.Model.Ledger | Where-Object Method -ne GET).Count -gt 0)
        }
        $e = New-ConsoleLifecycle Teams
        $auth = New-ConsoleAuth $e.Config $e.Trace $e.Auth.Transport @($roles | Where-Object { $_ -cne 'ChannelMessage.Read.All' })
        $r = Invoke-SeedConsole -Mode RunAll -ConfigPath $e.ConfigPath -PackPath $e.PackPath -NonInteractive -ConfirmTarget "$($e.Config.tenantId)/training01" -ConsoleHost ([SeedTestHost]::new()) -AppOptions $auth
        Assert-ConsoleExit $r 1
        Assert-Equal $r.Summary.ErrorCode 'Seed.Auth.Token'
        Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count 0
    }
    Test-Case 'same-client Console preserves safe structured auth diagnostics in completion and JSON report' {
        $e = New-ConsoleConfig
        $terminal = [SeedTestHost]::new()
        $terminal.Terminal.Answers.Add(''); $terminal.Terminal.Answers.Add('')
        $r = Invoke-SeedConsole -Mode InitializePersonas -ConfigPath $e.Path -ConsoleHost $terminal -InteractiveProbe { $true } -AdminOptions @{
            SdkConnect = { throw 'SECRET token=private device_code=private invalid_client AADSTS7000218 Correlation ID: dddddddd-dddd-4ddd-8ddd-dddddddddddd' }
            SdkContext = {}; SdkRequest = {}
        }
        Assert-ConsoleExit $r 1
        Assert-Equal $r.Summary.AuthDiagnostic.Stage 'SDKConnect'
        Assert-Equal $r.Summary.AuthDiagnostic.AadstsCode 'AADSTS7000218'
        $report = Get-Content -LiteralPath $r.Summary.Reports.Json -Raw
        $saved = $report | ConvertFrom-Json -AsHashtable
        Assert-Equal $saved.AuthDiagnostic $r.Summary.AuthDiagnostic
        $output = $terminal.Terminal.Lines -join "`n"
        Assert-True ($output -match 'SDKConnect' -and $output -match 'AADSTS7000218')
        Assert-True (($report + $output) -notmatch 'SECRET|token=|device_code=|private')
    }
    Test-Case 'same-client Console missing scope diagnostic ignores extras without dumping context' {
        $e = New-ConsoleConfig
        $e.Config.adminAuth.clientId = $e.Config.clientId
        $e.Config | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $e.Path
        $c = $e.Config
        $scopes = @((Get-SeedAdminScopes InitializePersonas) | Where-Object { $_ -cne 'Domain.Read.All' }) +
            @('User.Read', 'User.Read.All', 'ChannelMessage.Read.All', 'Mail.Read', 'Directory.ReadWrite.All')
        $ctx = @{ TenantId=$c.tenantId; ClientId=$c.clientId; Account=$c.adminAuth.adminOperatorUpn; AuthType='Delegated'; ContextScope='Process'; Scopes=$scopes; PrivateMetadata='SECRET' }
        $terminal = [SeedTestHost]::new()
        $terminal.Terminal.Answers.Add(''); $terminal.Terminal.Answers.Add('')
        $r = Invoke-SeedConsole -Mode InitializePersonas -ConfigPath $e.Path -ConsoleHost $terminal -InteractiveProbe { $true } -AdminOptions @{
            SdkConnect={}; SdkContext={ $ctx }.GetNewClosure(); SdkRequest={ throw 'No Graph call before scope validation.' }
        }
        Assert-ConsoleExit $r 1
        Assert-Equal $r.Summary.ErrorCode 'Seed.Auth.Scope'
        Assert-Equal $r.Summary.AuthDiagnostic.Stage 'ScopeValidation'
        Assert-Equal @($r.Summary.AuthDiagnostic.MissingScopes) @('Domain.Read.All')
        Assert-Equal @($r.Summary.AuthDiagnostic.UnexpectedScopes).Count 0
        $report = Get-Content -LiteralPath $r.Summary.Reports.Json -Raw
        Assert-True (($report + ($terminal.Terminal.Lines -join "`n")) -notmatch 'SECRET|PrivateMetadata|ContextScope|AuthType|ChannelMessage\.Read\.All|Mail\.Read|Directory\.ReadWrite\.All')
    }
    Test-Case 'Console menu rejects invalid and blank choices then zero exits without auth or wait' {
        $terminal = [SeedTestHost]::new()
        foreach ($answer in @('', '99', '0')) { $terminal.Terminal.Answers.Add($answer) }
        $r = Invoke-SeedConsole -ConsoleHost $terminal -InteractiveProbe { $true }
        Assert-Equal $r.ExitCode 0
        Assert-Equal $terminal.Terminal.Reads 3
        Assert-True (($terminal.Terminal.Lines -join "`n") -match 'RunAll')
    }
    Test-Case 'Console offline Validate never reads config SDK auth or secrets and supports personas only' {
        $terminal = [SeedTestHost]::new()
        $r = Invoke-SeedConsole -Mode Validate -PackPath (Join-Path $root 'tests\fixtures\scenario.json') -PersonaPackPath (Join-Path $root 'tests\fixtures\personas.json') -ConfigPath 'does-not-exist' -NonInteractive -ConsoleHost $terminal
        Assert-Equal $r.ExitCode 0
        Assert-Equal $r.Summary.Status 'Validated'
        $r = Invoke-SeedConsole -Mode Validate -PersonaPackPath (Join-Path $root 'tests\fixtures\personas.json') -PersonasOnly -NonInteractive -ConsoleHost $terminal
        Assert-Equal $r.ExitCode 0
        Assert-Equal $terminal.Terminal.Reads 0
    }
    Test-Case 'Console missing photos and missing scenario are input Blocked not successful or generic execution failures' {
        $terminal = [SeedTestHost]::new()
        $p = Join-Path $consoleScratch 'personas.json'
        Copy-Item -LiteralPath (Join-Path $root 'tests\fixtures\personas.json') -Destination $p
        $r = Invoke-SeedConsole -Mode Validate -PersonaPackPath $p -PersonasOnly -NonInteractive -ConsoleHost $terminal
        Assert-ConsoleExit $r 2
        Assert-Equal $r.Summary.Status 'Blocked'
        $r = Invoke-SeedConsole -Mode Validate -PersonaPackPath $p -NonInteractive -ConsoleHost $terminal
        Assert-Equal $r.ExitCode 2
    }
    Test-Case 'Console app authenticates before missing input processing and always closes authentic session' {
        $e = New-ConsoleConfig; $trace = [Collections.Generic.List[string]]::new()
        $presenter = $e.Config.presenterUpn
        $auth = New-ConsoleAuth $e.Config $trace { param($m,$p,$b,$r) @{ id='cccccccc-cccc-4ccc-8ccc-cccccccccccc'; userPrincipalName=$presenter; accountEnabled=$true; userType='Member' } }.GetNewClosure()
        $before = $script:SeedSessions.Count
        $r = Invoke-SeedConsole -Mode RunAll -ConfigPath $e.Path -PackPath 'missing scenario.json' -NonInteractive -ConsoleHost ([SeedTestHost]::new()) -AppOptions $auth
        Assert-Equal @($trace) @('Auth')
        Assert-Equal $r.ExitCode 2
        Assert-Equal $script:SeedSessions.Count $before
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $e.Directory 'state'))) 'No state before successful preflight.'
    }
    Test-Case 'Console unavailable interactive stdin rejects before auth and writes; explicit flag is not management consent' {
        $e = New-ConsoleConfig; $trace = [Collections.Generic.List[string]]::new()
        $auth = New-ConsoleAuth $e.Config $trace { throw 'No Graph expected.' }
        $r = Invoke-SeedConsole -Mode RunAll -ConfigPath $e.Path -InteractiveProbe { $false } -ConsoleHost ([SeedTestHost]::new()) -AppOptions $auth
        Assert-Equal $r.ExitCode 2; Assert-Equal $trace.Count 0
        foreach ($mode in @('InitializePersonas','InspectUsers')) {
            $r = Invoke-SeedConsole -Mode $mode -ConfigPath $e.Path -NonInteractive -ConsoleHost ([SeedTestHost]::new())
            Assert-Equal $r.ExitCode 2
        }
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $e.Directory 'state')))
    }
    Test-Case 'Console config uses literal paths and requires application credentials without inventing an operator' {
        $e = New-ConsoleConfig
        $e.Config.Remove('clientId'); $e.Config.Remove('clientSecretEnvironmentVariable'); $e.Config.adminAuth.Remove('adminOperatorUpn')
        $e.Config | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $e.Path
        $c = Read-SeedConsoleConfig -Path $e.Path -Mode InitializePersonas -PresenterUpn 'existing@example.invalid'
        Assert-Equal $c.personas.bindingPath (Join-Path $e.Directory 'private\training01.binding.json')
        Assert-True (-not $c.adminAuth.Contains('adminOperatorUpn'))
        Assert-Throws { Assert-SeedConsoleConfig -Config $c -Mode InitializePersonas } 'Seed.Input' | Out-Null
        $c.clientId = $e.Config.adminAuth.clientId; $c.clientSecretEnvironmentVariable = 'M365_DEMO_CLIENT_SECRET'
        Assert-SeedConsoleConfig -Config $c -Mode InitializePersonas
        $c.badSetting = $true
        Assert-Throws { Assert-SeedConsoleConfig -Config $c -Mode InitializePersonas } 'Seed.Input' | Out-Null
    }
    Test-Case 'app-only Console Inspect permits noninteractive readonly inventory without persona config or runId' {
        $e = New-ConsoleConfig
        foreach ($field in @('personas','runId','adminAuth')) { $e.Config.Remove($field) }
        $e.Config | ConvertTo-Json | Set-Content -LiteralPath $e.Path
        $trace = [Collections.Generic.List[string]]::new()
        $upn = $e.Config.presenterUpn
        $transport = {
            param($method,$path)
            if ($method -cne 'GET') { throw 'Unexpected write.' }
            if ($path -like '/users/presenter%40*') { return @{ id='cccccccc-cccc-4ccc-8ccc-cccccccccccc'; userPrincipalName=$upn; accountEnabled=$true; userType='Member' } }
            if ($path -like '/users?*') { return @{ value=@() } }
            throw 'Unexpected read.'
        }.GetNewClosure()
        $auth = New-ConsoleAuth $e.Config $trace $transport @('User.Read.All','Unrelated.Extra')
        $r = Invoke-SeedConsole -Mode InspectUsers -ConfigPath $e.Path -NonInteractive -ConsoleHost ([SeedTestHost]::new()) -AppOptions $auth
        Assert-ConsoleExit $r 0
        Assert-Equal $r.Summary.Status Inspected
        Assert-Equal @($trace) @('Auth')
    }
    Test-Case 'Console admin Inspect authenticates before inventory without seed app and defaults SDK client and operator' {
        $e = New-ConsoleConfig
        foreach ($key in @('clientId','clientSecretEnvironmentVariable','personas','runId','adminAuth')) { $e.Config.Remove($key) }
        $e.Config | ConvertTo-Json | Set-Content -LiteralPath $e.Path
        $trace = [Collections.Generic.List[string]]::new()
        $c = $e.Config; $client = '44444444-4444-4444-8444-444444444444'; $operatorId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
        $options = @{
            SdkConnect = { param($o) $trace.Add('Auth'); Assert-True (-not $o.ContainsKey('ClientId')) 'Use real SDK default, not an invented seed app.' }.GetNewClosure()
            SdkContext = { @{ TenantId=$c.tenantId; ClientId=$client; Account=$c.presenterUpn; AuthType='Delegated'; ContextScope='Process'; Scopes=@('User.Read.All','RoleManagement.Read.Directory') } }.GetNewClosure()
            SdkRequest = {
                param($m,$p,$b,$r)
                $trace.Add($p)
                if ($p -like '/me?*') { return @{ id=$operatorId; userPrincipalName=$c.presenterUpn } }
                if ($p -like '/roleManagement/*') { return @{ value=@(@{ principalId=$operatorId; directoryScopeId='/'; roleDefinition=@{ templateId='62e90394-69f5-4237-9190-012177145e10' } }) } }
                if ($p -like '/users?*') { return @{ value=@(@{ id=$operatorId; userPrincipalName=$c.presenterUpn; displayName='Existing'; accountEnabled=$true; userType='Member'; jobTitle=$null; department=$null; companyName=$null }) } }
                throw 'No administration writes allowed.'
            }.GetNewClosure()
        }
        $terminal = [SeedTestHost]::new(); $terminal.Terminal.Answers.Add(''); $terminal.Terminal.Answers.Add('')
        $r = Invoke-SeedConsole -Mode InspectUsers -ConfigPath $e.Path -ConsoleHost $terminal -InteractiveProbe { $true } -AdminOptions $options
        Assert-ConsoleExit $r 0
        Assert-Equal $trace[0] 'Auth'
        Assert-True (($terminal.Terminal.Lines -join "`n") -match 'NotVerified')
        Assert-Equal $r.Summary.ServiceStatus 'NotVerified'
    }
    Test-Case 'Console success and failure summaries really block in injected PSHost until Enter' {
        foreach ($status in @('Completed','Failed','Blocked','Unknown')) {
            $terminal = [SeedTestHost]::new()
            $ps = [powershell]::Create()
            $code = ". '$root\engine\Seed-GraphRead.ps1'; . '$root\engine\Seed-ResourceLinks.ps1'; . '$root\engine\Seed-Console.ps1'; Write-SeedCompletion -Summary `$args[0] -ConsoleHost `$args[1]"
            $summary = @{ Status = $status; ExitCode = 1; Mode = 'RunAll'; Workloads = @{}; ResourceLinkIndex = @(); PresenterStatus = 'NotVerified'; UiStatus = 'NotVerified'; Reports = @{} }
            $null = $ps.AddScript($code).AddArgument($summary).AddArgument($terminal)
            try {
                $pending = $ps.BeginInvoke()
                Assert-True ($terminal.Terminal.Reading.Wait(10000)) 'Completion never requested Enter.'
                Assert-True (-not $pending.IsCompleted) 'Returned before Enter.'
                Assert-True (($terminal.Terminal.Lines -join "`n") -match $status) 'Summary must precede ReadLine.'
                $terminal.Terminal.Answers.Add('')
                $null = $ps.EndInvoke($pending)
                Assert-Equal $ps.HadErrors $false
                Assert-Equal $terminal.Terminal.Reads 1
            } finally { $ps.Dispose() }
        }
    }
    Test-Case 'Console immutable JSON Markdown summaries preserve every actual site library and List URL' {
        $dir = Join-Path $consoleScratch 'summary'
        $null = New-Item -ItemType Directory -Path $dir
        $links = @(foreach ($pair in @(@('site','s'),@('documentLibrary','default'),@('documentLibrary','docs'),@('list','l'))) {
            @{ kind=$pair[0]; logicalId=$pair[1]; resourceId=$pair[1]; displayName=$pair[1]; webUrl="https://example.sharepoint.com/sites/actual/$($pair[1])"; presenterAccessStatus='StructuralVerified' }
        })
        $summary = @{ Status='Completed'; Mode='RunAll'; ResourceLinkIndex=$links; Workloads=@{}; PresenterStatus='StructuralVerified'; UiStatus='NotVerified'; ExitCode=0; Reports=@{} }
        Write-SeedSummaryFiles -Summary $summary -Directory $dir | Out-Null
        $json = Get-Content -LiteralPath (Join-Path $dir 'summary.json') -Raw | ConvertFrom-Json -AsHashtable
        $md = Get-Content -LiteralPath (Join-Path $dir 'summary.md') -Raw
        Assert-Equal $json.ResourceLinkIndex.Count 4
        foreach ($link in $links) { Assert-True ($md.Contains($link.webUrl)) }
        $hash = (Get-FileHash -LiteralPath (Join-Path $dir 'summary.json')).Hash
        Assert-Throws { Write-SeedSummaryFiles -Summary $summary -Directory $dir } 'Seed.Summary.Exists' | Out-Null
        Assert-Equal (Get-FileHash -LiteralPath (Join-Path $dir 'summary.json')).Hash $hash
    }
    Test-Case 'Console real Outlook lifecycle global journal full rerun and Verify preserve immutable evidence and zero writes' {
        $e = New-ConsoleLifecycle -WithAssets
        $args = @{ ConfigPath=$e.ConfigPath; PackPath=$e.PackPath; NonInteractive=$true; ConsoleHost=[SeedTestHost]::new(); AppOptions=$e.Auth }
        $r = Invoke-SeedConsole -Mode RunAll @args -ConfirmTarget "$($e.Config.tenantId)/training01"
        Assert-ConsoleExit $r 0
        Assert-Equal $r.Summary.Status 'Completed'
        Assert-True ($r.Summary.Workloads.outlook.Created -eq 3)
        $journalHash = (Get-FileHash -LiteralPath $e.Model.StatePath).Hash
        $reportHash = (Get-FileHash -LiteralPath $r.Summary.Reports.Json).Hash
        $e.Model.Ledger.Clear()
        $second = Invoke-SeedConsole -Mode Import @args
        Assert-Equal $second.ExitCode 0
        Assert-Equal $second.Summary.Workloads.outlook.Skipped 3
        $verify = Invoke-SeedConsole -Mode Verify @args
        Assert-Equal $verify.ExitCode 0
        Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count 0
        Assert-Equal (Get-FileHash -LiteralPath $e.Model.StatePath).Hash $journalHash
        Assert-Equal (Get-FileHash -LiteralPath $r.Summary.Reports.Json).Hash $reportHash
        Assert-True ($r.Summary.Reports.Json -cne $second.Summary.Reports.Json)
        $stream = [IO.File]::Open($e.Model.StatePath+'.active.lock','OpenOrCreate','ReadWrite','None'); $stream.Dispose()
    }
    Test-Case 'Console real Teams and Storage use same global context and correct late-bound validators' {
        $e = New-ConsoleLifecycle -Workload Teams -WithAssets
        $r = Invoke-SeedConsole -Mode RunAll -ConfigPath $e.ConfigPath -PackPath $e.PackPath -NonInteractive -ConsoleHost ([SeedTestHost]::new()) -AppOptions $e.Auth -ConfirmTarget "$($e.Config.tenantId)/training01"
        Assert-ConsoleExit $r 0
        Assert-True ($r.Summary.ResourceLinkIndex.Count -ge 3)
        Assert-True ($e.Model.CompletedTeam)
        Assert-Equal @($e.Model.Ledger | Where-Object { $_.Method -ne 'GET' -and $_.Path -match '^/users' }).Count 0
    }
    Test-Case 'Console missing or wrong confirmation never creates journal or submits writes even with NonInteractive' {
        $e = New-ConsoleLifecycle
        foreach ($target in @('', 'wrong/target')) {
            $r = Invoke-SeedConsole -Mode Import -ConfigPath $e.ConfigPath -PackPath $e.PackPath -NonInteractive -ConsoleHost ([SeedTestHost]::new()) -AppOptions $e.Auth -ConfirmTarget $target
            Assert-Equal $r.ExitCode 2
            Assert-True (-not (Test-Path -LiteralPath $e.Model.StatePath))
            Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count 0
        }
    }
    Test-Case 'Console unavailable mailbox stops before prepared build while preflight stays readonly without journal' {
        $e = New-ConsoleLifecycle
        $e.Model.Fault = 'Mailbox'
        $r = Invoke-SeedConsole -Mode RunAll -ConfigPath $e.ConfigPath -PackPath $e.PackPath -NonInteractive -ConsoleHost ([SeedTestHost]::new()) -AppOptions $e.Auth
        Assert-Equal $r.ExitCode 1
        Assert-Equal $r.Summary.Status 'Failed'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $e.Directory 'runs\training01\prepared')))
        $e.Model.Fault = ''
        $r = Invoke-SeedConsole -Mode Preflight -ConfigPath $e.ConfigPath -PackPath $e.PackPath -NonInteractive -ConsoleHost ([SeedTestHost]::new()) -AppOptions $e.Auth
        Assert-Equal $r.ExitCode 0
        Assert-True (-not (Test-Path -LiteralPath $e.Model.StatePath))
        Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count 0
    }
    Test-Case 'Console unknown or cross-workload partial stops are exit3 and never mixed Create Skip resume' {
        $e = New-ConsoleLifecycle -WithAssets
        $e.Model.Fault = 'Lost'
        $r = Invoke-SeedConsole -Mode RunAll -ConfigPath $e.ConfigPath -PackPath $e.PackPath -NonInteractive -ConsoleHost ([SeedTestHost]::new()) -AppOptions $e.Auth -ConfirmTarget "$($e.Config.tenantId)/training01"
        Assert-Equal $r.ExitCode 3
        Assert-Equal $r.Summary.Status 'Unknown'
        Assert-True ($r.Summary.Workloads.outlook.Unknown -gt 0)
        $count = @($e.Model.Ledger | Where-Object Method -ne GET).Count
        $e.Model.Fault = ''
        $r = Invoke-SeedConsole -Mode RunAll -ConfigPath $e.ConfigPath -PackPath $e.PackPath -NonInteractive -ConsoleHost ([SeedTestHost]::new()) -AppOptions $e.Auth -ConfirmTarget "$($e.Config.tenantId)/training01"
        Assert-Equal $r.ExitCode 3
        Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count $count
    }
    Test-Case 'Console Initialize requires explicit displayed fingerprint and target then renders persona counts without seed secret' {
        $personaScratch = $consoleScratch
        $e = New-PersonaTestEnvironment
        $e.Config.personas.bindingPath = Join-Path $e.Folder 'private\binding.json'
        $null = New-SeedPrivateDirectory (Join-Path $e.Folder 'private')
        $setup = Get-SeedPersonaPlan -Session $e.Session -Config $e.Config
        $record = Get-SeedSessionRecord $e.Session
        $ctx = $e.Context; $request = $record.Transport
        $admin = New-ConsoleAuth $e.Config ([Collections.Generic.List[string]]::new()) $request
        $path = Join-Path $e.Folder 'config.json'
        $e.Config | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $path
        Close-SeedSession $e.Session
        $terminal = [SeedTestHost]::new()
        foreach ($answer in @('', $setup.Target, 'incorrect', '')) { $terminal.Terminal.Answers.Add($answer) }
        $r = Invoke-SeedConsole -Mode InitializePersonas -ConfigPath $path -ConsoleHost $terminal -InteractiveProbe { $true } -AdminOptions $admin
        Assert-Equal $r.ExitCode 2
        Assert-Equal $e.Model.Created 0
        $terminal = [SeedTestHost]::new()
        foreach ($answer in @('', $setup.Target, $setup.Fingerprint, '')) { $terminal.Terminal.Answers.Add($answer) }
        $r = Invoke-SeedConsole -Mode InitializePersonas -ConfigPath $path -ConsoleHost $terminal -InteractiveProbe { $true } -AdminOptions $admin
        Assert-ConsoleExit $r 0
        Assert-Equal $r.Summary.Personas.Created 2
        Assert-True (($terminal.Terminal.Lines -join "`n") -match 'Created=2')
        Assert-True ((Get-Content -LiteralPath $r.Summary.Reports.Markdown -Raw) -match 'Created=2')
        Assert-Equal $r.Summary.ServiceStatus 'NotVerified'
        Assert-Equal $terminal.Terminal.Reads 4
    }
    Test-Case 'Console prepared transformed local asset uses selected source for readiness and prepared scenario for adapters' {
        $e = New-ConsoleLifecycle -WithAssets
        $s = Read-SeedConsoleJson $e.PackPath
        $s.Remove('workbooks'); $s.assets[0].Remove('workbookId')
        $s.assets[0].localPath='source notes.txt'; $s.assets[0].mediaType='text/plain'; $s.assets[0].destination.name='notes.txt'
        $source = Join-Path $e.Directory 'source notes.txt'; [IO.File]::WriteAllText($source, 'Original source for deterministic preparation.')
        $s.assets[0].sha256 = (Get-FileHash -LiteralPath $source).Hash.ToLowerInvariant()
        $s | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $e.PackPath
        $r = Invoke-SeedConsole -Mode RunAll -ConfigPath $e.ConfigPath -PackPath $e.PackPath -NonInteractive -ConsoleHost ([SeedTestHost]::new()) -AppOptions $e.Auth -ConfirmTarget "$($e.Config.tenantId)/training01"
        Assert-ConsoleExit $r 0
        $prepared = Read-SeedConsoleJson (Join-Path $r.Summary.Reports.Prepared 'scenario.json')
        Assert-True ($prepared.assets[0].localPath -cne $s.assets[0].localPath)
    }
    Test-Case 'Console actual SharePoint site default explicit library and Lists appear in JSON Markdown and console' {
        $e = New-ConsoleLifecycle -Workload Storage
        $terminal = [SeedTestHost]::new()
        $r = Invoke-SeedConsole -Mode RunAll -ConfigPath $e.ConfigPath -PackPath $e.PackPath -NonInteractive -ConsoleHost $terminal -AppOptions $e.Auth -ConfirmTarget "$($e.Config.tenantId)/training01"
        Assert-ConsoleExit $r 0
        Assert-Equal $r.Summary.ResourceLinkIndex.Count 4
        $json = Read-SeedConsoleJson $r.Summary.Reports.Json
        $md = Get-Content -LiteralPath $r.Summary.Reports.Markdown -Raw
        Assert-Equal $json.ResourceLinkIndex.Count 4
        foreach ($link in $json.ResourceLinkIndex) {
            Assert-True ($md.Contains($link.webUrl))
            Assert-True (($terminal.Terminal.Lines -join "`n").Contains($link.webUrl))
        }
        Assert-True ($r.Summary.PresenterStatus -match 'RemoteAclNotProven')
    }
    Test-Case 'Console offline invalid input displays structured path code message remediation before completion' {
        $terminal = [SeedTestHost]::new()
        $r = Invoke-SeedConsole -Mode Validate -PackPath 'missing scenario' -PersonaPackPath 'missing personas' -NonInteractive -ConsoleHost $terminal
        Assert-Equal $r.ExitCode 2
        foreach ($key in @('path','code','message','remediation')) { Assert-True (($terminal.Terminal.Lines -join "`n") -match $key) }
    }
    Test-Case 'Console Outlook-only accepts only selected roles and SharePoint upload requires actual Files role before build' {
        $e = New-ConsoleLifecycle
        $auth = New-ConsoleAuth $e.Config $e.Trace $e.Auth.Transport @('User.Read.All','Mail.Read','Mail.Send')
        $r = Invoke-SeedConsole -Mode Preflight -ConfigPath $e.ConfigPath -PackPath $e.PackPath -NonInteractive -ConsoleHost ([SeedTestHost]::new()) -AppOptions $auth
        Assert-ConsoleExit $r 0
        $e = New-ConsoleLifecycle -Workload Storage
        $s = Read-SeedConsoleJson $e.PackPath
        $s.Remove('onedrive'); $s.assets = @($s.assets | Where-Object { $_.destination.workload -eq 'sharepoint' })
        $s | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $e.PackPath
        $auth = New-ConsoleAuth $e.Config $e.Trace $e.Auth.Transport @('User.Read.All','Sites.ReadWrite.All','Group.ReadWrite.All')
        $auth.UploadTransport = $e.Auth.UploadTransport
        $r = Invoke-SeedConsole -Mode Preflight -ConfigPath $e.ConfigPath -PackPath $e.PackPath -NonInteractive -ConsoleHost ([SeedTestHost]::new()) -AppOptions $auth
        Assert-Equal $r.ExitCode 1
        Assert-Equal $r.Summary.ErrorCode 'Seed.Auth.Token'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $e.Directory 'runs\training01\prepared')))
    }
    Test-Case 'Console global resource Block prevents other workload creates and new journal' {
        $e = New-ConsoleLifecycle -WithAssets; $e.Model.Fault='Pagination'
        $r = Invoke-SeedConsole -Mode RunAll -ConfigPath $e.ConfigPath -PackPath $e.PackPath -NonInteractive -ConsoleHost ([SeedTestHost]::new()) -AppOptions $e.Auth -ConfirmTarget "$($e.Config.tenantId)/training01"
        Assert-ConsoleExit $r 2
        Assert-True (@($r.Summary.Plan | Where-Object { $_.Workload -ceq 'onedrive' -and $_.Action -ceq 'Create' }).Count -gt 0)
        Assert-True (@($r.Summary.Plan | Where-Object Action -eq Block).Count -gt 0)
        Assert-True (-not (Test-Path -LiteralPath $e.Model.StatePath))
        Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count 0
    }
    Test-Case 'Console interactive Import requires exact target after preview and waits once after rejection' {
        $e = New-ConsoleLifecycle; $terminal=[SeedTestHost]::new()
        foreach ($answer in @('', 'wrong/target', '')) { $terminal.Terminal.Answers.Add($answer) }
        $r = Invoke-SeedConsole -Mode Import -ConfigPath $e.ConfigPath -PackPath $e.PackPath -ConsoleHost $terminal -InteractiveProbe { $true } -AppOptions $e.Auth
        Assert-ConsoleExit $r 2
        Assert-Equal $terminal.Terminal.Reads 3
        Assert-True (-not (Test-Path -LiteralPath $e.Model.StatePath))
        Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count 0
    }
    Test-Case 'Console public entry executes offline personas-only alias and returns exit2 with summary for invalid Mode' {
        $pwsh = (Get-Process -Id $PID).Path
        $output = & $pwsh -NoProfile -File (Join-Path $root 'Invoke-M365Demo.ps1') -Mode Validate --personas-only -PersonaPackPath (Join-Path $root 'tests\fixtures\personas.json') -NonInteractive
        Assert-Equal $LASTEXITCODE 0
        Assert-True (($output -join "`n") -match '\[Validated\]')
        $output = & $pwsh -NoProfile -File (Join-Path $root 'Invoke-M365Demo.ps1') -Mode Invalid -NonInteractive
        Assert-Equal $LASTEXITCODE 2
        Assert-True (($output -join "`n") -match '\[Blocked\]')
    }
    Test-Case 'Console immediately authenticates even when selected scenario JSON is malformed' {
        $e=New-ConsoleConfig; $trace=[Collections.Generic.List[string]]::new()
        $path=Join-Path $e.Directory 'broken.json'; [IO.File]::WriteAllText($path,'{broken')
        $presenter=$e.Config.presenterUpn
        $auth=New-ConsoleAuth $e.Config $trace { param($m,$p,$b,$r) @{ id='cccccccc-cccc-4ccc-8ccc-cccccccccccc'; userPrincipalName=$presenter; accountEnabled=$true; userType='Member' } }.GetNewClosure()
        $r=Invoke-SeedConsole -Mode RunAll -ConfigPath $e.Path -PackPath $path -NonInteractive -ConsoleHost ([SeedTestHost]::new()) -AppOptions $auth
        Assert-Equal @($trace) @('Auth')
        Assert-ConsoleExit $r 2
    }
    Test-Case 'Console Initialize missing photo is structured input Blocked after auth not generic Python failure' {
        $personaScratch=$consoleScratch; $e=New-PersonaTestEnvironment
        $e.Config.personas.bindingPath=Join-Path $e.Folder 'private\binding.json'
        $record=Get-SeedSessionRecord $e.Session; $ctx=$e.Context; $request=$record.Transport
        $trace=[Collections.Generic.List[string]]::new()
        $admin=New-ConsoleAuth $e.Config $trace $request
        Close-SeedSession $e.Session
        $path=Join-Path $e.Folder 'config.json'; $e.Config | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $path
        Remove-Item -LiteralPath (Join-Path $e.Folder 'alice.jpg')
        $terminal=[SeedTestHost]::new(); $terminal.Terminal.Answers.Add(''); $terminal.Terminal.Answers.Add('')
        $r=Invoke-SeedConsole -Mode InitializePersonas -ConfigPath $path -ConsoleHost $terminal -InteractiveProbe { $true } -AdminOptions $admin
        Assert-ConsoleExit $r 2
        Assert-Equal @($trace) @('Auth')
        Assert-Equal $r.Summary.ErrorCode 'Seed.Input.Validation'
        Assert-Equal $e.Model.Created 0
        Assert-True (-not (Test-Path -LiteralPath $e.Config.personas.bindingPath))
    }
    Test-Case 'Console corrupt journal cannot escape centralized unknown summary or authorize writes' {
        $e=New-ConsoleLifecycle
        $null=New-SeedPrivateDirectory (Split-Path $e.Model.StatePath -Parent)
        [IO.File]::WriteAllText($e.Model.StatePath,'{"results":[{}],"status":"Running"}')
        $r=Invoke-SeedConsole -Mode RunAll -ConfigPath $e.ConfigPath -PackPath $e.PackPath -NonInteractive -ConsoleHost ([SeedTestHost]::new()) -AppOptions $e.Auth -ConfirmTarget "$($e.Config.tenantId)/training01"
        Assert-ConsoleExit $r 3
        Assert-Equal $r.Summary.Status 'Unknown'
        Assert-True ($r.Summary.Workloads.outlook.Unknown -gt 0)
        Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count 0
    }
    Test-Case 'Console failure preserves actual already read-back SharePoint resource links in both summaries' {
        $e=New-ConsoleLifecycle -Workload Storage; $e.Model.Fault='Fields'
        $r=Invoke-SeedConsole -Mode RunAll -ConfigPath $e.ConfigPath -PackPath $e.PackPath -NonInteractive -ConsoleHost ([SeedTestHost]::new()) -AppOptions $e.Auth -ConfirmTarget "$($e.Config.tenantId)/training01"
        Assert-ConsoleExit $r 3
        Assert-Equal $r.Summary.ResourceLinkIndex.Count 4
        $json=Read-SeedConsoleJson $r.Summary.Reports.Json
        $md=Get-Content -LiteralPath $r.Summary.Reports.Markdown -Raw
        Assert-Equal $json.ResourceLinkIndex.Count 4
        foreach($link in $json.ResourceLinkIndex) { Assert-True ($md.Contains($link.webUrl)) }
    }
    Test-Case 'Console blocked Completed-run readback never reports historical receipts as newly Created' {
        $e=New-ConsoleLifecycle
        $args=@{ ConfigPath=$e.ConfigPath; PackPath=$e.PackPath; NonInteractive=$true; ConsoleHost=[SeedTestHost]::new(); AppOptions=$e.Auth }
        $r=Invoke-SeedConsole -Mode RunAll @args -ConfirmTarget "$($e.Config.tenantId)/training01"
        Assert-ConsoleExit $r 0
        $e.Model.Ledger.Clear(); $e.Model.Fault='Author'
        $r=Invoke-SeedConsole -Mode Import @args
        Assert-ConsoleExit $r 2
        Assert-Equal $r.Summary.Workloads.outlook.Created 0
        Assert-True ($r.Summary.Workloads.outlook.Blocked -gt 0)
        Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count 0
    }
    Test-Case 'Console missing production app credential environment is configuration Blocked before network' {
        $e=New-ConsoleConfig
        $e.Config.clientSecretEnvironmentVariable='T7_UNSET_' + [guid]::NewGuid().ToString('N')
        $e.Config | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $e.Path
        $before=$script:NetworkAttempts
        $r=Invoke-SeedConsole -Mode RunAll -ConfigPath $e.Path -NonInteractive -ConsoleHost ([SeedTestHost]::new())
        Assert-ConsoleExit $r 2
        Assert-Equal $script:NetworkAttempts $before
    }
    function New-ConsoleExistingInit([int]$Count = 3) {
        $personaScratch = $consoleScratch
        $e = New-ExistingPersonaTestEnvironment -Count $Count
        $e.Config.personas.bindingPath = Join-Path $e.Folder 'private\binding.json'
        $null = New-SeedPrivateDirectory (Join-Path $e.Folder 'private')
        $setup = Get-SeedPersonaPlan -Session $e.Session -Config $e.Config
        $e.Target = $setup.Target; $e.Fingerprint = $setup.Fingerprint; $e.Planned = $e.Model.Ledger.Count
        $record = Get-SeedSessionRecord $e.Session; $ctx = $e.Context; $request = $record.Transport
        $e.Admin = New-ConsoleAuth $e.Config ([Collections.Generic.List[string]]::new()) $request
        $e.Path = Join-Path $e.Folder 'config.json'
        $e.Config | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $e.Path
        Close-SeedSession $e.Session
        $e.Model.Ledger.Clear()
        return $e
    }
    Test-Case 'Console Existing Initialize renders the shared warning once, needs a typed acknowledgement, writes only allowed effects and reports only the safe projection' {
        $e = New-ConsoleExistingInit 3
        foreach ($attempt in @('wrong-target', 'wrong-fingerprint', 'no-acknowledgement')) {
            $terminal = [SeedTestHost]::new()
            $answers = switch ($attempt) {
                'wrong-target' { @('', 'incorrect', $e.Fingerprint, 'DemoAccountAcknowledged', '') }
                'wrong-fingerprint' { @('', $e.Target, ('0' * 64), 'DemoAccountAcknowledged', '') }
                'no-acknowledgement' { @('', $e.Target, $e.Fingerprint, 'yes', '') }
            }
            foreach ($answer in $answers) { $terminal.Terminal.Answers.Add($answer) }
            $r = Invoke-SeedConsole -Mode InitializePersonas -ConfigPath $e.Path -ConsoleHost $terminal -InteractiveProbe { $true } -AdminOptions $e.Admin
            Assert-Equal $r.ExitCode 2
            Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count 0
            Assert-True (-not (Test-Path -LiteralPath $e.Config.personas.bindingPath))
            Assert-True (($terminal.Terminal.Lines -join "`n") -notmatch '\[ConfiguredExisting\]|Configured=')
            Assert-Equal $terminal.Terminal.Reads 5
        }
        $terminal = [SeedTestHost]::new()
        foreach ($answer in @('', $e.Target, $e.Fingerprint, 'DemoAccountAcknowledged', '')) { $terminal.Terminal.Answers.Add($answer) }
        $r = Invoke-SeedConsole -Mode InitializePersonas -ConfigPath $e.Path -ConsoleHost $terminal -InteractiveProbe { $true } -AdminOptions $e.Admin
        Assert-ConsoleExit $r 0
        Assert-Equal $r.Summary.Status 'ConfiguredExisting'; Assert-Equal $r.Summary.Personas.Updated 3; Assert-Equal $r.Summary.Personas.Created 0
        $text = $terminal.Terminal.Lines -join "`n"
        Assert-Equal ([regex]::Matches($text, [regex]::Escape('[Warning] 將修改既有 Microsoft 365 使用者的 profile／主管關係。'))).Count 1
        Assert-True ($text -match 'Updated=3' -and $text -notmatch '"Inventory"|OperatorId')
        $files = @(Get-Content -LiteralPath $r.Summary.Reports.Json -Raw) + @(Get-Content -LiteralPath $r.Summary.Reports.Markdown -Raw)
        foreach ($forbidden in @('existing-alice', 'existing-bob', 'Old title', 'External Boss', 'external-boss')) { Assert-True (-not (($files -join "`n").Contains($forbidden))) "Report leaked $forbidden" }
        Assert-Equal @($r.Summary.PersonaPreview.People.PersonaId | Sort-Object) @('alice', 'bob', 'carol')
        $writes = @($e.Model.Ledger | Where-Object Method -ne GET)
        Assert-True ($writes.Count -ge 3 -and @($writes | Where-Object { $_.Method -notin @('PATCH', 'PUT') -or $_.Path -match 'photo|assignLicense|^/users$' }).Count -eq 0)
    }
    Test-Case 'Console Existing Initialize with a blocked account offers no confirmation and never writes' {
        $e = New-ConsoleExistingInit 3
        $e.Model.Users[$e.Model.Ids.carol].Profile.userType = 'Guest'
        $terminal = [SeedTestHost]::new()
        foreach ($answer in @('', '')) { $terminal.Terminal.Answers.Add($answer) }
        $r = Invoke-SeedConsole -Mode InitializePersonas -ConfigPath $e.Path -ConsoleHost $terminal -InteractiveProbe { $true } -AdminOptions $e.Admin
        Assert-ConsoleExit $r 2
        Assert-Equal $r.Summary.ErrorCode 'Seed.Persona.Blocked'
        Assert-Equal $terminal.Terminal.Reads 2 'Only the Presenter prompt and the final Enter may be read.'
        Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count 0
        $text = $terminal.Terminal.Lines -join "`n"
        Assert-True ($text -match '\[Blocked\] persona=carol reason=Seed\.Persona\.Identity' -and $text -cnotmatch 'Enter exact|DemoAccountAcknowledged|ConfiguredExisting') "Unexpected output: $text"
    }
    Test-Case 'Console Existing Initialize treats role-bearing selected accounts like any other and states what the typed acknowledgement means without a PIM or non-administrator claim' {
        $e = New-ConsoleExistingInit 3
        $e.Model.Roles[$e.Model.Ids.alice] = @{ roleAssignments = @(@{ principalId = $e.Model.Ids.alice; roleDefinitionId = 'x'; directoryScopeId = '/' }) }
        $e.Model.Roles[$e.Model.Ids.carol] = @{ roleEligibilityScheduleInstances = @(@{ principalId = $e.Model.Ids.carol; roleDefinitionId = 'x'; directoryScopeId = '/' }) }
        $terminal = [SeedTestHost]::new()
        foreach ($answer in @('', $e.Target, $e.Fingerprint, 'DemoAccountAcknowledged', '')) { $terminal.Terminal.Answers.Add($answer) }
        $r = Invoke-SeedConsole -Mode InitializePersonas -ConfigPath $e.Path -ConsoleHost $terminal -InteractiveProbe { $true } -AdminOptions $e.Admin
        Assert-ConsoleExit $r 0
        Assert-Equal $r.Summary.Status 'ConfiguredExisting'; Assert-Equal $r.Summary.Personas.Updated 3
        $text = $terminal.Terminal.Lines -join "`n"
        Assert-True ($text -notmatch 'PIM|non-administrative|非管理') 'The typed prompt and renderer must not claim anything about PIM or non-administrator accounts.'
        Assert-True ($text -cmatch 'directory roles are neither checked nor changed' -and $text -cmatch 'Type DemoAccountAcknowledged to continue') 'The acknowledgement must say what it approves.'
        Assert-True (-not $r.Summary.PersonaPreview.Contains('PimGroupEligibility'))
        Assert-Equal @($e.Model.Ledger | Where-Object { $_.Path -match 'transitiveMemberOf|roleEligibilitySchedule' }).Count 0
    }
    function Get-ConsoleExistingCorrectedPlan($E, $Selection) {
        # The exact target/fingerprint the operator would be shown for the corrected batch, from a separate read-only setup session.
        $options = $E.Admin
        $s = Connect-AdminSession -Config $E.Config -Mode InitializePersonas @options
        try {
            $pack = Get-Content -LiteralPath $E.Config.personas.packPath -Raw | ConvertFrom-Json -AsHashtable
            $resolution = Resolve-SeedExistingAccountMappings -Session $s -Config $E.Config -Personas $pack -Selection $Selection
            Get-SeedPersonaPlan -Session $s -Config $resolution.EffectiveConfig -AccountResolution $resolution
        } finally { Close-SeedSession $s }
    }
    Test-Case 'Console Existing Initialize asks ONE local account selection before and separate from the confirmation, keeps candidates out of every report, saves the corrected mapping and the next run needs none' {
        $e = New-ConsoleExistingInit 3
        $x = '10101010-1010-4010-8010-101010101010'
        $e.Model.Users.Remove($e.Model.Ids.bob)
        Add-ExistingDirectoryUser $e $x 'bobby@other.example.invalid' 'Bobby Tester'
        $corrected = Get-ConsoleExistingCorrectedPlan $e @{ bob = @{ Method = 'UserSelectedCandidate'; ObjectId = $x } }
        $before = Get-Content -LiteralPath $e.Path -Raw | ConvertFrom-Json -AsHashtable
        $e.Model.Ledger.Clear()
        $terminal = [SeedTestHost]::new()
        foreach ($answer in @('', '1', $corrected.Target, $corrected.Fingerprint, 'DemoAccountAcknowledged', '')) { $terminal.Terminal.Answers.Add($answer) }
        $r = Invoke-SeedConsole -Mode InitializePersonas -ConfigPath $e.Path -ConsoleHost $terminal -InteractiveProbe { $true } -AdminOptions $e.Admin
        Assert-ConsoleExit $r 0
        Assert-Equal $r.Summary.Status 'ConfiguredExisting'; Assert-Equal $r.Summary.LocalConfigSync 'Saved'; Assert-Equal $r.Summary.Personas.Updated 3
        Assert-Equal $terminal.Terminal.Reads 6 'Presenter, one selection, target, fingerprint, acknowledgement and the final Enter.'
        $lines = $terminal.Terminal.Lines.ToArray(); $text = $lines -join "`n"
        $select = [Array]::FindIndex($lines, [Predicate[string]]{ param($l) $l.StartsWith('[AccountSelection]') })
        $setup = [Array]::FindIndex($lines, [Predicate[string]]{ param($l) $l.StartsWith('[PersonaSetup] Source=Existing') })
        $ask = [Array]::FindIndex($lines, [Predicate[string]]{ param($l) $l.StartsWith('Enter exact tenantId/instanceId') })
        Assert-True ($select -ge 0 -and $select -lt $setup -and $setup -lt $ask) 'The account selection must come before, and separate from, the batch preview and confirmation.'
        Assert-Equal @($lines | Where-Object { $_.StartsWith('Enter a candidate number') }).Count 1
        Assert-True ($text -match '\[PersonaDetail\]   1\) Bobby Tester <bobby@other\.example\.invalid> \[Prefix\]')
        Assert-True ($text -match 'account: existing-bob@example\.invalid → bobby@other\.example\.invalid via UserSelectedCandidate')
        $files = @(Get-Content -LiteralPath $r.Summary.Reports.Json -Raw) + @(Get-Content -LiteralPath $r.Summary.Reports.Markdown -Raw)
        foreach ($forbidden in @('bobby@other', 'Bobby Tester', $x, 'existing-bob')) { Assert-True (-not (($files -join "`n").Contains($forbidden))) "A report leaked $forbidden" }
        Assert-Equal @($r.Summary.PersonaPreview.People | Where-Object PersonaId -eq bob)[0].ResolutionMethod 'UserSelectedCandidate'
        $after = Get-Content -LiteralPath $e.Path -Raw | ConvertFrom-Json -AsHashtable
        Assert-Equal $after.personas.accountMappings.bob 'bobby@other.example.invalid'; Assert-Equal $after.personas.accountMappings.alice $before.personas.accountMappings.alice
        $left = Copy-PersonaTestValue $before; $left.personas.Remove('accountMappings'); $right = Copy-PersonaTestValue $after; $right.personas.Remove('accountMappings')
        Assert-Equal (Get-SeedFingerprint $left) (Get-SeedFingerprint $right) 'Only accountMappings may change in the private config.'
        $binding = Get-Content -LiteralPath $e.Config.personas.bindingPath -Raw | ConvertFrom-Json -AsHashtable
        Assert-Equal $binding.users.bob.objectId $x; Assert-Equal $binding.users.bob.upn 'bobby@other.example.invalid'
        $writes = @($e.Model.Ledger | Where-Object Method -ne GET)
        Assert-True ($writes.Count -ge 3 -and @($writes | Where-Object { $_.Method -notin @('PATCH', 'PUT') -or $_.Path -match 'photo|assignLicense|^/users$' }).Count -eq 0)
    }
    Test-Case 'Console Existing Initialize stops with zero writes when the one local selection is cancelled or unrecognised and never reaches the confirmation' {
        foreach ($answer in @('', 'maybe', '9', 'replace:not-a-upn')) {
            $e = New-ConsoleExistingInit 3
            $e.Model.Users.Remove($e.Model.Ids.bob)
            Add-ExistingDirectoryUser $e '10101010-1010-4010-8010-101010101010' 'bobby@other.example.invalid' 'Bobby Tester'
            $terminal = [SeedTestHost]::new()
            foreach ($typed in @('', $answer, '')) { $terminal.Terminal.Answers.Add($typed) }
            $r = Invoke-SeedConsole -Mode InitializePersonas -ConfigPath $e.Path -ConsoleHost $terminal -InteractiveProbe { $true } -AdminOptions $e.Admin
            Assert-ConsoleExit $r 2
            Assert-Equal $r.Summary.ErrorCode 'Seed.Persona.Selection'
            Assert-Equal $terminal.Terminal.Reads 3 'Only the Presenter prompt, the single selection answer and the final Enter may be read.'
            Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count 0
            Assert-True (-not (Test-Path -LiteralPath $e.Config.personas.bindingPath))
            Assert-True (($terminal.Terminal.Lines -join "`n") -cnotmatch 'Enter exact|DemoAccountAcknowledged|\[PersonaSetup\]')
        }
    }
    Test-Case 'Console Existing Initialize reports LocalConfigSyncRequired when the private config changed during the run, never replays the remote update, and the next run saves the proven mapping before login' {
        $e = New-ConsoleExistingInit 3
        $x = '10101010-1010-4010-8010-101010101010'
        $e.Model.Users.Remove($e.Model.Ids.bob)
        Add-ExistingDirectoryUser $e $x 'bobby@other.example.invalid' 'Bobby Tester'
        $corrected = Get-ConsoleExistingCorrectedPlan $e @{ bob = @{ Method = 'UserSelectedCandidate'; ObjectId = $x } }
        $configPath = $e.Path; $touched = @{ Done = $false }
        $e.Model.AfterWrite = { param($m, $p) if (-not $touched.Done) { $touched.Done = $true; Add-Content -LiteralPath $configPath -Value ' ' } }.GetNewClosure()
        $e.Model.Ledger.Clear()
        $terminal = [SeedTestHost]::new()
        foreach ($answer in @('', '1', $corrected.Target, $corrected.Fingerprint, 'DemoAccountAcknowledged', '')) { $terminal.Terminal.Answers.Add($answer) }
        $r = Invoke-SeedConsole -Mode InitializePersonas -ConfigPath $e.Path -ConsoleHost $terminal -InteractiveProbe { $true } -AdminOptions $e.Admin
        Assert-Equal $r.ExitCode 3; Assert-Equal $r.Summary.Status 'LocalConfigSyncRequired'; Assert-Equal $r.Summary.LocalConfigSync 'LocalConfigSyncRequired'; Assert-Equal $r.Summary.ErrorCode 'Seed.Persona.ConfigSync'
        Assert-Equal $r.Summary.Personas.Updated 3
        $journal = Get-Content -LiteralPath ($e.Config.personas.bindingPath + '.journal.json') -Raw | ConvertFrom-Json -AsHashtable
        Assert-Equal $journal.status 'Completed'; Assert-True (Test-Path -LiteralPath $e.Config.personas.bindingPath)
        Assert-True (($terminal.Terminal.Lines -join "`n") -match '\[LocalConfigSyncRequired\]')
        $stale = Get-Content -LiteralPath $e.Path -Raw | ConvertFrom-Json -AsHashtable
        Assert-Equal $stale.personas.accountMappings.bob 'existing-bob@example.invalid' 'A config that changed during the run is never overwritten.'
        $writesBefore = @($e.Model.Ledger | Where-Object Method -ne GET).Count
        $e.Model.AfterWrite = $null; $e.Model.Ledger.Clear()
        $second = [SeedTestHost]::new()
        foreach ($answer in @('', '', '', '', '')) { $second.Terminal.Answers.Add($answer) }
        $second.Terminal.Answers.CompleteAdding()
        $again = Invoke-SeedConsole -Mode InitializePersonas -ConfigPath $e.Path -ConsoleHost $second -InteractiveProbe { $true } -AdminOptions $e.Admin
        Assert-Equal $again.Summary.LocalConfigSync 'Synced'
        Assert-True (($second.Terminal.Lines -join "`n") -match '\[Config\] The private account mapping now matches')
        $synced = Get-Content -LiteralPath $e.Path -Raw | ConvertFrom-Json -AsHashtable
        Assert-Equal $synced.personas.accountMappings.bob 'bobby@other.example.invalid'
        Assert-Equal @($e.Model.Ledger | Where-Object { $_.Method -ne 'GET' -or $_.Path -match '^/users\?' }).Count 0 'The next run writes nothing and never searches by name.'
        Assert-True ($writesBefore -ge 3)
    }
    Test-Case 'Console Managed Initialize no longer dumps tenant inventory and keeps the original two-value confirmation' {
        $personaScratch = $consoleScratch
        $e = New-PersonaTestEnvironment
        $e.Config.personas.bindingPath = Join-Path $e.Folder 'private\binding.json'
        $null = New-SeedPrivateDirectory (Join-Path $e.Folder 'private')
        $setup = Get-SeedPersonaPlan -Session $e.Session -Config $e.Config
        $record = Get-SeedSessionRecord $e.Session; $ctx = $e.Context; $request = $record.Transport
        $admin = New-ConsoleAuth $e.Config ([Collections.Generic.List[string]]::new()) $request
        $path = Join-Path $e.Folder 'config.json'
        $e.Config | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $path
        Close-SeedSession $e.Session
        $terminal = [SeedTestHost]::new()
        foreach ($answer in @('', $setup.Target, $setup.Fingerprint, '')) { $terminal.Terminal.Answers.Add($answer) }
        $r = Invoke-SeedConsole -Mode InitializePersonas -ConfigPath $path -ConsoleHost $terminal -InteractiveProbe { $true } -AdminOptions $admin
        Assert-ConsoleExit $r 0
        Assert-Equal $r.Summary.Status 'Provisioned'; Assert-Equal $terminal.Terminal.Reads 4
        $text = $terminal.Terminal.Lines -join "`n"
        Assert-True ($text -match '\[PersonaSetup\] Source=Managed Selected=2 Create=2' -and $text -notmatch '"Inventory"|"OperatorId"|DemoAccountAcknowledged')
        Assert-True (-not (Get-Content -LiteralPath $r.Summary.Reports.Json -Raw).Contains('Inventory'))
        Assert-Equal $r.Summary.PersonaPreview.Counts.Create 2
    }
} finally {
    Remove-Item -LiteralPath $consoleScratch -Recurse -Force
}
