function Assert-StorageRelativePath {
    param([string]$Path, [switch]$FileName)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -match '^[\\/]|[:\x00-\x1f]' -or ($FileName -and $Path -match '[\\/]')) { throw 'Seed.Storage.Path: Unsafe relative path.' }
    foreach ($part in ($Path -split '[\\/]')) {
        if (-not $part -or $part -in @('.', '..') -or $part -match '[<>:"|?*%#]' -or $part -match '[. ]$|^(?i:con|prn|aux|nul|com[0-9]|lpt[0-9])(?:\.|$)') { throw 'Seed.Storage.Path: Unsafe path component.' }
    }
}

function Assert-StorageWebUrl {
    param($Value, [string]$ExpectedFileName, [string]$ExpectedDocumentId, [string]$ExpectedHost)
    $uri = $null
    if ($Value -isnot [string] -or -not [uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -cne 'https' -or -not $uri.IsDefaultPort -or $uri.UserInfo -or $uri.Fragment -or
        $uri.Host -notmatch '^[a-z0-9-]+(?:-my)?\.sharepoint\.com$' -or
        ($ExpectedHost -and $uri.Host -ine $ExpectedHost)) { throw 'Seed.Storage.Link: A canonical unsigned SharePoint webUrl is required.' }
    if ($uri.Query) {
        $query = [Web.HttpUtility]::ParseQueryString($uri.Query)
        $actualId = [guid]::Empty; $expectedId = [guid]::Empty
        $viewerPath = [uri]::UnescapeDataString($uri.AbsolutePath)
        if ($viewerPath -notmatch '^/(?:[^/:\\\x00-\x1f]+/)*_layouts/15/Doc\.aspx$' -or
            $viewerPath -match '(^|/)\.\.?(/|$)' -or
            -not $ExpectedHost -or -not $ExpectedFileName -or -not [guid]::TryParse($ExpectedDocumentId, [ref]$expectedId) -or
            -not [guid]::TryParse($query['sourcedoc'], [ref]$actualId) -or $actualId -ne $expectedId -or
            $actualId -eq [guid]::Empty -or $query['file'] -cne $ExpectedFileName) {
            throw 'Seed.Storage.Link: Office viewer URL must identify the exact verified file.'
        }
        foreach ($key in $query.AllKeys) {
            if ($key -cnotin @('sourcedoc', 'file', 'action', 'mobileredirect') -or $query.GetValues($key).Count -ne 1) {
                throw 'Seed.Storage.Link: Unknown or duplicate viewer parameters are not permitted.'
            }
        }
        if (($query.AllKeys -contains 'action' -and $query['action'] -cnotin @('default', 'view', 'edit')) -or
            ($query.AllKeys -contains 'mobileredirect' -and $query['mobileredirect'] -cnotin @('true', 'false'))) {
            throw 'Seed.Storage.Link: Invalid Office viewer action.'
        }
    }
    return $Value
}

function Get-StorageFieldName {
    param([string]$ColumnId)
    'seed_' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($ColumnId))).ToLowerInvariant().Substring(0, 24)
}

function ConvertTo-StorageColumns {
    param([object[]]$Columns)
    foreach ($column in $Columns) {
        $result = @{ name = Get-StorageFieldName $column.id; displayName = $column.name }
        switch ($column.type) {
            text { $result.text = @{ allowMultipleLines = $false } }
            number { $result.number = @{ decimalPlaces = 'automatic'; displayAs = 'number' } }
            integer { $result.number = @{ decimalPlaces = 'none'; displayAs = 'number' } }
            boolean { $result.boolean = @{} }
            dateTime { $result.dateTime = @{ displayAs = 'default'; format = 'dateTime' } }
            choice { $result.choice = @{ allowTextEntry = $false; displayAs = 'dropDownMenu'; choices = @($column.choices) } }
            default { throw 'Seed.Storage.Schema: Unsupported column type.' }
        }
        $result
    }
}

function ConvertTo-StorageFields {
    param($List, $Values)
    if ($Values.Count -ne $List.columns.Count) { throw 'Seed.Storage.Fields: Exact declared field set required.' }
    $fields = @{}
    foreach ($column in $List.columns) {
        if (-not $Values.Contains($column.id)) { throw 'Seed.Storage.Fields: Missing declared field.' }
        $value = $Values[$column.id]
        switch ($column.type) {
            text { if ($value -isnot [string]) { throw 'Seed.Storage.Fields: Text required.' } }
            boolean { if ($value -isnot [bool]) { throw 'Seed.Storage.Fields: Boolean required.' } }
            number {
                if ($value -is [bool] -or $value -is [string] -or $null -eq $value -or -not [double]::IsFinite([double]$value)) { throw 'Seed.Storage.Fields: Finite number required.' }
                $value = [double]$value
            }
            integer {
                if ($value -is [bool] -or $value -is [string] -or $null -eq $value -or [double]$value -ne [Math]::Truncate([double]$value)) { throw 'Seed.Storage.Fields: Integer required.' }
                $value = [long]$value
            }
            dateTime {
                if ($value -isnot [string] -or $value -notmatch '(Z|[+-]\d\d:\d\d)$') { throw 'Seed.Storage.Fields: Offset datetime required.' }
                $value = [DateTimeOffset]::Parse($value, [Globalization.CultureInfo]::InvariantCulture).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
            }
            choice { if ($value -isnot [string] -or $value -cnotin $column.choices) { throw 'Seed.Storage.Fields: Exact choice required.' } }
        }
        $fields[(Get-StorageFieldName $column.id)] = $value
    }
    return $fields
}

Export-ModuleMember -Function Assert-StorageRelativePath, Assert-StorageWebUrl, Get-StorageFieldName, ConvertTo-StorageColumns, ConvertTo-StorageFields
