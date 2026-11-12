if (-not (Get-Variable SeedPersonaPlans -Scope Script -ErrorAction SilentlyContinue)) { $script:SeedPersonaPlans = @{} }

function Assert-SeedPersonaAdmin {
    param($Session, $Config)
    $record = Get-SeedSessionRecord $Session
    if ($record.Kind -cne 'App' -or $record.Mode -cne 'InitializePersonas') { throw 'Seed.Persona.Session: Only the dedicated application initialization session is permitted.' }
    Assert-SeedSchema $Config config
    Assert-SeedFields $Config @('personas') 'Seed.Input.Config'
    if ($record.TenantId -ine $Config.tenantId -or $record.ClientId -ine $Config.clientId -or
        ($Config.Contains('adminAuth') -and $Config.adminAuth.Contains('clientId') -and $Config.adminAuth.clientId -ine $Config.clientId)) {
        throw 'Seed.Persona.Session: Tenant or application client differs.'
    }
    Assert-SeedAppSessionReady $Session
    foreach ($role in @(Get-SeedManagementAppRoles InitializePersonas -AccountSource (Get-SeedPersonaAccountSource $Config))) {
        if (-not (Test-SeedAppPermission -Granted $record.Permissions -Required $role)) { throw "Seed.Persona.Scope: Missing application role: $role" }
    }
    $protectedUpn = $Config.presenterUpn
    if ($Config.Contains('adminAuth') -and $Config.adminAuth.Contains('adminOperatorUpn')) { $protectedUpn = $Config.adminAuth.adminOperatorUpn }
    $protected = ConvertTo-SeedMap (Invoke-SeedGraph -Session $Session -Method GET -Path ('/users/' + [uri]::EscapeDataString($protectedUpn) + '?$select=id,userPrincipalName,accountEnabled,userType'))
    Assert-SeedFields $protected @('id','userPrincipalName') 'Seed.Persona.ProtectedAccount'
    Assert-SeedGuid $protected.id
    if ($protected.userPrincipalName -ine $protectedUpn) { throw 'Seed.Persona.ProtectedAccount: Protected account identity differs.' }
    return $protected.id.ToLowerInvariant()
}

function Read-SeedPersonaSource {
    param($Config)
    $secretNames = @()
    if ($Config.Contains('clientSecretEnvironmentVariable')) {
        $null = $script:SeedSecretEnvironmentVariables.Add($Config.clientSecretEnvironmentVariable)
        $secretNames = @($Config.clientSecretEnvironmentVariable)
    }
    Invoke-SeedPython -SecretEnvironmentVariables $secretNames -InputObject @{ path = [IO.Path]::GetFullPath($Config.personas.packPath) } -Code @'
import json,sys,base64
from pathlib import Path
sys.path.insert(0,str(Path.cwd()))
from generator.validate_pack import validate_files,load_json,safe_path,sha256,canonical_bytes
from generator.build_scenario import persona_fingerprint
d=json.load(sys.stdin); path=Path(d["path"])
if validate_files(personas_path=path): raise ValueError("Invalid public persona pack")
p=load_json(path); photos={}; hashes={}
for a in p.get("avatarAssets",[]):
    b=safe_path(path.parent,a["path"]).read_bytes()
    if sha256(b)!=a["sha256"]: raise ValueError("Source changed")
    photos[a["id"]]=base64.b64encode(b).decode("ascii")
    hashes[a["path"].replace("/","\\")]=sha256(b)
    raw=a["rights"]["evidencePath"]
    hashes[raw.replace("/","\\")]=sha256(safe_path(path.parent,raw).read_bytes())
fp=sha256(canonical_bytes({"personas":p,"files":hashes}))
if fp!=persona_fingerprint(path): raise ValueError("Source changed")
print(json.dumps({"Personas":p,"Fingerprint":fp,"Photos":photos},ensure_ascii=False))
'@
}

function Get-SeedPersonaBytesHash {
    param([byte[]]$Bytes)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Get-SeedPersonaRemoteState {
    param($Session, [string]$ObjectId, [string]$Upn, [string]$PresenterId)
    Assert-SeedGuid $ObjectId
    if ($ObjectId -ieq $PresenterId) { throw 'Seed.Persona.Presenter: Presenter is absolutely excluded.' }
    $p = ConvertTo-SeedMap (Invoke-SeedGraph -Session $Session -Method GET -Path "/users/$ObjectId`?`$select=id,userPrincipalName,displayName,jobTitle,department,companyName,officeLocation,usageLocation,accountEnabled,userType,onPremisesSyncEnabled,assignedLicenses,licenseAssignmentStates")
    Assert-SeedFields $p @('id', 'userPrincipalName', 'accountEnabled', 'userType', 'assignedLicenses', 'licenseAssignmentStates') 'Seed.Persona.ReadBack'
    foreach ($field in @('displayName', 'jobTitle', 'department', 'companyName', 'officeLocation', 'usageLocation', 'onPremisesSyncEnabled')) {
        if (-not $p.Contains($field)) { throw 'Seed.Persona.ReadBack: Required profile evidence is missing.' }
    }
    if ($p.id -ine $ObjectId -or $p.userPrincipalName -ine $Upn -or $p.userType -cne 'Member' -or $p.accountEnabled -isnot [bool] -or -not $p.accountEnabled -or
        ($null -ne $p.onPremisesSyncEnabled -and $p.onPremisesSyncEnabled -cne $false) -or $p.assignedLicenses -isnot [System.Collections.IList] -or $p.licenseAssignmentStates -isnot [System.Collections.IList]) {
        throw 'Seed.Persona.ReadBack: The expected enabled cloud Member identity is not proven.'
    }
    $profile = @{}
    foreach ($field in @('displayName', 'jobTitle', 'department', 'companyName', 'officeLocation', 'usageLocation')) { $profile[$field] = $p[$field] }
    $manager = $null; $photoHash = $null
    try {
        $m = ConvertTo-SeedMap (Invoke-SeedGraph -Session $Session -Method GET -Path "/users/$ObjectId/manager?`$select=id")
        Assert-SeedFields $m @('id') 'Seed.Persona.Manager'; Assert-SeedGuid $m.id
        $manager = $m.id.ToLowerInvariant()
    } catch { if ($_.Exception.Message -notlike 'Seed.Graph.404:*') { throw } }
    try {
        $photo = Invoke-SeedGraph -Session $Session -Method GET -Path "/users/$ObjectId/photo/`$value"
        if ($photo -isnot [byte[]] -or $photo.Length -lt 4 -or $photo[0] -ne 255 -or $photo[1] -ne 216) { throw 'Seed.Persona.Photo: Authoritative JPEG bytes are required.' }
        $photoHash = Get-SeedPersonaBytesHash $photo
    } catch { if ($_.Exception.Message -notlike 'Seed.Graph.404:*') { throw } }
    $licenses = @()
    foreach ($license in $p.assignedLicenses) {
        Assert-SeedFields $license @('skuId', 'disabledPlans') 'Seed.Persona.License'
        Assert-SeedGuid $license.skuId
        if (@($license.disabledPlans).Count -ne 0) { throw 'Seed.Persona.License: Existing service settings cannot be changed.' }
        $licenses += $license.skuId.ToLowerInvariant()
    }
    if (@($licenses | Sort-Object -Unique).Count -ne $licenses.Count) { throw 'Seed.Persona.License: Duplicate SKU evidence.' }
    $states = @()
    foreach ($s in $p.licenseAssignmentStates) {
        Assert-SeedFields $s @('skuId', 'state', 'disabledPlans') 'Seed.Persona.License'
        Assert-SeedGuid $s.skuId
        if ($s.state -cne 'Active' -or ($s.Contains('error') -and $null -ne $s.error -and $s.error -cne 'None') -or
            -not $s.Contains('assignedByGroup') -or $null -ne $s.assignedByGroup -or @($s.disabledPlans).Count -ne 0) {
            throw 'Seed.Persona.License: Pending, unknown, inherited or failed assignments are not provisioning evidence.'
        }
        $states += $s.skuId.ToLowerInvariant()
    }
    if ((@($licenses | Sort-Object) -join ',') -cne (@($states | Sort-Object) -join ',')) { throw 'Seed.Persona.License: Actual SKU sets and assignment states differ.' }
    return @{ ObjectId = $ObjectId.ToLowerInvariant(); Upn = $Upn.ToLowerInvariant(); Profile = $profile; ManagerObjectId = $manager; PhotoSha256 = $photoHash; SkuIds = @($licenses | Sort-Object); AssignmentStatus = 'Active' }
}

function Write-SeedPersonaFile {
    param([string]$Path, $Value, [string]$ExpectedHash)
    $Path = Assert-SeedStatePath $Path
    Assert-SeedNoSecrets $Value
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 100 -Compress) + "`n")
    $staging = $Path + '.new-' + [guid]::NewGuid().ToString('N')
    try {
        $stream = [IO.FileStream]::new($staging, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
        try { $stream.Write($bytes); $stream.Flush($true) } finally { $stream.Dispose() }
        if ($ExpectedHash) {
            if (-not (Test-Path -LiteralPath $Path) -or (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -cne $ExpectedHash) { throw 'Seed.Persona.Journal: Existing state changed; preserved without replacement.' }
            [IO.File]::Replace($staging, $Path, [System.Management.Automation.Language.NullString]::Value)
        } else { [IO.File]::Move($staging, $Path, $false) }
    } finally { if (Test-Path -LiteralPath $staging) { [IO.File]::Delete($staging) } }
}

function Save-SeedPersonaJournal {
    param($Store)
    $j = $Store.Value
    $j.Remove('fingerprint')
    $j.fingerprint = Get-SeedFingerprint $j
    Write-SeedPersonaFile -Path $Store.Path -Value $j -ExpectedHash $Store.FileHash
    $Store.FileHash = (Get-FileHash -LiteralPath $Store.Path -Algorithm SHA256).Hash
}

function Get-SeedPersonaPrior {
    param($Config, $Source)
    $path = Assert-SeedStatePath ($Config.personas.bindingPath + '.journal.json')
    $bindingPath = Assert-SeedStatePath $Config.personas.bindingPath
    $context = @{
        tenantId = $Config.tenantId.ToLowerInvariant(); clientId = $Config.clientId.ToLowerInvariant()
        packId = $Source.Personas.packId; instanceId = $Config.personas.instanceId
        accountPrefix = $Config.personas.accountPrefix; userDomain = $Config.personas.userDomain.ToLowerInvariant()
        presenterUpn = $Config.presenterUpn.ToLowerInvariant(); engineVersion = '1.0.0'
    }
    $prior = @{ Path = $path; FileHash = $null; Value = $null; Binding = $null; BindingFileHash = $null; Context = $context }
    if (-not (Test-Path -LiteralPath $path)) {
        if (Test-Path -LiteralPath $bindingPath) { throw 'Seed.Persona.Journal: A binding without completed creation provenance cannot authorize adoption.' }
        return $prior
    }
    try {
        $j = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
        Assert-SeedFields $j @('schemaVersion', 'context', 'status', 'plans', 'events', 'createdIds', 'bindingFingerprint', 'fingerprint') 'Seed.Persona.Journal'
        $hash = $j.fingerprint; $j.Remove('fingerprint')
        if ((Get-SeedFingerprint $j) -cne $hash -or $j.schemaVersion -cne '1.0' -or $j.status -cne 'Completed' -or
            (Get-SeedFingerprint $j.context) -cne (Get-SeedFingerprint $context)) { throw 'invalid' }
        $j.fingerprint = $hash
        if (@($j.events | Where-Object status -ne Verified).Count -ne 0) { throw 'incomplete' }
        $b = Get-Content -LiteralPath $bindingPath -Raw | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
        Assert-SeedSchema $b persona-binding
        if ((Get-SeedFingerprint $b) -cne $j.bindingFingerprint -or $b.tenantId -ine $context.tenantId -or
            $b.packId -cne $context.packId -or $b.instanceId -cne $context.instanceId -or $b.users.Count -ne $j.createdIds.Count) { throw 'binding' }
        $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($key in $b.users.Keys) {
            $u = $b.users[$key]
            $created = @($j.events | Where-Object { $_.kind -ceq 'Create' -and $_.personaId -ceq $key -and $_.status -ceq 'Verified' -and $_.objectId -ieq $u.objectId })
            if (-not $j.createdIds.Contains($key) -or $j.createdIds[$key] -ine $u.objectId -or $created.Count -ne 1 -or -not $ids.Add($u.objectId)) { throw 'identity' }
            $profile = ConvertTo-SeedMap $u.profile; $profile.Remove('sha256'); $profile.Remove('verifiedAt')
            if ((Get-SeedFingerprint $profile) -cne $u.profile.sha256) { throw 'profile' }
        }
        $prior.Value = $j; $prior.Binding = $b
        $prior.FileHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        $prior.BindingFileHash = (Get-FileHash -LiteralPath $bindingPath -Algorithm SHA256).Hash
        return $prior
    } catch { throw 'Seed.Persona.Journal: Partial, pending, unknown, changed or unproven state is blocked; never resume or adopt by name.' }
}

function Get-SeedPersonaSeatPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Requirements, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Subscriptions)
    foreach ($sku in @($Requirements.Keys | Sort-Object)) {
        Assert-SeedGuid $sku
        if ($Requirements[$sku] -isnot [int] -and $Requirements[$sku] -isnot [long] -or $Requirements[$sku] -lt 0) { throw 'Seed.Persona.Seats: Invalid whole-batch seat requirement.' }
        $found = @($Subscriptions | Where-Object { $_.Contains('skuId') -and $_.skuId -ieq $sku })
        if ($found.Count -ne 1) { throw 'Seed.Persona.Seats: Every selected SKU must be an existing subscription.' }
        $s = $found[0]; Assert-SeedFields $s @('capabilityStatus', 'consumedUnits', 'prepaidUnits') 'Seed.Persona.Seats'
        Assert-SeedFields $s.prepaidUnits @('enabled') 'Seed.Persona.Seats'
        if ($s.capabilityStatus -cne 'Enabled' -or $s.consumedUnits -isnot [long] -and $s.consumedUnits -isnot [int] -or
            $s.prepaidUnits.enabled -isnot [long] -and $s.prepaidUnits.enabled -isnot [int] -or $s.consumedUnits -lt 0 -or $s.prepaidUnits.enabled -lt 0) { throw 'Seed.Persona.Seats: Exact enabled subscription counts are required.' }
        $remaining = $s.prepaidUnits.enabled - $s.consumedUnits
        if ($Requirements[$sku] -gt $remaining) { throw 'Seed.Persona.Seats: Insufficient existing seats for the entire batch.' }
        @{ SkuId = $sku; Required = $Requirements[$sku]; Remaining = $remaining; RemainingAfter = $remaining - $Requirements[$sku] }
    }
}

function ConvertTo-SeedDisplayText {
    # Tenant strings are shown with control/format characters escaped; the written value and fingerprint are never altered.
    param($Value)
    if ($null -eq $Value) { return '<null>' }
    return [regex]::Replace([string]$Value, '[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]', { param($m) '\u{' + ([int][char]$m.Value[0]).ToString('X4') + '}' })
}

function Format-SeedPersonaValue {
    param($Value)
    if ($null -eq $Value) { return '<null>' }
    if ($Value -is [System.Collections.IDictionary] -or ($Value -is [System.Collections.IList] -and $Value -isnot [string])) { return ConvertTo-SeedDisplayText ($Value | ConvertTo-Json -Depth 10 -Compress) }
    return '"' + (ConvertTo-SeedDisplayText $Value) + '"'
}

function New-SeedPersonaBlock {
    # A content-level Existing-account block: a row is marked Block, while Graph/permission failures still stop the whole plan.
    param([Parameter(Mandatory)][string]$Code, [Parameter(Mandatory)][string]$Message)
    return [InvalidOperationException]::new("$Code`: $Message")
}

function Get-SeedPersonaLicenseDigest {
    # Existing licenses and disabled plans are evidence to keep unchanged, never a precondition or something to repair.
    param($User)
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($license in @($User['assignedLicenses'])) {
        $plans = @(); if ($license.Contains('disabledPlans') -and $null -ne $license['disabledPlans']) { $plans = @($license['disabledPlans'] | ForEach-Object { [string]$_ } | Sort-Object) }
        $lines.Add("A|$($license['skuId'])|$($plans -join ',')")
    }
    foreach ($state in @($User['licenseAssignmentStates'])) {
        $plans = @(); if ($state.Contains('disabledPlans') -and $null -ne $state['disabledPlans']) { $plans = @($state['disabledPlans'] | ForEach-Object { [string]$_ } | Sort-Object) }
        $lines.Add("S|$($state['skuId'])|$($state['state'])|$($state['error'])|$($state['assignedByGroup'])|$($plans -join ',')")
    }
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((@($lines | Sort-Object) -join "`n")))).ToLowerInvariant()
}

function Get-SeedExistingPersonaState {
    param($Session, [string]$ObjectId, [string]$Upn)
    Assert-SeedGuid $ObjectId
    $p = ConvertTo-SeedMap (Invoke-SeedGraph -Session $Session -Method GET -Path "/users/$ObjectId`?`$select=id,userPrincipalName,displayName,jobTitle,department,companyName,officeLocation,usageLocation,accountEnabled,userType,onPremisesSyncEnabled,assignedLicenses,licenseAssignmentStates")
    foreach ($field in @('id', 'userPrincipalName', 'displayName', 'jobTitle', 'department', 'companyName', 'officeLocation', 'usageLocation', 'accountEnabled', 'userType', 'onPremisesSyncEnabled', 'assignedLicenses', 'licenseAssignmentStates')) {
        if (-not $p.Contains($field)) { throw (New-SeedPersonaBlock 'Seed.Persona.Identity' 'Required read-back evidence is missing; absent fields are never defaulted.') }
    }
    if ($p.id -isnot [string] -or $p.userPrincipalName -isnot [string] -or $p.id -ine $ObjectId -or $p.userPrincipalName -ine $Upn -or $p.userType -cne 'Member' -or
        $p.accountEnabled -isnot [bool] -or -not $p.accountEnabled -or ($null -ne $p.onPremisesSyncEnabled -and $p.onPremisesSyncEnabled -cne $false) -or
        $p.assignedLicenses -isnot [System.Collections.IList] -or $p.licenseAssignmentStates -isnot [System.Collections.IList]) {
        throw (New-SeedPersonaBlock 'Seed.Persona.Identity' 'The expected enabled cloud Member identity is not proven.')
    }
    $profile = @{}
    foreach ($field in @('displayName', 'jobTitle', 'department', 'companyName', 'officeLocation', 'usageLocation')) { $profile[$field] = $p[$field] }
    if ($profile.displayName -isnot [string] -or [string]::IsNullOrWhiteSpace($profile.displayName) -or
        @('jobTitle', 'department', 'companyName', 'officeLocation' | Where-Object { $null -ne $profile[$_] -and $profile[$_] -isnot [string] }).Count -gt 0 -or
        ($null -ne $profile.usageLocation -and ($profile.usageLocation -isnot [string] -or $profile.usageLocation -cnotmatch '^([A-Z]{2})?$'))) {
        throw (New-SeedPersonaBlock 'Seed.Persona.Snapshot' 'The actual profile cannot be stored as a verified snapshot (name must be text; other fields text or null).')
    }
    $manager = $null
    try {
        $m = ConvertTo-SeedMap (Invoke-SeedGraph -Session $Session -Method GET -Path "/users/$ObjectId/manager?`$select=id")
        Assert-SeedFields $m @('id') 'Seed.Persona.Manager'; Assert-SeedGuid $m.id
        $manager = $m.id.ToLowerInvariant()
    } catch { if ($_.Exception.Message -notlike 'Seed.Graph.404:*') { throw } }
    return @{ ObjectId = $p.id.ToLowerInvariant(); Upn = $p.userPrincipalName.ToLowerInvariant(); Profile = $profile; ManagerObjectId = $manager; LicenseDigest = (Get-SeedPersonaLicenseDigest $p) }
}

function Test-SeedExistingPersonaStateEqual {
    param($Left, $Right)
    if ($null -eq $Left -or $null -eq $Right -or $Left.ObjectId -cne $Right.ObjectId -or $Left.Upn -cne $Right.Upn -or
        $Left.LicenseDigest -cne $Right.LicenseDigest -or $Left.ManagerObjectId -cne $Right.ManagerObjectId) { return $false }
    foreach ($field in @('displayName', 'jobTitle', 'department', 'companyName', 'officeLocation', 'usageLocation')) {
        if ($Left.Profile[$field] -cne $Right.Profile[$field]) { return $false }
    }
    return $true
}

function Get-SeedExistingManagerId {
    param($Session, [string]$ObjectId, [hashtable]$Cache)
    if ($Cache.ContainsKey($ObjectId)) { return $Cache[$ObjectId] }
    $manager = $null
    try {
        $m = ConvertTo-SeedMap (Invoke-SeedGraph -Session $Session -Method GET -Path "/users/$ObjectId/manager?`$select=id")
        Assert-SeedFields $m @('id') 'Seed.Persona.Manager'; Assert-SeedGuid $m.id
        $manager = $m.id.ToLowerInvariant()
    } catch { if ($_.Exception.Message -notlike 'Seed.Graph.404:*') { throw } }
    $Cache[$ObjectId] = $manager
    return $manager
}

function Get-SeedExistingManagerLabel {
    # Local-only identification of an outside manager; the manager is read, never changed.
    param($Session, [string]$ObjectId)
    try {
        $u = ConvertTo-SeedMap (Invoke-SeedGraph -Session $Session -Method GET -Path "/users/$ObjectId`?`$select=id,displayName,userPrincipalName")
        if ($u.Contains('displayName') -and $u.Contains('userPrincipalName') -and $u['displayName'] -is [string] -and $u['userPrincipalName'] -is [string]) { return "$($u['displayName']) <$($u['userPrincipalName'])>" }
    } catch { if ($_.Exception.Message -notlike 'Seed.Graph.404:*') { throw } }
    return 'outside directory object (identity not resolvable as a user)'
}

function Get-SeedExistingSelectionFingerprint {
    param([Parameter(Mandatory)][hashtable]$Mappings)
    $selected = [ordered]@{}
    foreach ($key in @($Mappings.Keys | Sort-Object)) { $selected[$key] = $Mappings[$key] }
    return Get-SeedFingerprint $selected
}

function Read-SeedExistingJournal {
    param([string]$Path)
    $j = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
    Assert-SeedFields $j @('schemaVersion', 'accountSource', 'context', 'status', 'plans', 'events', 'boundIds', 'bindingFingerprint', 'fingerprint') 'Seed.Persona.Journal'
    $copy = ConvertTo-SeedMap $j; $copy.Remove('fingerprint')
    if ((Get-SeedFingerprint $copy) -cne $j.fingerprint -or $j.schemaVersion -cne '1.1' -or $j.accountSource -cne 'Existing') { throw 'invalid' }
    return $j
}

function Assert-SeedExistingJournalEvidence {
    # Only a Completed journal whose BindExisting events match the binding, with no Create source, is completion evidence.
    param($Journal, $Binding)
    if ($Journal.status -cne 'Completed' -or @($Journal.events | Where-Object { $_.status -cne 'Verified' }).Count -ne 0 -or
        @($Journal.events | Where-Object { $_.kind -ceq 'Create' }).Count -ne 0 -or
        $Journal.context.tenantId -ine $Binding.tenantId -or $Journal.context.packId -cne $Binding.packId -or $Journal.context.instanceId -cne $Binding.instanceId -or
        $Journal.context.accountSource -cne 'Existing' -or $Journal.bindingFingerprint -cne (Get-SeedFingerprint $Binding) -or
        $Binding.users.Count -ne $Journal.boundIds.Count -or $Binding.approval.journalFingerprint -cne (Get-SeedFingerprint @{ events = @($Journal.events) }) -or
        @($Journal.plans | Where-Object { $_.fingerprint -ceq $Binding.approval.planFingerprint }).Count -lt 1) { throw 'evidence' }
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($key in $Binding.users.Keys) {
        $user = $Binding.users[$key]
        $bound = @($Journal.events | Where-Object { $_.kind -ceq 'BindExisting' -and $_.personaId -ceq $key -and $_.status -ceq 'Verified' -and $_.objectId -ieq $user.objectId })
        if ($bound.Count -ne 1 -or -not $Journal.boundIds.Contains($key) -or $Journal.boundIds[$key] -ine $user.objectId -or -not $ids.Add($user.objectId)) { throw 'identity' }
        $profile = ConvertTo-SeedMap $user.profile; $profile.Remove('sha256'); $profile.Remove('verifiedAt')
        if ((Get-SeedFingerprint $profile) -cne $user.profile.sha256) { throw 'profile' }
    }
}

function Assert-SeedExistingBindingEvidence {
    # RunAll uses this: a bare mapping or public ID never stands in for the completed BindExisting journal.
    param($Config, $Binding)
    try {
        $path = Assert-SeedStatePath ($Config.personas.bindingPath + '.journal.json')
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'missing' }
        Assert-SeedExistingJournalEvidence -Journal (Read-SeedExistingJournal $path) -Binding $Binding
    } catch { throw 'Seed.Binding.Evidence: The completed BindExisting journal for this exact binding is required; a bare mapping or partial journal is never evidence.' }
}

function Get-SeedExistingPersonaPrior {
    param($Config, $Source, [string]$SelectionFingerprint)
    $path = Assert-SeedStatePath ($Config.personas.bindingPath + '.journal.json')
    $bindingPath = Assert-SeedStatePath $Config.personas.bindingPath
    $context = @{
        tenantId = $Config.tenantId.ToLowerInvariant(); clientId = $Config.clientId.ToLowerInvariant(); accountSource = 'Existing'
        packId = $Source.Personas.packId; instanceId = $Config.personas.instanceId; presenterUpn = $Config.presenterUpn.ToLowerInvariant()
        selectionFingerprint = $SelectionFingerprint; engineVersion = '1.0.0'
    }
    $prior = @{ Path = $path; FileHash = $null; Value = $null; Binding = $null; BindingFileHash = $null; Context = $context }
    if (-not (Test-Path -LiteralPath $path)) {
        if (Test-Path -LiteralPath $bindingPath) { throw 'Seed.Persona.Journal: A binding without completed BindExisting provenance cannot authorize adoption.' }
        return $prior
    }
    try {
        $j = Read-SeedExistingJournal $path
        $b = Get-Content -LiteralPath $bindingPath -Raw | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
        Assert-SeedSchema $b persona-binding
        $without = ConvertTo-SeedMap $j; $without.Remove('fingerprint')
        if ($b.version -cne '1.1' -or $b.accountSource -cne 'Existing' -or (Get-SeedFingerprint $without.context) -cne (Get-SeedFingerprint $context) -or $b.fingerprint -cne $Source.Fingerprint) { throw 'context' }
        Assert-SeedExistingJournalEvidence -Journal $j -Binding $b
        $prior.Value = $j; $prior.Binding = $b
        $prior.FileHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        $prior.BindingFileHash = (Get-FileHash -LiteralPath $bindingPath -Algorithm SHA256).Hash
        return $prior
    } catch { throw 'Seed.Persona.Journal: Partial, pending, unknown, changed or unproven state is blocked; never resume or adopt by name.' }
}

function New-SeedExistingBinding {
    param($Config, $Preview, [hashtable]$States, [string]$PlanFingerprint, [string]$JournalFingerprint, [string]$At, [switch]$Projected)
    $binding = @{
        tenantId = $Config.tenantId; packId = $Preview.PackId; version = '1.1'; accountSource = 'Existing'; fingerprint = $Preview.PackFingerprint
        instanceId = $Config.personas.instanceId; status = 'ConfiguredExisting'; serviceStatus = 'NotVerified'
        approval = @{ planFingerprint = $PlanFingerprint; demoAccountAcknowledged = $true; journalFingerprint = $JournalFingerprint; acknowledgedAt = $At }
        users = @{}
    }
    foreach ($row in $Preview.Rows) {
        $state = $States[$row.PersonaId]
        $profile = ConvertTo-SeedMap $state.Profile
        $profile.managerObjectId = $state.ManagerObjectId
        $digest = if ($Projected) { '0' * 64 } else { Get-SeedFingerprint $profile }
        $profile.sha256 = $digest; $profile.verifiedAt = $At
        $binding.users[$row.PersonaId] = @{ objectId = $state.ObjectId; upn = $state.Upn; profile = $profile; status = 'ConfiguredExisting'; serviceStatus = 'NotVerified'; source = 'BindExisting' }
    }
    return $binding
}

function Get-SeedExistingMappingSelection {
    # The operator's explicit selection, checked before any tenant read: personas of the public pack, never the Presenter or the signed-in
    # operator, one account per persona, and every selected persona's manager selected too (the selection is never expanded).
    param($Config, $Pack)
    $people = @{}
    foreach ($p in $Pack.people) { $people[$p.personaId] = $p }
    $operatorUpn = $Config.presenterUpn
    if ($Config.Contains('adminAuth') -and $Config.adminAuth.Contains('adminOperatorUpn')) { $operatorUpn = $Config.adminAuth.adminOperatorUpn }
    $mappings = @{}; $seenUpns = @{}
    foreach ($key in @($Config.personas.accountMappings.Keys | Sort-Object)) {
        if (-not $people.ContainsKey($key)) { throw 'Seed.Persona.Selection: Every selected persona must be defined by the public pack.' }
        $upn = ([string]$Config.personas.accountMappings[$key]).ToLowerInvariant()
        if ($upn -ieq $Config.presenterUpn -or $upn -ieq $operatorUpn) { throw 'Seed.Persona.Presenter: Presenter and the explicitly protected legacy account can never be selected as Demo accounts.' }
        if ($seenUpns.ContainsKey($upn)) { throw 'Seed.Persona.Selection: One account cannot be mapped to two personas.' }
        $seenUpns[$upn] = $key; $mappings[$key] = $upn
    }
    foreach ($key in $mappings.Keys) {
        $target = $people[$key]['managerRef']
        if ($null -ne $target -and -not $mappings.ContainsKey($target)) { throw 'Seed.Persona.Manager: A selected persona names a manager who is not selected; the selection is never expanded automatically.' }
    }
    return @{ People = $people; Mappings = $mappings; OperatorUpn = $operatorUpn }
}

function Read-SeedExistingPresenter {
    param($Session, $Config)
    $presenter = ConvertTo-SeedMap (Invoke-SeedGraph -Session $Session -Method GET -Path ('/users/' + [uri]::EscapeDataString($Config.presenterUpn) + '?$select=id,userPrincipalName,accountEnabled,userType'))
    Assert-SeedFields $presenter @('id', 'userPrincipalName', 'accountEnabled', 'userType') 'Seed.Persona.Presenter'
    Assert-SeedGuid $presenter.id
    if ($presenter.userPrincipalName -ine $Config.presenterUpn -or $presenter.accountEnabled -cne $true -or $presenter.userType -cne 'Member') { throw 'Seed.Persona.Presenter: An existing enabled Member Presenter must be proven.' }
    return $presenter
}

function ConvertTo-SeedODataLiteral {
    param([Parameter(Mandatory)][string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function ConvertTo-SeedUserCandidate {
    # One directory user as a local candidate. Evidence that cannot be interpreted stops the lookup; it is never skipped to look unique.
    param($Entry)
    $u = ConvertTo-SeedMap $Entry
    if (-not $u.Contains('id') -or $u['id'] -isnot [string] -or $u['id'] -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' -or
        -not $u.Contains('userPrincipalName') -or $u['userPrincipalName'] -isnot [string] -or [string]::IsNullOrWhiteSpace($u['userPrincipalName'])) {
        throw 'Seed.Persona.Lookup: A directory candidate could not be interpreted; nothing was chosen.'
    }
    $text = { param($name) if ($u.Contains($name) -and $u[$name] -is [string]) { $u[$name] } else { $null } }
    return @{
        ObjectId = $u['id'].ToLowerInvariant(); Upn = $u['userPrincipalName'].ToLowerInvariant(); DisplayName = (& $text 'displayName'); MailNickname = (& $text 'mailNickname')
        Enabled = ($u.Contains('accountEnabled') -and $u['accountEnabled'] -is [bool] -and $u['accountEnabled'])
        Member = ($u.Contains('userType') -and $u['userType'] -ceq 'Member')
        Cloud = (-not $u.Contains('onPremisesSyncEnabled') -or $null -eq $u['onPremisesSyncEnabled'] -or $u['onPremisesSyncEnabled'] -ceq $false)
        Basis = $null
    }
}

function Read-SeedUserCandidates {
    # Bounded directory read of at most 20 users per page. -AllPages follows nextLink up to a hard page bound and reports Complete=$false when it
    # cannot finish (an incomplete list never proves uniqueness); otherwise exactly one page is read and Complete says whether the server had more.
    param($Session, [string]$Filter, [switch]$AllPages)
    $path = '/users?'
    if ($Filter) { $path += '$filter=' + [uri]::EscapeDataString($Filter) + '&' }
    $path += '$select=id,userPrincipalName,displayName,mailNickname,accountEnabled,userType,onPremisesSyncEnabled&$top=20'
    if ($AllPages) {
        try { $entries = @(Get-SeedGraphCollection -Session $Session -Path $path -MaxPages 5) }
        catch { if ($_.Exception.Message -like 'Seed.Pagination:*') { return @{ Items = @(); Complete = $false } } else { throw } }
        return @{ Items = @($entries | ForEach-Object { ConvertTo-SeedUserCandidate $_ }); Complete = $true }
    }
    $page = ConvertTo-SeedMap (Invoke-SeedGraph -Session $Session -Method GET -Path $path)
    Assert-SeedFields $page @('value') 'Seed.Pagination'
    if ($page.value -isnot [System.Collections.IList]) { throw 'Seed.Pagination: A collection response is required.' }
    return @{ Items = @($page.value | ForEach-Object { ConvertTo-SeedUserCandidate $_ }); Complete = (-not $page.Contains('@odata.nextLink') -or $null -eq $page['@odata.nextLink']) }
}

function Find-SeedExistingHintCandidates {
    # GET-only lookup of the public identity hint. Exact = the union of every page and both hints that equal the full name or alias (case and edge
    # spaces ignored, nothing fuzzy). Prefix = same first name, shown to the operator only and never counted as a match.
    param($Session, $Hint)
    $exact = @{}; $complete = $true
    $clauses = @()
    if ($Hint.DisplayName) { $clauses += "displayName eq $(ConvertTo-SeedODataLiteral $Hint.DisplayName)" }
    if ($Hint.Alias) { $clauses += "mailNickname eq $(ConvertTo-SeedODataLiteral $Hint.Alias)" }
    if ($clauses.Count -gt 0) {
        $query = Read-SeedUserCandidates -Session $Session -Filter ($clauses -join ' or ') -AllPages
        if (-not $query.Complete) { $complete = $false }
        foreach ($candidate in $query.Items) {
            $byName = [bool]$Hint.DisplayName -and $null -ne $candidate.DisplayName -and $candidate.DisplayName.Trim() -ieq $Hint.DisplayName
            $byAlias = [bool]$Hint.Alias -and $null -ne $candidate.MailNickname -and $candidate.MailNickname.Trim() -ieq $Hint.Alias
            if (-not $byName -and -not $byAlias) { continue }
            $candidate.Basis = $(if ($byName -and $byAlias) { 'ExactNameAndAlias' } elseif ($byName) { 'ExactName' } else { 'ExactAlias' })
            $exact[$candidate.ObjectId] = $candidate
        }
    }
    $prefix = @{}
    $first = $(if ($Hint.DisplayName) { @($Hint.DisplayName -split '\s+')[0] } else { $null })
    if ($first -and $first.Length -ge 2) {
        foreach ($candidate in @((Read-SeedUserCandidates -Session $Session -Filter "startsWith(displayName,$(ConvertTo-SeedODataLiteral $first))").Items)) {
            if ($exact.ContainsKey($candidate.ObjectId)) { continue }
            $candidate.Basis = 'Prefix'; $prefix[$candidate.ObjectId] = $candidate
        }
    }
    return @{ Exact = @($exact.Values | Sort-Object { $_.Upn }); Prefix = @($prefix.Values | Sort-Object { $_.Upn }); Complete = $complete }
}

function Resolve-SeedExistingAccountMappings {
    # Read-only (GET) resolution of the operator's private accountMappings before the plan. An existing exact UPN is never replaced and a
    # failed read is never "missing". Only a first-time (unbound) 404 triggers the bounded exact-hint lookup; one complete, eligible exact
    # match is only a proposal that the whole-batch preview and the real confirmation still show. Ambiguous, similar, absent, ineligible or
    # already used matches are returned as Unresolved for ONE explicit local Selection (data from the trusted host); nothing is guessed.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Personas, $Selection = $null)
    $record = Get-SeedSessionRecord $Session
    if ($record.Kind -cne 'App' -or $record.Mode -cne 'InitializePersonas') { throw 'Seed.Persona.Session: A dedicated application session is required.' }
    $Config = ConvertTo-SeedMap $Config; $Personas = ConvertTo-SeedMap $Personas
    $chosen = $(if ($null -eq $Selection) { @{} } else { ConvertTo-SeedMap $Selection })
    Assert-SeedSchema $Config config
    if ((Get-SeedPersonaAccountSource $Config) -cne 'Existing') { throw 'Seed.Persona.Source: Account resolution applies only to Existing accounts.' }
    Assert-SeedFields $Personas @('people') 'Seed.Persona.Source'
    $selected = Get-SeedExistingMappingSelection -Config $Config -Pack $Personas
    $mappings = $selected.Mappings
    $effective = ConvertTo-SeedMap $Config
    # An initialization that already started or completed pins its actual identities: never re-resolved by name, never rebound.
    $bindingPath = Assert-SeedStatePath $Config.personas.bindingPath
    $journalPath = Assert-SeedStatePath ($Config.personas.bindingPath + '.journal.json')
    if ((Test-Path -LiteralPath $bindingPath) -or (Test-Path -LiteralPath $journalPath)) {
        if ($chosen.Count -gt 0) { throw 'Seed.Persona.Selection: A selection cannot change the accounts of an initialization that already has a binding or journal.' }
        return @{ EffectiveConfig = $effective; Resolutions = @(); Unresolved = @() }
    }
    $record.ReadOnlyDepth++
    try {
        $operatorId = Assert-SeedPersonaAdmin $Session $Config
        $presenter = Read-SeedExistingPresenter $Session $Config
        $excludedIds = @($presenter.id.ToLowerInvariant(), $operatorId)
        $excludedUpns = @($Config.presenterUpn.ToLowerInvariant(), ([string]$selected.OperatorUpn).ToLowerInvariant())
        $eligible = { param($c) $c.Enabled -and $c.Member -and $c.Cloud -and $c.ObjectId -cnotin $excludedIds -and $c.Upn -cnotin $excludedUpns }
        $resolved = @{}; $missing = [Collections.Generic.List[string]]::new()
        foreach ($personaId in @($mappings.Keys | Sort-Object)) {
            $requested = $mappings[$personaId]
            try { $found = ConvertTo-SeedMap (Invoke-SeedGraph -Session $Session -Method GET -Path ('/users/' + [uri]::EscapeDataString($requested) + '?$select=id,userPrincipalName')) }
            catch { if ($_.Exception.Message -like 'Seed.Graph.404:*') { $missing.Add($personaId); continue } else { throw } }
            if (-not $found.Contains('id') -or $found['id'] -isnot [string] -or $found['id'] -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' -or
                -not $found.Contains('userPrincipalName') -or $found['userPrincipalName'] -isnot [string] -or $found['userPrincipalName'] -ine $requested) {
                throw 'Seed.Persona.Identity: The exact UPN lookup did not return the same account; there is no name fallback for an account that exists.'
            }
            $resolved[$personaId] = @{ PersonaId = $personaId; RequestedUpn = $requested; ResolvedUpn = $requested; ObjectId = $found['id'].ToLowerInvariant(); Method = 'ExactUpn'; Basis = $null }
        }
        foreach ($key in @($chosen.Keys)) {
            if (-not $missing.Contains($key)) { throw 'Seed.Persona.Selection: A selection can only choose an account for a persona whose requested UPN was not found; an existing exact UPN is never replaced.' }
        }
        $lookups = @{}
        foreach ($personaId in @($missing)) {
            $person = $selected.People[$personaId]
            $hint = @{ DisplayName = $null; Alias = $null }
            if ($person.Contains('identityHint') -and $person.identityHint -is [System.Collections.IDictionary]) {
                if ($person.identityHint.Contains('displayName') -and $person.identityHint.displayName -is [string]) { $hint.DisplayName = $person.identityHint.displayName.Trim() }
                if ($person.identityHint.Contains('alias') -and $person.identityHint.alias -is [string]) { $hint.Alias = $person.identityHint.alias.Trim() }
            }
            $lookups[$personaId] = @{ Hint = $hint; Found = (Find-SeedExistingHintCandidates -Session $Session -Hint $hint) }
        }
        $claimed = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($row in $resolved.Values) { $null = $claimed.Add($row.ObjectId) }
        $selectionColumns = '?$select=id,userPrincipalName,displayName,mailNickname,accountEnabled,userType,onPremisesSyncEnabled'
        foreach ($personaId in @($missing)) {
            if (-not $chosen.ContainsKey($personaId)) { continue }
            $entry = $chosen[$personaId]
            if ($entry -isnot [System.Collections.IDictionary] -or -not $entry.Contains('Method') -or $entry['Method'] -cnotin @('UserSelectedCandidate', 'UserSelectedReplacement') -or
                ($entry.Contains('ObjectId') -eq $entry.Contains('Upn'))) {
                throw 'Seed.Persona.Selection: Choose exactly one account (ObjectId or exact UPN) and one allowed method.'
            }
            $key = $(if ($entry.Contains('ObjectId')) { $entry['ObjectId'] } else { $entry['Upn'] })
            if ($entry.Contains('ObjectId')) { Assert-SeedGuid $key }
            elseif ($key -isnot [string] -or $key -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$') { throw 'Seed.Persona.Selection: A replacement account must be an exact UPN.' }
            try { $read = ConvertTo-SeedUserCandidate (Invoke-SeedGraph -Session $Session -Method GET -Path ('/users/' + [uri]::EscapeDataString($key) + $selectionColumns)) }
            catch { if ($_.Exception.Message -like 'Seed.Graph.404:*') { throw 'Seed.Persona.Selection: The chosen account could not be read back; nothing was changed.' } else { throw } }
            if ($entry.Contains('ObjectId') -and $read.ObjectId -cne $key.ToLowerInvariant()) { throw 'Seed.Persona.Selection: The chosen account read back as a different object.' }
            if (-not (& $eligible $read)) { throw 'Seed.Persona.Selection: The chosen account is not an enabled cloud Member, or is an explicitly protected account.' }
            if (-not $claimed.Add($read.ObjectId)) { throw 'Seed.Persona.Selection: The chosen account is already used by another person in this batch.' }
            if ($entry['Method'] -ceq 'UserSelectedCandidate') {
                $hit = @(@($lookups[$personaId].Found.Exact) + @($lookups[$personaId].Found.Prefix) | Where-Object { $_.ObjectId -ceq $read.ObjectId })
                if ($hit.Count -ne 1) { throw 'Seed.Persona.Selection: A candidate selection must be one of the hint candidates; choose an explicit replacement for a different person.' }
                $basis = $hit[0].Basis
            } else { $basis = $(if ($entry.Contains('Upn')) { 'TypedUpn' } else { 'ListedAccount' }) }
            $resolved[$personaId] = @{ PersonaId = $personaId; RequestedUpn = $mappings[$personaId]; ResolvedUpn = $read.Upn; ObjectId = $read.ObjectId; Method = $entry['Method']; Basis = $basis }
        }
        $proposed = @{}; $proposalUse = @{}
        foreach ($personaId in @($missing)) {
            if ($resolved.ContainsKey($personaId)) { continue }
            $found = $lookups[$personaId].Found
            if ($found.Complete -and @($found.Exact).Count -eq 1 -and (& $eligible @($found.Exact)[0])) {
                $proposed[$personaId] = @($found.Exact)[0]
                $proposalUse[$proposed[$personaId].ObjectId] = 1 + $(if ($proposalUse.ContainsKey($proposed[$personaId].ObjectId)) { $proposalUse[$proposed[$personaId].ObjectId] } else { 0 })
            }
        }
        $duplicate = @{}
        foreach ($personaId in @($proposed.Keys | Sort-Object)) {
            $candidate = $proposed[$personaId]
            if ($claimed.Contains($candidate.ObjectId) -or $proposalUse[$candidate.ObjectId] -gt 1) { $duplicate[$personaId] = $true; continue }
            $resolved[$personaId] = @{ PersonaId = $personaId; RequestedUpn = $mappings[$personaId]; ResolvedUpn = $candidate.Upn; ObjectId = $candidate.ObjectId; Method = 'UniqueExactHint'; Basis = $candidate.Basis }
        }
        foreach ($personaId in $proposed.Keys) { if ($resolved.ContainsKey($personaId)) { $null = $claimed.Add($proposed[$personaId].ObjectId) } }
        $unresolved = [Collections.Generic.List[hashtable]]::new(); $available = $null
        foreach ($personaId in @($missing)) {
            if ($resolved.ContainsKey($personaId)) { continue }
            $found = $lookups[$personaId].Found; $hint = $lookups[$personaId].Hint
            $reason = $(if ($duplicate.ContainsKey($personaId)) { 'DuplicateAccount' } elseif (-not $found.Complete) { 'IncompleteLookup' } elseif (@($found.Exact).Count -gt 1) { 'AmbiguousExactHint' }
                elseif (@($found.Exact).Count -eq 1) { 'IneligibleExactHint' } elseif (-not $hint.DisplayName -and -not $hint.Alias) { 'NoIdentityHint' } else { 'NoExactHint' })
            $pool = @(@($found.Exact) + @($found.Prefix) | Where-Object { (& $eligible $_) -and -not $claimed.Contains($_.ObjectId) })
            if ($pool.Count -eq 0) {
                if ($null -eq $available) { $available = @((Read-SeedUserCandidates -Session $Session).Items | ForEach-Object { $_.Basis = 'AvailablePage'; $_ }) }
                $pool = @($available | Where-Object { (& $eligible $_) -and -not $claimed.Contains($_.ObjectId) })
            }
            $rank = { param($c) if ($c.Basis -like 'Exact*') { 0 } elseif ($c.Basis -ceq 'Prefix') { 1 } else { 2 } }
            $ordered = @($pool | Sort-Object @{ Expression = { & $rank $_ } }, @{ Expression = { $_.Upn } })
            $unresolved.Add(@{
                PersonaId = $personaId; RequestedUpn = $mappings[$personaId]; HintName = $hint.DisplayName; Reason = $reason; Truncated = ($ordered.Count -gt 20)
                Candidates = @($ordered | Select-Object -First 20 | ForEach-Object { @{ ObjectId = $_.ObjectId; Upn = $_.Upn; DisplayName = $_.DisplayName; Basis = $_.Basis } })
            })
        }
        foreach ($row in $resolved.Values) { if ($row.Method -cne 'ExactUpn') { $effective.personas.accountMappings[$row.PersonaId] = $row.ResolvedUpn } }
        return @{ EffectiveConfig = $effective; Resolutions = @($resolved.Keys | Sort-Object | ForEach-Object { $resolved[$_] }); Unresolved = @($unresolved) }
    } finally { $record.ReadOnlyDepth-- }
}

function ConvertTo-SeedAccountSelection {
    # ONE local answer for one unresolved persona -> selection data for the resolver: a displayed candidate number, or replace:<exact UPN> for
    # a different person. Anything else (empty included) is a cancellation ($null): there is no default and no retry.
    param([AllowNull()][AllowEmptyString()][string]$Answer, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Candidates)
    $text = $(if ($null -eq $Answer) { '' } else { $Answer.Trim() })
    if ($text -cmatch '^[1-9][0-9]?$') {
        $index = [int]$text
        if ($index -gt $Candidates.Count) { return $null }
        $candidate = $Candidates[$index - 1]
        return @{ Method = $(if ($candidate.Basis -ceq 'AvailablePage') { 'UserSelectedReplacement' } else { 'UserSelectedCandidate' }); ObjectId = $candidate.ObjectId }
    }
    if ($text -imatch '^replace:\s*([^\s@]+@[^\s@]+\.[^\s@]+)$') { return @{ Method = 'UserSelectedReplacement'; Upn = $Matches[1] } }
    return $null
}

function Save-SeedResolvedAccountMappings {
    # The one local save of approved account corrections (console and session runner share it): re-read the RAW private config, require the hash
    # taken when it was read, patch ONLY personas.accountMappings of the corrected personas and replace the file atomically. A file that changed
    # since, or whose mapping is neither the requested nor the resolved account, is preserved and reported; runtime overrides are never saved.
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigPath, [string]$ExpectedHash, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Resolutions)
    $changes = @($Resolutions | Where-Object { $_.ResolvedUpn -ine $_.RequestedUpn })
    if ($changes.Count -eq 0) { return @{ Status = 'NoChange'; Changed = 0 } }
    $path = Assert-SeedStatePath $ConfigPath
    if ([string]::IsNullOrWhiteSpace($ExpectedHash)) { throw 'Seed.Persona.ConfigSync: The hash of the private config at read time is required; it was not changed.' }
    $expected = $ExpectedHash.ToLowerInvariant()
    $conflict = 'Seed.Persona.ConfigSync: The private config changed after it was read or no longer holds the requested accounts; it was not overwritten.'
    try { $bytes = [IO.File]::ReadAllBytes($path); $doc = [Text.UTF8Encoding]::new($false).GetString($bytes).TrimStart([char]0xFEFF) | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String }
    catch { throw 'Seed.Persona.ConfigSync: The private config could not be read; it was not changed.' }
    if ((Get-SeedPersonaBytesHash $bytes) -cne $expected) { throw $conflict }
    if ($doc -isnot [System.Collections.IDictionary] -or -not $doc.Contains('personas') -or $doc['personas'] -isnot [System.Collections.IDictionary] -or -not $doc['personas'].Contains('accountMappings') -or $doc['personas']['accountMappings'] -isnot [System.Collections.IDictionary]) { throw $conflict }
    $maps = $doc['personas']['accountMappings']; $patched = 0
    foreach ($change in $changes) {
        if (-not $maps.Contains($change.PersonaId) -or $maps[$change.PersonaId] -isnot [string]) { throw $conflict }
        if ($maps[$change.PersonaId] -ieq $change.ResolvedUpn) { continue }
        if ($maps[$change.PersonaId] -ine $change.RequestedUpn) { throw $conflict }
        $maps[$change.PersonaId] = $change.ResolvedUpn; $patched++
    }
    if ($patched -eq 0) { return @{ Status = 'NoChange'; Changed = 0 } }
    Assert-SeedSchema $doc config
    $staging = $path + '.new-' + [guid]::NewGuid().ToString('N')
    try {
        $stream = [IO.FileStream]::new($staging, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
        try { $stream.Write([Text.UTF8Encoding]::new($false).GetBytes(($doc | ConvertTo-Json -Depth 100) + "`n")); $stream.Flush($true) } finally { $stream.Dispose() }
        if ((Get-SeedPersonaBytesHash ([IO.File]::ReadAllBytes($path))) -cne $expected) { throw $conflict }
        [IO.File]::Replace($staging, $path, [System.Management.Automation.Language.NullString]::Value)
    } catch {
        if ($_.Exception.Message -like 'Seed.Persona.ConfigSync:*') { throw }
        throw 'Seed.Persona.ConfigSync: The private config could not be replaced; it was not changed.'
    } finally { if (Test-Path -LiteralPath $staging) { [IO.File]::Delete($staging) } }
    return @{ Status = 'Saved'; Changed = $patched }
}

function Get-SeedProvenAccountCorrections {
    # The requested -> final account of every person, only when the exact completed BindExisting journal and its binding prove them. Anything
    # less returns nothing: this is evidence for a finished result, never a way to rebind.
    param($Config)
    try {
        $bindingPath = Assert-SeedStatePath $Config.personas.bindingPath
        $journalPath = Assert-SeedStatePath ($Config.personas.bindingPath + '.journal.json')
        if (-not (Test-Path -LiteralPath $bindingPath -PathType Leaf) -or -not (Test-Path -LiteralPath $journalPath -PathType Leaf)) { return @() }
        $journal = Read-SeedExistingJournal $journalPath
        $binding = Get-Content -LiteralPath $bindingPath -Raw | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
        Assert-SeedSchema $binding persona-binding
        if ($binding.version -cne '1.1' -or $binding.accountSource -cne 'Existing' -or $binding.tenantId -ine $Config.tenantId -or $binding.instanceId -cne $Config.personas.instanceId) { return @() }
        Assert-SeedExistingJournalEvidence -Journal $journal -Binding $binding
        $approved = @($journal.plans | Where-Object { $_.fingerprint -ceq $binding.approval.planFingerprint })
        if ($approved.Count -lt 1) { return @() }
        $rows = @($approved[-1].preview.Rows)
        $proven = @()
        foreach ($key in @($binding.users.Keys | Sort-Object)) {
            $row = @($rows | Where-Object { $_.PersonaId -ceq $key })
            if ($row.Count -ne 1 -or -not $row[0].Contains('Resolution')) { return @() }
            $r = $row[0].Resolution; $user = $binding.users[$key]
            if ($r.ObjectId -ine $user.objectId -or $r.ResolvedUpn -ine $user.upn) { return @() }
            $proven += @{ PersonaId = $key; RequestedUpn = [string]$r.RequestedUpn; ResolvedUpn = [string]$r.ResolvedUpn; ObjectId = [string]$r.ObjectId; Method = [string]$r.Method }
        }
        return @($proven)
    } catch { return @() }
}

function Sync-SeedResolvedAccountMappings {
    # Local only, before any login: an earlier run completed the whole batch but could not save the corrected mapping. The next initialization saves
    # exactly the proven requested -> final differences. It never selects, resolves or rebinds; no proof or any other difference changes nothing.
    param($Config, [Parameter(Mandatory)][string]$ConfigPath, [string]$ExpectedHash)
    if ($Config -isnot [System.Collections.IDictionary] -or -not $Config.Contains('personas') -or $Config['personas'] -isnot [System.Collections.IDictionary] -or
        -not $Config['personas'].Contains('accountMappings') -or $Config['personas']['accountMappings'] -isnot [System.Collections.IDictionary]) { return @{ Status = 'NoProof' } }
    $proven = @(Get-SeedProvenAccountCorrections $Config)
    $maps = $Config.personas.accountMappings
    if ($proven.Count -eq 0 -or $maps.Count -ne $proven.Count) { return @{ Status = 'NoProof' } }
    $pending = @()
    foreach ($r in $proven) {
        if (-not $maps.Contains($r.PersonaId)) { return @{ Status = 'NoProof' } }
        if ($maps[$r.PersonaId] -ieq $r.ResolvedUpn) { continue }
        if ($maps[$r.PersonaId] -ine $r.RequestedUpn) { return @{ Status = 'NoProof' } }
        $pending += $r
    }
    if ($pending.Count -eq 0) { return @{ Status = 'NoChange' } }
    return Save-SeedResolvedAccountMappings -ConfigPath $ConfigPath -ExpectedHash $ExpectedHash -Resolutions $pending
}

function Get-SeedExistingPersonaPlan {
    param($Session, $Record, $Config, $Source, $AccountResolution = $null)
    $pack = $Source.Personas
    $selected = Get-SeedExistingMappingSelection -Config $Config -Pack $pack
    $people = $selected.People; $mappings = $selected.Mappings
    # A trusted resolution fixes the actual account (object ID) of every person it names; those persons are never looked up by name or UPN again.
    $fixed = @{}
    if ($null -ne $AccountResolution) {
        $AccountResolution = ConvertTo-SeedMap $AccountResolution
        Assert-SeedFields $AccountResolution @('Resolutions', 'Unresolved') 'Seed.Persona.Selection'
        if (@($AccountResolution.Unresolved).Count -gt 0) { throw 'Seed.Persona.Selection: Unresolved accounts remain; no writable plan exists until every person has an explicitly resolved account.' }
        foreach ($entry in @($AccountResolution.Resolutions)) {
            Assert-SeedFields $entry @('PersonaId', 'RequestedUpn', 'ResolvedUpn', 'ObjectId', 'Method') 'Seed.Persona.Selection'
            Assert-SeedGuid $entry.ObjectId
            if ($entry.RequestedUpn -isnot [string] -or $entry.ResolvedUpn -isnot [string] -or -not $mappings.ContainsKey($entry.PersonaId) -or $fixed.ContainsKey($entry.PersonaId) -or
                $entry.ResolvedUpn -ine $mappings[$entry.PersonaId] -or $entry.Method -cnotin @('ExactUpn', 'UniqueExactHint', 'UserSelectedCandidate', 'UserSelectedReplacement')) {
                throw 'Seed.Persona.Selection: A resolution does not match the effective account mapping.'
            }
            $fixed[$entry.PersonaId] = $entry
        }
    }
    $selectionFingerprint = Get-SeedExistingSelectionFingerprint $mappings
    $prior = Get-SeedExistingPersonaPrior $Config $Source $selectionFingerprint
    if ($null -ne $prior.Binding -and ($prior.Binding.users.Count -ne $mappings.Count -or @($mappings.Keys | Where-Object { -not $prior.Binding.users.Contains($_) -or $prior.Binding.users[$_].upn -ine $mappings[$_] }).Count -gt 0)) {
        throw 'Seed.Persona.Binding: The entire original selection and its exact account mapping are required; no implicit expansion, deletion or rebinding.'
    }
    $operatorId = Assert-SeedPersonaAdmin $Session $Config
    $presenter = Read-SeedExistingPresenter $Session $Config
    $blockable = '^Seed\.Persona\.(NotFound|Identity|Snapshot|Manager|Presenter|Duplicate):'
    $rows = [Collections.Generic.List[hashtable]]::new(); $rowById = @{}; $outsideManagers = @{}
    foreach ($personaId in @($mappings.Keys | Sort-Object)) {
        $upn = $mappings[$personaId]
        $row = @{ PersonaId = $personaId; Upn = $upn; ObjectId = $null; Before = $null; Patch = @{}; ManagerPersonaId = $null; ManagerTargetId = $null; Projected = $null
            Diff = @(); Labels = @{}; BindingRefresh = $false; Action = 'Keep'; BlockReason = $null
            Resolution = @{ PersonaId = $personaId; Method = 'ExactUpn'; RequestedUpn = $upn; ResolvedUpn = $upn; ObjectId = $null; Basis = $null } }
        try {
            if ($fixed.ContainsKey($personaId)) {
                $pinned = $fixed[$personaId]
                $id = $pinned.ObjectId.ToLowerInvariant()
                $row.Resolution = @{ PersonaId = $personaId; Method = $pinned.Method; RequestedUpn = $pinned.RequestedUpn.ToLowerInvariant(); ResolvedUpn = $upn; ObjectId = $id; Basis = $(if ($pinned.Contains('Basis')) { $pinned.Basis } else { $null }) }
            } else {
                try { $found = ConvertTo-SeedMap (Invoke-SeedGraph -Session $Session -Method GET -Path ('/users/' + [uri]::EscapeDataString($upn) + '?$select=id,userPrincipalName')) }
                catch { if ($_.Exception.Message -like 'Seed.Graph.404:*') { throw (New-SeedPersonaBlock 'Seed.Persona.NotFound' 'No account exists for the exact selected UPN; names are never matched.') } else { throw } }
                if (-not $found.Contains('id') -or $found['id'] -isnot [string] -or $found['id'] -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' -or
                    -not $found.Contains('userPrincipalName') -or $found['userPrincipalName'] -isnot [string] -or $found['userPrincipalName'] -ine $upn) { throw (New-SeedPersonaBlock 'Seed.Persona.Identity' 'The exact UPN lookup did not return the same account.') }
                $id = $found['id'].ToLowerInvariant()
                $row.Resolution.ObjectId = $id
            }
            $row.ObjectId = $id
            if ($id -ieq $presenter.id -or $id -ieq $operatorId) { throw (New-SeedPersonaBlock 'Seed.Persona.Presenter' 'Presenter and the explicitly protected legacy account can never be Demo accounts.') }
            if ($rowById.ContainsKey($id)) {
                $rowById[$id].Action = 'Block'; $rowById[$id].BlockReason = 'Seed.Persona.Duplicate'
                throw (New-SeedPersonaBlock 'Seed.Persona.Duplicate' 'Two selections resolved to the same account.')
            }
            $rowById[$id] = $row
            $state = Get-SeedExistingPersonaState $Session $id $upn
            if ($null -ne $prior.Binding -and $prior.Binding.users[$personaId].objectId -ine $id) { throw (New-SeedPersonaBlock 'Seed.Persona.Identity' 'The bound object ID differs from the account now holding this UPN; it is never rebound.') }
            $row.Before = $state
        } catch {
            $failure = $_.Exception.Message
            if ($failure -cnotmatch $blockable) { throw }
            $row.Action = 'Block'; if ($null -eq $row.BlockReason) { $row.BlockReason = ($failure -split ':', 2)[0] }
        }
        $rows.Add($row)
    }
    $byPersona = @{}; foreach ($row in $rows) { $byPersona[$row.PersonaId] = $row }
    foreach ($row in $rows) {
        if ($row.Action -ceq 'Block') { continue }
        $target = $people[$row.PersonaId]['managerRef']
        if ($null -eq $target) { continue }
        $targetRow = $byPersona[$target]
        if ($targetRow.Action -ceq 'Block') { $row.Action = 'Block'; $row.BlockReason = 'Seed.Persona.Manager'; continue }
        $row.ManagerPersonaId = $target; $row.ManagerTargetId = $targetRow.ObjectId
    }
    $finalManager = @{}
    foreach ($row in $rows) { if ($null -ne $row.Before) { $finalManager[$row.ObjectId] = $(if ($null -ne $row.ManagerTargetId -and $row.Action -cne 'Block') { $row.ManagerTargetId } else { $row.Before.ManagerObjectId }) } }
    foreach ($row in $rows) {
        if ($row.Action -ceq 'Block' -or $null -eq $row.Before) { continue }
        $visited = @{ $row.ObjectId = $true }; $current = $row.ObjectId; $hops = 0
        while ($true) {
            $next = if ($finalManager.ContainsKey($current)) { $finalManager[$current] } else { Get-SeedExistingManagerId $Session $current $outsideManagers }
            if ($null -eq $next) { break }
            $hops++
            if ($visited.ContainsKey($next) -or $hops -gt 25) { $row.Action = 'Block'; $row.BlockReason = 'Seed.Persona.Manager'; break }
            $visited[$next] = $true; $current = $next
        }
    }
    $states = @{}
    foreach ($row in $rows) {
        if ($row.Action -ceq 'Block' -or $null -eq $row.Before) { continue }
        $profileTarget = if ($people[$row.PersonaId].Contains('profile')) { $people[$row.PersonaId]['profile'] } else { @{} }
        foreach ($field in @('jobTitle', 'department', 'companyName', 'officeLocation')) {
            if ($profileTarget.Contains($field) -and $row.Before.Profile[$field] -cne $profileTarget[$field]) {
                $row.Diff += @{ Field = $field; Before = $row.Before.Profile[$field]; After = $profileTarget[$field] }
                $row.Patch[$field] = $profileTarget[$field]
            }
        }
        $current = $row.Before.ManagerObjectId
        $row.Labels.CurrentManager = $(if ($null -eq $current) { '<none>' } elseif ($rowById.ContainsKey($current)) { "$($rowById[$current].PersonaId) <$($rowById[$current].Upn)>" } else { Get-SeedExistingManagerLabel $Session $current })
        if ($null -ne $row.ManagerTargetId) {
            $row.Labels.TargetManager = "$($row.ManagerPersonaId) <$($byPersona[$row.ManagerPersonaId].Upn)>"
            if ($row.Before.ManagerObjectId -cne $row.ManagerTargetId) { $row.Diff += @{ Field = 'manager'; Before = $row.Before.ManagerObjectId; After = @{ PersonaId = $row.ManagerPersonaId; ObjectId = $row.ManagerTargetId } } }
        }
        $row.Action = $(if ($row.Diff.Count -gt 0) { 'Update' } else { 'Keep' })
        if ($null -ne $prior.Binding) {
            $bound = $prior.Binding.users[$row.PersonaId].profile
            $row.BindingRefresh = $bound.managerObjectId -cne $row.Before.ManagerObjectId -or @('displayName', 'jobTitle', 'department', 'companyName', 'officeLocation', 'usageLocation' | Where-Object { $bound[$_] -cne $row.Before.Profile[$_] }).Count -gt 0
        }
        $projected = @{ ObjectId = $row.Before.ObjectId; Upn = $row.Before.Upn; Profile = ConvertTo-SeedMap $row.Before.Profile; ManagerObjectId = $(if ($null -ne $row.ManagerTargetId) { $row.ManagerTargetId } else { $row.Before.ManagerObjectId }); LicenseDigest = $row.Before.LicenseDigest }
        foreach ($field in $row.Patch.Keys) { $projected.Profile[$field] = $row.Patch[$field] }
        $row.Projected = $projected
        $states[$row.PersonaId] = $projected
    }
    $rowList = @($rows)
    if (@($rowList | Where-Object { $_.Action -ceq 'Block' }).Count -eq 0) {
        $preview = @{ PackId = $pack.packId; PackFingerprint = $Source.Fingerprint; Rows = $rowList }
        try { Assert-SeedSchema (New-SeedExistingBinding -Config $Config -Preview $preview -States $states -PlanFingerprint ('0' * 64) -JournalFingerprint ('0' * 64) -At '2026-01-01T00:00:00Z' -Projected) persona-binding }
        catch { throw 'Seed.Persona.Snapshot: The projected approved snapshot cannot be stored in a binding; no warning, confirmation or write was started.' }
    }
    $preview = @{
        EngineVersion = '1.0.0'; AccountSource = 'Existing'; TenantId = $Record.TenantId; ClientId = $Record.ClientId; Actor = @{ Type = 'Application'; TenantId = $Record.TenantId; ClientId = $Record.ClientId }; ProtectedAccountId = $operatorId
        InstanceId = $Config.personas.instanceId; PackId = $pack.packId; PackFingerprint = $Source.Fingerprint
        Presenter = $presenter; Rows = $rowList; ServiceStatus = 'NotVerified'
        Selection = @{ Count = $rowList.Count; Fingerprint = $selectionFingerprint }
        Context = $prior.Context; PriorJournalHash = $prior.FileHash; PriorBindingHash = $prior.BindingFileHash
    }
    $handle = [pscustomobject]@{
        PlanId = [guid]::NewGuid().ToString('N'); Fingerprint = Get-SeedFingerprint $preview
        Target = "$($Record.TenantId)/$($Config.personas.instanceId)"; Preview = $preview
    }
    $script:SeedPersonaPlans[$handle.PlanId] = @{ Handle = $handle; Session = $Session; Config = $Config; Source = $Source; Prior = $prior; Fingerprint = $handle.Fingerprint; Used = $false; AccountResolution = $AccountResolution }
    $Record.PersonaPlanId = $handle.PlanId
    return $handle
}

function Get-SeedPersonaPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Config, $AccountResolution = $null)
    $record = Get-SeedSessionRecord $Session
    $record.PersonaPlanId = $null
    $Config = ConvertTo-SeedMap $Config
    $record.ReadOnlyDepth++
    try {
        if ($record.Kind -cne 'App' -or $record.Mode -cne 'InitializePersonas') { throw 'Seed.Persona.Session: A dedicated application session is required.' }
        Assert-SeedSchema $Config config
        $source = Read-SeedPersonaSource $Config
        $accountSource = Get-SeedPersonaAccountSource $Config
        $packSource = if ($source.Personas.Contains('accountSource')) { $source.Personas['accountSource'] } else { 'Managed' }
        if ($packSource -cne $accountSource) { throw 'Seed.Persona.Source: The configured account source and the public persona pack source differ; nothing was written.' }
        if ($accountSource -ceq 'Existing') { return Get-SeedExistingPersonaPlan -Session $Session -Record $record -Config $Config -Source $source -AccountResolution $AccountResolution }
        if ($null -ne $AccountResolution) { throw 'Seed.Persona.Source: An account resolution applies only to Existing accounts.' }
        $prior = Get-SeedPersonaPrior $Config $source
        $operatorId = Assert-SeedPersonaAdmin $Session $Config
        $countries = @([Globalization.CultureInfo]::GetCultures([Globalization.CultureTypes]::SpecificCultures) | ForEach-Object { try { ([Globalization.RegionInfo]::new($_.Name)).TwoLetterISORegionName } catch { } })
        if ($Config.personas.usageLocation -cnotin $countries) { throw 'Seed.Persona.Location: A valid usage country is required.' }
        $domains = @(Get-SeedGraphCollection -Session $Session -Path '/domains?$select=id,isVerified,authenticationType')
        $domain = @($domains | Where-Object { $_.Contains('id') -and $_.id -ieq $Config.personas.userDomain -and $_.Contains('isVerified') -and $_.isVerified -is [bool] -and $_.isVerified -and $_.Contains('authenticationType') -and $_.authenticationType -ceq 'Managed' })
        if ($domain.Count -ne 1) { throw 'Seed.Persona.Domain: Exactly one verified managed domain is required.' }
        $inventory = @(Get-DemoUserInventory -Session $Session -Binding $prior.Binding -PresenterUpn $Config.presenterUpn | Sort-Object ObjectId)
        $presenter = ConvertTo-SeedMap (Invoke-SeedGraph -Session $Session -Method GET -Path ('/users/' + [uri]::EscapeDataString($Config.presenterUpn) + '?$select=id,userPrincipalName,accountEnabled,userType'))
        Assert-SeedFields $presenter @('id', 'userPrincipalName', 'accountEnabled', 'userType') 'Seed.Persona.Presenter'
        Assert-SeedGuid $presenter.id
        if ($presenter.userPrincipalName -ine $Config.presenterUpn -or $presenter.accountEnabled -cne $true -or $presenter.userType -cne 'Member') { throw 'Seed.Persona.Presenter: An existing enabled Member Presenter must be proven.' }
        $byUpn = @{}; $byId = @{}
        foreach ($u in $inventory) {
            Assert-SeedGuid $u.ObjectId
            if ($byUpn.ContainsKey($u.Upn) -or $byId.ContainsKey($u.ObjectId)) { throw 'Seed.Persona.Inventory: Duplicate identity evidence.' }
            $byUpn[$u.Upn] = $u; $byId[$u.ObjectId] = $u
        }
        if (-not $byId.ContainsKey($presenter.id) -or $byId[$presenter.id].Upn -ine $Config.presenterUpn) { throw 'Seed.Persona.Presenter: Inventory and Presenter read-back differ.' }
        $people = @{}; $photos = @{}; $managedIds = @{}
        foreach ($a in $source.Personas.avatarAssets) { $photos[$a.id] = $a }
        foreach ($p in $source.Personas.people) { $people[$p.personaId] = $p }
        if ($null -ne $prior.Binding) {
            if ($prior.Binding.users.Count -ne $people.Count) { throw 'Seed.Persona.Binding: The entire original managed identity set is required; no implicit expansion or deletion.' }
            foreach ($key in $prior.Binding.users.Keys) {
                if (-not $people.ContainsKey($key)) { throw 'Seed.Persona.Binding: Persona identity set differs.' }
                $u = $prior.Binding.users[$key]
                $expectedUpn = "$($Config.personas.accountPrefix)$($people[$key].alias)@$($Config.personas.userDomain)"
                if ($u.upn -ine $expectedUpn -or $u.objectId -ieq $presenter.id -or $u.objectId -ieq $operatorId -or $u.upn -ieq $Config.presenterUpn -or
                    -not $byId.ContainsKey($u.objectId) -or -not $byUpn.ContainsKey($u.upn) -or $byUpn[$u.upn].ObjectId -ine $u.objectId) {
                    throw 'Seed.Persona.Binding: Managed namespace, object ID, UPN or Presenter exclusion differs.'
                }
                $managedIds[$u.objectId] = $true
            }
        }
        $rows = @(); $needs = @{}
        foreach ($p in $source.Personas.people) {
            $upn = "$($Config.personas.accountPrefix)$($p.alias)@$($Config.personas.userDomain)".ToLowerInvariant()
            if ($upn -ieq $Config.presenterUpn -or ($upn -split '@')[0].Length -gt 64 -or $upn -notmatch '^[a-z0-9][a-z0-9._-]*@[a-z0-9.-]+$') { throw 'Seed.Persona.Namespace: Invalid managed UPN or Presenter collision.' }
            if (-not $Config.personas.licenseProfiles.ContainsKey($p.licenseProfile)) { throw 'Seed.Persona.License: Every selected license profile must exist.' }
            $skuIds = @($Config.personas.licenseProfiles[$p.licenseProfile].skuIds | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object)
            if (@($skuIds | Sort-Object -Unique).Count -ne $skuIds.Count) { throw 'Seed.Persona.License: Duplicate normalized SKU.' }
            $bound = if ($null -ne $prior.Binding) { $prior.Binding.users[$p.personaId] } else { $null }
            $before = $null; $id = $null
            if ($null -eq $bound) {
                if ($byUpn.ContainsKey($upn)) { throw 'Seed.Persona.Collision: An existing account without completed creation provenance is never adopted.' }
            } else {
                $id = $bound.objectId.ToLowerInvariant()
                $before = Get-SeedPersonaRemoteState $Session $id $upn $presenter.id
                if ($null -ne $before.ManagerObjectId -and -not $managedIds.ContainsKey($before.ManagerObjectId)) { throw 'Seed.Persona.Manager: An outside manager relationship cannot be changed.' }
                if ($before.SkuIds.Count -gt 0 -and $before.Profile.usageLocation -cne $Config.personas.usageLocation) { throw 'Seed.Persona.Location: Licensed usage country cannot be changed.' }
                foreach ($sku in $before.SkuIds) { if ($sku -cnotin $skuIds) { throw 'Seed.Persona.License: Existing licenses cannot be removed.' } }
                if ($null -ne $before.ManagerObjectId -and $null -eq $p.managerRef) { throw 'Seed.Persona.Manager: Existing managers cannot be removed.' }
            }
            $desired = @{ Profile = @{ usageLocation = $Config.personas.usageLocation }; ManagerPersonaId = $p.managerRef; SkuIds = $skuIds }
            foreach ($field in @('displayName', 'jobTitle', 'department', 'companyName', 'officeLocation')) { $desired.Profile[$field] = $p[$field] }
            $diff = @()
            foreach ($field in @('displayName', 'jobTitle', 'department', 'companyName', 'officeLocation', 'usageLocation')) {
                $old = if ($null -eq $before) { $null } else { $before.Profile[$field] }
                if ($null -eq $before -or $old -cne $desired.Profile[$field]) { $diff += @{ Field = $field; Before = $old; After = $desired.Profile[$field] } }
            }
            $managerId = if ($null -ne $p.managerRef -and $null -ne $prior.Binding) { $prior.Binding.users[$p.managerRef].objectId.ToLowerInvariant() } else { $null }
            if ($null -ne $p.managerRef -and ($null -eq $before -or $before.ManagerObjectId -ine $managerId)) {
                $diff += @{ Field = 'manager'; Before = $(if ($before) { $before.ManagerObjectId } else { $null }); After = @{ PersonaId = $p.managerRef; ObjectId = $managerId } }
            }
            $photo = $photos[$p.avatarAssetId]
            $photoChange = $null -eq $bound -or $bound.photo.avatarAssetId -cne $p.avatarAssetId -or $bound.photo.sourceSha256 -cne $photo.sha256 -or $before.PhotoSha256 -cne $bound.photo.verifiedSha256
            if ($photoChange) { $diff += @{ Field = 'photo'; Before = $(if ($before) { $before.PhotoSha256 } else { $null }); After = @{ AvatarAssetId = $photo.id; SourcePath = $photo.path; SourceSha256 = $photo.sha256 } } }
            $adds = @($skuIds | Where-Object { $null -eq $before -or $_ -cnotin $before.SkuIds })
            if ($adds.Count -gt 0) { $diff += @{ Field = 'licenses'; Before = $(if ($before) { $before.SkuIds } else { @() }); After = $skuIds; Add = $adds; Remove = @() } }
            foreach ($sku in $skuIds) {
                if (-not $needs.ContainsKey($sku)) { $needs[$sku] = 0 }
                if ($sku -cin $adds) { $needs[$sku]++ }
            }
            $rows += @{
                PersonaId = $p.personaId; Upn = $upn; ObjectId = $id; Before = $before; Desired = $desired; Diff = $diff
                Photo = @{ AvatarAssetId = $photo.id; SourcePath = $photo.path; SourceSha256 = $photo.sha256; Change = $photoChange }
                LicenseProfile = $p.licenseProfile; AddSkuIds = $adds
                Action = $(if ($null -eq $bound) { 'Create' } elseif ($diff.Count -gt 0) { 'Update' } else { 'Keep' })
            }
        }
        $skus = @(Get-SeedGraphCollection -Session $Session -Path '/subscribedSkus?$select=skuId,capabilityStatus,consumedUnits,prepaidUnits')
        $seats = @(Get-SeedPersonaSeatPlan -Requirements $needs -Subscriptions $skus)
        $preview = @{
            EngineVersion = '1.0.0'; TenantId = $record.TenantId; ClientId = $record.ClientId; Actor = @{ Type = 'Application'; TenantId = $record.TenantId; ClientId = $record.ClientId }; ProtectedAccountId = $operatorId
            InstanceId = $Config.personas.instanceId; PackId = $source.Personas.packId; PackFingerprint = $source.Fingerprint
            Presenter = $presenter; Inventory = $inventory; Rows = $rows; Seats = $seats; ServiceStatus = 'NotVerified'
            Context = $prior.Context; PriorJournalHash = $prior.FileHash; PriorBindingHash = $prior.BindingFileHash
        }
        $handle = [pscustomobject]@{
            PlanId = [guid]::NewGuid().ToString('N'); Fingerprint = Get-SeedFingerprint $preview
            Target = "$($record.TenantId)/$($Config.personas.instanceId)"; Preview = $preview
        }
        $script:SeedPersonaPlans[$handle.PlanId] = @{ Handle = $handle; Session = $Session; Config = $Config; Source = $source; Prior = $prior; Fingerprint = $handle.Fingerprint; Used = $false }
        $record.PersonaPlanId = $handle.PlanId
        return $handle
    } finally { $record.ReadOnlyDepth-- }
}

function Get-SeedPersonaSavedPlan {
    # One authenticity gate shared by rendering and writing: the exact handle, session, fingerprint and unconsumed state.
    param($Session, $Plan, [switch]$ForWrite)
    $record = Get-SeedSessionRecord $Session
    if ($record.Kind -cne 'App' -or $record.Mode -cne 'InitializePersonas' -or ($ForWrite -and $record.ReadOnlyDepth -gt 0)) { throw 'Seed.Persona.Session: Only explicit application initialization can write.' }
    if ($null -eq $Plan -or -not $Plan.PSObject.Properties['PlanId'] -or -not $script:SeedPersonaPlans.ContainsKey($Plan.PlanId)) { throw 'Seed.Persona.Plan: An authentic current preview is required.' }
    $saved = $script:SeedPersonaPlans[$Plan.PlanId]
    if (-not [object]::ReferenceEquals($saved.Handle, $Plan) -or -not [object]::ReferenceEquals($saved.Session, $Session) -or $saved.Used -or
        $record.PersonaPlanId -cne $Plan.PlanId -or $Plan.Fingerprint -cne $saved.Fingerprint -or
        (Get-SeedFingerprint $Plan.Preview) -cne $saved.Fingerprint -or $Plan.Target -cne "$($record.TenantId)/$($saved.Config.personas.instanceId)") {
        throw 'Seed.Persona.Plan: Preview was forged, edited, consumed or superseded.'
    }
    return $saved
}

function Show-SeedPersonaSetupPlan {
    # Shared by the console and every trusted runner: warning, per-person Before -> After and limits come from the authentic
    # plan only. Lines carrying tenant values are tagged "[PersonaDetail]" so a trusted host can keep them on the local machine.
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Plan, [Management.Automation.Host.PSHost]$ConsoleHost)
    $null = Get-SeedPersonaSavedPlan -Session $Session -Plan $Plan
    $preview = $Plan.Preview
    $write = if ($null -ne $ConsoleHost) { $ui = $ConsoleHost.UI; { param([string]$Line) $ui.WriteLine($Line) }.GetNewClosure() } else { { param([string]$Line) Write-Host $Line } }
    $local = '[PersonaDetail] '
    $rows = @($preview.Rows)
    $source = $(if ($preview.Contains('AccountSource')) { $preview.AccountSource } else { 'Managed' })
    $updates = @($rows | Where-Object { $_.Action -ceq 'Update' })
    $blocked = @($rows | Where-Object { $_.Action -ceq 'Block' })
    $creates = @($rows | Where-Object { $_.Action -ceq 'Create' })
    & $write "[PersonaSetup] Source=$source Selected=$($rows.Count) Create=$($creates.Count) Update=$($updates.Count) Keep=$(@($rows | Where-Object { $_.Action -ceq 'Keep' }).Count) Block=$($blocked.Count)"
    if ($source -ceq 'Existing') {
        & $write '[PersonaSetup] Whole-batch checks finished before any write: Presenter/operator exclusion, exact UPN and enabled cloud Member read-back, manager graph, projected binding.'
        $methodOf = { param($r) if ($r.Contains('Resolution') -and $r.Resolution.Contains('Method')) { $r.Resolution.Method } else { 'ExactUpn' } }
        $counts = @{}; foreach ($name in @('ExactUpn', 'UniqueExactHint', 'UserSelectedCandidate', 'UserSelectedReplacement')) { $counts[$name] = @($rows | Where-Object { (& $methodOf $_) -ceq $name }).Count }
        & $write "[PersonaSetup] Account resolution: ExactUpn=$($counts.ExactUpn) UniqueExactHint=$($counts.UniqueExactHint) UserSelectedCandidate=$($counts.UserSelectedCandidate) UserSelectedReplacement=$($counts.UserSelectedReplacement)"
        if ($blocked.Count -gt 0) {
            foreach ($row in $blocked) { & $write "[Blocked] persona=$($row.PersonaId) reason=$($row.BlockReason)"; & $write "$local  account: $(ConvertTo-SeedDisplayText $row.Upn)" }
            & $write '[Blocked] No confirmation is offered and nothing will be written; correct the selection and plan again.'
            return
        }
        $corrected = $rows.Count - $counts.ExactUpn
        if ($corrected -gt 0) { & $write "[Warning] 本批有 $corrected 位的實際帳號不是你原先指定的 UPN（唯一姓名提示或你本次選定）；請在本機逐一核對「原指定帳號 → 實際帳號」，替代者保留其自己的姓名與照片。" }
        if ($updates.Count -gt 0) {
            & $write '[Warning] 將修改既有 Microsoft 365 使用者的 profile／主管關係。'
            & $write "目標 tenant：$($Plan.Target)；將變更：$($updates.Count) 人。"
            & $write '變更只限：jobTitle、department、companyName、officeLocation、manager。'
            & $write '姓名、UPN、照片、密碼、使用地區、管理角色及既有授權不修改。'
            & $write '請核對下方每人的 Before → After；取消或不確認不會寫入。'
            & $write 'DemoAccountAcknowledged 表示你已核對本批實際帳號與下方每人的變更，並同意以此計畫 fingerprint 更新；工具不檢查也不修改這些帳號的目錄角色。'
        } else { & $write '將沿用既有人員，不修改 profile。' }
        $index = 0
        foreach ($row in $rows) {
            $index++
            & $write "$local[$index/$($rows.Count)] $($row.PersonaId) $(ConvertTo-SeedDisplayText $row.Upn) $($row.Action)"
            $method = & $methodOf $row
            if ($method -cne 'ExactUpn') {
                & $write "$local  account: $(ConvertTo-SeedDisplayText $row.Resolution.RequestedUpn) → $(ConvertTo-SeedDisplayText $row.Resolution.ResolvedUpn) via $method"
                if ($method -ceq 'UserSelectedReplacement') { & $write "$local  replacement: a different person you chose; the account keeps its own real name and photo" }
            }
            foreach ($d in @($row.Diff)) {
                if ($d.Field -ceq 'manager') { & $write "$local  manager: $(ConvertTo-SeedDisplayText $row.Labels.CurrentManager) → $(ConvertTo-SeedDisplayText $row.Labels.TargetManager)" }
                else { & $write "$local  $($d.Field): $(Format-SeedPersonaValue $d.Before) → $(Format-SeedPersonaValue $d.After)" }
            }
            if ($row.Diff.Count -eq 0) { & $write "$local  no profile or manager change" }
            if ($row.BindingRefresh) { & $write "$local  the previously approved binding snapshot differs from the actual profile and will be refreshed (no tenant write)" }
        }
    } else {
        foreach ($s in @($preview.Seats)) { & $write "[PersonaSetup] Seats: SKU $($s.SkuId) required=$($s.Required) remaining=$($s.Remaining) after=$($s.RemainingAfter)" }
        if ($updates.Count -gt 0) {
            $fields = @($updates | ForEach-Object { $_.Diff | ForEach-Object { $_.Field } } | Sort-Object -Unique)
            & $write "[Warning] 將修改本工具先前建立之受管使用者：$($updates.Count) 人，欄位：$($fields -join '、')。請核對下方每人的 Before → After；取消或不確認不會寫入。"
        }
        $index = 0
        foreach ($row in $rows) {
            $index++
            & $write "$local[$index/$($rows.Count)] $($row.PersonaId) $(ConvertTo-SeedDisplayText $row.Upn) $($row.Action)"
            foreach ($d in @($row.Diff)) { & $write "$local  $($d.Field): $(Format-SeedPersonaValue $d.Before) → $(Format-SeedPersonaValue $d.After)" }
        }
    }
    & $write "Target: $($Plan.Target)  PlanFingerprint: $($Plan.Fingerprint)"
}

function ConvertTo-SeedPersonaSafePreview {
    # The only projection allowed in automation output and summaries: logical personas, changed field names, counts, codes.
    param([Parameter(Mandatory)]$Plan)
    $preview = $Plan.Preview
    $rows = @($preview.Rows)
    $people = @(foreach ($row in $rows) {
        $entry = [ordered]@{ PersonaId = $row.PersonaId; Action = $row.Action; ChangedFields = @($row.Diff | ForEach-Object { $_.Field } | Sort-Object -Unique)
            BlockReason = $(if ($row.Contains('BlockReason')) { $row['BlockReason'] } else { $null }) }
        if ($row.Contains('Resolution')) { $entry.ResolutionMethod = $row.Resolution.Method }
        $entry
    })
    $projection = [ordered]@{
        AccountSource = $(if ($preview.Contains('AccountSource')) { $preview.AccountSource } else { 'Managed' })
        Target = $Plan.Target; PlanFingerprint = $Plan.Fingerprint
        Counts = [ordered]@{ Selected = $rows.Count; Create = @($rows | Where-Object { $_.Action -ceq 'Create' }).Count; Update = @($rows | Where-Object { $_.Action -ceq 'Update' }).Count
            Keep = @($rows | Where-Object { $_.Action -ceq 'Keep' }).Count; Block = @($rows | Where-Object { $_.Action -ceq 'Block' }).Count }
        People = $people
    }
    if (@($rows | Where-Object { $_.Contains('Resolution') }).Count -gt 0) {
        $methods = [ordered]@{}
        foreach ($name in @('ExactUpn', 'UniqueExactHint', 'UserSelectedCandidate', 'UserSelectedReplacement')) { $methods[$name] = @($rows | Where-Object { $_.Contains('Resolution') -and $_.Resolution.Method -ceq $name }).Count }
        $projection.AccountResolution = $methods
    }
    return $projection
}
