function Get-SeedOperationPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Operations, [Parameter(Mandatory)][hashtable]$ResourceChecks, $RunState = $null)
    $record = Get-SeedSessionRecord $Session
    $record.LastPlanFingerprint = $null
    $null = Get-SeedOperationKeys $Operations
    $trustedState = $true
    if ($null -ne $RunState) {
        try {
            $trustedState = $script:SeedValidatedStates.ContainsKey((Get-SeedFingerprint $RunState)) -and $RunState.context.tenantId -ieq $record.TenantId -and $RunState.context.clientId -ieq $record.ClientId
            $expectedKeys = @(Get-SeedOperationKeys $Operations)
            $actualKeys = @($RunState.results | ForEach-Object { "$($_.workload)/$($_.id)" } | Sort-Object)
            if (($expectedKeys -join ',') -cne ($actualKeys -join ',')) { $trustedState = $false }
            foreach ($operation in $Operations) {
                $marker = @($RunState.events | Where-Object { $_.action -eq 'Plan' -and $_.id -ceq $operation.OperationId -and $_.workload -ceq $operation.Workload })
                if ($marker.Count -ne 1 -or $marker[0].objectId -cne ('plan-sha256:' + (Get-SeedOperationDigest $operation))) { $trustedState = $false }
            }
        } catch { $trustedState = $false }
    }
    $record.ReadOnlyDepth++
    $plan = [System.Collections.Generic.List[object]]::new()
    try {
        foreach ($entry in $Operations) {
            $operation = ConvertTo-SeedMap $entry
            $item = @{}
            foreach ($key in $operation.Keys) { $item[$key] = $operation[$key] }
            $item.Action = 'Block'; $item.Reason = 'AuthoritativeResourceCheckRequired'
            try {
                if (-not $trustedState) { throw 'untrusted-state' }
                Assert-SeedFields $operation.PresenterEvidence @('verified', 'objectId') 'Seed.Plan.Presenter'
                if ($operation.PresenterEvidence.verified -isnot [bool] -or -not $operation.PresenterEvidence.verified) { throw 'unverified' }
                Assert-SeedGuid $operation.PresenterEvidence.objectId
                if (-not $ResourceChecks.ContainsKey($operation.Workload) -or $ResourceChecks[$operation.Workload] -isnot [scriptblock]) { throw 'missing' }
                $proof = ConvertTo-SeedMap (& $ResourceChecks[$operation.Workload] $Session $operation)
                Assert-SeedFields $proof @('State', 'PresenterVerified') 'Seed.Plan.Proof'
                if ($proof.PresenterVerified -isnot [bool] -or -not $proof.PresenterVerified) { throw 'presenter' }
                if ($proof.State -ceq 'Absent' -and $proof.Contains('AbsenceVerified') -and $proof.AbsenceVerified -is [bool] -and $proof.AbsenceVerified -and $null -eq $RunState) {
                    $item.Action = 'Create'; $item.Reason = 'AuthoritativeAbsenceVerified'
                } elseif ($proof.State -ceq 'Absent' -and $proof.Contains('AbsenceVerified') -and $proof.AbsenceVerified -ceq $true -and $null -ne $RunState -and $RunState.status -eq 'Planned') {
                    $item.Action = 'Create'; $item.Reason = 'AuthoritativeAbsenceVerified'
                } elseif ($proof.State -ceq 'Existing' -and $null -ne $RunState -and $RunState.status -ceq 'Completed') {
                    Assert-SeedFields $proof @('ToolOwned', 'ContentVerified', 'ObjectId', 'DataFingerprint', 'EvidenceFingerprint') 'Seed.Plan.Proof'
                    $result = @($RunState.results | Where-Object { $_.id -ceq $operation.OperationId -and $_.workload -ceq $operation.Workload })
                    if ($proof.ToolOwned -is [bool] -and $proof.ToolOwned -and $proof.ContentVerified -is [bool] -and $proof.ContentVerified -and
                        $proof.DataFingerprint -ceq $operation.DataFingerprint -and $result.Count -eq 1 -and $result[0].status -ceq 'Verified' -and
                        $result[0].objectId -ceq $proof.ObjectId -and $result[0].evidence.sha256 -ceq $proof.EvidenceFingerprint) {
                        $item.Action = 'Skip'; $item.TargetId = $proof.ObjectId; $item.Reason = 'ExactCompletedRunAndFreshReadBack'
                    }
                }
            } catch {
                $item.Action = 'Block'; $item.Reason = 'ResourceIdentityContentOrPresenterNotProven'
                $code = [regex]::Match($_.Exception.Message, '\bSeed\.[A-Za-z0-9_.]+').Value
                $item.FailureCode = $(if ($code) { $code } else { 'Seed.Plan.ResourceCheck' })
                $item.FailureType = $_.Exception.GetType().Name
                if ($_.Exception -is [Management.Automation.CommandNotFoundException] -and $_.CategoryInfo.TargetName -cmatch '^[A-Za-z][A-Za-z0-9-]{0,80}$') {
                    $item.MissingCommand = $_.CategoryInfo.TargetName
                }
            }
            $plan.Add($item)
        }
    } finally { $record.ReadOnlyDepth-- }
    $resultPlan = $plan.ToArray()
    # Keep a process-local digest; a caller-edited plan is not a write capability.
    $record.LastPlanFingerprint = Get-SeedFingerprint $resultPlan
    return $resultPlan
}

function Get-SeedRequestFingerprint {
    param([string]$Method, [string]$Path, $Body, [byte[]]$RawBody)
    $rawHash = $null
    if ($null -ne $RawBody) { $rawHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($RawBody)).ToLowerInvariant() }
    Get-SeedFingerprint @{ method = $Method; path = $Path; body = $Body; rawSha256 = $rawHash }
}

function Assert-SeedWriteAllowlist {
    param($Record, [string]$Method, [string]$Path)
    $resource = ($Path -split '\?', 2)[0]
    if ($Path.Contains('?') -and
        ($Method -cne 'PUT' -or ($Path -split '\?', 2)[1] -cne '@microsoft.graph.conflictBehavior=fail' -or
            $resource -cnotmatch '^/drives/[^/]+/items/[^/]+:/[^/]+:/content$')) {
        throw 'Seed.Write.Allowlist: Only the exact fail-on-conflict new-file query is allowed.'
    }
    if ($Record.Kind -ne 'App' -or $Record.Mode -notin @('RunAll', 'Import')) { throw 'Seed.Write.Mode: No write authorization exists for this session mode.' }
    $guid = '[0-9a-fA-F-]{36}'
    $item = '[A-Za-z0-9!_.~%+,=:@-]+'
    $allowed = ($Method -eq 'POST' -and (
        $resource -match "^/users/$guid/sendMail$" -or $resource -match "^/users/$guid/messages/$item/(reply|createReply)$" -or
        $resource -match "^/users/$guid/messages$" -or $resource -match "^/users/$guid/messages/$item/send$" -or
        $resource -ceq '/groups' -or $resource -ceq '/teams' -or
        $resource -match ('^/groups/' + $guid + '/(owners|members)/\$ref$') -or
        $resource -match "^/teams/$guid/(channels|members|completeMigration)$" -or
        $resource -match "^/teams/$guid/channels/$item/(messages|completeMigration)$" -or
        $resource -match "^/teams/$guid/channels/$item/messages/$item/replies$" -or
        $resource -match "^/drives/$item/(root|items/$item)/children$" -or
        $resource -match "^/drives/$item/items/$item`:/[^/]+`:/createUploadSession$" -or
        $resource -match "^/sites/$item/lists$" -or $resource -match "^/sites/$item/lists/$item/items$")) -or
        ($Method -eq 'PUT' -and ($resource -match "^/drives/$item/items/$item/content$" -or $resource -match "^/drives/$item/(root|items/$item):/.+:/content$")) -or
        ($Method -eq 'PATCH' -and $resource -match "^/users/$guid/messages/$item$")
    if (-not $allowed) { throw 'Seed.Write.Allowlist: Endpoint is outside the explicit content write allowlist; directory writes are never available here.' }
}

function Assert-SeedBoundUserReferences {
    param($Value, [hashtable]$KnownIds)
    if ($null -eq $Value) { return }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            $child = $Value[$key]
            if ($key -ceq 'user' -and $child -is [System.Collections.IDictionary] -and $child.Contains('id') -and -not $KnownIds.ContainsKey([string]$child.id)) { throw 'Seed.Approval.Actor: Referenced user is not in the actual verified actor set.' }
            if ($key -ceq '@odata.id' -or $key -clike '*@odata.bind') {
                foreach ($reference in @($child)) {
                    if ($reference -is [string] -and $reference -match '(?i)/users[/('']') {
                        if ($reference -cnotmatch '^https://graph\.microsoft\.com/v1\.0/users/([0-9a-fA-F-]{36})$' -or -not $KnownIds.ContainsKey($Matches[1])) { throw 'Seed.Approval.Actor: User binding must reference an actual verified Global Graph user ID.' }
                    }
                }
            }
            Assert-SeedBoundUserReferences $child $KnownIds
        }
    } elseif ($Value -is [System.Collections.IList]) {
        foreach ($child in $Value) { Assert-SeedBoundUserReferences $child $KnownIds }
    }
}

function Assert-SeedRequestActors {
    param($Record, [string]$Workload, [string]$Path, $Body)
    $known = @{}
    foreach ($actor in $Record.Identity.Roles.Values) { $known[$actor.ObjectId] = $true }
    if ($Workload -eq 'outlook' -and $Path -cmatch '^/users/([^/]+)/') {
        if (-not $known.ContainsKey($Matches[1]) -or $Matches[1] -ieq $Record.Identity.Presenter.ObjectId) { throw 'Seed.Approval.Actor: Mail must use an actual bound persona mailbox, never Presenter or an arbitrary user.' }
        if ($null -ne $Body -and ($Body.Contains('from') -or $Body.Contains('sender') -or ($Body.Contains('message') -and ($Body.message.Contains('from') -or $Body.message.Contains('sender'))))) { throw 'Seed.Approval.Actor: Mail sender overrides are not allowed.' }
    }
    if ($Workload -eq 'teams' -and $Path -cmatch '/messages(?:/[^/]+/replies)?$') {
        Assert-SeedFields $Body @('from') 'Seed.Approval.Actor'
        Assert-SeedFields $Body.from @('user') 'Seed.Approval.Actor'
        Assert-SeedFields $Body.from.user @('id') 'Seed.Approval.Actor'
        if (-not $known.ContainsKey($Body.from.user.id) -or $Body.from.user.id -ieq $Record.Identity.Presenter.ObjectId) { throw 'Seed.Approval.Actor: Teams author must be an actual bound persona, never Presenter.' }
    }
    Assert-SeedBoundUserReferences $Body $known
}

function Add-SeedExactRequestRule {
    param($Record, [object[]]$Plan, $Request, [hashtable]$Rules, [switch]$DynamicResolved)
        $request = $Request
        $request = ConvertTo-SeedMap $request
        Assert-SeedFields $request @('OperationId', 'Method', 'Path') 'Seed.Approval.Request'
        if ($request.Method -isnot [string] -or $request.Path -isnot [string]) { throw 'Seed.Approval.Request: Method and Path must be strings.' }
        $targets = @($Plan | Where-Object { $_.OperationId -ceq $request.OperationId -and $_.Action -ceq 'Create' })
        if ($targets.Count -ne 1) { throw 'Seed.Approval.Request: Request must identify exactly one Create operation.' }
        $method = $request.Method.ToUpperInvariant()
        $path = ConvertTo-SeedGraphPath $request.Path
        Assert-SeedWriteAllowlist -Record $record -Method $method -Path $path
        $workload = $targets[0].Workload
        $migration = $false
        if ($targets[0].Contains('TeamsScope')) {
            $scope = $targets[0].TeamsScope
            if ($null -eq $scope.InitialRequest) {
                if (-not $DynamicResolved) { throw 'Seed.Approval.Teams: All child operations require exact verified-parent late binding.' }
            } elseif ($method -cne $scope.InitialRequest.Method -or $path -cne $scope.InitialRequest.Path -or
                -not $request.Contains('Body') -or $request.Contains('RawBody') -or
                (Get-SeedFingerprint $request.Body) -cne (Get-SeedFingerprint $scope.InitialRequest.Body)) {
                throw 'Seed.Approval.Teams: Initial migration Team request differs from the exact upfront body.'
            }
            if ($path -ceq '/teams') {
                $migration = $method -ceq 'POST' -and $scope.Contains('Kind') -and $scope.Kind -ceq 'Team' -and $null -ne $scope.InitialRequest -and
                    $request.Body.Contains('@microsoft.graph.teamCreationMode') -and $request.Body.'@microsoft.graph.teamCreationMode' -ceq 'migration'
            }
        }
        if ($path -ceq '/teams' -and -not (Test-SeedAppPermission -Granted $record.Permissions -Required 'Team.Create' -Migration:$migration)) {
            throw 'Seed.Approval.Scope: Team.Create application role or the exact approved migration Team body is required.'
        }
        if ($targets[0].Contains('OutlookScope')) {
            $scope = $targets[0].OutlookScope
            if ($null -eq $scope.InitialRequest) {
                if (-not $DynamicResolved) { throw 'Seed.Approval.Outlook: Replies and asset-bearing messages require exact verified-parent late binding.' }
            } elseif ($method -cne $scope.InitialRequest.Method -or $path -cne $scope.InitialRequest.Path -or
                -not $request.Contains('Body') -or $request.Contains('RawBody') -or
                (Get-SeedFingerprint $request.Body) -cne (Get-SeedFingerprint $scope.InitialRequest.Body)) {
                throw 'Seed.Approval.Outlook: Initial mail request differs from the exact upfront sender, subject, recipients or body.'
            }
        }
        if ($path.EndsWith('/createUploadSession') -and (-not $targets[0].Contains('StorageScope') -or $targets[0].StorageScope.Kind -cne 'Session')) { throw 'Seed.Approval.Storage: Upload sessions require a plan-bound Storage scope.' }
        if ($targets[0].Contains('StorageScope')) {
            $scope = $targets[0].StorageScope
            if ($scope.ParentOperationId) {
                if (-not $DynamicResolved) { throw 'Seed.Approval.Storage: Dynamic storage requests require verified plan-bound parents, not upfront arbitrary paths.' }
            } else {
                $expectedPath = if ($scope.Kind -ceq 'Group') { '/groups' } elseif ($scope.Kind -ceq 'Folder') { "/drives/$($scope.DriveId)/items/$($scope.ParentId)/children" } else { '' }
                if ($method -cne 'POST' -or -not $expectedPath -or $path -cne $expectedPath -or -not $request.Contains('Body') -or $request.Contains('RawBody') -or
                    (Get-SeedFingerprint $request.Body) -cne (Get-SeedFingerprint $scope.Body)) { throw 'Seed.Approval.Storage: Initial storage request differs from the exact approved parent and body.' }
            }
        }
        $compatible = ($workload -eq 'outlook' -and $path -cmatch '^/users/') -or
            ($workload -eq 'teams' -and $path -cmatch '^/(teams|groups)(/|$)') -or
            ($workload -eq 'onedrive' -and $path -cmatch '^/drives/') -or
            ($workload -eq 'sharepoint' -and $path -cmatch '^/(groups|sites|drives)(/|$)')
        if (-not $compatible) { throw 'Seed.Approval.Workload: Exact request endpoint does not belong to the approved operation workload.' }
        $required = switch -Regex ($path) {
            '^/users/.+/(sendMail|reply|send)$' { 'Mail.Send'; break }
            '^/users/' { 'Mail.ReadWrite'; break }
            '^/groups' { 'Group.ReadWrite.All'; break }
            '^/teams/.+/members$' { 'TeamMember.ReadWrite.All'; break }
            '^/teams' { 'Teamwork.Migrate.All'; break }
            '^/drives/' { 'Files.ReadWrite.All'; break }
            '^/sites/' { 'Sites.ReadWrite.All'; break }
        }
        if ($required -cnotin $record.Permissions) { throw 'Seed.Approval.Scope: Exact write application role is missing.' }
        $body = if ($request.Contains('Body')) { $request.Body } else { $null }
        $raw = if ($request.Contains('RawBody')) { $request.RawBody } else { $null }
        if ($null -ne $body -and $null -ne $raw) { throw 'Seed.Approval.Request: Body and RawBody are mutually exclusive.' }
        Assert-SeedRequestActors -Record $record -Workload $workload -Path $path -Body $body
        $digest = Get-SeedRequestFingerprint $method $path $body $raw
        if ($rules.ContainsKey($digest) -or @($rules.Values | Where-Object OperationId -eq $request.OperationId).Count -gt 0) { throw 'Seed.Approval.Request: Exactly one write per journal operation is allowed.' }
        $rules[$digest] = @{ OperationId = $request.OperationId; Workload = $targets[0].Workload; Used = $false }
}

function New-SeedWriteApproval {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][object[]]$Plan, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Requests,
        [Parameter(Mandatory)][string]$ConfirmTarget, [Parameter(Mandatory)][string]$StatePath, [Parameter(Mandatory)][string]$RunId, [Parameter(Mandatory)]$Context)
    $record = Get-SeedSessionRecord $Session
    $Context = ConvertTo-SeedMap $Context
    Assert-SeedFields $Context @('tenantId', 'clientId', 'presenterUpn')
    if ($record.ReadOnlyDepth -gt 0 -or $record.Kind -ne 'App' -or $record.Mode -notin @('RunAll', 'Import') -or
        $ConfirmTarget -cne "$($record.TenantId)/$RunId" -or $Context.tenantId -ine $record.TenantId -or $Context.clientId -ine $record.ClientId -or
        $Context.presenterUpn -ine $record.ExpectedPresenterUpn) { throw 'Seed.Approval: Explicit exact tenant/run confirmation and unchanged Presenter are required for this app session.' }
    if (-not $record.Contains('LastPlanFingerprint') -or (Get-SeedFingerprint $Plan) -cne $record.LastPlanFingerprint -or @($Plan | Where-Object Action -eq Block).Count -gt 0) { throw 'Seed.Approval.Plan: Plan changed, was not checked, or contains a blocking operation.' }
    if (-not $record.Contains('Identity') -or $null -eq $record.Identity -or -not $record.Contains('ServiceGate') -or $null -eq $record.ServiceGate) { throw 'Seed.Approval.Identity: Actual provisioned identities and selected service checks are required before writes.' }
    $identity = $record.Identity
    Assert-SeedFields $Context @('bindingFingerprint', 'personaPackFingerprint', 'instanceId', 'scenarioId')
    if ($Context.bindingFingerprint -cne $identity.BindingFingerprint -or $Context.personaPackFingerprint -cne $identity.PersonaPackFingerprint -or
        $Context.instanceId -cne $identity.InstanceId -or $Context.scenarioId -cne $identity.ScenarioId -or
        $record.ServiceGate.ActorFingerprint -cne $identity.ActorFingerprint) { throw 'Seed.Approval.Identity: Exact actor provenance and journal context differ.' }
    foreach ($operation in $Plan) {
        if ($operation.PresenterEvidence.objectId -ine $identity.Presenter.ObjectId -or $operation.Workload -cnotin $record.ServiceGate.Workloads) { throw 'Seed.Approval.Identity: Presenter or selected workload service gate differs.' }
    }
    if ($null -ne $record.Approval) { throw 'Seed.Approval.Active: This session already owns a run capability.' }
    $operations = @($Plan)
    $StatePath = Assert-SeedStatePath $StatePath
    $lease = Enter-SeedRunLock -Path ($StatePath + '.active')
    try {
        $state = Get-SeedRunState -Path $StatePath -RunId $RunId -Context $Context -Operations $operations -ForImport
        if ($state.status -ne 'Planned') { throw 'Seed.Approval.State: Completed runs only Skip; partial runs are never resumed.' }
        $rules = @{}
        foreach ($request in $Requests) { Add-SeedExactRequestRule -Record $record -Plan $Plan -Request $request -Rules $rules }
        $record.Approval = @{ Rules = $rules; Path = $StatePath; RunId = $RunId; Context = $Context; Operations = $operations; PlanFingerprint = $record.LastPlanFingerprint }
        $record.Lease = $lease
        $lease = $null
        [pscustomobject]@{ Approved = $true; PlanFingerprint = $record.LastPlanFingerprint; Target = $ConfirmTarget }
    } finally { if ($null -ne $lease) { $lease.Dispose() } }
}

function Add-SeedApprovedRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Request, [Parameter(Mandatory)][scriptblock]$RequestCheck)
    $record = Get-SeedSessionRecord $Session
    $approval = $record.Approval
    if ($record.ReadOnlyDepth -gt 0 -or $null -eq $approval) { throw 'Seed.Approval: An uninterrupted approved session is required.' }
    $Request = ConvertTo-SeedMap $Request
    Assert-SeedFields $Request @('OperationId', 'Method', 'Path') 'Seed.Approval.Request'
    $operation = @($approval.Operations | Where-Object { $_.OperationId -ceq $Request.OperationId -and $_.Action -ceq 'Create' })
    if ($operation.Count -ne 1) { throw 'Seed.Approval.Request: Exact approved Create operation is required.' }
    $staged = @{}
    Add-SeedExactRequestRule -Record $record -Plan $approval.Operations -Request $Request -Rules $staged -DynamicResolved
    $state = Get-SeedRunState -Path $approval.Path -RunId $approval.RunId -Context $approval.Context -Operations $approval.Operations
    $result = @($state.results | Where-Object { $_.id -ceq $Request.OperationId -and $_.workload -ceq $operation[0].Workload })
    if ($result.Count -ne 1 -or $result[0].status -ne 'Planned' -or $state.status -in @('Blocked', 'Failed', 'Completed') -or @($state.results | Where-Object status -eq Submitted).Count -gt 0) { throw 'Seed.Approval.Pending: Operation is not safely awaiting a first submission.' }
    $record.ReadOnlyDepth++
    try { $proof = ConvertTo-SeedMap (& $RequestCheck $Session $operation[0] $Request) }
    catch {
        $cause = [regex]::Match($_.Exception.Message, '\bSeed\.[A-Za-z0-9_.]+').Value
        $failure = [InvalidOperationException]::new('Seed.Approval.Check: Adapter could not prove the resolved request matches the approved logical operation.')
        $failure.Data['SeedDiagnostic'] = @{
            Stage='LateBindingRequestCheck'; ErrorCode='Seed.Approval.Check'
            CauseCode=$(if($cause){$cause}else{'Unclassified'}); HttpStatus=(Get-SeedGraphFailure $_.Exception).Status
            ExceptionType=$_.Exception.GetType().FullName
        }
        throw $failure
    }
    finally { $record.ReadOnlyDepth-- }
    Assert-SeedFields $proof @('OperationFingerprint', 'RequestFingerprint', 'MatchesPlan', 'PresenterVerified', 'ParentOperationId', 'ParentObjectId') 'Seed.Approval.Check'
    $digest = @($staged.Keys)[0]
    if ($proof.OperationFingerprint -cne (Get-SeedOperationDigest $operation[0]) -or $proof.RequestFingerprint -cne $digest -or
        $proof.MatchesPlan -isnot [bool] -or -not $proof.MatchesPlan -or $proof.PresenterVerified -isnot [bool] -or -not $proof.PresenterVerified) { throw 'Seed.Approval.Check: Adapter proof does not match the exact approved request.' }
    $parent = @($state.results | Where-Object { $_.id -ceq $proof.ParentOperationId -and $_.status -ceq 'Verified' -and $_.objectId -ceq $proof.ParentObjectId })
    if ($parent.Count -ne 1) { throw 'Seed.Approval.Parent: Dynamic target requires an authoritative verified parent created in this uninterrupted run.' }
    if ($approval.Rules.ContainsKey($digest) -or @($approval.Rules.Values | Where-Object OperationId -eq $Request.OperationId).Count -gt 0) { throw 'Seed.Approval.Request: An exact rule for this operation already exists.' }
    $approval.Rules[$digest] = $staged[$digest]
}

function Start-SeedAuthorizedWrite {
    param($Record, [string]$Method, [string]$Path, $Body, [byte[]]$RawBody, [switch]$UploadContinuation)
    if ($Record.ReadOnlyDepth -gt 0) { throw 'Seed.Write.ReadOnly: Preflight and resource checks are GET-only.' }
    Assert-SeedWriteAllowlist -Record $Record -Method $Method -Path $Path
    $approval = $Record.Approval
    if ($null -eq $approval) { throw 'Seed.Write.Approval: No explicit approval capability is attached to this session.' }
    if (-not $Record.Contains('LastPlanFingerprint') -or $Record.LastPlanFingerprint -cne $approval.PlanFingerprint) { throw 'Seed.Write.Plan: A later failed or changed preflight invalidated this approval.' }
    if ($null -eq $Record.Identity -or $null -eq $Record.ServiceGate -or $Record.ServiceGate.ActorFingerprint -cne $Record.Identity.ActorFingerprint) { throw 'Seed.Write.Identity: Identity or service validation is no longer current.' }
    $digest = Get-SeedRequestFingerprint $Method $Path $Body $RawBody
    if (-not $approval.Rules.ContainsKey($digest) -or $approval.Rules[$digest].Used) { throw 'Seed.Write.Approval: Request is not in the exact approved allowlist or was already submitted.' }
    $rule = $approval.Rules[$digest]
    $operation = @($approval.Operations | Where-Object { $_.OperationId -ceq $rule.OperationId -and $_.Workload -ceq $rule.Workload })[0]
    if ($operation.Contains('StorageScope') -and $operation.StorageScope.Kind -ceq 'Content' -and -not $UploadContinuation) {
        if (-not $operation.StorageScope.Contains('Transfer') -or $operation.StorageScope.Transfer -cne 'Simple' -or
            ($Path -split '\?', 2).Count -ne 2 -or ($Path -split '\?', 2)[1] -cne '@microsoft.graph.conflictBehavior=fail') {
            throw 'Seed.Approval.Upload: Storage content requires its private continuation or exact fail-on-conflict Simple request.'
        }
    }
    Write-SeedRunEvent -Path $approval.Path -RunId $approval.RunId -Context $approval.Context -Operations $approval.Operations -OperationId $rule.OperationId -Workload $rule.Workload -Action Submit -Status Submitted | Out-Null
    $rule.Used = $true
    return @{ Approval = $approval; Rule = $rule }
}

function Write-SeedGraph {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Request, [scriptblock]$RequestCheck, [string]$UploadFromOperationId)
    $record = Get-SeedSessionRecord $Session
    $request = ConvertTo-SeedMap $Request
    # Preserve byte[] across JSON normalization.
    if ($Request.Contains('RawBody')) { $request.RawBody = [byte[]]$Request.RawBody }
    Assert-SeedFields $request @('OperationId', 'Method', 'Path') 'Seed.Approval.Request'
    if ($null -eq $record.Approval) { throw 'Seed.Approval: Explicit run approval required.' }
    $body = if ($request.Contains('Body')) { $request.Body } else { $null }
    $raw = $null
    if ($request.Contains('RawBody')) { $raw = [byte[]]$request.RawBody }
    $digest = Get-SeedRequestFingerprint $request.Method $request.Path $body $raw
    if (-not $record.Approval.Rules.ContainsKey($digest)) {
        if ($null -eq $RequestCheck) { throw 'Seed.Approval.Check: A real plan-bound adapter validator is required.' }
        Add-SeedApprovedRequest -Session $Session -Request $request -RequestCheck $RequestCheck
    }
    if ($UploadFromOperationId) {
        if (-not $record.Contains('Uploads') -or -not $record.Uploads.ContainsKey($UploadFromOperationId) -or
            -not $record.Contains('UploadTransport') -or $record.UploadTransport -isnot [scriptblock]) { throw 'Seed.Approval.Upload: A private uninterrupted upload continuation is required.' }
        $upload = $record.Uploads[$UploadFromOperationId]
        $operation = @($record.Approval.Operations | Where-Object OperationId -CEQ $request.OperationId)
        if ($operation.Count -ne 1 -or $operation[0].StorageScope.Kind -cne 'Content' -or
            $operation[0].StorageScope.ParentOperationId -cne $UploadFromOperationId -or $request.Method -cne 'PUT' -or
            $request.Path -cne $upload.Path -or $null -eq $raw -or $raw.Length -eq 0 -or $raw.Length -gt 33554432 -or
            $operation[0].StorageScope.Sha256 -cne [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($raw)).ToLowerInvariant()) { throw 'Seed.Approval.Upload: Continuation differs from the exact approved target and bytes.' }
        $write = Start-SeedAuthorizedWrite -Record $record -Method PUT -Path $request.Path -RawBody $raw -UploadContinuation
        try {
            # Never send the Graph bearer token to a preauthenticated upload URL.
            $uploaded = & $record.UploadTransport $upload.Url $raw @{ 'Content-Range' = "bytes 0-$($raw.Length-1)/$($raw.Length)"; 'Content-Length' = "$($raw.Length)" }
            if ($uploaded -is [byte[]]) { return ,$uploaded }
            # The final PUT returns its driveItem as PSCustomObject from Invoke-RestMethod without passing through Invoke-SeedGraph.
            if ($uploaded -is [System.Management.Automation.PSCustomObject]) { return ConvertTo-SeedMap $uploaded }
            return $uploaded
        } catch {
            $diagnostic = @{
                Stage = 'UploadPut'; HttpStatus = (Get-SeedGraphFailure $_.Exception).Status
                ExceptionType = $_.Exception.GetType().FullName
            }
            if ($_.Exception.Data.Contains('SeedDiagnostic')) { $diagnostic = $_.Exception.Data['SeedDiagnostic'] }
            Complete-SeedUnknownWrite $write
            $failure = [InvalidOperationException]::new('Seed.Graph.Upload: Upload outcome is unknown; preserve the run and never retry.')
            $failure.Data['SeedDiagnostic'] = $diagnostic
            throw $failure
        } finally { $record.Uploads.Remove($UploadFromOperationId) }
    }
    $args = @{ Session = $Session; Method = $request.Method; Path = $request.Path }
    if ($null -ne $body) { $args.Body = $body }
    if ($null -ne $raw) { $args.RawBody = $raw }
    $response = Invoke-SeedGraph @args
    if ($request.Path.EndsWith('/createUploadSession')) {
        $response = ConvertTo-SeedMap $response
        Assert-SeedFields $response @('uploadUrl', 'expirationDateTime', 'nextExpectedRanges') 'Seed.Storage.Session'
        $uri = $null
        if (-not [uri]::TryCreate($response.uploadUrl, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -cne 'https' -or
            -not $uri.IsDefaultPort -or $uri.UserInfo -or $uri.Fragment -or $uri.Host -notmatch '^[a-z0-9-]+(?:-my)?\.sharepoint\.com$' -or
            [DateTimeOffset]::Parse($response.expirationDateTime) -le [DateTimeOffset]::UtcNow -or
            @($response.nextExpectedRanges).Count -ne 1 -or $response.nextExpectedRanges[0] -cne '0-') { throw 'Seed.Storage.Session: Invalid first upload-session response.' }
        if (-not $record.Contains('Uploads')) { $record.Uploads = @{} }
        $record.Uploads[$request.OperationId] = @{ Url = $response.uploadUrl; Path = $request.Path.Substring(0, $request.Path.Length - 'createUploadSession'.Length) + 'content' }
        return @{ accepted = $true }
    }
    return $response
}

function Read-SeedUploadSession {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$OperationId)
    $record = Get-SeedSessionRecord $Session
    if (-not $record.Contains('Uploads') -or -not $record.Uploads.ContainsKey($OperationId) -or
        $record.UploadTransport -isnot [scriptblock]) { throw 'Seed.Storage.Session: Private upload allocation is unavailable.' }
    $record.ReadOnlyDepth++
    try {
        $status = ConvertTo-SeedMap (& $record.UploadTransport $record.Uploads[$OperationId].Url $null @{})
        Assert-SeedFields $status @('expirationDateTime', 'nextExpectedRanges') 'Seed.Storage.Session'
        if ([DateTimeOffset]::Parse($status.expirationDateTime) -le [DateTimeOffset]::UtcNow -or
            @($status.nextExpectedRanges).Count -ne 1 -or $status.nextExpectedRanges[0] -cne '0-') { throw 'invalid-status' }
        return @{ verified = $true }
    } catch { throw 'Seed.Storage.Session: Private GET did not prove a fresh untouched upload allocation.' }
    finally { $record.ReadOnlyDepth-- }
}

function Complete-SeedUnknownWrite {
    param($Write)
    $approval = $Write.Approval; $rule = $Write.Rule
    try {
        Write-SeedRunEvent -Path $approval.Path -RunId $approval.RunId -Context $approval.Context -Operations $approval.Operations -OperationId $rule.OperationId -Workload $rule.Workload -Action Fail -Status Unknown -ErrorCode GraphWriteOutcomeUnknown | Out-Null
    } catch { throw 'Seed.State.Pending: Write outcome is unknown; the durable Submit marker blocks replay even if the Unknown update failed.' }
}
