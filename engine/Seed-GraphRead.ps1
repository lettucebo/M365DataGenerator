# Dot-source this file before the other engine files. No authentication occurs on load.
$script:SeedEngineRoot = Split-Path $PSScriptRoot -Parent
if (-not (Get-Variable SeedSessions -Scope Script -ErrorAction SilentlyContinue)) {
    $script:SeedSessions = @{}
    $script:SeedValidatedStates = @{}
    $script:SeedSecretEnvironmentVariables = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
}

function ConvertTo-SeedMap {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary] -or $Value -is [pscustomobject]) {
        try { return $Value | ConvertTo-Json -Depth 100 -Compress -EnumsAsStrings | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String }
        catch { throw 'Seed.Input.Object: Expected a finite JSON object within the supported depth.' }
    }
    throw 'Seed.Input.Object: Expected a JSON object.'
}

function Assert-SeedFields {
    param($Value, [string[]]$Fields, [string]$Code = 'Seed.Input')
    if ($null -eq $Value -or $Value -isnot [System.Collections.IDictionary]) { throw "$Code`: Expected a JSON object." }
    foreach ($field in $Fields) {
        if (-not $Value.Contains($field) -or $null -eq $Value[$field]) { throw "$Code`: A required field is missing." }
    }
}

function Assert-SeedGuid {
    param($Value)
    if ($Value -isnot [string] -or $Value -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        throw 'Seed.Input.Guid: Expected a GUID.'
    }
}

function Assert-SeedNoSecrets {
    param($Value)
    if ($null -eq $Value) { return }
    if ($Value -is [pscustomobject]) { $Value = ConvertTo-SeedMap $Value }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            if ($key -ceq 'clientSecretEnvironmentVariable' -and $Value[$key] -is [string] -and $Value[$key] -match '^[A-Za-z_][A-Za-z0-9_]*$') { continue }
            if ($key -match '(?i)(password|secret|(^|_)token($|_)|access.?token|refresh.?token|authorization|capability|downloadurl|uploadurl)') {
                throw 'Seed.Secret: Sensitive evidence is not permitted.'
            }
            Assert-SeedNoSecrets $Value[$key]
        }
    } elseif ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        foreach ($item in $Value) { Assert-SeedNoSecrets $item }
    } elseif ($Value -is [string]) {
        $decoded = [uri]::UnescapeDataString([uri]::UnescapeDataString($Value))
        if ($decoded -match '(?i)(bearer\s|https?://[^\s]*[?&](sig|token|access_token|authkey|tempauth|capability)=|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.)') {
            throw 'Seed.Secret: Sensitive evidence is not permitted.'
        }
    }
}

function Invoke-SeedPython {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Code, [Parameter(Mandatory)][AllowNull()]$InputObject, [string[]]$SecretEnvironmentVariables = @())
    Assert-SeedNoSecrets $InputObject
    $python = Join-Path $script:SeedEngineRoot '.venv\Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { throw 'Seed.Python.Missing: Restore the locked local Python environment first.' }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $python
    $start.WorkingDirectory = $script:SeedEngineRoot
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $start.ArgumentList.Add('-I')
    $start.ArgumentList.Add('-X')
    $start.ArgumentList.Add('utf8')
    $start.ArgumentList.Add('-c')
    $start.ArgumentList.Add($Code)
    foreach ($name in @($start.Environment.Keys)) {
        if ($name -match '(?i)(secret|token|password)' -or $name -in $SecretEnvironmentVariables -or $script:SeedSecretEnvironmentVariables.Contains($name)) {
            $null = $start.Environment.Remove($name)
        }
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        $null = $process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write(($InputObject | ConvertTo-Json -Depth 100 -Compress))
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(30000)) {
            $process.Kill($true)
            throw 'Seed.Python.Timeout: Offline helper timed out.'
        }
        if ($process.ExitCode -ne 0) { throw 'Seed.Python.Failed: Offline helper rejected the input.' }
        return $stdout.GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
    } catch { throw 'Seed.Python.Failed: Offline helper failed; no child output is disclosed.' }
    finally { $process.Dispose() }
}

function Get-SeedFingerprint {
    param([Parameter(Mandatory)][AllowNull()]$Value)
    Assert-SeedNoSecrets $Value
    if (-not (Get-Variable SeedFingerprintCache -Scope Script -ErrorAction SilentlyContinue)) { $script:SeedFingerprintCache = @{} }
    $wire = $Value | ConvertTo-Json -Depth 100 -Compress
    $key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($wire)))
    if ($script:SeedFingerprintCache.ContainsKey($key)) { return $script:SeedFingerprintCache[$key] }
    $digest = Invoke-SeedPython -Code 'import json,sys,hashlib; d=json.load(sys.stdin); b=(json.dumps(d,sort_keys=True,ensure_ascii=False,separators=(",",":"),allow_nan=False)+"\n").encode("utf-8"); print(json.dumps(hashlib.sha256(b).hexdigest()))' -InputObject $Value
    if ($script:SeedFingerprintCache.Count -ge 4096) { $script:SeedFingerprintCache.Clear() }
    $script:SeedFingerprintCache[$key] = $digest
    return $digest
}

function Assert-SeedSchema {
    param($Value, [Parameter(Mandatory)][string]$Name)
    if ($Name -notin @('config', 'personas', 'scenario', 'persona-binding', 'run-state')) { throw 'Seed.Input.Schema: Unknown schema.' }
    $result = Invoke-SeedPython -Code 'import json,sys; from pathlib import Path; from jsonschema import Draft202012Validator,FormatChecker; d=json.load(sys.stdin); s=json.loads((Path("schemas")/(d["name"]+".schema.json")).read_text(encoding="utf-8")); print(json.dumps({"valid":not any(Draft202012Validator(s,format_checker=FormatChecker()).iter_errors(d["value"]))}))' -InputObject @{ name = $Name; value = $Value }
    if (-not $result.valid) { throw 'Seed.Input.Schema: Input does not match the canonical contract.' }
}

function Get-SeedSessionRecord {
    param($Session)
    if ($null -eq $Session -or -not $Session.PSObject.Properties['SessionId'] -or -not $script:SeedSessions.ContainsKey([string]$Session.SessionId)) {
        throw 'Seed.Auth.Session: A verified engine session is required.'
    }
    $record = $script:SeedSessions[[string]$Session.SessionId]
    if (-not [object]::ReferenceEquals($record.Handle, $Session)) { throw 'Seed.Auth.Session: Session handle is not authentic.' }
    return $record
}

function Close-SeedSession {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session)
    $record = Get-SeedSessionRecord $Session
    if ($record.Contains('Lease') -and $null -ne $record.Lease) { $record.Lease.Dispose() }
    $record.Transport = $null
    $record.Approval = $null
    $record.PersonaWriteGuard = $null
    if ($record.Contains('AppAuth')) { $record.AppAuth.Token = $null; $record.AppAuth.Acquire = $null }
    if ($record.Contains('Uploads')) { $record.Uploads.Clear() }
    if ($record.Contains('UploadTransport')) { $record.UploadTransport = $null }
    if ($record.Contains('StorageAdapters')) { $record.StorageAdapters.Clear() }
    if ($record.Contains('StorageAssetMaps')) { $record.StorageAssetMaps.Clear() }
    if ($record.Contains('OutlookAdapters')) { $record.OutlookAdapters.Clear() }
    if ($record.Contains('TeamsAdapters')) { $record.TeamsAdapters.Clear() }
    if (Get-Variable SeedPersonaPlans -Scope Script -ErrorAction SilentlyContinue) {
        foreach ($key in @($script:SeedPersonaPlans.Keys)) {
            if ([object]::ReferenceEquals($script:SeedPersonaPlans[$key].Session, $Session)) { $script:SeedPersonaPlans.Remove($key) }
        }
    }
    $script:SeedSessions.Remove($Session.SessionId)
}

function New-SeedSessionHandle {
    param([string]$Kind, [string]$Mode, [string]$TenantId, [string]$ClientId, [string]$Operator, [string[]]$Permissions, [scriptblock]$Transport, [scriptblock]$Delay)
    $handle = [pscustomobject]@{ SessionId = [guid]::NewGuid().ToString(); Kind = $Kind; Mode = $Mode; TenantId = $TenantId; ClientId = $ClientId; Operator = $Operator; Permissions = @($Permissions) }
    $script:SeedSessions[$handle.SessionId] = @{
        Handle = $handle; Kind = $Kind; Mode = $Mode; TenantId = $TenantId; ClientId = $ClientId; Operator = $Operator
        Permissions = @($Permissions); Transport = $Transport; Delay = $Delay; ReadOnlyDepth = 0; Approval = $null
    }
    return $handle
}

function ConvertTo-SeedGraphPath {
    param($Path)
    if ($Path -isnot [string] -or [string]::IsNullOrWhiteSpace($Path) -or $Path -match '[\x00-\x20\\#]' -or $Path.StartsWith('//')) {
        throw 'Seed.Path: Invalid Graph path.'
    }
    $rawResource = ($Path -split '\?', 2)[0]
    if ($rawResource -match '(?i)(^|/)\.\.?(/|$)|%2e|%2f|%5c|%25') { throw 'Seed.Path: Encoded or normalized traversal is not permitted.' }
    if ($Path -match '^https?://') {
        $uri = $null
        if (-not [uri]::TryCreate($Path, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -cne 'https' -or $uri.Host -cne 'graph.microsoft.com' -or -not $uri.IsDefaultPort -or $uri.UserInfo -or $uri.Fragment -or $uri.AbsolutePath -cnotmatch '^/v1\.0/') {
            throw 'Seed.Path: Only the Global Graph v1.0 endpoint is allowed.'
        }
        $Path = $uri.PathAndQuery
    }
    if (-not $Path.StartsWith('/')) { throw 'Seed.Path: Expected an absolute Graph resource path.' }
    $Path = $Path -creplace '^/v1\.0/', '/'
    $resource = ($Path -split '\?', 2)[0]
    $decoded = [uri]::UnescapeDataString([uri]::UnescapeDataString($resource))
    $decodedQuery = [uri]::UnescapeDataString([uri]::UnescapeDataString($Path))
    if ($resource -match '(?i)%2e|%2f|%5c|%25' -or $decoded -match '(^|/)\.\.?(/|$)|^/(beta|v1\.0)(/|$)|//' -or $decodedQuery -match '(?i)[?&](access_token|token|sig|authkey|tempauth|capability)=') {
        throw 'Seed.Path: Unsafe Graph path or capability URL.'
    }
    return $Path
}

function Get-SeedGraphFailure {
    param([Exception]$Exception)
    $status = 0; $retry = 0
    try {
    if ($Exception.Data.Contains('StatusCode')) { $status = [int]$Exception.Data['StatusCode'] }
    elseif ($Exception.PSObject.Properties['Response'] -and $null -ne $Exception.Response -and $Exception.Response.PSObject.Properties['StatusCode']) {
        $status = [int]$Exception.Response.StatusCode
    }
    if ($Exception.Data.Contains('RetryAfterSeconds')) { $retry = [int]$Exception.Data['RetryAfterSeconds'] }
    elseif ($Exception.PSObject.Properties['Response'] -and $null -ne $Exception.Response -and $Exception.Response.PSObject.Properties['Headers']) {
        $headers = $Exception.Response.Headers
        if ($headers.PSObject.Properties['RetryAfter'] -and $null -ne $headers.RetryAfter) {
            if ($null -ne $headers.RetryAfter.Delta) { $retry = [int][Math]::Ceiling($headers.RetryAfter.Delta.TotalSeconds) }
            elseif ($null -ne $headers.RetryAfter.Date) { $retry = [int][Math]::Ceiling(($headers.RetryAfter.Date - [DateTimeOffset]::UtcNow).TotalSeconds) }
        }
    }
    } catch { $status = 0; $retry = 31 }
    @{ Status = $status; Retry = [Math]::Max(0, $retry) }
}

function Invoke-SeedGraph {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$Method, [Parameter(Mandatory)][string]$Path, $Body = $null, [byte[]]$RawBody = $null, $AdminCapability = $null)
    $record = Get-SeedSessionRecord $Session
    $Method = $Method.ToUpperInvariant()
    $Path = ConvertTo-SeedGraphPath $Path
    if ($Method -notin @('GET', 'POST', 'PATCH', 'PUT')) { throw 'Seed.Write.Method: This HTTP method is not allowed.' }
    if ($null -ne $Body -and $null -ne $RawBody) { throw 'Seed.Input.Body: Body and RawBody are mutually exclusive.' }
    if ($Method -eq 'GET' -and ($null -ne $Body -or $null -ne $RawBody)) { throw 'Seed.Input.Body: GET requests cannot contain a body.' }
    Assert-SeedAppSessionReady $Session
    $write = $null
    if ($Method -ne 'GET') {
        if ($null -ne $AdminCapability) {
            if ($record.Kind -cne 'App' -or $record.Mode -cne 'InitializePersonas' -or $record.ReadOnlyDepth -gt 0 -or
                -not $record.Contains('PersonaWriteGuard') -or $record.PersonaWriteGuard -isnot [scriptblock]) {
                throw 'Seed.Write.Persona: A private plan-bound administration capability is required.'
            }
            $write = & $record.PersonaWriteGuard $AdminCapability $Method $Path $Body $RawBody
        } else { $write = Start-SeedAuthorizedWrite -Record $record -Method $Method -Path $Path -Body $Body -RawBody $RawBody }
    }
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            $result = & $record.Transport $Method $Path $Body $RawBody
            if ($result -is [byte[]]) { return ,$result }
            # Invoke-RestMethod and the Graph SDK return a JSON object as PSCustomObject; callers expect a dictionary.
            if ($result -is [System.Management.Automation.PSCustomObject]) { return ConvertTo-SeedMap $result }
            return $result
        } catch {
            $requestError = $_
            $failure = Get-SeedGraphFailure $requestError.Exception
            if ($Method -eq 'GET' -and $failure.Status -in @(429, 500, 502, 503, 504) -and $attempt -lt 3 -and $failure.Retry -le 30) {
                $seconds = [Math]::Max($failure.Retry, [Math]::Pow(2, $attempt - 1))
                & $record.Delay $seconds | Out-Null
                continue
            }
            if ($Method -ceq 'POST' -and $null -eq $Body -and $null -eq $RawBody -and
                $failure.Status -in @(502, 503, 504) -and $null -ne $write -and $write.Contains('Approval') -and
                $write.Rule.Workload -ceq 'teams' -and $record.Contains('TeamsCompletionProbe') -and
                $record.TeamsCompletionProbe -is [scriptblock]) {
                $completion = @($write.Approval.Operations | Where-Object {
                    $_.OperationId -ceq $write.Rule.OperationId -and $_.Contains('TeamsScope') -and
                    $_.TeamsScope.Kind -ceq 'CompleteChannel'
                })
                if ($completion.Count -eq 1) {
                    try {
                        if ($attempt -lt 3) { & $record.Delay 2 | Out-Null }
                        $mode = & $record.TeamsCompletionProbe $completion[0] $Path
                        Write-Host ('[TeamsCompletionObservation] ' + (@{ Attempt = $attempt; Mode = $mode } | ConvertTo-Json -Compress))
                        if ($mode -ceq 'completed') { return $null }
                        if ($mode -ceq 'inProgress' -and $attempt -lt 3) { continue }
                    } catch {
                        Write-Host ('[TeamsCompletionObservation] ' + (@{ Attempt = $attempt; Mode = 'Unproven' } | ConvertTo-Json -Compress))
                    }
                }
            }
            if ($null -ne $write) {
                if ($write.Contains('PersonaUnknown')) { & $write.PersonaUnknown | Out-Null }
                else { Complete-SeedUnknownWrite -Write $write }
            }
            $kind = switch -Regex ($Path) {
                '^/drives/[^/]+/items/[^/]+/permissions' { 'DrivePermissions'; break }
                '^/drives/[^/]+/items/[^/]+/content$' { 'DriveContent'; break }
                '^/drives/[^/]+/items/' { 'DriveItem'; break }
                '^/users/[^/]+/drive' { 'PresenterDrive'; break }
                '^/users/[^/]+/manager' { 'UserManager'; break }
                '^/users/' { 'UserProfile'; break }
                default { 'Resource' }
            }
            $providerCode = $null
            $exceptionType = $requestError.Exception.GetType().FullName
            try {
                $provider = $requestError.ErrorDetails.Message | ConvertFrom-Json -AsHashtable -ErrorAction Stop
                if ($provider.error.code -cmatch '^[A-Za-z][A-Za-z0-9_.-]{0,80}$') { $providerCode = $provider.error.code }
            } catch { $providerCode = $null }
            $requestFailure = [InvalidOperationException]::new("Seed.Graph.$($failure.Status): Graph request failed; inspect permissions, service readiness, or retained pending state.")
            $requestFailure.Data['StatusCode'] = $failure.Status
            $requestFailure.Data['SeedDiagnostic'] = @{
                Stage = 'GraphRequest'; HttpStatus = $failure.Status; RequestKind = $kind; Method = $Method
                ProviderCode = $providerCode; ExceptionType = $exceptionType
            }
            throw $requestFailure
        }
    }
}

function Get-SeedGraphCollection {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$Path, [ValidateRange(1, 1000)][int]$MaxPages = 100)
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $items = [System.Collections.Generic.List[object]]::new()
    for ($page = 0; $page -lt $MaxPages; $page++) {
        $Path = ConvertTo-SeedGraphPath $Path
        if (-not $seen.Add($Path)) { throw 'Seed.Pagination: Repeated nextLink.' }
        $result = ConvertTo-SeedMap (Invoke-SeedGraph -Session $Session -Method GET -Path $Path)
        Assert-SeedFields $result @('value') 'Seed.Pagination'
        if ($result.value -isnot [System.Collections.IList]) { throw 'Seed.Pagination: A collection response is required.' }
        foreach ($item in $result.value) { $items.Add($item) }
        if (-not $result.Contains('@odata.nextLink') -or $null -eq $result['@odata.nextLink']) { return $items.ToArray() }
        $Path = $result['@odata.nextLink']
    }
    throw 'Seed.Pagination: Page bound exceeded.'
}

function Read-SeedGraphContent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][scriptblock]$Send)
    $path = ConvertTo-SeedGraphPath $Path
    if ($path -cnotmatch '^/drives/[^/]+/items/[^/]+/content$') { throw 'Seed.Content.Path: Only exact drive item content reads are supported.' }
    $uri = [uri]"https://graph.microsoft.com/v1.0$path"
    for ($hop = 0; $hop -lt 4; $hop++) {
        $response = & $Send $uri ($hop -eq 0)
        if ($response -isnot [Net.Http.HttpResponseMessage]) { throw 'Seed.Content.Response: A typed HTTP response is required.' }
        try {
            if ([int]$response.StatusCode -in @(301, 302, 303, 307, 308)) {
                $next = $response.Headers.Location
                if ($null -eq $next -or -not $next.IsAbsoluteUri -or $next.Scheme -cne 'https' -or -not $next.IsDefaultPort -or $next.UserInfo -or $next.Fragment -or
                    $next.Host -notmatch '^[a-z0-9-]+(?:-my)?\.sharepoint\.com$') { throw 'Seed.Content.Redirect: Unsafe content redirect.' }
                $uri = $next
                continue
            }
            if (-not $response.IsSuccessStatusCode) {
                $failure = [InvalidOperationException]::new('Seed.Content.Read: Content read failed.')
                $failure.Data['StatusCode'] = [int]$response.StatusCode
                $retry = $response.Headers.RetryAfter
                if ($null -ne $retry) {
                    if ($null -ne $retry.Delta) { $failure.Data['RetryAfterSeconds'] = [int][Math]::Ceiling($retry.Delta.TotalSeconds) }
                    elseif ($null -ne $retry.Date) { $failure.Data['RetryAfterSeconds'] = [int][Math]::Ceiling(($retry.Date - [DateTimeOffset]::UtcNow).TotalSeconds) }
                }
                throw $failure
            }
            if ($response.Content.Headers.ContentLength -gt 33554432) { throw 'Seed.Content.Size: Oversized content.' }
            $stream = $response.Content.ReadAsStream()
            $buffer = [byte[]]::new(65536); $output = [IO.MemoryStream]::new()
            try {
                while (($count = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    if ($output.Length + $count -gt 33554432) { throw 'Seed.Content.Size: Oversized content.' }
                    $output.Write($buffer, 0, $count)
                }
                return ,$output.ToArray()
            } finally { $stream.Dispose(); $output.Dispose() }
        } finally { $response.Dispose() }
    }
    throw 'Seed.Content.Redirect: Content redirect bound exceeded.'
}
