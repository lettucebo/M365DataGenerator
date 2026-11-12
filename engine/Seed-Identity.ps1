function Get-SeedReferencedRoles {
    param($Scenario, [string]$Workload)
    $roles = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if (-not $Scenario.Contains($Workload)) { return @() }
    switch ($Workload) {
        outlook {
            foreach ($thread in $Scenario.outlook.threads) {
                foreach ($message in $thread.messages) {
                    $null = $roles.Add($message.fromRole)
                    foreach ($role in @($message.toRoles) + @($message.ccRoles)) { $null = $roles.Add($role) }
                }
            }
        }
        teams {
            foreach ($channel in $Scenario.teams.channels) {
                foreach ($role in $channel.memberRoles) { $null = $roles.Add($role) }
                foreach ($message in $channel.messages) {
                    foreach ($entry in @($message) + @($message.replies)) {
                        $null = $roles.Add($entry.fromRole)
                        foreach ($mention in $entry.mentions) { $null = $roles.Add($mention.role) }
                    }
                }
            }
        }
        onedrive { foreach ($drive in $Scenario.onedrive.drives) { $null = $roles.Add($drive.ownerRole) } }
        sharepoint { foreach ($site in $Scenario.sharepoint.sites) { foreach ($role in @($site.ownerRoles) + @($site.memberRoles)) { $null = $roles.Add($role) } } }
    }
    return @($roles | Sort-Object)
}

function Resolve-SeedIdentityContext {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Personas, [Parameter(Mandatory)]$Scenario, [Parameter(Mandatory)][AllowNull()]$Binding, [Parameter(Mandatory)][string]$PersonaPackFingerprint)
    $record = Get-SeedSessionRecord $Session
    if ($record.Kind -ne 'App') { throw 'Seed.Identity.Session: Workload identities require an app-only session.' }
    $record.Identity = $null
    $record.ServiceGate = $null
    $Config = ConvertTo-SeedMap $Config; $Personas = ConvertTo-SeedMap $Personas; $Scenario = ConvertTo-SeedMap $Scenario
    $Binding = ConvertTo-SeedMap $Binding
    Assert-SeedSchema $Config config
    Assert-SeedSchema $Personas personas
    Assert-SeedSchema $Scenario scenario
    Assert-SeedSchema $Binding persona-binding
    $accountSource = $(if ($Binding.Contains('accountSource')) { $Binding['accountSource'] } else { 'Managed' })
    if ($accountSource -cne (Get-SeedPersonaAccountSource $Config) -or $accountSource -cne $(if ($Personas.Contains('accountSource')) { $Personas['accountSource'] } else { 'Managed' })) {
        throw 'Seed.Binding.Context: The account source differs between the config, the public pack and the binding; sources are never mixed or switched automatically.'
    }
    if ($record.TenantId -ine $Config.tenantId -or $record.ClientId -ine $Config.clientId -or
        $Binding.tenantId -ine $Config.tenantId -or $Binding.packId -cne $Personas.packId -or
        $Scenario.scenario.personaPackId -cne $Personas.packId -or $Binding.fingerprint -cne $PersonaPackFingerprint -or
        $Binding.instanceId -cne $Config.personas.instanceId) { throw 'Seed.Binding.Context: Persona binding differs from the exact selected pack, instance or tenant.' }
    if ($accountSource -ceq 'Existing') { Assert-SeedExistingBindingEvidence -Config $Config -Binding $Binding }
    $people = @{}; $photos = @{}
    foreach ($person in $Personas.people) {
        if ($people.ContainsKey($person.personaId)) { throw 'Seed.Identity.Duplicate: Duplicate public persona.' }
        $people[$person.personaId] = $person
    }
    if ($accountSource -cne 'Existing') { foreach ($photo in $Personas.avatarAssets) { $photos[$photo.id] = $photo } }
    $ids = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $upns = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($key in $Binding.users.Keys) {
        $bound = $Binding.users[$key]
        if (-not $people.ContainsKey($key) -or -not $ids.Add($bound.objectId) -or -not $upns.Add($bound.upn) -or $bound.upn -ieq $Config.presenterUpn) {
            throw 'Seed.Binding.Identity: Unknown, duplicate or Presenter identity in managed bindings.'
        }
        $person = $people[$key]
        if ($accountSource -ceq 'Existing') {
            # The approved snapshot is the actual one; public targets only constrain the fields the pack explicitly specifies.
            if (-not $Config.personas.accountMappings.Contains($key) -or $Config.personas.accountMappings[$key] -ine $bound.upn) { throw 'Seed.Binding.Identity: The explicit account mapping differs from the binding; accounts are never rebound automatically.' }
            if ($person.Contains('profile')) {
                foreach ($field in $person.profile.Keys) { if ($bound.profile[$field] -cne $person.profile[$field]) { throw 'Seed.Binding.Profile: The public target differs from the approved binding; run the separate initialization workflow.' } }
            }
            if ($null -ne $person['managerRef'] -and (-not $Binding.users.ContainsKey($person.managerRef) -or $bound.profile.managerObjectId -ine $Binding.users[$person.managerRef].objectId)) { throw 'Seed.Binding.Manager: The approved manager differs from the public target.' }
            $snapshot = @{}
            foreach ($field in @('displayName', 'jobTitle', 'department', 'companyName', 'officeLocation', 'usageLocation', 'managerObjectId')) { $snapshot[$field] = $bound.profile[$field] }
            if ((Get-SeedFingerprint $snapshot) -cne $bound.profile.sha256) { throw 'Seed.Binding.Profile: The approved snapshot and its digest differ.' }
            continue
        }
        $expectedUpn = "$($Config.personas.accountPrefix)$($person.alias)@$($Config.personas.userDomain)"
        if ($bound.upn -ine $expectedUpn) { throw 'Seed.Binding.Namespace: Binding does not match the explicit managed account namespace.' }
        $expected = @{ usageLocation = $Config.personas.usageLocation; managerObjectId = $null }
        foreach ($field in @('displayName', 'jobTitle', 'department', 'companyName', 'officeLocation')) { $expected[$field] = $person[$field] }
        if ($null -ne $person.managerRef) {
            if (-not $Binding.users.ContainsKey($person.managerRef)) { throw 'Seed.Binding.Manager: Missing managed manager binding.' }
            $expected.managerObjectId = $Binding.users[$person.managerRef].objectId
        }
        if ((Get-SeedFingerprint $expected) -cne $bound.profile.sha256) { throw 'Seed.Binding.Profile: Public profile and provisioning digest differ.' }
        foreach ($field in $expected.Keys) {
            if ($bound.profile[$field] -cne $expected[$field]) { throw 'Seed.Binding.Profile: Provisioning profile differs.' }
        }
        if (-not $photos.ContainsKey($person.avatarAssetId) -or $bound.photo.avatarAssetId -cne $person.avatarAssetId -or
            $bound.photo.sourceSha256 -cne $photos[$person.avatarAssetId].sha256) { throw 'Seed.Binding.Photo: Portrait provenance differs.' }
        if (-not $Config.personas.licenseProfiles.ContainsKey($person.licenseProfile) -or $bound.license.profileId -cne $person.licenseProfile) { throw 'Seed.Binding.License: License profile differs.' }
        $expectedSku = @($Config.personas.licenseProfiles[$person.licenseProfile].skuIds | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
        $actualSku = @($bound.license.skuIds | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
        if (($expectedSku -join ',') -cne ($actualSku -join ',')) { throw 'Seed.Binding.License: License evidence differs from the selected exact SKU set.' }
    }
    $referenced = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($workload in @('outlook', 'teams', 'onedrive', 'sharepoint')) {
        foreach ($role in @(Get-SeedReferencedRoles $Scenario $workload)) { $null = $referenced.Add($role) }
    }
    $actorPersonas = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($role in $referenced) {
        if ($role -ieq 'Presenter') { continue }
        if (-not $Scenario.roles.ContainsKey($role)) { throw 'Seed.Identity.Role: Unknown actor role.' }
        if (-not $actorPersonas.Add($Scenario.roles[$role].personaId)) { throw 'Seed.Identity.Duplicate: Distinct roles must resolve to distinct provisioned personas.' }
    }
    if ($accountSource -ceq 'Existing') {
        $missingPersonas = @($actorPersonas | Where-Object { -not $Binding.users.ContainsKey($_) })
        if ($missingPersonas.Count -gt 0) {
            throw "Seed.Binding.Missing: The scenario needs $($actorPersonas.Count) distinct selected people but only $($actorPersonas.Count - $missingPersonas.Count) are bound; $($missingPersonas.Count) more must come from a new explicit initialization selection. The Presenter is never used as a substitute author."
        }
    }
    $resolved = @{}
    foreach ($role in @($referenced | Sort-Object)) {
        if ($role -ieq 'Presenter') { continue }
        if (-not $Scenario.roles.ContainsKey($role)) { throw 'Seed.Identity.Role: Unknown actor role.' }
        $personaId = $Scenario.roles[$role].personaId
        if (-not $Binding.users.ContainsKey($personaId)) { throw 'Seed.Binding.Missing: Referenced persona is not provisioned.' }
        $bound = $Binding.users[$personaId]
        $path = "/users/$($bound.objectId)?`$select=id,userPrincipalName,displayName,jobTitle,department,companyName,officeLocation,usageLocation,accountEnabled,userType"
        $actual = ConvertTo-SeedMap (Invoke-SeedGraph -Session $Session -Method GET -Path $path)
        if ($accountSource -ceq 'Existing') {
            # Existing profiles may legitimately hold null values, but every field must be present and correctly typed.
            foreach ($field in @('id', 'userPrincipalName', 'accountEnabled', 'userType', 'displayName', 'jobTitle', 'department', 'companyName', 'officeLocation', 'usageLocation')) {
                if (-not $actual.Contains($field)) { throw 'Seed.Identity.Profile: A required field is missing; absent values are never defaulted.' }
            }
            if ($actual.id -isnot [string] -or $actual.userPrincipalName -isnot [string] -or $actual.displayName -isnot [string] -or
                @('jobTitle', 'department', 'companyName', 'officeLocation' | Where-Object { $null -ne $actual[$_] -and $actual[$_] -isnot [string] }).Count -gt 0 -or
                ($null -ne $actual.usageLocation -and ($actual.usageLocation -isnot [string] -or $actual.usageLocation -cnotmatch '^([A-Z]{2})?$'))) { throw 'Seed.Identity.Profile: A profile field has an unexpected type.' }
        } else {
            Assert-SeedFields $actual @('id', 'userPrincipalName', 'accountEnabled', 'userType', 'displayName', 'jobTitle', 'department', 'companyName', 'officeLocation', 'usageLocation') 'Seed.Identity.Profile'
        }
        if ($actual.id -ine $bound.objectId -or $actual.userPrincipalName -ine $bound.upn -or $actual.accountEnabled -isnot [bool] -or -not $actual.accountEnabled -or $actual.userType -cne 'Member') { throw 'Seed.Identity.Profile: Actual enabled Member identity differs from provisioning evidence.' }
        foreach ($field in @('displayName', 'jobTitle', 'department', 'companyName', 'officeLocation', 'usageLocation')) {
            if ($actual[$field] -cne $bound.profile[$field]) { throw 'Seed.Identity.Profile: Actual profile drifted; use the separate initialization workflow.' }
        }
        $managerId = $null
        try {
            $manager = ConvertTo-SeedMap (Invoke-SeedGraph -Session $Session -Method GET -Path "/users/$($bound.objectId)/manager?`$select=id")
            Assert-SeedFields $manager @('id') 'Seed.Identity.Manager'
            $managerId = $manager.id
        } catch {
            if ($_.Exception.Message -notlike 'Seed.Graph.404:*' -or $null -ne $bound.profile.managerObjectId) { throw }
        }
        if ($managerId -ine $bound.profile.managerObjectId) { throw 'Seed.Identity.Manager: Actual manager differs.' }
        $resolved[$role] = @{ PersonaId = $personaId; ObjectId = $actual.id; Upn = $actual.userPrincipalName; ProfileFingerprint = $bound.profile.sha256; Provenance = 'ProvisionedBindingAndReadBack' }
        if ($accountSource -ceq 'Existing') { $resolved[$role].Provenance = 'ConfiguredExistingBindingAndReadBack'; $resolved[$role].AccountSource = 'Existing' }
    }
    $presenterPath = '/users/' + [uri]::EscapeDataString($Config.presenterUpn) + '?$select=id,userPrincipalName,accountEnabled,userType'
    $presenter = ConvertTo-SeedMap (Invoke-SeedGraph -Session $Session -Method GET -Path $presenterPath)
    Assert-SeedFields $presenter @('id', 'userPrincipalName', 'accountEnabled', 'userType') 'Seed.Identity.Presenter'
    Assert-SeedGuid $presenter.id
    if ($presenter.userPrincipalName -ine $Config.presenterUpn -or $presenter.accountEnabled -isnot [bool] -or -not $presenter.accountEnabled -or $presenter.userType -cne 'Member' -or $ids.Contains($presenter.id)) {
        throw 'Seed.Identity.Presenter: Presenter must be a distinct existing enabled Member; it is never provisioned or repaired.'
    }
    $presenterIdentity = @{ ObjectId = $presenter.id; Upn = $presenter.userPrincipalName; Provenance = 'ExistingReadBack' }
    $resolved.Presenter = $presenterIdentity
    $identity = @{
        TenantId = $Config.tenantId; ClientId = $Config.clientId; InstanceId = $Binding.instanceId
        ScenarioId = $Scenario.scenario.id
        PersonaPackFingerprint = $PersonaPackFingerprint; BindingFingerprint = Get-SeedFingerprint $Binding
        Roles = $resolved; Presenter = $presenterIdentity; ServiceStatus = 'NotVerified'
        ActorFingerprint = Get-SeedFingerprint $resolved
    }
    $record.Identity = $identity | ConvertTo-Json -Depth 100 -Compress | ConvertFrom-Json -AsHashtable
    return $identity
}

function Get-DemoUserInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, $Binding = $null, [string]$PresenterUpn)
    $record = Get-SeedSessionRecord $Session
    if ($record.Kind -ne 'App' -or $record.Mode -notin @('InspectUsers', 'InitializePersonas')) { throw 'Seed.Identity.Inventory: Explicit application management session required.' }
    $managed = @{}
    if ($null -ne $Binding) {
        $Binding = ConvertTo-SeedMap $Binding
        Assert-SeedSchema $Binding persona-binding
        if ($Binding.tenantId -ine $record.TenantId) { throw 'Seed.Binding.Context: Inventory binding tenant differs.' }
        foreach ($key in $Binding.users.Keys) { $managed[$Binding.users[$key].objectId] = $key }
    }
    foreach ($entry in @(Get-SeedGraphCollection -Session $Session -Path '/users?$select=id,displayName,userPrincipalName,jobTitle,department,companyName,accountEnabled,userType')) {
        $user = ConvertTo-SeedMap $entry
        Assert-SeedFields $user @('id', 'userPrincipalName', 'accountEnabled', 'userType') 'Seed.Identity.Inventory'
        @{
            ObjectId = $user.id; Upn = $user.userPrincipalName; DisplayName = $user['displayName']; JobTitle = $user['jobTitle']; Department = $user['department']; CompanyName = $user['companyName']
            AccountEnabled = $user.accountEnabled; UserType = $user.userType; IsPresenter = ($user.userPrincipalName -ieq $PresenterUpn)
            ManagedStatus = $(if ($managed.ContainsKey($user.id) -and $Binding.users[$managed[$user.id]].upn -ieq $user.userPrincipalName) { 'BindingMatchNotServiceVerified' } else { 'Unmanaged' })
            ManagerStatus = 'NotChecked'; PhotoStatus = 'NotChecked'; LicenseStatus = 'NotChecked'
        }
    }
}
