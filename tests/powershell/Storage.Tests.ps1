$storageScratch = Join-Path $root ('tests\.scratch\t3-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $storageScratch -Force | Out-Null
foreach ($file in @('Seed-OneDriveOwnership.ps1', 'Invoke-SeedSharePoint.ps1', 'Invoke-UploadFiles.ps1')) {
    $path = Join-Path $root "engine\$file"
    if (Test-Path -LiteralPath $path) { . $path }
}
function Copy-StorageValue($v) { $v | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -DateKind String }
function Invoke-StoragePendingRead($Model, [string]$Stage) {
    if (-not $Model.PendingReads.ContainsKey($Stage)) { return }
    $pending = $Model.PendingReads[$Stage]
    $pending.Attempts++
    if ($pending.Remaining -gt 0) {
        $pending.Remaining--
        throw (New-GraphStubError $pending.Status)
    }
}
function New-StorageEnvironment([string]$ListDisplayName = '') {
    $dir = Join-Path $storageScratch ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $c = Get-Content (Join-Path $root 'tests\fixtures\managed-config.json') -Raw | ConvertFrom-Json -AsHashtable
    $s = Get-Content (Join-Path $root 'tests\fixtures\scenario.json') -Raw | ConvertFrom-Json -AsHashtable
    $s.Remove('outlook'); $s.Remove('teams')
    if ($ListDisplayName) { $s.sharepoint.sites[0].lists[0].displayName = $ListDisplayName }
    $s.onedrive.drives[0].ownerRole = 'Presenter'
    $s.assets[0].destination.folder = 'Training\Nested'
    $a = Copy-StorageValue $s.assets[0]; $a.id = 'shared'; $a.destination.workload = 'sharepoint'; $a.destination.containerId = 'site'
    $s.assets += $a; $s.sharepoint.sites[0].assetRefs = @('shared')
    $s.sharepoint.sites[0].lists[0].columns += @(
        @{ id = 'amount'; name = 'Amount'; type = 'number' }, @{ id = 'units'; name = 'Units'; type = 'integer' },
        @{ id = 'when'; name = 'When'; type = 'dateTime' }, @{ id = 'stage'; name = 'Stage'; type = 'choice'; choices = @('Open', 'Done') }
    )
    $v = $s.sharepoint.sites[0].lists[0].items[0].values
    $v.amount = 2.5; $v.units = 3; $v.when = '2026-10-29T10:00:00+08:00'; $v.stage = 'Open'
    $scenarioPath = Join-Path $dir 'scenario.json'
    $s | ConvertTo-Json -Depth 100 | Set-Content $scenarioPath -Encoding utf8
    & (Join-Path $root '.venv\Scripts\python.exe') (Join-Path $root 'generator\build_scenario.py') --pack $scenarioPath --personas (Join-Path $root 'tests\fixtures\personas.json') --output (Join-Path $dir 'prepared') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Storage fixture build failed.' }
    $s = Get-Content (Join-Path $dir 'prepared\scenario.json') -Raw | ConvertFrom-Json -AsHashtable
    $m = Get-Content (Join-Path $dir 'prepared\prepared-manifest.json') -Raw | ConvertFrom-Json -AsHashtable
    $presenter = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
    $alice = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'; $bob = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
    $profiles = @{}; $roles = @{}
    $pack = Get-Content (Join-Path $root 'tests\fixtures\personas.json') -Raw | ConvertFrom-Json -AsHashtable
    foreach ($pair in @(@('Lead', 'alice', $alice), @('Analyst', 'bob', $bob))) {
        $person = @($pack.people | Where-Object personaId -eq $pair[1])[0]
        $profile = @{ usageLocation = 'TW'; managerObjectId = $(if ($pair[1] -eq 'bob') { $alice } else { $null }) }
        foreach ($f in @('displayName', 'jobTitle', 'department', 'companyName', 'officeLocation')) { $profile[$f] = $person[$f] }
        $roles[$pair[0]] = @{ ObjectId = $pair[2]; Upn = "demo-$($pair[1])@example.invalid"; ProfileFingerprint = Get-SeedFingerprint $profile }
        $profiles[$pair[2]] = $profile
    }
    $identity = @{
        TenantId = $c.tenantId; ClientId = $c.clientId; InstanceId = 'training01'; ScenarioId = $s.scenario.id
        PersonaPackFingerprint = $m.personaPackFingerprint; BindingFingerprint = ('a' * 64)
        Roles = $roles; Presenter = @{ ObjectId = $presenter; Upn = $c.presenterUpn; Provenance = 'ExistingReadBack' }
    }
    $identity.Roles.Presenter = $identity.Presenter; $identity.ActorFingerprint = Get-SeedFingerprint $identity.Roles
    $ctx = @{
        tenantId = $c.tenantId; clientId = $c.clientId; scenarioId = $s.scenario.id; personaPackId = 'fixture'
        personaPackFingerprint = $m.personaPackFingerprint; bindingFingerprint = $identity.BindingFingerprint
        preparedFingerprint = $m.fingerprint; presenterUpn = $c.presenterUpn; instanceId = 'training01'
    }
    $model = @{
        Counter = 0; Fault = ''; Presenter = $presenter; Identity = $identity; Profiles = $profiles
        Ledger = [Collections.Generic.List[object]]::new(); Groups = @{}; Lists = @{}; Items = @{}; Drives = @{}
        StatePath = Join-Path $dir 'storage.run-state.json'; Uploads = @{}; Context = $ctx
        PendingReads = @{}; Delays = [Collections.Generic.List[object]]::new(); FaultOnDelay = ''
    }
    $model.Drives.od = @{ id = 'od'; owner = @{ user = @{ id = $presenter } }; root = 'od-root' }
    $model.Items['od-root'] = @{ id = 'od-root'; name = 'root'; folder = @{}; eTag = 'root-v1'; parentReference = @{ driveId = 'od' }; webUrl = 'https://example.sharepoint.com/personal/p/Documents' }
    $createFile = {
        param($Drive, $Parent, $Name, [byte[]]$Bytes)
        $model.Counter++; $id = "file-$($model.Counter)"
        $model.Items[$id] = @{
            id = $id; name = $Name; eTag = "$id-v1"; cTag = "$id-content-v1"; size = $Bytes.Length
            parentReference = @{ id = $Parent; driveId = $Drive }; webUrl = "https://example.sharepoint.com/files/$id"
            file = @{ hashes = @{ sha256Hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant() } }
            Bytes = $Bytes
        }
        return @{ id = $id }
    }.GetNewClosure()
    $transport = {
        param($Method, $Path, $Body, $RawBody)
        $model.Ledger.Add(@{ Method = $Method; Path = $Path; Body = $(if ($Body) { Copy-StorageValue $Body } else { $null }) })
        if ($Method -ne 'GET') {
            $j = Get-Content $model.StatePath -Raw | ConvertFrom-Json -AsHashtable
            if ($j.events[-1].action -ne 'Submit' -or $j.events[-1].status -ne 'Submitted') { throw 'Missing durable Submit.' }
            if ($model.Fault -eq 'UnknownCreate') { throw (New-GraphStubError 503) }
        }
        if ($Method -eq 'GET' -and $Path -match '^/users/([^/]+)/drive\?') {
            $d = Copy-StorageValue $model.Drives.od
            if ($model.Fault -eq 'DriveOwner') { $d.owner.user.id = $alice }
            return $d
        }
        if ($Method -eq 'GET' -and $Path -match '^/users/([^/?]+)(.*)$') {
            $id = $Matches[1]; $tail = $Matches[2]
            if ($id -eq $presenter) { return @{ id = $presenter; userPrincipalName = $c.presenterUpn; accountEnabled = $true; userType = 'Member' } }
            if ($tail.StartsWith('/manager')) {
                if ($null -eq $model.Profiles[$id].managerObjectId) { throw (New-GraphStubError 404) }
                return @{ id = $model.Profiles[$id].managerObjectId }
            }
            $p = Copy-StorageValue $model.Profiles[$id]; $p.Remove('managerObjectId')
            $p.id = $id; $p.userPrincipalName = $identity.Roles[$(if ($id -eq $alice) { 'Lead' } else { 'Analyst' })].Upn
            $p.accountEnabled = $true; $p.userType = 'Member'
            if ($model.Fault -eq 'Profile') { $p.department = 'drift' }
            return $p
        }
        if ($Path -match '^/groups(?:\?|$)' -and $Method -eq 'GET') {
            if ($model.Fault -eq 'Pagination') { return @{ value = @(); '@odata.nextLink' = 'https://foreign.invalid/v1.0/groups' } }
            if ($model.Fault -eq 'PageCollision') {
                if ($Path.Contains('skiptoken')) { return @{ value = @(@{ id = 'foreign-owned-group' }) } }
                return @{ value = @(); '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/groups?$skiptoken=collision' }
            }
            $alias = [uri]::UnescapeDataString($Path)
            return @{ value = @($model.Groups.Values | Where-Object { $alias.Contains("'$($_.mailNickname)'") }) }
        }
        if ($Path -eq '/groups' -and $Method -eq 'POST') {
            $id = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
            $g = Copy-StorageValue $Body; $g.id = $id
            $g.Owners = @($Body['owners@odata.bind'] | ForEach-Object { @{ id = ($_ -split '/')[-1] } })
            $g.Members = @($Body['members@odata.bind'] | ForEach-Object { @{ id = ($_ -split '/')[-1] } })
            $model.Groups[$id] = $g
            $defaultId = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'
            $model.Lists[$defaultId] = @{
                id = $defaultId; displayName = 'Documents'; description = ''; list = @{ template = 'documentLibrary' }
                webUrl = 'https://example.sharepoint.com/sites/actual/Shared%20Documents'; DriveId = 'default-drive'; columns = @()
            }
            $model.Drives['default-drive'] = @{ id = 'default-drive'; root = 'default-root'; list = @{ id = $defaultId } }
            $model.Items['default-root'] = @{ id = 'default-root'; name = 'root'; folder = @{}; eTag = 'default-v1'; parentReference = @{ driveId = 'default-drive' }; webUrl = $model.Lists[$defaultId].webUrl }
            if ($model.Fault -eq 'UnknownGroup') { throw (New-GraphStubError 503) }
            return @{ id = $id }
        }
        if ($Path -match '^/groups/([^/?]+)(.*)$' -and $Method -eq 'GET') {
            $id = $Matches[1]; $tail = $Matches[2]
            if (-not $model.Groups.ContainsKey($id)) { throw (New-GraphStubError 404) }
            $g = $model.Groups[$id]
            if ($tail.StartsWith('/owners')) { return @{ value = @($(if ($model.Fault -ne 'ACL') { $g.Owners })) } }
            if ($tail.StartsWith('/members')) {
                if ($model.Fault -eq 'PagedMembers') {
                    if ($tail.Contains('skiptoken')) { return @{ value = @($g.Members | Select-Object -Skip 1) } }
                    return @{ value = @($g.Members[0]); '@odata.nextLink' = "https://graph.microsoft.com/v1.0/groups/$id/members?`$skiptoken=more" }
                }
                return @{ value = @($g.Members | Where-Object { $model.Fault -ne 'MemberACL' -or $_.id -ne $presenter }) }
            }
            if ($tail.StartsWith('/sites/root')) {
                Invoke-StoragePendingRead $model GroupSite
                return @{ id = $(if ($model.Fault -eq 'GroupSite') { 'example.sharepoint.com,foreign,web' } else { 'example.sharepoint.com,site,web' }); displayName = $g.displayName; webUrl = $(if ($model.Fault -in @('NoLinks', 'InitialLinks')) { $null } else { 'https://example.sharepoint.com/sites/actual' }) }
            }
            $result = Copy-StorageValue $g
            if ($model.Fault -eq 'GroupProfile') { $result.visibility = 'Public' }
            return $result
        }
        if ($Path -match '^/sites/[^/]+/drive/list$') {
            Invoke-StoragePendingRead $model DefaultList
            return Copy-StorageValue $model.Lists['eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee']
        }
        if ($Path -match '^/sites/[^/]+/drive$') {
            Invoke-StoragePendingRead $model DefaultDrive
            return Copy-StorageValue $model.Drives['default-drive']
        }
        if ($Path -match '^/sites/([^/]+)/lists(.*)$') {
            $site = $Matches[1]; $tail = $Matches[2]
            if ($tail -eq '' -and $Method -eq 'POST') {
                $model.Counter++; $id = [guid]::NewGuid().ToString()
                $l = Copy-StorageValue $Body; $l.id = $id; $l.eTag = "$id-v1"; $l.webUrl = "https://example.sharepoint.com/sites/actual/Lists/$id"
                $l.columns = @($Body['columns'] | ForEach-Object { $col = Copy-StorageValue $_; $col.id = [guid]::NewGuid().ToString(); $col })
                $model.Lists[$id] = $l
                if ($Body.list.template -eq 'documentLibrary') {
                    $driveId = "drive-$id"; $rootId = "$driveId-root"
                    $model.Drives[$driveId] = @{ id = $driveId; root = $rootId; list = @{ id = $id }; sharePointIds = @{ siteId = $site } }
                    $model.Items[$rootId] = @{ id = $rootId; name = 'root'; folder = @{}; eTag = 'root-v1'; parentReference = @{ driveId = $driveId }; webUrl = "$($l.webUrl)/Forms/AllItems.aspx" }
                    $l.DriveId = $driveId
                }
                return @{ id = $id }
            }
            if (($tail -eq '' -or $tail.StartsWith('?')) -and $Method -eq 'GET') { return @{ value = @($model.Lists.Values) } }
            if ($tail -match '^/([^/?]+)(.*)$') {
                $id = $Matches[1]; $rest = $Matches[2]
                if (-not $model.Lists.ContainsKey($id)) { throw (New-GraphStubError 404) }
                $l = $model.Lists[$id]
                if ($rest -eq '/drive') {
                    Invoke-StoragePendingRead $model LibraryDrive
                    return Copy-StorageValue $model.Drives[$l.DriveId]
                }
                if ($rest -eq '/columns') {
                    $cols = @(Copy-StorageValue @{ columns = $l.columns }).columns
                    if ($model.Fault -eq 'Schema') { $cols[0].text = $null }
                    if ($model.Fault -eq 'ExtraSchema') { $cols += @{ id = [guid]::NewGuid().ToString(); name = 'foreign'; displayName = 'Foreign'; hidden = $true; text = @{} } }
                    return @{ value = @($cols) }
                }
                if ($rest -eq '/items' -and $Method -eq 'POST') {
                    $model.Counter++; $itemId = "$($model.Counter)"
                    $item = @{ id = $itemId; eTag = "item-$itemId-v1"; fields = (Copy-StorageValue $Body.fields); ListId = $id }
                    $model.Items["li-$itemId"] = $item
                    return @{ id = $itemId }
                }
                if ($rest -eq '/items' -and $Method -eq 'GET') { return @{ value = @($model.Items.Values | Where-Object { $_.ContainsKey('ListId') -and $_.ListId -eq $id }) } }
                if ($rest -match '^/items/([^?]+)') {
                    $item = Copy-StorageValue $model.Items["li-$($Matches[1])"]
                    if ($model.Fault -eq 'Fields') { $key = @($item.fields.Keys)[0]; $item.fields[$key] = 'changed' }
                    if ($model.Fault -eq 'ItemEtag') { $item.eTag = 'changed' }
                    if ($model.Fault -eq 'ItemId') { $item.id = 'foreign' }
                    return $item
                }
                Invoke-StoragePendingRead $model $(if ($l.list.template -ceq 'documentLibrary') { 'LibraryList' } else { 'ListRead' })
                $result = Copy-StorageValue $l
                if ($model.Fault -eq 'Schema' -and $result.list.template -eq 'genericList') { $result.columns[0].text = $null }
                if ($model.Fault -eq 'NoLinks') { $result.webUrl = $null }
                if ($model.Fault -eq 'InitialLinks' -and $rest.Contains('expand')) { $result.webUrl = $null }
                return $result
            }
        }
        if ($Path -match '^/sites/([^/?]+)' -and $Method -eq 'GET') {
            return @{ id = $Matches[1]; displayName = 'Training'; webUrl = $(if ($model.Fault -eq 'NoLinks') { $null } else { 'https://example.sharepoint.com/sites/actual' }) }
        }
        if ($Path -match '^/drives/([^/]+)(.*)$') {
            $drive = $Matches[1]; $tail = $Matches[2]
            if ($tail -eq '/root') {
                if ($drive -ne 'od') { Invoke-StoragePendingRead $model $(if ($drive -ceq 'default-drive') { 'DefaultRoot' } else { 'LibraryRoot' }) }
                return Copy-StorageValue $model.Items[$model.Drives[$drive].root]
            }
            if ($tail -eq '') { return Copy-StorageValue $model.Drives[$drive] }
            if ($tail -match '^/(root|items/([^/:?]+))/children$') {
                $parent = if ($Matches[1] -eq 'root') { $model.Drives[$drive].root } else { $Matches[2] }
                if ($Method -eq 'GET') {
                    return @{ value = @($model.Items.Values | Where-Object { $_.ContainsKey('parentReference') -and $_.parentReference.ContainsKey('id') -and $_.parentReference.id -eq $parent }) }
                }
                if ($Body['@microsoft.graph.conflictBehavior'] -ne 'fail') { throw 'Folder must fail on conflict.' }
                $model.Counter++; $id = "folder-$($model.Counter)"
                $item = @{ id = $id; name = $Body.name; folder = @{}; eTag = "$id-v1"; parentReference = @{ id = $parent; driveId = $drive }; webUrl = "https://example.sharepoint.com/files/$id" }
                $model.Items[$id] = $item; return @{ id = $id }
            }
            if ($tail -match '^/items/([^/:]+):/([^/]+):/content\?@microsoft\.graph\.conflictBehavior=fail$' -and $Method -ceq 'PUT') {
                $parent = $Matches[1]; $name = [uri]::UnescapeDataString($Matches[2])
                if ($RawBody -isnot [byte[]]) { throw 'Simple upload must send a real byte array.' }
                if ($model.Fault -ceq 'UnknownUpload') { throw (New-GraphStubError 503) }
                if ($model.Fault -ceq 'UploadCollision' -or @($model.Items.Values | Where-Object { $_.ContainsKey('parentReference') -and $_.parentReference.ContainsKey('id') -and $_.parentReference.id -ceq $parent -and $_.name -ceq $name }).Count -gt 0) { throw (New-GraphStubError 409) }
                return & $createFile $drive $parent $name $RawBody
            }
            if ($tail -match '^/items/([^/:]+):/([^/]+):/createUploadSession$' -and $Method -eq 'POST') {
                if ($Body.item['@microsoft.graph.conflictBehavior'] -ne 'fail') { throw 'Upload must fail on conflict.' }
                $parent = $Matches[1]; $name = [uri]::UnescapeDataString($Matches[2])
                if ($model.Fault -eq 'UploadCollision') { throw (New-GraphStubError 409) }
                $key = [guid]::NewGuid().ToString('N')
                $model.Uploads[$key] = @{ Parent = $parent; Name = $name; Drive = $drive }
                return @{ uploadUrl = "https://example.sharepoint.com/upload?sig=$key"; expirationDateTime = [DateTimeOffset]::UtcNow.AddHours(1).ToString('o'); nextExpectedRanges = @('0-') }
            }
            if ($tail -match '^/items/([^/?]+)') {
                $id = $Matches[1]
                if (-not $model.Items.ContainsKey($id)) { throw (New-GraphStubError 404) }
                if ($tail.EndsWith('/permissions')) {
                    if ($drive -ne 'od') {
                        if ($model.Fault -cin @('PermissionMetadata', 'PermissionPrincipal', 'PermissionRole', 'PermissionMalformed', 'PermissionAliasMismatch', 'PermissionDuplicate', 'PermissionExpiry', 'PermissionNoExpiry', 'PermissionLegacyOnly', 'PermissionPlural', 'PermissionPluralLink', 'PermissionMissingId', 'PermissionInheritance')) {
                            if (-not $model.ContainsKey('PermissionReads')) { $model.PermissionReads = 0 }
                            $model.PermissionReads++
                            $principal = $(if ($model.Fault -ceq 'PermissionPrincipal') { '4' } elseif ($model.Fault -ceq 'PermissionMalformed') { $null } else { '3' })
                            $permission = @{
                                id = "provider-alias-$($model.PermissionReads)"
                                roles = @($(if ($model.Fault -ceq 'PermissionRole') { 'read' } else { 'owner' }))
                                grantedTo = @{ user = @{ id="legacy-$($model.PermissionReads)"; displayName="Legacy $($model.PermissionReads)" } }
                                grantedToV2 = @{
                                    siteGroup = @{ id=$principal; displayName="Group $($model.PermissionReads)"; loginName="Group $($model.PermissionReads)" }
                                    sharePointGroup = @{ id="provider-group-$($model.PermissionReads)"; principalId=$(if($model.Fault -ceq 'PermissionAliasMismatch'){'9'}else{$principal}); title="Group $($model.PermissionReads)" }
                                }
                            }
                            if ($model.Fault -ceq 'PermissionExpiry') { $permission.expirationDateTime = '2030-01-01T00:00:00Z' }
                            if ($model.Fault -ceq 'PermissionNoExpiry') { $permission.expirationDateTime = '0001-01-01T00:00:00Z' }
                            if ($model.Fault -ceq 'PermissionInheritance') { $permission.inheritedFrom = @{ driveId='sp'; id='different-parent' } }
                            if ($model.Fault -cin @('PermissionPlural','PermissionPluralLink')) { $permission.grantedToIdentitiesV2 = @($permission.grantedToV2); $permission.Remove('grantedToV2') }
                            if ($model.Fault -ceq 'PermissionPluralLink') { $permission.link=@{scope='existingAccess'}; $permission.roles=@('read') }
                            if ($model.Fault -ceq 'PermissionLegacyOnly') { $permission.Remove('grantedToV2') }
                            if ($model.Fault -ceq 'PermissionMissingId') { $permission.Remove('id') }
                            if ($model.Fault -ceq 'PermissionDuplicate') { return @{ value=@($permission,$permission.Clone()) } }
                            return @{ value=@($permission) }
                        }
                        if ($model.Fault -in @('ExistingAccess', 'OrganizationLink', 'ExistingAccessInvite')) {
                            $permission = @{ id = 'copy-link'; roles = @('read'); grantedToIdentities = @(); grantedToIdentitiesV2 = @(); link = @{ type = 'unknown'; scope = $(if ($model.Fault -ceq 'OrganizationLink') { 'organization' } else { 'existingAccess' }); webUrl = 'https://example.sharepoint.com/private?sig=never-store-this' } }
                            if ($model.Fault -ceq 'ExistingAccessInvite') { $permission.invitation = @{ email = 'foreign@example.invalid' } }
                            return @{ value = @($permission) }
                        }
                        if ($model.Fault -eq 'UniqueSharing') { return @{ value = @(@{ id = 'unique'; roles = @('read'); invitation = @{ email = 'foreign@example.invalid' } }) } }
                        if ($model.Fault -eq 'SharingDrift') { return @{ value = @(@{ id = 'changed'; roles = @('read'); grantedToV2 = @{ user = @{ id = $alice } } }) } }
                        return @{ value = @() }
                    }
                    return @{ value = @($(if ($model.Fault -ne 'DriveACL') { @{ roles = @('owner'); grantedToV2 = @{ user = @{ id = $presenter } } } })) }
                }
                if ($tail.EndsWith('/content')) { return ,([byte[]]$model.Items[$id].Bytes) }
                $item = Copy-StorageValue $model.Items[$id]; $item.Remove('Bytes')
                if ($model.Fault -ceq 'OfficeViewer' -and $item.ContainsKey('file')) {
                    $digest = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($id))
                    $documentId = [guid]::new([byte[]]$digest[0..15]).ToString()
                    $item.sharepointIds = @{ listItemUniqueId = $documentId }
                    $item.webUrl = 'https://example.sharepoint.com/_layouts/15/Doc.aspx?sourcedoc=%7B' + $documentId + '%7D&file=' + [uri]::EscapeDataString($item.name) + '&action=default&mobileredirect=true'
                }
                if ($model.Fault -eq 'Etag') { $item.eTag = 'changed' }
                if ($model.Fault -eq 'Content' -and $item.ContainsKey('file')) { $item.file.hashes.sha256Hash = '0' * 64 }
                if ($model.Fault -eq 'Bytes' -and $item.ContainsKey('file')) { $item.file.hashes.Remove('sha256Hash') }
                return $item
            }
        }
        throw "Unrouted storage request $Method $Path"
    }.GetNewClosure()
    $upload = {
        param($Url, $Bytes, $Headers)
        if ($null -eq $Bytes) {
            $model.Ledger.Add(@{ Method = 'GET'; Path = '[private upload status]'; Body = $null })
            if ($model.Fault -eq 'SessionStatus') { throw (New-GraphStubError 403) }
            return @{ expirationDateTime = [DateTimeOffset]::UtcNow.AddHours(1).ToString('o'); nextExpectedRanges = @('0-') }
        }
        $model.Ledger.Add(@{ Method = 'PUT'; Path = '[private upload continuation]'; Body = $null })
        $j = Get-Content $model.StatePath -Raw | ConvertFrom-Json -AsHashtable
        if ($j.events[-1].action -ne 'Submit' -or $Headers['Content-Range'] -ne "bytes 0-$($Bytes.Length-1)/$($Bytes.Length)") { throw 'Unjournaled or malformed upload.' }
        if ($model.Fault -eq 'UnknownUpload') { throw (New-GraphStubError 503) }
        $u = $model.Uploads[($Url -split '=')[-1]]
        return & $createFile $u.Drive $u.Parent $u.Name $Bytes
    }.GetNewClosure()
    $claims = @{ tid = $c.tenantId; appid = $c.clientId; aud = 'https://graph.microsoft.com'; iss = "https://sts.windows.net/$($c.tenantId)/"; exp = [DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds(); roles = @('User.Read.All', 'Files.ReadWrite.All', 'Sites.ReadWrite.All', 'Group.ReadWrite.All') }
    $encode = { param($v) [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($v | ConvertTo-Json -Compress))).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
    $jwt = "$(& $encode @{ alg = 'RS256' }).$(& $encode $claims).offline"
    $delay = {
        param($Seconds)
        $model.Delays.Add($Seconds)
        if ($model.FaultOnDelay) { $model.Fault = $model.FaultOnDelay }
    }.GetNewClosure()
    $session = Connect-SeedSession -Config $c -Mode Import -TokenProvider { $jwt }.GetNewClosure() -Transport $transport -Delay $delay
    $record = Get-SeedSessionRecord $session
    $record.Identity = $identity; $record.ServiceGate = @{ Workloads = @('onedrive', 'sharepoint'); ActorFingerprint = $identity.ActorFingerprint }
    # This fixture injects already validated T2 provenance, not a production bypass.
    $record.UploadTransport = $upload
    return @{ Session = $session; Model = $model; Scenario = $s; Context = $ctx; PreparedPath = (Join-Path $dir 'prepared'); Config = $c; StatePath = $model.StatePath }
}
function Get-StorageTestAdapter($e) {
    Get-SeedStorageAdapter -Session $e.Session -Scenario $e.Scenario -PreparedPath $e.PreparedPath -Context $e.Context -RunId training01 -StatePath $e.StatePath -UseUploadSessions
}
function Start-StorageTestRun($e, $a) {
    $plan = @(Get-SeedOperationPlan -Session $e.Session -Operations $a.Operations -ResourceChecks $a.ResourceChecks)
    Assert-Equal @($plan | Where-Object Action -eq Block).Count 0
    New-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $a.Operations | Out-Null
    New-SeedWriteApproval -Session $e.Session -Plan $plan -Requests $a.Requests -ConfirmTarget "$($e.Config.tenantId)/training01" -StatePath $e.StatePath -RunId training01 -Context $e.Context | Out-Null
    Invoke-UploadFiles -Session $e.Session -Adapter $a -Plan $plan
}
function Use-StorageNativeJsonTransports($e) {
    # Invoke-RestMethod returns every JSON object as PSCustomObject, so both Graph and upload responses of the dictionary model are converted.
    $record = Get-SeedSessionRecord $e.Session
    $graph = $record.Transport; $upload = $record.UploadTransport; $model = $e.Model
    $native = @{ Graph = 0; GraphPost = 0; Upload = 0; UploadPut = 0 }
    $record.Transport = {
        param($Method, $Path, $Body, $RawBody)
        $value = & $graph $Method $Path $Body $RawBody
        if ($value -is [byte[]]) { return ,$value }
        if ($value -isnot [Collections.IDictionary]) { return $value }
        $native.Graph++
        if ($Method -ceq 'POST') { $native.GraphPost++ }
        return $value | ConvertTo-Json -Depth 100 -Compress | ConvertFrom-Json -Depth 100
    }.GetNewClosure()
    $record.UploadTransport = {
        param($Url, $Bytes, $Headers)
        $value = & $upload $Url $Bytes $Headers
        if ($value -isnot [Collections.IDictionary]) { return $value }
        $native.Upload++
        if ($null -ne $Bytes) {
            $native.UploadPut++
            if ($model.Fault -ceq 'UploadResponseTooDeep') {
                $deep = [pscustomobject]@{ leaf = 1 }
                for ($level = 0; $level -lt 150; $level++) { $deep = [pscustomobject]@{ child = $deep } }
                return $deep
            }
        }
        return $value | ConvertTo-Json -Depth 100 -Compress | ConvertFrom-Json -Depth 100
    }.GetNewClosure()
    return $native
}
try {
    Test-Case 'Storage provisioning polls Group site default drive List and root readiness then reruns with zero writes' {
        $e = New-StorageEnvironment
        foreach ($stage in @('GroupSite', 'DefaultDrive', 'DefaultList', 'DefaultRoot')) {
            $e.Model.PendingReads[$stage] = @{ Remaining = $(if ($stage -ceq 'GroupSite') { 2 } else { 1 }); Status = 404; Attempts = 0 }
        }
        $a = Get-StorageTestAdapter $e
        $result = Start-StorageTestRun $e $a
        Assert-True $result.Verified
        Assert-Equal @($e.Model.Delays.ToArray()) @(5, 5, 5, 5, 5)
        foreach ($pending in $e.Model.PendingReads.Values) { Assert-Equal $pending.Remaining 0 }
        Assert-Equal @($e.Model.Ledger | Where-Object { $_.Method -ceq 'POST' -and $_.Path -ceq '/groups' }).Count 1
        $hash = (Get-FileHash $e.StatePath).Hash
        $fresh = Get-StorageTestAdapter $e
        $state = Get-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $fresh.Operations -ForImport
        Assert-Equal $state.status Completed
        Set-SeedStorageRunState -Session $e.Session -Adapter $fresh -RunState $state
        $before = @($e.Model.Ledger | Where-Object Method -ne GET).Count
        $plan = @(Get-SeedOperationPlan -Session $e.Session -Operations $fresh.Operations -ResourceChecks $fresh.ResourceChecks -RunState $state)
        Assert-Equal @($plan | Where-Object Action -ne Skip).Count 0
        Assert-True (Invoke-UploadFiles -Session $e.Session -Adapter $fresh -Plan $plan).Verified
        Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count $before
        Assert-Equal $e.Model.Delays.Count 5
        Assert-Equal (Get-FileHash $e.StatePath).Hash $hash
    }
    Test-Case 'Storage provisioning polls delayed library drive root and exact List readback without duplicate creates' {
        $e = New-StorageEnvironment
        foreach ($stage in @('LibraryList', 'LibraryDrive', 'LibraryRoot', 'ListRead')) {
            $e.Model.PendingReads[$stage] = @{ Remaining = $(if ($stage -cin @('LibraryDrive', 'ListRead')) { 2 } else { 1 }); Status = 404; Attempts = 0 }
        }
        $a = Get-StorageTestAdapter $e
        Assert-True (Start-StorageTestRun $e $a).Verified
        Assert-Equal @($e.Model.Delays.ToArray()) @(5, 5, 5, 5, 5, 5)
        foreach ($pending in $e.Model.PendingReads.Values) { Assert-Equal $pending.Remaining 0 }
        Assert-Equal @($e.Model.Ledger | Where-Object { $_.Method -ceq 'POST' -and $_.Path -ceq '/groups' }).Count 1
        Assert-Equal @($e.Model.Ledger | Where-Object { $_.Method -ceq 'POST' -and $_.Path -match '^/sites/[^/]+/lists$' }).Count 2
        Assert-Equal (Get-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $a.Operations).status Completed
    }
    Test-Case 'Storage provisioning exhaustion is bounded to 180 seconds and retains Unknown actual IDs without resume' {
        foreach ($stage in @('GroupSite', 'LibraryDrive', 'ListRead')) {
            $e = New-StorageEnvironment
            $e.Model.PendingReads[$stage] = @{ Remaining = 100; Status = 404; Attempts = 0 }
            $a = Get-StorageTestAdapter $e
            Assert-Throws { Start-StorageTestRun $e $a } 'Seed.Storage.Stopped' | Out-Null
            Assert-Equal $e.Model.PendingReads[$stage].Attempts 37
            Assert-Equal $e.Model.Delays.Count 36
            Assert-True (($e.Model.Delays | Measure-Object -Sum).Sum -eq 180) 'Provisioning delay budget must total 180 seconds.'
            Assert-Equal @($e.Model.Delays | Where-Object { $_ -ne 5 }).Count 0
            $state = Get-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $a.Operations
            Assert-Equal $state.status Blocked
            $unknown = @($state.results | Where-Object status -ceq Unknown)
            Assert-Equal $unknown.Count 1
            $kind = switch ($stage) { GroupSite { 'Group' } LibraryDrive { 'Library' } ListRead { 'List' } }
            $operation = @($a.Operations | Where-Object { $_.StorageScope.Kind -ceq $kind })[0]
            Assert-Equal $unknown[0].id $operation.OperationId
            $storage = Get-SeedStorageRecord $e.Session $a
            $failure = @($state.events | Where-Object { $_.id -ceq $operation.OperationId -and $_.action -ceq 'Fail' -and $_.status -ceq 'Unknown' })[0]
            Assert-Equal $failure.objectId $storage.Ids[$operation.OperationId]
            Assert-True (-not [string]::IsNullOrWhiteSpace($failure.objectId))
            Assert-Equal @($e.Model.Ledger | Where-Object { $_.Method -ceq 'POST' -and $_.Path -ceq '/groups' }).Count 1
            Assert-Equal @($e.Model.Ledger | Where-Object { $_.Method -ceq 'POST' -and $_.Path -match '^/sites/[^/]+/lists$' }).Count $(switch ($stage) { GroupSite { 0 } LibraryDrive { 1 } ListRead { 2 } })
            $before = @($e.Model.Ledger | Where-Object Method -ne GET).Count
            $hash = (Get-FileHash $e.StatePath).Hash
            Assert-Throws { Get-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $a.Operations -ForImport } 'Seed.State.Blocked' | Out-Null
            Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count $before
            Assert-Equal (Get-FileHash $e.StatePath).Hash $hash
        }
    }
    Test-Case 'Storage provisioning 403 stops immediately without delay or a second read or create' {
        foreach ($stage in @('GroupSite', 'LibraryDrive', 'ListRead')) {
            $e = New-StorageEnvironment
            $e.Model.PendingReads[$stage] = @{ Remaining = 100; Status = 403; Attempts = 0 }
            $a = Get-StorageTestAdapter $e
            Assert-Throws { Start-StorageTestRun $e $a } 'Seed.Storage.Stopped' | Out-Null
            Assert-Equal $e.Model.PendingReads[$stage].Attempts 1
            Assert-Equal $e.Model.Delays.Count 0
            $state = Get-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $a.Operations
            Assert-Equal $state.status Blocked
            Assert-Equal @($state.results | Where-Object status -ceq Unknown).Count 1
            Assert-Equal @($e.Model.Ledger | Where-Object { $_.Method -ceq 'POST' -and $_.Path -ceq '/groups' }).Count 1
            Assert-Equal @($e.Model.Ledger | Where-Object { $_.Method -ceq 'POST' -and $_.Path -match '^/sites/[^/]+/lists$' }).Count $(switch ($stage) { GroupSite { 0 } LibraryDrive { 1 } ListRead { 2 } })
        }
    }
    Test-Case 'Storage provisioning rechecks actual owners profile sharing and schema after 404 instead of retrying mismatches' {
        foreach ($fault in @('ACL', 'GroupProfile', 'UniqueSharing', 'Schema')) {
            $e = New-StorageEnvironment
            $stage = if ($fault -ceq 'Schema') { 'ListRead' } else { 'GroupSite' }
            $e.Model.PendingReads[$stage] = @{ Remaining = 1; Status = 404; Attempts = 0 }
            $e.Model.FaultOnDelay = $fault
            $a = Get-StorageTestAdapter $e
            Assert-Throws { Start-StorageTestRun $e $a } 'Seed.Storage.Stopped' | Out-Null
            Assert-Equal @($e.Model.Delays.ToArray()) @(5)
            Assert-Equal $e.Model.Fault $fault
            $state = Get-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $a.Operations
            Assert-Equal $state.status Blocked
            Assert-Equal @($state.results | Where-Object status -ceq Unknown).Count 1
            Assert-Equal @($e.Model.Ledger | Where-Object { $_.Method -ceq 'POST' -and $_.Path -ceq '/groups' }).Count 1
            Assert-Equal @($e.Model.Ledger | Where-Object { $_.Method -ceq 'POST' -and $_.Path -match '^/sites/[^/]+/lists$' }).Count $(if ($fault -ceq 'Schema') { 2 } else { 0 })
        }
    }
    Test-Case 'Storage Graph-only SharePoint create verifies structural inheritance without an extra authentication backend' {
        $e = New-StorageEnvironment; $a = Get-StorageTestAdapter $e
        $plan = @(Get-SeedOperationPlan -Session $e.Session -Operations $a.Operations -ResourceChecks $a.ResourceChecks)
        Assert-Equal @($plan | Where-Object Action -eq Block).Count 0
        Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count 0
        $result = Start-StorageTestRun $e $a
        Assert-Equal $result.PresenterProof.Kind GraphStructural
        Assert-Equal $result.PresenterProof.ActualUiStatus Required
        Assert-Equal $result.PresenterProof.RemoteAclStatus NotProven
        foreach ($link in $result.ResourceLinkIndex) { Assert-Equal $link.presenterAccessStatus StructuralVerified }
        Assert-True (($result | ConvertTo-Json -Depth 50) -notmatch 'ActualUiStatus":"Passed')
        Assert-Equal @($e.Model.Ledger | Where-Object { $_.Path -match '/_api/|/sites/[^/]+/permissions' }).Count 0
        # A fresh adapter must recover the recorded creation proof, not an in-memory success flag.
        $fresh = Get-StorageTestAdapter $e
        $state = Get-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $fresh.Operations -ForImport
        Set-SeedStorageRunState -Session $e.Session -Adapter $fresh -RunState $state
        $before = @($e.Model.Ledger | Where-Object Method -ne GET).Count
        $rerun = @(Get-SeedOperationPlan -Session $e.Session -Operations $fresh.Operations -ResourceChecks $fresh.ResourceChecks -RunState $state)
        Assert-Equal @($rerun | Where-Object Action -ne Skip).Count 0
        $verified = Invoke-UploadFiles -Session $e.Session -Adapter $fresh -Plan $rerun
        Assert-True $verified.Verified
        Assert-Equal $verified.PresenterProof $result.PresenterProof
        Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count $before
    }
    Test-Case 'Storage Graph-only SharePoint rejects missing Presenter altered group association and observable sharing drift' {
        $e = New-StorageEnvironment; $a = Get-StorageTestAdapter $e
        Start-StorageTestRun $e $a | Out-Null
        $state = Get-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $a.Operations
        Set-SeedStorageRunState -Session $e.Session -Adapter $a -RunState $state
        $before = @($e.Model.Ledger | Where-Object Method -ne GET).Count
        foreach ($fault in @('ACL', 'MemberACL', 'GroupProfile', 'GroupSite', 'UniqueSharing', 'SharingDrift')) {
            $e.Model.Fault = $fault
            $p = @(Get-SeedOperationPlan -Session $e.Session -Operations $a.Operations -ResourceChecks $a.ResourceChecks -RunState $state)
            Assert-True (@($p | Where-Object Action -eq Block).Count -gt 0) "Missing structural block: $fault"
            Assert-Throws { Test-SeedStorage -Session $e.Session -Adapter $a } 'Seed.Storage.Verify' | Out-Null
        }
        Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count $before
    }
    Test-Case 'Storage Graph-only SharePoint requires recorded creation not just known IDs or matching names' {
        $e = New-StorageEnvironment; $a = Get-StorageTestAdapter $e
        Start-StorageTestRun $e $a | Out-Null
        $storage = Get-SeedStorageRecord $e.Session $a
        $group = @($a.Operations | Where-Object { $_.StorageScope.Kind -ceq 'Group' })[0]
        $storage.RunState = $null; $storage.CreationProofs.Clear()
        $before = @($e.Model.Ledger | Where-Object Method -ne GET).Count
        Assert-Throws { Get-SeedStorageSnapshot $e.Session $storage $group } 'Seed.Storage.Inheritance' | Out-Null
        Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count $before
    }
    Test-Case 'Storage Graph-only SharePoint rejects receipts with missing or altered inheritance read-back evidence' {
        $e = New-StorageEnvironment; $a = Get-StorageTestAdapter $e
        Start-StorageTestRun $e $a | Out-Null
        $storage = Get-SeedStorageRecord $e.Session $a
        $group = @($a.Operations | Where-Object { $_.StorageScope.Kind -ceq 'Group' })[0]
        $original = Get-Content $e.StatePath -Raw
        $before = @($e.Model.Ledger | Where-Object Method -ne GET).Count
        foreach ($fault in @('Missing', 'Changed')) {
            $snapshot = Copy-StorageValue $storage.Evidence[$group.OperationId]
            if ($fault -ceq 'Missing') { $snapshot.access.Remove('inheritance') }
            else { $snapshot.access.inheritance.model = 'UnknownOrUniquePermissions' }
            $digest = Get-SeedFingerprint $snapshot
            $journal = $original | ConvertFrom-Json -AsHashtable
            @($journal.results | Where-Object id -CEQ $group.OperationId)[0].evidence.sha256 = $digest
            @($journal.events | Where-Object { $_.id -ceq $group.OperationId -and $_.action -ceq 'ReadBack' })[0].objectId = "readback-sha256:$digest"
            $journal | ConvertTo-Json -Depth 100 | Set-Content $e.StatePath -Encoding utf8
            $state = Get-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $a.Operations
            Set-SeedStorageRunState -Session $e.Session -Adapter $a -RunState $state
            $p = @(Get-SeedOperationPlan -Session $e.Session -Operations $a.Operations -ResourceChecks $a.ResourceChecks -RunState $state)
            Assert-True (@($p | Where-Object Action -eq Block).Count -gt 0) "Missing inheritance block: $fault"
            Assert-Throws { Test-SeedStorage -Session $e.Session -Adapter $a } 'Seed.Storage.Verify' | Out-Null
        }
        Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count $before
    }
    Test-Case 'Storage SharePoint accepts server ColorTag and IsRecord fields but rejects undeclared custom columns' {
        $e = New-StorageEnvironment; $a = Get-StorageTestAdapter $e
        Start-StorageTestRun $e $a | Out-Null
        $storage = Get-SeedStorageRecord $e.Session $a
        $list = @($a.Operations | Where-Object { $_.StorageScope.Kind -ceq 'List' })[0]
        $id = $storage.Ids[$list.OperationId]
        $e.Model.Lists[$id].columns += @(
            @{ id = [guid]::NewGuid().ToString(); name = '_ColorTag'; displayName = 'Color Tag'; readOnly = $true; text = @{ allowMultipleLines = $false } },
            @{ id = [guid]::NewGuid().ToString(); name = '_IsRecord'; displayName = 'Item is a Record'; readOnly = $true }
        )
        $before = @($e.Model.Ledger | Where-Object Method -ne GET).Count
        $snapshot = Get-SeedStorageSnapshot $e.Session $storage $list
        Assert-Equal $snapshot.columns.Count $list.StorageScope.Body.columns.Count
        $e.Model.Lists[$id].columns += @{ id = [guid]::NewGuid().ToString(); name = 'UnexpectedBusinessField'; displayName = 'Extra'; text = @{} }
        Assert-Throws { Get-SeedStorageSnapshot $e.Session $storage $list } 'Seed.Storage.Schema' | Out-Null
        Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count $before
    }
    Test-Case 'Storage Graph-only SharePoint rechecks actual group membership before a List child request' {
        $e = New-StorageEnvironment; $a = Get-StorageTestAdapter $e
        Start-StorageTestRun $e $a | Out-Null
        $storage = Get-SeedStorageRecord $e.Session $a
        $list = @($a.Operations | Where-Object { $_.StorageScope.Kind -ceq 'List' })[0]
        $e.Model.Fault = 'MemberACL'
        Assert-Throws { Get-SeedStorageSnapshot $e.Session $storage $list } 'Seed.Storage.ACL' | Out-Null
    }
    Test-Case 'Storage binary content follows only bounded SharePoint redirects without forwarding Graph authorization' {
        Assert-True ([bool](Get-Command Read-SeedGraphContent -ErrorAction SilentlyContinue)) 'Binary content reader is not implemented.'
        $calls = [Collections.Generic.List[object]]::new()
        $send = {
            param($Uri, $UseGraphAuthorization)
            $calls.Add(@{ Auth = $UseGraphAuthorization; Host = $Uri.Host })
            if ($UseGraphAuthorization) {
                $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::Found)
                $response.Headers.Location = [uri]'https://example.sharepoint.com/private-content?sig=never-return-this'
            } else {
                $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::OK)
                $response.Content = [Net.Http.ByteArrayContent]::new([byte[]]@(1, 2, 255))
            }
            return $response
        }.GetNewClosure()
        $bytes = Read-SeedGraphContent -Path '/drives/drive/items/file/content' -Send $send
        Assert-True ($bytes -is [byte[]]); Assert-Equal $bytes ([byte[]]@(1, 2, 255))
        Assert-Equal @($calls.Auth) @($true, $false)
        $foreign = {
            param($Uri, $UseGraphAuthorization)
            $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::Found)
            $response.Headers.Location = [uri]'https://foreign.invalid/private?sig=hidden'
            return $response
        }
        Assert-Throws { Read-SeedGraphContent -Path '/drives/drive/items/file/content' -Send $foreign } 'Seed.Content' | Out-Null
        $oversized = {
            param($Uri, $UseGraphAuthorization)
            $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::OK)
            $response.Content = [Net.Http.ByteArrayContent]::new([byte[]]@(1))
            $response.Content.Headers.ContentLength = 33554433
            return $response
        }
        Assert-Throws { Read-SeedGraphContent -Path '/drives/drive/items/file/content' -Send $oversized } 'Seed.Content' | Out-Null
    }
    Test-Case 'Storage complete create then exact full rerun and readonly Verify issue zero writes' {
        Assert-True ([bool](Get-Command Get-SeedStorageAdapter -ErrorAction SilentlyContinue)) 'T3 Storage adapter is not implemented.'
        $e = New-StorageEnvironment; $e.Model.Fault = 'PagedMembers'; $a = Get-StorageTestAdapter $e
        $result = Start-StorageTestRun $e $a
        Assert-Equal $result.AssetUrlMap.Count 2
        Assert-Equal @($result.ResourceLinkIndex).Count 4
        Assert-Equal @($result.ResourceLinkIndex.kind | Sort-Object) @('documentLibrary', 'documentLibrary', 'list', 'site')
        foreach ($asset in $result.AssetUrlMap.Values) { Assert-True $asset.presenterVerified; Assert-True ($asset.webUrl -match '^https://'); Assert-True ($asset.sourceSha256 -match '^[a-f0-9]{64}$') }
        Assert-True (($result | ConvertTo-Json -Depth 50) -notmatch 'sig=|uploadUrl|downloadUrl')
        $state = Get-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $a.Operations -ForImport
        Assert-Equal $state.status Completed
        $before = @($e.Model.Ledger | Where-Object Method -ne GET).Count
        Set-SeedStorageRunState -Session $e.Session -Adapter $a -RunState $state
        $plan = @(Get-SeedOperationPlan -Session $e.Session -Operations $a.Operations -ResourceChecks $a.ResourceChecks -RunState $state)
        Assert-Equal @($plan | Where-Object Action -ne Skip).Count 0
        $again = Invoke-UploadFiles -Session $e.Session -Adapter $a -Plan $plan
        Assert-Equal $again.AssetUrlMap $result.AssetUrlMap
        $verified = Test-SeedStorage -Session $e.Session -Adapter $a
        Assert-True $verified.Verified
        Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count $before
    }
    Test-Case 'Storage preflight blocks wrong Presenter drive ownership and foreign pagination without writes' {
        foreach ($fault in @('DriveOwner', 'Pagination', 'Profile')) {
            $e = New-StorageEnvironment; $e.Model.Fault = $fault; $a = Get-StorageTestAdapter $e
            $p = @(Get-SeedOperationPlan -Session $e.Session -Operations $a.Operations -ResourceChecks $a.ResourceChecks)
            Assert-True (@($p | Where-Object Action -eq Block).Count -gt 0)
            Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count 0
        }
    }
    Test-Case 'Storage refuses arbitrary owned group or namespaced folder collision without receipt' {
        foreach ($kind in @('Group', 'Folder')) {
            $e = New-StorageEnvironment; $a = Get-StorageTestAdapter $e
            if ($kind -eq 'Group') {
                $request = @($a.Requests | Where-Object Path -eq '/groups')[0]
                $g = Copy-StorageValue $request.Body; $g.id = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'; $e.Model.Groups[$g.id] = $g
            } else {
                $request = @($a.Requests | Where-Object Path -like '/drives/*')[0]
                $e.Model.Items.collision = @{ id = 'collision'; name = $request.Body.name; folder = @{}; parentReference = @{ id = 'od-root'; driveId = 'od' } }
            }
            $p = @(Get-SeedOperationPlan -Session $e.Session -Operations $a.Operations -ResourceChecks $a.ResourceChecks)
            Assert-True (@($p | Where-Object Action -eq Block).Count -gt 0)
            Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count 0
        }
    }
    Test-Case 'Storage names the created library Project Documents so no seed marker is visible in actual display names' {
        $e = New-StorageEnvironment; $a = Get-StorageTestAdapter $e
        $library = @($a.Operations | Where-Object { $_.StorageScope.Kind -ceq 'Library' })
        Assert-Equal $library.Count 1
        Assert-Equal $library[0].StorageScope.Body.displayName 'Project Documents'
        $result = Start-StorageTestRun $e $a
        Assert-True $result.Verified
        Assert-Equal @($e.Model.Lists.Values | Where-Object { $_.displayName -match 'Seed|Demo' }).Count 0
        Assert-Equal @($result.ResourceLinkIndex | Where-Object kind -ceq documentLibrary | ForEach-Object { $_.displayName } | Sort-Object) @('Documents', 'Project Documents')
    }
    Test-Case 'Storage refuses a site List that would reuse the library name before any remote write' {
        foreach ($name in @('Project Documents', ' project documents ')) {
            $e = New-StorageEnvironment -ListDisplayName $name
            Assert-Throws { Get-StorageTestAdapter $e } 'Seed\.Storage\.Collision' | Out-Null
            Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count 0
        }
        $e = New-StorageEnvironment -ListDisplayName 'Project Documents Archive'
        $a = Get-StorageTestAdapter $e
        $plan = @(Get-SeedOperationPlan -Session $e.Session -Operations $a.Operations -ResourceChecks $a.ResourceChecks)
        Assert-Equal @($plan | Where-Object Action -eq Block).Count 0
        Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count 0
    }
    Test-Case 'Storage rejects unsafe paths duplicate destinations non-Presenter drives and tampered prepared bytes upfront' {
        foreach ($fault in @('Traversal', 'Duplicate', 'Owner', 'Source')) {
            $e = New-StorageEnvironment
            switch ($fault) {
                Traversal { $e.Scenario.assets[0].destination.folder = '..\outside' }
                Duplicate { $e.Scenario.assets += (Copy-StorageValue $e.Scenario.assets[0]) }
                Owner { $e.Scenario.onedrive.drives[0].ownerRole = 'Lead' }
                Source { Add-Content (Join-Path $e.PreparedPath 'assets\metrics.xlsx') 'tampered' }
            }
            Assert-Throws { Get-StorageTestAdapter $e } 'Seed.Storage' | Out-Null
            Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count 0
        }
    }
    Test-Case 'Storage complete receipts never Skip changed content etag fields schema profile ACL or missing links' {
        $e = New-StorageEnvironment; $a = Get-StorageTestAdapter $e
        Start-StorageTestRun $e $a | Out-Null
        $state = Get-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $a.Operations
        Set-SeedStorageRunState -Session $e.Session -Adapter $a -RunState $state
        $before = @($e.Model.Ledger | Where-Object Method -ne GET).Count
        foreach ($fault in @('Content', 'Etag', 'Fields', 'ItemEtag', 'ItemId', 'Schema', 'ExtraSchema', 'Profile', 'ACL', 'DriveACL', 'NoLinks')) {
            $e.Model.Fault = $fault
            $p = @(Get-SeedOperationPlan -Session $e.Session -Operations $a.Operations -ResourceChecks $a.ResourceChecks -RunState $state)
            Assert-True (@($p | Where-Object Action -eq Block).Count -gt 0) "Missing block: $fault"
            Assert-Throws { Test-SeedStorage -Session $e.Session -Adapter $a } 'Seed.Storage' | Out-Null
        }
        Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count $before
    }
    Test-Case 'Storage uncertain create upload and submit-time collision preserve Unknown with no retry or repair' {
        foreach ($fault in @('UnknownCreate', 'UnknownGroup', 'UnknownUpload', 'UploadCollision')) {
            $e = New-StorageEnvironment; $a = Get-StorageTestAdapter $e; $e.Model.Fault = $fault
            Assert-Throws { Start-StorageTestRun $e $a } 'Seed.Graph|Seed.Storage' | Out-Null
            $state = Get-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $a.Operations
            Assert-Equal $state.status Blocked
            Assert-Equal @($state.results | Where-Object status -eq Unknown).Count 1
            Assert-Equal $e.Model.Delays.Count 0
            if ($fault -eq 'UnknownGroup') {
                Assert-Equal $e.Model.Groups.Count 1
                Assert-Equal @($e.Model.Ledger | Where-Object { $_.Method -ceq 'POST' -and $_.Path -ceq '/groups' }).Count 1
            }
            if ($fault -eq 'UnknownUpload') { Assert-Equal @($e.Model.Ledger | Where-Object Method -ceq PUT).Count 1 }
            $before = @($e.Model.Ledger | Where-Object Method -ne GET).Count
            Assert-Throws { Get-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $a.Operations -ForImport } 'Seed.State.Blocked' | Out-Null
            Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count $before
        }
    }
    Test-Case 'Storage exact dynamic request validator rejects unrelated parent and altered body before submit' {
        $e = New-StorageEnvironment; $a = Get-StorageTestAdapter $e
        $p = @(Get-SeedOperationPlan -Session $e.Session -Operations $a.Operations -ResourceChecks $a.ResourceChecks)
        New-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $a.Operations | Out-Null
        New-SeedWriteApproval -Session $e.Session -Plan $p -Requests $a.Requests -ConfirmTarget "$($e.Config.tenantId)/training01" -StatePath $e.StatePath -RunId training01 -Context $e.Context | Out-Null
        $child = @($a.Operations | Where-Object { $_.StorageScope.ParentOperationId })[0]
        $r = @{ OperationId = $child.OperationId; Method = 'POST'; Path = '/drives/foreign/items/foreign/children'; Body = @{ name = 'foreign'; folder = @{}; '@microsoft.graph.conflictBehavior' = 'fail' } }
        Assert-Throws { Write-SeedGraph -Session $e.Session -Request $r -RequestCheck $a.RequestCheck } 'Seed.Approval|Seed.Storage' | Out-Null
        Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count 0
    }
    Test-Case 'Storage root capability cannot authorize another directory or altered Group body' {
        foreach ($kind in @('Folder', 'Group')) {
            $e = New-StorageEnvironment; $a = Get-StorageTestAdapter $e
            $p = @(Get-SeedOperationPlan -Session $e.Session -Operations $a.Operations -ResourceChecks $a.ResourceChecks)
            New-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $a.Operations | Out-Null
            $requests = @($a.Requests | ForEach-Object { Copy-StorageValue $_ })
            if ($kind -eq 'Folder') { $requests[0].Path = '/drives/foreign/items/foreign/children' }
            else { @($requests | Where-Object Path -eq '/groups')[0].Body.visibility = 'Public' }
            Assert-Throws { New-SeedWriteApproval -Session $e.Session -Plan $p -Requests $requests -ConfirmTarget "$($e.Config.tenantId)/training01" -StatePath $e.StatePath -RunId training01 -Context $e.Context } 'Seed.Approval.Storage' | Out-Null
            Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count 0
        }
    }
    Test-Case 'Storage callbacks reject caller-edited operation scopes rather than bless arbitrary upfront writes' {
        $e = New-StorageEnvironment; $a = Get-StorageTestAdapter $e
        $operations = @($a.Operations | ForEach-Object { Copy-StorageValue $_ })
        @($operations | Where-Object { $_.StorageScope.Kind -ceq 'Group' })[0].StorageScope.Body.visibility = 'Public'
        $p = @(Get-SeedOperationPlan -Session $e.Session -Operations $operations -ResourceChecks $a.ResourceChecks)
        Assert-True (@($p | Where-Object Action -eq Block).Count -gt 0)
    }
    Test-Case 'Storage source mutation after adapter preparation blocks the whole preflight before writing' {
        $e = New-StorageEnvironment; $a = Get-StorageTestAdapter $e
        Add-Content (Join-Path $e.PreparedPath 'assets\shared.xlsx') 'changed'
        $p = @(Get-SeedOperationPlan -Session $e.Session -Operations $a.Operations -ResourceChecks $a.ResourceChecks)
        Assert-True (@($p | Where-Object Action -eq Block).Count -gt 0)
        Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count 0
    }
    Test-Case 'Storage actual webUrl fallback pagination collision and authoritative bytes are exercised' {
        $e = New-StorageEnvironment; $e.Model.Fault = 'PageCollision'; $a = Get-StorageTestAdapter $e
        $p = @(Get-SeedOperationPlan -Session $e.Session -Operations $a.Operations -ResourceChecks $a.ResourceChecks)
        Assert-True (@($p | Where-Object Action -eq Block).Count -gt 0)
        Assert-True (@($e.Model.Ledger | Where-Object Path -like '*skiptoken*').Count -gt 0)
        $e.Model.Fault = 'InitialLinks'
        $result = Start-StorageTestRun $e $a
        Assert-Equal $result.ResourceLinkIndex.Count 4
        $e.Model.Fault = 'Bytes'
        $verified = Test-SeedStorage -Session $e.Session -Adapter $a
        Assert-True $verified.Verified
        $file = @($e.Model.Items.Values | Where-Object { $_.ContainsKey('Bytes') })[0]
        $file.Bytes[0] = $file.Bytes[0] -bxor 1
        Assert-Throws { Test-SeedStorage -Session $e.Session -Adapter $a } 'Seed.Storage.Verify' | Out-Null
    }
    Test-Case 'Storage content capability cannot be used as a replacing Graph PUT without its private upload session' {
        $e = New-StorageEnvironment; $a = Get-StorageTestAdapter $e
        $plan = @(Get-SeedOperationPlan -Session $e.Session -Operations $a.Operations -ResourceChecks $a.ResourceChecks)
        New-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $a.Operations | Out-Null
        New-SeedWriteApproval -Session $e.Session -Plan $plan -Requests $a.Requests -ConfirmTarget "$($e.Config.tenantId)/training01" -StatePath $e.StatePath -RunId training01 -Context $e.Context | Out-Null
        $storage = Get-SeedStorageRecord $e.Session $a
        foreach ($op in $a.Operations) {
            $r = Get-SeedStorageRequest $e.Session $storage $op
            if ($op.StorageScope.Kind -ceq 'Content') {
                Add-SeedApprovedRequest -Session $e.Session -Request $r -RequestCheck $a.RequestCheck
                $before = $e.Model.Ledger.Count
                Assert-Throws { Invoke-SeedGraph -Session $e.Session -Method PUT -Path $r.Path -RawBody $r.RawBody } 'Seed.Approval.Upload' | Out-Null
                Assert-Equal $e.Model.Ledger.Count $before
                break
            }
            $response = Write-SeedGraph -Session $e.Session -Request $r -RequestCheck $a.RequestCheck
            $id = if ($op.StorageScope.Kind -ceq 'Session') { (Get-SeedStorageDirectory $e.Session $storage $op.StorageScope).ParentId } else { $response.id }
            $storage.Ids[$op.OperationId] = $id
            if ($op.Workload -ceq 'sharepoint') {
                $storage.CreationProofs[$op.OperationId] = @{ objectId = $id; requestSha256 = Get-SeedRequestFingerprint $r.Method $r.Path $r.Body $null }
            }
            $snapshot = Get-SeedStorageSnapshot $e.Session $storage $op
            Write-SeedRunEvent -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $a.Operations -OperationId $op.OperationId -Workload $op.Workload -Action Verify -Status Verified -ObjectId $id -ReadBack $snapshot | Out-Null
        }
    }
    Test-Case 'Storage completed resources reject extra undeclared child IDs and Lists rather than matching counts or titles' {
        $e = New-StorageEnvironment; $a = Get-StorageTestAdapter $e
        Start-StorageTestRun $e $a | Out-Null
        $state = Get-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $a.Operations
        Set-SeedStorageRunState -Session $e.Session -Adapter $a -RunState $state
        $foreign = 'ffffffff-ffff-4fff-8fff-ffffffffffff'
        $e.Model.Lists[$foreign] = @{ id = $foreign; displayName = 'Actions'; list = @{ template = 'genericList' } }
        Assert-Throws { Test-SeedStorage -Session $e.Session -Adapter $a } 'Seed.Storage.Verify' | Out-Null
        $e.Model.Lists.Remove($foreign)
        $folder = @($e.Model.Items.Values | Where-Object { $_.ContainsKey('name') -and $_.name -ceq 'Nested' })[0]
        $e.Model.Items.foreign = @{ id = 'foreign'; name = 'Metrics.xlsx'; parentReference = @{ id = $folder.id; driveId = $folder.parentReference.driveId } }
        Assert-Throws { Test-SeedStorage -Session $e.Session -Adapter $a } 'Seed.Storage.Verify' | Out-Null
    }
    Test-Case 'Storage accepted create with missing canonical links retains Unknown and the known remote ID without further writes' {
        $e = New-StorageEnvironment; $a = Get-StorageTestAdapter $e
        $e.Model.Fault = 'NoLinks'
        Assert-Throws { Start-StorageTestRun $e $a } 'Seed.Storage.Stopped' | Out-Null
        $state = Get-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $a.Operations
        Assert-Equal $state.status Blocked
        $failure = @($state.events | Where-Object status -ceq Unknown)[0]
        Assert-True ($failure.Contains('objectId') -and $failure.objectId -ceq 'dddddddd-dddd-4ddd-8ddd-dddddddddddd')
        Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count 2
    }
    Test-Case 'Storage upload allocation requires actual private GET status rather than trusting POST acceptance' {
        $e = New-StorageEnvironment; $a = Get-StorageTestAdapter $e
        $e.Model.Fault = 'SessionStatus'
        Assert-Throws { Start-StorageTestRun $e $a } 'Seed.Storage.Stopped' | Out-Null
        $state = Get-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $a.Operations
        Assert-Equal $state.status Blocked
        Assert-Equal @($e.Model.Ledger | Where-Object Method -ceq PUT).Count 0
        Assert-True (@($e.Model.Ledger | Where-Object Path -ceq '[private upload status]').Count -gt 0)
    }
    Test-Case 'Storage actor guard accepts null profile fields only for Existing-source actors and keeps Managed strict' {
        $e = New-StorageEnvironment
        $record = Get-SeedSessionRecord $e.Session
        $leadId = $record.Identity.Roles.Lead.ObjectId
        $setIdentity = {
            param([string]$Source)
            $identity = Copy-StorageValue $record.Identity
            $identity.Roles.Lead.ProfileFingerprint = Get-SeedFingerprint (Copy-StorageValue $e.Model.Profiles[$leadId])
            if ($Source) { $identity.Roles.Lead.AccountSource = $Source }
            $identity.Roles.Presenter = $identity.Presenter
            $identity.ActorFingerprint = Get-SeedFingerprint $identity.Roles
            $record.Identity = $identity
            $record.ServiceGate = @{ Workloads = @('onedrive', 'sharepoint'); ActorFingerprint = $identity.ActorFingerprint }
            @{ IdentityFingerprint = Get-SeedFingerprint $record.Identity }
        }.GetNewClosure()
        $e.Model.Profiles[$leadId].officeLocation = $null
        $storage = & $setIdentity ''
        Assert-Throws { Assert-SeedStorageActors $e.Session $storage } 'Seed.Storage.Identity' | Out-Null
        $storage = & $setIdentity 'Existing'
        Assert-SeedStorageActors $e.Session $storage
        $e.Model.Profiles[$leadId].jobTitle = 7
        Assert-Throws { Assert-SeedStorageActors $e.Session $storage } 'Seed.Storage.Identity' | Out-Null
        $e.Model.Profiles[$leadId].jobTitle = 'Lead'
        $e.Model.Profiles[$leadId].department = 'drift'
        Assert-Throws { Assert-SeedStorageActors $e.Session $storage } 'Seed.Storage.Identity' | Out-Null
        Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count 0
    }
    Test-Case 'Storage native REST JSON objects from both transports keep folder ids payloads ACL fields and the zero-write rerun' {
        $e = New-StorageEnvironment; $e.Model.Fault = 'PagedMembers'
        $native = Use-StorageNativeJsonTransports $e
        $a = Get-StorageTestAdapter $e
        $result = Start-StorageTestRun $e $a
        Assert-True $result.Verified
        Assert-True ($native.GraphPost -gt 0 -and $native.Graph -gt $native.GraphPost -and $native.UploadPut -gt 0) 'Both transports must have returned native objects.'
        Assert-Equal $native.UploadPut @($e.Model.Ledger | Where-Object Method -ceq PUT).Count
        $state = Get-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $a.Operations -ForImport
        Assert-Equal $state.status Completed
        $storage = Get-SeedStorageRecord $e.Session $a
        $folders = @($a.Operations | Where-Object { $_.StorageScope.Kind -ceq 'Folder' })
        $posts = @($e.Model.Ledger | Where-Object { $_.Method -ceq 'POST' -and $_.Path -match '^/drives/[^/]+/items/[^/]+/children$' })
        Assert-True ($folders.Count -gt 0)
        Assert-Equal $posts.Count $folders.Count
        foreach ($folder in $folders) {
            $created = @($state.results | Where-Object { $_.id -ceq $folder.OperationId -and $_.status -ceq 'Verified' })
            Assert-Equal $created.Count 1
            $item = $e.Model.Items[$created[0].objectId]
            Assert-True ($item.name -ceq $folder.StorageScope.Name -and $item.ContainsKey('folder')) 'The journal must hold the folder ID returned by the POST.'
            $sent = @($posts | Where-Object { $_.Body.name -ceq $folder.StorageScope.Name })
            Assert-True ($sent.Count -ge 1 -and $sent[0].Body.Contains('folder') -and $sent[0].Body['@microsoft.graph.conflictBehavior'] -ceq 'fail') 'The approved folder payload must be what was sent.'
            $access = $storage.Evidence[$folder.OperationId].access
            Assert-Equal $access.presenterId $e.Model.Presenter
            if ($folder.Workload -ceq 'onedrive') { Assert-True $access.read }
            else {
                Assert-Equal $access.kind GraphStructural
                Assert-Equal $access.remoteAclStatus NotProven
                Assert-Equal $access.groupId 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
                Assert-Equal $access.inheritance.model ToolCreatedGroupInheritanceV1
                Assert-Equal @($access.sharingPermissions).Count 0
            }
        }
        $writes = @($e.Model.Ledger | Where-Object Method -ne GET).Count; $reads = $native.Graph
        Set-SeedStorageRunState -Session $e.Session -Adapter $a -RunState $state
        $plan = @(Get-SeedOperationPlan -Session $e.Session -Operations $a.Operations -ResourceChecks $a.ResourceChecks -RunState $state)
        Assert-Equal @($plan | Where-Object Action -ne Skip).Count 0
        $again = Invoke-UploadFiles -Session $e.Session -Adapter $a -Plan $plan
        Assert-True $again.Verified
        foreach ($key in $result.AssetUrlMap.Keys) { Assert-Equal $again.AssetUrlMap[$key].resourceId $result.AssetUrlMap[$key].resourceId }
        Assert-True ($native.Graph -gt $reads) 'The rerun must read back through the native transport.'
        Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count $writes
    }
    Test-Case 'Storage stable sharing evidence ignores mutable provider aliases but retains exact principal and role boundaries' {
        $e = New-StorageEnvironment
        try {
            $e.Model.Items.permissionProbe = @{ id='permissionProbe' }
            $e.Model.Fault = 'PermissionMetadata'
            $first = @(Get-SeedStorageSharingSnapshot $e.Session sp permissionProbe -SharingEvidenceVersion 2)
            $next = @(Get-SeedStorageSharingSnapshot $e.Session sp permissionProbe -SharingEvidenceVersion 2)
            Assert-Equal (Get-SeedFingerprint $first) (Get-SeedFingerprint $next)
            $e.Model.Fault = 'PermissionNoExpiry'
            Assert-Equal (Get-SeedFingerprint @(Get-SeedStorageSharingSnapshot $e.Session sp permissionProbe -SharingEvidenceVersion 2)) (Get-SeedFingerprint $first)
            foreach ($fault in @('PermissionPrincipal','PermissionRole','PermissionInheritance')) {
                $e.Model.Fault = $fault
                $changed = @(Get-SeedStorageSharingSnapshot $e.Session sp permissionProbe -SharingEvidenceVersion 2)
                Assert-True ((Get-SeedFingerprint $changed) -cne (Get-SeedFingerprint $first))
            }
            foreach ($fault in @('PermissionMalformed','PermissionAliasMismatch','PermissionDuplicate','PermissionExpiry','PermissionLegacyOnly','PermissionMissingId','PermissionPlural')) {
                $e.Model.Fault = $fault
                Assert-Throws { Get-SeedStorageSharingSnapshot $e.Session sp permissionProbe -SharingEvidenceVersion 2 } 'Seed.Storage.Inheritance' | Out-Null
            }
            $e.Model.Fault = 'PermissionPluralLink'
            $plural = @(Get-SeedStorageSharingSnapshot $e.Session sp permissionProbe -SharingEvidenceVersion 2)
            Assert-Equal $plural[0].grantedToIdentitiesV2[0].siteGroup '3'
            $e.Model.Fault = 'ExistingAccess'
            $emptyRecipients = @(Get-SeedStorageSharingSnapshot $e.Session sp permissionProbe -SharingEvidenceVersion 2)
            Assert-Equal $emptyRecipients[0].link.scope 'existingAccess'
            Assert-True (-not $emptyRecipients[0].Contains('grantedToIdentitiesV2'))
            Assert-Throws { Get-SeedStorageSharingSnapshot $e.Session sp permissionProbe } 'Seed.Storage.Inheritance' | Out-Null
            Assert-Throws { Get-SeedStorageSharingSnapshot $e.Session sp permissionProbe -SharingEvidenceVersion 3 } 'Seed.Storage.Inheritance' | Out-Null
            Assert-Equal (Get-SeedFingerprint (ConvertTo-SeedStoragePermissionIdentity @{siteGroup=@{id=3}})) (Get-SeedFingerprint (ConvertTo-SeedStoragePermissionIdentity @{sharePointGroup=@{principalId='3'}}))
            Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count 0
        } finally { Close-SeedSession $e.Session }
    }
    Test-Case 'Storage provisioned sharing identities remain stable through complete Simple creation and zero-write rerun' {
        $e = New-StorageEnvironment
        try {
            $e.Model.Fault = 'PermissionMetadata'
            $a = Get-SeedStorageAdapter -Session $e.Session -Scenario $e.Scenario -PreparedPath $e.PreparedPath -Context $e.Context -RunId training01 -StatePath $e.StatePath
            Assert-Equal @($a.Operations | Where-Object { $_.Workload -ceq 'sharepoint' -and $_.StorageScope.SharingEvidenceVersion -ne 2 }).Count 0
            $result = Start-StorageTestRun $e $a
            Assert-Equal $result.AssetUrlMap.Count 2
            $state = Get-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $a.Operations -ForImport
            Set-SeedStorageRunState $e.Session $a $state
            $before = @($e.Model.Ledger | Where-Object Method -ne GET).Count
            $plan = @(Get-SeedOperationPlan -Session $e.Session -Operations $a.Operations -ResourceChecks $a.ResourceChecks -RunState $state)
            Assert-Equal @($plan | Where-Object Action -ne Skip).Count 0
            Invoke-UploadFiles -Session $e.Session -Adapter $a -Plan $plan | Out-Null
            foreach ($fault in @('PermissionPrincipal','PermissionRole','PermissionInheritance')) {
                $e.Model.Fault = $fault
                Assert-Throws { Test-SeedStorage $e.Session $a } 'Seed.Storage.Verify' | Out-Null
            }
            Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count $before
        } finally { Close-SeedSession $e.Session }
    }
    Test-Case 'Storage existingAccess links preserve private group proof without storing links or accepting new grants' {
        $e = New-StorageEnvironment
        $e.Model.Fault = 'ExistingAccess'
        $a = Get-StorageTestAdapter $e
        $result = Start-StorageTestRun $e $a
        $storage = Get-SeedStorageRecord $e.Session $a
        Assert-True (($storage.Evidence | ConvertTo-Json -Depth 100) -notmatch 'never-store-this|private\?sig=')
        Assert-True (($storage.Evidence | ConvertTo-Json -Depth 100) -match 'existingAccess')
        $before = @($e.Model.Ledger | Where-Object Method -ne GET).Count
        foreach ($fault in @('OrganizationLink', 'ExistingAccessInvite')) {
            $e.Model.Fault = $fault
            Assert-Throws { Test-SeedStorage -Session $e.Session -Adapter $a } 'Seed.Storage.Verify' | Out-Null
        }
        Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count $before
    }
    Test-Case 'Storage Office viewer links require exact document identity and filename and reject capability parameters' {
        $documentId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
        $url = 'https://example.sharepoint.com/_layouts/15/Doc.aspx?sourcedoc=%7B' + $documentId + '%7D&file=Pilot-20.xlsx&action=default&mobileredirect=true'
        Assert-Equal (Assert-StorageWebUrl $url -ExpectedFileName 'Pilot-20.xlsx' -ExpectedDocumentId $documentId -ExpectedHost 'example.sharepoint.com') $url
        foreach ($bad in @(
            ($url + '&sig=hidden'),
            ($url + '&token=hidden'),
            ($url + '&file=Other.xlsx'),
            ($url -replace 'Pilot-20.xlsx', 'Other.xlsx'),
            ($url -replace $documentId, 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'),
            ($url -replace 'action=default', 'action=share'),
            ($url -replace '/_layouts/', '/:x:/r/_layouts/'),
            ($url -replace '/_layouts/', '/%3Ax%3A/r/_layouts/'),
            ($url -replace '/_layouts/15/Doc.aspx', '/ordinary.xlsx')
        )) {
            Assert-Throws { Assert-StorageWebUrl $bad -ExpectedFileName 'Pilot-20.xlsx' -ExpectedDocumentId $documentId -ExpectedHost 'example.sharepoint.com' } 'Seed.Storage.Link' | Out-Null
        }
        Assert-Throws { Assert-StorageWebUrl $url -ExpectedFileName 'Pilot-20.xlsx' -ExpectedDocumentId $documentId -ExpectedHost 'foreign.sharepoint.com' } 'Seed.Storage.Link' | Out-Null
        Assert-Throws { Assert-StorageWebUrl $url -ExpectedFileName 'Pilot-20.xlsx' -ExpectedDocumentId $documentId } 'Seed.Storage.Link' | Out-Null
        Assert-Throws { Assert-StorageWebUrl $url } 'Seed.Storage.Link' | Out-Null
    }
    Test-Case 'Storage canonical Office viewer readback remains valid in a completed Simple run' {
        $e = New-StorageEnvironment
        $e.Model.Fault = 'OfficeViewer'
        $a = Get-SeedStorageAdapter -Session $e.Session -Scenario $e.Scenario -PreparedPath $e.PreparedPath -Context $e.Context -RunId training01 -StatePath $e.StatePath
        $result = Start-StorageTestRun $e $a
        Assert-Equal $result.AssetUrlMap.Count 2
        foreach ($asset in $result.AssetUrlMap.Values) { Assert-True ($asset.webUrl.Contains('Doc.aspx?sourcedoc=')) }
        $state = Get-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $a.Operations -ForImport
        Set-SeedStorageRunState -Session $e.Session -Adapter $a -RunState $state
        $before = @($e.Model.Ledger | Where-Object Method -ne GET).Count
        $plan = @(Get-SeedOperationPlan -Session $e.Session -Operations $a.Operations -ResourceChecks $a.ResourceChecks -RunState $state)
        Assert-Equal @($plan | Where-Object Action -ne Skip).Count 0
        Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count $before
    }
    Test-Case 'Storage simple upload defaults to fail-only Graph byte PUT and a completed zero-write rerun' {
        $e = New-StorageEnvironment
        $a = Get-SeedStorageAdapter -Session $e.Session -Scenario $e.Scenario -PreparedPath $e.PreparedPath -Context $e.Context -RunId training01 -StatePath $e.StatePath
        Assert-Equal @($a.Operations | Where-Object { $_.StorageScope.Kind -ceq 'Session' }).Count 0
        $result = Start-StorageTestRun $e $a
        Assert-Equal $result.AssetUrlMap.Count 2
        $puts = @($e.Model.Ledger | Where-Object Method -ceq PUT)
        Assert-Equal $puts.Count 2
        Assert-Equal @($puts | Where-Object { -not $_.Path.EndsWith('?@microsoft.graph.conflictBehavior=fail', [StringComparison]::Ordinal) }).Count 0
        Assert-Equal $e.Model.Uploads.Count 0
        $state = Get-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $a.Operations -ForImport
        Set-SeedStorageRunState -Session $e.Session -Adapter $a -RunState $state
        $before = @($e.Model.Ledger | Where-Object Method -ne GET).Count
        $plan = @(Get-SeedOperationPlan -Session $e.Session -Operations $a.Operations -ResourceChecks $a.ResourceChecks -RunState $state)
        Assert-Equal @($plan | Where-Object Action -ne Skip).Count 0
        Invoke-UploadFiles -Session $e.Session -Adapter $a -Plan $plan | Out-Null
        Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count $before
    }
    Test-Case 'Storage simple upload rejects missing or altered conflict policy before a network write' {
        $e = New-StorageEnvironment
        $a = Get-SeedStorageAdapter -Session $e.Session -Scenario $e.Scenario -PreparedPath $e.PreparedPath -Context $e.Context -RunId training01 -StatePath $e.StatePath
        Start-StorageTestRun $e $a | Out-Null
        $storage = Get-SeedStorageRecord $e.Session $a
        $content = @($a.Operations | Where-Object { $_.StorageScope.Kind -ceq 'Content' })[0]
        $request = Get-SeedStorageRequest $e.Session $storage $content
        $before = @($e.Model.Ledger | Where-Object Method -ne GET).Count
        foreach ($query in @('', '?@microsoft.graph.conflictBehavior=replace', '?@microsoft.graph.conflictBehavior=rename', '?@microsoft.graph.conflictBehavior=fail&other=true')) {
            $changed = Copy-StorageValue $request
            $changed.RawBody = [byte[]]$request.RawBody
            $changed.Path = ($request.Path -split '\?', 2)[0] + $query
            Assert-Throws { Write-SeedGraph -Session $e.Session -Request $changed -RequestCheck $a.RequestCheck } 'Seed\.(Write|Approval)' | Out-Null
        }
        Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count $before
    }
    Test-Case 'Storage callbacks retain their helpers when the calling host cannot resolve their names' {
        $e = New-StorageEnvironment
        $a = Get-StorageTestAdapter $e
        $proof = ${function:Get-SeedStorageProof}
        $check = ${function:Test-SeedStorageRequest}
        try {
            Remove-Item Function:\Get-SeedStorageProof
            Remove-Item Function:\Test-SeedStorageRequest
            $roots = @($a.Operations | Where-Object { -not $_.StorageScope.ParentOperationId })
            $plan = @(Get-SeedOperationPlan -Session $e.Session -Operations $roots -ResourceChecks $a.ResourceChecks)
            Assert-Equal @($plan | Where-Object Action -eq Block).Count 0
        } finally {
            Set-Item Function:script:Get-SeedStorageProof -Value $proof
            Set-Item Function:script:Test-SeedStorageRequest -Value $check
        }
    }
    Test-Case 'Storage upload continuation passes a byte array rather than conditional pipeline objects' {
        $e = New-StorageEnvironment
        $record = Get-SeedSessionRecord $e.Session
        $original = $record.UploadTransport
        $checked = @{ Put = 0 }
        $record.UploadTransport = {
            param($Url, $Bytes, $Headers)
            if ($null -ne $Bytes) {
                Assert-True ($Bytes -is [byte[]]) 'The actual HTTP Body must remain byte[], not Object[] with the same Length.'
                Assert-Equal ([string]$Headers['Content-Length']) ([string]$Bytes.Length)
                $checked.Put++
            }
            & $original $Url $Bytes $Headers
        }.GetNewClosure()
        $a = Get-StorageTestAdapter $e
        Start-StorageTestRun $e $a | Out-Null
        Assert-Equal $checked.Put 2
    }
    Test-Case 'Storage upload failure preserves safe HTTP diagnostics and never retries the PUT' {
        $e = New-StorageEnvironment
        $record = Get-SeedSessionRecord $e.Session
        $original = $record.UploadTransport
        $calls = @{ Put = 0 }
        $record.UploadTransport = {
            param($Url, $Bytes, $Headers)
            if ($null -eq $Bytes) { return & $original $Url $Bytes $Headers }
            $calls.Put++
            $failure = [InvalidOperationException]::new('https://example.invalid/?sig=private-value')
            $failure.Data['StatusCode'] = 403
            throw $failure
        }.GetNewClosure()
        $a = Get-StorageTestAdapter $e
        $caught = $null
        try { Start-StorageTestRun $e $a | Out-Null } catch { $caught = $_.Exception }
        Assert-True ($null -ne $caught)
        Assert-Equal $caught.Data['SeedDiagnostic'].Stage UploadPut
        Assert-Equal $caught.Data['SeedDiagnostic'].HttpStatus 403
        Assert-True (($caught.Data['SeedDiagnostic'] | ConvertTo-Json) -notmatch 'private-value|example.invalid')
        Assert-Equal $calls.Put 1
        $state = Get-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $a.Operations
        Assert-Equal @($state.results | Where-Object status -ceq Unknown).Count 1
    }
    Test-Case 'Storage native upload PUT response that cannot be converted keeps Unknown through the existing upload protocol' {
        $e = New-StorageEnvironment
        $null = Use-StorageNativeJsonTransports $e
        $a = Get-StorageTestAdapter $e
        $e.Model.Fault = 'UploadResponseTooDeep'
        Assert-Throws { Start-StorageTestRun $e $a 3>$null } 'Seed.Storage.Stopped' | Out-Null
        $state = Get-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $a.Operations
        Assert-Equal $state.status Blocked
        $unknown = @($state.results | Where-Object status -ceq Unknown)
        Assert-Equal $unknown.Count 1
        $operation = @($a.Operations | Where-Object OperationId -ceq $unknown[0].id)
        Assert-Equal $operation.Count 1
        Assert-Equal $operation[0].StorageScope.Kind Content
        $failure = @($state.events | Where-Object status -ceq Unknown)
        Assert-Equal $failure.Count 1
        Assert-Equal $failure[0].error.code GraphWriteOutcomeUnknown
        Assert-Equal @($e.Model.Ledger | Where-Object Method -ceq PUT).Count 1
        $writes = @($e.Model.Ledger | Where-Object Method -ne GET).Count
        Assert-Throws { Get-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $a.Operations -ForImport } 'Seed.State.Blocked' | Out-Null
        Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count $writes
    }
} finally {
    foreach ($r in @($script:SeedSessions.Values)) { Close-SeedSession $r.Handle }
    Remove-Item -LiteralPath $storageScratch -Recurse -Force
}
