# Trusted host entry points; pack/config data cannot supply callbacks or a terminal.
function Read-SeedConsoleJson {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf) -or (Get-Item -LiteralPath $Path).Length -gt 16777216) {
        throw 'Seed.Input.File: Supply an existing bounded local JSON file.'
    }
    try {
        $value = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
        if ($value -isnot [Collections.IDictionary]) { throw 'object' }
        return $value
    } catch { throw 'Seed.Input.Json: Expected a valid JSON object.' }
}

function Read-SeedConsoleConfig {
    param([string]$Path, [string]$Mode, [string]$PresenterUpn, [ref]$OperatorDefaulted)
    $config = Read-SeedConsoleJson $Path
    $base = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    if ($PresenterUpn) { $config.presenterUpn = $PresenterUpn }
    if (-not $config.Contains('presenterUpn')) { $config.presenterUpn = '' }
    if ($config.Contains('clientSecretEnvironmentVariable') -and $config.clientSecretEnvironmentVariable -is [string] -and
        $config.clientSecretEnvironmentVariable -match '^[A-Za-z_][A-Za-z0-9_]*$') {
        $null = $script:SeedSecretEnvironmentVariables.Add($config.clientSecretEnvironmentVariable)
    }
    if ($config.Contains('personas') -and $config.personas -is [Collections.IDictionary]) {
        foreach ($field in @('packPath','bindingPath')) {
            if ($config.personas.Contains($field) -and $config.personas[$field] -is [string] -and $config.personas[$field]) {
                try { $config.personas[$field] = [IO.Path]::GetFullPath($config.personas[$field], $base) }
                catch { throw 'Seed.Input.Path: Invalid config-relative path.' }
            }
        }
    }
    return $config
}

function Assert-SeedConsoleConfig {
    param($Config, [string]$Mode)
    Assert-SeedSchema $Config config
    Assert-SeedFields $Config @('clientId','clientSecretEnvironmentVariable') 'Seed.Input.Config'
    if ($Config.Contains('adminAuth') -and $Config.adminAuth.Contains('clientId') -and $Config.adminAuth.clientId -ine $Config.clientId) { throw 'Seed.Auth.Migration: Legacy administration client must match top-level clientId.' }
    if ($Mode -in @('RunAll','Preflight','Import','Verify')) {
        Assert-SeedFields $Config @('clientId','clientSecretEnvironmentVariable','personas','runId') 'Seed.Input.Config'
    } elseif ($Mode -ceq 'InitializePersonas') {
        Assert-SeedFields $Config @('personas') 'Seed.Input.Config'
    }
}

function New-SeedPrivateDirectory {
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $current = $full
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            if (((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Seed.Input.Path: Private directories cannot traverse reparse points.' }
        }
        $current = [IO.Path]::GetDirectoryName($current)
    }
    if ($full.StartsWith('\\')) { throw 'Seed.Input.Path: Private directories must be local.' }
    if (Test-Path -LiteralPath $full) {
        if (-not (Test-Path -LiteralPath $full -PathType Container)) { throw 'Seed.Input.Path: Expected private directory.' }
    } else {
        $parent = [IO.Path]::GetDirectoryName($full)
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { $null = New-SeedPrivateDirectory $parent }
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl = [Security.AccessControl.DirectorySecurity]::new()
        $acl.SetOwner($sid); $acl.SetAccessRuleProtection($true, $false)
        foreach ($principal in @($sid, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($principal, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
        }
        $null = [IO.FileSystemAclExtensions]::CreateDirectory($acl, $full)
    }
    $allowed = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18')
    foreach ($rule in (Get-Acl -LiteralPath $full).Access) {
        if ($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -notin $allowed) {
            throw 'Seed.Input.Privacy: Private directory grants access to another principal; select a private config location.'
        }
    }
    return $full
}

function Invoke-SeedConsoleValidation {
    param([string]$PackPath, [string]$PersonaPackPath, [switch]$PersonasOnly)
    if (-not $PersonaPackPath -or (-not $PersonasOnly -and -not $PackPath)) { throw 'Seed.Input.Paths: Explicit PersonaPackPath and scenario PackPath (unless PersonasOnly) are required.' }
    Invoke-SeedPython -InputObject @{ pack = $(if ($PersonasOnly) { $null } else { [IO.Path]::GetFullPath($PackPath) }); personas = [IO.Path]::GetFullPath($PersonaPackPath) } -Code @'
import json,sys
from pathlib import Path
sys.path.insert(0,str(Path.cwd()))
from generator.validate_pack import validate_files
d=json.load(sys.stdin)
errors=validate_files(Path(d["pack"]) if d["pack"] else None,Path(d["personas"]))
print(json.dumps({"valid":not errors,"errors":errors},ensure_ascii=False))
'@
}

function Get-SeedConsolePersonaFingerprint {
    param([string]$Path)
    $result = Invoke-SeedPython -InputObject @{ path = $Path } -Code @'
import json,sys
from pathlib import Path
sys.path.insert(0,str(Path.cwd()))
from generator.build_scenario import persona_fingerprint
try: print(json.dumps({"valid":True,"fingerprint":persona_fingerprint(Path(json.load(sys.stdin)["path"]))}))
except (ValueError,OSError,KeyError): print(json.dumps({"valid":False}))
'@
    if (-not $result.valid) { throw 'Seed.Input.Personas: Missing or invalid persona source/photos; repair the input pack.' }
    return $result.fingerprint
}

function Build-SeedConsolePrepared {
    param([string]$PackPath, [string]$PersonaPackPath, [string]$Output)
    $result = Invoke-SeedPython -InputObject @{ pack=$PackPath; personas=$PersonaPackPath; output=$Output } -Code @'
import json,sys
from pathlib import Path
sys.path.insert(0,str(Path.cwd()))
from generator.build_scenario import build_scenario
try:
 d=json.load(sys.stdin)
 p=build_scenario(Path(d["pack"]),Path(d["personas"]),Path(d["output"]))
 print(json.dumps({"prepared":True,"output":str(p)}))
except (ValueError,OSError): print(json.dumps({"prepared":False}))
'@
    if (-not $result.prepared) { throw 'Seed.Input.Prepared: Build or exact existing-package comparison failed; preserve existing output.' }
}

function Write-SeedConsoleStage {
    param($ConsoleHost, [string]$Name)
    $ConsoleHost.UI.WriteLine("[Stage] $Name")
}

function Write-SeedCompletion {
    param([Parameter(Mandatory)]$Summary, [Management.Automation.Host.PSHost]$ConsoleHost = $Host, [switch]$NonInteractive)
    $ConsoleHost.UI.WriteLine("[$($Summary.Status)] Mode=$($Summary.Mode) Exit=$($Summary.ExitCode)")
    foreach ($field in @('TenantId','RunId','PresenterUpn','Operator','ServiceStatus','LocalConfigSync','ErrorCode')) {
        if ($Summary.Contains($field) -and $Summary[$field]) { $ConsoleHost.UI.WriteLine("$field`: $($Summary[$field])") }
    }
    if ($Summary.Contains('AuthDiagnostic')) { $ConsoleHost.UI.WriteLine("AuthDiagnostic: $($Summary.AuthDiagnostic | ConvertTo-Json -Depth 5 -Compress)") }
    foreach ($workload in $Summary.Workloads.Keys | Sort-Object) {
        $row = $Summary.Workloads[$workload]
        $ConsoleHost.UI.WriteLine("$workload Created=$($row.Created) Skipped=$($row.Skipped) Failed=$($row.Failed) Blocked=$($row.Blocked) Unknown=$($row.Unknown)")
    }
    if ($Summary.Contains('Personas')) {
        $people = $Summary.Personas
        $ConsoleHost.UI.WriteLine("Personas Created=$($people.Created) Updated=$($people.Updated) Skipped=$($people.Skipped) Failed=$($people.Failed) Unknown=$($people.Unknown); ServiceStatus=NotVerified")
    }
    if ($Summary.Contains('Validation') -and -not $Summary.Validation.valid) {
        $ConsoleHost.UI.WriteLine(($Summary.Validation | ConvertTo-Json -Depth 100))
    }
    $ConsoleHost.UI.WriteLine("Presenter checks: $($Summary.PresenterStatus); actual UI/Copilot: $($Summary.UiStatus)")
    foreach ($link in $Summary.ResourceLinkIndex) { $ConsoleHost.UI.WriteLine("$($link.kind) | $($link.displayName) | $($link.webUrl) | Presenter=$($link.presenterAccessStatus)") }
    if ($Summary.Contains('ResourceLinksMissing') -and $Summary.ResourceLinksMissing.Count -gt 0) {
        $ConsoleHost.UI.WriteLine("Incomplete resource URLs (not guessed): $($Summary.ResourceLinksMissing -join ', ')")
    }
    foreach ($key in $Summary.Reports.Keys | Sort-Object) { $ConsoleHost.UI.WriteLine("$key`: $($Summary.Reports[$key])") }
    if (-not $NonInteractive) { $ConsoleHost.UI.WriteLine('按 Enter 結束 / Press Enter to exit.'); $null = $ConsoleHost.UI.ReadLine() }
}

function Set-SeedConsoleAdapterState {
    param($Session, $Adapters, $State)
    foreach ($key in $Adapters.Keys) {
        switch ($key) {
            Storage { Set-SeedStorageRunState -Session $Session -Adapter $Adapters[$key] -RunState $State }
            Outlook { Set-SeedOutlookRunState -Session $Session -Adapter $Adapters[$key] -RunState $State }
            Teams { Set-SeedTeamsRunState -Session $Session -Adapter $Adapters[$key] -RunState $State }
        }
    }
}

function Update-SeedConsoleCounts {
    param($Summary, $State, [object[]]$Plan, [switch]$Failure)
    foreach ($row in $Summary.Workloads.Values) {
        foreach ($name in @('Created','Skipped','Failed','Blocked','Unknown')) { $row[$name] = 0 }
    }
    if ($null -eq $State) {
        foreach ($row in $Summary.Workloads.Values) {
            if ($Failure) { $row[$(if ($Summary.Status -ceq 'Unknown') { 'Unknown' } elseif ($Summary.ExitCode -eq 1) { 'Failed' } else { 'Blocked' })] = 1 }
        }
        return
    }
    foreach ($result in $State.results) {
        if (-not $Summary.Workloads.Contains($result.workload)) { continue }
        $row = $Summary.Workloads[$result.workload]
        switch ($result.status) {
            Verified {
                $matching = @($Plan | Where-Object { $_.OperationId -ceq $result.id -and $_.Workload -ceq $result.workload })
                if ($Failure -and $State.status -ceq 'Completed' -and ($matching.Count -eq 0 -or $matching[0].Action -ceq 'Block')) { $row.Blocked++ }
                else { $row[$(if ($matching.Count -eq 1 -and $matching[0].Action -ceq 'Skip') { 'Skipped' } else { 'Created' })]++ }
            }
            { $_ -in @('Unknown','Partial','Submitted') } { $row.Unknown++ }
            Failed { $row.Failed++ }
            default { if ($Failure) { $row.Blocked++ } }
        }
    }
}

function Read-SeedConsoleAccountSelection {
    # ONE local selection stage, before and separate from the batch confirmation: every unresolved person is shown once with its bounded candidates
    # and answered with a single line. Choosing an account is never consent to write; anything unrecognised cancels, with no retry and no default.
    param([Parameter(Mandatory)][Management.Automation.Host.PSHost]$ConsoleHost, [Parameter(Mandatory)][object[]]$Unresolved)
    $ui = $ConsoleHost.UI
    $local = '[PersonaDetail] '
    $ui.WriteLine("[AccountSelection] $($Unresolved.Count) requested account(s) need one local choice before the batch preview; choosing an account is not consent to write.")
    $selection = @{}; $index = 0
    foreach ($item in $Unresolved) {
        $index++
        $candidates = @($item.Candidates)
        $ui.WriteLine("$local[$index/$($Unresolved.Count)] persona=$($item.PersonaId) requested=$(ConvertTo-SeedDisplayText $item.RequestedUpn) hint=$(ConvertTo-SeedDisplayText $item.HintName) reason=$($item.Reason)")
        for ($i = 0; $i -lt $candidates.Count; $i++) {
            $ui.WriteLine("$local  $($i + 1)) $(ConvertTo-SeedDisplayText $candidates[$i].DisplayName) <$(ConvertTo-SeedDisplayText $candidates[$i].Upn)> [$($candidates[$i].Basis)]")
        }
        if ($item.Truncated) { $ui.WriteLine("$local  only the first 20 candidates are listed; use replace:<exact UPN> for any other account") }
        $ui.WriteLine('Enter a candidate number, or replace:<exact UPN> for a different person; anything else cancels:')
        $choice = ConvertTo-SeedAccountSelection -Answer $ui.ReadLine() -Candidates $candidates
        if ($null -eq $choice) { throw 'Seed.Persona.Selection: The account selection was cancelled or not recognised; nothing was written.' }
        $selection[$item.PersonaId] = $choice
    }
    return $selection
}

function Invoke-SeedConsole {
    [CmdletBinding()]
    param([string]$Mode, [string]$PresenterUpn, [string]$PackPath, [string]$PersonaPackPath, [string]$ConfigPath,
        [switch]$NonInteractive, [string]$ConfirmTarget, [switch]$PersonasOnly,
        [Management.Automation.Host.PSHost]$ConsoleHost = $Host,
        [scriptblock]$InteractiveProbe = { -not [Console]::IsInputRedirected -and [Environment]::UserInteractive -and '-NonInteractive' -notin [Environment]::GetCommandLineArgs() },
        [hashtable]$AppOptions = @{}, [hashtable]$AdminOptions = @{})
    $session = $null; $config = $null; $state = $null; $statePath = $null; $context = $null
    $operations = @(); $plan = @(); $adapters = @{}; $base = $null; $reportDir = $null
    $canInteract = $false; $menu = -not $Mode
    $summary = @{ Mode=$Mode; Status='Blocked'; ExitCode=2; Workloads=@{}; ResourceLinkIndex=@()
        PresenterStatus='NotVerified'; UiStatus='NotVerified'; ServiceStatus='NotVerified'; Reports=@{} }
    try {
        $canInteract = [bool](& $InteractiveProbe)
        if (-not $NonInteractive -and -not $canInteract) { throw 'Seed.Input.Interactive: Interactive stdin is unavailable; explicitly select NonInteractive (not consent).' }
        if ($menu) {
            if ($NonInteractive) { throw 'Seed.Input.Mode: NonInteractive requires an explicit Mode.' }
            $ConsoleHost.UI.WriteLine('M365 Demo Data Generator')
            $modes = @('RunAll','InitializePersonas','InspectUsers','Preflight','Verify','Validate','Import')
            for ($i=0; $i -lt $modes.Count; $i++) { $ConsoleHost.UI.WriteLine("$($i+1). $($modes[$i])") }
            $ConsoleHost.UI.WriteLine('0. 離開 / Exit')
            do {
                $choice = $ConsoleHost.UI.ReadLine()
                if ($choice -ceq '0') { return @{ ExitCode=0; Summary=@{ Status='Exited'; Mode='Menu' } } }
                if ($choice -notmatch '^[1-7]$') { $ConsoleHost.UI.WriteLine('Invalid option; enter 0–7.'); continue }
                $Mode = $modes[[int]$choice-1]
            } while (-not $Mode)
        }
        $summary.Mode = $Mode
        if ($Mode -cnotin @('RunAll','InitializePersonas','InspectUsers','Validate','Preflight','Import','Verify')) { throw 'Seed.Input.Mode: Select a supported Mode.' }
        if ($PersonasOnly -and $Mode -cne 'Validate') { throw 'Seed.Input.Mode: PersonasOnly is only valid for offline Validate.' }
        if ($Mode -ceq 'Validate') {
            if ($menu) {
                if (-not $PersonaPackPath) { $ConsoleHost.UI.WriteLine('PersonaPackPath:'); $PersonaPackPath = $ConsoleHost.UI.ReadLine() }
                if (-not $PackPath -and -not $PersonasOnly) { $ConsoleHost.UI.WriteLine('PackPath:'); $PackPath = $ConsoleHost.UI.ReadLine() }
            }
            Write-SeedConsoleStage $ConsoleHost 'Offline Validate (no config, SDK or authentication)'
            $validation = Invoke-SeedConsoleValidation -PackPath $PackPath -PersonaPackPath $PersonaPackPath -PersonasOnly:$PersonasOnly
            $summary.Validation = $validation
            if (-not $validation.valid) { throw 'Seed.Input.Validation: Offline validation rejected the selected input; inspect structured errors.' }
            $summary.Status = 'Validated'; $summary.ExitCode = 0
        } else {
            if ($Mode -ceq 'InitializePersonas' -and $NonInteractive) { throw 'Seed.Input.Management: Production persona initialization requires personal preview and confirmation.' }
            if ($menu -and -not $ConfigPath) { $ConsoleHost.UI.WriteLine('ConfigPath:'); $ConfigPath = $ConsoleHost.UI.ReadLine() }
            if (-not $ConfigPath) { throw 'Seed.Input.Config: Explicit ConfigPath is required.' }
            $operatorDefaulted = $false
            $configHash = $null
            if ($Mode -ceq 'InitializePersonas' -and (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { $configHash = (Get-FileHash -LiteralPath $ConfigPath -Algorithm SHA256).Hash }
            $config = Read-SeedConsoleConfig -Path $ConfigPath -Mode $Mode -PresenterUpn $PresenterUpn -OperatorDefaulted ([ref]$operatorDefaulted)
            if ($Mode -ceq 'InitializePersonas' -and (Get-SeedPersonaAccountSource $config) -ceq 'Existing') {
                # Local only, before any login: finish the saving of an earlier, already completed and fully proven account correction.
                $synced = Sync-SeedResolvedAccountMappings -Config $config -ConfigPath $ConfigPath -ExpectedHash $configHash
                if ($synced.Status -ceq 'Saved') {
                    $summary.LocalConfigSync = 'Synced'
                    $ConsoleHost.UI.WriteLine('[Config] The private account mapping now matches the earlier completed and proven correction; no tenant write or lookup was made.')
                    $configHash = (Get-FileHash -LiteralPath $ConfigPath -Algorithm SHA256).Hash
                    $operatorDefaulted = $false
                    $config = Read-SeedConsoleConfig -Path $ConfigPath -Mode $Mode -PresenterUpn $PresenterUpn -OperatorDefaulted ([ref]$operatorDefaulted)
                }
            }
            $base = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ConfigPath))
            if (-not $NonInteractive) {
                $oldPresenter = $config.presenterUpn
                $ConsoleHost.UI.WriteLine("既有 Presenter UPN [$oldPresenter] (Enter keeps configured value):")
                $entered = $ConsoleHost.UI.ReadLine()
                if ($entered) { $config.presenterUpn = $entered }
                if ($Mode -in @('InitializePersonas','InspectUsers') -and $operatorDefaulted) {
                    $config.adminAuth.adminOperatorUpn = $config.presenterUpn
                }
            }
            if ($config.presenterUpn -isnot [string] -or $config.presenterUpn -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$') { throw 'Seed.Input.Presenter: Supply an existing Presenter UPN at startup.' }
            Assert-SeedFields $config @('tenantId') 'Seed.Input.Config'
            Assert-SeedGuid $config.tenantId
            $summary.TenantId = $config.tenantId; $summary.PresenterUpn = $config.presenterUpn
            $ConsoleHost.UI.WriteLine("Existing Presenter: $($config.presenterUpn) (not authenticated as this user; never managed)")
            if ($true) {
                Write-SeedConsoleStage $ConsoleHost 'Authenticate seeding application (app-only), not Presenter or administrator'
                if ($AdminOptions.Count -gt 0) {
                    if ($AppOptions.Count -gt 0 -or @($AdminOptions.Keys | Where-Object { $_ -notin @('TokenProvider','Transport','Delay','Send') }).Count -gt 0) { throw 'Seed.Injection: Retired SDK or mixed callbacks are not accepted; use application options.' }
                    $AppOptions = $AdminOptions
                }
                if ($AppOptions.Count -eq 0) {
                    Assert-SeedFields $config @('clientSecretEnvironmentVariable') 'Seed.Input.Config'
                    if ($config.clientSecretEnvironmentVariable -isnot [string] -or $config.clientSecretEnvironmentVariable -notmatch '^[A-Za-z_][A-Za-z0-9_]*$' -or
                        [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($config.clientSecretEnvironmentVariable, 'Process'))) {
                        throw 'Seed.Input.Credential: Set the configured app credential environment variable; do not put its value in config or arguments.'
                    }
                }
                $session = Connect-SeedSession -Config $config -Mode $Mode -RequiredRoles @('User.Read.All') @AppOptions
                $ConsoleHost.UI.WriteLine("Application connected: $($session.ClientId); not a Presenter sign-in.")
                $presenter = ConvertTo-SeedMap (Invoke-SeedGraph -Session $session -Method GET -Path "/users/$([uri]::EscapeDataString($config.presenterUpn))?`$select=id,userPrincipalName,accountEnabled,userType")
                Assert-SeedFields $presenter @('id','userPrincipalName','accountEnabled','userType') 'Seed.Identity.Presenter'
                Assert-SeedGuid $presenter.id
                if ($presenter.userPrincipalName -ine $config.presenterUpn -or $presenter.accountEnabled -cne $true -or $presenter.userType -cne 'Member') { throw 'Seed.Identity.Presenter: Existing enabled Member Presenter must read back exactly.' }
            }
            Write-SeedConsoleStage $ConsoleHost 'Validate mode-dependent config after authentication'
            Assert-SeedConsoleConfig -Config $config -Mode $Mode
            if ($Mode -ceq 'InspectUsers') {
                Write-SeedConsoleStage $ConsoleHost 'Read-only tenant inventory'
                $binding = $null
                if ($config.Contains('personas') -and (Test-Path -LiteralPath $config.personas.bindingPath -PathType Leaf)) { $binding = Read-SeedConsoleJson $config.personas.bindingPath }
                $inventory = Invoke-InspectUsers -Session $session -PresenterUpn $config.presenterUpn -Binding $binding
                $summary.Inventory = $inventory
                $ConsoleHost.UI.WriteLine(($inventory | ConvertTo-Json -Depth 100))
                $summary.Status = 'Inspected'; $summary.ExitCode = 0
            } elseif ($Mode -ceq 'InitializePersonas') {
                if ($PersonaPackPath) { $config.personas.packPath = [IO.Path]::GetFullPath($PersonaPackPath) }
                $validation = Invoke-SeedConsoleValidation -PersonaPackPath $config.personas.packPath -PersonasOnly
                $summary.Validation = $validation
                if (-not $validation.valid) { throw 'Seed.Input.Validation: Persona source/photos are invalid; no plan or writes started.' }
                $null = New-SeedPrivateDirectory ([IO.Path]::GetDirectoryName($config.personas.bindingPath))
                $accountSource = Get-SeedPersonaAccountSource $config
                Write-SeedConsoleStage $ConsoleHost $(if ($accountSource -ceq 'Existing') { 'Existing-account batch checks (every selected person, before any warning, confirmation or write)' } else { 'Complete persona/photo/seat diff (all before confirmation)' })
                $planArguments = @{ Session = $session; Config = $config }
                if ($accountSource -ceq 'Existing') {
                    # Bounded read-only account resolution first; only an unresolved person needs ONE local choice, which is not consent to write.
                    $personaSource = Read-SeedPersonaSource $config
                    $accountResolution = Resolve-SeedExistingAccountMappings -Session $session -Config $config -Personas $personaSource.Personas
                    if (@($accountResolution.Unresolved).Count -gt 0) {
                        Write-SeedConsoleStage $ConsoleHost 'Local account selection (once, before and separate from the batch confirmation)'
                        $selection = Read-SeedConsoleAccountSelection -ConsoleHost $ConsoleHost -Unresolved @($accountResolution.Unresolved)
                        $accountResolution = Resolve-SeedExistingAccountMappings -Session $session -Config $config -Personas $personaSource.Personas -Selection $selection
                        if (@($accountResolution.Unresolved).Count -gt 0) { throw 'Seed.Persona.Selection: Some requested accounts are still unresolved after the selection; nothing was written.' }
                    }
                    $planArguments.Config = $accountResolution.EffectiveConfig
                    $planArguments.AccountResolution = $accountResolution
                }
                $setup = Get-SeedPersonaPlan @planArguments
                # Automation-visible output gets only this projection; the shared renderer shows the full diff to the operator.
                $summary.PersonaPreview = ConvertTo-SeedPersonaSafePreview -Plan $setup
                $terminal = $ConsoleHost
                $confirmation = {
                    param($preview,$target,$fingerprint)
                    $terminal.UI.WriteLine("Enter exact tenantId/instanceId: $target")
                    $answerTarget = $terminal.UI.ReadLine()
                    $terminal.UI.WriteLine("Enter exact plan fingerprint: $fingerprint")
                    $answer = @{ Target=$answerTarget; PlanFingerprint=$terminal.UI.ReadLine() }
                    if ($preview.Contains('AccountSource') -and $preview['AccountSource'] -ceq 'Existing') {
                        $terminal.UI.WriteLine('I reviewed the exact accounts and Before -> After above and approve updating them for this Demo with this plan fingerprint; directory roles are neither checked nor changed. Type DemoAccountAcknowledged to continue (anything else cancels):')
                        $answer.DemoAccountAcknowledged = ($terminal.UI.ReadLine() -ceq 'DemoAccountAcknowledged')
                    }
                    $answer
                }.GetNewClosure()
                # Host owns interactive policy and the sole final Enter; engine still demands both exact values.
                $summary.Personas = Invoke-InitializePersonas -Session $session -Plan $setup -Confirmation $confirmation -ConsoleHost $ConsoleHost -NonInteractive 6>$null
                $summary.Status = $(if ($accountSource -ceq 'Existing') { 'ConfiguredExisting' } else { 'Provisioned' }); $summary.ExitCode = 0
                $summary.Reports.Binding = $config.personas.bindingPath
                $summary.Reports.Journal = $config.personas.bindingPath + '.journal.json'
                if ($accountSource -ceq 'Existing') {
                    # The whole batch is already verified and persisted in the binding/journal; the corrected mapping is saved locally by the same
                    # shared function. If that cannot be done the result is explicit and the remote update is never replayed.
                    try {
                        $mappingSave = Save-SeedResolvedAccountMappings -ConfigPath $ConfigPath -ExpectedHash $configHash -Resolutions @($setup.Preview.Rows | ForEach-Object { $_.Resolution })
                        if ($mappingSave.Status -ceq 'Saved') { $summary.LocalConfigSync = 'Saved' } elseif (-not $summary.Contains('LocalConfigSync')) { $summary.LocalConfigSync = 'NoChange' }
                    } catch {
                        $summary.LocalConfigSync = 'LocalConfigSyncRequired'; $summary.Status = 'LocalConfigSyncRequired'; $summary.ExitCode = 3; $summary.ErrorCode = 'Seed.Persona.ConfigSync'
                        $ConsoleHost.UI.WriteLine('[LocalConfigSyncRequired] The tenant batch is complete and read back, but the private account mapping could not be saved. Do not repeat the remote update and do not run RunAll yet: the next InitializePersonas saves the proven mapping before login.')
                    }
                }
            } else {
                $summary.RunId = $config.runId
                if ($menu -and -not $PackPath) { $ConsoleHost.UI.WriteLine('PackPath:'); $PackPath = $ConsoleHost.UI.ReadLine() }
                if (-not $PackPath) { throw 'Seed.Input.Paths: Explicit scenario PackPath is required.' }
                $PackPath = [IO.Path]::GetFullPath($PackPath)
                if (-not $PersonaPackPath) { $PersonaPackPath = $config.personas.packPath }
                $PersonaPackPath = [IO.Path]::GetFullPath($PersonaPackPath)
                $sourceScenario = Read-SeedConsoleJson $PackPath
                $personas = Read-SeedConsoleJson $PersonaPackPath
                foreach ($workload in @('outlook','teams','onedrive','sharepoint')) {
                    if ($sourceScenario.Contains($workload)) { $summary.Workloads[$workload] = @{ Created=0; Skipped=0; Failed=0; Blocked=0; Unknown=0 } }
                }
                $required = @('User.Read.All')
                foreach ($workload in $summary.Workloads.Keys) { $required += @(Get-SeedRequiredAppRoles $workload) }
                if ($sourceScenario.Contains('sharepoint') -and $sourceScenario.Contains('assets')) {
                    foreach ($asset in $sourceScenario.assets) {
                        if ($asset -is [Collections.IDictionary] -and $asset.Contains('destination') -and
                            $asset.destination -is [Collections.IDictionary] -and $asset.destination.Contains('workload') -and $asset.destination.workload -ceq 'sharepoint') {
                            # Site-hosted file operations also use the actual /drives write allowlist.
                            $required += 'Files.ReadWrite.All'
                            break
                        }
                    }
                }
                $permissions = (Get-SeedSessionRecord $session).Permissions
                foreach ($permission in $required | Sort-Object -Unique) {
                    if (-not (Test-SeedAppPermission -Granted $permissions -Required $permission -Migration:($sourceScenario.Contains('teams')))) { throw 'Seed.Auth.Token: A selected workload application role is missing; no scope escalation or delegated fallback.' }
                }
                Write-SeedConsoleStage $ConsoleHost 'Read-only binding and selected services before content build'
                $binding = Read-SeedConsoleJson $config.personas.bindingPath
                $personaFingerprint = Get-SeedConsolePersonaFingerprint $PersonaPackPath
                $identity = Resolve-SeedIdentityContext -Session $session -Config $config -Personas $personas -Scenario $sourceScenario -Binding $binding -PersonaPackFingerprint $personaFingerprint
                Test-SeedServices -Session $session -Scenario $sourceScenario -IdentityContext $identity | Out-Null
                Write-SeedConsoleStage $ConsoleHost 'Full offline source validation'
                $validation = Invoke-SeedConsoleValidation -PackPath $PackPath -PersonaPackPath $PersonaPackPath
                $summary.Validation = $validation
                if (-not $validation.valid) { throw 'Seed.Input.Validation: Full input validation failed before content build or writes.' }
                $runDir = Join-Path $base "runs\$($config.runId)"
                $stateDir = Join-Path $base "state\runs\$($config.runId)"
                $null = New-SeedPrivateDirectory $runDir
                $null = New-SeedPrivateDirectory $stateDir
                $prepared = Join-Path $runDir 'prepared'
                $statePath = Join-Path $stateDir 'run-state.json'
                $summary.Reports.Journal = $statePath; $summary.Reports.Prepared = $prepared
                if ($Mode -ceq 'Verify' -and -not (Test-Path -LiteralPath $prepared -PathType Container)) { throw 'Seed.Input.Prepared: Verify requires the original completed prepared package.' }
                Write-SeedConsoleStage $ConsoleHost 'Build new or compare exact immutable prepared package'
                Build-SeedConsolePrepared -PackPath $PackPath -PersonaPackPath $PersonaPackPath -Output $prepared
                $scenario = Read-SeedConsoleJson (Join-Path $prepared 'scenario.json')
                $preparedPersonas = Read-SeedConsoleJson (Join-Path $prepared 'personas\personas.json')
                $manifest = Read-SeedConsoleJson (Join-Path $prepared 'prepared-manifest.json')
                if ($manifest.sourceScenarioFingerprint -cne (Get-SeedFingerprint $sourceScenario) -or $manifest.personaPackFingerprint -cne $personaFingerprint) { throw 'Seed.Input.Prepared: Prepared source manifest differs from the selected input.' }
                $context = @{ tenantId=$config.tenantId; clientId=$config.clientId; scenarioId=$scenario.scenario.id; personaPackId=$personas.packId
                    personaPackFingerprint=$personaFingerprint; instanceId=$config.personas.instanceId; bindingFingerprint=$identity.BindingFingerprint
                    preparedFingerprint=$manifest.fingerprint; presenterUpn=$config.presenterUpn }
                $adapterArgs = @{ Session=$session; Scenario=$scenario; PreparedPath=$prepared; Context=$context; RunId=$config.runId; StatePath=$statePath }
                Write-SeedConsoleStage $ConsoleHost 'Complete selected adapters: operations, root requests and exact late-binding validators'
                if ($scenario.Contains('onedrive') -or $scenario.Contains('sharepoint')) { $adapters.Storage = Get-SeedStorageAdapter @adapterArgs }
                if ($scenario.Contains('outlook')) { $adapters.Outlook = Get-SeedOutlookAdapter @adapterArgs }
                if ($scenario.Contains('teams')) { $adapters.Teams = Get-SeedTeamsAdapter @adapterArgs }
                $checks = @{}; $requests = @()
                foreach ($key in @('Storage','Outlook','Teams')) {
                    if (-not $adapters.Contains($key)) { continue }
                    $adapter = $adapters[$key]
                    $operations += @($adapter.Operations); $requests += @($adapter.Requests)
                    foreach ($workload in $adapter.ResourceChecks.Keys) { $checks[$workload] = $adapter.ResourceChecks[$workload] }
                }
                if (Test-Path -LiteralPath $statePath) {
                    $state = Get-SeedRunState -Path $statePath -RunId $config.runId -Context $context -Operations $operations -ForImport
                    Set-SeedConsoleAdapterState $session $adapters $state
                } elseif ($Mode -ceq 'Verify') { throw 'Seed.Input.Journal: Verify requires the original journal.' }
                Write-SeedConsoleStage $ConsoleHost 'Global GET-only preflight (all selected workloads)'
                $preflight = Invoke-SeedPreflight -Session $session -Config $config -Personas $preparedPersonas -Scenario $scenario -Binding $binding -PersonaPackFingerprint $personaFingerprint -Operations $operations -ResourceChecks $checks -RunState $state
                $plan = @($preflight.Plan); $summary.Plan = $plan; $summary.Identity = $preflight.IdentityContext
                $ConsoleHost.UI.WriteLine(($summary.Identity | ConvertTo-Json -Depth 100))
                $ConsoleHost.UI.WriteLine(($plan | ConvertTo-Json -Depth 100))
                if (-not $preflight.CanImport) { throw 'Seed.Preflight.Blocked: At least one operation is Block; no workload is approved.' }
                $actions = @($plan.Action | Sort-Object -Unique)
                if ($actions.Count -ne 1 -or $actions[0] -cnotin @('Create','Skip')) { throw 'Seed.State.Blocked: Mixed Create/Skip is a partial run, never an automatic resume.' }
                if ($Mode -ceq 'Preflight') {
                    $summary.Status = 'PreflightPassed'; $summary.ExitCode = 0
                } else {
                    if ($Mode -ceq 'Verify' -and ($null -eq $state -or $state.status -cne 'Completed')) { throw 'Seed.Input.Journal: Verify requires globally Completed evidence.' }
                    if ($Mode -cne 'Verify' -and $actions[0] -ceq 'Create') {
                        $target = "$($config.tenantId)/$($config.runId)"
                        $ConsoleHost.UI.WriteLine("Side effects: exact operations above. Confirm tenantId/runId: $target")
                        if (-not $NonInteractive) {
                            if (-not $ConfirmTarget) { $ConfirmTarget = $ConsoleHost.UI.ReadLine() }
                        }
                        if ($ConfirmTarget -cne $target) { throw 'Seed.Input.Confirmation: Exact tenantId/runId is required; NonInteractive is never consent.' }
                        if ($null -eq $state) { $state = New-SeedRunState -Path $statePath -RunId $config.runId -Context $context -Operations $operations }
                        New-SeedWriteApproval -Session $session -Plan $plan -Requests $requests -ConfirmTarget $ConfirmTarget -StatePath $statePath -RunId $config.runId -Context $context | Out-Null
                        Write-SeedConsoleStage $ConsoleHost 'Execute Storage then Outlook then Teams; no partial resume; only state-checked channel completion retries'
                        $map = @{}
                        if ($adapters.Contains('Storage')) {
                            $storageResult = Invoke-UploadFiles -Session $session -Adapter $adapters.Storage -Plan $plan
                            $map = $storageResult.AssetUrlMap; $summary.ResourceLinkIndex = @($storageResult.ResourceLinkIndex)
                        }
                        if ($adapters.Contains('Outlook')) { Invoke-SeedEmails -Session $session -Adapter $adapters.Outlook -Plan $plan -AssetUrlMap $map | Out-Null }
                        if ($adapters.Contains('Teams')) {
                            $teamsResult = Invoke-SeedTeamsChannel -Session $session -Adapter $adapters.Teams -Plan $plan -AssetUrlMap $map
                            $summary.ResourceLinkIndex += @($teamsResult.ResourceLinkIndex)
                        }
                    }
                    Write-SeedConsoleStage $ConsoleHost 'Verify exact globally Completed journal and authoritative remote results'
                    $state = Get-SeedRunState -Path $statePath -RunId $config.runId -Context $context -Operations $operations -ForImport
                    if ($state.status -cne 'Completed') { throw 'Seed.State.Blocked: Partial results cannot be reported as completed.' }
                    Set-SeedConsoleAdapterState $session $adapters $state
                    $map = @{}; $summary.ResourceLinkIndex = @()
                    if ($adapters.Contains('Storage')) {
                        $storageResult = Test-SeedStorage -Session $session -Adapter $adapters.Storage
                        $map = $storageResult.AssetUrlMap; $summary.ResourceLinkIndex = @($storageResult.ResourceLinkIndex)
                    }
                    if ($adapters.Contains('Outlook')) { Test-SeedOutlook -Session $session -Adapter $adapters.Outlook -AssetUrlMap $map | Out-Null }
                    if ($adapters.Contains('Teams')) {
                        $teamsResult = Test-SeedTeams -Session $session -Adapter $adapters.Teams -AssetUrlMap $map
                        $summary.ResourceLinkIndex += @($teamsResult.ResourceLinkIndex)
                    }
                    Assert-SeedResourceLinks -Links @($summary.ResourceLinkIndex) -Scenario $scenario
                    if ($Mode -ceq 'Verify') { foreach ($row in $plan) { $row.Action = 'Skip' } }
                    Update-SeedConsoleCounts $summary $state $plan
                    $summary.PresenterStatus = $(if ($scenario.Contains('sharepoint')) { 'GraphStructural; RemoteAclNotProven; actual UI required' } else { 'ReadBackVerified; actual UI required' })
                    $summary.ServiceStatus = 'SelectedServicesReadBack'; $summary.Status = 'Completed'; $summary.ExitCode = 0
                }
            }
        }
    } catch {
        $code = [regex]::Match($_.Exception.Message, 'Seed\.[A-Za-z0-9_.]+').Value
        if (-not $code) { $code = 'Seed.Execution' }
        $summary.ErrorCode = $code
        if ($_.Exception.Data.Contains('SeedAuthDiagnostic')) { $summary.AuthDiagnostic = $_.Exception.Data['SeedAuthDiagnostic'] }
        $summary.Status = 'Failed'; $summary.ExitCode = 1
        if ($code -match '^Seed\.(Input|Preflight|Approval|Binding|Identity|State|Secret|Injection|Mode|Persona)' -or $code -match '\.Prepared$') { $summary.Status='Blocked'; $summary.ExitCode=2 }
        if ($statePath -and (Test-Path -LiteralPath $statePath)) {
            try {
                # Diagnostic evidence only, never reused as authorization or Skip proof.
                $diagnostic = Read-SeedConsoleJson $statePath
                Assert-SeedSchema $diagnostic run-state
                Assert-SeedNoSecrets $diagnostic
                if ($diagnostic.Contains('results') -and $diagnostic.results -is [Collections.IList]) {
                    $state = $diagnostic
                    $uncertain = @($state.results | Where-Object status -in @('Unknown','Partial','Submitted')).Count -gt 0
                    $partial = $state.status -ne 'Completed' -and @($state.results | Where-Object status -eq Verified).Count -gt 0
                    if ($uncertain -or $partial) { $summary.ExitCode=3; $summary.Status=$(if ($uncertain) { 'Unknown' } else { 'Partial' }) }
                }
            } catch { $state=$null; $summary.ExitCode=3; $summary.Status='Unknown' }
        }
        if ($config -and $Mode -ceq 'InitializePersonas' -and $config.Contains('personas')) {
            $journalPath = $config.personas.bindingPath + '.journal.json'
            if (Test-Path -LiteralPath $journalPath) {
                try {
                    $journal = Read-SeedConsoleJson $journalPath
                    if ($journal.status -cne 'Completed' -and @($journal.events | Where-Object { $_.kind -cne 'BindExisting' }).Count -gt 0) { $summary.ExitCode=3; $summary.Status='Unknown' }
                    if ($journal.Contains('lastSummary')) { $summary.Personas = $journal.lastSummary }
                    $summary.Reports.Journal = $journalPath
                } catch { $summary.ExitCode=3; $summary.Status='Unknown' }
            }
        }
        Update-SeedConsoleCounts $summary $state $plan -Failure
        if ($null -ne $session -and $adapters.Contains('Storage')) {
            try {
                $recordedLinks = Get-SeedConsoleFailureLinks -Session $session -Adapter $adapters.Storage
                $summary.ResourceLinkIndex = @($summary.ResourceLinkIndex | Where-Object kind -notin @('site','documentLibrary','list')) + @($recordedLinks.Links)
                $summary.ResourceLinksMissing = @($recordedLinks.Missing)
            } catch { $summary.ResourceLinkStatus = 'Incomplete; no unverified URLs are guessed.' }
        }
    } finally {
        if ($null -ne $session) { Close-SeedSession -Session $session }
    }
    if ($base) {
        try {
            $reportDir = New-SeedPrivateDirectory (Join-Path $base ('runs\reports\' + [guid]::NewGuid().ToString('N')))
            $summary.Reports.Json = Join-Path $reportDir 'summary.json'
            $summary.Reports.Markdown = Join-Path $reportDir 'summary.md'
            Write-SeedSummaryFiles -Summary $summary -Directory $reportDir | Out-Null
        } catch {
            $summary.ReportStatus = 'NotWritten'
            if ($summary.ExitCode -eq 0) { $summary.Status='Failed'; $summary.ExitCode=1; $summary.ErrorCode='Seed.Summary.Write' }
        }
    }
    Write-SeedCompletion -Summary $summary -ConsoleHost $ConsoleHost -NonInteractive:($NonInteractive -or -not $canInteract)
    return @{ ExitCode=$summary.ExitCode; Summary=$summary }
}
