function Test-SeedAppPermission {
    param([string[]]$Granted, [string]$Required, [switch]$Migration)
    if ($Required -cin $Granted) { return $true }
    switch -CaseSensitive ($Required) {
        'User.Read.All' { return 'User.ReadWrite.All' -cin $Granted }
        'ProfilePhoto.ReadWrite.All' { return 'User.ReadWrite.All' -cin $Granted }
        'LicenseAssignment.ReadWrite.All' { return 'User.ReadWrite.All' -cin $Granted }
        'LicenseAssignment.Read.All' { return 'LicenseAssignment.ReadWrite.All' -cin $Granted }
        'Domain.Read.All' { return 'Domain.ReadWrite.All' -cin $Granted }
        'Mail.Read' { return 'Mail.ReadWrite' -cin $Granted }
        'Team.ReadBasic.All' { return 'Group.ReadWrite.All' -cin $Granted }
        'Channel.ReadBasic.All' { return 'Group.ReadWrite.All' -cin $Granted }
        'Team.Create' { return $Migration -and 'Teamwork.Migrate.All' -cin $Granted }
        default { return $false }
    }
}

function Get-SeedManagementAppRoles {
    param([string]$Mode, [ValidateSet('Managed','Existing')][string]$AccountSource = 'Managed')
    switch ($Mode) {
        InspectUsers { return @('User.Read.All') }
        InitializePersonas {
            if ($AccountSource -ceq 'Existing') { return @('User.ReadWrite.All') }
            return @('User.ReadWrite.All','ProfilePhoto.ReadWrite.All','LicenseAssignment.ReadWrite.All','LicenseAssignment.Read.All','Domain.Read.All')
        }
        default { throw 'Seed.Mode: Explicit management mode required.' }
    }
}

function Get-SeedRequiredAppRoles {
    param([string]$Workload)
    switch ($Workload) {
        outlook { @('Mail.Read', 'Mail.Send') }
        onedrive { @('Files.ReadWrite.All') }
        teams { @('Team.Create', 'Teamwork.Migrate.All', 'TeamMember.ReadWrite.All', 'Group.ReadWrite.All', 'Team.ReadBasic.All', 'Channel.ReadBasic.All', 'ChannelMessage.Read.All') }
        sharepoint { @('Group.ReadWrite.All', 'Sites.ReadWrite.All') }
        default { throw 'Seed.Service.Workload: Unknown workload.' }
    }
}

function Test-SeedServices {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Scenario, [Parameter(Mandatory)]$IdentityContext)
    $record = Get-SeedSessionRecord $Session
    if ($record.Kind -ne 'App') { throw 'Seed.Service.Session: App-only workload checks are required.' }
    $record.ServiceGate = $null
    $Scenario = ConvertTo-SeedMap $Scenario; $IdentityContext = ConvertTo-SeedMap $IdentityContext
    Assert-SeedFields $IdentityContext @('Roles', 'Presenter') 'Seed.Service.Identity'
    Assert-SeedFields $IdentityContext.Presenter @('ObjectId') 'Seed.Service.Identity'
    foreach ($workload in @('outlook', 'onedrive', 'teams', 'sharepoint')) {
        if (-not $Scenario.Contains($workload)) { continue }
        foreach ($permission in @(Get-SeedRequiredAppRoles $workload)) {
            if (-not (Test-SeedAppPermission -Granted $record.Permissions -Required $permission -Migration:($workload -ceq 'teams'))) { throw 'Seed.Service.Scope: A selected workload application role is missing.' }
        }
    }
    $evidence = [System.Collections.Generic.List[object]]::new()
    if ($Scenario.Contains('outlook')) {
        foreach ($permission in @('Mail.Read', 'Mail.Send')) { if (-not (Test-SeedAppPermission -Granted $record.Permissions -Required $permission)) { throw 'Seed.Service.Scope: Required Outlook application role missing.' } }
        $checked = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $roles = @(Get-SeedReferencedRoles $Scenario outlook) + @('Presenter')
        foreach ($role in $roles) {
            if (-not $IdentityContext.Roles.ContainsKey($role)) {
                if ($role -ne 'Presenter') { throw 'Seed.Service.Identity: Referenced mailbox role is unresolved.' }
                $actor = $IdentityContext.Presenter
            } else { $actor = $IdentityContext.Roles[$role] }
            Assert-SeedFields $actor @('ObjectId') 'Seed.Service.Identity'
            Assert-SeedGuid $actor.ObjectId
            if (-not $checked.Add($actor.ObjectId)) { continue }
            $folder = ConvertTo-SeedMap (Invoke-SeedGraph -Session $Session -Method GET -Path "/users/$($actor.ObjectId)/mailFolders/inbox?`$select=id")
            Assert-SeedFields $folder @('id') 'Seed.Service.Mailbox'
            $evidence.Add(@{ Workload = 'outlook'; ActorId = $actor.ObjectId; ResourceId = $folder.id; Method = 'ReadBack' })
        }
    }
    if ($Scenario.Contains('onedrive')) {
        if ('Files.ReadWrite.All' -cnotin $record.Permissions) { throw 'Seed.Service.Scope: Required OneDrive application role missing.' }
        $id = $IdentityContext.Presenter.ObjectId
        Assert-SeedGuid $id
        $drive = ConvertTo-SeedMap (Invoke-SeedGraph -Session $Session -Method GET -Path "/users/$id/drive?`$select=id,driveType,owner")
        Assert-SeedFields $drive @('id', 'owner') 'Seed.Service.Drive'
        $owner = ConvertTo-SeedMap $drive.owner; Assert-SeedFields $owner @('user') 'Seed.Service.Drive'
        $user = ConvertTo-SeedMap $owner.user; Assert-SeedFields $user @('id') 'Seed.Service.Drive'
        if ($user.id -ine $id) { throw 'Seed.Service.Drive: Presenter drive ownership is not proven.' }
        $evidence.Add(@{ Workload = 'onedrive'; ActorId = $id; ResourceId = $drive.id; Method = 'ReadBack' })
    }
    # Tenant-specific Teams/SharePoint resource and permission checks belong to adapter callbacks.
    # No success is invented here for resources that do not yet exist.
    if ($Scenario.Contains('teams') -and 'Teamwork.Migrate.All' -cnotin $record.Permissions) { throw 'Seed.Service.Scope: Required Teams migration application role missing.' }
    $record.ServiceGate = @{
        Workloads = @(@('outlook', 'onedrive', 'teams', 'sharepoint') | Where-Object { $Scenario.Contains($_) })
        ActorFingerprint = Get-SeedFingerprint $IdentityContext.Roles
    }
    return @{ Ready = $true; Evidence = $evidence.ToArray(); ResourceChecksRequired = @(@('teams', 'sharepoint') | Where-Object { $Scenario.Contains($_) }) }
}

function Invoke-SeedPreflight {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Personas, [Parameter(Mandatory)]$Scenario, [Parameter(Mandatory)][AllowNull()]$Binding,
        [Parameter(Mandatory)][string]$PersonaPackFingerprint, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Operations, [Parameter(Mandatory)][hashtable]$ResourceChecks, $RunState = $null)
    $record = Get-SeedSessionRecord $Session
    if ($record.Kind -ne 'App') { throw 'Seed.Preflight.Session: App session required.' }
    $record.LastPlanFingerprint = $null
    $Scenario = ConvertTo-SeedMap $Scenario
    $Operations = @(foreach ($operation in $Operations) { ConvertTo-SeedMap $operation })
    $null = Get-SeedOperationKeys $Operations
    $record.ReadOnlyDepth++
    try {
        $identity = Resolve-SeedIdentityContext -Session $Session -Config $Config -Personas $Personas -Scenario $Scenario -Binding $Binding -PersonaPackFingerprint $PersonaPackFingerprint
        $services = Test-SeedServices -Session $Session -Scenario $Scenario -IdentityContext $identity
        $selected = @(@('outlook', 'teams', 'onedrive', 'sharepoint') | Where-Object { $Scenario.Contains($_) })
        foreach ($workload in $selected) {
            if (@($Operations | Where-Object Workload -eq $workload).Count -eq 0) { throw 'Seed.Preflight.Operations: Every selected workload requires explicit adapter operations.' }
        }
        foreach ($operation in $Operations) {
            Assert-SeedFields $operation @('Workload', 'PresenterEvidence') 'Seed.Preflight.Operations'
            Assert-SeedFields $operation.PresenterEvidence @('objectId') 'Seed.Preflight.Presenter'
            if ($operation.Workload -notin $selected) { throw 'Seed.Preflight.Operations: Operation workload is not selected.' }
            if ($operation.PresenterEvidence.objectId -ine $identity.Presenter.ObjectId) { throw 'Seed.Preflight.Presenter: Operation Presenter evidence differs from actual identity.' }
        }
        $plan = @(Get-SeedOperationPlan -Session $Session -Operations $Operations -ResourceChecks $ResourceChecks -RunState $RunState)
        return @{ CanImport = ($plan.Count -gt 0 -and @($plan | Where-Object Action -eq Block).Count -eq 0); IdentityContext = $identity; Services = $services; Plan = $plan; PlanFingerprint = Get-SeedFingerprint $plan }
    } finally { $record.ReadOnlyDepth-- }
}
