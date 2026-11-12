function Assert-SeedStorageActors {
    param($Session, $Storage)
    $record = Get-SeedSessionRecord $Session
    if ($null -eq $record.Identity -or (Get-SeedFingerprint $record.Identity) -cne $Storage.IdentityFingerprint -or
        $null -eq $record.ServiceGate -or $record.ServiceGate.ActorFingerprint -cne $record.Identity.ActorFingerprint) { throw 'Seed.Storage.Identity: Current T2 identity and service provenance required.' }
    foreach ($role in $record.Identity.Roles.Keys) {
        $actor = $record.Identity.Roles[$role]
        $profile = ConvertTo-SeedMap (Invoke-SeedGraph -Session $Session -Method GET -Path "/users/$($actor.ObjectId)?`$select=id,userPrincipalName,displayName,jobTitle,department,companyName,officeLocation,usageLocation,accountEnabled,userType")
        if ($profile.id -ine $actor.ObjectId -or $profile.userPrincipalName -ine $actor.Upn -or $profile.accountEnabled -cne $true -or $profile.userType -cne 'Member') { throw 'Seed.Storage.Identity: Actual enabled Member changed.' }
        if ($role -ceq 'Presenter') { continue }
        $values = @{ managerObjectId = $null }
        # Existing accounts may hold null profile fields: the field must exist and be text or null, never defaulted. Managed stays strict.
        $nullable = $actor.Contains('AccountSource') -and $actor['AccountSource'] -ceq 'Existing'
        foreach ($field in @('displayName', 'jobTitle', 'department', 'companyName', 'officeLocation', 'usageLocation')) {
            if ($nullable) { if (-not $profile.Contains($field) -or ($null -ne $profile[$field] -and $profile[$field] -isnot [string])) { throw 'Seed.Storage.Identity: A required field is missing or has an unexpected type.' } }
            else { Assert-SeedFields $profile @($field) 'Seed.Storage.Identity' }
            $values[$field] = $profile[$field]
        }
        try {
            $manager = Invoke-SeedGraph -Session $Session -Method GET -Path "/users/$($actor.ObjectId)/manager?`$select=id"
            $values.managerObjectId = $manager.id
        } catch { if ($_.Exception.Message -notlike 'Seed.Graph.404:*') { throw } }
        if ((Get-SeedFingerprint $values) -cne $actor.ProfileFingerprint) { throw 'Seed.Storage.Identity: Applied profile or manager changed.' }
    }
}

function Get-SeedPresenterDrive {
    param($Session, [string]$PresenterId, [string]$ExpectedDriveId)
    $drive = ConvertTo-SeedMap (Invoke-SeedGraph -Session $Session -Method GET -Path "/users/$PresenterId/drive?`$select=id,driveType,owner")
    Assert-SeedFields $drive @('id', 'owner') 'Seed.Storage.Owner'
    if ($drive.owner.user.id -ine $PresenterId -or ($ExpectedDriveId -and $drive.id -cne $ExpectedDriveId)) { throw 'Seed.Storage.Owner: Actual Presenter drive owner and ID must match.' }
    return $drive
}

function Get-SeedStorageDirectory {
    param($Session, $Storage, $Scope)
    if (-not $Scope.ParentOperationId) { return @{ DriveId = $Scope.DriveId; ParentId = $Scope.ParentId } }
    $parentOp = $Storage.ById[$Scope.ParentOperationId]
    $parentId = Get-SeedStorageResultId $Storage $parentOp.OperationId
    if ($parentOp.StorageScope.Kind -ceq 'Library') {
        $site = Get-SeedStorageSite $Session $Storage $parentOp.StorageScope.GroupOperationId
        $drive = Invoke-SeedGraph -Session $Session -Method GET -Path "/sites/$($site.id)/lists/$parentId/drive"
        Assert-SeedFields $drive @('id') 'Seed.Storage.Parent'
        $root = Invoke-SeedGraph -Session $Session -Method GET -Path "/drives/$($drive.id)/root"
        Assert-SeedFields $root @('id') 'Seed.Storage.Parent'
        return @{ DriveId = $drive.id; ParentId = $root.id }
    }
    $parentScope = $parentOp.StorageScope
    if ($parentScope.Kind -ceq 'Session') { return Get-SeedStorageDirectory $Session $Storage $parentScope }
    $directory = Get-SeedStorageDirectory $Session $Storage $parentScope
    return @{ DriveId = $directory.DriveId; ParentId = $parentId }
}

function Get-SeedStorageFileSnapshot {
    param($Session, $Storage, $Operation, [string]$ObjectId)
    $scope = $Operation.StorageScope
    $directory = Get-SeedStorageDirectory $Session $Storage $scope
    $item = ConvertTo-SeedMap (Invoke-SeedGraph -Session $Session -Method GET -Path "/drives/$($directory.DriveId)/items/$ObjectId")
    Assert-SeedFields $item @('id', 'name', 'parentReference') 'Seed.Storage.Item'
    if ($item.id -cne $ObjectId -or $item.name -cne $scope.Name -or $item.parentReference.id -cne $directory.ParentId -or $item.parentReference.driveId -cne $directory.DriveId) { throw 'Seed.Storage.Item: Exact item identity or destination changed.' }
    $linkOptions = @{}
    if (([uri]$item.webUrl).Query) {
        if (-not $item.Contains('sharepointIds') -or -not $item.sharepointIds.Contains('listItemUniqueId')) {
            $details = ConvertTo-SeedMap (Invoke-SeedGraph -Session $Session -Method GET -Path "/drives/$($directory.DriveId)/items/$ObjectId`?`$select=id,sharepointIds")
            if ($details.id -cne $ObjectId -or -not $details.Contains('sharepointIds') -or -not $details.sharepointIds.Contains('listItemUniqueId')) {
                throw 'Seed.Storage.Link: Actual SharePoint file identity is required.'
            }
            $item.sharepointIds = $details.sharepointIds
        }
        $parent = ConvertTo-SeedMap (Invoke-SeedGraph -Session $Session -Method GET -Path "/drives/$($directory.DriveId)/items/$($directory.ParentId)?`$select=id,webUrl")
        if ($parent.id -cne $directory.ParentId) { throw 'Seed.Storage.Link: Link parent identity changed.' }
        $parentUrl = Assert-StorageWebUrl $parent.webUrl
        $linkOptions = @{
            ExpectedFileName = $scope.Name; ExpectedDocumentId = $item.sharepointIds.listItemUniqueId
            ExpectedHost = ([uri]$parentUrl).Host
        }
    }
    $url = Assert-StorageWebUrl $item.webUrl @linkOptions
    $acl = Get-SeedStorageDriveAccess $Session $Storage $directory.DriveId $ObjectId $scope.GroupOperationId $Operation
    $snapshot = @{ id = $item.id; name = $item.name; parentId = $directory.ParentId; driveId = $directory.DriveId; webUrl = $url; access = $acl }
    if ($scope.Kind -ceq 'Folder') {
        Assert-SeedFields $item @('folder') 'Seed.Storage.Folder'
        if ($item.Contains('file')) { throw 'Seed.Storage.Folder: Expected a directory, not a file.' }
    } else {
        Assert-SeedFields $item @('file', 'eTag', 'cTag', 'size') 'Seed.Storage.Content'
        if ([long]$item.size -ne $scope.Size) { throw 'Seed.Storage.Content: Size changed.' }
        $actualHash = $null
        if ($item.file.Contains('hashes') -and $item.file.hashes.Contains('sha256Hash')) { $actualHash = ([string]$item.file.hashes.sha256Hash).ToLowerInvariant() }
        if (-not $actualHash) {
            $bytes = Invoke-SeedGraph -Session $Session -Method GET -Path "/drives/$($directory.DriveId)/items/$ObjectId/content"
            if ($bytes -isnot [byte[]] -or $bytes.Length -ne $scope.Size) { throw 'Seed.Storage.Content: Authoritative bytes or SHA256 unavailable.' }
            $actualHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        }
        if ($actualHash -cne $scope.Sha256) { throw 'Seed.Storage.Content: Authoritative source hash changed.' }
        $snapshot.sha256 = $actualHash; $snapshot.eTag = $item.eTag; $snapshot.cTag = $item.cTag; $snapshot.size = $item.size
    }
    return $snapshot
}

function Get-SeedStorageDriveAccess {
    param($Session, $Storage, [string]$DriveId, [string]$ItemId, [string]$GroupOperationId, $Operation)
    if (-not $GroupOperationId) {
        $null = Get-SeedPresenterDrive $Session $Storage.PresenterId $DriveId
    } else {
        $group = Get-SeedStorageGroupSnapshot $Session $Storage $Storage.ById[$GroupOperationId] (Get-SeedStorageResultId $Storage $GroupOperationId)
        $objectId = Get-SeedStorageResultId $Storage $Operation.OperationId
        return @{
            presenterId = $Storage.PresenterId; kind = 'GraphStructural'; actualUiStatus = 'Required'; remoteAclStatus = 'NotProven'
            groupId = $group.id; siteId = $group.siteId
            inheritance = Get-SeedStorageCreationProof $Session $Storage $Operation $objectId
            sharingPermissions = @(Get-SeedStorageSharingSnapshot $Session $DriveId $ItemId -SharingEvidenceVersion $Operation.StorageScope['SharingEvidenceVersion'])
        }
    }
    $permissions = @(Get-SeedGraphCollection -Session $Session -Path "/drives/$DriveId/items/$ItemId/permissions")
    $found = $false
    foreach ($permission in $permissions) {
        if (@($permission.roles | Where-Object { $_ -in @('read', 'write', 'owner') }).Count -eq 0) { continue }
        $identities = @()
        foreach ($key in @('grantedToV2', 'grantedTo')) { if ($permission.Contains($key)) { $identities += $permission[$key] } }
        foreach ($key in @('grantedToIdentitiesV2', 'grantedToIdentities')) { if ($permission.Contains($key)) { $identities += @($permission[$key]) } }
        foreach ($identity in $identities) {
            if ($identity.Contains('user') -and $identity.user.id -ieq $Storage.PresenterId) { $found = $true }
            if ($GroupOperationId -and $identity.Contains('group') -and $identity.group.id -ieq (Get-SeedStorageResultId $Storage $GroupOperationId)) { $found = $true }
        }
    }
    if (-not $found) { throw 'Seed.Storage.ACL: Presenter content permission is not proven; directory admin roles are not evidence.' }
    return @{ presenterId = $Storage.PresenterId; read = $true }
}
