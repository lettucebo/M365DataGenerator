Import-Module (Join-Path $PSScriptRoot 'SharePointSeedHelpers.psm1') -Force -DisableNameChecking

function Get-SeedStorageRecord {
    param($Session, $Adapter)
    $record = Get-SeedSessionRecord $Session
    if ($null -eq $Adapter -or -not $Adapter.PSObject.Properties['AdapterId'] -or -not $record.Contains('StorageAdapters') -or
        -not $record.StorageAdapters.ContainsKey($Adapter.AdapterId)) { throw 'Seed.Storage.Adapter: An authentic session-bound adapter is required.' }
    $storage = $record.StorageAdapters[$Adapter.AdapterId]
    if (-not [object]::ReferenceEquals($storage.Handle, $Adapter) -or
        (Get-SeedFingerprint $Adapter.Operations) -cne $storage.OperationsFingerprint) { throw 'Seed.Storage.Adapter: The approved storage scope changed.' }
    return $storage
}

function Get-SeedStorageResultId {
    param($Storage, [string]$OperationId)
    if (-not $Storage.Ids.ContainsKey($OperationId)) { throw 'Seed.Storage.Parent: Exact verified parent ID is unavailable.' }
    return $Storage.Ids[$OperationId]
}

function Assert-SeedStorageSources {
    param($Storage)
    foreach ($source in $Storage.Assets.Values) {
        $null = Assert-SeedStatePath $source.Path
        if (-not (Test-Path -LiteralPath $source.Path -PathType Leaf) -or
            (Get-Item -LiteralPath $source.Path).Length -ne $source.Size -or
            (Get-FileHash -LiteralPath $source.Path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $source.Sha256) { throw 'Seed.Storage.Source: All local source bytes must still match the approved prepared manifest.' }
    }
}

function Add-SeedStorageOperation {
    param($Storage, [string]$Key, [string]$Workload, $Scope)
    $id = 's' + (Get-SeedFingerprint $Key).Substring(0, 30)
    $normalizedScope = @{ ParentOperationId = ''; GroupOperationId = '' }
    foreach ($scopeField in $Scope.Keys) { $normalizedScope[$scopeField] = $Scope[$scopeField] }
    if ($Workload -ceq 'sharepoint') {
        $normalizedScope.PermissionModel = 'ToolCreatedGroupInheritanceV1'
        $normalizedScope.SharingEvidenceVersion = 2
    }
    $scope = $normalizedScope
    $operation = @{
        OperationId = $id; Workload = $Workload; TargetKey = $Key; TargetId = $null
        StorageScope = $scope
        DataFingerprint = Get-SeedFingerprint @{ scope = $scope; context = $Storage.Context; actors = $Storage.IdentityFingerprint }
        ActorFingerprint = $Storage.IdentityFingerprint
        PresenterEvidence = @{ verified = $true; objectId = $Storage.PresenterId }
        SideEffects = @("Create only: $($scope.Kind) $Key; no replace, rename, adoption or repair.")
    }
    if ($Storage.ById.ContainsKey($id)) { throw 'Seed.Storage.Duplicate: Duplicate logical operation.' }
    $Storage.Operations.Add($operation); $Storage.ById[$id] = $operation
    return $id
}

function Get-SeedStorageAdapter {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Scenario, [Parameter(Mandatory)][string]$PreparedPath,
        [Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$RunId, [Parameter(Mandatory)][string]$StatePath,
        [switch]$UseUploadSessions)
    $record = Get-SeedSessionRecord $Session
    if ($record.Kind -cne 'App' -or $null -eq $record.Identity -or $null -eq $record.ServiceGate) { throw 'Seed.Storage.Identity: T2 identity and selected service gate must run first.' }
    $Scenario = ConvertTo-SeedMap $Scenario; $Context = ConvertTo-SeedMap $Context
    try { Assert-SeedSchema $Scenario scenario; $StatePath = Assert-SeedStatePath $StatePath }
    catch { throw 'Seed.Storage.Input: Canonical scenario and safe journal path required.' }
    $PreparedPath = [IO.Path]::GetFullPath($PreparedPath)
    $code = @'
import hashlib,json,os,sys
from pathlib import Path
sys.path.insert(0,str(Path.cwd()))
from generator.validate_pack import canonical_bytes,validate_files
d=json.load(sys.stdin); root=Path(d["root"])
def digest(b): return hashlib.sha256(b).hexdigest()
def fail(): raise ValueError("invalid prepared input")
if not root.is_dir() or root.is_symlink() or root.is_junction(): fail()
for p in [root,*root.parents]:
    if p.is_symlink() or p.is_junction(): fail()
m=json.loads((root/"prepared-manifest.json").read_text(encoding="utf-8"))
c=json.loads((root/"COMPLETE.json").read_text(encoding="utf-8"))
if m["fingerprint"] != digest(canonical_bytes({k:v for k,v in m.items() if k!="fingerprint"})): fail()
if c != {"schemaVersion":"1.0","fingerprint":m["fingerprint"],"manifestSha256":digest((root/"prepared-manifest.json").read_bytes())}: fail()
if json.loads((root/"scenario.json").read_text(encoding="utf-8")) != d["scenario"]: fail()
seen=set(); dirs=set()
for p in root.rglob("*"):
    if p.is_symlink() or p.is_junction() or (p.stat().st_file_attributes & 1024): fail()
    rel=str(p.relative_to(root))
    if p.is_file():
        if rel in ("prepared-manifest.json","COMPLETE.json"): continue
        if rel not in m["files"] or digest(p.read_bytes()) != m["files"][rel]: fail()
        seen.add(rel)
    elif p.is_dir(): dirs.add(rel)
    else: fail()
expected_dirs=set()
for name in m["files"]:
    parts=name.split("\\")
    if any(x in ("",".","..") or ":" in x or "/" in x for x in parts): fail()
    for i in range(1,len(parts)): expected_dirs.add("\\".join(parts[:i]))
if seen != set(m["files"]) or dirs != expected_dirs: fail()
sf=digest(canonical_bytes({p.name:digest(p.read_bytes()) for p in Path("schemas").glob("*.schema.json")}))
bf=digest(canonical_bytes({n:digest((Path("generator")/n).read_bytes()) for n in ("build_scenario.py","validate_pack.py")}))
if m["schemaFingerprint"]!=sf or m["builderFingerprint"]!=bf: fail()
if validate_files(root/"scenario.json",root/"personas"/"personas.json"): fail()
for a in m["assets"]:
    p=root/a["relativePath"]
    if p.stat().st_size==0 or p.stat().st_size>33554432 or digest(p.read_bytes())!=a["sha256"]: fail()
print(json.dumps(m))
'@
    try { $manifest = Invoke-SeedPython -Code $code -InputObject @{ root = $PreparedPath; scenario = $Scenario } }
    catch { throw 'Seed.Storage.Prepared: Prepared bytes, schema, builder, media types or complete marker differ.' }
    if ($Context.tenantId -ine $record.TenantId -or $Context.clientId -ine $record.ClientId -or
        $Context.presenterUpn -ine $record.Identity.Presenter.Upn -or $Context.scenarioId -cne $Scenario.scenario.id -or
        $Context.preparedFingerprint -cne $manifest.fingerprint -or $Context.personaPackFingerprint -cne $manifest.personaPackFingerprint -or
        $Context.personaPackFingerprint -cne $record.Identity.PersonaPackFingerprint -or $Context.bindingFingerprint -cne $record.Identity.BindingFingerprint -or
        $Context.instanceId -cne $record.Identity.InstanceId) { throw 'Seed.Storage.Context: Exact prepared, identity and run context required.' }
    $storage = @{
        Session = $Session; Context = $Context; RunId = $RunId; StatePath = $StatePath; PreparedPath = $PreparedPath
        IdentityFingerprint = Get-SeedFingerprint $record.Identity; PresenterId = $record.Identity.Presenter.ObjectId
        Operations = [Collections.Generic.List[object]]::new(); ById = @{}; Ids = @{}; Evidence = @{}; RunState = $null
        Assets = @{}; Directories = @{}; Scenario = $Scenario; CreationProofs = @{}
    }
    $namespace = (Get-SeedFingerprint @{ context = $Context; runId = $RunId }).Substring(0, 32)
    $containers = @{}
    if ($Scenario.Contains('onedrive')) {
        $drive = Invoke-SeedGraph -Session $Session -Method GET -Path "/users/$($storage.PresenterId)/drive?`$select=id,driveType,owner"
        $root = Invoke-SeedGraph -Session $Session -Method GET -Path "/drives/$($drive.id)/root"
        foreach ($container in $Scenario.onedrive.drives) {
            if ($container.ownerRole -cne 'Presenter' -or $containers.ContainsKey("onedrive/$($container.id)") -or $containers.ContainsKey('onedrive/Presenter')) { throw 'Seed.Storage.Owner: Only one Presenter-owned OneDrive container is supported.' }
            $id = Add-SeedStorageOperation $storage "onedrive/$($container.id)/root" onedrive @{
                Kind = 'Folder'; Name = "seed-$namespace"; DriveId = $drive.id; ParentId = $root.id
                Body = @{ name = "seed-$namespace"; folder = @{}; '@microsoft.graph.conflictBehavior' = 'fail' }
            }
            $containers["onedrive/$($container.id)"] = @{ OperationId = $id; GroupOperationId = ''; AssetRefs = @($container.assetRefs) }
            $containers['onedrive/Presenter'] = $true
        }
    }
    if ($Scenario.Contains('sharepoint')) {
        $libraryName = 'Project Documents'
        foreach ($site in $Scenario.sharepoint.sites) {
            if ('Presenter' -cnotin $site.ownerRoles -or $containers.ContainsKey("sharepoint/$($site.id)")) { throw 'Seed.Storage.Owner: Distinct sites with Presenter owner required.' }
            # List titles are unique per site; a clash would otherwise surface only after the Group and library are already created.
            if (@($site.lists | Where-Object { $_.displayName.Trim() -ieq $libraryName }).Count -gt 0) { throw "Seed.Storage.Collision: A site List cannot reuse the document library name '$libraryName' (case-insensitive); rename it before any write." }
            $owners = @($site.ownerRoles | ForEach-Object {
                if (-not $record.Identity.Roles.ContainsKey($_)) { throw 'Seed.Storage.Actor: Unbound owner role.' }
                $record.Identity.Roles[$_].ObjectId.ToLowerInvariant()
            } | Sort-Object -Unique)
            $members = @(@($site.memberRoles | ForEach-Object {
                if (-not $record.Identity.Roles.ContainsKey($_)) { throw 'Seed.Storage.Actor: Unbound member role.' }
                $record.Identity.Roles[$_].ObjectId.ToLowerInvariant()
            }) + $owners | Sort-Object -Unique)
            if ($owners.Count + $members.Count -gt 20) { throw 'Seed.Storage.Group: Atomic Group creation supports at most twenty owner/member bindings; no membership repair is allowed.' }
            $marker = Get-SeedFingerprint @{ run = $namespace; site = $site }
            $body = @{
                displayName = $site.displayName; description = "M365DataGenerator:$marker"; mailNickname = "seed-$($marker.Substring(0,32))"
                groupTypes = @('Unified'); mailEnabled = $true; securityEnabled = $false; visibility = 'Private'
                'owners@odata.bind' = @($owners | ForEach-Object { "https://graph.microsoft.com/v1.0/users/$_" })
                'members@odata.bind' = @($members | ForEach-Object { "https://graph.microsoft.com/v1.0/users/$_" })
            }
            $group = Add-SeedStorageOperation $storage "sharepoint/$($site.id)/group" sharepoint @{ Kind = 'Group'; Body = $body; OwnerIds = $owners; MemberIds = $members; LogicalId = $site.id }
            $library = Add-SeedStorageOperation $storage "sharepoint/$($site.id)/library" sharepoint @{
                Kind = 'Library'; ParentOperationId = $group; GroupOperationId = $group; LogicalId = "$($site.id)/documents"
                Body = @{ displayName = $libraryName; description = "M365DataGenerator:$marker:library"; list = @{ template = 'documentLibrary' }; columns = @() }
            }
            $containers["sharepoint/$($site.id)"] = @{ OperationId = $library; GroupOperationId = $group; AssetRefs = @($site.assetRefs) }
            foreach ($list in $site.lists) {
                $listOp = Add-SeedStorageOperation $storage "sharepoint/$($site.id)/lists/$($list.id)" sharepoint @{
                    Kind = 'List'; ParentOperationId = $group; GroupOperationId = $group; LogicalId = "$($site.id)/$($list.id)"
                    CanonicalList = $list
                    Body = @{ displayName = $list.displayName; description = "M365DataGenerator:$marker:list:$($list.id)"; list = @{ template = 'genericList' }; columns = @(ConvertTo-StorageColumns $list.columns) }
                }
                foreach ($item in $list.items) {
                    $null = Add-SeedStorageOperation $storage "sharepoint/$($site.id)/lists/$($list.id)/items/$($item.id)" sharepoint @{
                        Kind = 'ListItem'; ParentOperationId = $listOp; GroupOperationId = $group
                        Body = @{ fields = ConvertTo-StorageFields $list $item.values }
                    }
                }
            }
        }
    }
    $assetIds = @{}; $destinations = @{}
    foreach ($asset in $Scenario.assets) {
        if ($assetIds.ContainsKey($asset.id)) { throw 'Seed.Storage.Duplicate: Duplicate asset ID.' }
        $assetIds[$asset.id] = $true
        $d = $asset.destination; $key = "$($d.workload)/$($d.containerId)"
        Assert-StorageRelativePath $d.folder; Assert-StorageRelativePath $d.name -FileName
        if (-not $containers.ContainsKey($key) -or $asset.id -cnotin $containers[$key].AssetRefs) { throw 'Seed.Storage.Asset: Exact declared container reference required.' }
        $folder = $d.folder -replace '/', '\'
        $dest = "$key/$folder/$($d.name)"
        if ($destinations.ContainsKey($dest)) { throw 'Seed.Storage.Duplicate: Duplicate destination.' }
        $destinations[$dest] = $true
        $matches = @($manifest.assets | Where-Object id -CEQ $asset.id)
        if ($matches.Count -ne 1 -or (Get-SeedFingerprint $matches[0].destination) -cne (Get-SeedFingerprint $d)) { throw 'Seed.Storage.Prepared: Exact asset manifest destination required.' }
        $source = Join-Path $PreparedPath $matches[0].relativePath
        $storage.Assets[$asset.id] = @{ Path = $source; Sha256 = $matches[0].sha256; Size = (Get-Item -LiteralPath $source).Length; Workload = $d.workload }
        $parent = $containers[$key].OperationId; $group = $containers[$key].GroupOperationId; $partial = ''
        foreach ($segment in ($folder -split '\\')) {
            $partial += "\$segment"; $directoryKey = "$key$partial"
            if (-not $storage.Directories.ContainsKey($directoryKey)) {
                $storage.Directories[$directoryKey] = Add-SeedStorageOperation $storage "$key/folders$partial" $d.workload @{
                    Kind = 'Folder'; Name = $segment; ParentOperationId = $parent; GroupOperationId = $group
                    Body = @{ name = $segment; folder = @{}; '@microsoft.graph.conflictBehavior' = 'fail' }
                }
            }
            $parent = $storage.Directories[$directoryKey]
        }
        $contentParent = $parent
        if ($UseUploadSessions) {
            $contentParent = Add-SeedStorageOperation $storage "$key/assets/$($asset.id)/session" $d.workload @{
                Kind = 'Session'; Name = $d.name; ParentOperationId = $parent; GroupOperationId = $group; AssetId = $asset.id
                Sha256 = $matches[0].sha256; Size = (Get-Item -LiteralPath $source).Length
                Body = @{ item = @{ name = $d.name; '@microsoft.graph.conflictBehavior' = 'fail' } }
            }
        }
        $null = Add-SeedStorageOperation $storage "$key/assets/$($asset.id)/content" $d.workload @{
            Kind = 'Content'; Name = $d.name; ParentOperationId = $contentParent; GroupOperationId = $group; AssetId = $asset.id
            Transfer = $(if ($UseUploadSessions) { 'Session' } else { 'Simple' })
            Sha256 = $matches[0].sha256; Size = (Get-Item -LiteralPath $source).Length
        }
    }
    foreach ($path in $destinations.Keys) {
        foreach ($other in $destinations.Keys) {
            if ($other.StartsWith($path + '/', [StringComparison]::OrdinalIgnoreCase) -or $other.StartsWith($path + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Seed.Storage.Path: A file cannot also be a parent directory.' }
        }
    }
    $checks = @{}
    $getProof = ${function:Get-SeedStorageProof}
    $checkRequest = ${function:Test-SeedStorageRequest}
    foreach ($workload in @('onedrive', 'sharepoint')) {
        $checks[$workload] = { param($s, $o) & $getProof -Session $s -Storage $storage -Operation $o }.GetNewClosure()
    }
    $validator = { param($s, $o, $r) & $checkRequest -Session $s -Storage $storage -Operation $o -Request $r }.GetNewClosure()
    $requests = @()
    foreach ($op in $storage.Operations) {
        if (-not $op.StorageScope.ParentOperationId) { $requests += Get-SeedStorageRequest $Session $storage $op }
    }
    $handle = [pscustomobject]@{ AdapterId = [guid]::NewGuid().ToString(); Operations = @($storage.Operations.ToArray()); ResourceChecks = $checks; RequestCheck = $validator; Requests = $requests }
    $storage.Handle = $handle; $storage.OperationsFingerprint = Get-SeedFingerprint $handle.Operations
    if (-not $record.Contains('StorageAdapters')) { $record.StorageAdapters = @{} }
    $record.StorageAdapters[$handle.AdapterId] = $storage
    return $handle
}

function Set-SeedStorageRunState {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Adapter, [Parameter(Mandatory)]$RunState)
    $storage = Get-SeedStorageRecord $Session $Adapter
    if (-not $script:SeedValidatedStates.ContainsKey((Get-SeedFingerprint $RunState)) -or
        $RunState.runId -cne $storage.RunId -or (Get-SeedFingerprint $RunState.context) -cne (Get-SeedFingerprint $storage.Context)) { throw 'Seed.Storage.State: Supply an exact T2-validated journal, never a caller-created receipt.' }
    $storage.RunState = ConvertTo-SeedMap $RunState; $storage.Ids.Clear()
    foreach ($op in $storage.Operations) {
        $result = @($RunState.results | Where-Object { $_.id -ceq $op.OperationId -and $_.workload -ceq $op.Workload -and $_.status -ceq 'Verified' })
        if ($RunState.status -ceq 'Completed' -and $result.Count -ne 1) { throw 'Seed.Storage.State: Complete exact storage result set required.' }
        if ($result.Count -eq 1) { $storage.Ids[$op.OperationId] = $result[0].objectId }
    }
}

function Get-SeedStorageRequest {
    param($Session, $Storage, $Operation)
    $scope = $Operation.StorageScope
    $request = @{ OperationId = $Operation.OperationId; Method = 'POST' }
    switch ($scope.Kind) {
        Group { $request.Path = '/groups'; $request.Body = $scope.Body }
        { $_ -in @('List', 'Library') } {
            $site = Get-SeedStorageSite $Session $Storage $scope.GroupOperationId
            $request.Path = "/sites/$($site.id)/lists"; $request.Body = $scope.Body
        }
        ListItem {
            $site = Get-SeedStorageSite $Session $Storage $scope.GroupOperationId
            $id = Get-SeedStorageResultId $Storage $scope.ParentOperationId
            $request.Path = "/sites/$($site.id)/lists/$id/items"; $request.Body = $scope.Body
        }
        default {
            $directory = Get-SeedStorageDirectory $Session $Storage $scope
            $base = "/drives/$($directory.DriveId)/items/$($directory.ParentId)"
            if ($scope.Kind -ceq 'Folder') { $request.Path = "$base/children"; $request.Body = $scope.Body }
            else {
                $base += ':/' + [uri]::EscapeDataString($scope.Name) + ':/'
                if ($scope.Kind -ceq 'Session') { $request.Path = $base + 'createUploadSession'; $request.Body = $scope.Body }
                else {
                    $request.Method = 'PUT'; $request.Path = $base + 'content'
                    $source = $Storage.Assets[$scope.AssetId]
                    $bytes = [IO.File]::ReadAllBytes($source.Path)
                    if ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant() -cne $scope.Sha256 -or $bytes.Length -ne $scope.Size) { throw 'Seed.Storage.Source: Source changed after preflight.' }
                    $request.RawBody = $bytes
                    if ($scope.Contains('Transfer') -and $scope.Transfer -ceq 'Simple') {
                        $request.Path += '?@microsoft.graph.conflictBehavior=fail'
                    }
                }
            }
        }
    }
    return $request
}

function Test-SeedStorageRequest {
    param($Session, $Storage, $Operation, $Request)
    if (-not $Storage.ById.ContainsKey($Operation.OperationId) -or (Get-SeedOperationDigest $Storage.ById[$Operation.OperationId]) -cne (Get-SeedOperationDigest $Operation)) { throw 'Seed.Storage.Scope: Operation differs from upfront scope.' }
    $expected = Get-SeedStorageRequest $Session $Storage $Storage.ById[$Operation.OperationId]
    $body = if ($Request.Contains('Body')) { $Request.Body } else { $null }
    $raw = if ($Request.Contains('RawBody')) { [byte[]]$Request.RawBody } else { $null }
    $expectedBody = if ($expected.Contains('Body')) { $expected.Body } else { $null }
    $expectedRaw = if ($expected.Contains('RawBody')) { [byte[]]$expected.RawBody } else { $null }
    $digest = Get-SeedRequestFingerprint $Request.Method $Request.Path $body $raw
    if ($digest -cne (Get-SeedRequestFingerprint $expected.Method $expected.Path $expectedBody $expectedRaw)) { throw 'Seed.Storage.Scope: Exact method, parent IDs, body and bytes must match the approved logical operation.' }
    $parentId = $Operation.StorageScope.ParentOperationId
    if (-not $parentId) { throw 'Seed.Storage.Scope: Root requests must be approved upfront.' }
    # Read the actual parent again; a completed journal is not itself remote evidence.
    $null = Get-SeedStorageSnapshot $Session $Storage $Storage.ById[$parentId]
    return @{
        OperationFingerprint = Get-SeedOperationDigest $Operation; RequestFingerprint = $digest
        MatchesPlan = $true; PresenterVerified = $true; ParentOperationId = $parentId; ParentObjectId = Get-SeedStorageResultId $Storage $parentId
    }
}

function Get-SeedStorageSnapshot {
    param($Session, $Storage, $Operation)
    $id = Get-SeedStorageResultId $Storage $Operation.OperationId
    switch ($Operation.StorageScope.Kind) {
        Group { return Get-SeedStorageGroupSnapshot $Session $Storage $Operation $id }
        { $_ -in @('List', 'Library') } { return Get-SeedStorageListSnapshot $Session $Storage $Operation $id }
        ListItem { return Get-SeedStorageListItemSnapshot $Session $Storage $Operation $id }
        Session {
            $scope = $Operation.StorageScope
            $directory = Get-SeedStorageDirectory $Session $Storage $scope
            if ($id -cne $directory.ParentId) { throw 'Seed.Storage.Session: Upload allocation is tied to the exact parent ID.' }
            $null = Get-SeedStorageSnapshot $Session $Storage $Storage.ById[$scope.ParentOperationId]
            if ($null -ne $Storage.RunState -and $Storage.RunState.status -ceq 'Completed') {
                $content = @($Storage.Operations | Where-Object { $_.StorageScope.Kind -ceq 'Content' -and $_.StorageScope.ParentOperationId -ceq $Operation.OperationId })
                if ($content.Count -ne 1) { throw 'Seed.Storage.Session: The allocation must resolve to one exact completed content operation.' }
                $null = Get-SeedStorageFileSnapshot $Session $Storage $content[0] (Get-SeedStorageResultId $Storage $content[0].OperationId)
            } else {
                $null = Read-SeedUploadSession -Session $Session -OperationId $Operation.OperationId
            }
            return @{ id = $id; driveId = $directory.DriveId; name = $scope.Name; sha256 = $scope.Sha256; conflictBehavior = 'fail'; allocation = 'AcceptedInThisRun' }
        }
        default { return Get-SeedStorageFileSnapshot $Session $Storage $Operation $id }
    }
}

function Test-SeedStorageCompleteCollections {
    param($Session, $Storage)
    foreach ($op in $Storage.Operations) {
        $scope = $op.StorageScope; $id = Get-SeedStorageResultId $Storage $op.OperationId
        if ($scope.Kind -in @('Folder', 'Library')) {
            if ($scope.Kind -ceq 'Library') {
                $dummy = @{ ParentOperationId = $op.OperationId }
                $directory = Get-SeedStorageDirectory $Session $Storage $dummy
            } else {
                $d = Get-SeedStorageDirectory $Session $Storage $scope
                $directory = @{ DriveId = $d.DriveId; ParentId = $id }
            }
            $actual = @(Get-SeedGraphCollection -Session $Session -Path "/drives/$($directory.DriveId)/items/$($directory.ParentId)/children" | ForEach-Object { $_.id } | Sort-Object)
            $expected = @()
            foreach ($child in $Storage.Operations) {
                $s = $child.StorageScope
                $parent = $s.ParentOperationId
                if ($s.Kind -ceq 'Content' -and (-not $s.Contains('Transfer') -or $s.Transfer -cne 'Simple')) {
                    $parent = $Storage.ById[$parent].StorageScope.ParentOperationId
                }
                if ($s.Kind -in @('Folder', 'Content') -and $parent -ceq $op.OperationId) { $expected += Get-SeedStorageResultId $Storage $child.OperationId }
            }
            $expected = @($expected | Sort-Object)
        } elseif ($scope.Kind -ceq 'Group') {
            $group = Get-SeedStorageGroupSnapshot $Session $Storage $op $id
            $lists = @(Get-SeedGraphCollection -Session $Session -Path "/sites/$($group.siteId)/lists?`$select=id,system")
            $actual = @($lists | Where-Object { -not $_.Contains('system') -or $null -eq $_.system } | ForEach-Object { $_.id } | Sort-Object)
            $expected = @(@($group.defaultLibrary.id) + @($Storage.Operations | Where-Object {
                $_.StorageScope.GroupOperationId -ceq $op.OperationId -and $_.StorageScope.Kind -in @('List', 'Library')
            } | ForEach-Object { Get-SeedStorageResultId $Storage $_.OperationId }) | Sort-Object)
            $defaultChildren = @(Get-SeedGraphCollection -Session $Session -Path "/drives/$($group.defaultLibrary.driveId)/items/$($group.defaultLibrary.rootId)/children")
            if ($defaultChildren.Count -ne 0) { throw 'Seed.Storage.Collection: Undeclared content in the automatically created default library.' }
        } elseif ($scope.Kind -ceq 'List') {
            $site = Get-SeedStorageSite $Session $Storage $scope.GroupOperationId
            $actual = @(Get-SeedGraphCollection -Session $Session -Path "/sites/$($site.id)/lists/$id/items" | ForEach-Object { $_.id } | Sort-Object)
            $expected = @($Storage.Operations | Where-Object { $_.StorageScope.ParentOperationId -ceq $op.OperationId } | ForEach-Object { Get-SeedStorageResultId $Storage $_.OperationId } | Sort-Object)
        } else { continue }
        if (($actual -join "`n") -cne ($expected -join "`n")) { throw 'Seed.Storage.Collection: Exact declared remote ID set changed or pagination is incomplete.' }
    }
}

function Get-SeedStorageProof {
    param($Session, $Storage, $Operation, [switch]$Ancestor)
    if (-not $Storage.ById.ContainsKey($Operation.OperationId) -or
        (Get-SeedOperationDigest $Operation) -cne (Get-SeedOperationDigest $Storage.ById[$Operation.OperationId])) { throw 'Seed.Storage.Scope: Resource checks only cover the exact upfront adapter operations.' }
    if (-not $Ancestor) {
        $null = Get-SeedStorageRecord $Session $Storage.Handle
        Assert-SeedStorageActors $Session $Storage
        Assert-SeedStorageSources $Storage
    }
    $record = Get-SeedSessionRecord $Session
    if (@($Storage.Operations | Where-Object { $_.StorageScope.Kind -ceq 'Session' }).Count -gt 0 -and
        (-not $record.Contains('UploadTransport') -or $record.UploadTransport -isnot [scriptblock])) { throw 'Seed.Storage.Transport: A scoped upload transport must be available before any writes.' }
    if ($null -ne $Storage.RunState -and $Storage.RunState.status -ceq 'Completed') {
        Test-SeedStorageCompleteCollections $Session $Storage
        $snapshot = Get-SeedStorageSnapshot $Session $Storage $Operation
        $Storage.Evidence[$Operation.OperationId] = $snapshot
        return @{ State = 'Existing'; ToolOwned = $true; ContentVerified = $true; PresenterVerified = $true; ObjectId = Get-SeedStorageResultId $Storage $Operation.OperationId; DataFingerprint = $Operation.DataFingerprint; EvidenceFingerprint = Get-SeedFingerprint $snapshot }
    }
    if ($null -ne $Storage.RunState -and $Storage.RunState.status -cne 'Planned') { throw 'Seed.Storage.State: Unknown or partial runs are never resumed.' }
    $scope = $Operation.StorageScope
    if ($scope.Kind -ceq 'Group') {
        $alias = [uri]::EscapeDataString("mailNickname eq '$($scope.Body.mailNickname)'")
        $groups = @(Get-SeedGraphCollection -Session $Session -Path "/groups?`$filter=$alias")
        if ($groups.Count -ne 0) { throw 'Seed.Storage.Collision: Existing groups are never adopted, even if Presenter owns them.' }
    } elseif (-not $scope.ParentOperationId) {
        $null = Get-SeedPresenterDrive $Session $Storage.PresenterId $scope.DriveId
        $children = @(Get-SeedGraphCollection -Session $Session -Path "/drives/$($scope.DriveId)/items/$($scope.ParentId)/children")
        if (@($children | Where-Object { $_.name -ieq $scope.Name }).Count -ne 0) { throw 'Seed.Storage.Collision: Run namespace must be fresh.' }
        $null = Get-SeedStorageDriveAccess $Session $Storage $scope.DriveId $scope.ParentId ''
    } else {
        # Re-prove ancestor absence, not merely a caller-supplied "new parent" flag.
        $null = Get-SeedStorageProof $Session $Storage $Storage.ById[$scope.ParentOperationId] -Ancestor
    }
    return @{ State = 'Absent'; AbsenceVerified = $true; PresenterVerified = $true }
}

function Get-SeedStorageOutput {
    param($Storage)
    $assets = @{}; $links = @()
    foreach ($op in $Storage.Operations) {
        $scope = $op.StorageScope; $snapshot = $Storage.Evidence[$op.OperationId]
        if ($scope.Kind -ceq 'Content') {
            $assets[$scope.AssetId] = @{
                webUrl = $snapshot.webUrl; targetWorkload = $(if ($op.Workload -ceq 'onedrive') { 'OneDrive' } else { 'SharePoint' })
                resourceId = $snapshot.id; sourceSha256 = $scope.Sha256; presenterVerified = $true
            }
        } elseif ($scope.Kind -in @('Group', 'Library', 'List')) {
            $links += @{
                kind = $(switch ($scope.Kind) { Group { 'site' } Library { 'documentLibrary' } List { 'list' } })
                logicalId = $scope.LogicalId; resourceId = $(if ($scope.Kind -ceq 'Group') { $snapshot.siteId } else { $snapshot.id })
                displayName = $scope.Body.displayName; webUrl = $snapshot.webUrl; presenterAccessStatus = 'StructuralVerified'
            }
            if ($scope.Kind -ceq 'Group') {
                $links += @{
                    kind = 'documentLibrary'; logicalId = "$($scope.LogicalId)/defaultDocuments"; resourceId = $snapshot.defaultLibrary.id
                    displayName = $snapshot.defaultLibrary.displayName; webUrl = $snapshot.defaultLibrary.webUrl; presenterAccessStatus = 'StructuralVerified'
                }
            }
        }
    }
    $record = Get-SeedSessionRecord $Storage.Session
    if (-not $record.Contains('StorageAssetMaps')) { $record.StorageAssetMaps = [Collections.Generic.List[object]]::new() }
    $record.StorageAssetMaps.Add(@{
        Map = $assets; Fingerprint = Get-SeedFingerprint $assets; Adapter = $Storage.Handle
        ContextFingerprint = Get-SeedFingerprint $Storage.Context; RunId = $Storage.RunId
    })
    return @{
        AssetUrlMap = $assets; ResourceLinkIndex = $links
        PresenterProof = @{
            Kind = 'GraphStructural'; ActualUiStatus = 'Required'; RemoteAclStatus = 'NotProven'
            Limitation = 'Application read-back and recorded default inheritance are not Presenter UI or effective ACL proof. Actual Presenter UI check is required; Graph cannot enumerate arbitrary SharePoint ACL changes.'
        }
    }
}

function Test-SeedStorage {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Adapter)
    $storage = Get-SeedStorageRecord $Session $Adapter
    $record = Get-SeedSessionRecord $Session
    $record.ReadOnlyDepth++
    try {
        if ($null -eq $storage.RunState -or $storage.RunState.status -cne 'Completed') { throw 'Seed.Storage.Verify: An exact completed T2-validated journal is required.' }
        Assert-SeedStorageActors $Session $storage
        Assert-SeedStorageSources $storage
        Test-SeedStorageCompleteCollections $Session $storage
        foreach ($op in $storage.Operations) {
            $snapshot = Get-SeedStorageSnapshot $Session $storage $op
            $result = @($storage.RunState.results | Where-Object { $_.id -ceq $op.OperationId -and $_.workload -ceq $op.Workload })[0]
            if ((Get-SeedFingerprint $snapshot) -cne $result.evidence.sha256) { throw 'Seed.Storage.Verify: Authoritative remote revision differs from the completed receipt.' }
            $storage.Evidence[$op.OperationId] = $snapshot
        }
        $output = Get-SeedStorageOutput $storage; $output.Verified = $true
        return $output
    } catch { throw 'Seed.Storage.Verify: Storage identity, content, schema, ACL, link or revision could not be verified.' }
    finally { $record.ReadOnlyDepth-- }
}

function Invoke-UploadFiles {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Adapter, [Parameter(Mandatory)][object[]]$Plan)
    $storage = Get-SeedStorageRecord $Session $Adapter
    $selected = @($Plan | Where-Object { $storage.ById.ContainsKey($_.OperationId) })
    if ($selected.Count -ne $storage.Operations.Count -or @($Plan | Where-Object Action -eq Block).Count -gt 0 -or
        @($selected | Where-Object Action -notin @('Create', 'Skip')).Count -gt 0) { throw 'Seed.Storage.Plan: Whole preflight must pass; no partial storage execution.' }
    foreach ($op in $selected) {
        $comparison = ConvertTo-SeedMap $op
        if ($op.Action -ceq 'Skip') {
            if ($op.TargetId -cne (Get-SeedStorageResultId $storage $op.OperationId)) { throw 'Seed.Storage.Plan: Skip ID differs from the exact receipt.' }
            $comparison.TargetId = $storage.ById[$op.OperationId].TargetId
        }
        if ((Get-SeedOperationDigest $comparison) -cne (Get-SeedOperationDigest $storage.ById[$op.OperationId])) { throw 'Seed.Storage.Plan: The exact upfront scope changed.' }
    }
    if (@($selected | Where-Object Action -eq Skip).Count -eq $selected.Count) { return Test-SeedStorage $Session $Adapter }
    if (@($selected | Where-Object Action -eq Skip).Count -gt 0) { throw 'Seed.Storage.Plan: Partial completion is never repaired.' }
    $record = Get-SeedSessionRecord $Session; $approval = $record.Approval
    if ($null -eq $approval -or $approval.Path -cne $storage.StatePath -or $approval.RunId -cne $storage.RunId -or
        (Get-SeedFingerprint $Plan) -cne $approval.PlanFingerprint) { throw 'Seed.Storage.Approval: Exact global approval must precede all writes.' }
    Assert-SeedStorageActors $Session $storage
    Assert-SeedStorageSources $storage
    foreach ($operation in $storage.Operations) {
        $id = $null
        try {
            $request = Get-SeedStorageRequest $Session $storage $operation
            $args = @{ Session = $Session; Request = $request; RequestCheck = $Adapter.RequestCheck }
            if ($operation.StorageScope.Kind -ceq 'Content' -and
                (-not $operation.StorageScope.Contains('Transfer') -or $operation.StorageScope.Transfer -cne 'Simple')) {
                $args.UploadFromOperationId = $operation.StorageScope.ParentOperationId
            }
            $response = Write-SeedGraph @args
            if ($operation.StorageScope.Kind -ceq 'Session') {
                if ($response.accepted -cne $true) { throw 'Seed.Storage.Session: Session allocation was not accepted.' }
                $id = (Get-SeedStorageDirectory $Session $storage $operation.StorageScope).ParentId
            } else {
                Assert-SeedFields $response @('id') 'Seed.Storage.ReadBack'
                $id = $response.id
            }
            $storage.Ids[$operation.OperationId] = $id
            if ($operation.Workload -ceq 'sharepoint') {
                $storage.CreationProofs[$operation.OperationId] = @{
                    objectId = $id
                    requestSha256 = Get-SeedRequestFingerprint $request.Method $request.Path $(if ($request.Contains('Body')) { $request.Body } else { $null }) $null
                }
                if ($request.Contains('RawBody')) {
                    $storage.CreationProofs[$operation.OperationId].requestSha256 = Get-SeedRequestFingerprint $request.Method $request.Path $null ([byte[]]$request.RawBody)
                }
            }
            # Only newly created SharePoint containers may need propagation: at most 36 GET-only waits (180 seconds).
            for ($attempt = 0; $attempt -le 36; $attempt++) {
                try { $snapshot = Get-SeedStorageSnapshot $Session $storage $operation; break }
                catch {
                    if ($operation.Workload -cne 'sharepoint' -or $operation.StorageScope.Kind -cnotin @('Group', 'Library', 'List') -or
                        $attempt -eq 36 -or $_.Exception.Message -cnotmatch '^Seed\.Graph\.404:') { throw }
                    & $record.Delay 5 | Out-Null
                }
            }
            $storage.Evidence[$operation.OperationId] = $snapshot
            Write-SeedRunEvent -Path $approval.Path -RunId $approval.RunId -Context $approval.Context -Operations $approval.Operations -OperationId $operation.OperationId -Workload $operation.Workload -Action Verify -Status Verified -ObjectId $id -ReadBack $snapshot | Out-Null
        } catch {
            $diagnostic = @{
                Stage = 'StorageReadBack'; HttpStatus = (Get-SeedGraphFailure $_.Exception).Status
                ExceptionType = $_.Exception.GetType().FullName
            }
            if ($_.Exception.Data.Contains('SeedDiagnostic')) { $diagnostic = $_.Exception.Data['SeedDiagnostic'] }
            $code = [regex]::Match($_.Exception.Message, '\bSeed\.[A-Za-z0-9_.]+').Value
            $diagnostic.ErrorCode = $(if ($code) { $code } else { 'Seed.Storage.ReadBack' })
            Write-Host ('[StorageDiagnostic] ' + ($diagnostic | ConvertTo-Json -Compress))
            $state = Get-SeedRunState -Path $approval.Path -RunId $approval.RunId -Context $approval.Context -Operations $approval.Operations
            $result = @($state.results | Where-Object { $_.id -ceq $operation.OperationId -and $_.workload -ceq $operation.Workload })[0]
            if ($result.status -ceq 'Submitted') {
                Write-SeedRunEvent -Path $approval.Path -RunId $approval.RunId -Context $approval.Context -Operations $approval.Operations -OperationId $operation.OperationId -Workload $operation.Workload -Action Fail -Status Unknown -ObjectId $id -ErrorCode StorageReadBackUnknown | Out-Null
            }
            $failure = [InvalidOperationException]::new('Seed.Storage.Stopped: Preserve the journal and remote resources; unknown or partial operations are never retried or repaired.')
            $failure.Data['SeedDiagnostic'] = $diagnostic
            throw $failure
        }
    }
    $state = Get-SeedRunState -Path $approval.Path -RunId $approval.RunId -Context $approval.Context -Operations $approval.Operations
    if ($state.status -ceq 'Completed') {
        Set-SeedStorageRunState $Session $Adapter $state
        return Test-SeedStorage $Session $Adapter
    }
    # Other approved workload adapters may still be Planned in the global run.
    Test-SeedStorageCompleteCollections $Session $storage
    return Get-SeedStorageOutput $storage
}
