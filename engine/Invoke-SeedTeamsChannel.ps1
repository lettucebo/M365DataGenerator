# Reuse the prepared-package and verified Storage provenance readers, not mail execution.
if (-not (Get-Command Read-SeedOutlookPrepared -ErrorAction SilentlyContinue)) { . "$PSScriptRoot\Invoke-SeedEmails.ps1" }

function Get-SeedTeamsRecord {
    param($Session, $Adapter)
    $r = Get-SeedSessionRecord $Session
    if ($null -eq $Adapter -or -not $Adapter.PSObject.Properties['AdapterId'] -or -not $r.Contains('TeamsAdapters') -or
        -not $r.TeamsAdapters.ContainsKey($Adapter.AdapterId)) { throw 'Seed.Teams.Adapter: Authentic session-bound adapter required.' }
    $t = $r.TeamsAdapters[$Adapter.AdapterId]
    if (-not [object]::ReferenceEquals($t.Handle, $Adapter) -or
        (Get-SeedFingerprint $Adapter.Operations) -cne $t.OperationsFingerprint -or
        (Get-SeedFingerprint @{ requests = @($Adapter.Requests) }) -cne $t.RequestsFingerprint -or
        -not [object]::ReferenceEquals($Adapter.ResourceChecks.teams, $t.ResourceCheck) -or
        -not [object]::ReferenceEquals($Adapter.RequestCheck, $t.RequestCheck)) { throw 'Seed.Teams.Adapter: Adapter scope or callbacks changed.' }
    return $t
}

function Assert-SeedTeamsSources {
    param($Teams)
    try { $m = Read-SeedOutlookPrepared $Teams.PreparedPath $Teams.Scenario }
    catch { throw 'Seed.Teams.Prepared: Exact complete canonical package and source bytes required.' }
    if ($m.fingerprint -cne $Teams.Context.preparedFingerprint) { throw 'Seed.Teams.Prepared: Prepared context changed.' }
    foreach ($c in $Teams.Scenario.teams.channels) {
        foreach ($root in $c.messages) {
            foreach ($m in @($root) + @($root.replies)) {
                $instant = [DateTimeOffset]::Parse($m.createdDateTime, [cultureinfo]::InvariantCulture)
                if ($instant -gt [DateTimeOffset]::UtcNow -or $instant.Ticks % [TimeSpan]::TicksPerMillisecond -ne 0 -or
                    $m.createdDateTime -match '\.\d{4,}(Z|[+-]\d{2}:\d{2})$') {
                    throw 'Seed.Teams.Time: Historical millisecond instant must not exceed current wall clock or canonical reference anchor; no truncation.'
                }
            }
        }
    }
}

function Assert-SeedTeamsActors {
    param($Session, $Teams)
    $r = Get-SeedSessionRecord $Session
    if ($null -eq $r.Identity -or (Get-SeedFingerprint $r.Identity) -cne $Teams.IdentityFingerprint -or
        $null -eq $r.ServiceGate -or 'teams' -cnotin $r.ServiceGate.Workloads -or
        $r.ServiceGate.ActorFingerprint -cne $r.Identity.ActorFingerprint) { throw 'Seed.Teams.Identity: Current T2 identity and service provenance required.' }
    foreach ($role in @(Get-SeedRequiredAppRoles teams)) {
        if (-not (Test-SeedAppPermission -Granted $r.Permissions -Required $role -Migration)) { throw 'Seed.Teams.Scope: Explicit migration and v1.0 read application roles required.' }
    }
    $ids = @{}
    foreach ($role in $Teams.Roles) {
        $actor = $r.Identity.Roles[$role]
        if ($null -eq $actor -or $ids.ContainsKey($actor.ObjectId)) { throw 'Seed.Teams.Actor: Distinct roles must resolve to distinct actual identities.' }
        $ids[$actor.ObjectId] = $true
        $p = ConvertTo-SeedMap (Invoke-SeedGraph -Session $Session -Method GET -Path "/users/$($actor.ObjectId)?`$select=id,userPrincipalName,displayName,jobTitle,department,companyName,officeLocation,usageLocation,accountEnabled,userType")
        if ($p.id -ine $actor.ObjectId -or $p.userPrincipalName -ine $actor.Upn -or $p.accountEnabled -cne $true -or
            $p.userType -cne 'Member' -or [string]::IsNullOrWhiteSpace($p.displayName)) { throw 'Seed.Teams.Actor: Actual enabled Member and displayName required.' }
        if ($role -cne 'Presenter') {
            $v = @{ managerObjectId = $null }
            foreach ($f in @('displayName', 'jobTitle', 'department', 'companyName', 'officeLocation', 'usageLocation')) { $v[$f] = $p[$f] }
            try { $v.managerObjectId = (Invoke-SeedGraph -Session $Session -Method GET -Path "/users/$($actor.ObjectId)/manager?`$select=id").id }
            catch { if ($_.Exception.Message -notlike 'Seed.Graph.404:*') { throw } }
            if ((Get-SeedFingerprint $v) -cne $actor.ProfileFingerprint) { throw 'Seed.Teams.Actor: Provisioned profile or manager changed.' }
        }
        if ($Teams.Names.ContainsKey($role) -and $Teams.Names[$role] -cne $p.displayName) { throw 'Seed.Teams.Actor: Planned actual displayName changed.' }
        $Teams.Names[$role] = $p.displayName
    }
}

function Add-SeedTeamsOperation {
    param($Teams, [string]$Key, $Scope)
    $id = 't' + (Get-SeedFingerprint "teams/$Key").Substring(0, 30)
    $op = @{
        OperationId = $id; Workload = 'teams'; TargetKey = "teams/$Key"; TargetId = $null; TeamsScope = $Scope
        DataFingerprint = Get-SeedFingerprint @{ context = $Teams.Context; runId = $Teams.RunId; scope = $Scope; identity = $Teams.IdentityFingerprint }
        ActorFingerprint = $Teams.IdentityFingerprint; PresenterEvidence = @{ verified = $true; objectId = $Teams.PresenterId }
        SideEffects = @("One $($Scope.Kind) write in a newly isolated migration Demo Team; no adoption, resend, completion retry or membership repair.")
    }
    if ($Teams.ById.ContainsKey($id)) { throw 'Seed.Teams.Duplicate: Operation identity collision.' }
    $Teams.Operations.Add($op); $Teams.ById[$id] = $op
    return $id
}

function Assert-SeedTeamsTitle {
    param($Title)
    # The scenario title becomes the visible Team name; the schema's text limit is far larger than a Team name allows.
    if ($Title -isnot [string] -or [string]::IsNullOrWhiteSpace($Title) -or $Title.Length -gt 200 -or $Title -cne $Title.Trim() -or
        $Title -match '[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]') {
        throw 'Seed.Input.TeamName: Scenario title becomes the visible Team name and must be 1-200 trimmed characters without control, format or line-separator characters.'
    }
    return $Title
}

function Get-SeedTeamsAdapter {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Scenario, [Parameter(Mandatory)][string]$PreparedPath,
        [Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$RunId, [Parameter(Mandatory)][string]$StatePath)
    $r = Get-SeedSessionRecord $Session
    if ($r.Kind -cne 'App' -or -not $r.Contains('Identity') -or $null -eq $r.Identity -or
        -not $r.Contains('ServiceGate') -or $null -eq $r.ServiceGate) { throw 'Seed.Teams.Identity: Run T2 identity and service checks first.' }
    $s = ConvertTo-SeedMap $Scenario; $ctx = ConvertTo-SeedMap $Context
    try {
        Assert-SeedSchema $s scenario; $StatePath = Assert-SeedStatePath $StatePath
        $PreparedPath = [IO.Path]::GetFullPath($PreparedPath)
        $manifest = Read-SeedOutlookPrepared $PreparedPath $s
    } catch { throw 'Seed.Teams.Prepared: Canonical exact prepared scenario and safe journal path required.' }
    if (-not $s.Contains('teams') -or [string]::IsNullOrWhiteSpace($RunId) -or
        $ctx.tenantId -ine $r.TenantId -or $ctx.clientId -ine $r.ClientId -or $ctx.presenterUpn -ine $r.Identity.Presenter.Upn -or
        $ctx.scenarioId -cne $s.scenario.id -or $ctx.personaPackId -cne $s.scenario.personaPackId -or
        $ctx.preparedFingerprint -cne $manifest.fingerprint -or $ctx.personaPackFingerprint -cne $manifest.personaPackFingerprint -or
        $ctx.personaPackFingerprint -cne $r.Identity.PersonaPackFingerprint -or $ctx.bindingFingerprint -cne $r.Identity.BindingFingerprint -or
        $ctx.instanceId -cne $r.Identity.InstanceId -or $ctx.scenarioId -cne $r.Identity.ScenarioId) { throw 'Seed.Teams.Context: Exact prepared, identity, client and run context required.' }
    $title = Assert-SeedTeamsTitle $s.scenario.title
    $t = @{
        Session = $Session; Scenario = $s; Context = $ctx; RunId = $RunId; StatePath = $StatePath; PreparedPath = $PreparedPath
        IdentityFingerprint = Get-SeedFingerprint $r.Identity; PresenterId = $r.Identity.Presenter.ObjectId
        Roles = @(@(Get-SeedReferencedRoles $s teams) + @('Presenter') | Sort-Object -Unique); Names = @{}
        Operations = [Collections.Generic.List[object]]::new(); ById = @{}; Channels = @{}; LogicalIds = @{}
        Ids = @{}; Evidence = @{}; RunState = $null; Assets = @{}; AssetUrlMap = $null; Resolved = @{}
    }
    Assert-SeedTeamsSources $t; Assert-SeedTeamsActors $Session $t
    $dates = @($s.teams.channels | ForEach-Object { foreach ($m in $_.messages) { $m.createdDateTime; foreach ($reply in $m.replies) { $reply.createdDateTime } } })
    if ($dates.Count -eq 0) { throw 'Seed.Teams.Time: At least one historical message required.' }
    $first = @($dates | ForEach-Object { [DateTimeOffset]::Parse($_, [cultureinfo]::InvariantCulture) } | Sort-Object)[0]
    $created = $first.ToUniversalTime().AddDays(-1).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $ns = Get-SeedFingerprint @{ context = $ctx; runId = $RunId }
    # Ownership rests on the full namespace in the description and the journal; the short suffix only keeps same-title runs apart.
    $t.Name = $title + ' [' + $ns.Substring(0, 8) + ']'
    $t.Description = "M365Seed:$ns"
    $teamBody = @{ 'template@odata.bind' = "https://graph.microsoft.com/v1.0/teamsTemplates('standard')"
        displayName = $t.Name; description = $t.Description; visibility = 'private'; createdDateTime = $created; '@microsoft.graph.teamCreationMode' = 'migration' }
    $t.TeamOperationId = Add-SeedTeamsOperation $t team @{ Kind = 'Team'; ParentOperationId = ''; Dependencies = @(); Body = $teamBody
        InitialRequest = @{ Method = 'POST'; Path = '/teams'; Body = $teamBody } }
    # The standard template's primary channel is intrinsic to this new team, never adopted from an existing team.
    $t.Channels.primary = @{ LogicalId = ''; Name = 'General'; ParentOperationId = $t.TeamOperationId; Primary = $true; Messages = @() }
    foreach ($c in $s.teams.channels) {
        $key = $c.id
        if ($c.displayName -ieq 'General') { $key = 'primary'; $t.Channels.primary.LogicalId = $c.id }
        elseif ($key -ieq 'primary') { throw 'Seed.Teams.Channel: Reserved primary channel key.' }
        else {
            $body = @{ displayName = $c.displayName; description = "M365Seed:$ns/$($c.id)"; membershipType = 'standard'
                createdDateTime = $created; '@microsoft.graph.channelCreationMode' = 'migration' }
            $channelOp = Add-SeedTeamsOperation $t "channel/$key" @{ Kind = 'Channel'; ChannelKey = $key; ParentOperationId = $t.TeamOperationId; Dependencies = @($t.TeamOperationId); Body = $body; InitialRequest = $null }
            $t.Channels[$key] = @{ LogicalId = $c.id; Name = $c.displayName; ParentOperationId = $channelOp; Primary = $false; Messages = @() }
        }
        foreach ($root in $c.messages) {
            foreach ($m in @($root) + @($root.replies)) {
                if ($t.LogicalIds.ContainsKey($m.id)) { throw 'Seed.Teams.Duplicate: All root and reply logical IDs must be unique.' }
                $actor = $r.Identity.Roles[$m.fromRole]
                if ($m.fromRole -ceq 'Presenter' -or $null -eq $actor -or $actor.ObjectId -ieq $t.PresenterId -or $m.fromRole -cnotin $c.memberRoles) { throw 'Seed.Teams.Actor: Exact distinct mapped persona author must be a declared member.' }
                $parent = $(if ($m.id -ceq $root.id) { $t.Channels[$key].ParentOperationId } else { $t.LogicalIds[$root.id] })
                $scope = @{ Kind = $(if ($m.id -ceq $root.id) { 'Root' } else { 'Reply' }); ChannelKey = $key
                    MessageId = $m.id; StoryId = $m.storyId; AuthorId = $actor.ObjectId; AuthorName = $t.Names[$m.fromRole]
                    CreatedDateTime = [DateTimeOffset]::Parse($m.createdDateTime, [cultureinfo]::InvariantCulture).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
                    BodyHtml = $m.bodyHtml; Mentions = @(); AssetRefs = @($m.assetRefs); Assets = @{}
                    ParentOperationId = $parent; Dependencies = @($parent); InitialRequest = $null }
                foreach ($mention in $m.mentions) {
                    if ($mention.role -cnotin $c.memberRoles -or -not $r.Identity.Roles.ContainsKey($mention.role)) { throw 'Seed.Teams.Mention: Actual mentioned member required.' }
                    $scope.Mentions += @{ id = $mention.id; role = $mention.role; mentionText = $t.Names[$mention.role]
                        mentioned = @{ user = @{ id = $r.Identity.Roles[$mention.role].ObjectId; displayName = $t.Names[$mention.role]; userIdentityType = 'aadUser' } } }
                }
                foreach ($assetId in $scope.AssetRefs) {
                    $asset = @($manifest.assets | Where-Object id -CEQ $assetId)
                    $matches = @()
                    if ($r.Contains('StorageAdapters')) {
                        foreach ($storage in $r.StorageAdapters.Values) {
                            if ($storage.RunId -cne $RunId -or $storage.StatePath -cne $StatePath -or
                                (Get-SeedFingerprint $storage.Context) -cne (Get-SeedFingerprint $ctx)) { continue }
                            $null = Get-SeedStorageRecord $Session $storage.Handle
                            $matches += @($storage.Operations | Where-Object { $_.StorageScope.Kind -ceq 'Content' -and $_.StorageScope.AssetId -ceq $assetId -and $_.StorageScope.Sha256 -ceq $asset[0].sha256 })
                        }
                    }
                    if ($asset.Count -ne 1 -or $matches.Count -ne 1) { throw 'Seed.Teams.Asset: Declare one authentic same-run Storage content operation first.' }
                    $a = @{ Sha256 = $asset[0].sha256; Workload = $asset[0].destination.workload; OperationId = $matches[0].OperationId }
                    $scope.Assets[$assetId] = $a; $t.Assets[$assetId] = $a
                }
                $id = Add-SeedTeamsOperation $t "message/$($m.id)" $scope
                $t.LogicalIds[$m.id] = $id; $t.Channels[$key].Messages += $id
            }
        }
    }
    $completed = @()
    foreach ($key in @($t.Channels.Keys | Sort-Object)) {
        $c = $t.Channels[$key]
        $c.CompleteOperationId = Add-SeedTeamsOperation $t "complete/channel/$key" @{ Kind = 'CompleteChannel'; ChannelKey = $key; ParentOperationId = $c.ParentOperationId
            Dependencies = @($c.ParentOperationId) + @($c.Messages); Body = $null; InitialRequest = $null }
        $completed += $c.CompleteOperationId
    }
    $t.CompleteOperationId = Add-SeedTeamsOperation $t complete/team @{ Kind = 'CompleteTeam'; ParentOperationId = $completed[-1]; Dependencies = $completed; Body = $null; InitialRequest = $null }
    $owner = Add-SeedTeamsOperation $t owner @{ Kind = 'Owner'; UserId = $t.PresenterId; ParentOperationId = $t.CompleteOperationId; Dependencies = @($t.CompleteOperationId)
        Body = @{ '@odata.id' = "https://graph.microsoft.com/v1.0/users/$($t.PresenterId)" }; InitialRequest = $null }
    $presenterMember = $null
    foreach ($role in @('Presenter') + @($t.Roles | Where-Object { $_ -cne 'Presenter' })) {
        $actor = $r.Identity.Roles[$role]
        $parent = $(if ($role -ceq 'Presenter') { $owner } else { $presenterMember })
        $groupMember = Add-SeedTeamsOperation $t "group-member/$role" @{ Kind = 'GroupMember'; UserId = $actor.ObjectId; ParentOperationId = $parent; Dependencies = @($owner, $parent | Sort-Object -Unique)
            Body = @{ '@odata.id' = "https://graph.microsoft.com/v1.0/users/$($actor.ObjectId)" }; InitialRequest = $null }
        $member = Add-SeedTeamsOperation $t "member/$role" @{ Kind = 'Member'; UserId = $actor.ObjectId; ParentOperationId = $groupMember; Dependencies = @($owner, $groupMember)
            Body = @{ '@odata.type' = '#microsoft.graph.aadUserConversationMember'; roles = @($(if ($role -ceq 'Presenter') { 'owner' }))
                'user@odata.bind' = "https://graph.microsoft.com/v1.0/users/$($actor.ObjectId)" }; InitialRequest = $null }
        if ($role -ceq 'Presenter') { $presenterMember = $member }
    }
    $check = { param($s, $o) Get-SeedTeamsProof $s $t $o }.GetNewClosure()
    $validator = { param($s, $o, $q) Test-SeedTeamsRequest $s $t $o $q }.GetNewClosure()
    $requests = @(@{ OperationId = $t.TeamOperationId; Method = 'POST'; Path = '/teams'; Body = $teamBody })
    $handle = [pscustomobject]@{ AdapterId = [guid]::NewGuid().ToString(); Operations = @($t.Operations.ToArray()); ResourceChecks = @{ teams = $check }; Requests = $requests; RequestCheck = $validator }
    $t.Handle = $handle; $t.OperationsFingerprint = Get-SeedFingerprint $handle.Operations
    $t.RequestsFingerprint = Get-SeedFingerprint @{ requests = $requests }; $t.ResourceCheck = $check; $t.RequestCheck = $validator
    if (-not $r.Contains('TeamsAdapters')) { $r.TeamsAdapters = @{} }
    $r.TeamsAdapters[$handle.AdapterId] = $t
    $getRecord = ${function:Get-SeedTeamsRecord}
    $getDigest = ${function:Get-SeedOperationDigest}
    $invokeGraph = ${function:Invoke-SeedGraph}
    $assertFields = ${function:Assert-SeedFields}
    $r.TeamsCompletionProbe = {
        param($Operation, [string]$Path)
        $owned = & $getRecord $Session $handle
        if (-not $owned.ById.ContainsKey($Operation.OperationId) -or $Operation.TeamsScope.Kind -cne 'CompleteChannel' -or
            (& $getDigest $Operation) -cne (& $getDigest $owned.ById[$Operation.OperationId])) {
            throw 'Seed.Teams.MigrationState: Exact owned channel completion operation required.'
        }
        $teamId = $owned.Ids[$owned.TeamOperationId]
        $channelId = $owned.Ids["channel:$($Operation.TeamsScope.ChannelKey)"]
        if ([string]::IsNullOrWhiteSpace($teamId) -or [string]::IsNullOrWhiteSpace($channelId)) {
            throw 'Seed.Teams.MigrationState: Receipted team and channel IDs are required.'
        }
        $expectedPath = "/teams/$teamId/channels/$([uri]::EscapeDataString($channelId))/completeMigration"
        if ($Path -cne $expectedPath) { throw 'Seed.Teams.MigrationState: Completion target changed.' }
        $resource = $expectedPath.Substring(0, $expectedPath.Length - '/completeMigration'.Length)
        $state = & $invokeGraph -Session $Session -Method GET -Path ($resource + '?$select=id,migrationMode')
        & $assertFields $state @('id', 'migrationMode') 'Seed.Teams.MigrationState'
        if ($state.id -isnot [string] -or $state.id -cne $channelId -or $state.migrationMode -isnot [string] -or
            $state.migrationMode -cnotin @('inProgress', 'completed')) {
            throw 'Seed.Teams.MigrationState: Actual exact channel migration state is unproven.'
        }
        return $state.migrationMode
    }.GetNewClosure()
    return $handle
}

function Assert-SeedTeamsJournal {
    param($Teams, $State)
    try {
        $path = Assert-SeedStatePath $Teams.StatePath
        if ((Get-Item -LiteralPath $path).Length -gt 16777216) { throw 'oversized' }
        $current = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 100
        if ((Get-SeedFingerprint $current) -cne (Get-SeedFingerprint $State)) { throw 'changed' }
    } catch { throw 'Seed.Teams.State: Durable journal differs; preserve it without repair.' }
}

function Set-SeedTeamsRunState {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Adapter, [Parameter(Mandatory)]$RunState)
    $t = Get-SeedTeamsRecord $Session $Adapter
    if (-not $script:SeedValidatedStates.ContainsKey((Get-SeedFingerprint $RunState)) -or $RunState.runId -cne $t.RunId -or
        (Get-SeedFingerprint $RunState.context) -cne (Get-SeedFingerprint $t.Context) -or $RunState.status -cnotin @('Planned', 'Completed')) { throw 'Seed.Teams.State: Exact T2-validated Planned or globally Completed journal required; no partial resume.' }
    foreach ($op in $t.Operations) {
        $p = @($RunState.events | Where-Object { $_.action -ceq 'Plan' -and $_.workload -ceq 'teams' -and $_.id -ceq $op.OperationId })
        $v = @($RunState.results | Where-Object { $_.workload -ceq 'teams' -and $_.id -ceq $op.OperationId })
        if ($p.Count -ne 1 -or $p[0].objectId -cne ('plan-sha256:' + (Get-SeedOperationDigest $op)) -or $v.Count -ne 1 -or
            ($RunState.status -ceq 'Completed' -and $v[0].status -cne 'Verified')) { throw 'Seed.Teams.State: Exact complete Teams operation set required.' }
    }
    Assert-SeedTeamsJournal $t $RunState
    $t.RunState = ConvertTo-SeedMap $RunState; $t.Ids.Clear(); $t.Evidence.Clear()
    foreach ($v in $RunState.results) {
        if ($v.workload -ceq 'teams' -and $v.status -ceq 'Verified' -and $t.ById.ContainsKey($v.id)) { $t.Ids[$v.id] = $v.objectId }
    }
}

function Get-SeedTeamsGroups {
    param($Session, $Teams)
    $filter = [uri]::EscapeDataString("displayName eq '$($Teams.Name.Replace("'", "''"))'")
    return @(Get-SeedGraphCollection -Session $Session -Path "/groups?`$filter=$filter&`$select=id,displayName,description,groupTypes,visibility,resourceProvisioningOptions" -MaxPages 20)
}

function Assert-SeedTeamsLink {
    param([string]$Url)
    $u = $null
    if (-not [uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$u) -or $u.Scheme -cne 'https' -or
        $u.Host -cnotin @('teams.microsoft.com', 'teams.cloud.microsoft') -or -not $u.IsDefaultPort -or $u.UserInfo -or $u.Fragment) { throw 'Seed.Teams.Link: Authoritative unsigned Teams webUrl required.' }
    Assert-SeedNoSecrets $Url
    return $Url
}

function Get-SeedTeamsTeamSnapshot {
    param($Session, $Teams)
    $groups = @(Get-SeedTeamsGroups $Session $Teams)
    if ($groups.Count -eq 0) { throw 'Seed.Teams.Pending: Accepted team has not propagated to authoritative reads.' }
    if ($groups.Count -ne 1) { throw 'Seed.Teams.Collision: Exactly one new run group required; never adopt or select newest.' }
    $g = ConvertTo-SeedMap $groups[0]
    Assert-SeedFields $g @('id', 'displayName', 'description', 'groupTypes', 'visibility', 'resourceProvisioningOptions') 'Seed.Teams.Group'
    Assert-SeedGuid $g.id
    if ($g.displayName -cne $Teams.Name -or $g.description -cne $Teams.Description -or $g.visibility -ine 'Private' -or
        (@($g.groupTypes) -join ',') -cne 'Unified' -or 'Team' -cnotin $g.resourceProvisioningOptions -or
        ($Teams.Ids.ContainsKey($Teams.TeamOperationId) -and $Teams.Ids[$Teams.TeamOperationId] -cne $g.id)) { throw 'Seed.Teams.Group: Exact tool-created private Unified Team identity required.' }
    $v = ConvertTo-SeedMap (Invoke-SeedGraph -Session $Session -Method GET -Path "/teams/$($g.id)")
    Assert-SeedFields $v @('id', 'displayName', 'description', 'createdDateTime', 'webUrl') 'Seed.Teams.Team'
    $created = [DateTimeOffset]::Parse($v.createdDateTime, [cultureinfo]::InvariantCulture)
    if ($v.id -cne $g.id -or $v.displayName -cne $Teams.Name -or $v.description -cne $Teams.Description -or
        $created -ne [DateTimeOffset]::Parse($Teams.ById[$Teams.TeamOperationId].TeamsScope.Body.createdDateTime, [cultureinfo]::InvariantCulture)) { throw 'Seed.Teams.Team: Actual team, imported creation time and backing group identity must match.' }
    $Teams.Ids[$Teams.TeamOperationId] = $v.id
    return @{ id = $v.id; displayName = $v.displayName; description = $v.description; webUrl = Assert-SeedTeamsLink $v.webUrl
        createdDateTime = $created.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        groupTypes = @($g.groupTypes); visibility = $g.visibility; provisioning = @($g.resourceProvisioningOptions | Sort-Object) }
}

function Get-SeedTeamsChannelSnapshot {
    param($Session, $Teams, [string]$Key)
    $teamId = $Teams.Ids[$Teams.TeamOperationId]; $c = $Teams.Channels[$Key]
    if ([string]::IsNullOrWhiteSpace($teamId)) { throw 'Seed.Teams.Parent: Verified actual new team ID required.' }
    if ($c.Primary) { $v = ConvertTo-SeedMap (Invoke-SeedGraph -Session $Session -Method GET -Path "/teams/$teamId/primaryChannel") }
    else {
        $values = @(Get-SeedGraphCollection -Session $Session -Path "/teams/$teamId/channels" -MaxPages 20 | Where-Object displayName -CEQ $c.Name)
        if ($values.Count -eq 0) { throw 'Seed.Teams.Pending: Accepted channel has not propagated to authoritative reads.' }
        if ($values.Count -ne 1) { throw 'Seed.Teams.Channel: Exact unique new channel required.' }
        $v = ConvertTo-SeedMap (Invoke-SeedGraph -Session $Session -Method GET -Path "/teams/$teamId/channels/$([uri]::EscapeDataString($values[0].id))")
    }
    Assert-SeedFields $v @('id', 'displayName', 'membershipType', 'createdDateTime', 'webUrl') 'Seed.Teams.Channel'
    $created = [DateTimeOffset]::Parse($v.createdDateTime, [cultureinfo]::InvariantCulture)
    if ($v.displayName -cne $c.Name -or $v.membershipType -cne 'standard' -or [string]::IsNullOrWhiteSpace($v.id)) { throw 'Seed.Teams.Channel: Only exact standard channels supported.' }
    $keyId = "channel:$Key"
    if ($Teams.Ids.ContainsKey($keyId) -and $Teams.Ids[$keyId] -cne $v.id) { throw 'Seed.Teams.Channel: Actual channel ID changed.' }
    if (-not $c.Primary -and ($v.description -cne $Teams.ById[$c.ParentOperationId].TeamsScope.Body.description -or
        $created -ne [DateTimeOffset]::Parse($Teams.ById[$c.ParentOperationId].TeamsScope.Body.createdDateTime, [cultureinfo]::InvariantCulture) -or
        ($Teams.Ids.ContainsKey($c.ParentOperationId) -and $Teams.Ids[$c.ParentOperationId] -cne $v.id))) { throw 'Seed.Teams.Channel: Exact run marker and receipted channel ID required.' }
    foreach ($id in $c.Messages) {
        if ($created -ge [DateTimeOffset]::Parse($Teams.ById[$id].TeamsScope.CreatedDateTime, [cultureinfo]::InvariantCulture)) { throw 'Seed.Teams.Time: Actual parent channel must predate every imported message.' }
    }
    $Teams.Ids[$keyId] = $v.id
    return @{ id = $v.id; teamId = $teamId; displayName = $v.displayName; membershipType = $v.membershipType
        createdDateTime = $created.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        webUrl = Assert-SeedTeamsLink $v.webUrl; description = $(if ($c.Primary) { '' } else { $v.description }) }
}

function Get-SeedTeamsMessageBody {
    param($Scope, $Assets)
    $html = $Scope.BodyHtml
    foreach ($a in $Scope.AssetRefs) {
        if (-not $Assets.ContainsKey($a)) { throw 'Seed.Teams.Asset: Every reference requires verified Storage output.' }
        $html = $html.Replace('{{asset:' + $a + '}}', [Net.WebUtility]::HtmlEncode($Assets[$a]))
    }
    $mentions = @()
    foreach ($m in $Scope.Mentions) {
        $mentions += @{ id = $m.id; mentionText = $m.mentionText; mentioned = $m.mentioned }
    }
    $tags = [regex]::Matches($html, '(?is)<at\b[^>]*>[^<]*</at\s*>')
    if ($tags.Count -ne $mentions.Count) { throw 'Seed.Teams.Mention: Every canonical mention must be regenerated from its actual identity.' }
    # Replace backwards so original offsets remain valid; canonical validation already
    # proved the ordered IDs and decoded role labels, irrespective of quote/entity spelling.
    for ($i = $tags.Count - 1; $i -ge 0; $i--) {
        $text = '<at id="' + $mentions[$i].id + '">' + [Net.WebUtility]::HtmlEncode($mentions[$i].mentionText) + '</at>'
        $html = $html.Remove($tags[$i].Index, $tags[$i].Length).Insert($tags[$i].Index, $text)
    }
    if ($html.Contains('{{') -or $html.Contains('}}')) { throw 'Seed.Teams.Asset: Unresolved template syntax is never posted.' }
    return @{ createdDateTime = $Scope.CreatedDateTime
        from = @{ user = @{ id = $Scope.AuthorId; displayName = $Scope.AuthorName; userIdentityType = 'aadUser' } }
        body = @{ contentType = 'html'; content = $html }; mentions = $mentions }
}

function Compare-SeedTeamsHtml {
    param([string]$Expected, [string]$Actual)
    $code = @'
import json,sys,re
from html.parser import HTMLParser
class Proof(HTMLParser):
    def __init__(self): super().__init__(convert_charrefs=True); self.stack=[]; self.events=[]
    def handle_starttag(self,t,a):
        tags={"p","br","strong","em","b","i","u","table","thead","tbody","tr","th","td","a","ul","ol","li","at"}
        if t not in tags or len(dict(a))!=len(a): raise ValueError("unsupported markup")
        a=dict(a)
        if set(a)-({"href"} if t=="a" else {"id"} if t=="at" else set()): raise ValueError("unsupported attributes")
        if t=="tbody" and (not self.stack or self.stack[-1]!="table"): raise ValueError("misplaced row group")
        if t!="tbody": self.events.append(["start",{"b":"strong","i":"em"}.get(t,t),a])
        if t!="br": self.stack.append(t)
    def handle_endtag(self,t):
        if not self.stack or self.stack.pop()!=t: raise ValueError("unbalanced HTML")
        if t!="tbody": self.events.append(["end",{"b":"strong","i":"em"}.get(t,t)])
    def handle_startendtag(self,t,a):
        if t!="br": raise ValueError("invalid empty tag")
        self.handle_starttag(t,a)
    def handle_data(self,s):
        s=re.sub(r"\s+"," ",s)
        if self.events and self.events[-1][0]=="text": self.events[-1][1]+=s
        else: self.events.append(["text",s])
    def handle_comment(self,s): raise ValueError("comment")
    def handle_decl(self,s): raise ValueError("declaration")
    def handle_pi(self,s): raise ValueError("processing instruction")
    def proof(self,s):
        if "{{" in s or "}}" in s or len(s)>2097152: raise ValueError("invalid body")
        self.feed(s)
        if self.rawdata: raise ValueError("incomplete body")
        self.close()
        if self.stack: raise ValueError("unclosed tag")
        return [e if e[0]!="text" else ["text",e[1].strip()] for e in self.events if e[0]!="text" or e[1].strip()]
d=json.load(sys.stdin); e=Proof().proof(d["expected"]); a=Proof().proof(d["actual"])
if e!=a: raise ValueError("full body differs")
print(json.dumps(a,ensure_ascii=False))
'@
    try { return ,@(Invoke-SeedPython -Code $code -InputObject @{ expected = $Expected; actual = $Actual }) }
    catch { throw 'Seed.Teams.Content: Exact normalized HTML, mention labels, formatting, text and links required.' }
}

function Get-SeedTeamsMessageSnapshot {
    param($Session, $Teams, $Operation)
    $s = $Operation.TeamsScope
    $channel = Get-SeedTeamsChannelSnapshot $Session $Teams $s.ChannelKey
    $prefix = "/teams/$($channel.teamId)/channels/$([uri]::EscapeDataString($channel.id))/messages"
    $parentId = $null
    if ($s.Kind -ceq 'Reply') { $parentId = $Teams.Ids[$s.ParentOperationId]; $prefix += '/' + [uri]::EscapeDataString($parentId) + '/replies' }
    $id = $Teams.Ids[$Operation.OperationId]
    if ([string]::IsNullOrWhiteSpace($id)) { throw 'Seed.Teams.Message: Actual response or Completed receipt ID required.' }
    $v = ConvertTo-SeedMap (Invoke-SeedGraph -Session $Session -Method GET -Path ($prefix + '/' + [uri]::EscapeDataString($id)))
    Assert-SeedFields $v @('id', 'createdDateTime', 'from', 'body', 'mentions', 'webUrl', 'messageType') 'Seed.Teams.Message'
    if (-not $v.Contains('replyToId') -or $v.replyToId -cne $parentId -or $v.id -cne $id -or $v.messageType -cne 'message' -or
        ($v.Contains('deletedDateTime') -and $null -ne $v.deletedDateTime) -or $v.from.user.id -ine $s.AuthorId -or
        $v.from.user.displayName -cne $s.AuthorName -or $v.from.user.userIdentityType -cne 'aadUser' -or $v.body.contentType -ine 'html' -or
        [DateTimeOffset]::Parse($v.createdDateTime, [cultureinfo]::InvariantCulture) -ne [DateTimeOffset]::Parse($s.CreatedDateTime, [cultureinfo]::InvariantCulture)) { throw 'Seed.Teams.Message: Exact actual author, historical instant, root/reply identity and HTML required.' }
    if ($v.Contains('channelIdentity') -and ($v.channelIdentity.teamId -cne $channel.teamId -or $v.channelIdentity.channelId -cne $channel.id)) { throw 'Seed.Teams.Message: Channel identity changed.' }
    $expected = Get-SeedTeamsMessageBody $s $Teams.Resolved
    if ($v.mentions.Count -ne $expected.mentions.Count) { throw 'Seed.Teams.Mention: Exact mention set required.' }
    for ($i = 0; $i -lt $expected.mentions.Count; $i++) {
        $a = $v.mentions[$i]; $b = $expected.mentions[$i]
        if ($a.id -ne $b.id -or $a.mentionText -cne $b.mentionText -or $a.mentioned.user.id -ine $b.mentioned.user.id -or
            $a.mentioned.user.displayName -cne $b.mentioned.user.displayName -or $a.mentioned.user.userIdentityType -cne 'aadUser') { throw 'Seed.Teams.Mention: Exact mapped mention identities and actual displayNames required.' }
    }
    return @{ id = $v.id; operationId = $Operation.OperationId; messageId = $s.MessageId; storyId = $s.StoryId
        teamId = $channel.teamId; channelId = $channel.id; replyToId = $parentId; createdDateTime = $s.CreatedDateTime
        authorId = $v.from.user.id; authorName = $v.from.user.displayName; mentions = $expected.mentions
        body = Compare-SeedTeamsHtml $expected.body.content $v.body.content; webUrl = Assert-SeedTeamsLink $v.webUrl }
}

function Assert-SeedTeamsMessageSet {
    param([AllowEmptyCollection()][string[]]$Actual, [AllowEmptyCollection()][string[]]$Expected)
    if (@($Actual | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0 -or
        @($Expected | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
        throw 'Seed.Teams.Collection: Actual and expected message IDs must be nonempty.'
    }
    if (($Actual -join "`n") -ceq ($Expected -join "`n")) { return }
    if (@($Actual | Sort-Object -Unique).Count -ne $Actual.Count -or
        @($Actual | Where-Object { $_ -cnotin $Expected }).Count -gt 0) {
        throw 'Seed.Teams.Collection: Extra or duplicate message IDs are not permitted.'
    }
    throw 'Seed.Teams.Pending: Known imported message IDs have not propagated to the collection.'
}

function Test-SeedTeamsMessageSets {
    param($Session, $Teams, [string]$ChannelKey)
    $c = Get-SeedTeamsChannelSnapshot $Session $Teams $ChannelKey
    $base = "/teams/$($c.teamId)/channels/$([uri]::EscapeDataString($c.id))/messages"
    $roots = @($Teams.Channels[$ChannelKey].Messages | Where-Object { $Teams.ById[$_].TeamsScope.Kind -ceq 'Root' })
    $messages = @(Get-SeedGraphCollection -Session $Session -Path $base -MaxPages 20)
    $actual = @(foreach ($message in $messages) {
        $knownEvent = $message.Contains('eventDetail') -and $message.eventDetail -is [Collections.IDictionary] -and
            $message.eventDetail.Contains('@odata.type') -and $message.eventDetail.'@odata.type' -cin @(
                '#microsoft.graph.channelAddedEventMessageDetail', '#microsoft.graph.membersAddedEventMessageDetail')
        $noUser = -not $message.Contains('from') -or $null -eq $message.from -or
            ($message.from -is [Collections.IDictionary] -and (-not $message.from.Contains('user') -or $null -eq $message.from.user))
        $noReply = -not $message.Contains('replyToId') -or $null -eq $message.replyToId
        $sameChannel = $true
        if ($message.Contains('channelIdentity') -and $null -ne $message.channelIdentity) {
            $sameChannel = $message.channelIdentity -is [Collections.IDictionary] -and
                $message.channelIdentity.Contains('teamId') -and $message.channelIdentity.Contains('channelId') -and
                $message.channelIdentity.teamId -ceq $c.teamId -and $message.channelIdentity.channelId -ceq $c.id
        }
        if ($message.Contains('id') -and -not [string]::IsNullOrWhiteSpace($message.id) -and
            $message.Contains('messageType') -and $message.messageType -cin @('systemEventMessage', 'unknownFutureValue') -and
            $knownEvent -and $noUser -and $noReply -and $sameChannel) { continue }
        $message.id
    })
    $actual = @($actual | Sort-Object)
    $expected = @($roots | ForEach-Object { $Teams.Ids[$_] } | Sort-Object)
    Assert-SeedTeamsMessageSet -Actual $actual -Expected $expected
    foreach ($rootId in $roots) {
        $children = @($Teams.Channels[$ChannelKey].Messages | Where-Object { $Teams.ById[$_].TeamsScope.Kind -ceq 'Reply' -and $Teams.ById[$_].TeamsScope.ParentOperationId -ceq $rootId })
        $actual = @(Get-SeedGraphCollection -Session $Session -Path ($base + '/' + [uri]::EscapeDataString($Teams.Ids[$rootId]) + '/replies') -MaxPages 20 | ForEach-Object { $_.id } | Sort-Object)
        $expected = @($children | ForEach-Object { $Teams.Ids[$_] } | Sort-Object)
        Assert-SeedTeamsMessageSet -Actual $actual -Expected $expected
    }
}

function Get-SeedTeamsSnapshot {
    param($Session, $Teams, $Operation)
    $s = $Operation.TeamsScope; $tid = $Teams.Ids[$Teams.TeamOperationId]
    switch ($s.Kind) {
        Team { return Get-SeedTeamsTeamSnapshot $Session $Teams }
        Channel { return Get-SeedTeamsChannelSnapshot $Session $Teams $s.ChannelKey }
        { $_ -cin @('Root', 'Reply') } { return Get-SeedTeamsMessageSnapshot $Session $Teams $Operation }
        CompleteChannel {
            $channel = Get-SeedTeamsChannelSnapshot $Session $Teams $s.ChannelKey
            $mode = & (Get-SeedSessionRecord $Session).TeamsCompletionProbe $Operation "/teams/$($channel.teamId)/channels/$([uri]::EscapeDataString($channel.id))/completeMigration"
            if ($mode -cne 'completed') { throw 'Seed.Teams.Pending: Accepted channel completion has not propagated.' }
            Test-SeedTeamsMessageSets $Session $Teams $s.ChannelKey
            $messages = @($Teams.Channels[$s.ChannelKey].Messages | ForEach-Object { Get-SeedTeamsMessageSnapshot $Session $Teams $Teams.ById[$_] })
            return @{ id = $channel.id; channel = $channel; messages = $messages; migrationMode = $mode }
        }
        CompleteTeam {
            $team = Get-SeedTeamsTeamSnapshot $Session $Teams
            $channels = @($Teams.Channels.Keys | Sort-Object | ForEach-Object { Get-SeedTeamsSnapshot $Session $Teams $Teams.ById[$Teams.Channels[$_].CompleteOperationId] })
            return @{ id = $team.id; team = $team; channels = $channels }
        }
        Owner {
            $owners = @(Get-SeedGraphCollection -Session $Session -Path "/groups/$tid/owners?`$select=id" -MaxPages 20 | ForEach-Object { $_.id } | Sort-Object)
            if ($owners.Count -eq 0) { throw 'Seed.Teams.Pending: Accepted group ownership has not propagated to authoritative reads.' }
            if (($owners -join ',') -cne $Teams.PresenterId) { throw 'Seed.Teams.Owner: Actual Presenter must be the exact group owner, never repaired on rerun.' }
            return @{ id = $Teams.PresenterId; teamId = $tid; owners = $owners }
        }
        GroupMember {
            $allMembers = @(Get-SeedGraphCollection -Session $Session -Path "/groups/$tid/members?`$select=id" -MaxPages 20)
            $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($member in $allMembers) {
                if ($member -isnot [Collections.IDictionary] -or -not $member.Contains('id') -or
                    $member.id -isnot [string] -or [string]::IsNullOrWhiteSpace($member.id) -or -not $seen.Add($member.id)) {
                    throw 'Seed.Teams.Member: Malformed or duplicate backing group membership evidence.'
                }
            }
            $members = @($allMembers | Where-Object id -IEQ $s.UserId)
            if ($members.Count -eq 0) { throw 'Seed.Teams.Pending: Accepted backing group membership has not propagated to authoritative reads.' }
            if ($members.Count -ne 1 -or $members[0].id -isnot [string] -or $members[0].id -cne $s.UserId) {
                throw 'Seed.Teams.Member: Exact actual backing group member identity required.'
            }
            return @{ id = $members[0].id; teamId = $tid; userId = $s.UserId }
        }
        Member {
            $members = @(Get-SeedGraphCollection -Session $Session -Path "/teams/$tid/members" -MaxPages 20 | Where-Object userId -IEQ $s.UserId)
            if ($members.Count -eq 0) { throw 'Seed.Teams.Pending: Accepted membership has not propagated to authoritative reads.' }
            if ($members.Count -ne 1 -or [string]::IsNullOrWhiteSpace($members[0].id) -or $members[0].tenantId -ine $Teams.Context.tenantId -or
                (@($members[0].roles | Sort-Object) -join ',') -cne (@($s.Body.roles | Sort-Object) -join ',')) { throw 'Seed.Teams.Member: Exact actual Teams user membership and owner role required.' }
            $m = $members[0]
            if ($Teams.Ids.ContainsKey($Operation.OperationId) -and $Teams.Ids[$Operation.OperationId] -cne $m.id) { throw 'Seed.Teams.Member: Receipted membership ID changed.' }
            $groups = @(Get-SeedGraphCollection -Session $Session -Path "/groups/$tid/members?`$select=id" -MaxPages 20 | Where-Object id -IEQ $s.UserId)
            if ($groups.Count -eq 0) { throw 'Seed.Teams.Pending: Accepted backing group membership has not propagated to authoritative reads.' }
            if ($groups.Count -ne 1) { throw 'Seed.Teams.Member: Actual backing group membership required.' }
            return @{ id = $m.id; teamId = $tid; userId = $m.userId; tenantId = $m.tenantId; roles = @($m.roles | Sort-Object); groupMemberId = $groups[0].id }
        }
        default { throw 'Seed.Teams.Scope: Unknown operation kind.' }
    }
}

function Get-SeedTeamsRequest {
    param($Session, $Teams, $Operation)
    $s = $Operation.TeamsScope
    $tid = $Teams.Ids[$Teams.TeamOperationId]
    $q = @{ OperationId = $Operation.OperationId; Method = 'POST'; Body = $(if ($s.Contains('Body')) { $s.Body } else { $null }) }
    switch ($s.Kind) {
        Team { $q.Path = '/teams' }
        Channel { $q.Path = "/teams/$tid/channels" }
        { $_ -cin @('Root', 'Reply', 'CompleteChannel') } {
            $channel = Get-SeedTeamsChannelSnapshot $Session $Teams $s.ChannelKey
            $q.Path = "/teams/$tid/channels/$([uri]::EscapeDataString($channel.id))"
            if ($s.Kind -ceq 'CompleteChannel') { $q.Path += '/completeMigration' }
            else {
                $q.Path += '/messages'
                if ($s.Kind -ceq 'Reply') { $q.Path += '/' + [uri]::EscapeDataString($Teams.Ids[$s.ParentOperationId]) + '/replies' }
                $q.Body = Get-SeedTeamsMessageBody $s $Teams.Resolved
            }
        }
        CompleteTeam { $q.Path = "/teams/$tid/completeMigration" }
        Owner { $q.Path = "/groups/$tid/owners/`$ref" }
        GroupMember { $q.Path = "/groups/$tid/members/`$ref" }
        Member { $q.Path = "/teams/$tid/members" }
        default { throw 'Seed.Teams.Scope: Unknown write kind.' }
    }
    return $q
}

function Resolve-SeedTeamsAssets {
    param($Session, $Teams, $AssetUrlMap = $null)
    try { $a = Resolve-SeedOutlookAssets $Session $Teams $AssetUrlMap; $Teams.Resolved = $a.Assets }
    catch { throw 'Seed.Teams.Asset: Only unchanged same-session, same-context verified Storage content and actual URLs are accepted.' }
}

function Test-SeedTeamsRequest {
    param($Session, $Teams, $Operation, $Request)
    $null = Get-SeedTeamsRecord $Session $Teams.Handle
    if (-not $Teams.ById.ContainsKey($Operation.OperationId) -or
        (Get-SeedOperationDigest $Operation) -cne (Get-SeedOperationDigest $Teams.ById[$Operation.OperationId]) -or $Operation.TeamsScope.Kind -ceq 'Team') { throw 'Seed.Teams.Request: Exact original late-bound scope required.' }
    Assert-SeedTeamsActors $Session $Teams
    Resolve-SeedTeamsAssets $Session $Teams
    $approval = (Get-SeedSessionRecord $Session).Approval
    $state = Get-SeedRunState -Path $approval.Path -RunId $approval.RunId -Context $approval.Context -Operations $approval.Operations
    foreach ($id in @($Teams.TeamOperationId) + @($Operation.TeamsScope.Dependencies) | Sort-Object -Unique) {
        $receipt = @($state.results | Where-Object { $_.workload -ceq 'teams' -and $_.id -ceq $id -and $_.status -ceq 'Verified' })
        $snapshot = Get-SeedTeamsSnapshot $Session $Teams $Teams.ById[$id]
        if ($receipt.Count -ne 1 -or $snapshot.id -cne $receipt[0].objectId -or (Get-SeedFingerprint $snapshot) -cne $receipt[0].evidence.sha256) { throw 'Seed.Teams.Parent: Fresh full parent evidence and actual ID must equal the Verified receipt.' }
    }
    $expected = Get-SeedTeamsRequest $Session $Teams $Teams.ById[$Operation.OperationId]
    $digest = Get-SeedRequestFingerprint $Request.Method $Request.Path $Request.Body $null
    if ($Request.Contains('RawBody') -or $digest -cne (Get-SeedRequestFingerprint $expected.Method $expected.Path $expected.Body $null)) { throw 'Seed.Teams.Request: Exact actual parent, author, timestamps, mentions and body required.' }
    $parent = $Operation.TeamsScope.ParentOperationId
    return @{ OperationFingerprint = Get-SeedOperationDigest $Operation; RequestFingerprint = $digest; MatchesPlan = $true; PresenterVerified = $true
        ParentOperationId = $parent; ParentObjectId = $Teams.Ids[$parent] }
}

function Get-SeedTeamsProof {
    param($Session, $Teams, $Operation)
    $null = Get-SeedTeamsRecord $Session $Teams.Handle
    if (-not $Teams.ById.ContainsKey($Operation.OperationId) -or
        (Get-SeedOperationDigest $Operation) -cne (Get-SeedOperationDigest $Teams.ById[$Operation.OperationId])) { throw 'Seed.Teams.Scope: Only original upfront scope accepted.' }
    Assert-SeedTeamsActors $Session $Teams; Assert-SeedTeamsSources $Teams
    if ($null -ne $Teams.RunState -and $Teams.RunState.status -ceq 'Completed') {
        Assert-SeedTeamsJournal $Teams $Teams.RunState
        Resolve-SeedTeamsAssets $Session $Teams
        $s = Get-SeedTeamsSnapshot $Session $Teams $Teams.ById[$Operation.OperationId]
        Test-SeedTeamsCollections $Session $Teams
        $Teams.Evidence[$Operation.OperationId] = $s
        return @{ State = 'Existing'; ToolOwned = $true; ContentVerified = $true; PresenterVerified = $true
            ObjectId = $s.id; DataFingerprint = $Operation.DataFingerprint; EvidenceFingerprint = Get-SeedFingerprint $s }
    }
    if ($null -ne $Teams.RunState -and $Teams.RunState.status -cne 'Planned') { throw 'Seed.Teams.State: No partial repair.' }
    if (@(Get-SeedTeamsGroups $Session $Teams).Count -ne 0) { throw 'Seed.Teams.Collision: Existing group/team is never adopted without an exact Completed journal.' }
    return @{ State = 'Absent'; AbsenceVerified = $true; PresenterVerified = $true }
}

function Test-SeedTeamsCollections {
    param($Session, $Teams)
    $tid = $Teams.Ids[$Teams.TeamOperationId]
    foreach ($key in $Teams.Channels.Keys) { $null = Get-SeedTeamsChannelSnapshot $Session $Teams $key }
    $actual = @(Get-SeedGraphCollection -Session $Session -Path "/teams/$tid/channels" -MaxPages 20 | ForEach-Object { $_.id } | Sort-Object)
    $expected = @($Teams.Channels.Keys | ForEach-Object { $Teams.Ids["channel:$_"] } | Sort-Object)
    if (($actual -join ',') -cne ($expected -join ',')) { throw 'Seed.Teams.Collection: Exact full standard channel set including primary required.' }
    foreach ($key in $Teams.Channels.Keys) { Test-SeedTeamsMessageSets $Session $Teams $key }
    $actual = @(Get-SeedGraphCollection -Session $Session -Path "/teams/$tid/members" -MaxPages 20 | ForEach-Object { $_.userId } | Sort-Object)
    $expected = @($Teams.Roles | ForEach-Object { (Get-SeedSessionRecord $Session).Identity.Roles[$_].ObjectId } | Sort-Object)
    if (($actual -join ',') -cne ($expected -join ',')) { throw 'Seed.Teams.Collection: Complete actual actor and Presenter Team membership required.' }
    $actual = @(Get-SeedGraphCollection -Session $Session -Path "/groups/$tid/members?`$select=id" -MaxPages 20 | ForEach-Object { $_.id } | Sort-Object)
    if (($actual -join ',') -cne ($expected -join ',')) { throw 'Seed.Teams.Collection: Complete backing group membership required.' }
}

function Get-SeedTeamsOutput {
    param($Teams, [bool]$Verified)
    $messages = @($Teams.Operations | Where-Object { $_.TeamsScope.Kind -cin @('Root', 'Reply') } | ForEach-Object { $Teams.Evidence[$_.OperationId] })
    $team = $Teams.Evidence[$Teams.TeamOperationId]
    $links = @(@{ kind = 'team'; logicalId = $Teams.Scenario.scenario.id; resourceId = $team.id; displayName = $team.displayName; webUrl = $team.webUrl; presenterAccessStatus = 'Verified' })
    foreach ($key in @($Teams.Channels.Keys | Sort-Object)) {
        $c = $Teams.Evidence[$Teams.Channels[$key].CompleteOperationId].channel
        $links += @{ kind = 'channel'; logicalId = $(if ($Teams.Channels[$key].LogicalId) { $Teams.Channels[$key].LogicalId } else { 'primary' })
            resourceId = $c.id; displayName = $c.displayName; webUrl = $c.webUrl; presenterAccessStatus = 'Verified' }
    }
    return @{ Team = $team; Messages = $messages; ResourceLinkIndex = $links; Verified = $Verified }
}

function Test-SeedTeams {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Adapter, $AssetUrlMap = $null)
    $t = Get-SeedTeamsRecord $Session $Adapter; $r = Get-SeedSessionRecord $Session
    $r.ReadOnlyDepth++
    try {
        if ($null -eq $t.RunState -or $t.RunState.status -cne 'Completed') { throw 'Seed.Teams.State: Globally Completed journal required.' }
        Assert-SeedTeamsJournal $t $t.RunState; Assert-SeedTeamsActors $Session $t; Assert-SeedTeamsSources $t
        Resolve-SeedTeamsAssets $Session $t $AssetUrlMap
        $t.Evidence.Clear()
        foreach ($op in $t.Operations) {
            $s = Get-SeedTeamsSnapshot $Session $t $op
            $receipt = @($t.RunState.results | Where-Object { $_.workload -ceq 'teams' -and $_.id -ceq $op.OperationId })[0]
            if ($s.id -cne $receipt.objectId -or (Get-SeedFingerprint $s) -cne $receipt.evidence.sha256) { throw 'Seed.Teams.Receipt: Full current readback differs from exact completed receipt.' }
            $t.Evidence[$op.OperationId] = $s
        }
        Test-SeedTeamsCollections $Session $t
        return Get-SeedTeamsOutput $t $true
    } catch { throw 'Seed.Teams.Verify: Exact Team, channel, authors, times, bodies, mentions, parents, membership, links or durable receipts not proven; no writes or repair.' }
    finally { $r.ReadOnlyDepth-- }
}

function Invoke-SeedTeamsChannel {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Adapter, [Parameter(Mandatory)][object[]]$Plan,
        [Parameter(Mandatory)][AllowEmptyCollection()]$AssetUrlMap)
    $t = Get-SeedTeamsRecord $Session $Adapter
    $selected = @($Plan | Where-Object { $_.Workload -ceq 'teams' -and $t.ById.ContainsKey($_.OperationId) })
    if ($selected.Count -ne $t.Operations.Count -or @($Plan | Where-Object Action -eq Block).Count -gt 0 -or
        @($selected | Where-Object Action -notin @('Create', 'Skip')).Count -gt 0) { throw 'Seed.Teams.Plan: Whole global preflight and complete Teams scope required.' }
    foreach ($op in $selected) {
        $v = ConvertTo-SeedMap $op
        if ($op.Action -ceq 'Skip') {
            if (-not $t.Ids.ContainsKey($op.OperationId) -or $op.TargetId -cne $t.Ids[$op.OperationId]) { throw 'Seed.Teams.Plan: Exact Completed actual ID required.' }
            $v.TargetId = $null
        }
        if ((Get-SeedOperationDigest $v) -cne (Get-SeedOperationDigest $t.ById[$op.OperationId])) { throw 'Seed.Teams.Plan: Exact upfront scope changed.' }
    }
    if (@($selected | Where-Object Action -eq Skip).Count -eq $selected.Count) { return Test-SeedTeams $Session $Adapter $AssetUrlMap }
    if (@($selected | Where-Object Action -eq Skip).Count -gt 0) { throw 'Seed.Teams.Plan: No mixed partial resume.' }
    $r = Get-SeedSessionRecord $Session; $approval = $r.Approval
    if ($null -eq $approval -or $approval.Path -cne $t.StatePath -or $approval.RunId -cne $t.RunId -or
        (Get-SeedFingerprint $Plan) -cne $approval.PlanFingerprint) { throw 'Seed.Teams.Approval: Exact global approval must precede all writes.' }
    Assert-SeedTeamsActors $Session $t; Assert-SeedTeamsSources $t
    Resolve-SeedTeamsAssets $Session $t $AssetUrlMap
    if (@(Get-SeedTeamsGroups $Session $t).Count -ne 0) { throw 'Seed.Teams.Collision: Team namespace no longer absent; no adoption.' }
    foreach ($op in $t.Operations) {
        if ($op.TeamsScope.Kind -cin @('Root', 'Reply')) {
            $b = Get-SeedTeamsMessageBody $op.TeamsScope $t.Resolved
            $null = Compare-SeedTeamsHtml $b.body.content $b.body.content
        }
    }
    foreach ($op in $t.Operations) {
        $id = $null
        try {
            $q = Get-SeedTeamsRequest $Session $t $op
            $response = Write-SeedGraph -Session $Session -Request $q -RequestCheck $t.RequestCheck
            if ($op.TeamsScope.Kind -cin @('Root', 'Reply')) {
                if ($null -eq $response -or [string]::IsNullOrWhiteSpace($response.id)) { throw 'Seed.Teams.Message: Actual created message ID required.' }
                $id = $response.id; $t.Ids[$op.OperationId] = $id
            }
            # Poll only authoritative GET propagation, never retry a write.
            for ($attempt = 0; $attempt -lt 31; $attempt++) {
                try { $snapshot = Get-SeedTeamsSnapshot $Session $t $op; break }
                catch {
                    if ($attempt -eq 30 -or $_.Exception.Message -notmatch '^Seed\.(Teams\.Pending|Graph\.404):') { throw }
                    & $r.Delay 2 | Out-Null
                }
            }
            $id = $snapshot.id; $t.Ids[$op.OperationId] = $id; $t.Evidence[$op.OperationId] = $snapshot
            Write-SeedRunEvent -Path $approval.Path -RunId $approval.RunId -Context $approval.Context -Operations $approval.Operations -OperationId $op.OperationId -Workload teams -Action Verify -Status Verified -ObjectId $id -ReadBack $snapshot | Out-Null
        } catch {
            $diagnostic = @{
                Stage = 'TeamsReadBack'; HttpStatus = (Get-SeedGraphFailure $_.Exception).Status
                ExceptionType = $_.Exception.GetType().FullName
            }
            if ($_.Exception.Data.Contains('SeedDiagnostic')) { $diagnostic = $_.Exception.Data['SeedDiagnostic'] }
            $code = [regex]::Match($_.Exception.Message, '\bSeed\.[A-Za-z0-9_.]+').Value
            $diagnostic.ErrorCode = $(if ($code) { $code } else { 'Seed.Teams.ReadBack' })
            Write-Host ('[TeamsDiagnostic] ' + ($diagnostic | ConvertTo-Json -Compress))
            $state = Get-SeedRunState -Path $approval.Path -RunId $approval.RunId -Context $approval.Context -Operations $approval.Operations
            $result = @($state.results | Where-Object { $_.workload -ceq 'teams' -and $_.id -ceq $op.OperationId })[0]
            if ($result.status -ceq 'Submitted') {
                Write-SeedRunEvent -Path $approval.Path -RunId $approval.RunId -Context $approval.Context -Operations $approval.Operations -OperationId $op.OperationId -Workload teams -Action Fail -Status Unknown -ObjectId $id -ErrorCode TeamsReadBackUnknown | Out-Null
            }
            $failure = [InvalidOperationException]::new('Seed.Teams.Stopped: Preserve journal and remote resources; unknown or partial migration is never resumed, completed again or repaired.')
            $failure.Data['SeedDiagnostic'] = $diagnostic
            throw $failure
        }
    }
    $state = Get-SeedRunState -Path $approval.Path -RunId $approval.RunId -Context $approval.Context -Operations $approval.Operations
    if ($state.status -ceq 'Completed') {
        Set-SeedTeamsRunState $Session $Adapter $state
        return Test-SeedTeams $Session $Adapter $AssetUrlMap
    }
    Test-SeedTeamsCollections $Session $t
    return Get-SeedTeamsOutput $t $false
}
