function Get-SeedStorageSite {
    param($Session, $Storage, [string]$GroupOperationId)
    $groupId = Get-SeedStorageResultId $Storage $GroupOperationId
    $site = ConvertTo-SeedMap (Invoke-SeedGraph -Session $Session -Method GET -Path "/groups/$groupId/sites/root")
    Assert-SeedFields $site @('id') 'Seed.Storage.Site'
    if (-not $site.Contains('webUrl') -or -not $site.webUrl) {
        $site = ConvertTo-SeedMap (Invoke-SeedGraph -Session $Session -Method GET -Path "/sites/$($site.id)")
    }
    $null = Assert-StorageWebUrl $site.webUrl
    return $site
}

function Get-SeedStorageCreationProof {
    param($Session, $Storage, $Operation, [string]$ObjectId)
    $scope = $Operation.StorageScope
    if (-not $scope.Contains('PermissionModel') -or $scope.PermissionModel -cne 'ToolCreatedGroupInheritanceV1') {
        throw 'Seed.Storage.Inheritance: Recorded create-with-default-inheritance plan is required; unknown containers are not adopted.'
    }
    $request = Get-SeedStorageRequest $Session $Storage $Operation
    $body = if ($request.Contains('Body')) { $request.Body } else { $null }
    $raw = if ($request.Contains('RawBody')) { [byte[]]$request.RawBody } else { $null }
    $digest = Get-SeedRequestFingerprint $request.Method $request.Path $body $raw
    if ($null -ne $Storage.RunState -and $Storage.RunState.status -ceq 'Completed') {
        if (-not $script:SeedValidatedStates.ContainsKey((Get-SeedFingerprint $Storage.RunState))) { throw 'Seed.Storage.Inheritance: Validated completed creation history required.' }
        $result = @($Storage.RunState.results | Where-Object { $_.id -ceq $Operation.OperationId -and $_.workload -ceq 'sharepoint' -and $_.status -ceq 'Verified' -and $_.objectId -ceq $ObjectId })
        if ($result.Count -ne 1) { throw 'Seed.Storage.Inheritance: Exact recorded created resource required.' }
    } elseif (-not $Storage.CreationProofs.ContainsKey($Operation.OperationId) -or
        $Storage.CreationProofs[$Operation.OperationId].objectId -cne $ObjectId -or
        $Storage.CreationProofs[$Operation.OperationId].requestSha256 -cne $digest) {
        throw 'Seed.Storage.Inheritance: No successful exact tool creation is recorded; no adoption or ACL repair.'
    }
    # This provenance is included in the authoritative receipt digest, not inferred from an empty ACL collection.
    return @{
        model = $scope.PermissionModel; operationId = $Operation.OperationId
        operationSha256 = Get-SeedOperationDigest $Operation; requestSha256 = $digest; objectId = $ObjectId
        groupId = $(if ($scope.Kind -ceq 'Group') { $ObjectId } else { Get-SeedStorageResultId $Storage $scope.GroupOperationId })
    }
}

function Get-SeedStorageSiteAccess {
    param($Session, $Storage, $Site, $Operation, [string]$ObjectId, [string]$ContainerId)
    return @{
        presenterId = $Storage.PresenterId; kind = 'GraphStructural'; actualUiStatus = 'Required'; remoteAclStatus = 'NotProven'
        siteId = $Site.id; containerId = $ContainerId
        inheritance = Get-SeedStorageCreationProof $Session $Storage $Operation $ObjectId
    }
}

function ConvertTo-SeedStoragePermissionIdentity {
    param($Identity)
    if ($Identity -isnot [Collections.IDictionary] -or $Identity.Count -eq 0) { throw 'Seed.Storage.Inheritance: Stable permission principal identity is required.' }
    $result = @{}
    foreach ($type in $Identity.Keys) {
        if ($type -cnotin @('user','group','siteUser','siteGroup','sharePointGroup')) {
            throw 'Seed.Storage.Inheritance: Unsupported permission identity type.'
        }
        $entity = $Identity[$type]
        $field = $(if ($type -ceq 'sharePointGroup') { 'principalId' } else { 'id' })
        if ($entity -isnot [Collections.IDictionary] -or -not $entity.Contains($field) -or
            ($entity[$field] -isnot [string] -and $entity[$field] -isnot [int] -and $entity[$field] -isnot [long])) {
            throw 'Seed.Storage.Inheritance: Stable scalar principal ID is required.'
        }
        $id = [string]$entity[$field]
        if ($type -cin @('siteUser','siteGroup','sharePointGroup')) {
            $number = 0L
            if (-not [long]::TryParse($id, [ref]$number) -or $number -le 0) { throw 'Seed.Storage.Inheritance: Valid site-scoped principal ID required.' }
            $id = $number.ToString([Globalization.CultureInfo]::InvariantCulture)
        } else {
            $guid = [guid]::Empty
            if (-not [guid]::TryParse($id, [ref]$guid) -or $guid -eq [guid]::Empty) { throw 'Seed.Storage.Inheritance: Valid directory principal ID required.' }
            $id = $guid.ToString()
        }
        $key = $(if ($type -ceq 'sharePointGroup') { 'siteGroup' } else { $type })
        if ($result.ContainsKey($key) -and $result[$key] -cne $id) { throw 'Seed.Storage.Inheritance: Conflicting site principal aliases.' }
        $result[$key] = $id
    }
    return $result
}

function Get-SeedStorageSharingSnapshot {
    param($Session, [string]$DriveId, [string]$ItemId, [int]$SharingEvidenceVersion = 0)
    if ($SharingEvidenceVersion -ne 2) { throw 'Seed.Storage.Inheritance: Explicit supported sharing evidence version required.' }
    $permissions = @(Get-SeedGraphCollection -Session $Session -Path "/drives/$DriveId/items/$ItemId/permissions")
    $snapshots = @()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($permission in $permissions) {
        if (-not $permission.Contains('id') -or $permission.id -isnot [string] -or [string]::IsNullOrWhiteSpace($permission.id)) {
            throw 'Seed.Storage.Inheritance: Provider permission identity is required.'
        }
        if ($permission.Contains('expirationDateTime') -and $null -ne $permission.expirationDateTime) {
            $expiry = $permission.expirationDateTime
            $unset = ($expiry -is [string] -and $expiry -cmatch '^0001-01-01T00:00:00(?:\.0{1,7})?Z$') -or
                ($expiry -is [DateTime] -and $expiry.Ticks -eq 0) -or
                ($expiry -is [DateTimeOffset] -and $expiry.Ticks -eq 0 -and $expiry.Offset -eq [TimeSpan]::Zero)
            if (-not $unset) { throw 'Seed.Storage.Inheritance: Expiring or malformed permissions are unsupported.' }
        }
        $hasLink = $permission.Contains('link') -and $null -ne $permission.link
        $existingAccess = $hasLink -and $permission.link -is [Collections.IDictionary] -and
            $permission.link.Contains('scope') -and $permission.link.scope -ceq 'existingAccess' -and
            $permission.Contains('roles') -and $permission.roles -is [Collections.IList] -and
            $permission.roles.Count -eq 1 -and $permission.roles[0] -ceq 'read'
        if (($hasLink -and -not $existingAccess) -or
            ($permission.Contains('invitation') -and $null -ne $permission.invitation)) {
            throw 'Seed.Storage.Inheritance: Shared or uniquely granted containers are unsupported; no adoption or repair.'
        }
        if (-not $permission.Contains('roles') -or $permission.roles -isnot [Collections.IList] -or $permission.roles.Count -eq 0 -or
            @($permission.roles | Where-Object { $_ -isnot [string] -or $_ -cnotin @('read','write','owner') }).Count -gt 0 -or
            @($permission.roles | Sort-Object -Unique).Count -ne $permission.roles.Count) {
            throw 'Seed.Storage.Inheritance: Exact supported permission roles required.'
        }
        # Provider aliases and principal labels can change while the site-scoped identities and grants remain the same.
        $value = @{ roles = @($permission.roles | Sort-Object) }
        if ($permission.Contains('grantedToV2') -and $null -ne $permission.grantedToV2) {
            $value.grantedToV2 = ConvertTo-SeedStoragePermissionIdentity $permission.grantedToV2
        }
        if ($permission.Contains('grantedToIdentitiesV2') -and $null -ne $permission.grantedToIdentitiesV2) {
            if (-not $existingAccess) { throw 'Seed.Storage.Inheritance: Plural recipients require an explicitly supported non-granting link.' }
            if ($permission.grantedToIdentitiesV2 -isnot [Collections.IList]) { throw 'Seed.Storage.Inheritance: Explicit permission identity collection required.' }
            if ($permission.grantedToIdentitiesV2.Count -gt 0) {
                $identities = @($permission.grantedToIdentitiesV2 | ForEach-Object {
                    $identity = ConvertTo-SeedStoragePermissionIdentity $_
                    @{ hash=Get-SeedFingerprint $identity; value=$identity }
                })
                if (@($identities.hash | Sort-Object -Unique).Count -ne $identities.Count) { throw 'Seed.Storage.Inheritance: Duplicate permission principals.' }
                $value.grantedToIdentitiesV2 = @($identities | Sort-Object hash | ForEach-Object value)
            }
        }
        if (-not $existingAccess -and -not $value.Contains('grantedToV2') -and -not $value.Contains('grantedToIdentitiesV2')) {
            throw 'Seed.Storage.Inheritance: Authoritative V2 principal identities are required.'
        }
        if ($permission.Contains('inheritedFrom')) { $value.inheritedFrom = $permission.inheritedFrom }
        if ($existingAccess) { $value.link = @{ scope = 'existingAccess' } }
        $hash = Get-SeedFingerprint $value
        if (-not $seen.Add($hash)) { throw 'Seed.Storage.Inheritance: Duplicate canonical permission grants.' }
        $snapshots += @{ hash = $hash; value = $value }
    }
    return @($snapshots | Sort-Object hash | ForEach-Object { $_.value })
}

function Get-SeedStorageGroupSnapshot {
    param($Session, $Storage, $Operation, [string]$ObjectId)
    $scope = $Operation.StorageScope
    $group = ConvertTo-SeedMap (Invoke-SeedGraph -Session $Session -Method GET -Path "/groups/$ObjectId")
    foreach ($key in @('displayName', 'description', 'mailNickname', 'mailEnabled', 'securityEnabled', 'visibility', 'groupTypes')) {
        if (-not $group.Contains($key) -or (Get-SeedFingerprint $group[$key]) -cne (Get-SeedFingerprint $scope.Body[$key])) { throw 'Seed.Storage.Group: Exact private tool-owned group profile changed.' }
    }
    if ($group.id -cne $ObjectId) { throw 'Seed.Storage.Group: Group ID changed.' }
    $owners = @(Get-SeedGraphCollection -Session $Session -Path "/groups/$ObjectId/owners?`$select=id")
    $members = @(Get-SeedGraphCollection -Session $Session -Path "/groups/$ObjectId/members?`$select=id")
    foreach ($pair in @(@($owners, $scope.OwnerIds), @($members, $scope.MemberIds))) {
        $actual = @($pair[0] | ForEach-Object { $_.id.ToLowerInvariant() } | Sort-Object)
        $expected = @($pair[1] | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object)
        if (($actual -join ',') -cne ($expected -join ',') -or $Storage.PresenterId -cnotin $actual) { throw 'Seed.Storage.ACL: Exact new Group owners and members including Presenter required.' }
    }
    $site = Get-SeedStorageSite $Session $Storage $Operation.OperationId
    if ($site.displayName -cne $scope.Body.displayName) { throw 'Seed.Storage.Site: Site profile changed.' }
    $access = Get-SeedStorageSiteAccess $Session $Storage $site $Operation $ObjectId $site.id
    $drive = ConvertTo-SeedMap (Invoke-SeedGraph -Session $Session -Method GET -Path "/sites/$($site.id)/drive")
    $defaultList = ConvertTo-SeedMap (Invoke-SeedGraph -Session $Session -Method GET -Path "/sites/$($site.id)/drive/list")
    Assert-SeedFields $drive @('id') 'Seed.Storage.Library'
    Assert-SeedFields $defaultList @('id', 'displayName', 'list') 'Seed.Storage.Library'
    if ($defaultList.list.template -cne 'documentLibrary') { throw 'Seed.Storage.Library: The new site default drive must be an actual document library.' }
    if (-not $defaultList.Contains('webUrl') -or -not $defaultList.webUrl) { $defaultList = ConvertTo-SeedMap (Invoke-SeedGraph -Session $Session -Method GET -Path "/sites/$($site.id)/lists/$($defaultList.id)") }
    $root = ConvertTo-SeedMap (Invoke-SeedGraph -Session $Session -Method GET -Path "/drives/$($drive.id)/root")
    Assert-SeedFields $root @('id') 'Seed.Storage.Library'
    $defaultLibrary = @{
        id = $defaultList.id; displayName = $defaultList.displayName; driveId = $drive.id; rootId = $root.id
        webUrl = Assert-StorageWebUrl $defaultList.webUrl; access = Get-SeedStorageSiteAccess $Session $Storage $site $Operation $ObjectId $defaultList.id
        sharingPermissions = @(Get-SeedStorageSharingSnapshot $Session $drive.id $root.id -SharingEvidenceVersion $scope['SharingEvidenceVersion'])
    }
    return @{ id = $ObjectId; profile = $scope.Body; owners = @($scope.OwnerIds); members = @($scope.MemberIds); siteId = $site.id; webUrl = $site.webUrl; access = $access; defaultLibrary = $defaultLibrary }
}

function Get-SeedStorageListSnapshot {
    param($Session, $Storage, $Operation, [string]$ObjectId)
    $scope = $Operation.StorageScope
    $null = Get-SeedStorageGroupSnapshot $Session $Storage $Storage.ById[$scope.GroupOperationId] (Get-SeedStorageResultId $Storage $scope.GroupOperationId)
    $site = Get-SeedStorageSite $Session $Storage $scope.GroupOperationId
    $list = ConvertTo-SeedMap (Invoke-SeedGraph -Session $Session -Method GET -Path "/sites/$($site.id)/lists/$ObjectId`?`$expand=columns")
    Assert-SeedFields $list @('id', 'displayName', 'description', 'list') 'Seed.Storage.List'
    if ($list.id -cne $ObjectId -or $list.displayName -cne $scope.Body.displayName -or $list.description -cne $scope.Body.description -or $list.list.template -cne $scope.Body.list.template) { throw 'Seed.Storage.List: Exact List ID and profile differ.' }
    if (-not $list.Contains('webUrl') -or -not $list.webUrl) { $list = ConvertTo-SeedMap (Invoke-SeedGraph -Session $Session -Method GET -Path "/sites/$($site.id)/lists/$ObjectId") }
    $url = Assert-StorageWebUrl $list.webUrl
    $snapshot = @{ id = $ObjectId; siteId = $site.id; displayName = $scope.Body.displayName; description = $scope.Body.description; template = $scope.Body.list.template; webUrl = $url; access = Get-SeedStorageSiteAccess $Session $Storage $site $Operation $ObjectId $ObjectId }
    if ($scope.Kind -ceq 'Library') {
        $drive = Invoke-SeedGraph -Session $Session -Method GET -Path "/sites/$($site.id)/lists/$ObjectId/drive"
        Assert-SeedFields $drive @('id') 'Seed.Storage.Library'
        $root = Invoke-SeedGraph -Session $Session -Method GET -Path "/drives/$($drive.id)/root"
        $snapshot.driveId = $drive.id; $snapshot.rootId = $root.id
        $snapshot.contentAccess = Get-SeedStorageDriveAccess $Session $Storage $drive.id $root.id $scope.GroupOperationId $Operation
    } else {
        $columns = @(Get-SeedGraphCollection -Session $Session -Path "/sites/$($site.id)/lists/$ObjectId/columns")
        $verified = @()
        foreach ($expected in $scope.Body.columns) {
            $matches = @($columns | Where-Object { $_.name -ceq $expected.name })
            if ($matches.Count -ne 1 -or $matches[0].displayName -cne $expected.displayName) { throw 'Seed.Storage.Schema: Exact typed column required.' }
            $actual = $matches[0]; Assert-SeedFields $actual @('id') 'Seed.Storage.Schema'
            foreach ($facet in @('text', 'number', 'boolean', 'dateTime', 'choice', 'lookup', 'personOrGroup', 'calculated', 'currency')) {
                if ($expected.Contains($facet)) {
                    if (-not $actual.Contains($facet) -or $null -eq $actual[$facet]) { throw 'Seed.Storage.Schema: Column type changed.' }
                    foreach ($key in $expected[$facet].Keys) {
                        if (-not $actual[$facet].Contains($key) -or (Get-SeedFingerprint $actual[$facet][$key]) -cne (Get-SeedFingerprint $expected[$facet][$key])) { throw 'Seed.Storage.Schema: Column definition changed.' }
                    }
                } elseif ($actual.Contains($facet) -and $null -ne $actual[$facet]) { throw 'Seed.Storage.Schema: Unexpected column type.' }
            }
            $verified += @{ id = $actual.id; definition = $expected }
        }
        $builtins = @('Title', 'ID', 'ContentType', 'Modified', 'Created', 'Author', 'Editor', '_UIVersionString', 'Attachments', 'Edit', 'LinkTitle', 'LinkTitleNoMenu', 'DocIcon', 'ItemChildCount', 'FolderChildCount', 'AppAuthor', 'AppEditor', 'ComplianceAssetId', '_ColorTag', '_IsRecord', '_ComplianceFlags', '_ComplianceTag', '_ComplianceTagWrittenTime', '_ComplianceTagUserId', 'GUID')
        foreach ($column in $columns) {
            if ($column.name -cnotin @($scope.Body.columns.name) -and $column.name -cnotin $builtins) { throw 'Seed.Storage.Schema: Undeclared column, including hidden fields.' }
        }
        $snapshot.columns = $verified
    }
    return $snapshot
}

function Get-SeedStorageListItemSnapshot {
    param($Session, $Storage, $Operation, [string]$ObjectId)
    $scope = $Operation.StorageScope
    $null = Get-SeedStorageGroupSnapshot $Session $Storage $Storage.ById[$scope.GroupOperationId] (Get-SeedStorageResultId $Storage $scope.GroupOperationId)
    $parent = $Storage.ById[$scope.ParentOperationId]
    $listId = Get-SeedStorageResultId $Storage $parent.OperationId
    $site = Get-SeedStorageSite $Session $Storage $scope.GroupOperationId
    $item = ConvertTo-SeedMap (Invoke-SeedGraph -Session $Session -Method GET -Path "/sites/$($site.id)/lists/$listId/items/$ObjectId`?`$expand=fields")
    Assert-SeedFields $item @('id', 'eTag', 'fields') 'Seed.Storage.Fields'
    if ($item.id -cne $ObjectId) { throw 'Seed.Storage.Fields: Item ID changed.' }
    $values = @{}
    foreach ($column in $parent.StorageScope.CanonicalList.columns) {
        $name = Get-StorageFieldName $column.id
        if (-not $item.fields.Contains($name)) { throw 'Seed.Storage.Fields: Field missing from read-back.' }
        $values[$column.id] = $item.fields[$name]
    }
    $normalized = ConvertTo-StorageFields $parent.StorageScope.CanonicalList $values
    foreach ($field in $item.fields.Keys) {
        if ($field -clike 'seed_*' -and -not $normalized.ContainsKey($field)) { throw 'Seed.Storage.Fields: Undeclared tool data field.' }
        if ($field -ceq 'Title' -and $null -ne $item.fields[$field] -and $item.fields[$field] -cne '') { throw 'Seed.Storage.Fields: Undeclared built-in Title content.' }
    }
    if ((Get-SeedFingerprint $normalized) -cne (Get-SeedFingerprint $scope.Body.fields)) { throw 'Seed.Storage.Fields: Exact typed field contents changed.' }
    return @{ id = $ObjectId; listId = $listId; fields = $normalized; eTag = $item.eTag; access = Get-SeedStorageSiteAccess $Session $Storage $site $Operation $ObjectId $listId }
}

function Invoke-SeedSharePoint {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Adapter, [Parameter(Mandatory)][object[]]$Plan)
    Invoke-UploadFiles -Session $Session -Adapter $Adapter -Plan $Plan
}
