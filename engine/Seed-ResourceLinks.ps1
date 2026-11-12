function Assert-SeedResourceLinks {
    param([AllowEmptyCollection()][object[]]$Links, $Scenario = $null)
    $keys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($link in $Links) {
        Assert-SeedFields $link @('kind','logicalId','resourceId','displayName','webUrl','presenterAccessStatus') 'Seed.Links.Incomplete'
        $uri = $null
        if (-not [uri]::TryCreate($link.webUrl, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -cne 'https' -or
            $uri.UserInfo -or $uri.Fragment -or -not $uri.IsDefaultPort -or
            ($uri.Query -and $uri.Host -cnotin @('teams.microsoft.com','teams.cloud.microsoft')) -or
            ($uri.Host -notmatch '^[a-z0-9-]+\.sharepoint\.com$' -and $uri.Host -cnotin @('teams.microsoft.com','teams.cloud.microsoft')) -or
            -not $keys.Add("$($link.kind)/$($link.logicalId)")) { throw 'Seed.Links.Incomplete: Exact unique unsigned resource URLs are required.' }
    }
    if ($null -ne $Scenario -and $Scenario.Contains('sharepoint')) {
        foreach ($site in $Scenario.sharepoint.sites) {
            $required = @("site/$($site.id)", "documentLibrary/$($site.id)/documents", "documentLibrary/$($site.id)/defaultDocuments")
            $required += @($site.lists | ForEach-Object { "list/$($site.id)/$($_.id)" })
            foreach ($key in $required) {
                if (-not $keys.Contains($key)) { throw 'Seed.Links.Incomplete: Every site, default/explicit library and List requires actual read-back URL evidence.' }
            }
        }
    }
    Assert-SeedNoSecrets $Links
}

function Write-SeedPrivateFile {
    param([string]$Path, [string]$Text)
    $Path = Assert-SeedStatePath $Path
    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 4096, [IO.FileOptions]::WriteThrough)
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
        $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true)
    } finally { $stream.Dispose() }
}

function Get-SeedConsoleFailureLinks {
    param($Session, $Adapter)
    # Read only genuine snapshots already obtained by this adapter; never mint a map or write capability.
    $storage = Get-SeedStorageRecord $Session $Adapter
    $links = @(); $missing = @()
    foreach ($operation in $storage.Operations) {
        $scope = $operation.StorageScope
        if ($scope.Kind -cnotin @('Group','Library','List')) { continue }
        if (-not $storage.Evidence.ContainsKey($operation.OperationId)) {
            $missing += $scope.LogicalId
            if ($scope.Kind -ceq 'Group') { $missing += "$($scope.LogicalId)/defaultDocuments" }
            continue
        }
        $snapshot = $storage.Evidence[$operation.OperationId]
        $links += @{
            kind = $(switch ($scope.Kind) { Group { 'site' } Library { 'documentLibrary' } List { 'list' } })
            logicalId=$scope.LogicalId; resourceId=$(if ($scope.Kind -ceq 'Group') { $snapshot.siteId } else { $snapshot.id })
            displayName=$scope.Body.displayName; webUrl=$snapshot.webUrl; presenterAccessStatus='RecordedReadBack; partial run, not currently Verified'
        }
        if ($scope.Kind -ceq 'Group') {
            $links += @{ kind='documentLibrary'; logicalId="$($scope.LogicalId)/defaultDocuments"; resourceId=$snapshot.defaultLibrary.id
                displayName=$snapshot.defaultLibrary.displayName; webUrl=$snapshot.defaultLibrary.webUrl; presenterAccessStatus='RecordedReadBack; partial run, not currently Verified' }
        }
    }
    Assert-SeedResourceLinks -Links $links
    return @{ Links=$links; Missing=$missing }
}

function Write-SeedSummaryFiles {
    param([Parameter(Mandatory)]$Summary, [Parameter(Mandatory)][string]$Directory)
    Assert-SeedNoSecrets $Summary
    Assert-SeedResourceLinks -Links @($Summary.ResourceLinkIndex)
    $json = Join-Path $Directory 'summary.json'; $md = Join-Path $Directory 'summary.md'
    if ((Test-Path -LiteralPath $json) -or (Test-Path -LiteralPath $md)) { throw 'Seed.Summary.Exists: Completed evidence is immutable; use a new report directory.' }
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add("# M365 Demo — $($Summary.Status)")
    $lines.Add("Mode: $($Summary.Mode); Exit: $($Summary.ExitCode)")
    foreach ($field in @('TenantId','RunId','PresenterUpn','Operator','ServiceStatus','ErrorCode')) {
        if ($Summary.Contains($field) -and $Summary[$field]) { $lines.Add("$field`: $($Summary[$field])") }
    }
    $lines.Add("Presenter checks: $($Summary.PresenterStatus); actual UI/Copilot: $($Summary.UiStatus)")
    $lines.Add(''); $lines.Add('## Workloads')
    foreach ($key in $Summary.Workloads.Keys | Sort-Object) {
        $row = $Summary.Workloads[$key]
        $lines.Add("$key`: Created=$($row.Created) Skipped=$($row.Skipped) Failed=$($row.Failed) Blocked=$($row.Blocked) Unknown=$($row.Unknown)")
    }
    if ($Summary.Contains('Personas')) {
        $people = $Summary.Personas
        $lines.Add("Personas: Created=$($people.Created) Updated=$($people.Updated) Skipped=$($people.Skipped) Failed=$($people.Failed) Unknown=$($people.Unknown); ServiceStatus=NotVerified")
    }
    $lines.Add(''); $lines.Add('## ResourceLinkIndex')
    foreach ($link in $Summary.ResourceLinkIndex) {
        $name = $link.displayName.Replace("`r",' ').Replace("`n",' ').Replace('[','\[').Replace(']','\]')
        $lines.Add("- $($link.kind) / $($link.logicalId): [$name]($($link.webUrl)) — $($link.presenterAccessStatus)")
    }
    if ($Summary.Contains('ResourceLinksMissing') -and $Summary.ResourceLinksMissing.Count -gt 0) {
        $lines.Add("Incomplete resource URLs (not guessed): $($Summary.ResourceLinksMissing -join ', ')")
    }
    # CreateNew keeps earlier success/failure evidence intact, including on reruns.
    Write-SeedPrivateFile -Path $json -Text (($Summary | ConvertTo-Json -Depth 100) + "`n")
    Write-SeedPrivateFile -Path $md -Text (($lines -join "`n") + "`n")
    return @{ Json = $json; Markdown = $md }
}
