function Invoke-InitializePersonas {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Plan,
        [string]$ConfirmTarget, [string]$ConfirmPlanFingerprint, [scriptblock]$Confirmation, [switch]$NonInteractive,
        [switch]$DemoAccountAcknowledged, [Management.Automation.Host.PSHost]$ConsoleHost)
    $record = Get-SeedSessionRecord $Session
    $saved = Get-SeedPersonaSavedPlan -Session $Session -Plan $Plan -ForWrite
    if (-not $NonInteractive -and ([Console]::IsInputRedirected -or -not [Environment]::UserInteractive)) { throw 'Seed.Persona.Confirmation: Interactive input is unavailable; explicit noninteractive confirmation is required.' }
    # The shared renderer always runs first, so a direct confirmation can never skip the warning and per-person diff.
    Show-SeedPersonaSetupPlan -Session $Session -Plan $Plan -ConsoleHost $ConsoleHost
    $existing = $Plan.Preview.Contains('AccountSource') -and $Plan.Preview.AccountSource -ceq 'Existing'
    if ($existing -and @($Plan.Preview.Rows | Where-Object { $_.Action -ceq 'Block' }).Count -gt 0) { throw 'Seed.Persona.Blocked: The plan contains blocked accounts; nothing was confirmed or written.' }
    $acknowledged = [bool]$DemoAccountAcknowledged
    if ($null -ne $Confirmation) {
        if ($ConfirmTarget -or $ConfirmPlanFingerprint) { throw 'Seed.Persona.Confirmation: Use one explicit confirmation source.' }
        $record.ReadOnlyDepth++
        try { $answer = ConvertTo-SeedMap (& $Confirmation (ConvertTo-SeedMap $Plan.Preview) $Plan.Target $Plan.Fingerprint) }
        catch { throw 'Seed.Persona.Confirmation: Confirmation callback failed.' }
        finally { $record.ReadOnlyDepth-- }
        Assert-SeedFields $answer @('Target', 'PlanFingerprint') 'Seed.Persona.Confirmation'
        $ConfirmTarget = $answer.Target; $ConfirmPlanFingerprint = $answer.PlanFingerprint
        if ($existing) { $acknowledged = $answer.Contains('DemoAccountAcknowledged') -and $answer['DemoAccountAcknowledged'] -is [bool] -and $answer['DemoAccountAcknowledged'] }
    } elseif (-not $NonInteractive -and -not $ConfirmTarget -and -not $ConfirmPlanFingerprint) {
        $ConfirmTarget = Read-Host 'Enter the exact tenantId/instanceId'
        $ConfirmPlanFingerprint = Read-Host 'Enter the current plan fingerprint'
        if ($existing) { $acknowledged = (Read-Host 'I reviewed the exact accounts and Before -> After above and approve updating them for this Demo with this plan fingerprint; directory roles are neither checked nor changed. Type DemoAccountAcknowledged to continue') -ceq 'DemoAccountAcknowledged' }
    }
    if ($ConfirmTarget -cne $Plan.Target -or $ConfirmPlanFingerprint -cne $saved.Fingerprint) { throw 'Seed.Persona.Confirmation: Exact target AND current plan fingerprint must be explicitly confirmed after preview.' }
    if ($existing -and -not $acknowledged) { throw 'Seed.Persona.Confirmation: DemoAccountAcknowledged must be explicitly true for this exact plan: the reviewed actual accounts and profile effects are approved.' }
    $lease = $null; $store = $null; $started = $false
    try {
        $lease = Enter-SeedRunLock ($saved.Prior.Path + '.active')
        # A new full read-only proof is compared, not merely a timestamp or a cached diff. A resolved account stays pinned to its approved
        # object ID: the fresh proof never re-runs a name lookup or a selection.
        $fresh = Get-SeedPersonaPlan -Session $Session -Config $saved.Config -AccountResolution $(if ($saved.Contains('AccountResolution')) { $saved.AccountResolution } else { $null })
        if ($fresh.Fingerprint -cne $saved.Fingerprint) { throw 'Seed.Persona.Changed: Target, source, role, seats or snapshots changed after preview.' }
        $work = $script:SeedPersonaPlans[$fresh.PlanId]
        Assert-SeedAppSessionReady $Session
        $saved.Used = $true; $work.Used = $true
        $record.PersonaPlanId = $null
        $preview = $fresh.Preview; $config = $work.Config
        $prior = $work.Prior
        $value = if ($null -ne $prior.Value) { $prior.Value } elseif ($existing) {
            @{ schemaVersion = '1.1'; accountSource = 'Existing'; context = $prior.Context; status = 'Planned'; plans = @(); events = @(); boundIds = @{}; bindingFingerprint = $null }
        } else {
            @{ schemaVersion = '1.0'; context = $prior.Context; status = 'Planned'; plans = @(); events = @(); createdIds = @{}; bindingFingerprint = $null }
        }
        $attempt = $value.plans.Count
        $approval = @{ attempt = $attempt; fingerprint = $fresh.Fingerprint; preview = $preview; approvedTarget = $ConfirmTarget; approvedBy = "Application:$($record.TenantId)/$($record.ClientId)"; Actor = @{ Type = 'Application'; TenantId = $record.TenantId; ClientId = $record.ClientId }; at = [DateTimeOffset]::UtcNow.ToString('o') }
        if ($existing) { $approval.demoAccountAcknowledged = $true }
        $value.plans += $approval
        $value.status = 'Running'
        if ($existing -and $null -eq $prior.Binding) {
            # The first explicit selection of an existing account is its own provenance, never a tool-created ID.
            foreach ($row in $preview.Rows) {
                $value.events += @{ sequence = $value.events.Count; attempt = $attempt; personaId = $row.PersonaId; kind = 'BindExisting'; status = 'Verified'; objectId = $row.ObjectId; at = [DateTimeOffset]::UtcNow.ToString('o'); readBack = $row.Before }
                $value.boundIds[$row.PersonaId] = $row.ObjectId
            }
        }
        $store = @{ Path = $prior.Path; FileHash = $prior.FileHash; Value = $value; Submitted = $false }
        if ($existing) { return Invoke-SeedExistingPersonaBatch -Session $Session -Record $record -Config $config -Fresh $fresh -Prior $prior -Store $store -Attempt $attempt }
        $states = @{}; $ids = @{}
        foreach ($row in $preview.Rows) {
            if ($null -ne $row.ObjectId) { $ids[$row.PersonaId] = $row.ObjectId; $states[$row.PersonaId] = ConvertTo-SeedMap $row.Before }
        }
        $usedInitialValues = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        # This dispatcher and each one-shot capability are local to the authenticated,
        # confirmed execution. There is deliberately no public plan-to-write grant API.
        $dispatch = {
            param($Row, [string]$Kind, [string]$Method, [string]$Path, $Body, [byte[]]$Raw)
            $personaKey = $Row.PersonaId
            $null = Assert-SeedPersonaAdmin $Session $config
            if ($Kind -eq 'Create') {
                $currentUsers = @(Get-DemoUserInventory -Session $Session -PresenterUpn $config.presenterUpn)
                if (@($currentUsers | Where-Object { $_.Upn -ieq $Row.Upn }).Count -ne 0) { throw 'Seed.Persona.Changed: Create target is no longer absent.' }
            } else {
                $current = Get-SeedPersonaRemoteState $Session $ids[$personaKey] $Row.Upn $preview.Presenter.id
                if ((Get-SeedFingerprint $current) -cne (Get-SeedFingerprint $states[$personaKey])) { throw 'Seed.Persona.Changed: Fresh write target differs from the approved snapshot.' }
            }
            $cap = [object]::new()
            $once = @{ Used = $false }
            $expectedBody = $Body; $expectedRaw = $Raw; $expectedPath = $Path; $expectedMethod = $Method
            $unknown = {
                if ($store.Value.events.Count -gt 0 -and $store.Value.events[-1].status -eq 'Pending') {
                    $store.Value.events[-1].status = 'Unknown'
                    $store.Value.events[-1].errorCode = 'OutcomeNotVerified'
                }
                $store.Value.status = 'Blocked'
                Save-SeedPersonaJournal $store
            }
            $record.PersonaWriteGuard = {
                param($Presented, $M, $P, $B, $R)
                if ($record.Kind -cne 'App' -or $record.Mode -cne 'InitializePersonas' -or $record.ReadOnlyDepth -gt 0 -or
                    -not [object]::ReferenceEquals($Presented, $cap) -or $once.Used -or $M -cne $expectedMethod -or $P -cne $expectedPath -or
                    -not [object]::ReferenceEquals($B, $expectedBody) -or -not [object]::ReferenceEquals($R, $expectedRaw)) {
                    throw 'Seed.Write.Persona: No authentic exact one-shot administration capability exists.'
                }
                $store.Value.events += @{
                    sequence = $store.Value.events.Count; attempt = $attempt; personaId = $personaKey; kind = $Kind
                    status = 'Pending'; objectId = $(if ($ids.ContainsKey($personaKey)) { $ids[$personaKey] } else { $null })
                    at = [DateTimeOffset]::UtcNow.ToString('o')
                }
                Save-SeedPersonaJournal $store
                $store.Submitted = $true
                $once.Used = $true
                return @{ PersonaUnknown = $unknown }
            }
            try {
                $response = Invoke-SeedGraph -Session $Session -Method $Method -Path $Path -Body $Body -RawBody $Raw -AdminCapability $cap
                if ($Kind -eq 'Create') {
                    $response = ConvertTo-SeedMap $response
                    Assert-SeedFields $response @('id') 'Seed.Persona.Create'
                    Assert-SeedGuid $response.id
                    if ($response.id -ieq $preview.Presenter.id -or $response.id -iin @($ids.Values)) { throw 'Seed.Persona.Create: Returned identity is not a distinct new Member.' }
                    $ids[$personaKey] = $response.id.ToLowerInvariant()
                    $expected = @{
                        ObjectId = $ids[$personaKey]; Upn = $Row.Upn; Profile = ConvertTo-SeedMap $Row.Desired.Profile
                        ManagerObjectId = $null; PhotoSha256 = $null; SkuIds = @(); AssignmentStatus = 'Active'
                    }
                } else {
                    $expected = ConvertTo-SeedMap $states[$personaKey]
                    switch ($Kind) {
                        Profile { foreach ($key in $Body.Keys) { $expected.Profile[$key] = $Body[$key] } }
                        Manager { $expected.ManagerObjectId = $ids[$Row.Desired.ManagerPersonaId] }
                        License { $expected.SkuIds = @($Row.Desired.SkuIds) }
                    }
                }
                $actual = Get-SeedPersonaRemoteState $Session $ids[$personaKey] $Row.Upn $preview.Presenter.id
                if ($Kind -eq 'Photo') {
                    if ($null -eq $actual.PhotoSha256 -or
                        ($actual.PhotoSha256 -ceq $states[$personaKey].PhotoSha256 -and $actual.PhotoSha256 -cne $Row.Photo.SourceSha256)) {
                        throw 'Seed.Persona.Photo: Missing or unchanged stale server bytes do not prove the approved upload.'
                    }
                    $expected.PhotoSha256 = $actual.PhotoSha256
                }
                if ((Get-SeedFingerprint $actual) -cne (Get-SeedFingerprint $expected)) { throw 'Seed.Persona.Verify: Authoritative read-back does not match the approved effect.' }
                $states[$personaKey] = $actual
                $event = $store.Value.events[-1]
                $event.status = 'Verified'; $event.objectId = $ids[$personaKey]; $event.readBack = $actual
                $event.verifiedAt = [DateTimeOffset]::UtcNow.ToString('o')
                if ($Kind -eq 'Create') { $store.Value.createdIds[$personaKey] = $ids[$personaKey] }
                Save-SeedPersonaJournal $store
            } catch {
                if (-not $once.Used) { throw }
                & $unknown
                throw 'Seed.Persona.Unknown: A submitted effect could not be verified; retained state blocks all automatic reruns.'
            } finally {
                $record.PersonaWriteGuard = $null
                if ($null -ne $Body -and $Body.Contains('passwordProfile')) { $Body.Remove('passwordProfile') }
                $response = $null; $cap = $null; $expectedBody = $null
            }
        }
        foreach ($row in $preview.Rows) {
            if ($row.Action -cne 'Create') { continue }
            $random = [byte[]]::new(32)
            do {
                [Security.Cryptography.RandomNumberGenerator]::Fill($random)
                $initial = 'Aa1!' + [Convert]::ToBase64String($random)
                $initialHash = Get-SeedPersonaBytesHash ([Text.Encoding]::UTF8.GetBytes($initial))
            } while (-not $usedInitialValues.Add($initialHash))
            [Array]::Clear($random, 0, $random.Length)
            $body = ConvertTo-SeedMap $row.Desired.Profile
            $body.accountEnabled = $true; $body.userType = 'Member'; $body.userPrincipalName = $row.Upn
            $body.mailNickname = ($row.Upn -split '@')[0]
            $body.passwordProfile = @{ password = $initial; forceChangePasswordNextSignIn = $true }
            $initial = $null
            try { & $dispatch $row Create POST '/users' $body $null }
            finally { $body.Remove('passwordProfile'); $body = $null }
        }
        foreach ($row in $preview.Rows) {
            $id = $ids[$row.PersonaId]
            if ($row.Action -ceq 'Update') {
                $patch = @{}
                foreach ($d in $row.Diff) {
                    if ($d.Field -cin @('displayName', 'jobTitle', 'department', 'companyName', 'officeLocation', 'usageLocation')) { $patch[$d.Field] = $d.After }
                }
                if ($patch.Count -gt 0) { & $dispatch $row Profile PATCH "/users/$id" $patch $null }
            }
            if ($null -ne $row.Desired.ManagerPersonaId -and $states[$row.PersonaId].ManagerObjectId -ine $ids[$row.Desired.ManagerPersonaId]) {
                & $dispatch $row Manager PUT "/users/$id/manager/`$ref" @{ '@odata.id' = "https://graph.microsoft.com/v1.0/users/$($ids[$row.Desired.ManagerPersonaId])" } $null
            }
            if ($row.Photo.Change) {
                $bytes = [Convert]::FromBase64String($work.Source.Photos[$row.Photo.AvatarAssetId])
                if ((Get-SeedPersonaBytesHash $bytes) -cne $row.Photo.SourceSha256) { throw 'Seed.Persona.Source: Approved photo bytes changed.' }
                & $dispatch $row Photo PUT "/users/$id/photo/`$value" $null $bytes
            }
            if ($row.AddSkuIds.Count -gt 0) {
                $adds = @($row.AddSkuIds | ForEach-Object { @{ skuId = $_; disabledPlans = @() } })
                & $dispatch $row License POST "/users/$id/assignLicense" @{ addLicenses = $adds; removeLicenses = @() } $null
            }
        }
        $binding = @{
            tenantId = $config.tenantId; packId = $preview.PackId; version = '1.0'; fingerprint = $preview.PackFingerprint
            instanceId = $config.personas.instanceId; users = @{}; status = 'Provisioned'; serviceStatus = 'NotVerified'
        }
        foreach ($row in $preview.Rows) {
            $actual = Get-SeedPersonaRemoteState $Session $ids[$row.PersonaId] $row.Upn $preview.Presenter.id
            if ((Get-SeedFingerprint $actual) -cne (Get-SeedFingerprint $states[$row.PersonaId]) -or
                ($actual.SkuIds -join ',') -cne ($row.Desired.SkuIds -join ',') -or $null -eq $actual.PhotoSha256) { throw 'Seed.Persona.Verify: Final whole-batch read-back differs or is incomplete.' }
            $at = [DateTimeOffset]::UtcNow.ToString('o')
            $profile = ConvertTo-SeedMap $actual.Profile
            $profile.managerObjectId = $actual.ManagerObjectId
            $digest = Get-SeedFingerprint $profile
            $profile.sha256 = $digest; $profile.verifiedAt = $at
            $binding.users[$row.PersonaId] = @{
                objectId = $actual.ObjectId; upn = $actual.Upn; profile = $profile
                photo = @{ avatarAssetId = $row.Photo.AvatarAssetId; sourceSha256 = $row.Photo.SourceSha256; verifiedSha256 = $actual.PhotoSha256; verifiedAt = $at }
                license = @{ profileId = $row.LicenseProfile; skuIds = $actual.SkuIds; verifiedAt = $at }
                status = 'Provisioned'; serviceStatus = 'NotVerified'
            }
        }
        Assert-SeedSchema $binding persona-binding
        Write-SeedPersonaFile -Path $config.personas.bindingPath -Value $binding -ExpectedHash $prior.BindingFileHash
        $store.Value.bindingFingerprint = Get-SeedFingerprint $binding
        $store.Value.status = 'Completed'
        Save-SeedPersonaJournal $store
        $result = @{
            Status = 'Provisioned'; ServiceStatus = 'NotVerified'
            Created = @($preview.Rows | Where-Object Action -eq Create).Count
            Updated = @($preview.Rows | Where-Object Action -eq Update).Count
            Skipped = @($preview.Rows | Where-Object Action -eq Keep).Count; Failed = 0; Unknown = 0
            BindingPath = $config.personas.bindingPath; JournalPath = $store.Path
        }
        Write-Host ($result | ConvertTo-Json -Compress)
        Write-Host 'People provisioned; mailbox/service/Demo readiness has NOT been verified.'
        return $result
    } catch {
        if ($null -ne $store -and $store.Submitted) {
            $store.Value.status = 'Blocked'
            if ($store.Value.events.Count -gt 0 -and $store.Value.events[-1].status -ceq 'Pending') {
                $store.Value.events[-1].status = 'Unknown'
                $store.Value.events[-1].errorCode = 'OutcomeNotVerified'
            }
            $attemptEvents = @($store.Value.events | Where-Object attempt -eq $attempt)
            $unknownCount = @($attemptEvents | Where-Object { $_.status -in @('Pending', 'Unknown') }).Count
            $updatedIds = @($preview.Rows | Where-Object Action -eq Update | ForEach-Object PersonaId)
            # Existing: BindExisting only records adoption of the account, so just a verified Profile or Manager write proves an update.
            $summary = @{
                Status = 'Blocked'; ServiceStatus = 'NotVerified'
                Created = @($attemptEvents | Where-Object { $_.kind -eq 'Create' -and $_.status -eq 'Verified' }).Count
                Updated = @($attemptEvents | Where-Object { $_.personaId -cin $updatedIds -and $_.status -eq 'Verified' -and (-not $existing -or $_.kind -cin @('Profile', 'Manager')) } | ForEach-Object personaId | Sort-Object -Unique).Count
                Skipped = @($preview.Rows | Where-Object Action -eq Keep).Count
                Failed = $(if ($unknownCount -eq 0) { 1 } else { 0 }); Unknown = $unknownCount
                JournalPath = $store.Path
            }
            if ($existing) { $summary.Selected = @($preview.Rows).Count } else { $summary.KnownObjectIds = $store.Value.createdIds }
            $store.Value.lastSummary = $summary
            try { Save-SeedPersonaJournal $store } catch { }
            Write-Host ($summary | ConvertTo-Json -Depth 10 -Compress)
            Write-Host "Blocked/Unknown. Preserve private journal: $($store.Path). No automatic resume."
            throw $(if ($existing) { 'Seed.Persona.Blocked: Existing-account configuration did not complete; preserve the private journal. No automatic retry, rollback or reselection.' } else { 'Seed.Persona.Blocked: Provisioning did not complete; preserve the private journal and known IDs. No automatic retry or rollback.' })
        }
        # The fresh proof replaces the active slot even before submission. A new attempt must still confirm and revalidate.
        $saved.Used = $false
        $record.PersonaPlanId = $Plan.PlanId
        if ($_.Exception.Message -like 'Seed.*') { throw }
        throw 'Seed.Persona.Blocked: Initialization stopped before authorization; no exception payload is disclosed.'
    } finally {
        $record.PersonaWriteGuard = $null
        if ($null -ne $lease) { $lease.Dispose() }
        if (-not $NonInteractive) { $null = Read-Host 'Press Enter to close the initialization summary' }
    }
}

function Invoke-SeedExistingPersonaBatch {
    # Existing accounts: the whole selected batch was already checked before this first write. The only effects are the four
    # allowed profile fields and the manager reference; each gets a fresh snapshot, a durable pending record and a read-back.
    param($Session, $Record, $Config, $Fresh, $Prior, $Store, [int]$Attempt)
    $record = $Record; $config = $Config; $store = $Store; $attempt = $Attempt
    $preview = $Fresh.Preview
    $rows = @($preview.Rows)
    $ids = @{}; $states = @{}
    foreach ($row in $rows) { $ids[$row.PersonaId] = $row.ObjectId; $states[$row.PersonaId] = ConvertTo-SeedMap $row.Before }
    $approvedIds = @($ids.Values)
    $allowedFields = @('jobTitle', 'department', 'companyName', 'officeLocation')
    $dispatch = {
        param($Row, [string]$Kind, [string]$Method, [string]$Path, $Body)
        $personaKey = $Row.PersonaId
        $personId = $ids[$personaKey]
        $legal = $false
        if ($Kind -ceq 'Profile') {
            $legal = $Method -ceq 'PATCH' -and $Path -ceq "/users/$personId" -and $Body -is [System.Collections.IDictionary] -and $Body.Count -gt 0 -and
                @($Body.Keys | Where-Object { $_ -cnotin $allowedFields }).Count -eq 0 -and @($Body.Values | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) }).Count -eq 0
        } elseif ($Kind -ceq 'Manager') {
            $legal = $Method -ceq 'PUT' -and $Path -ceq "/users/$personId/manager/`$ref" -and $Body -is [System.Collections.IDictionary] -and $Body.Count -eq 1 -and
                $null -ne $Row.ManagerTargetId -and $Row.ManagerTargetId -in $approvedIds -and $Row.ManagerTargetId -cne $personId -and
                $Body['@odata.id'] -ceq "https://graph.microsoft.com/v1.0/users/$($Row.ManagerTargetId)"
        }
        if (-not $legal) { throw 'Seed.Write.Persona: Existing accounts allow only the four approved profile fields and an approved same-batch manager reference.' }
        $null = Assert-SeedPersonaAdmin $Session $config
        $current = Get-SeedExistingPersonaState $Session $personId $Row.Upn
        if (-not (Test-SeedExistingPersonaStateEqual $current $states[$personaKey])) { throw 'Seed.Persona.Changed: Fresh write target differs from the approved snapshot.' }
        $cap = [object]::new()
        $once = @{ Used = $false }
        $expectedBody = $Body; $expectedPath = $Path; $expectedMethod = $Method
        $unknown = {
            if ($store.Value.events.Count -gt 0 -and $store.Value.events[-1].status -eq 'Pending') {
                $store.Value.events[-1].status = 'Unknown'
                $store.Value.events[-1].errorCode = 'OutcomeNotVerified'
            }
            $store.Value.status = 'Blocked'
            Save-SeedPersonaJournal $store
        }
        $record.PersonaWriteGuard = {
            param($Presented, $M, $P, $B, $R)
            if ($record.Kind -cne 'App' -or $record.Mode -cne 'InitializePersonas' -or $record.ReadOnlyDepth -gt 0 -or
                -not [object]::ReferenceEquals($Presented, $cap) -or $once.Used -or $M -cne $expectedMethod -or $P -cne $expectedPath -or
                -not [object]::ReferenceEquals($B, $expectedBody) -or $null -ne $R) {
                throw 'Seed.Write.Persona: No authentic exact one-shot administration capability exists.'
            }
            $store.Value.events += @{
                sequence = $store.Value.events.Count; attempt = $attempt; personaId = $personaKey; kind = $Kind
                status = 'Pending'; objectId = $personId; at = [DateTimeOffset]::UtcNow.ToString('o')
            }
            Save-SeedPersonaJournal $store
            $store.Submitted = $true
            $once.Used = $true
            return @{ PersonaUnknown = $unknown }
        }
        try {
            $null = Invoke-SeedGraph -Session $Session -Method $Method -Path $Path -Body $Body -AdminCapability $cap
            $expected = ConvertTo-SeedMap $states[$personaKey]
            if ($Kind -ceq 'Profile') { foreach ($key in $Body.Keys) { $expected.Profile[$key] = $Body[$key] } } else { $expected.ManagerObjectId = $Row.ManagerTargetId }
            $actual = Get-SeedExistingPersonaState $Session $personId $Row.Upn
            if (-not (Test-SeedExistingPersonaStateEqual $actual $expected)) { throw 'Seed.Persona.Verify: Authoritative read-back does not match the approved effect.' }
            $states[$personaKey] = $actual
            $event = $store.Value.events[-1]
            $event.status = 'Verified'; $event.readBack = $actual; $event.verifiedAt = [DateTimeOffset]::UtcNow.ToString('o')
            Save-SeedPersonaJournal $store
        } catch {
            if (-not $once.Used) { throw }
            & $unknown
            throw 'Seed.Persona.Unknown: A submitted effect could not be verified; retained state blocks all automatic reruns.'
        } finally {
            $record.PersonaWriteGuard = $null
            $cap = $null; $expectedBody = $null
        }
    }
    foreach ($row in $rows) {
        if ($row.Action -cne 'Update') { continue }
        $personId = $ids[$row.PersonaId]
        if ($row.Patch.Count -gt 0) {
            $patch = @{}
            foreach ($key in $row.Patch.Keys) { $patch[$key] = $row.Patch[$key] }
            & $dispatch $row Profile PATCH "/users/$personId" $patch
        }
        if ($null -ne $row.ManagerTargetId -and $states[$row.PersonaId].ManagerObjectId -cne $row.ManagerTargetId) {
            & $dispatch $row Manager PUT "/users/$personId/manager/`$ref" @{ '@odata.id' = "https://graph.microsoft.com/v1.0/users/$($row.ManagerTargetId)" }
        }
    }
    # Whole-batch final read-back, including unchanged accounts: only a fully matching batch may become a binding.
    $final = @{}
    foreach ($row in $rows) {
        $actual = Get-SeedExistingPersonaState $Session $ids[$row.PersonaId] $row.Upn
        if (-not (Test-SeedExistingPersonaStateEqual $actual $row.Projected)) { throw 'Seed.Persona.Verify: Final whole-batch read-back differs or is incomplete.' }
        $final[$row.PersonaId] = $actual
    }
    $at = [DateTimeOffset]::UtcNow.ToString('o')
    $binding = New-SeedExistingBinding -Config $config -Preview $preview -States $final -PlanFingerprint $Fresh.Fingerprint -JournalFingerprint (Get-SeedFingerprint @{ events = @($store.Value.events) }) -At $at
    Assert-SeedSchema $binding persona-binding
    Write-SeedPersonaFile -Path $config.personas.bindingPath -Value $binding -ExpectedHash $Prior.BindingFileHash
    $store.Value.bindingFingerprint = Get-SeedFingerprint $binding
    $store.Value.status = 'Completed'
    Save-SeedPersonaJournal $store
    $result = @{
        Status = 'ConfiguredExisting'; ServiceStatus = 'NotVerified'; Created = 0
        Updated = @($rows | Where-Object { $_.Action -ceq 'Update' }).Count
        Skipped = @($rows | Where-Object { $_.Action -ceq 'Keep' }).Count; Failed = 0; Unknown = 0; Selected = $rows.Count
        BindingPath = $config.personas.bindingPath; JournalPath = $store.Path
    }
    Write-Host ($result | ConvertTo-Json -Compress)
    Write-Host 'Existing accounts configured and read back; mailbox/service/Demo readiness has NOT been verified.'
    return $result
}
