function Assert-SeedStatePath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.StartsWith('\\') -or $Path -match '(^|[\\/])\.\.([\\/]|$)|[^A-Za-z]:|:[^\\]') {
        throw 'Seed.State.Path: Use an explicit safe local journal path.'
    }
    $full = [IO.Path]::GetFullPath($Path)
    $current = $full
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Seed.State.Path: Reparse points are not allowed.' }
        }
        $parent = [IO.Path]::GetDirectoryName($current)
        if ($parent -eq $current) { break }
        $current = $parent
    }
    if (-not (Test-Path -LiteralPath ([IO.Path]::GetDirectoryName($full)) -PathType Container)) { throw 'Seed.State.Path: Journal parent must already exist.' }
    return $full
}

function Enter-SeedRunLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $Path = Assert-SeedStatePath $Path
    $lockPath = Assert-SeedStatePath ($Path + '.lock')
    try { return [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch { throw 'Seed.State.Lock: Another writer holds the run lock or the lock cannot be acquired.' }
}

function Exit-SeedRunLock {
    param([Parameter(Mandatory)][IO.FileStream]$Lock)
    $Lock.Dispose()
}

function Get-SeedOperationKeys {
    param([AllowEmptyCollection()][object[]]$Operations)
    $keys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $Operations) {
        $operation = ConvertTo-SeedMap $entry
        Assert-SeedFields $operation @('OperationId', 'Workload', 'TargetKey', 'DataFingerprint', 'SideEffects', 'PresenterEvidence') 'Seed.State.Operations'
        if ($operation.OperationId -notmatch '^[A-Za-z][A-Za-z0-9_-]{0,63}$' -or $operation.Workload -cnotin @('outlook', 'teams', 'onedrive', 'sharepoint') -or
            $operation.DataFingerprint -cnotmatch '^[0-9a-f]{64}$' -or -not $keys.Add("$($operation.Workload)/$($operation.OperationId)")) { throw 'Seed.State.Operations: Invalid or duplicate operation.' }
    }
    return @($keys | Sort-Object)
}

function Get-SeedOperationDigest {
    param($Operation)
    $operation = ConvertTo-SeedMap $Operation
    $core = @{}
    foreach ($field in @('OperationId', 'Workload', 'TargetKey', 'TargetId', 'DataFingerprint', 'SideEffects', 'PresenterEvidence', 'ActorFingerprint', 'StorageScope', 'OutlookScope', 'TeamsScope')) {
        if ($operation.Contains($field)) { $core[$field] = $operation[$field] }
    }
    Get-SeedFingerprint @{ engineVersion = '1.0.0'; operation = $core }
}

function Write-SeedAtomicState {
    param([string]$Path, $State, [string]$ExpectedFileHash)
    Assert-SeedSchema $State run-state
    Assert-SeedNoSecrets $State
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($State | ConvertTo-Json -Depth 100 -Compress) + "`n")
    $staging = $Path + '.new-' + [guid]::NewGuid().ToString('N')
    try {
        $stream = [IO.FileStream]::new($staging, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        if ($ExpectedFileHash) {
            $null = Assert-SeedStatePath $Path
            if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -cne $ExpectedFileHash) { throw 'Seed.State.Changed: Journal changed outside the run lock; preserved without replacement.' }
            [IO.File]::Replace($staging, $Path, [System.Management.Automation.Language.NullString]::Value)
        } else {
            [IO.File]::Move($staging, $Path, $false)
        }
    } finally { if (Test-Path -LiteralPath $staging) { [IO.File]::Delete($staging) } }
}

function New-SeedRunState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$RunId, [Parameter(Mandatory)]$Context, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Operations)
    $Path = Assert-SeedStatePath $Path
    $null = Get-SeedOperationKeys $Operations
    if ($Operations.Count -eq 0) { throw 'Seed.State.Operations: Empty runs cannot be created.' }
    $Context = ConvertTo-SeedMap $Context
    $state = @{
        schemaVersion = '1.0'; runId = $RunId; context = $Context; status = 'Planned'
        fingerprint = Get-SeedFingerprint @{ schemaVersion = '1.0'; runId = $RunId; context = $Context }
        events = @(); results = @()
    }
    foreach ($entry in $Operations) {
        $operation = ConvertTo-SeedMap $entry
        # A Plan marker is explicitly not a remote Graph object ID.
        $state.events += @{ sequence = $state.events.Count; at = [DateTimeOffset]::UtcNow.ToString('o'); id = $operation.OperationId; workload = $operation.Workload; action = 'Plan'; status = 'Planned'; objectId = 'plan-sha256:' + (Get-SeedOperationDigest $operation) }
        $state.results += @{ id = $operation.OperationId; workload = $operation.Workload; status = 'Planned' }
    }
    $lock = Enter-SeedRunLock $Path
    try {
        if (Test-Path -LiteralPath $Path) { throw 'Seed.State.Exists: Existing journal is never overwritten or adopted.' }
        Write-SeedAtomicState -Path $Path -State $state
        return $state
    } finally { Exit-SeedRunLock $lock }
}

function Get-SeedRunState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$RunId, [Parameter(Mandatory)]$Context, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Operations, [switch]$ForImport)
    $Path = Assert-SeedStatePath $Path
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or (Get-Item -LiteralPath $Path).Length -gt 16777216) { throw 'Seed.State.Missing: Missing or oversized journal.' }
    try { $state = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 100 }
    catch { throw 'Seed.State.Invalid: Journal cannot be parsed; preserve it for inspection.' }
    try { Assert-SeedSchema $state run-state; Assert-SeedNoSecrets $state }
    catch { throw 'Seed.State.Invalid: Journal violates the canonical contract.' }
    $expectedFingerprint = Get-SeedFingerprint @{ schemaVersion = '1.0'; runId = $RunId; context = $Context }
    if ($state.runId -cne $RunId -or $state.fingerprint -cne $expectedFingerprint -or (Get-SeedFingerprint $state.context) -cne (Get-SeedFingerprint $Context)) { throw 'Seed.State.Context: Exact run context fingerprint differs.' }
    $expectedKeys = @(Get-SeedOperationKeys $Operations)
    $actualKeys = @($state.results | ForEach-Object { "$($_.workload)/$($_.id)" } | Sort-Object)
    if (($actualKeys -join ',') -cne ($expectedKeys -join ',')) { throw 'Seed.State.Operations: Journal result set differs from the exact selected operations.' }
    $plans = @($state.events | Where-Object action -eq Plan)
    if ($plans.Count -ne $Operations.Count) { throw 'Seed.State.Operations: Journal plan is incomplete.' }
    foreach ($operation in $Operations) {
        $markers = @($plans | Where-Object { $_.id -ceq $operation.OperationId -and $_.workload -ceq $operation.Workload })
        if ($markers.Count -ne 1 -or $markers[0].objectId -cne ('plan-sha256:' + (Get-SeedOperationDigest $operation))) { throw 'Seed.State.Operations: Exact operation data, target or Presenter fingerprint differs.' }
    }
    $latest = @{}
    $readBackDigests = @{}
    for ($i = 0; $i -lt $state.events.Count; $i++) {
        $event = $state.events[$i]
        $key = "$($event.workload)/$($event.id)"
        if ($event.sequence -ne $i -or $key -cnotin $expectedKeys) { throw 'Seed.State.Sequence: Invalid event ordering or operation.' }
        if ($event.action -eq 'Plan') {
            if ($latest.ContainsKey($key)) { throw 'Seed.State.Sequence: Duplicate Plan event.' }
        } else {
            if (-not $latest.ContainsKey($key)) { throw 'Seed.State.Sequence: Missing initial Plan.' }
            Assert-SeedStateTransition -Previous $latest[$key].status -Action $event.action -Status $event.status
        }
        if ($event.action -eq 'ReadBack' -and $event.status -eq 'Submitted') {
            if (-not $event.Contains('objectId') -or $event.objectId -cnotmatch '^readback-sha256:[0-9a-f]{64}$') { throw 'Seed.State.Evidence: Invalid read-back digest marker.' }
            $readBackDigests[$key] = $event.objectId.Substring(16)
        }
        $latest[$key] = $event
    }
    foreach ($result in $state.results) {
        $key = "$($result.workload)/$($result.id)"
        if (-not $latest.ContainsKey($key) -or $latest[$key].status -cne $result.status) { throw 'Seed.State.Results: Result does not match the journal event history.' }
        if ($result.status -eq 'Verified' -and ($latest[$key].objectId -cne $result.objectId)) { throw 'Seed.State.Results: Remote object ID differs from Verify event.' }
        if ($result.status -eq 'Verified' -and (-not $readBackDigests.ContainsKey($key) -or $readBackDigests[$key] -cne $result.evidence.sha256 -or $result.evidence.verifiedAt -cne $latest[$key].at)) {
            throw 'Seed.State.Evidence: Result evidence differs from the atomic read-back history.'
        }
    }
    if ($state.status -cne (Get-SeedRootStatus $state.results)) { throw 'Seed.State.Results: Root status differs from operation results.' }
    if ($ForImport -and ($state.status -notin @('Planned', 'Completed') -or @($state.results | Where-Object status -in @('Submitted', 'Unknown', 'Partial', 'Failed')).Count -gt 0)) { throw 'Seed.State.Blocked: Pending, partial, failed or unknown run cannot be automatically resumed.' }
    $script:SeedValidatedStates[(Get-SeedFingerprint $state)] = $true
    return $state
}

function Assert-SeedStateTransition {
    param([string]$Previous, [string]$Action, [string]$Status)
    $valid = ($Previous -eq 'Planned' -and $Action -eq 'Submit' -and $Status -eq 'Submitted') -or
        ($Previous -eq 'Submitted' -and $Action -eq 'ReadBack' -and $Status -eq 'Submitted') -or
        ($Previous -eq 'Submitted' -and $Action -eq 'Verify' -and $Status -eq 'Verified') -or
        ($Previous -eq 'Submitted' -and $Action -in @('Block', 'Fail') -and $Status -in @('Unknown', 'Partial', 'Failed'))
    if (-not $valid) { throw 'Seed.State.Transition: Unsafe journal transition; no automatic recovery or replay.' }
}

function Get-SeedRootStatus {
    param([object[]]$Results)
    if (@($Results | Where-Object status -in @('Unknown', 'Partial')).Count -gt 0) { return 'Blocked' }
    if (@($Results | Where-Object status -eq Failed).Count -gt 0) { return 'Failed' }
    if ($Results.Count -gt 0 -and @($Results | Where-Object status -ne Verified).Count -eq 0) { return 'Completed' }
    if (@($Results | Where-Object status -ne Planned).Count -gt 0) { return 'Running' }
    return 'Planned'
}

function Write-SeedRunEvent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$RunId, [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][object[]]$Operations, [Parameter(Mandatory)][string]$OperationId, [Parameter(Mandatory)][string]$Workload,
        [Parameter(Mandatory)][string]$Action, [Parameter(Mandatory)][string]$Status, [string]$ObjectId, $ReadBack = $null, [string]$ErrorCode)
    $Path = Assert-SeedStatePath $Path
    if ($Action -eq 'ReadBack') { throw 'Seed.State.Evidence: Supply authoritative ReadBack to a Verify action; digest markers are appended atomically.' }
    $lock = Enter-SeedRunLock $Path
    try {
        $expectedHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        $state = Get-SeedRunState -Path $Path -RunId $RunId -Context $Context -Operations $Operations
        $matches = @($state.results | Where-Object { $_.id -ceq $OperationId -and $_.workload -ceq $Workload })
        if ($matches.Count -ne 1) { throw 'Seed.State.Operations: Event operation is not in this run.' }
        $result = $matches[0]
        Assert-SeedStateTransition -Previous $result.status -Action $Action -Status $Status
        if ($Status -eq 'Submitted' -and @($state.results | Where-Object status -in @('Submitted', 'Partial', 'Unknown', 'Failed')).Count -gt 0) { throw 'Seed.State.Blocked: Another operation is pending or unsafe.' }
        $event = @{ sequence = $state.events.Count; at = [DateTimeOffset]::UtcNow.ToString('o'); id = $OperationId; workload = $Workload; action = $Action; status = $Status }
        if ($ObjectId) { Assert-SeedNoSecrets $ObjectId; $event.objectId = $ObjectId }
        if ($Status -eq 'Verified') {
            if (-not $ObjectId -or $null -eq $ReadBack) { throw 'Seed.State.Evidence: Verified requires authoritative read-back and object ID.' }
            Assert-SeedNoSecrets $ReadBack
            $result.objectId = $ObjectId
            $result.evidence = @{ verifiedAt = $event.at; method = 'ReadBack'; sha256 = Get-SeedFingerprint $ReadBack }
            $state.events += @{ sequence = $state.events.Count; at = $event.at; id = $OperationId; workload = $Workload; action = 'ReadBack'; status = 'Submitted'; objectId = 'readback-sha256:' + $result.evidence.sha256 }
            $event.sequence = $state.events.Count
        }
        if ($ErrorCode) {
            if ($ErrorCode -notmatch '^[A-Za-z][A-Za-z0-9_.-]{0,63}$') { throw 'Seed.State.Error: Use a sanitized error code, not exception content.' }
            $event.error = @{ code = $ErrorCode; message = 'Operation stopped; inspect retained local state and authoritative read-back.' }
        }
        $result.status = $Status
        $state.events += $event
        $state.status = Get-SeedRootStatus $state.results
        Write-SeedAtomicState -Path $Path -State $state -ExpectedFileHash $expectedHash
        return $state
    } finally { Exit-SeedRunLock $lock }
}
