$personaScratch = Join-Path $root ('tests\.scratch\t2a-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $personaScratch -Force | Out-Null
function Copy-PersonaTestValue($Value) { $Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable }
function New-PersonaAppTestSession($Config, $Transport) {
    $claims = @{ tid = $Config.tenantId; appid = $Config.clientId; aud = 'https://graph.microsoft.com'; iss = "https://sts.windows.net/$($Config.tenantId)/"
        exp = [DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds(); roles = @(Get-SeedManagementAppRoles InitializePersonas -AccountSource (Get-SeedPersonaAccountSource $Config)) }
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($claims | ConvertTo-Json -Compress))).TrimEnd('=').Replace('+','-').Replace('/','_')
    $token = "offline.$payload.offline"
    Connect-SeedSession -Config $Config -Mode InitializePersonas -TokenProvider { $token }.GetNewClosure() -Transport $Transport -Delay {}
}
function New-PersonaTestEnvironment {
    $folder = Join-Path $personaScratch ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $folder | Out-Null
    foreach ($name in @('personas.json', 'alice.jpg', 'bob.jpg', 'rights.txt')) {
        Copy-Item -LiteralPath (Join-Path $root "tests\fixtures\$name") -Destination $folder
    }
    $c = Get-Content -LiteralPath (Join-Path $root 'tests\fixtures\managed-config.json') -Raw | ConvertFrom-Json -AsHashtable
    $c.personas.packPath = Join-Path $folder 'personas.json'
    $c.personas.bindingPath = Join-Path $folder 'private.binding.json'
    $model = @{
        Users = @{}; Ledger = [Collections.Generic.List[object]]::new()
        InitialValues = [Collections.Generic.List[string]]::new(); Seats = 100
        DomainVerified = $true; ActiveRole = $true; Fault = ''; Created = 0; PendingLicense = $false
        PresenterId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
        OperatorId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'; Config = $c
    }
    $transport = {
        param($Method, $Path, $Body, $RawBody)
        $safe = if ($null -ne $Body) { Copy-PersonaTestValue $Body } else { $null }
        if ($null -ne $safe -and $safe.Contains('passwordProfile')) { $safe.Remove('passwordProfile') }
        $model.Ledger.Add(@{ Method = $Method; Path = $Path; Body = $safe })
        if ($Method -ne 'GET') {
            $journalPath = $c.personas.bindingPath + '.journal.json'
            if (-not (Test-Path -LiteralPath $journalPath)) { throw 'Journal missing before write.' }
            $j = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json -AsHashtable
            if ($j.status -ne 'Running' -or $j.events[-1].status -ne 'Pending') { throw 'Durable pending missing.' }
        }
        if ($Path -eq '/me?$select=id,userPrincipalName') { return @{ id = $model.OperatorId; userPrincipalName = $c.adminAuth.adminOperatorUpn } }
        if ($Path -like '/roleManagement/*') {
            return @{ value = @($(if ($model.ActiveRole) { @{ principalId = $model.OperatorId; directoryScopeId = '/'; roleDefinition = @{ templateId = 'fe930be7-5e62-47db-91af-98c3a49a38b1' } } })) }
        }
        if ($Path -eq '/domains?$select=id,isVerified,authenticationType') {
            return @{ value = @(@{ id = $c.personas.userDomain; isVerified = $model.DomainVerified; authenticationType = 'Managed' }) }
        }
        if ($Path -eq '/subscribedSkus?$select=skuId,capabilityStatus,consumedUnits,prepaidUnits') {
            return @{ value = @(@{ skuId = $c.personas.licenseProfiles.standard.skuIds[0]; capabilityStatus = 'Enabled'; consumedUnits = 0; prepaidUnits = @{ enabled = $model.Seats } }) }
        }
        if ($Method -eq 'GET' -and $Path.StartsWith('/users?')) {
            return @{ value = @(@{ id = $model.PresenterId; userPrincipalName = $c.presenterUpn; displayName = 'Presenter'; jobTitle = ''; department = ''; companyName = ''; accountEnabled = $true; userType = 'Member' }) + @($model.Users.Values | ForEach-Object { $_.Profile }) }
        }
        if ($Method -eq 'GET' -and $Path -like '/users/presenter%40*') {
            return @{ id = $model.PresenterId; userPrincipalName = $c.presenterUpn; accountEnabled = $true; userType = 'Member' }
        }
        if ($Method -eq 'POST' -and $Path -eq '/users') {
            $model.Created++
            $id = if ($model.Created -eq 1) { 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' } else { 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' }
            $model.InitialValues.Add($Body.passwordProfile.password)
            if ($Body.passwordProfile.forceChangePasswordNextSignIn -cne $true) { throw 'Initial password policy missing.' }
            $profile = Copy-PersonaTestValue $Body
            $profile.Remove('passwordProfile'); $profile.Remove('mailNickname')
            $profile.id = $id; $profile.assignedLicenses = @(); $profile.licenseAssignmentStates = @(); $profile.onPremisesSyncEnabled = $null
            $model.Users[$id] = @{ Profile = $profile; Manager = $null; Photo = $null }
            if ($model.Fault -eq 'UnknownCreate') { throw [InvalidOperationException]::new("SECRET $($Body.passwordProfile.password)") }
            return @{ id = $id }
        }
        if ($Path -match '^/users/([0-9a-f-]{36})(.*)$') {
            $id = $Matches[1]; $tail = $Matches[2]
            if (-not $model.Users.ContainsKey($id)) { throw (New-GraphStubError 404) }
            $u = $model.Users[$id]
            if ($Method -eq 'GET' -and $tail.StartsWith('?')) {
                if ($model.Fault -eq 'ChangedId') { $p = Copy-PersonaTestValue $u.Profile; $p.id = $model.PresenterId; return $p }
                return Copy-PersonaTestValue $u.Profile
            }
            if ($tail -eq '/manager?$select=id' -and $Method -eq 'GET') {
                if ($null -eq $u.Manager) { throw (New-GraphStubError 404) }
                return @{ id = $u.Manager }
            }
            if ($tail -eq '/photo/$value' -and $Method -eq 'GET') {
                if ($model.Fault -eq 'PhotoForbidden') { throw (New-GraphStubError 403) }
                if ($null -eq $u.Photo) { throw (New-GraphStubError 404) }
                return ,([byte[]]$u.Photo)
            }
            if ($Method -eq 'PATCH' -and $tail -eq '') {
                foreach ($key in $Body.Keys) { $u.Profile[$key] = $Body[$key] }
                if ($model.Fault -eq 'UnknownPatch') { throw (New-GraphStubError 503) }
                return $null
            }
            if ($Method -eq 'PUT' -and $tail -eq '/manager/$ref') {
                $u.Manager = ($Body['@odata.id'] -split '/')[-1]; return $null
            }
            if ($Method -eq 'PUT' -and $tail -eq '/photo/$value') {
                if ($model.Fault -eq 'IgnorePhoto') { return $null }
                # Graph may re-encode JPEGs; the binding must hash downloaded bytes.
                $u.Photo = [byte[]](@($RawBody) + @(0))
                if ($model.Fault -eq 'DriftAfterPhoto' -and $model.Users.ContainsKey('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb')) {
                    $model.Users['bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'].Profile.department = 'Concurrent change'
                }
                if ($model.Fault -eq 'UnknownPhoto') { throw (New-GraphStubError 503) }
                return $null
            }
            if ($Method -eq 'POST' -and $tail -eq '/assignLicense') {
                if (@($Body.removeLicenses).Count -ne 0) { throw 'Removal forbidden.' }
                foreach ($sku in $Body.addLicenses) {
                    $u.Profile.assignedLicenses += @{ skuId = $sku.skuId; disabledPlans = @() }
                    $u.Profile.licenseAssignmentStates += @{ skuId = $sku.skuId; state = $(if ($model.PendingLicense) { 'ActiveWithError' } else { 'Active' }); error = $(if ($model.PendingLicense) { 'CountViolation' } else { $null }); assignedByGroup = $null; disabledPlans = @() }
                }
                return Copy-PersonaTestValue $u.Profile
            }
        }
        throw "Unconfigured offline request: $Method $Path"
    }.GetNewClosure()
    $ctx = @{ TenantId = $c.tenantId; ClientId = $c.adminAuth.clientId; Account = $c.adminAuth.adminOperatorUpn; AuthType = 'Delegated'; ContextScope = 'Process'; Scopes = @(Get-SeedAdminScopes InitializePersonas) }
    $context = { $ctx }.GetNewClosure()
    $s = New-PersonaAppTestSession $c $transport
    @{ Config = $c; Model = $model; Session = $s; Context = $ctx; Folder = $folder }
}
function Get-PersonaTestPlan($E) { Get-SeedPersonaPlan -Session $E.Session -Config $E.Config }
function Invoke-PersonaTestPlan($E, $P) {
    Invoke-InitializePersonas -Session $E.Session -Plan $P -ConfirmTarget $P.Target -ConfirmPlanFingerprint $P.Fingerprint -NonInteractive 6>$null
}
function Assert-NoPersonaWrites($E) { Assert-Equal @($E.Model.Ledger | Where-Object Method -ne GET).Count 0 }
function Complete-PersonaTestEnvironment($E) {
    $p = Get-PersonaTestPlan $E
    Invoke-PersonaTestPlan $E $p
}
function New-ExistingPersonaTestEnvironment {
    # Synthetic tenant of already-existing accounts (some with null profile fields) behind the exact Graph boundary.
    param([int]$Count = 2, [string]$PackFile = '', [string[]]$PersonaIds = @(), [string]$UpnPrefix = 'existing-', [string]$UpnDomain = 'example.invalid')
    if (-not ('SeedTestHost' -as [type])) { Add-Type -TypeDefinition (Get-Content -LiteralPath (Join-Path $root 'tests\powershell\Console.TestHost.cs') -Raw) }
    $folder = Join-Path $personaScratch ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $folder | Out-Null
    $names = @('alice', 'bob', 'carol', 'dave', 'erin', 'frank', 'grace', 'heidi')
    if ($PackFile) {
        $pack = Get-Content -LiteralPath $PackFile -Raw | ConvertFrom-Json -AsHashtable
        $selected = @($PersonaIds)
    } else {
        $pack = Get-Content -LiteralPath (Join-Path $root 'tests\fixtures\existing-personas.json') -Raw | ConvertFrom-Json -AsHashtable
        for ($i = 2; $i -lt $Count; $i++) {
            $pack.people += @{ personaId = $names[$i]; identityHint = @{ displayName = "$($names[$i]) Test"; alias = $names[$i] }; profile = @{ jobTitle = "Role $($names[$i])"; department = 'Operations'; companyName = 'Fictional Test' }; managerRef = 'alice' }
        }
        $selected = @($names | Select-Object -First $Count)
    }
    $ids = [ordered]@{}
    for ($i = 0; $i -lt $selected.Count; $i++) {
        $d = [string]($i + 1)
        $ids[$selected[$i]] = switch ($i) { 0 { 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa' } 1 { 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' } default { ($d * 8) + '-' + ($d * 4) + '-4' + ($d * 3) + '-8' + ($d * 3) + '-' + ($d * 12) } }
    }
    $pack | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath (Join-Path $folder 'personas.json') -Encoding utf8
    $m = Get-Content -LiteralPath (Join-Path $root 'tests\fixtures\managed-config.json') -Raw | ConvertFrom-Json -AsHashtable
    $c = @{ schemaVersion = '1.1'; tenantId = $m.tenantId; presenterUpn = $m.presenterUpn; clientId = $m.clientId; clientSecretEnvironmentVariable = $m.clientSecretEnvironmentVariable
        personas = @{ accountSource = 'Existing'; packPath = (Join-Path $folder 'personas.json'); instanceId = 'training01'; bindingPath = (Join-Path $folder 'private.binding.json'); accountMappings = @{} }
        runId = 'training01'; adminAuth = $m.adminAuth }
    $model = @{
        Users = @{}; Ledger = [Collections.Generic.List[object]]::new(); Ids = $ids; Roles = @{}; Groups = @{}; AfterWrite = $null
        PresenterId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'; OperatorId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'; ExternalId = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'
        ActiveRole = $true; Fault = ''; Config = $c
    }
    foreach ($n in @($ids.Keys)) {
        $c.personas.accountMappings[$n] = "$UpnPrefix$n@$UpnDomain"
        $model.Users[$ids[$n]] = @{ Manager = $null; Profile = @{
            id = $ids[$n]; userPrincipalName = "$UpnPrefix$n@$UpnDomain"; displayName = "$n Existing"; jobTitle = 'Old title'; department = $null; companyName = $null
            officeLocation = $null; usageLocation = 'US'; accountEnabled = $true; userType = 'Member'; onPremisesSyncEnabled = $null
            assignedLicenses = @(@{ skuId = '99999999-9999-4999-8999-999999999999'; disabledPlans = @('PLAN-X') })
            licenseAssignmentStates = @(@{ skuId = '99999999-9999-4999-8999-999999999999'; state = 'Active'; error = 'None'; assignedByGroup = $null; disabledPlans = @('PLAN-X') }) } }
    }
    $first = $model.Users[$ids[0]]
    $first.Profile.jobTitle = 'Lead'; $first.Profile.department = 'Operations'; $first.Manager = $model.ExternalId
    $first.Profile.licenseAssignmentStates = @(@{ skuId = '99999999-9999-4999-8999-999999999999'; state = 'Active'; error = 'None'; assignedByGroup = 'ffffffff-ffff-4fff-8fff-ffffffffffff'; disabledPlans = @('PLAN-X') })
    $model.Users[$model.ExternalId] = @{ Manager = $null; Profile = @{ id = $model.ExternalId; userPrincipalName = 'external-boss@example.invalid'; displayName = 'External Boss'; jobTitle = 'Outside manager'; accountEnabled = $true; userType = 'Member' } }
    $transport = {
        param($Method, $Path, $Body, $RawBody)
        $safe = if ($null -ne $Body) { Copy-PersonaTestValue $Body } else { $null }
        $model.Ledger.Add(@{ Method = $Method; Path = $Path; Body = $safe })
        if ($Method -ne 'GET') {
            $journalPath = $c.personas.bindingPath + '.journal.json'
            if (-not (Test-Path -LiteralPath $journalPath)) { throw 'Journal missing before write.' }
            $j = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json -AsHashtable
            if ($j.status -ne 'Running' -or $j.events[-1].status -ne 'Pending') { throw 'Durable pending missing.' }
            if ($Method -notin @('PATCH', 'PUT') -or $Path -notmatch '^/users/[0-9a-f-]{36}(?:/manager/\$ref)?$') { throw "Forbidden offline write: $Method $Path" }
        }
        if ($Path -eq '/me?$select=id,userPrincipalName') { return @{ id = $model.OperatorId; userPrincipalName = $c.adminAuth.adminOperatorUpn } }
        if ($Path -match '^/roleManagement/directory/(roleAssignments|roleEligibilityScheduleInstances)\?\$filter=principalId%20eq%20''([0-9a-f-]{36})''') {
            $kind = $Matches[1]; $principal = $Matches[2]
            if ($principal -eq $model.OperatorId) {
                if ($kind -ne 'roleAssignments' -or -not $model.ActiveRole) { return @{ value = @() } }
                return @{ value = @(@{ principalId = $model.OperatorId; directoryScopeId = '/'; roleDefinition = @{ templateId = 'fe930be7-5e62-47db-91af-98c3a49a38b1' } }) }
            }
            if ($model.Fault -eq 'RoleQuery403') { throw (New-GraphStubError 403) }
            if ($model.Fault -eq 'RoleUnreadable') { return @{ value = @(@{ unexpected = 'shape' }) } }
            if ($model.Roles.ContainsKey($principal) -and $model.Roles[$principal].ContainsKey($kind)) { return @{ value = @($model.Roles[$principal][$kind]) } }
            return @{ value = @() }
        }
        if ($Method -eq 'GET' -and $Path -like '/users/presenter%40*') { return @{ id = $model.PresenterId; userPrincipalName = $c.presenterUpn; accountEnabled = $true; userType = 'Member' } }
        if ($Method -eq 'GET' -and $Path -match '^/users\?') {
            # Directory list/filter model for the resolver: exact displayName/mailNickname, startsWith(displayName), $top, optional server paging.
            if ($model.Fault -eq 'UserList403') { throw (New-GraphStubError 403) }
            if ($model.Fault -eq 'UserListTimeout') { throw [InvalidOperationException]::new('simulated timeout') }
            $query = @{}
            foreach ($part in ($Path.Substring(7) -split '&')) { $kv = $part -split '=', 2; $query[[uri]::UnescapeDataString($kv[0])] = $(if ($kv.Count -gt 1) { [uri]::UnescapeDataString($kv[1]) } else { '' }) }
            $filter = [string]$query['$filter']
            $nick = { param($p) if ($p.Contains('mailNickname')) { [string]$p.mailNickname } else { ([string]$p.userPrincipalName -split '@')[0] } }
            $hits = @($model.Users.Keys | Sort-Object | Where-Object {
                $p = $model.Users[$_].Profile
                if (-not $p.Contains('userPrincipalName') -or -not $p.Contains('displayName')) { return $false }
                if (-not $filter) { return $true }
                foreach ($clause in ($filter -split ' or ')) {
                    if ($clause -match '^(displayName|mailNickname) eq ''(.*)''$') {
                        $value = if ($Matches[1] -eq 'displayName') { [string]$p.displayName } else { & $nick $p }
                        if ($value -ieq $Matches[2].Replace("''", "'")) { return $true }
                    } elseif ($clause -match '^startsWith\((displayName|mailNickname),''(.*)''\)$') {
                        $value = if ($Matches[1] -eq 'displayName') { [string]$p.displayName } else { & $nick $p }
                        if ($value.StartsWith($Matches[2].Replace("''", "'"), [StringComparison]::OrdinalIgnoreCase)) { return $true }
                    } else { throw "Unsupported offline filter: $clause" }
                }
                return $false
            })
            $top = $(if ($query.ContainsKey('$top')) { [int]$query['$top'] } else { 100 })
            $size = $(if ($model.PageSize) { [Math]::Min($top, [int]$model.PageSize) } else { $top })
            $skip = $(if ($query.ContainsKey('$skiptoken')) { [int]$query['$skiptoken'] } else { 0 })
            $items = @($hits | Select-Object -Skip $skip -First $size | ForEach-Object {
                $p = $model.Users[$_].Profile
                @{ id = $p.id; userPrincipalName = $p.userPrincipalName; displayName = $p.displayName; mailNickname = (& $nick $p)
                    accountEnabled = $(if ($p.Contains('accountEnabled')) { $p.accountEnabled } else { $null }); userType = $(if ($p.Contains('userType')) { $p.userType } else { $null })
                    onPremisesSyncEnabled = $(if ($p.Contains('onPremisesSyncEnabled')) { $p.onPremisesSyncEnabled } else { $null }) }
            })
            $result = @{ value = [object[]]$items }
            if ($skip + $size -lt $hits.Count) {
                $base = (($Path.Substring(7) -split '&') | Where-Object { $_ -notmatch '^\$skiptoken=' }) -join '&'
                $result['@odata.nextLink'] = "https://graph.microsoft.com/v1.0/users?$base&`$skiptoken=$($skip + $size)"
            }
            return $result
        }
        if ($Path -match '^/users/([^/?]+)(/[^?]*)?(\?.*)?$') {
            $key = [uri]::UnescapeDataString($Matches[1]); $tail = [string]$Matches[2]; $query = [string]$Matches[3]
            $id = $null
            if ($model.Users.ContainsKey($key)) { $id = $key }
            else { $found = @($model.Users.Keys | Where-Object { $model.Users[$_].Profile.userPrincipalName -ieq $key }); if ($found.Count -eq 1) { $id = $found[0] } }
            if ($null -eq $id) { throw (New-GraphStubError 404) }
            $u = $model.Users[$id]
            if ($Method -eq 'GET' -and $tail -eq '') {
                if ($query -eq '?$select=id,userPrincipalName' -and $model.Fault -eq 'ExactUpn403') { throw (New-GraphStubError 403) }
                if ($query -eq '?$select=id,userPrincipalName' -and $model.Fault -eq 'ExactUpnTimeout') { throw [InvalidOperationException]::new('simulated timeout') }
                if ($query -eq '?$select=id,userPrincipalName') { return @{ id = $id; userPrincipalName = $u.Profile.userPrincipalName } }
                if ($query -eq '?$select=id,displayName,userPrincipalName') { return @{ id = $id; displayName = $u.Profile.displayName; userPrincipalName = $u.Profile.userPrincipalName } }
                $p = Copy-PersonaTestValue $u.Profile
                if ($model.Fault -eq 'ChangedId' -and $id -eq $model.Ids.bob) { $p.id = $model.PresenterId }
                return $p
            }
            if ($Method -eq 'GET' -and $tail -eq '/manager') {
                if ($null -eq $u.Manager) { throw (New-GraphStubError 404) }
                return @{ id = $u.Manager }
            }
            if ($Method -eq 'GET' -and $tail -eq '/transitiveMemberOf') {
                $groups = [object[]]@()
                if ($model.Groups.ContainsKey($id)) { $groups = [object[]]@($model.Groups[$id]) }
                return @{ value = $groups }
            }
            if ($Method -eq 'PATCH' -and $tail -eq '') {
                if ($model.Fault -ne 'IgnorePatch') { foreach ($k in $Body.Keys) { $u.Profile[$k] = $Body[$k] } }
                if ($model.Fault -eq 'UnknownPatch') { throw (New-GraphStubError 503) }
                if ($null -ne $model.AfterWrite) { & $model.AfterWrite $Method $Path }
                return $null
            }
            if ($Method -eq 'PUT' -and $tail -eq '/manager/$ref') {
                $u.Manager = ($Body['@odata.id'] -split '/')[-1]
                if ($null -ne $model.AfterWrite) { & $model.AfterWrite $Method $Path }
                return $null
            }
        }
        throw "Unconfigured offline request: $Method $Path"
    }.GetNewClosure()
    $ctx = @{ TenantId = $c.tenantId; ClientId = $c.adminAuth.clientId; Account = $c.adminAuth.adminOperatorUpn; AuthType = 'Delegated'; ContextScope = 'Process'
        Scopes = @(Get-SeedAdminScopes -Mode InitializePersonas -AccountSource Existing) }
    $context = { $ctx }.GetNewClosure()
    $s = New-PersonaAppTestSession $c $transport
    @{ Config = $c; Model = $model; Session = $s; Context = $ctx; Folder = $folder; Host = [SeedTestHost]::new() }
}
function Get-ExistingTestPlan($E) { Get-SeedPersonaPlan -Session $E.Session -Config $E.Config }
function Invoke-ExistingTestPlan($E, $P, [switch]$WithoutAcknowledgement) {
    $arguments = @{ Session = $E.Session; Plan = $P; ConfirmTarget = $P.Target; ConfirmPlanFingerprint = $P.Fingerprint; ConsoleHost = $E.Host; NonInteractive = $true }
    if (-not $WithoutAcknowledgement) { $arguments.DemoAccountAcknowledged = $true }
    Invoke-InitializePersonas @arguments 6>$null
}
function Get-ExistingTestWrites($E) { , @($E.Model.Ledger | Where-Object Method -ne GET) }
function Get-ExistingResolverPack($E) { Get-Content -LiteralPath $E.Config.personas.packPath -Raw | ConvertFrom-Json -AsHashtable }
function Invoke-ExistingResolver($E, $Selection = $null) {
    Resolve-SeedExistingAccountMappings -Session $E.Session -Config $E.Config -Personas (Get-ExistingResolverPack $E) -Selection $Selection
}
function Add-ExistingDirectoryUser($E, [string]$Id, [string]$Upn, [string]$DisplayName, [hashtable]$Extra = @{}) {
    $p = @{ id = $Id; userPrincipalName = $Upn; displayName = $DisplayName; jobTitle = $null; department = $null; companyName = $null; officeLocation = $null; usageLocation = 'US'
        accountEnabled = $true; userType = 'Member'; onPremisesSyncEnabled = $null; assignedLicenses = @(); licenseAssignmentStates = @() }
    foreach ($key in $Extra.Keys) { $p[$key] = $Extra[$key] }
    $E.Model.Users[$Id] = @{ Manager = $null; Profile = $p }
}
function Get-ExistingDirectoryReads($E, [int]$Since = 0) { , @($E.Model.Ledger | Select-Object -Skip $Since | Where-Object { $_.Path -match '^/users\?' }) }
function Save-ExistingTestConfig($E) {
    # The operator's private config file as the console reads it; the runtime-only adminAuth stays out of it.
    $E.ConfigFile = Join-Path $E.Folder 'config.json'
    $raw = Copy-PersonaTestValue $E.Config; $raw.Remove('adminAuth')
    $raw | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $E.ConfigFile -Encoding utf8
    $E.ConfigHash = (Get-FileHash -LiteralPath $E.ConfigFile -Algorithm SHA256).Hash
}
function New-ExistingCorrectionEnvironment {
    # bob's configured UPN no longer exists, but exactly one account has bob's public full name: a proposed correction, planned (not written).
    $e = New-ExistingPersonaTestEnvironment -Count 2
    $e.NewId = '10101010-1010-4010-8010-101010101010'
    $e.Model.Users.Remove($e.Model.Ids.bob)
    Add-ExistingDirectoryUser $e $e.NewId 'bob.test@other.example.invalid' 'Bob Test'
    Save-ExistingTestConfig $e
    $r = Invoke-ExistingResolver $e
    $e.Plan = Get-SeedPersonaPlan -Session $e.Session -Config $r.EffectiveConfig -AccountResolution $r
    $e
}
try {
    Test-Case 'canonical helpers preserve ISO-looking strings rather than local timezone coercion' {
        $original = '2026-10-30T00:00:00.1234000+00:00'
        $copy = ConvertTo-SeedMap @{ at = $original }
        Assert-True ($copy.at -is [string])
        Assert-Equal $copy.at $original
        $child = Invoke-SeedPython -Code 'import json,sys; print(json.dumps(json.load(sys.stdin)))' -InputObject @{ at = $original }
        Assert-True ($child.at -is [string])
        Assert-Equal $child.at $original
    }
    Test-Case 'persona APIs exist without authentication on load' {
        foreach ($name in @('Get-SeedPersonaPlan', 'Invoke-InitializePersonas', 'Invoke-InspectUsers')) {
            Assert-True ([bool](Get-Command $name -ErrorAction SilentlyContinue)) "T2A API missing: $name"
        }
    }
    Test-Case 'whole batch seat arithmetic covers 24 personas without charging existing Presenter' {
        $sku = '33333333-3333-4333-8333-333333333333'
        $sub = @(@{ skuId = $sku; capabilityStatus = 'Enabled'; consumedUnits = 1; prepaidUnits = @{ enabled = 25 } })
        $seats = @(Get-SeedPersonaSeatPlan -Requirements @{ $sku = 24 } -Subscriptions $sub)
        Assert-Equal $seats[0].Required 24; Assert-Equal $seats[0].RemainingAfter 0
        $sub[0].prepaidUnits.enabled = 24
        Assert-Throws { Get-SeedPersonaSeatPlan -Requirements @{ $sku = 24 } -Subscriptions $sub } 'Seed.Persona.Seats' | Out-Null
    }
    Test-Case 'inspect lists every account readonly and never implies optional checks' {
        $e = New-PersonaTestEnvironment
        $r = Invoke-InspectUsers -Session $e.Session -PresenterUpn $e.Config.presenterUpn
        Assert-Equal @($r.Users).Count 1; Assert-True $r.Users[0].IsPresenter
        Assert-Equal $r.Users[0].PhotoStatus 'NotChecked'
        Assert-NoPersonaWrites $e
    }
    Test-Case 'canonical pack full preview capacity and binding server evidence' {
        $e = New-PersonaTestEnvironment; $p = Get-PersonaTestPlan $e
        Assert-Equal @($p.Preview.Rows).Count 2
        Assert-Equal $p.Preview.Seats[0].Required 2
        Assert-Equal $p.Preview.Seats[0].Remaining 100
        Assert-True (@($p.Preview.Rows[0].Diff).Count -ge 8)
        $r = Invoke-PersonaTestPlan $e $p
        Assert-Equal $r.Created 2; Assert-Equal $r.ServiceStatus 'NotVerified'
        $binding = Get-Content -LiteralPath $e.Config.personas.bindingPath -Raw | ConvertFrom-Json -AsHashtable
        Assert-SeedSchema $binding persona-binding
        Assert-Equal $binding.users.bob.profile.managerObjectId $binding.users.alice.objectId
        Assert-True ($binding.users.alice.photo.verifiedSha256 -ne $binding.users.alice.photo.sourceSha256)
        Assert-True ($e.Model.InitialValues[0] -cne $e.Model.InitialValues[1])
        foreach ($v in $e.Model.InitialValues) {
            Assert-True ($v.Length -ge 24 -and $v -cmatch '[A-Z]' -and $v -cmatch '[a-z]' -and $v -match '\d' -and $v -match '[^A-Za-z0-9]')
            foreach ($file in @(Get-ChildItem -LiteralPath $e.Folder -File | Where-Object Extension -eq '.json')) {
                Assert-True (-not (Get-Content -LiteralPath $file.FullName -Raw).Contains($v))
            }
        }
        $writes = @($e.Model.Ledger | Where-Object Method -ne GET)
        Assert-Equal $writes[0].Path '/users'; Assert-Equal $writes[1].Path '/users'
        Assert-True (@($writes | Where-Object { $_.Path -match $e.Model.PresenterId -or $_.Path -match 'role|purchase|mail' }).Count -eq 0)
        foreach ($w in @($writes | Where-Object Path -like '*/assignLicense')) { Assert-Equal @($w.Body.removeLicenses).Count 0 }
        $e.Model.Ledger.Clear()
        $againPlan = Get-PersonaTestPlan $e
        $again = Invoke-PersonaTestPlan $e $againPlan
        Assert-Equal $again.Skipped 2; Assert-NoPersonaWrites $e
        Assert-True $script:SeedPersonaPlans[$againPlan.PlanId].Used
        Assert-Equal (Get-SeedSessionRecord $e.Session).PersonaPlanId $null
    }
    Test-Case 'fake plans edited previews App and Inspect sessions cannot obtain provisioning authority' {
        $e = New-PersonaTestEnvironment; $p = Get-PersonaTestPlan $e
        $fake = $p | ConvertTo-Json -Depth 100 | ConvertFrom-Json
        Assert-Throws { Invoke-PersonaTestPlan $e $fake } 'Seed.Persona.Plan' | Out-Null
        $p.Preview.Rows[0].Upn = $e.Config.presenterUpn
        Assert-Throws { Invoke-PersonaTestPlan $e $p } 'Seed.Persona.Plan' | Out-Null
        foreach ($mode in @('InspectUsers', 'Import')) {
            $s = New-SeedSessionHandle -Kind $(if ($mode -eq 'Import') { 'App' } else { 'Admin' }) -Mode $mode -TenantId $e.Config.tenantId -ClientId $e.Config.adminAuth.clientId -Operator $e.Config.adminAuth.adminOperatorUpn -Permissions @() -Transport {} -Delay {}
            Assert-Throws { Get-SeedPersonaPlan -Session $s -Config $e.Config } 'Seed.Persona.Session' | Out-Null
            Assert-Throws { Invoke-SeedGraph -Session $s -Method POST -Path '/users' -Body @{} -AdminCapability ([object]::new()) } 'Seed.(Write|Auth)' | Out-Null
        }
        Assert-Throws { Invoke-SeedGraph -Session $e.Session -Method POST -Path '/users' -Body @{} } 'Seed.Write' | Out-Null
        Assert-Throws { Invoke-SeedGraph -Session $e.Session -Method POST -Path '/users' -Body @{} -AdminCapability ([object]::new()) } 'Seed.Write' | Out-Null
        Assert-NoPersonaWrites $e
    }
    Test-Case 'confirmation requires exact target and current fingerprint not just noninteractive' {
        $e = New-PersonaTestEnvironment; $p = Get-PersonaTestPlan $e
        Assert-Throws { Invoke-InitializePersonas -Session $e.Session -Plan $p -NonInteractive 6>$null } 'Seed.Persona.Confirmation' | Out-Null
        Assert-Throws { Invoke-InitializePersonas -Session $e.Session -Plan $p -ConfirmTarget $p.Target -ConfirmPlanFingerprint ('0' * 64) -NonInteractive 6>$null } 'Seed.Persona.Confirmation' | Out-Null
        Assert-NoPersonaWrites $e
    }
    Test-Case 'whole batch blocks unverified domain shortage revoked app role and foreign namespace collisions' {
        foreach ($fault in @('Domain', 'Seats', 'Collision', 'Presenter', 'Scope')) {
            $e = New-PersonaTestEnvironment
            switch ($fault) {
                Domain { $e.Model.DomainVerified = $false }
                Seats { $e.Model.Seats = 1 }
                Role { $e.Model.ActiveRole = $false }
                Collision { $e.Model.Users.x = @{ Profile = @{ id = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'; userPrincipalName = 'demo-alice@example.invalid'; userType = 'Member'; accountEnabled = $true } } }
                Presenter { $e.Config.presenterUpn = 'demo-alice@example.invalid' }
                Scope { (Get-SeedSessionRecord $e.Session).Permissions = @('User.ReadWrite.All') }
            }
            Assert-Throws { Get-PersonaTestPlan $e } 'Seed\.' | Out-Null
            Assert-NoPersonaWrites $e
        }
    }
    Test-Case 'offline validator blocks missing portraits duplicate aliases manager cycles and public secrets' {
        foreach ($fault in @('Missing', 'Duplicate', 'Cycle', 'Secret')) {
            $e = New-PersonaTestEnvironment
            $doc = Get-Content -LiteralPath $e.Config.personas.packPath -Raw | ConvertFrom-Json -AsHashtable
            switch ($fault) {
                Missing { Remove-Item -LiteralPath (Join-Path $e.Folder 'bob.jpg') }
                Duplicate { $doc.people[1].alias = $doc.people[0].alias }
                Cycle { $doc.people[0].managerRef = 'bob' }
                Secret { $doc.password = 'forbidden' }
            }
            $doc | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $e.Config.personas.packPath -Encoding utf8
            Assert-Throws { Get-PersonaTestPlan $e } 'Seed\.' | Out-Null
            Assert-NoPersonaWrites $e
        }
    }
    Test-Case 'changes during confirmation invalidate entire batch before first create' {
        $e = New-PersonaTestEnvironment; $p = Get-PersonaTestPlan $e
        $confirm = { param($Preview, $Target, $Fingerprint) $e.Model.Seats = 1; @{ Target = $Target; PlanFingerprint = $Fingerprint } }.GetNewClosure()
        Assert-Throws { Invoke-InitializePersonas -Session $e.Session -Plan $p -Confirmation $confirm -NonInteractive 6>$null } 'Seed\.' | Out-Null
        Assert-NoPersonaWrites $e
    }
    Test-Case 'unknown create is durable redacted terminal and never adopted by matching UPN' {
        $e = New-PersonaTestEnvironment; $e.Model.Fault = 'UnknownCreate'
        $p = Get-PersonaTestPlan $e
        $printed = [Collections.Generic.List[string]]::new()
        $message = Assert-Throws {
            Invoke-InitializePersonas -Session $e.Session -Plan $p -ConfirmTarget $p.Target -ConfirmPlanFingerprint $p.Fingerprint -NonInteractive 6>&1 |
                ForEach-Object { $printed.Add($_.ToString()) }
        } 'Seed.Persona'
        Assert-True ($message -notmatch 'SECRET')
        Assert-True (($printed -join "`n") -match '"Unknown":1') 'Failure summary must distinguish Unknown from Failed and list counters.'
        $journal = Get-Content -LiteralPath ($e.Config.personas.bindingPath + '.journal.json') -Raw
        Assert-True ($journal -match 'Unknown' -and $journal -notmatch 'password|SECRET')
        $state = $journal | ConvertFrom-Json -AsHashtable
        Assert-Equal $state.plans.Count 1
        Assert-Equal @($state.events | Where-Object status -eq Unknown).Count 1
        Assert-True $script:SeedPersonaPlans[$p.PlanId].Used
        Assert-Equal (Get-SeedSessionRecord $e.Session).PersonaPlanId $null
        foreach ($v in $e.Model.InitialValues) { Assert-True (-not $journal.Contains($v) -and -not $message.Contains($v) -and -not ($printed -join "`n").Contains($v)) }
        Assert-Equal $e.Model.Created 1
        Assert-True (-not (Test-Path -LiteralPath $e.Config.personas.bindingPath))
        $e.Model.Fault = ''
        Assert-Throws { Get-PersonaTestPlan $e } 'Seed.Persona.Journal' | Out-Null
        Assert-Equal $e.Model.Created 1
    }
    Test-Case 'license pending and photo unknown never emit Provisioned binding or retry writes' {
        foreach ($fault in @('LicensePending', 'UnknownPhoto')) {
            $e = New-PersonaTestEnvironment
            if ($fault -eq 'LicensePending') { $e.Model.PendingLicense = $true } else { $e.Model.Fault = $fault }
            $p = Get-PersonaTestPlan $e
            Assert-Throws { Invoke-PersonaTestPlan $e $p } 'Seed.Persona' | Out-Null
            Assert-True (-not (Test-Path -LiteralPath $e.Config.personas.bindingPath))
            Assert-Throws { Get-PersonaTestPlan $e } 'Seed.Persona.Journal' | Out-Null
            $keys = @($e.Model.Ledger | Where-Object { $_.Method -ne 'GET' -and $_.Path -ne '/users' } | ForEach-Object { "$($_.Method) $($_.Path)" })
            Assert-Equal @($keys | Sort-Object -Unique).Count $keys.Count
        }
    }
    Test-Case 'proven correction requires new diff approval never resets credentials or touches existing license settings' {
        $e = New-PersonaTestEnvironment; Complete-PersonaTestEnvironment $e | Out-Null
        $doc = Get-Content -LiteralPath $e.Config.personas.packPath -Raw | ConvertFrom-Json -AsHashtable
        $doc.people[0].jobTitle = 'New Lead'
        $doc | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $e.Config.personas.packPath -Encoding utf8
        $e.Model.Ledger.Clear()
        $p = Get-PersonaTestPlan $e
        Assert-Equal $p.Preview.Rows[0].Action 'Update'
        Assert-True (@($p.Preview.Rows[0].Diff | Where-Object Field -eq jobTitle).Count -eq 1)
        $r = Invoke-PersonaTestPlan $e $p
        Assert-Equal $r.Updated 1; Assert-Equal $r.Skipped 1
        $w = @($e.Model.Ledger | Where-Object Method -ne GET)
        Assert-Equal $w.Count 1; Assert-Equal $w[0].Method 'PATCH'
        Assert-Equal @($w[0].Body.Keys) @('jobTitle')
    }
    Test-Case 'unknown managed correction preserves prior binding and cannot automatically resume' {
        $e = New-PersonaTestEnvironment; Complete-PersonaTestEnvironment $e | Out-Null
        $oldHash = (Get-FileHash -LiteralPath $e.Config.personas.bindingPath).Hash
        $e.Model.Users['aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'].Profile.jobTitle = 'Drift'
        $e.Model.Ledger.Clear(); $p = Get-PersonaTestPlan $e
        $e.Model.Fault = 'UnknownPatch'
        Assert-Throws { Invoke-PersonaTestPlan $e $p } 'Seed.Persona.Blocked' | Out-Null
        Assert-Equal (Get-FileHash -LiteralPath $e.Config.personas.bindingPath).Hash $oldHash
        Assert-Equal @($e.Model.Ledger | Where-Object Method -eq PATCH).Count 1
        $e.Model.Fault = ''
        Assert-Throws { Get-PersonaTestPlan $e } 'Seed.Persona.Journal' | Out-Null
    }
    Test-Case 'fresh snapshots before each write stop concurrent profile drift without overwriting it' {
        $e = New-PersonaTestEnvironment; $p = Get-PersonaTestPlan $e
        $e.Model.Fault = 'DriftAfterPhoto'
        Assert-Throws { Invoke-PersonaTestPlan $e $p } 'Seed.Persona.Blocked' | Out-Null
        $bob = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
        Assert-Equal $e.Model.Users[$bob].Profile.department 'Concurrent change'
        Assert-Equal @($e.Model.Ledger | Where-Object { $_.Method -ne 'GET' -and $_.Path -match $bob }).Count 0
    }
    Test-Case 'accepted but ignored photo correction cannot bind stale server bytes to approved source' {
        $e = New-PersonaTestEnvironment; Complete-PersonaTestEnvironment $e | Out-Null
        $alice = $e.Model.Users['aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa']
        $alice.Photo = [byte[]](@($alice.Photo) + @(0))
        $oldHash = (Get-FileHash -LiteralPath $e.Config.personas.bindingPath).Hash
        $p = Get-PersonaTestPlan $e
        $e.Model.Fault = 'IgnorePhoto'
        Assert-Throws { Invoke-PersonaTestPlan $e $p } 'Seed.Persona.Blocked' | Out-Null
        Assert-Equal (Get-FileHash -LiteralPath $e.Config.personas.bindingPath).Hash $oldHash
        Assert-Throws { Get-PersonaTestPlan $e } 'Seed.Persona.Journal' | Out-Null
    }
    Test-Case 'binding alone and foreign pack instance namespace never prove existing managed identities' {
        $e = New-PersonaTestEnvironment; Complete-PersonaTestEnvironment $e | Out-Null
        $e.Model.Ledger.Clear()
        foreach ($field in @('instanceId', 'accountPrefix', 'userDomain')) {
            $changed = Copy-PersonaTestValue $e.Config
            $changed.personas[$field] = $(if ($field -eq 'userDomain') { 'foreign.invalid' } else { 'foreign' })
            Assert-Throws { Get-SeedPersonaPlan -Session $e.Session -Config $changed } 'Seed.Persona.Journal' | Out-Null
        }
        Remove-Item -LiteralPath ($e.Config.personas.bindingPath + '.journal.json')
        Assert-Throws { Get-PersonaTestPlan $e } 'Seed.Persona.Journal' | Out-Null
        Assert-NoPersonaWrites $e
    }
    Test-Case 'managed UID replacement photo 403 licensed country drift and unmanaged manager removal block' {
        foreach ($fault in @('ChangedId', 'PhotoForbidden', 'Country', 'RemoveManager', 'ForeignBinding')) {
            $e = New-PersonaTestEnvironment; Complete-PersonaTestEnvironment $e | Out-Null
            $e.Model.Ledger.Clear()
            switch ($fault) {
                ChangedId { $e.Model.Fault = $fault }
                PhotoForbidden { $e.Model.Fault = $fault }
                Country { $e.Model.Users['aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'].Profile.usageLocation = 'US' }
                RemoveManager {
                    $doc = Get-Content -LiteralPath $e.Config.personas.packPath -Raw | ConvertFrom-Json -AsHashtable
                    $doc.people[1].managerRef = $null
                    $doc | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $e.Config.personas.packPath
                }
                ForeignBinding {
                    $b = Get-Content -LiteralPath $e.Config.personas.bindingPath -Raw | ConvertFrom-Json -AsHashtable
                    $b.tenantId = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'
                    $b | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $e.Config.personas.bindingPath
                }
            }
            $pattern = switch ($fault) {
                ChangedId { 'Seed.Persona.ReadBack' }
                PhotoForbidden { 'Seed.Graph.403' }
                Country { 'Seed.Persona.Location' }
                RemoveManager { 'Seed.Persona.Manager' }
                ForeignBinding { 'Seed.Persona.Journal' }
            }
            Assert-Throws { Get-PersonaTestPlan $e } $pattern | Out-Null
            Assert-NoPersonaWrites $e
        }
    }
    Test-Case 'Existing batch updates only four profile fields and manager, reads back all N accounts, and binds without seats domains inventory photos or licenses' {
        foreach ($count in @(1, 3, 5)) {
            $e = New-ExistingPersonaTestEnvironment -Count $count
            $before = @{}; foreach ($id in $e.Model.Users.Keys) { $before[$id] = Copy-PersonaTestValue $e.Model.Users[$id].Profile }
            $p = Get-ExistingTestPlan $e
            Assert-Equal @($p.Preview.Rows).Count $count
            Assert-Equal @($p.Preview.Rows | Where-Object Action -ne Update).Count 0
            Assert-True (-not $p.Preview.Contains('Inventory') -and -not $p.Preview.Contains('Seats'))
            Assert-Equal $p.Preview.AccountSource 'Existing'
            Assert-True (-not $p.Preview.Contains('PimGroupEligibility')) 'The tool no longer claims anything about target roles or PIM eligibility.'
            Assert-Equal @($e.Model.Ledger | Where-Object { $_.Path -match '^/domains|subscribedSkus|^/users\?|assignLicense|/photo|/users/[^/?]+$' -and $_.Method -ne 'GET' }).Count 0
            foreach ($name in $e.Config.personas.accountMappings.Keys) { Assert-True (@($e.Model.Ledger | Where-Object { $_.Path -like "*existing-$name%40*" }).Count -ge 1) "$name was not read." }
            Assert-NoPersonaWrites $e
            $r = Invoke-ExistingTestPlan $e $p
            Assert-Equal $r.Status 'ConfiguredExisting'; Assert-Equal $r.Created 0; Assert-Equal $r.Updated $count; Assert-Equal $r.Selected $count; Assert-Equal $r.Failed 0
            $writes = Get-ExistingTestWrites $e
            Assert-Equal @($writes | Where-Object { $_.Method -ne 'PATCH' -and $_.Method -ne 'PUT' }).Count 0
            foreach ($w in @($writes | Where-Object Method -eq PATCH)) { foreach ($key in $w.Body.Keys) { Assert-True ($key -in @('jobTitle', 'department', 'companyName', 'officeLocation')) "Unexpected field $key" } }
            Assert-Equal @($writes | Where-Object { $_.Method -eq 'PUT' -and $_.Path -notmatch '/manager/\$ref$' }).Count 0
            Assert-Equal @($writes | Where-Object { $_.Path -match 'photo|assignLicense|^/users$' }).Count 0
            Assert-Equal @($writes | Where-Object { $_.Method -eq 'PUT' }).Count ([Math]::Max(0, $count - 1)) 'Only explicit same-batch managers are written.'
            foreach ($id in $before.Keys) {
                foreach ($kept in @('displayName', 'userPrincipalName', 'usageLocation', 'accountEnabled', 'userType', 'assignedLicenses', 'licenseAssignmentStates')) { Assert-Equal $e.Model.Users[$id].Profile[$kept] $before[$id][$kept] }
            }
            Assert-Equal $e.Model.Users[$e.Model.ExternalId].Profile.displayName 'External Boss'
            Assert-Equal $e.Model.Users[$e.Model.Ids.alice].Manager $e.Model.ExternalId 'An outside manager that is not explicitly replaced is kept.'
            $binding = Get-Content -LiteralPath $e.Config.personas.bindingPath -Raw | ConvertFrom-Json -AsHashtable
            Assert-SeedSchema $binding persona-binding
            Assert-Equal $binding.status 'ConfiguredExisting'; Assert-Equal $binding.version '1.1'; Assert-Equal $binding.users.Count $count
            Assert-True $binding.approval.demoAccountAcknowledged; Assert-Equal $binding.approval.planFingerprint $p.Fingerprint
            foreach ($name in $binding.users.Keys) {
                $profile = $binding.users[$name].profile
                $raw = @{}; foreach ($f in @('displayName', 'jobTitle', 'department', 'companyName', 'officeLocation', 'usageLocation', 'managerObjectId')) { $raw[$f] = $profile[$f] }
                Assert-Equal (Get-SeedFingerprint $raw) $profile.sha256
            }
            Assert-Equal $binding.users.alice.profile.managerObjectId $e.Model.ExternalId
            $journal = Get-Content -LiteralPath ($e.Config.personas.bindingPath + '.journal.json') -Raw | ConvertFrom-Json -AsHashtable
            Assert-Equal $journal.status 'Completed'; Assert-True (-not $journal.Contains('createdIds'))
            Assert-Equal @($journal.events | Where-Object kind -eq BindExisting).Count $count
            Assert-Equal @($journal.events | Where-Object kind -eq Create).Count 0
            Assert-Equal @($journal.events | Where-Object status -ne Verified).Count 0
            $e.Model.Ledger.Clear()
            $again = Get-ExistingTestPlan $e
            Assert-Equal @($again.Preview.Rows | Where-Object Action -ne Keep).Count 0
            $second = Invoke-ExistingTestPlan $e $again
            Assert-Equal $second.Skipped $count; Assert-Equal $second.Updated 0
            Assert-NoPersonaWrites $e
        }
    }
    Test-Case 'Existing whole batch is blocked by one bad account: guest synced disabled missing or changed ID write nothing' {
        foreach ($fault in @('Guest', 'Synced', 'Disabled', 'NotFound', 'NullDisplayName', 'BadUsageLocation', 'BadFieldType')) {
            $e = New-ExistingPersonaTestEnvironment -Count 3
            $last = $e.Model.Ids.carol; $profile = $e.Model.Users[$last].Profile
            switch ($fault) {
                Guest { $profile.userType = 'Guest' }
                Synced { $profile.onPremisesSyncEnabled = $true }
                Disabled { $profile.accountEnabled = $false }
                NotFound { $e.Model.Users.Remove($last) }
                NullDisplayName { $profile.displayName = $null }
                BadUsageLocation { $profile.usageLocation = 'tw' }
                BadFieldType { $profile.jobTitle = 7 }
            }
            $p = Get-ExistingTestPlan $e
            $bad = @($p.Preview.Rows | Where-Object Action -eq Block)
            Assert-Equal $bad.Count 1 $fault
            Assert-Equal $bad[0].PersonaId 'carol'
            Assert-Equal @($p.Preview.Rows | Where-Object Action -eq Update).Count 2
            $called = $false
            $confirm = { param($Preview, $Target, $Fingerprint) $script:confirmCalled = $true; @{ Target = $Target; PlanFingerprint = $Fingerprint; DemoAccountAcknowledged = $true } }
            $script:confirmCalled = $false
            Assert-Throws { Invoke-InitializePersonas -Session $e.Session -Plan $p -Confirmation $confirm -ConsoleHost $e.Host -NonInteractive 6>$null } 'Seed.Persona.Blocked' | Out-Null
            Assert-True (-not $script:confirmCalled) "$fault reached confirmation."
            Assert-NoPersonaWrites $e
            Assert-True (-not (Test-Path -LiteralPath $e.Config.personas.bindingPath)); Assert-True (-not (Test-Path -LiteralPath ($e.Config.personas.bindingPath + '.journal.json')))
            $text = $e.Host.Terminal.Lines.ToArray() -join "`n"
            Assert-True ($text -match '\[Blocked\] persona=carol reason=Seed\.Persona\.' -and $text -notmatch '\[Warning\]' -and $text -notmatch 'PlanFingerprint:') "$fault must only show the block."
        }
    }
    Test-Case 'Existing Presenter operator duplicate unmapped-manager and unknown persona selections stop before any Graph read' {
        foreach ($fault in @('Presenter', 'Operator', 'Duplicate', 'ManagerNotSelected', 'UnknownPersona')) {
            $e = New-ExistingPersonaTestEnvironment -Count 2
            $maps = $e.Config.personas.accountMappings
            switch ($fault) {
                Presenter { $maps.bob = $e.Config.presenterUpn }
                Operator { $e.Config.adminAuth.adminOperatorUpn = 'existing-bob@example.invalid' }
                Duplicate { $maps.bob = $maps.alice }
                ManagerNotSelected { $maps.Remove('alice') }
                UnknownPersona { $maps.nobody = 'existing-nobody@example.invalid' }
            }
            $e.Model.Ledger.Clear()
            Assert-Throws { Get-ExistingTestPlan $e } 'Seed.Persona.(Presenter|Selection|Manager)' | Out-Null
            Assert-Equal $e.Model.Ledger.Count 0 "$fault read the tenant."
        }
    }
    Test-Case 'Existing targets and managers holding direct, eligible, group or directory roles are planned like any selected account without any target role or membership query' {
        $e = New-ExistingPersonaTestEnvironment -Count 3
        $group = '77777777-7777-4777-8777-777777777777'
        $e.Model.Roles[$e.Model.Ids.alice] = @{ roleAssignments = @(@{ principalId = $e.Model.Ids.alice; roleDefinitionId = 'x'; directoryScopeId = '/' }) }
        $e.Model.Roles[$e.Model.Ids.bob] = @{ roleEligibilityScheduleInstances = @(@{ principalId = $e.Model.Ids.bob; roleDefinitionId = 'x'; directoryScopeId = '/' }) }
        $e.Model.Groups[$e.Model.Ids.carol] = @(@{ '@odata.type' = '#microsoft.graph.group'; id = $group }, @{ '@odata.type' = '#microsoft.graph.directoryRole'; id = '66666666-6666-4666-8666-666666666666' })
        $e.Model.Roles[$group] = @{ roleAssignments = @(@{ principalId = $group; roleDefinitionId = 'x'; directoryScopeId = '/' }) }
        $e.Model.Fault = 'RoleQuery403'
        $p = Get-ExistingTestPlan $e
        Assert-Equal @($p.Preview.Rows | Where-Object Action -eq Block).Count 0
        Assert-Equal @($p.Preview.Rows | Where-Object Action -eq Update).Count 3
        Assert-Equal @($e.Model.Ledger | Where-Object { $_.Path -match 'transitiveMemberOf|roleEligibilitySchedule|^/roleManagement' -and $_.Path -notmatch $e.Model.OperatorId }).Count 0 'Only the signed-in operator is checked for a role; no target, manager or group role query may exist.'
        Assert-True (-not $p.Preview.Contains('PimGroupEligibility'))
        $r = Invoke-ExistingTestPlan $e $p
        Assert-Equal $r.Status 'ConfiguredExisting'; Assert-Equal $r.Updated 3
        $text = $e.Host.Terminal.Lines.ToArray() -join "`n"
        Assert-True ($text -notmatch 'PIM|non-administrative|非管理') 'No false PIM or non-administrator claim may remain in the shared renderer.'
        $writes = Get-ExistingTestWrites $e
        Assert-Equal @($writes | Where-Object { $_.Method -notin @('PATCH', 'PUT') -or $_.Path -notmatch '^/users/[0-9a-f-]{36}(/manager/\$ref)?$' }).Count 0
        Assert-Equal @($writes | Where-Object { $_.Method -eq 'PUT' }).Count 2
        $journal = Get-Content -LiteralPath ($e.Config.personas.bindingPath + '.journal.json') -Raw | ConvertFrom-Json -AsHashtable
        Assert-Equal $journal.status 'Completed'
        Assert-Equal @($journal.events | Where-Object { $_.kind -in @('Profile', 'Manager') -and $_.status -eq 'Verified' }).Count 5
    }
    Test-Case 'Existing real manager problems still block: a manager that is not a valid enabled Member blocks its subordinates for that real reason while roles never do' {
        $e = New-ExistingPersonaTestEnvironment -Count 3
        $e.Model.Roles[$e.Model.Ids.bob] = @{ roleAssignments = @(@{ principalId = $e.Model.Ids.bob; roleDefinitionId = 'x'; directoryScopeId = '/' }) }
        $e.Model.Users[$e.Model.Ids.alice].Profile.userType = 'Guest'
        $p = Get-ExistingTestPlan $e
        $byId = @{}; foreach ($row in $p.Preview.Rows) { $byId[$row.PersonaId] = $row }
        Assert-Equal $byId.alice.BlockReason 'Seed.Persona.Identity'
        Assert-Equal $byId.bob.BlockReason 'Seed.Persona.Manager'; Assert-Equal $byId.carol.BlockReason 'Seed.Persona.Manager'
        Assert-Throws { Invoke-ExistingTestPlan $e $p } 'Seed.Persona.Blocked' | Out-Null
        Assert-NoPersonaWrites $e
    }
    Test-Case 'Existing revoked application write role stops before any selected account is read' {
        $e = New-ExistingPersonaTestEnvironment -Count 2
        (Get-SeedSessionRecord $e.Session).Permissions = @('User.Read.All')
        Assert-Throws { Get-ExistingTestPlan $e } 'Seed.Persona.Scope' | Out-Null
        Assert-Equal @($e.Model.Ledger | Where-Object { $_.Path -like '/users/*' }).Count 0 'The operator gate must run before the selected accounts are read.'
        Assert-NoPersonaWrites $e
    }
    Test-Case 'app-only renewal failure before initialization leaves no journal binding write or Unknown' {
        foreach ($source in @('Managed','Existing')) {
            $e = if ($source -ceq 'Managed') { New-PersonaTestEnvironment } else { New-ExistingPersonaTestEnvironment -Count 2 }
            $p = Get-PersonaTestPlan $e
            $auth = (Get-SeedSessionRecord $e.Session).AppAuth
            $confirm = {
                param($preview,$target,$fingerprint)
                $auth.ExpiresAt = 0; $auth.Acquire = { throw 'private acquisition failure' }
                @{ Target = $target; PlanFingerprint = $fingerprint; DemoAccountAcknowledged = $true }
            }.GetNewClosure()
            Assert-Throws { Invoke-InitializePersonas -Session $e.Session -Plan $p -Confirmation $confirm -NonInteractive 6>$null } 'Seed.Auth.Acquire' | Out-Null
            Assert-NoPersonaWrites $e
            Assert-True (-not (Test-Path -LiteralPath ($e.Config.personas.bindingPath + '.journal.json')))
            Assert-True (-not (Test-Path -LiteralPath $e.Config.personas.bindingPath))
            Assert-True (-not $script:SeedPersonaPlans[$p.PlanId].Used)
            Assert-Equal (Get-SeedSessionRecord $e.Session).PersonaPlanId $p.PlanId
            $null = Get-SeedPersonaSavedPlan -Session $e.Session -Plan $p -ForWrite
        }
    }
    foreach ($source in @('Managed', 'Existing')) {
        Test-Case "$source second readiness failure preserves the original authentic plan before submission" {
            $e = if ($source -ceq 'Managed') { New-PersonaTestEnvironment } else { New-ExistingPersonaTestEnvironment -Count 2 }
            if ($source -ceq 'Existing') {
                $null = Invoke-ExistingTestPlan $e (Get-ExistingTestPlan $e)
                $e.Model.Users[$e.Model.Ids.bob].Profile.jobTitle = 'Correction needed'
                $e.Model.Ledger.Clear()
            }
            $p = Get-PersonaTestPlan $e
            $record = Get-SeedSessionRecord $e.Session
            $saved = Get-SeedPersonaSavedPlan -Session $e.Session -Plan $p -ForWrite
            $expiresAt = $record.AppAuth.ExpiresAt
            $journalPath = $e.Config.personas.bindingPath + '.journal.json'
            $journalHash = if (Test-Path -LiteralPath $journalPath) { (Get-FileHash -LiteralPath $journalPath).Hash } else { $null }
            $bindingHash = if (Test-Path -LiteralPath $e.Config.personas.bindingPath) { (Get-FileHash -LiteralPath $e.Config.personas.bindingPath).Hash } else { $null }
            $checks = @{ InitialPassed = 0; WriteChecks = 0 }
            $originalReadiness = ${function:Assert-SeedAppSessionReady}
            function Assert-SeedAppSessionReady {
                param($Session)
                $caller = @(Get-PSCallStack)[1].FunctionName
                if ($caller -ceq 'Invoke-InitializePersonas') {
                    & $originalReadiness $Session
                    $checks.InitialPassed++
                    return
                }
                if ($caller -ceq 'Invoke-SeedGraph' -and (Get-Variable -Name Method -Scope 1 -ValueOnly) -cne 'GET') {
                    $checks.WriteChecks++
                    $record.AppAuth.ExpiresAt = 0
                    $record.AppAuth.Acquire = { throw 'synthetic second-readiness renewal failure' }
                }
                & $originalReadiness $Session
            }
            try {
                $arguments = @{ Session = $e.Session; Plan = $p; ConfirmTarget = $p.Target; ConfirmPlanFingerprint = $p.Fingerprint; NonInteractive = $true }
                if ($source -ceq 'Existing') { $arguments.DemoAccountAcknowledged = $true; $arguments.ConsoleHost = $e.Host }
                Assert-Throws { Invoke-InitializePersonas @arguments 6>$null } 'Seed.Auth.Acquire' | Out-Null
            } finally { Set-Item -Path Function:\Assert-SeedAppSessionReady -Value $originalReadiness }
            Assert-Equal $checks.InitialPassed 1
            Assert-Equal $checks.WriteChecks 1
            Assert-NoPersonaWrites $e
            Assert-Equal $(if (Test-Path -LiteralPath $journalPath) { (Get-FileHash -LiteralPath $journalPath).Hash } else { $null }) $journalHash
            Assert-Equal $(if (Test-Path -LiteralPath $e.Config.personas.bindingPath) { (Get-FileHash -LiteralPath $e.Config.personas.bindingPath).Hash } else { $null }) $bindingHash
            Assert-True (-not $saved.Used) 'A pre-submission renewal failure must not consume the original caller plan.'
            Assert-Equal $record.PersonaPlanId $p.PlanId
            Assert-True ([object]::ReferenceEquals((Get-SeedPersonaSavedPlan -Session $e.Session -Plan $p -ForWrite), $saved))
            $record.AppAuth.ExpiresAt = $expiresAt
            Assert-Throws { Invoke-InitializePersonas -Session $e.Session -Plan $p -ConfirmTarget $p.Target -NonInteractive 6>$null } 'Seed.Persona.Confirmation' | Out-Null
            if ($source -ceq 'Managed') { $e.Model.Seats-- } else { $e.Model.Users[$e.Model.Ids.bob].Profile.jobTitle = 'Changed after renewal failure' }
            Assert-Throws { Invoke-InitializePersonas @arguments 6>$null } 'Seed.Persona.Changed' | Out-Null
            Assert-NoPersonaWrites $e
            Assert-True (-not $saved.Used)
            Assert-Equal $record.PersonaPlanId $p.PlanId
            $null = Get-SeedPersonaSavedPlan -Session $e.Session -Plan $p -ForWrite
        }
    }
    Test-Case 'Existing manager graph keeps an outside manager and blocks direct, batch and outside-chain cycles' {
        $e = New-ExistingPersonaTestEnvironment -Count 3
        $p = Get-ExistingTestPlan $e
        $alice = @($p.Preview.Rows | Where-Object PersonaId -eq alice)[0]
        Assert-Equal @($alice.Diff | Where-Object Field -eq manager).Count 0
        Assert-True ($alice.Labels.CurrentManager -match 'External Boss <external-boss@example.invalid>')
        $e.Model.Users[$e.Model.ExternalId].Manager = $e.Model.Ids.bob
        $cycle = Get-ExistingTestPlan $e
        Assert-True (@($cycle.Preview.Rows | Where-Object { $_.Action -eq 'Block' -and $_.BlockReason -eq 'Seed.Persona.Manager' }).Count -ge 2)
        Assert-Throws { Invoke-ExistingTestPlan $e $cycle } 'Seed.Persona.Blocked' | Out-Null
        Assert-NoPersonaWrites $e
    }
    Test-Case 'Existing preview checks the whole batch, then warns, lists per-person Before to After, confirms, rechecks and only then writes' {
        $e = New-ExistingPersonaTestEnvironment -Count 3
        $p = Get-ExistingTestPlan $e
        $planned = $e.Model.Ledger.Count
        $seen = @{}
        $confirm = {
            param($Preview, $Target, $Fingerprint)
            $seen.Lines = @($e.Host.Terminal.Lines.ToArray()); $seen.Reads = $e.Model.Ledger.Count
            $seen.Writes = @($e.Model.Ledger | Where-Object Method -ne GET).Count; $seen.Source = $Preview.AccountSource
            @{ Target = $Target; PlanFingerprint = $Fingerprint; DemoAccountAcknowledged = $true }
        }.GetNewClosure()
        $null = Invoke-InitializePersonas -Session $e.Session -Plan $p -Confirmation $confirm -ConsoleHost $e.Host -NonInteractive 6>$null
        Assert-Equal $seen.Writes 0; Assert-Equal $seen.Reads $planned; Assert-Equal $seen.Source 'Existing'
        $text = $seen.Lines -join "`n"
        $order = @('[PersonaSetup] Source=Existing', '[Warning] 將修改既有 Microsoft 365 使用者的 profile／主管關係。', '變更只限：jobTitle、department、companyName、officeLocation、manager。', '姓名、UPN、照片、密碼、使用地區、管理角色及既有授權不修改。',
            'DemoAccountAcknowledged 表示你已核對本批實際帳號', '[PersonaDetail] [1/3] alice', '[PersonaDetail] [3/3] carol', 'Target: ')
        $cursor = -1
        foreach ($marker in $order) { $next = $text.IndexOf($marker, $cursor + 1, [StringComparison]::Ordinal); Assert-True ($next -gt $cursor) "Missing or out of order: $marker"; $cursor = $next }
        Assert-True ($text -match 'jobTitle: "Old title" → "Role carol"' -and $text -match 'officeLocation: <null> → "Test"' -and $text -match 'manager: <none> → alice <existing-alice@example\.invalid>')
        $after = @($e.Model.Ledger | Select-Object -Skip $planned)
        $firstWrite = @($after | Where-Object Method -ne GET)[0]
        $recheck = @($after[0..($after.IndexOf($firstWrite) - 1)])
        foreach ($name in @('alice', 'bob', 'carol')) { Assert-True (@($recheck | Where-Object { $_.Path -like "*existing-$name%40*" }).Count -ge 1) "No fresh recheck of $name before the first write." }
    }
    Test-Case 'Existing manager-only change warns and an unchanged batch shows no modification warning' {
        $e = New-ExistingPersonaTestEnvironment -Count 2
        foreach ($name in @('alice', 'bob')) { $pr = $e.Model.Users[$e.Model.Ids[$name]].Profile; $pr.jobTitle = $(if ($name -eq 'alice') { 'Lead' } else { 'Analyst' }); $pr.department = 'Operations'; $pr.companyName = 'Fictional Test' }
        $e.Model.Users[$e.Model.Ids.alice].Profile.officeLocation = 'Test'
        $p = Get-ExistingTestPlan $e
        $bob = @($p.Preview.Rows | Where-Object PersonaId -eq bob)[0]
        Assert-Equal @($bob.Diff.Field) @('manager')
        $null = Invoke-ExistingTestPlan $e $p
        $text = $e.Host.Terminal.Lines.ToArray() -join "`n"
        Assert-True ($text -match '\[Warning\] 將修改既有' -and $text -match '將變更：1 人')
        $writes = Get-ExistingTestWrites $e
        Assert-Equal $writes.Count 1; Assert-Equal $writes[0].Method 'PUT'
        $e.Host = [SeedTestHost]::new(); $e.Model.Ledger.Clear()
        $again = Get-ExistingTestPlan $e
        $null = Invoke-ExistingTestPlan $e $again
        $text = $e.Host.Terminal.Lines.ToArray() -join "`n"
        Assert-True ($text -match '將沿用既有人員，不修改 profile' -and $text -notmatch '\[Warning\]')
        Assert-NoPersonaWrites $e
        Assert-True $script:SeedPersonaPlans[$again.PlanId].Used
        Assert-Equal (Get-SeedSessionRecord $e.Session).PersonaPlanId $null
    }
    Test-Case 'Existing direct and callback confirmations both render the shared warning and require DemoAccountAcknowledged for this exact plan' {
        $e = New-ExistingPersonaTestEnvironment -Count 2
        $p = Get-ExistingTestPlan $e
        Assert-Throws { Invoke-ExistingTestPlan $e $p -WithoutAcknowledgement } 'Seed.Persona.Confirmation' | Out-Null
        Assert-True (($e.Host.Terminal.Lines.ToArray() -join "`n") -match '\[Warning\] 將修改既有' ) 'The direct path must still render the shared warning.'
        Assert-NoPersonaWrites $e
        Assert-Throws { Invoke-InitializePersonas -Session $e.Session -Plan $p -ConfirmTarget $p.Target -ConfirmPlanFingerprint ('0' * 64) -DemoAccountAcknowledged -ConsoleHost $e.Host -NonInteractive 6>$null } 'Seed.Persona.Confirmation' | Out-Null
        foreach ($answer in @(@{}, @{ DemoAccountAcknowledged = $false }, @{ DemoAccountAcknowledged = 'true' }, @{ DemoAccountAcknowledged = $true; PlanFingerprint = ('1' * 64) })) {
            $reply = $answer
            $confirm = { param($Preview, $Target, $Fingerprint) $result = @{ Target = $Target; PlanFingerprint = $Fingerprint }; foreach ($k in $reply.Keys) { $result[$k] = $reply[$k] }; $result }.GetNewClosure()
            $e.Host = [SeedTestHost]::new()
            Assert-Throws { Invoke-InitializePersonas -Session $e.Session -Plan $p -Confirmation $confirm -ConsoleHost $e.Host -NonInteractive 6>$null } 'Seed.Persona.Confirmation' | Out-Null
            Assert-True (($e.Host.Terminal.Lines.ToArray() -join "`n") -match '\[Warning\] 將修改既有') 'The callback path must render the shared warning first.'
            Assert-NoPersonaWrites $e
        }
        Assert-True (-not (Test-Path -LiteralPath $e.Config.personas.bindingPath))
        $other = Get-ExistingTestPlan $e
        Assert-Throws { Invoke-InitializePersonas -Session $e.Session -Plan $p -ConfirmTarget $p.Target -ConfirmPlanFingerprint $other.Fingerprint -DemoAccountAcknowledged -ConsoleHost $e.Host -NonInteractive 6>$null } 'Seed.Persona.Plan|Seed.Persona.Confirmation' | Out-Null
        Assert-NoPersonaWrites $e
    }
    Test-Case 'Existing data changes after the preview invalidate the whole batch before the first write' {
        foreach ($change in @('Profile', 'Manager', 'Disabled')) {
            $e = New-ExistingPersonaTestEnvironment -Count 3
            $p = Get-ExistingTestPlan $e
            switch ($change) {
                Profile { $e.Model.Users[$e.Model.Ids.bob].Profile.jobTitle = 'Concurrent change' }
                Manager { $e.Model.Users[$e.Model.Ids.carol].Manager = $e.Model.Ids.bob }
                Disabled { $e.Model.Users[$e.Model.Ids.alice].Profile.accountEnabled = $false }
            }
            Assert-Throws { Invoke-ExistingTestPlan $e $p } 'Seed\.Persona\.'  | Out-Null
            Assert-NoPersonaWrites $e
            Assert-True (-not (Test-Path -LiteralPath $e.Config.personas.bindingPath))
        }
    }
    Test-Case 'Existing mid-run drift, unknown or ignored effect stops with no retry no binding and a blocking journal' {
        foreach ($fault in @('Drift', 'UnknownPatch', 'IgnorePatch')) {
            $e = New-ExistingPersonaTestEnvironment -Count 3
            $p = Get-ExistingTestPlan $e
            if ($fault -eq 'Drift') { $e.Model.AfterWrite = { param($m, $path) $e.Model.Users[$e.Model.Ids.carol].Profile.jobTitle = 'Concurrent change' }.GetNewClosure() } else { $e.Model.Fault = $fault }
            Assert-Throws { Invoke-ExistingTestPlan $e $p } 'Seed.Persona.(Blocked|Unknown)' | Out-Null
            $writes = Get-ExistingTestWrites $e
            if ($fault -eq 'Drift') { Assert-True (@($writes | Where-Object { $_.Path -match $e.Model.Ids.carol }).Count -eq 0) 'The drifted account must never be overwritten.' }
            else { Assert-Equal $writes.Count 1 'A submitted effect is never retried.' }
            Assert-True (-not (Test-Path -LiteralPath $e.Config.personas.bindingPath))
            $journal = Get-Content -LiteralPath ($e.Config.personas.bindingPath + '.journal.json') -Raw | ConvertFrom-Json -AsHashtable
            Assert-Equal $journal.status 'Blocked'
            Assert-True $script:SeedPersonaPlans[$p.PlanId].Used
            Assert-Equal (Get-SeedSessionRecord $e.Session).PersonaPlanId $null
            if ($fault -ceq 'UnknownPatch') {
                Assert-Equal $journal.plans.Count 1
                Assert-Equal @($journal.events | Where-Object status -eq Unknown).Count 1
            }
            Assert-Throws { Get-ExistingTestPlan $e } 'Seed.Persona.Journal' | Out-Null
            Assert-Equal (Get-ExistingTestWrites $e).Count $writes.Count
        }
    }
    Test-Case 'Existing failure summary counts a persona as Updated only after a verified Profile or Manager effect, never for BindExisting adoption alone' {
        # UnknownPatch verifies nothing but BindExisting. DriftAfterEffects verifies alice Profile, bob Profile and Manager, carol Manager only; dave drifts before its first write.
        foreach ($case in @(
                @{ Fault = 'UnknownPatch'; Count = 3; Effects = 0; Updated = 0; Unknown = 1; Failed = 0 },
                @{ Fault = 'DriftAfterEffects'; Count = 4; Effects = 4; Updated = 3; Unknown = 0; Failed = 1 })) {
            $e = New-ExistingPersonaTestEnvironment -Count $case.Count
            if ($case.Fault -eq 'DriftAfterEffects') {
                $carol = $e.Model.Users[$e.Model.Ids.carol].Profile
                $carol.jobTitle = 'Role carol'; $carol.department = 'Operations'; $carol.companyName = 'Fictional Test'
            }
            $p = Get-ExistingTestPlan $e
            Assert-Equal @($p.Preview.Rows | Where-Object Action -eq Update).Count $case.Count
            if ($case.Fault -eq 'UnknownPatch') { $e.Model.Fault = 'UnknownPatch' } else { $e.Model.AfterWrite = { param($m, $path) $e.Model.Users[$e.Model.Ids.dave].Profile.jobTitle = 'Concurrent change' }.GetNewClosure() }
            Assert-Throws { Invoke-ExistingTestPlan $e $p } 'Seed.Persona.(Blocked|Unknown)' | Out-Null
            $journal = Get-Content -LiteralPath ($e.Config.personas.bindingPath + '.journal.json') -Raw | ConvertFrom-Json -AsHashtable
            Assert-Equal @($journal.events | Where-Object { $_.kind -eq 'BindExisting' -and $_.status -eq 'Verified' }).Count $case.Count
            Assert-Equal @($journal.events | Where-Object { $_.kind -in @('Profile', 'Manager') -and $_.status -eq 'Verified' }).Count $case.Effects
            $summary = $journal.lastSummary
            Assert-Equal $summary.Selected $case.Count
            Assert-Equal $summary.Updated $case.Updated
            Assert-Equal $summary.Unknown $case.Unknown
            Assert-Equal $summary.Failed $case.Failed
        }
    }
    Test-Case 'Existing null and absent profile values keep bindable snapshots while explicit targets update and invalid evidence blocks before any warning' {
        $e = New-ExistingPersonaTestEnvironment -Count 2
        $p = Get-ExistingTestPlan $e
        $alice = @($p.Preview.Rows | Where-Object PersonaId -eq alice)[0]; $bob = @($p.Preview.Rows | Where-Object PersonaId -eq bob)[0]
        Assert-True (@($alice.Diff | Where-Object Field -eq officeLocation).Count -eq 1) 'An explicit officeLocation must update from null.'
        Assert-True (@($bob.Diff | Where-Object Field -eq officeLocation).Count -eq 0) 'An unspecified officeLocation is kept as null.'
        $null = Invoke-ExistingTestPlan $e $p
        $binding = Get-Content -LiteralPath $e.Config.personas.bindingPath -Raw | ConvertFrom-Json -AsHashtable
        Assert-Equal $binding.users.bob.profile.officeLocation $null
        Assert-Equal $e.Model.Users[$e.Model.Ids.bob].Profile.officeLocation $null
        $bad = New-ExistingPersonaTestEnvironment -Count 2
        $bad.Model.Users[$bad.Model.Ids.bob].Profile.Remove('officeLocation')
        $plan = Get-ExistingTestPlan $bad
        Assert-Equal @($plan.Preview.Rows | Where-Object Action -eq Block).Count 1
        Assert-Throws { Invoke-ExistingTestPlan $bad $plan } 'Seed.Persona.Blocked' | Out-Null
        Assert-True (($bad.Host.Terminal.Lines.ToArray() -join "`n") -notmatch '\[Warning\]')
        Assert-NoPersonaWrites $bad
    }
    Test-Case 'Existing prior state needs the exact completed BindExisting journal; fake binding, missing journal, changed selection and a reassigned UPN never authorize adoption' {
        foreach ($fault in @('FakeProvisioned', 'NoJournal', 'ChangedSelection', 'ReassignedUpn')) {
            $e = New-ExistingPersonaTestEnvironment -Count 2
            $null = Invoke-ExistingTestPlan $e (Get-ExistingTestPlan $e)
            $e.Model.Ledger.Clear()
            switch ($fault) {
                FakeProvisioned { $b = Get-Content -LiteralPath $e.Config.personas.bindingPath -Raw | ConvertFrom-Json -AsHashtable; $b.status = 'Provisioned'; $b.version = '1.0'; $b | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $e.Config.personas.bindingPath }
                NoJournal { Remove-Item -LiteralPath ($e.Config.personas.bindingPath + '.journal.json') }
                ChangedSelection { $e.Config.personas.accountMappings.Remove('bob') }
                ReassignedUpn {
                    $new = 'abababab-abab-4bab-8bab-abababababab'
                    $e.Model.Users[$new] = $e.Model.Users[$e.Model.Ids.alice]; $e.Model.Users[$new].Profile.id = $new; $e.Model.Users.Remove($e.Model.Ids.alice)
                }
            }
            if ($fault -eq 'ReassignedUpn') {
                $plan = Get-ExistingTestPlan $e
                Assert-Equal @($plan.Preview.Rows | Where-Object { $_.PersonaId -eq 'alice' -and $_.Action -eq 'Block' -and $_.BlockReason -eq 'Seed.Persona.Identity' }).Count 1
                Assert-Throws { Invoke-ExistingTestPlan $e $plan } 'Seed.Persona.Blocked' | Out-Null
            } else { Assert-Throws { Get-ExistingTestPlan $e } 'Seed\.Persona\.(Journal|Binding)' | Out-Null }
            Assert-NoPersonaWrites $e
        }
    }
    Test-Case 'Existing and Managed sources are never mixed between config and public pack' {
        $e = New-ExistingPersonaTestEnvironment -Count 2
        Copy-Item -LiteralPath (Join-Path $root 'tests\fixtures\personas.json') -Destination $e.Folder -Force
        foreach ($name in @('alice.jpg', 'bob.jpg', 'rights.txt')) { Copy-Item -LiteralPath (Join-Path $root "tests\fixtures\$name") -Destination $e.Folder -Force }
        $e.Model.Ledger.Clear()
        Assert-Throws { Get-ExistingTestPlan $e } 'Seed.Persona.Source' | Out-Null
        $managed = New-PersonaTestEnvironment
        Copy-Item -LiteralPath (Join-Path $root 'tests\fixtures\existing-personas.json') -Destination $managed.Config.personas.packPath -Force
        $managed.Model.Ledger.Clear()
        Assert-Throws { Get-PersonaTestPlan $managed } 'Seed.Persona.Source' | Out-Null
        Assert-Equal $managed.Model.Ledger.Count 0
    }
    Test-Case 'Existing safe preview projection carries only logical personas, field names, counts and codes' {
        $e = New-ExistingPersonaTestEnvironment -Count 3
        $e.Model.Users[$e.Model.Ids.carol].Profile.userType = 'Guest'
        $p = Get-ExistingTestPlan $e
        $json = ConvertTo-SeedPersonaSafePreview -Plan $p | ConvertTo-Json -Depth 10
        foreach ($forbidden in @('existing-', '@example.invalid', 'Old title', 'External Boss', 'alice Existing', 'aaaaaaaa-aaaa', 'Inventory', $e.Model.OperatorId)) { Assert-True (-not $json.Contains($forbidden)) "Projection leaked $forbidden" }
        $projection = $json | ConvertFrom-Json -AsHashtable
        Assert-Equal $projection.Counts.Selected 3; Assert-Equal $projection.Counts.Block 1; Assert-Equal $projection.Counts.Update 2
        Assert-True ($projection.People[0].ChangedFields -contains 'companyName')
        Assert-Equal @($projection.People | Where-Object Action -eq Block)[0].BlockReason 'Seed.Persona.Identity'
        Assert-True (-not $projection.Contains('PimGroupEligibility'))
    }
    Test-Case 'Existing resolver keeps every exact UPN that exists, never replaces it by a name hint, and only reads' {
        $e = New-ExistingPersonaTestEnvironment -Count 3
        Add-ExistingDirectoryUser $e '12121212-1212-4212-8212-121212121212' 'someone.else@example.invalid' 'alice Test' @{ mailNickname = 'alice' }
        $start = $e.Model.Ledger.Count
        $r = Invoke-ExistingResolver $e
        Assert-Equal @($r.Unresolved).Count 0
        Assert-Equal @($r.Resolutions).Count 3
        Assert-Equal @($r.Resolutions | ForEach-Object { $_.Method } | Sort-Object -Unique) @('ExactUpn')
        Assert-Equal $r.EffectiveConfig.personas.accountMappings.alice 'existing-alice@example.invalid'
        Assert-Equal (@($r.Resolutions | Where-Object PersonaId -eq alice)[0].ObjectId) $e.Model.Ids.alice
        Assert-Equal (Get-ExistingDirectoryReads $e $start).Count 0 'An existing exact UPN is never looked up by name.'
        Assert-Equal @($e.Model.Ledger | Select-Object -Skip $start | Where-Object Method -ne GET).Count 0
    }
    Test-Case 'Existing resolver proposes a missing UPN only from one complete exact full-name or alias match and leaves the caller config untouched' {
        foreach ($mode in @('Name', 'Alias', 'NameAndAlias')) {
            $e = New-ExistingPersonaTestEnvironment -Count 2
            $e.Model.Users.Remove($e.Model.Ids.bob)
            $new = '12121212-1212-4212-8212-121212121212'
            Add-ExistingDirectoryUser $e $new 'bob.test@other.example.invalid' $(if ($mode -eq 'Alias') { 'Another Display' } else { 'Bob Test' }) @{ mailNickname = $(if ($mode -eq 'Name') { 'unrelated' } else { 'bob' }) }
            $copy = Copy-PersonaTestValue $e.Config
            $r = Invoke-ExistingResolver $e
            $bob = @($r.Resolutions | Where-Object PersonaId -eq bob)[0]
            Assert-Equal $bob.Method 'UniqueExactHint'
            Assert-Equal $bob.ObjectId $new; Assert-Equal $bob.ResolvedUpn 'bob.test@other.example.invalid'; Assert-Equal $bob.RequestedUpn 'existing-bob@example.invalid'
            Assert-Equal $bob.Basis $(switch ($mode) { 'Name' { 'ExactName' } 'Alias' { 'ExactAlias' } default { 'ExactNameAndAlias' } })
            Assert-Equal $r.EffectiveConfig.personas.accountMappings.bob 'bob.test@other.example.invalid'
            Assert-Equal $r.EffectiveConfig.personas.accountMappings.alice 'existing-alice@example.invalid'
            Assert-Equal @($r.Unresolved).Count 0
            Assert-Equal (Get-SeedFingerprint $e.Config) (Get-SeedFingerprint $copy) 'The caller config must never be mutated.'
            Assert-Equal (Get-ExistingTestWrites $e).Count 0
        }
    }
    Test-Case 'Existing resolver never picks a person from ambiguous, similar, absent, ineligible or already used matches: it returns bounded local candidates and no resolution' {
        $x = '10101010-1010-4010-8010-101010101010'; $y = '20202020-2020-4020-8020-202020202020'
        foreach ($case in @('NameAndAliasDiffer', 'SameNameTwice', 'SecondPage', 'PrefixOnly', 'Zero', 'Disabled', 'Guest', 'Synced', 'PresenterMatch', 'OperatorMatch', 'AlreadyUsed', 'Overflow', 'Bounded')) {
            $e = New-ExistingPersonaTestEnvironment -Count 2
            $e.Model.Users.Remove($e.Model.Ids.bob)
            $reason = 'AmbiguousExactHint'
            switch ($case) {
                'NameAndAliasDiffer' { Add-ExistingDirectoryUser $e $x 'x@other.example.invalid' 'Bob Test' @{ mailNickname = 'xx' }; Add-ExistingDirectoryUser $e $y 'y@other.example.invalid' 'Different' @{ mailNickname = 'bob' } }
                'SameNameTwice' { Add-ExistingDirectoryUser $e $x 'x@other.example.invalid' 'Bob Test'; Add-ExistingDirectoryUser $e $y 'y@other.example.invalid' 'Bob Test' }
                'SecondPage' { $e.Model.PageSize = 1; Add-ExistingDirectoryUser $e $x 'x@other.example.invalid' 'Bob Test'; Add-ExistingDirectoryUser $e $y 'y@other.example.invalid' 'Bob Test' }
                'PrefixOnly' { $reason = 'NoExactHint'; Add-ExistingDirectoryUser $e $x 'x@other.example.invalid' 'Bobby Tester' }
                'Zero' { $reason = 'NoExactHint' }
                'Disabled' { $reason = 'IneligibleExactHint'; Add-ExistingDirectoryUser $e $x 'x@other.example.invalid' 'Bob Test' @{ accountEnabled = $false } }
                'Guest' { $reason = 'IneligibleExactHint'; Add-ExistingDirectoryUser $e $x 'x@other.example.invalid' 'Bob Test' @{ userType = 'Guest' } }
                'Synced' { $reason = 'IneligibleExactHint'; Add-ExistingDirectoryUser $e $x 'x@other.example.invalid' 'Bob Test' @{ onPremisesSyncEnabled = $true } }
                'PresenterMatch' { $reason = 'IneligibleExactHint'; Add-ExistingDirectoryUser $e $e.Model.PresenterId $e.Config.presenterUpn 'Bob Test' }
                'OperatorMatch' { $reason = 'IneligibleExactHint'; Add-ExistingDirectoryUser $e $e.Model.OperatorId $e.Config.adminAuth.adminOperatorUpn 'Bob Test' }
                'AlreadyUsed' { $reason = 'DuplicateAccount'; $e.Model.Users[$e.Model.Ids.alice].Profile.displayName = 'Bob Test' }
                'Overflow' {
                    $reason = 'IncompleteLookup'; $e.Model.PageSize = 1
                    foreach ($n in 1..6) { Add-ExistingDirectoryUser $e ('4040404' + $n + '-4040-4040-8040-404040404040') "many$n@other.example.invalid" 'Bob Test' }
                }
                'Bounded' { foreach ($n in 10..34) { Add-ExistingDirectoryUser $e ('50505050-5050-4050-8050-5050505050' + $n) "many$n@other.example.invalid" 'Bob Test' } }
            }
            $start = $e.Model.Ledger.Count
            $r = Invoke-ExistingResolver $e
            $bob = @($r.Unresolved | Where-Object PersonaId -eq bob)
            Assert-Equal $bob.Count 1 $case
            Assert-Equal $bob[0].Reason $reason $case
            Assert-Equal @($r.Resolutions | Where-Object PersonaId -eq bob).Count 0 "$case picked a person."
            Assert-Equal $r.EffectiveConfig.personas.accountMappings.bob 'existing-bob@example.invalid'
            Assert-Equal $bob[0].RequestedUpn 'existing-bob@example.invalid'
            $candidates = @($bob[0].Candidates)
            Assert-True ($candidates.Count -le 20) "$case returned an unbounded candidate list."
            Assert-True ((Get-ExistingDirectoryReads $e $start).Count -le 10) "$case read the directory without a bound."
            switch ($case) {
                'NameAndAliasDiffer' { Assert-Equal @($candidates | ForEach-Object { $_.ObjectId } | Sort-Object) @($x, $y) }
                { $_ -in @('SameNameTwice', 'SecondPage') } { Assert-Equal @($candidates | ForEach-Object { $_.ObjectId } | Sort-Object) @($x, $y) }
                'PrefixOnly' { Assert-Equal @($candidates | ForEach-Object { $_.Basis }) @('Prefix'); Assert-Equal $candidates[0].ObjectId $x }
                'Zero' { Assert-True ($candidates.Count -ge 1 -and @($candidates | Where-Object { $_.Basis -cne 'AvailablePage' }).Count -eq 0) }
                { $_ -in @('Disabled', 'Guest', 'Synced') } { Assert-Equal @($candidates | Where-Object { $_.ObjectId -eq $x }).Count 0 'An ineligible account must never be offered.' }
                { $_ -in @('PresenterMatch', 'OperatorMatch') } { Assert-Equal @($candidates | Where-Object { $_.ObjectId -in @($e.Model.PresenterId, $e.Model.OperatorId) }).Count 0 'The Presenter and operator are never offered.' }
                'Bounded' { Assert-Equal $candidates.Count 20; Assert-True $bob[0].Truncated }
            }
            Assert-Equal (Get-ExistingTestWrites $e).Count 0
        }
    }
    Test-Case 'Existing resolver treats 403, timeout and a failed name query as failures, never as a missing account, and stops without pairing' {
        foreach ($fault in @('ExactUpn403', 'ExactUpnTimeout', 'UserList403', 'UserListTimeout')) {
            $e = New-ExistingPersonaTestEnvironment -Count 2
            if ($fault -like 'UserList*') { $e.Model.Users.Remove($e.Model.Ids.bob); Add-ExistingDirectoryUser $e '12121212-1212-4212-8212-121212121212' 'bob.test@other.example.invalid' 'Bob Test' }
            $e.Model.Fault = $fault
            $start = $e.Model.Ledger.Count
            Assert-Throws { Invoke-ExistingResolver $e } 'Seed\.Graph\.(403|0):' | Out-Null
            if ($fault -like 'ExactUpn*') { Assert-Equal (Get-ExistingDirectoryReads $e $start).Count 0 "$fault fell back to a name lookup." }
            Assert-Equal (Get-ExistingTestWrites $e).Count 0
        }
    }
    Test-Case 'Existing resolver accepts one explicit local selection per unresolved persona, reads the chosen account back and labels a hint candidate versus a different person' {
        $x = '10101010-1010-4010-8010-101010101010'; $y = '20202020-2020-4020-8020-202020202020'
        $e = New-ExistingPersonaTestEnvironment -Count 2
        $e.Model.Users.Remove($e.Model.Ids.bob)
        Add-ExistingDirectoryUser $e $x 'x@other.example.invalid' 'Bobby Tester'
        Add-ExistingDirectoryUser $e $y 'y@other.example.invalid' 'Totally Different'
        $first = Invoke-ExistingResolver $e
        Assert-Equal @($first.Unresolved).Count 1
        Assert-Equal @($first.Unresolved[0].Candidates | Where-Object { $_.Basis -ceq 'Prefix' } | ForEach-Object { $_.ObjectId }) @($x)
        $c = Invoke-ExistingResolver $e @{ bob = @{ Method = 'UserSelectedCandidate'; ObjectId = $x } }
        $bob = @($c.Resolutions | Where-Object PersonaId -eq bob)[0]
        Assert-Equal $bob.Method 'UserSelectedCandidate'; Assert-Equal $bob.ObjectId $x; Assert-Equal $bob.ResolvedUpn 'x@other.example.invalid'; Assert-Equal $bob.Basis 'Prefix'
        Assert-Equal @($c.Unresolved).Count 0; Assert-Equal $c.EffectiveConfig.personas.accountMappings.bob 'x@other.example.invalid'
        foreach ($choice in @(@{ Method = 'UserSelectedReplacement'; ObjectId = $y }, @{ Method = 'UserSelectedReplacement'; Upn = 'Y@Other.Example.Invalid' })) {
            $r = Invoke-ExistingResolver $e @{ bob = $choice }
            $row = @($r.Resolutions | Where-Object PersonaId -eq bob)[0]
            Assert-Equal $row.Method 'UserSelectedReplacement'; Assert-Equal $row.ObjectId $y; Assert-Equal $row.ResolvedUpn 'y@other.example.invalid'
        }
        Assert-Equal (Get-ExistingTestWrites $e).Count 0
    }
    Test-Case 'Existing resolver rejects a selection that is the Presenter, the operator, a duplicate, ineligible, unreadable, for a persona whose UPN exists, or called a candidate without being one' {
        $x = '10101010-1010-4010-8010-101010101010'
        foreach ($case in @('Presenter', 'Operator', 'DuplicateOfAlice', 'Guest', 'Synced', 'Disabled', 'Unknown', 'ExactUpnPersona', 'CandidateNotHint', 'BadMethod', 'BothIdentifiers', 'NoIdentifier', 'UnknownPersona')) {
            $e = New-ExistingPersonaTestEnvironment -Count 2
            $e.Model.Users.Remove($e.Model.Ids.bob)
            Add-ExistingDirectoryUser $e $x 'x@other.example.invalid' 'Some One'
            Add-ExistingDirectoryUser $e $e.Model.PresenterId $e.Config.presenterUpn 'Presenter'
            Add-ExistingDirectoryUser $e $e.Model.OperatorId $e.Config.adminAuth.adminOperatorUpn 'Operator'
            $replacement = { param($extra) @{ Method = 'UserSelectedReplacement' } + $extra }
            $selection = switch ($case) {
                'Presenter' { @{ bob = (& $replacement @{ ObjectId = $e.Model.PresenterId }) } }
                'Operator' { @{ bob = (& $replacement @{ Upn = $e.Config.adminAuth.adminOperatorUpn }) } }
                'DuplicateOfAlice' { @{ bob = (& $replacement @{ ObjectId = $e.Model.Ids.alice }) } }
                { $_ -in @('Guest', 'Synced', 'Disabled') } {
                    $profile = $e.Model.Users[$x].Profile
                    if ($case -eq 'Guest') { $profile.userType = 'Guest' } elseif ($case -eq 'Synced') { $profile.onPremisesSyncEnabled = $true } else { $profile.accountEnabled = $false }
                    @{ bob = (& $replacement @{ ObjectId = $x }) }
                }
                'Unknown' { @{ bob = (& $replacement @{ Upn = 'nobody@other.example.invalid' }) } }
                'ExactUpnPersona' { @{ alice = (& $replacement @{ ObjectId = $x }) } }
                'CandidateNotHint' { @{ bob = @{ Method = 'UserSelectedCandidate'; ObjectId = $x } } }
                'BadMethod' { @{ bob = @{ Method = 'AutoPick'; ObjectId = $x } } }
                'BothIdentifiers' { @{ bob = (& $replacement @{ ObjectId = $x; Upn = 'x@other.example.invalid' }) } }
                'NoIdentifier' { @{ bob = @{ Method = 'UserSelectedReplacement' } } }
                'UnknownPersona' { @{ ghost = (& $replacement @{ ObjectId = $x }) } }
            }
            Assert-Throws { Invoke-ExistingResolver $e $selection } 'Seed\.Persona\.Selection' | Out-Null
            Assert-Equal (Get-ExistingTestWrites $e).Count 0
        }
    }
    Test-Case 'Existing resolver for a generic pack without identity hints never searches by name: a missing UPN needs one local choice and accepts an exact typed UPN' {
        $e = New-ExistingPersonaTestEnvironment -Count 2 -PackFile (Join-Path $root 'personas\existing-template\personas.json') -PersonaIds @('demo-lead', 'demo-analyst')
        $e.Model.Users.Remove($e.Model.Ids['demo-analyst'])
        $other = '12121212-1212-4212-8212-121212121212'
        Add-ExistingDirectoryUser $e $other 'someone.else@other.example.invalid' 'Someone Else'
        $r = Invoke-ExistingResolver $e
        $item = @($r.Unresolved | Where-Object PersonaId -eq 'demo-analyst')[0]
        Assert-Equal $item.Reason 'NoIdentityHint'
        Assert-Equal @($item.Candidates | Where-Object { $_.Basis -cne 'AvailablePage' }).Count 0
        $typed = Invoke-ExistingResolver $e @{ 'demo-analyst' = @{ Method = 'UserSelectedReplacement'; Upn = 'someone.else@other.example.invalid' } }
        $row = @($typed.Resolutions | Where-Object PersonaId -eq 'demo-analyst')[0]
        Assert-Equal $row.Method 'UserSelectedReplacement'; Assert-Equal $row.ObjectId $other; Assert-Equal $row.Basis 'TypedUpn'
        Assert-Equal @($e.Model.Ledger | Where-Object { $_.Path -match '^/users\?.*filter' }).Count 0 'Without a hint no name filter may be issued.'
    }
    Test-Case 'Existing resolver is inert once an initialization started: a blocked journal means no name lookup, no selection and no rebinding' {
        $e = New-ExistingPersonaTestEnvironment -Count 2
        $e.Model.Fault = 'UnknownPatch'
        $p = Get-ExistingTestPlan $e
        Assert-Throws { Invoke-ExistingTestPlan $e $p } 'Seed\.Persona\.(Blocked|Unknown)' | Out-Null
        $e.Model.Fault = ''
        $e.Model.Users.Remove($e.Model.Ids.bob)
        $other = '12121212-1212-4212-8212-121212121212'
        Add-ExistingDirectoryUser $e $other 'bob.test@other.example.invalid' 'Bob Test'
        $start = $e.Model.Ledger.Count
        $r = Invoke-ExistingResolver $e
        Assert-Equal @($r.Resolutions).Count 0; Assert-Equal @($r.Unresolved).Count 0
        Assert-Equal $r.EffectiveConfig.personas.accountMappings.bob 'existing-bob@example.invalid'
        Assert-Equal @($e.Model.Ledger | Select-Object -Skip $start).Count 0 'A started initialization is never re-resolved: no read at all.'
        Assert-Throws { Invoke-ExistingResolver $e @{ bob = @{ Method = 'UserSelectedReplacement'; ObjectId = $other } } } 'Seed\.Persona\.Selection' | Out-Null
        Assert-Throws { Get-ExistingTestPlan $e } 'Seed\.Persona\.Journal' | Out-Null
        Assert-Equal (Get-ExistingTestWrites $e).Count 1 'The submitted effect is never retried.'
    }
    Test-Case 'Existing plan built from a resolution reads chosen accounts by fixed ID, puts method and actual account into its fingerprint, keeps the real name, and refuses unresolved or inconsistent resolutions' {
        $x = '10101010-1010-4010-8010-101010101010'
        $e = New-ExistingPersonaTestEnvironment -Count 2
        $e.Model.Users.Remove($e.Model.Ids.bob)
        Add-ExistingDirectoryUser $e $x 'bob.test@other.example.invalid' 'Bob Test' @{ mailNickname = 'bt'; jobTitle = 'Old role' }
        $r = Invoke-ExistingResolver $e
        $start = $e.Model.Ledger.Count
        $p = Get-SeedPersonaPlan -Session $e.Session -Config $r.EffectiveConfig -AccountResolution $r
        $bob = @($p.Preview.Rows | Where-Object PersonaId -eq bob)[0]
        Assert-Equal $bob.ObjectId $x; Assert-Equal $bob.Upn 'bob.test@other.example.invalid'
        Assert-Equal $bob.Resolution.Method 'UniqueExactHint'; Assert-Equal $bob.Resolution.RequestedUpn 'existing-bob@example.invalid'
        Assert-Equal $bob.Resolution.ResolvedUpn 'bob.test@other.example.invalid'; Assert-Equal $bob.Resolution.ObjectId $x
        Assert-Equal $bob.Before.Profile.displayName 'Bob Test'
        Assert-True (@($bob.Diff | ForEach-Object { $_.Field }) -notcontains 'displayName') 'The real name is never rewritten.'
        $reads = @($e.Model.Ledger | Select-Object -Skip $start | Where-Object Method -eq GET | ForEach-Object { $_.Path })
        Assert-Equal @($reads | Where-Object { $_ -match '^/users\?|existing-bob|existing-alice' }).Count 0 'Resolved personas are read by their fixed IDs, never again by name or UPN.'
        Assert-Equal (@($p.Preview.Rows | Where-Object PersonaId -eq alice)[0].Resolution.Method) 'ExactUpn'
        $safe = ConvertTo-SeedPersonaSafePreview -Plan $p | ConvertTo-Json -Depth 10
        foreach ($forbidden in @('bob.test', 'Bob Test', $x, 'existing-bob')) { Assert-True (-not $safe.Contains($forbidden)) "The automation projection leaked $forbidden." }
        Assert-True ($safe.Contains('UniqueExactHint'))
        $labelled = ConvertTo-SeedMap $r
        @($labelled.Resolutions | Where-Object { $_.PersonaId -eq 'bob' })[0].Method = 'UserSelectedCandidate'
        Assert-True ((Get-SeedPersonaPlan -Session $e.Session -Config $r.EffectiveConfig -AccountResolution $labelled).Fingerprint -cne $p.Fingerprint) 'The method is part of the fingerprint.'
        $forged = ConvertTo-SeedMap $r
        @($forged.Resolutions | Where-Object { $_.PersonaId -eq 'bob' })[0].ResolvedUpn = 'someone.else@other.example.invalid'
        Assert-Throws { Get-SeedPersonaPlan -Session $e.Session -Config $r.EffectiveConfig -AccountResolution $forged } 'Seed\.Persona\.Selection' | Out-Null
        $swapped = ConvertTo-SeedMap $r
        @($swapped.Resolutions | Where-Object { $_.PersonaId -eq 'bob' })[0].ObjectId = $e.Model.Ids.alice
        $swappedPlan = Get-SeedPersonaPlan -Session $e.Session -Config $r.EffectiveConfig -AccountResolution $swapped
        Assert-True (@($swappedPlan.Preview.Rows | Where-Object { $_.Action -eq 'Block' }).Count -ge 1) 'A fixed ID that does not currently hold the resolved UPN must block.'
        $unresolved = ConvertTo-SeedMap $r; $unresolved.Unresolved = @(@{ PersonaId = 'bob'; Reason = 'NoExactHint'; Candidates = @() })
        Assert-Throws { Get-SeedPersonaPlan -Session $e.Session -Config $r.EffectiveConfig -AccountResolution $unresolved } 'Seed\.Persona\.Selection' | Out-Null
        $p.Preview.Rows[1].Resolution.Method = 'ExactUpn'
        Assert-Throws { Invoke-ExistingTestPlan $e $p } 'Seed\.Persona\.Plan' | Out-Null
        Assert-Equal (Get-ExistingTestWrites $e).Count 0
        $managed = New-PersonaTestEnvironment
        Assert-Throws { Get-SeedPersonaPlan -Session $managed.Session -Config $managed.Config -AccountResolution @{ Resolutions = @(); Unresolved = @() } } 'Seed\.Persona\.Source' | Out-Null
        $direct = New-ExistingPersonaTestEnvironment -Count 2
        $same = Get-SeedPersonaPlan -Session $direct.Session -Config $direct.Config -AccountResolution (Invoke-ExistingResolver $direct)
        Assert-Equal $same.Fingerprint (Get-ExistingTestPlan $direct).Fingerprint
    }
    Test-Case 'Existing corrected account: the confirmed batch writes only the approved fixed ID, journals the resolution, shows the correction locally, then never looks up names again' {
        $e = New-ExistingCorrectionEnvironment
        $late = '30303030-3030-4030-8030-303030303030'
        Add-ExistingDirectoryUser $e $late 'late@other.example.invalid' 'Bob Test'
        $start = $e.Model.Ledger.Count
        $done = Invoke-ExistingTestPlan $e $e.Plan
        Assert-Equal $done.Status 'ConfiguredExisting'; Assert-Equal $done.Selected 2
        Assert-Equal (Get-ExistingDirectoryReads $e $start).Count 0 'The confirmed batch must never run another name filter.'
        $writes = Get-ExistingTestWrites $e
        Assert-Equal @($writes | Where-Object { $_.Path -match '30303030' }).Count 0 'A later same-name account must never be written.'
        Assert-True (@($writes | Where-Object { $_.Path -match $e.NewId }).Count -ge 1)
        $text = $e.Host.Terminal.Lines.ToArray() -join "`n"
        Assert-True ($text -match '\[PersonaDetail\]   account: existing-bob@example\.invalid → bob\.test@other\.example\.invalid via UniqueExactHint')
        Assert-True ($text -match '\[PersonaSetup\] Account resolution: ExactUpn=1 UniqueExactHint=1 UserSelectedCandidate=0 UserSelectedReplacement=0' -and $text -match '\[Warning\] 本批有 1 位的實際帳號不是你原先指定的 UPN')
        $binding = Get-Content -LiteralPath $e.Config.personas.bindingPath -Raw | ConvertFrom-Json -AsHashtable
        Assert-SeedSchema $binding persona-binding
        Assert-Equal $binding.users.bob.objectId $e.NewId; Assert-Equal $binding.users.bob.upn 'bob.test@other.example.invalid'
        $journal = Get-Content -LiteralPath ($e.Config.personas.bindingPath + '.journal.json') -Raw | ConvertFrom-Json -AsHashtable
        $approved = @($journal.plans)[-1]
        Assert-Equal (@($approved.preview.Rows | Where-Object { $_.PersonaId -eq 'bob' })[0].Resolution.Method) 'UniqueExactHint'
        Assert-Throws { Get-ExistingTestPlan $e } 'Seed\.Persona\.(Binding|Journal)' | Out-Null
        $save = Save-SeedResolvedAccountMappings -ConfigPath $e.ConfigFile -ExpectedHash $e.ConfigHash -Resolutions @($e.Plan.Preview.Rows | ForEach-Object { $_.Resolution })
        Assert-Equal $save.Status 'Saved'; Assert-Equal $save.Changed 1
        $saved = Get-Content -LiteralPath $e.ConfigFile -Raw | ConvertFrom-Json -AsHashtable
        Assert-Equal $saved.personas.accountMappings.bob 'bob.test@other.example.invalid'; Assert-Equal $saved.personas.accountMappings.alice 'existing-alice@example.invalid'
        $e.Config.personas.accountMappings.bob = $saved.personas.accountMappings.bob
        $e.Model.Ledger.Clear()
        $again = Invoke-ExistingResolver $e
        Assert-Equal @($again.Resolutions).Count 0; Assert-Equal @($again.Unresolved).Count 0
        $second = Get-SeedPersonaPlan -Session $e.Session -Config $again.EffectiveConfig -AccountResolution $again
        Assert-Equal @($second.Preview.Rows | Where-Object Action -ne Keep).Count 0
        Assert-Equal (Get-ExistingDirectoryReads $e).Count 0 'A completed binding is never re-resolved by name.'
    }
    Test-Case 'Existing fresh recheck uses the approved fixed ID: a changed UPN of the approved account blocks the whole batch before any write' {
        $e = New-ExistingCorrectionEnvironment
        $e.Model.Users[$e.NewId].Profile.userPrincipalName = 'renamed@other.example.invalid'
        Assert-Throws { Invoke-ExistingTestPlan $e $e.Plan } 'Seed\.Persona\.Changed' | Out-Null
        Assert-Equal (Get-ExistingTestWrites $e).Count 0
        Assert-True (-not (Test-Path -LiteralPath $e.Config.personas.bindingPath))
    }
    Test-Case 'Existing mapping save patches only accountMappings under the raw file hash and never overwrites a config that changed or no longer holds the requested value' {
        $e = New-ExistingPersonaTestEnvironment -Count 2
        Save-ExistingTestConfig $e
        $bob = @{ PersonaId = 'bob'; RequestedUpn = 'existing-bob@example.invalid'; ResolvedUpn = 'bob.test@other.example.invalid'; ObjectId = $e.Model.Ids.bob; Method = 'UniqueExactHint' }
        $alice = @{ PersonaId = 'alice'; RequestedUpn = 'existing-alice@example.invalid'; ResolvedUpn = 'existing-alice@example.invalid'; ObjectId = $e.Model.Ids.alice; Method = 'ExactUpn' }
        $noop = Save-SeedResolvedAccountMappings -ConfigPath $e.ConfigFile -ExpectedHash $e.ConfigHash -Resolutions @($alice)
        Assert-Equal $noop.Status 'NoChange'; Assert-Equal (Get-FileHash -LiteralPath $e.ConfigFile).Hash $e.ConfigHash
        $original = Get-Content -LiteralPath $e.ConfigFile -Raw | ConvertFrom-Json -AsHashtable
        Assert-Throws { Save-SeedResolvedAccountMappings -ConfigPath $e.ConfigFile -ExpectedHash ('0' * 64) -Resolutions @($alice, $bob) } 'Seed\.Persona\.ConfigSync' | Out-Null
        Assert-Equal (Get-FileHash -LiteralPath $e.ConfigFile).Hash $e.ConfigHash
        $edited = Copy-PersonaTestValue $original; $edited.personas.accountMappings.bob = 'operator.edited@other.example.invalid'
        $edited | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $e.ConfigFile -Encoding utf8
        $editedHash = (Get-FileHash -LiteralPath $e.ConfigFile).Hash
        Assert-Throws { Save-SeedResolvedAccountMappings -ConfigPath $e.ConfigFile -ExpectedHash $editedHash -Resolutions @($alice, $bob) } 'Seed\.Persona\.ConfigSync' | Out-Null
        Assert-Equal (Get-FileHash -LiteralPath $e.ConfigFile).Hash $editedHash
        $original | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $e.ConfigFile -Encoding utf8
        $hash = (Get-FileHash -LiteralPath $e.ConfigFile).Hash
        $saved = Save-SeedResolvedAccountMappings -ConfigPath $e.ConfigFile -ExpectedHash $hash -Resolutions @($alice, $bob)
        Assert-Equal $saved.Status 'Saved'; Assert-Equal $saved.Changed 1
        $after = Get-Content -LiteralPath $e.ConfigFile -Raw | ConvertFrom-Json -AsHashtable
        Assert-Equal $after.personas.accountMappings.bob 'bob.test@other.example.invalid'; Assert-Equal $after.personas.accountMappings.alice 'existing-alice@example.invalid'
        $left = Copy-PersonaTestValue $original; $left.personas.Remove('accountMappings'); $right = Copy-PersonaTestValue $after; $right.personas.Remove('accountMappings')
        Assert-Equal (Get-SeedFingerprint $left) (Get-SeedFingerprint $right) 'Only accountMappings may change.'
        Assert-SeedSchema $after config
    }
    Test-Case 'Existing local mapping sync follows only a proven completed correction: exact requested-to-final difference with intact journal and binding, otherwise nothing changes' {
        $e = New-ExistingCorrectionEnvironment
        $null = Invoke-ExistingTestPlan $e $e.Plan
        $original = [IO.File]::ReadAllBytes($e.ConfigFile)
        $unrelated = Copy-PersonaTestValue $e.Config; $unrelated.personas.accountMappings.bob = 'unrelated@other.example.invalid'
        $none = Sync-SeedResolvedAccountMappings -Config $unrelated -ConfigPath $e.ConfigFile -ExpectedHash $e.ConfigHash
        Assert-Equal $none.Status 'NoProof'
        $bindingPath = $e.Config.personas.bindingPath; $journalPath = $bindingPath + '.journal.json'
        foreach ($tamper in @('BindingUpn', 'JournalStatus', 'MissingJournal')) {
            $bindingBytes = [IO.File]::ReadAllBytes($bindingPath); $journalBytes = [IO.File]::ReadAllBytes($journalPath)
            switch ($tamper) {
                'BindingUpn' { $b = Get-Content -LiteralPath $bindingPath -Raw | ConvertFrom-Json -AsHashtable; $b.users.bob.upn = 'tampered@other.example.invalid'; [IO.File]::WriteAllText($bindingPath, ($b | ConvertTo-Json -Depth 100 -Compress)) }
                'JournalStatus' { $j = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json -AsHashtable; $j.status = 'Blocked'; [IO.File]::WriteAllText($journalPath, ($j | ConvertTo-Json -Depth 100 -Compress)) }
                'MissingJournal' { Remove-Item -LiteralPath $journalPath }
            }
            $result = Sync-SeedResolvedAccountMappings -Config $e.Config -ConfigPath $e.ConfigFile -ExpectedHash $e.ConfigHash
            Assert-Equal $result.Status 'NoProof' $tamper
            Assert-Equal (Get-FileHash -LiteralPath $e.ConfigFile).Hash $e.ConfigHash "$tamper changed the config."
            [IO.File]::WriteAllBytes($bindingPath, $bindingBytes); [IO.File]::WriteAllBytes($journalPath, $journalBytes)
        }
        $sync = Sync-SeedResolvedAccountMappings -Config $e.Config -ConfigPath $e.ConfigFile -ExpectedHash $e.ConfigHash
        Assert-Equal $sync.Status 'Saved'
        $saved = Get-Content -LiteralPath $e.ConfigFile -Raw | ConvertFrom-Json -AsHashtable
        Assert-Equal $saved.personas.accountMappings.bob 'bob.test@other.example.invalid'; Assert-Equal $saved.personas.accountMappings.alice 'existing-alice@example.invalid'
        $e.Config.personas.accountMappings.bob = $saved.personas.accountMappings.bob
        $e.ConfigHash = (Get-FileHash -LiteralPath $e.ConfigFile -Algorithm SHA256).Hash
        Assert-Equal (Sync-SeedResolvedAccountMappings -Config $e.Config -ConfigPath $e.ConfigFile -ExpectedHash $e.ConfigHash).Status 'NoChange'
        Assert-True ($e.ConfigHash -cne (Get-FileHash -InputStream ([IO.MemoryStream]::new($original)) -Algorithm SHA256).Hash)
    }
    Test-Case 'Local selection answers map only a displayed candidate number or an explicit replace:UPN, and everything else cancels' {
        $candidates = @(@{ ObjectId = 'a-id'; Basis = 'ExactName' }, @{ ObjectId = 'b-id'; Basis = 'Prefix' }, @{ ObjectId = 'c-id'; Basis = 'AvailablePage' })
        $one = ConvertTo-SeedAccountSelection -Answer ' 1 ' -Candidates $candidates
        Assert-Equal $one.Method 'UserSelectedCandidate'; Assert-Equal $one.ObjectId 'a-id'
        Assert-Equal (ConvertTo-SeedAccountSelection -Answer '2' -Candidates $candidates).Method 'UserSelectedCandidate'
        $listed = ConvertTo-SeedAccountSelection -Answer '3' -Candidates $candidates
        Assert-Equal $listed.Method 'UserSelectedReplacement'; Assert-Equal $listed.ObjectId 'c-id'
        $typed = ConvertTo-SeedAccountSelection -Answer 'replace: Other.Person@contoso.example' -Candidates @()
        Assert-Equal $typed.Method 'UserSelectedReplacement'; Assert-Equal $typed.Upn 'Other.Person@contoso.example'; Assert-True (-not $typed.Contains('ObjectId'))
        foreach ($cancel in @($null, '', '  ', '0', '4', '01', 'yes', 'replace:', 'replace:not-a-upn', 'replace: a@b.c d@e.f', '1;2', '-1')) {
            Assert-Equal $null (ConvertTo-SeedAccountSelection -Answer $cancel -Candidates $candidates)
        }
        Assert-Equal $null (ConvertTo-SeedAccountSelection -Answer '1' -Candidates @())
    }
} finally {
    foreach ($record in @($script:SeedSessions.Values)) { Close-SeedSession $record.Handle }
    Remove-Item -LiteralPath $personaScratch -Recurse -Force
}
