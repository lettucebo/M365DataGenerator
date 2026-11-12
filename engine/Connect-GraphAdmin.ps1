function Get-SeedPersonaAccountSource {
    # Public source selector: only the schema-validated personas.accountSource may choose Existing; anything else is Managed.
    param($Config)
    if ($Config -is [System.Collections.IDictionary] -and $Config.Contains('personas') -and $Config['personas'] -is [System.Collections.IDictionary] -and
        $Config['personas'].Contains('accountSource') -and $Config['personas']['accountSource'] -ceq 'Existing') { return 'Existing' }
    return 'Managed'
}

function Get-SeedAdminScopes {
    param([string]$Mode, [ValidateSet('Managed', 'Existing')][string]$AccountSource = 'Managed')
    Get-SeedManagementAppRoles -Mode $Mode -AccountSource $AccountSource
}

function New-SeedAdminAuthFailure {
    param([string]$Code, [ValidateSet('SDKLoad', 'SDKConnect', 'SDKContext', 'ContextValidation', 'ScopeValidation', 'OperatorRead', 'RoleRead', 'RoleValidation')][string]$Stage,
        [Exception]$Failure, [string[]]$MissingScopes = @(), [string[]]$UnexpectedScopes = @())
    $diagnostic = @{
        Stage = $Stage; MissingScopes = @(); UnexpectedScopes = @()
        OAuthError = 'Unknown'; AadstsCode = 'Unknown'; CorrelationId = $null
    }
    foreach ($pair in @(@('MissingScopes', $MissingScopes), @('UnexpectedScopes', $UnexpectedScopes))) {
        $diagnostic[$pair[0]] = @($pair[1] | Where-Object { $_ -is [string] -and $_.Length -le 96 -and $_ -cmatch '^[A-Za-z][A-Za-z0-9]*(?:\.[A-Za-z][A-Za-z0-9]*){1,5}$' } | Sort-Object -Unique)
    }
    $oauthErrors = @('invalid_request', 'invalid_client', 'invalid_grant', 'unauthorized_client', 'invalid_scope', 'access_denied',
        'unsupported_grant_type', 'unsupported_response_type', 'server_error', 'temporarily_unavailable',
        'interaction_required', 'login_required', 'consent_required', 'authorization_pending', 'slow_down', 'expired_token', 'bad_verification_code')
    $current = $Failure
    for ($depth = 0; $null -ne $current -and $depth -lt 4; $depth++) {
        if ($current.PSObject.Properties['ErrorCode'] -and $current.ErrorCode -cin $oauthErrors) { $diagnostic.OAuthError = [string]$current.ErrorCode }
        if ($current.PSObject.Properties['CorrelationId'] -and [string]$current.CorrelationId -match '^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') {
            $diagnostic.CorrelationId = [string]$current.CorrelationId
        }
        $message = $current.Message
        $match = [regex]::Match($message, '\bAADSTS[0-9]{5,9}\b')
        if ($match.Success) { $diagnostic.AadstsCode = $match.Value }
        $match = [regex]::Match($message, '(?i)\bcorrelation[ _-]?id\s*[:=]\s*([0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12})\b')
        if ($match.Success) { $diagnostic.CorrelationId = $match.Groups[1].Value }
        if ($diagnostic.OAuthError -ceq 'Unknown') {
            $match = [regex]::Match($message, '\b(' + ($oauthErrors -join '|') + ')\b')
            if ($match.Success) { $diagnostic.OAuthError = $match.Value }
        }
        $current = $current.InnerException
    }
    # Never retain the original exception, raw message, SDK context or token as diagnostic data.
    $result = [InvalidOperationException]::new("$Code`: Administrator authentication failed; see safe diagnostic fields.")
    $result.Data['SeedAuthDiagnostic'] = $diagnostic
    return $result
}

function Assert-SeedAdminScopeSet {
    param($Context, [string[]]$Expected, [string]$Mode)
    $missing = @($Expected | Where-Object { $_ -cnotin $Context.Scopes })
    if ($missing.Count -gt 0) {
        throw (New-SeedAdminAuthFailure -Code 'Seed.Auth.Scope' -Stage ScopeValidation -MissingScopes $missing)
    }
}

function Connect-AdminSession {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Mode, [scriptblock]$SdkConnect, [scriptblock]$SdkContext, [scriptblock]$SdkRequest,
        [scriptblock]$TokenProvider, [scriptblock]$Transport, [scriptblock]$Delay = { param($Seconds) Start-Sleep -Seconds $Seconds }, [scriptblock]$Send)
    if ($null -ne $SdkConnect -or $null -ne $SdkContext -or $null -ne $SdkRequest) { throw 'Seed.Injection: Delegated SDK callbacks are retired; use the application connector.' }
    if ($Mode -notin @('InspectUsers','InitializePersonas')) { throw 'Seed.Mode: Explicit management mode required.' }
    Connect-SeedSession -Config $Config -Mode $Mode -TokenProvider $TokenProvider -Transport $Transport -Delay $Delay -Send $Send
}
