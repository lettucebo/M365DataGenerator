function Assert-SeedAppToken {
    param([string]$Token, [string]$TenantId, [string]$ClientId, [string[]]$RequiredRoles)
    try {
        $segments = $Token.Split('.')
        if ($segments.Length -ne 3) { throw 'format' }
        $segment = $segments[1].Replace('-', '+').Replace('_', '/')
        $segment = $segment.PadRight($segment.Length + (4 - $segment.Length % 4) % 4, '=')
        $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($segment)) | ConvertFrom-Json -AsHashtable
        Assert-SeedFields $claims @('tid', 'aud', 'iss', 'exp', 'roles')
        $application = if ($claims.Contains('appid')) { $claims.appid } elseif ($claims.Contains('azp')) { $claims.azp } else { '' }
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        if ($claims.tid -ine $TenantId -or $application -ine $ClientId -or $claims.aud -notin @('https://graph.microsoft.com', 'https://graph.microsoft.com/', '00000003-0000-0000-c000-000000000000') -or
            $claims.iss -notin @("https://sts.windows.net/$TenantId/", "https://login.microsoftonline.com/$TenantId/v2.0") -or
            [long]$claims.exp -le $now -or ($claims.Contains('nbf') -and [long]$claims.nbf -gt $now + 60) -or
            $claims.Contains('scp') -or $claims.roles -isnot [System.Collections.IList]) { throw 'identity' }
        if ($claims.Contains('appid') -and $claims.Contains('azp') -and $claims.appid -ine $claims.azp) { throw 'identity' }
        $missing = @($RequiredRoles | Where-Object { -not (Test-SeedAppPermission -Granted $claims.roles -Required $_) })
        if ($missing.Count -gt 0) { throw ('Seed.Auth.Roles: Missing application roles: ' + ($missing -join ', ')) }
        return @($claims.roles)
    } catch {
        if ($_.Exception.Message -like 'Seed.Auth.Roles:*') { throw }
        throw 'Seed.Auth.Token: App token tenant, client, audience, issuer, lifetime or roles do not match.'
    }
}

function Get-SeedAppTokenExpiry {
    param([string]$Token)
    $segment = $Token.Split('.')[1].Replace('-', '+').Replace('_', '/')
    $segment = $segment.PadRight($segment.Length + (4 - $segment.Length % 4) % 4, '=')
    [long](([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($segment)) | ConvertFrom-Json -AsHashtable).exp)
}

function Assert-SeedAppSessionReady {
    param($Session)
    $record = Get-SeedSessionRecord $Session
    if ($record.Kind -cne 'App') { throw 'Seed.Auth.Context: Application session required.' }
    if (-not $record.Contains('AppAuth')) { throw 'Seed.Auth.Context: Verified application connection required.' }
    $auth = $record.AppAuth
    if ($auth.ExpiresAt -gt [DateTimeOffset]::UtcNow.AddMinutes(2).ToUnixTimeSeconds()) { return }
    try { $token = & $auth.Acquire }
    catch { throw 'Seed.Auth.Acquire: Application renewal failed before submission; no fallback or write retry.' }
    $permissions = @(Assert-SeedAppToken -Token $token -TenantId $record.TenantId -ClientId $record.ClientId -RequiredRoles $auth.RequiredRoles)
    $auth.Token = $token; $auth.ExpiresAt = Get-SeedAppTokenExpiry $token
    $record.Permissions = $permissions; $record.Handle.Permissions = $permissions
}

function Connect-SeedSession {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [string]$Mode = 'Preflight', [string[]]$RequiredRoles = @('User.Read.All'), [scriptblock]$TokenProvider, [scriptblock]$Transport, [scriptblock]$Delay = { param($Seconds) Start-Sleep -Seconds $Seconds }, [scriptblock]$UploadTransport, [scriptblock]$Send)
    if ($Mode -notin @('RunAll', 'Preflight', 'Import', 'Verify','InspectUsers','InitializePersonas')) { throw 'Seed.Mode: This mode does not use app authentication.' }
    $Config = ConvertTo-SeedMap $Config
    Assert-SeedFields $Config @('tenantId', 'clientId', 'clientSecretEnvironmentVariable', 'presenterUpn')
    Assert-SeedGuid $Config.tenantId; Assert-SeedGuid $Config.clientId
    if ($Config.Contains('adminAuth') -and $Config.adminAuth.Contains('clientId') -and $Config.adminAuth.clientId -ine $Config.clientId) {
        throw 'Seed.Auth.Migration: Legacy adminAuth.clientId must equal top-level clientId; use the same application.'
    }
    if ($Mode -in @('InspectUsers','InitializePersonas')) { $RequiredRoles = @(Get-SeedManagementAppRoles $Mode -AccountSource (Get-SeedPersonaAccountSource $Config)) }
    if ($Config.presenterUpn -isnot [string] -or $Config.presenterUpn -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$') { throw 'Seed.Input.Presenter: Explicit Presenter UPN is required.' }
    if ($Config.clientSecretEnvironmentVariable -isnot [string] -or $Config.clientSecretEnvironmentVariable -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw 'Seed.Input.SecretVariable: Invalid environment variable name.' }
    $null = $script:SeedSecretEnvironmentVariables.Add($Config.clientSecretEnvironmentVariable)
    $injected = $null -ne $TokenProvider -or $null -ne $Transport
    if ($null -ne $Send -and $injected) { throw 'Seed.Injection: HTTP primitive injection cannot mix with token or Graph transport injection.' }
    if ($injected -and ($null -eq $TokenProvider -or $null -eq $Transport)) { throw 'Seed.Injection: Supply both token provider and transport; live fallback is never used.' }
    $tenant = $Config.tenantId; $client = $Config.clientId; $variable = $Config.clientSecretEnvironmentVariable
    $acquire = {
        if ($injected) {
            return & $TokenProvider $tenant $client $variable
        } else {
            $secret = [Environment]::GetEnvironmentVariable($variable, 'Process')
            if ([string]::IsNullOrWhiteSpace($secret)) { throw 'missing' }
            try {
                $options = @{ Uri = "https://login.microsoftonline.com/$tenant/oauth2/v2.0/token"; Method = 'POST'; MaximumRedirection = 0; MaximumRetryCount = 0; TimeoutSec = 60; ErrorAction = 'Stop'
                    Body = @{ client_id = $client; client_secret = $secret; scope = 'https://graph.microsoft.com/.default'; grant_type = 'client_credentials' } }
                $response = if ($null -ne $Send) { & $Send $options } else { Invoke-RestMethod @options }
                return $response.access_token
            } finally { $secret = $null; $response = $null }
        }
    }.GetNewClosure()
    $token = $null
    try {
        $token = & $acquire
        if ($token -isnot [string] -or [string]::IsNullOrWhiteSpace($token)) { throw 'token' }
    } catch { throw 'Seed.Auth.Acquire: App authentication failed; no credentials or provider output is disclosed.' }
    finally { $secret = $null; $response = $null }
    $permissions = @(Assert-SeedAppToken -Token $token -TenantId $Config.tenantId -ClientId $Config.clientId -RequiredRoles $RequiredRoles)
    $auth = @{ Token = $token; ExpiresAt = Get-SeedAppTokenExpiry $token; Acquire = $acquire; RequiredRoles = $RequiredRoles }
    if (-not $injected) {
        if ($null -ne $UploadTransport) { throw 'Seed.Injection: An injected upload transport requires explicit token and Graph transport injection.' }
        $Transport = {
            param($Method, $Path, $Body, $RawBody)
            $privateToken = $auth.Token
            $photo = $Path -cmatch '^/users/[0-9a-fA-F-]{36}/photo/\$value$'
            if ($Method -ceq 'GET' -and $photo) {
                $options = @{ Uri = "https://graph.microsoft.com/v1.0$Path"; Method = 'GET'; Headers = @{ Authorization = "Bearer $privateToken" }; MaximumRedirection = 0 }
                $handler = [Net.Http.HttpClientHandler]::new(); $handler.AllowAutoRedirect = $false
                $http = [Net.Http.HttpClient]::new($handler); $http.Timeout = [TimeSpan]::FromSeconds(60)
                $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, $options.Uri)
                $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $privateToken)
                $response = $null
                try {
                    $response = if ($null -ne $Send) { & $Send $options } else { $http.Send($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead) }
                    if ($response -isnot [Net.Http.HttpResponseMessage]) { throw 'Seed.Photo.Response: Typed HTTP response required.' }
                    if (-not $response.IsSuccessStatusCode) {
                        $failure = [InvalidOperationException]::new('Photo request failed.'); $failure.Data['StatusCode'] = [int]$response.StatusCode; throw $failure
                    }
                    return ,($response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult())
                } finally { if ($null -ne $response) { $response.Dispose() }; $request.Dispose(); $http.Dispose(); $handler.Dispose() }
            }
            if ($Method -ceq 'GET' -and $Path -cmatch '^/drives/[^/]+/items/[^/]+/content$') {
                $handler = [Net.Http.HttpClientHandler]::new()
                $handler.AllowAutoRedirect = $false
                $http = [Net.Http.HttpClient]::new($handler)
                $http.Timeout = [TimeSpan]::FromSeconds(60)
                $send = {
                    param($Uri, $UseGraphAuthorization)
                    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, $Uri)
                    if ($UseGraphAuthorization) { $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $privateToken) }
                    try { return $http.Send($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead) }
                    finally { $request.Dispose() }
                }.GetNewClosure()
                try { return ,(Read-SeedGraphContent -Path $Path -Send $send) }
                finally { $http.Dispose(); $handler.Dispose() }
            }
            $options = @{
                Uri = "https://graph.microsoft.com/v1.0$Path"; Method = $Method
                Headers = @{ Authorization = "Bearer $privateToken" }
                MaximumRedirection = 0; MaximumRetryCount = 0; TimeoutSec = 60; ErrorAction = 'Stop'
            }
            if ($null -ne $RawBody) { $options.Body = $RawBody; $options.ContentType = $(if ($Method -ceq 'PUT' -and $photo) { 'image/jpeg' } else { 'application/octet-stream' }) }
            elseif ($null -ne $Body) { $options.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 100 -Compress)); $options.ContentType = 'application/json' }
            if ($null -ne $Send) { & $Send $options } else { Invoke-RestMethod @options }
        }.GetNewClosure()
        $UploadTransport = {
            param($Url, $Bytes, $Headers)
            if ($null -eq $Bytes) {
                return Invoke-RestMethod -Uri $Url -Method GET -MaximumRedirection 0 -MaximumRetryCount 0 -TimeoutSec 60 -ErrorAction Stop
            }
            try {
                Invoke-RestMethod -Uri $Url -Method PUT -Headers $Headers -Body $Bytes -ContentType 'application/octet-stream' -MaximumRedirection 0 -MaximumRetryCount 0 -TimeoutSec 120 -ErrorAction Stop
            } catch {
                $_.Exception.Data['SeedDiagnostic'] = @{
                    Stage = 'UploadPut'; HttpStatus = (Get-SeedGraphFailure $_.Exception).Status
                    ExceptionType = $_.Exception.GetType().FullName
                    RequestError = $(if ($_.Exception.PSObject.Properties['HttpRequestError']) { $_.Exception.HttpRequestError.ToString() } else { 'Unknown' })
                    ByteLength = $Bytes.Length; HeaderLengthMatches = ([string]$Headers['Content-Length'] -ceq [string]$Bytes.Length)
                }
                throw
            }
        }
    }
    $token = $null
    $session = New-SeedSessionHandle -Kind App -Mode $Mode -TenantId $Config.tenantId -ClientId $Config.clientId -Permissions $permissions -Transport $Transport -Delay $Delay
    (Get-SeedSessionRecord $session).ExpectedPresenterUpn = $Config.presenterUpn
    (Get-SeedSessionRecord $session).UploadTransport = $UploadTransport
    (Get-SeedSessionRecord $session).AppAuth = $auth
    return $session
}
