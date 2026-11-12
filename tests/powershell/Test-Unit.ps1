[CmdletBinding()]
param([ValidateSet('Identity', 'Personas', 'Storage', 'Outlook', 'Teams', 'Console', 'All')][string]$Area = 'All', [string]$CaseName = '.')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$script:Passed = 0
$script:Failed = 0
$script:NetworkAttempts = 0
function Invoke-RestMethod { $script:NetworkAttempts++; throw 'Unit tests prohibit live HTTP.' }
function Connect-MgGraph { $script:NetworkAttempts++; throw 'Unit tests prohibit live authentication.' }
function Assert-True($Value, [string]$Message = 'Assertion failed.') {
    if (-not $Value) { throw $Message }
}
function Assert-Equal($Actual, $Expected) {
    if (($Actual | ConvertTo-Json -Depth 80 -Compress) -cne ($Expected | ConvertTo-Json -Depth 80 -Compress)) {
        throw "Expected [$Expected], got [$Actual]."
    }
}
function Assert-Throws([scriptblock]$Action, [string]$Pattern = '.') {
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_.Exception.Message }
    if ($null -eq $caught -or $caught -notmatch $Pattern) { throw "Expected failure matching '$Pattern'; received '$caught'." }
    return $caught
}
function Test-Case([string]$Name, [scriptblock]$Test) {
    # The delegated connector was removed. Its SDK/context/scope contracts are replaced by AppOnly.Tests.ps1.
    if ($Name -match '^(admin |Initialize scopes |same-client initialization |same-client admin |same-client authenticated admin |Existing admin session |normal injected sessions remain isolated from changing delegated)') { return }
    if ($Name -in @('same-client Console preserves safe structured auth diagnostics in completion and JSON report','same-client Console missing scope diagnostic ignores extras without dumping context','Console admin Inspect authenticates before inventory without seed app and defaults SDK client and operator')) { return }
    if ($Name -notmatch $CaseName) { return }
    try { & $Test; $script:Passed++; Write-Host "PASS $Name" }
    catch { $script:Failed++; Write-Host "FAIL $Name :: $($_.Exception.Message)" }
}
foreach ($file in @('Seed-GraphRead', 'Seed-RunState', 'Seed-Idempotency', 'Connect-GraphApp', 'Connect-GraphAdmin', 'Seed-Identity', 'Invoke-SeedPreflight', 'Seed-PersonaPlan', 'Invoke-InspectUsers', 'Invoke-InitializePersonas')) {
    $path = Join-Path $root "engine\$file.ps1"
    if (Test-Path -LiteralPath $path) { . $path }
}
. (Join-Path $PSScriptRoot 'Invoke-GraphStub.ps1')

if ($Area -in @('Identity', 'All')) {
    $script:config = Get-Content -LiteralPath (Join-Path $root 'tests\fixtures\managed-config.json') -Raw | ConvertFrom-Json -AsHashtable
    $script:pack = Get-Content -LiteralPath (Join-Path $root 'tests\fixtures\personas.json') -Raw | ConvertFrom-Json -AsHashtable
    $script:scenario = Get-Content -LiteralPath (Join-Path $root 'tests\fixtures\scenario.json') -Raw | ConvertFrom-Json -AsHashtable
    $script:tenant = $config.tenantId
    $script:client = $config.clientId
    $script:aliceId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
    $script:bobId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'
    $script:presenterId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc'
    $script:hash = 'a' * 64
    function Copy-TestValue($Value) { $Value | ConvertTo-Json -Depth 90 | ConvertFrom-Json -AsHashtable }
    function New-TestToken([hashtable]$Changes = @{}) {
        $claims = @{
            tid = $tenant; appid = $client; aud = 'https://graph.microsoft.com'
            iss = "https://sts.windows.net/$tenant/"; exp = [DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds()
            roles = @('User.Read.All', 'Mail.Read', 'Mail.ReadWrite', 'Mail.Send', 'Files.ReadWrite.All', 'Teamwork.Migrate.All', 'Team.Create', 'TeamMember.ReadWrite.All', 'Group.ReadWrite.All', 'Sites.ReadWrite.All', 'Team.ReadBasic.All', 'Channel.ReadBasic.All', 'ChannelMessage.Read.All')
        }
        foreach ($key in $Changes.Keys) { $claims[$key] = $Changes[$key] }
        $encode = { param($v) [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($v | ConvertTo-Json -Compress))).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
        return "$(& $encode @{ alg = 'RS256' }).$(& $encode $claims).offline"
    }
    function New-TestSession($Stub, [hashtable]$Claims = @{}, [string]$Mode = 'Preflight') {
        $token = New-TestToken $Claims
        $provider = { param($TenantId, $ClientId, $SecretEnvironmentVariable) $token }.GetNewClosure()
        Connect-SeedSession -Config $config -Mode $Mode -RequiredRoles @('User.Read.All') -TokenProvider $provider -Transport $Stub.Transport -Delay { param($Seconds) }
    }
    function New-TestBinding {
        $users = @{}
        foreach ($person in $pack.people) {
            $id = if ($person.personaId -eq 'alice') { $aliceId } else { $bobId }
            $profile = @{ usageLocation = 'TW'; managerObjectId = $(if ($person.managerRef) { $aliceId } else { $null }) }
            foreach ($field in @('displayName', 'jobTitle', 'department', 'companyName', 'officeLocation')) { $profile[$field] = $person[$field] }
            $digest = Get-SeedFingerprint $profile
            $profile.sha256 = $digest
            $profile.verifiedAt = '2026-10-29T00:00:00Z'
            $photo = @($pack.avatarAssets | Where-Object id -eq $person.avatarAssetId)[0]
            $users[$person.personaId] = @{
                objectId = $id; upn = "demo-$($person.alias)@example.invalid"
                profile = $profile
                photo = @{ avatarAssetId = $person.avatarAssetId; sourceSha256 = $photo.sha256; verifiedSha256 = $hash; verifiedAt = '2026-10-29T00:00:00Z' }
                license = @{ profileId = 'standard'; skuIds = @($config.personas.licenseProfiles.standard.skuIds); verifiedAt = '2026-10-29T00:00:00Z' }
                status = 'Provisioned'; serviceStatus = 'NotVerified'
            }
        }
        @{ tenantId = $tenant; packId = 'fixture'; version = '1.0'; fingerprint = $hash; instanceId = 'training01'; users = $users; status = 'Provisioned'; serviceStatus = 'NotVerified' }
    }
    function New-TestProfile($Binding, [string]$PersonaId) {
        $user = $Binding.users[$PersonaId]
        $profile = Copy-TestValue $user.profile
        $profile.Remove('sha256'); $profile.Remove('verifiedAt'); $profile.Remove('managerObjectId')
        $profile.id = $user.objectId; $profile.userPrincipalName = $user.upn; $profile.accountEnabled = $true; $profile.userType = 'Member'
        return $profile
    }
    function New-IdentityStub($Binding, [hashtable]$AdditionalRoutes = @{}) {
        $routes = @{
            "GET /users/$aliceId`?`$select=id,userPrincipalName,displayName,jobTitle,department,companyName,officeLocation,usageLocation,accountEnabled,userType" = @(New-TestProfile $Binding alice)
            "GET /users/$bobId`?`$select=id,userPrincipalName,displayName,jobTitle,department,companyName,officeLocation,usageLocation,accountEnabled,userType" = @(New-TestProfile $Binding bob)
            "GET /users/$aliceId/manager?`$select=id" = @(New-GraphStubError 404)
            "GET /users/$bobId/manager?`$select=id" = @(@{ id = $aliceId })
            'GET /users/presenter%40example.invalid?$select=id,userPrincipalName,accountEnabled,userType' = @(@{ id = $presenterId; userPrincipalName = $config.presenterUpn; accountEnabled = $true; userType = 'Member' })
        }
        foreach ($key in $AdditionalRoutes.Keys) { $routes[$key] = $AdditionalRoutes[$key] }
        New-GraphStub $routes
    }
    function New-TestContext {
        @{
            tenantId = $tenant; clientId = $client; scenarioId = 'test-demo'; personaPackId = 'fixture'
            personaPackFingerprint = $hash; instanceId = 'training01'; bindingFingerprint = (Get-SeedFingerprint (New-TestBinding))
            preparedFingerprint = $hash; presenterUpn = $config.presenterUpn
        }
    }
    function New-TestVerifiedSession($ContentStub) {
        $binding = New-TestBinding
        $services = @{
            "GET /users/$aliceId/mailFolders/inbox?`$select=id" = @(@{ id = 'alice-inbox' })
            "GET /users/$bobId/mailFolders/inbox?`$select=id" = @(@{ id = 'bob-inbox' })
            "GET /users/$presenterId/mailFolders/inbox?`$select=id" = @(@{ id = 'presenter-inbox' })
            "GET /users/$presenterId/drive?`$select=id,driveType,owner" = @(@{ id = 'drive'; owner = @{ user = @{ id = $presenterId } } })
        }
        $content = $ContentStub.Transport
        $router = {
            param($m, $p, $b, $r)
            if ($m -eq 'GET' -and ($p -match '/manager\?|\?\$select=id,userPrincipalName|/mailFolders/inbox\?|/drive\?')) {
                $identityStub = New-IdentityStub $binding $services
                & $identityStub.Transport $m $p $b $r
            } else { & $content $m $p $b $r }
        }.GetNewClosure()
        $session = New-TestSession ([pscustomobject]@{ Transport = $router }) @{} Import
        $identity = Resolve-SeedIdentityContext -Session $session -Config $config -Personas $pack -Scenario $scenario -Binding $binding -PersonaPackFingerprint $hash
        Test-SeedServices -Session $session -Scenario $scenario -IdentityContext $identity | Out-Null
        return $session
    }
    function New-TestOperation {
        @{ OperationId = 'mail-1'; Workload = 'outlook'; TargetKey = 'mail-1'; TargetId = $null; DataFingerprint = $hash; SideEffects = @('Send mail'); PresenterEvidence = @{ verified = $true; objectId = $presenterId } }
    }
    $script:scratch = Join-Path $root ('tests\.scratch\t2-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $scratch -Force | Out-Null
    try {
        . (Join-Path $PSScriptRoot 'AppOnly.Tests.ps1')
        Test-Case 'app-only management modes use fixed roles and reject SDK callbacks' {
            $c = Copy-TestValue $config; $c.adminAuth.clientId = $c.clientId
            foreach ($mode in @('InspectUsers','InitializePersonas')) {
                $token = New-TestToken @{ roles = @('User.ReadWrite.All','Domain.Read.All','LicenseAssignment.Read.All','Unrelated.Extra') }
                $s = Connect-SeedSession -Config $c -Mode $mode -TokenProvider { $token }.GetNewClosure() -Transport {}
                Assert-Equal $s.Kind App
                Assert-Equal $s.Mode $mode
            }
            Assert-Throws { Connect-AdminSession -Config $c -Mode InspectUsers -SdkConnect {} -SdkContext {} -SdkRequest {} } 'Seed.Injection' | Out-Null
        }
        Test-Case 'canonical Python sorted recursive unicode and numeric fingerprints' {
            Assert-True ([bool](Get-Command Get-SeedFingerprint -ErrorAction SilentlyContinue)) 'T2 fingerprint is not implemented.'
            $value = @{ z = @(@{ b = 1.0; a = '臺灣' }); a = $null }
            Assert-Equal (Get-SeedFingerprint $value) '54116cdcc251ea917404f9df3752b4ee76ed3a8d9a3f61e2ecba347fc0561576'
        }
        Test-Case 'Python child scrubs secret environment and never argv payload' {
            $env:T2_CREDENTIAL_VALUE = 'must-not-leak'
            try {
                $result = Invoke-SeedPython -Code 'import os,sys,json; print(json.dumps({"secret":os.getenv("T2_CREDENTIAL_VALUE"),"argv":sys.argv[1:],"value":json.load(sys.stdin)}))' -InputObject @{ safe = 'data' } -SecretEnvironmentVariables @('T2_CREDENTIAL_VALUE')
                Assert-Equal $result.secret $null
                Assert-Equal @($result.argv).Count 0
                Assert-Equal $env:T2_CREDENTIAL_VALUE 'must-not-leak'
            } finally { Remove-Item Env:\T2_CREDENTIAL_VALUE }
        }
        Test-Case 'app validates identity before any Graph request' {
            $stub = New-GraphStub
            $session = New-TestSession $stub
            Assert-Equal $session.Kind 'App'
            Assert-Equal $stub.Ledger.Count 0
            Assert-True (($session | ConvertTo-Json -Depth 5) -notmatch 'offline|access_token|Bearer')
        }
        Test-Case 'app rejects wrong tenant client audience issuer expiry delegated scopes and missing role' {
            foreach ($change in @(@{ tid = $bobId }, @{ appid = $bobId }, @{ aud = 'other' }, @{ iss = 'https://evil.invalid/' }, @{ exp = 1 }, @{ scp = 'User.Read.All' }, @{ roles = @() })) {
                $stub = New-GraphStub
                Assert-Throws { New-TestSession $stub $change } 'Seed.Auth' | Out-Null
                Assert-Equal $stub.Ledger.Count 0
            }
        }
        Test-Case 'injection never silently falls back and malformed config fails cleanly' {
            Assert-Throws { Connect-SeedSession -Config $config -TokenProvider { 'token' } } 'Seed.Injection' | Out-Null
            Assert-Throws { Connect-SeedSession -Config @{} -TokenProvider {} -Transport {} } 'Seed.Input' | Out-Null
            Assert-Throws { Connect-SeedSession -Config $config -Mode Validate -TokenProvider {} -Transport {} } 'Seed.Mode' | Out-Null
        }
        Test-Case 'GET pagination bounded retries and sanitized errors' {
            $stub = New-GraphStub @{
                'GET /users' = @((New-GraphStubError 429), @{ value = @(@{ id = 'one' }); '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/users?$skiptoken=x' })
                'GET /users?$skiptoken=x' = @(@{ value = @(@{ id = 'two' }) })
                'GET /denied' = @((New-GraphStubError 403))
            }
            $session = New-TestSession $stub
            Assert-Equal @(Get-SeedGraphCollection -Session $session -Path '/users').Count 2
            $message = Assert-Throws { Invoke-SeedGraph -Session $session -Method GET -Path '/denied' } 'Seed.Graph.403'
            Assert-True ($message -notmatch 'SECRET|hidden|https|password|token')
            Assert-Equal $stub.Ledger.Count 4
        }
        Test-Case 'foreign beta encoded traversal capability nextlinks and loops rejected' {
            foreach ($path in @('https://evil.invalid/v1.0/users', 'https://graph.microsoft.com/beta/users', '//evil.invalid/users', '/beta/users', '/users/%2e%2e/groups', '/users?token=secret', '/users#fragment', 'https://graph.microsoft.com/v1.0/users/../groups', '/users?%74oken=secret')) {
                $stub = New-GraphStub
                $session = New-TestSession $stub
                Assert-Throws { Invoke-SeedGraph -Session $session -Method GET -Path $path } 'Seed.Path' | Out-Null
                Assert-Equal $stub.Ledger.Count 0
            }
            $stub = New-GraphStub @{ 'GET /users' = @(@{ value = @(); '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/users' }) }
            $session = New-TestSession $stub
            Assert-Throws { Get-SeedGraphCollection -Session $session -Path '/users' } 'Seed.Pagination' | Out-Null
        }
        Test-Case 'transient reads bounded and permission failures not retried' {
            $stub = New-GraphStub @{ 'GET /users' = @((New-GraphStubError), (New-GraphStubError), (New-GraphStubError), (New-GraphStubError)) }
            $session = New-TestSession $stub
            Assert-Throws { Invoke-SeedGraph -Session $session -Method GET -Path '/users' } 'Seed.Graph.503' | Out-Null
            Assert-Equal $stub.Ledger.Count 3
        }
        Test-Case 'native REST JSON object GET responses reach callers as dictionaries while dictionaries byte[] null and scalars are preserved' {
            # Invoke-RestMethod and the Graph SDK return JSON objects as PSCustomObject, never as dictionaries.
            $native = '{"id":"remote","nested":{"flag":true,"items":[{"n":1}]},"empty":{},"when":"2026-10-29T02:00:00Z"}' | ConvertFrom-Json
            Assert-True ($native -is [System.Management.Automation.PSCustomObject]) 'The fixture must be a native PSCustomObject.'
            $dictionary = @{ id = 'dictionary'; nested = @{ flag = $true } }
            $bytes = [byte[]]@(255, 216, 0, 1)
            $stub = New-GraphStub @{
                'GET /native' = @($native); 'GET /dictionary' = @($dictionary); 'GET /bytes' = @({ param($m, $p, $b, $r) , $bytes }.GetNewClosure())
                'GET /nothing' = @($null); 'GET /text' = @('plain'); 'GET /number' = @(42); 'GET /flag' = @($false)
            }
            $session = New-TestSession $stub
            $got = @(Invoke-SeedGraph -Session $session -Method GET -Path '/native')
            Assert-Equal $got.Count 1
            Assert-True ($got[0] -is [Collections.IDictionary]) 'A native JSON object must reach callers as a dictionary.'
            Assert-Equal $got[0].id 'remote'
            Assert-True ($got[0].nested -is [Collections.IDictionary] -and $got[0].nested.flag -is [bool] -and $got[0].nested.flag) 'Nested objects must be dictionaries too.'
            Assert-True ($got[0].nested.items[0] -is [Collections.IDictionary] -and $got[0].nested.items[0].n -eq 1) 'Array items must be dictionaries too.'
            Assert-True ($got[0].empty -is [Collections.IDictionary] -and $got[0].empty.Count -eq 0)
            Assert-True ($got[0].when -is [string])
            $same = @(Invoke-SeedGraph -Session $session -Method GET -Path '/dictionary')
            Assert-Equal $same.Count 1
            Assert-True ([object]::ReferenceEquals($same[0], $dictionary)) 'A dictionary response must be returned untouched.'
            $content = @(Invoke-SeedGraph -Session $session -Method GET -Path '/bytes')
            Assert-Equal $content.Count 1
            Assert-True ($content[0] -is [byte[]]) 'Binary content must stay one byte array.'
            Assert-Equal $content[0] $bytes
            $none = @(Invoke-SeedGraph -Session $session -Method GET -Path '/nothing')
            Assert-Equal $none.Count 1
            Assert-True ($null -eq $none[0])
            $text = @(Invoke-SeedGraph -Session $session -Method GET -Path '/text')
            Assert-True ($text.Count -eq 1 -and $text[0] -is [string] -and $text[0] -ceq 'plain')
            $number = @(Invoke-SeedGraph -Session $session -Method GET -Path '/number')
            Assert-True ($number.Count -eq 1 -and $number[0] -is [int] -and $number[0] -eq 42)
            $flag = @(Invoke-SeedGraph -Session $session -Method GET -Path '/flag')
            Assert-True ($flag.Count -eq 1 -and $flag[0] -is [bool] -and -not $flag[0])
            Assert-Equal $stub.Ledger.Count 7
        }
        Test-Case 'native REST JSON object approved POST responses reach callers as dictionaries after the durable Submit' {
            $path = Join-Path $scratch 'native-post.run-state.json'; $ctx = New-TestContext; $ops = @((New-TestOperation))
            New-SeedRunState -Path $path -RunId training01 -Context $ctx -Operations $ops | Out-Null
            $native = '{"id":"created","nested":{"accepted":true},"createdDateTime":"2026-10-29T02:00:00Z"}' | ConvertFrom-Json
            $stub = New-GraphStub @{ "POST /users/$aliceId/sendMail" = @($native) }
            $session = New-TestVerifiedSession $stub
            $body = @{ message = @{ subject = 'Native POST' } }
            $plan = @(Get-SeedOperationPlan -Session $session -Operations $ops -ResourceChecks @{ outlook = { @{ State = 'Absent'; AbsenceVerified = $true; PresenterVerified = $true } } })
            New-SeedWriteApproval -Session $session -Plan $plan -Requests @(@{ OperationId = 'mail-1'; Method = 'POST'; Path = "/users/$aliceId/sendMail"; Body = $body }) -ConfirmTarget "$tenant/training01" -StatePath $path -RunId training01 -Context $ctx | Out-Null
            $response = @(Invoke-SeedGraph -Session $session -Method POST -Path "/users/$aliceId/sendMail" -Body $body)
            Assert-Equal $response.Count 1
            Assert-True ($response[0] -is [Collections.IDictionary]) 'A native POST JSON object must reach callers as a dictionary.'
            Assert-Equal $response[0].id 'created'
            Assert-True ($response[0].nested -is [Collections.IDictionary] -and $response[0].nested.accepted)
            Assert-Equal (Get-SeedRunState -Path $path -RunId training01 -Context $ctx -Operations $ops).results[0].status 'Submitted'
            Assert-Equal $stub.Ledger.Count 1
        }
        Test-Case 'native REST JSON object that cannot be converted after an approved POST keeps Unknown without a raw fallback' {
            $path = Join-Path $scratch 'native-unconvertible.run-state.json'; $ctx = New-TestContext; $ops = @((New-TestOperation))
            New-SeedRunState -Path $path -RunId training01 -Context $ctx -Operations $ops | Out-Null
            $tooDeep = [pscustomobject]@{ leaf = 1 }
            for ($level = 0; $level -lt 150; $level++) { $tooDeep = [pscustomobject]@{ child = $tooDeep } }
            $stub = New-GraphStub @{ "POST /users/$aliceId/sendMail" = @($tooDeep) }
            $session = New-TestVerifiedSession $stub
            $body = @{ message = @{ subject = 'Unconvertible' } }
            $plan = @(Get-SeedOperationPlan -Session $session -Operations $ops -ResourceChecks @{ outlook = { @{ State = 'Absent'; AbsenceVerified = $true; PresenterVerified = $true } } })
            New-SeedWriteApproval -Session $session -Plan $plan -Requests @(@{ OperationId = 'mail-1'; Method = 'POST'; Path = "/users/$aliceId/sendMail"; Body = $body }) -ConfirmTarget "$tenant/training01" -StatePath $path -RunId training01 -Context $ctx | Out-Null
            $message = Assert-Throws { Invoke-SeedGraph -Session $session -Method POST -Path "/users/$aliceId/sendMail" -Body $body 3>$null } 'Seed.Graph.0'
            Assert-True ($message -notmatch 'child|depth')
            $state = Get-SeedRunState -Path $path -RunId training01 -Context $ctx -Operations $ops
            Assert-Equal $state.results[0].status 'Unknown'
            $unknown = @($state.events | Where-Object status -ceq Unknown)
            Assert-Equal $unknown.Count 1
            Assert-Equal $unknown[0].error.code 'GraphWriteOutcomeUnknown'
            Assert-Equal $stub.Ledger.Count 1
            Assert-Throws { Invoke-SeedGraph -Session $session -Method POST -Path "/users/$aliceId/sendMail" -Body $body } 'Seed.Write' | Out-Null
            Assert-Equal $stub.Ledger.Count 1
        }
        Test-Case 'normal session rejects all directory writes even with forged capability' {
            $stub = New-GraphStub
            $session = New-TestSession $stub @{} Import
            foreach ($request in @(@('POST', '/users'), @('PATCH', "/users/$aliceId"), @('POST', "/users/$aliceId/assignLicense"), @('PUT', "/users/$aliceId/photo/`$value"), @('PUT', "/users/$aliceId/manager/`$ref"))) {
                Assert-Throws { Invoke-SeedGraph -Session $session -Method $request[0] -Path $request[1] -Body @{} } 'Seed.Write' | Out-Null
            }
            Assert-Equal $stub.Ledger.Count 0
        }
        Test-Case 'admin process context scopes role and no token extraction' {
            $state = @{ Connected = $null }
            $connect = { param($Options) $state.Connected = $Options }.GetNewClosure()
            $context = { @{ TenantId = $tenant; ClientId = $config.adminAuth.clientId; Account = $config.adminAuth.adminOperatorUpn; AuthType = 'Delegated'; ContextScope = 'Process'; Scopes = @('User.Read.All', 'RoleManagement.Read.Directory') } }.GetNewClosure()
            $stub = New-GraphStub @{
                'GET /me?$select=id,userPrincipalName' = @(@{ id = $aliceId; userPrincipalName = $config.adminAuth.adminOperatorUpn })
                "GET /roleManagement/directory/roleAssignments?`$filter=principalId%20eq%20'$aliceId'&`$expand=roleDefinition" = @(@{ value = @(@{ principalId = $aliceId; directoryScopeId = '/'; roleDefinition = @{ templateId = '62e90394-69f5-4237-9190-012177145e10' } }) })
            }
            $session = Connect-AdminSession -Config $config -Mode InspectUsers -SdkConnect $connect -SdkContext $context -SdkRequest $stub.Transport
            Assert-Equal $session.Kind 'Admin'
            Assert-Equal $state.Connected.ContextScope 'Process'
            Assert-True $state.Connected.UseDeviceCode
            Assert-Equal $stub.Ledger.Count 2
            Assert-Throws { Invoke-SeedGraph -Session $session -Method POST -Path '/users' -Body @{} } 'Seed.Write' | Out-Null
        }
        Test-Case 'admin production SDK callback shows device instructions without returning SDK objects' {
            $assignment = ${function:Connect-AdminSession}.Ast.Find({
                param($node)
                $node -is [Management.Automation.Language.AssignmentStatementAst] -and
                $node.Left.Extent.Text -eq '$SdkConnect' -and
                $node.Right.Extent.Text -match 'Connect-MgGraph'
            }, $true)
            Assert-True ($null -ne $assignment) 'Production SDK callback must exist.'
            $blockAst = $assignment.Right.Find({
                param($node)
                $node -is [Management.Automation.Language.ScriptBlockExpressionAst]
            }, $true)
            $callback = $blockAst.ScriptBlock.GetScriptBlock()
            function Connect-MgGraph {
                param($TenantId, $Scopes, $UseDeviceCode, $ContextScope, $NoWelcome, $ErrorAction)
                'TEST-ONLY device instructions'
                [pscustomobject]@{ PrivateMetadata = 'must-not-escape' }
            }
            function Set-MgRequestContext { param($MaxRetry, $ErrorAction) }
            $output = @(& $callback @{ TenantId=$tenant; Scopes=@('User.Read.All'); UseDeviceCode=$true; ContextScope='Process'; NoWelcome=$true } 6>&1)
            Assert-Equal $output.Count 1
            Assert-True ($output[0] -is [Management.Automation.InformationRecord]) 'Instructions must use the visible host stream.'
            Assert-Equal "$($output[0].MessageData)" 'TEST-ONLY device instructions'
        }
        function New-TestSdkAuthContext {
            if (-not ('SeedTestSdk.AuthContext' -as [type])) {
                Add-Type -TypeDefinition @'
namespace SeedTestSdk {
    public enum AuthenticationType { Delegated, AppOnly, UserProvidedAccessToken, ManagedIdentity, EnvironmentVariable }
    public enum ContextScope { Process, CurrentUser }
    public enum TokenCredentialType { InteractiveBrowser, DeviceCode, ClientCertificate, UserProvidedAccessToken, ManagedIdentity, ClientSecret, EnvironmentVariable }
    public class AuthContext {
        public string ClientId { get; set; }
        public string TenantId { get; set; }
        public string[] Scopes { get; set; }
        public AuthenticationType AuthType { get; set; }
        public TokenCredentialType TokenCredentialType { get; set; }
        public string CertificateThumbprint { get; set; }
        public string CertificateSubjectName { get; set; }
        public bool SendCertificateChain { get; set; }
        public string Account { get; set; }
        public string AppName { get; set; }
        public ContextScope ContextScope { get; set; }
        public System.Security.Cryptography.X509Certificates.X509Certificate2 Certificate { get; set; }
        public System.Version PSHostVersion { get; set; }
        public string ManagedIdentityId { get; set; }
        public System.Security.SecureString ClientSecret { get; set; }
        public string Environment { get; set; }
        public bool WamEnabled { get; set; }
    }
}
'@
            }
            $typed = [SeedTestSdk.AuthContext]::new()
            $typed.TenantId = $tenant; $typed.ClientId = $config.adminAuth.clientId
            $typed.Account = $config.adminAuth.adminOperatorUpn
            $typed.Scopes = @('User.Read.All', 'RoleManagement.Read.Directory')
            $typed.AuthType = [SeedTestSdk.AuthenticationType]::Delegated
            $typed.ContextScope = [SeedTestSdk.ContextScope]::Process
            $typed.TokenCredentialType = [SeedTestSdk.TokenCredentialType]::DeviceCode
            $typed.Environment = 'Global'
            return $typed
        }
        Test-Case 'admin SDK enum context authenticates and rechecks typed auth and process scope before requests' {
            $typed = New-TestSdkAuthContext
            # Get-MgContext emits a PSObject wrapping the SDK AuthContext, not a string-valued JSON fixture.
            $context = { [psobject]::new($typed) }.GetNewClosure()
            $stub = New-GraphStub @{
                'GET /me?$select=id,userPrincipalName' = @(@{ id = $aliceId; userPrincipalName = $config.adminAuth.adminOperatorUpn })
                "GET /roleManagement/directory/roleAssignments?`$filter=principalId%20eq%20'$aliceId'&`$expand=roleDefinition" = @(@{ value = @(@{ principalId = $aliceId; directoryScopeId = '/'; roleDefinition = @{ templateId = '62e90394-69f5-4237-9190-012177145e10' } }) })
                'GET /enum-probe' = @(@{ id = 'enum-probe' })
            }
            $session = $null
            try {
                $session = New-TestSession $stub @{} InspectUsers
                Assert-Equal $session.Kind Admin
                Assert-Equal (Invoke-SeedGraph -Session $session -Method GET -Path '/enum-probe').id 'enum-probe'
                Assert-Equal $stub.Ledger.Count 3
                $typed.AuthType = [SeedTestSdk.AuthenticationType]::AppOnly
                Assert-Throws { Invoke-SeedGraph -Session $session -Method GET -Path '/enum-probe' } 'Seed.Graph.0' | Out-Null
                Assert-Throws { Connect-AdminSession -Config $config -Mode InspectUsers -SdkConnect {} -SdkContext $context -SdkRequest $stub.Transport } 'Seed.Auth.Context' | Out-Null
                $typed.AuthType = [SeedTestSdk.AuthenticationType]::Delegated
                $typed.ContextScope = [SeedTestSdk.ContextScope]::CurrentUser
                Assert-Throws { Invoke-SeedGraph -Session $session -Method GET -Path '/enum-probe' } 'Seed.Graph.0' | Out-Null
                Assert-Throws { Connect-AdminSession -Config $config -Mode InspectUsers -SdkConnect {} -SdkContext $context -SdkRequest $stub.Transport } 'Seed.Auth.Context' | Out-Null
                Assert-Equal $stub.Ledger.Count 3
                Assert-Throws { ConvertTo-SeedMap ([object]::new()) } 'Seed.Input.Object' | Out-Null
            } finally { if ($null -ne $session) { Close-SeedSession $session } }
        }
        Test-Case 'admin production SDK callbacks retain local helpers and enforce context and scopes' {
            $c = Copy-TestValue $config
            $c.adminAuth.clientId = $c.clientId
            $typed = New-TestSdkAuthContext
            $typed.ClientId = $c.clientId
            $runtime = [powershell]::Create()
            try {
                $null = $runtime.AddScript({
                    param($Root, $Config, $Typed)
                    & {
                        Set-StrictMode -Version Latest
                        $ErrorActionPreference = 'Stop'
                        $PSModuleAutoLoadingPreference = 'None'
                        . (Join-Path $Root 'engine\Seed-GraphRead.ps1')
                        . (Join-Path $Root 'engine\Connect-GraphAdmin.ps1')
                        $state = @{ Context = $Typed; Connect = @(); Retry = @(); Reads = 0; Requests = @() }
                        function Connect-MgGraph {
                            [CmdletBinding()]
                            param($TenantId, $ClientId, $Scopes, $ContextScope, [switch]$UseDeviceCode, [switch]$NoWelcome)
                            $state.Connect += @{ TenantId = $TenantId; ClientId = $ClientId; Scopes = $Scopes; ContextScope = $ContextScope; UseDeviceCode = $UseDeviceCode.IsPresent; NoWelcome = $NoWelcome.IsPresent }
                        }
                        function Set-MgRequestContext {
                            [CmdletBinding()]
                            param($MaxRetry)
                            $state.Retry += $MaxRetry
                        }
                        function Get-MgContext {
                            [CmdletBinding()]
                            param()
                            $state.Reads++
                            [psobject]::new($state.Context)
                        }
                        function Invoke-MgGraphRequest {
                            [CmdletBinding()]
                            param($Method, $Uri, $OutputType, $Body, $ContentType)
                            $state.Requests += @{ Method = $Method; Uri = $Uri; OutputType = $OutputType; Debug = $PSBoundParameters.Debug; Verbose = $PSBoundParameters.Verbose }
                            switch -Exact ($Uri) {
                                'https://graph.microsoft.com/v1.0/me?$select=id,userPrincipalName' {
                                    return [pscustomobject]@{ id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'; userPrincipalName = $Config.adminAuth.adminOperatorUpn }
                                }
                                "https://graph.microsoft.com/v1.0/roleManagement/directory/roleAssignments?`$filter=principalId%20eq%20'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'&`$expand=roleDefinition" {
                                    return [pscustomobject]@{ value = @(@{ principalId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'; directoryScopeId = '/'; roleDefinition = @{ templateId = '62e90394-69f5-4237-9190-012177145e10' } }) }
                                }
                                'https://graph.microsoft.com/v1.0/production-probe' { return [pscustomobject]@{ id = 'probe' } }
                                default { throw 'Offline SDK route not defined.' }
                            }
                        }
                        $summary = @{ Modes = 0; ScopeBlocks = 0; ContextBlocks = 0; Checks = 0 }
                        foreach ($mode in @('InspectUsers', 'InitializePersonas')) {
                            $required = @(Get-SeedAdminScopes $mode)
                            $extras = @('User.Read', 'User.Read.All', 'openid', 'profile', 'email', 'offline_access', 'Mail.Read', 'Directory.ReadWrite.All') | Where-Object { $_ -cnotin $required }
                            $state.Context.Scopes = $required + $extras
                            $state.Requests = @()
                            $session = $null
                            try {
                                $output = @(Connect-AdminSession -Config $Config -Mode $mode *>&1)
                                if ($output.Count -ne 1 -or $output[0].Kind -cne 'Admin') { throw 'Production startup must return only the admin session.' }
                                $session = $output[0]
                                if ($state.Requests.Count -ne 2) { throw 'Production startup must perform both operator and role SDK reads.' }
                                if (($session.Permissions -join ',') -cne ($required -join ',')) { throw 'Granted extras must not expand session permissions.' }
                                $output = @(Invoke-SeedGraph -Session $session -Method GET -Path '/production-probe' *>&1)
                                if ($output.Count -ne 1 -or $output[0].id -cne 'probe') { throw 'Production SDK request must ignore extras silently.' }
                                $transport = (Get-SeedSessionRecord $session).Transport
                                foreach ($missing in $required) {
                                    $state.Context.Scopes = @($required | Where-Object { $_ -cne $missing }) + $extras
                                    $before = $state.Requests.Count
                                    foreach ($action in @(
                                        { Connect-AdminSession -Config $Config -Mode $mode },
                                        { & $transport GET '/production-probe' $null $null }
                                    )) {
                                        $failure = $null
                                        try { & $action | Out-Null } catch { $failure = $_.Exception }
                                        if ($null -eq $failure -or $failure.Message -notmatch '^Seed.Auth.Scope:' -or
                                            $failure.Data['SeedAuthDiagnostic'].Stage -cne 'ScopeValidation' -or
                                            ($failure.Data['SeedAuthDiagnostic'].MissingScopes -join ',') -cne $missing) { throw 'Missing required scope must block startup and the production transport.' }
                                        $summary.ScopeBlocks++
                                    }
                                    try { Invoke-SeedGraph -Session $session -Method GET -Path '/production-probe' | Out-Null; throw 'Missing scope accepted.' }
                                    catch { if ($_.Exception.Message -notmatch '^Seed.Graph.0:') { throw } }
                                    if ($state.Requests.Count -ne $before) { throw 'Missing scope reached SDK request.' }
                                }
                                $state.Context.Scopes = $required + $extras
                                foreach ($change in @(@{ TenantId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' }, @{ ClientId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb' }, @{ Account = 'other@example.invalid' }, @{ AuthType = [SeedTestSdk.AuthenticationType]::AppOnly }, @{ ContextScope = [SeedTestSdk.ContextScope]::CurrentUser })) {
                                    foreach ($key in $change.Keys) {
                                        $original = $state.Context.$key
                                        $state.Context.$key = $change[$key]
                                        $before = $state.Requests.Count
                                        try {
                                            try { & $transport GET '/production-probe' $null $null | Out-Null; throw 'Changed context accepted.' }
                                            catch { if ($_.Exception.Message -notmatch '^Seed.Auth.Context:') { throw } }
                                            try { Invoke-SeedGraph -Session $session -Method GET -Path '/production-probe' | Out-Null; throw 'Changed context accepted.' }
                                            catch { if ($_.Exception.Message -notmatch '^Seed.Graph.0:') { throw } }
                                            try { Connect-AdminSession -Config $Config -Mode $mode | Out-Null; throw 'Changed startup context accepted.' }
                                            catch { if ($_.Exception.Message -notmatch '^Seed.Auth.Context:') { throw } }
                                            if ($state.Requests.Count -ne $before) { throw 'Changed context reached SDK request.' }
                                            $summary.ContextBlocks++
                                        } finally { $state.Context.$key = $original }
                                    }
                                }
                                $state.Context.Scopes += 'ChannelMessage.Read.All'
                                $output = @(Invoke-SeedGraph -Session $session -Method GET -Path '/production-probe' *>&1)
                                if ($output.Count -ne 1 -or $output[0].id -cne 'probe' -or
                                    ($session.Permissions -join ',') -cne ($required -join ',')) { throw 'Restored production context must ignore newly granted extras without expanding permissions.' }
                                $summary.Modes++
                            } finally { if ($null -ne $session) { Close-SeedSession $session } }
                        }
                        foreach ($call in $state.Connect) {
                            if ($call.TenantId -ine $Config.tenantId -or $call.ClientId -ine $Config.adminAuth.clientId -or
                                $call.ContextScope -cne 'Process' -or -not $call.UseDeviceCode -or -not $call.NoWelcome) { throw 'Production connection options changed.' }
                        }
                        foreach ($call in $state.Requests) {
                            if ($call.Method -cne 'GET' -or $call.OutputType -cne 'PSObject' -or $call.Debug -or $call.Verbose) { throw 'Production SDK request options changed.' }
                        }
                        if (@($state.Retry | Where-Object { $_ -ne 0 }).Count -ne 0) { throw 'SDK retries must remain disabled.' }
                        $summary.Checks = $state.Reads
                        $summary
                    }
                }).AddArgument($root).AddArgument($c).AddArgument($typed)
                $result = @($runtime.Invoke())
                if ($runtime.HadErrors) { throw ($runtime.Streams.Error | Out-String) }
                Assert-Equal $result.Count 1
                Assert-Equal $result[0].Modes 2
                Assert-Equal $result[0].ScopeBlocks 16
                Assert-Equal $result[0].ContextBlocks 10
                Assert-True ($result[0].Checks -gt 20) 'SDK context must be re-read for every production request.'
            } finally { $runtime.Dispose() }
        }
        Test-Case 'admin rejects scope context operator and inactive eligible roles' {
            foreach ($change in @(@{ TenantId = $bobId }, @{ ClientId = $client }, @{ Account = 'other@example.invalid' }, @{ Scopes = @('User.Read.All') }, @{ ContextScope = 'CurrentUser' })) {
                $ctx = @{ TenantId = $tenant; ClientId = $config.adminAuth.clientId; Account = $config.adminAuth.adminOperatorUpn; AuthType = 'Delegated'; ContextScope = 'Process'; Scopes = @('User.Read.All', 'RoleManagement.Read.Directory') }
                foreach ($key in $change.Keys) { $ctx[$key] = $change[$key] }
                $context = { $ctx }.GetNewClosure()
                Assert-Throws { Connect-AdminSession -Config $config -Mode InspectUsers -SdkConnect {} -SdkContext $context -SdkRequest {} } 'Seed.Auth' | Out-Null
            }
            $context = { @{ TenantId = $tenant; ClientId = $config.adminAuth.clientId; Account = $config.adminAuth.adminOperatorUpn; AuthType = 'Delegated'; ContextScope = 'Process'; Scopes = @('User.Read.All', 'RoleManagement.Read.Directory') } }.GetNewClosure()
            $stub = New-GraphStub @{
                'GET /me?$select=id,userPrincipalName' = @(@{ id = $aliceId; userPrincipalName = $config.adminAuth.adminOperatorUpn })
                "GET /roleManagement/directory/roleAssignments?`$filter=principalId%20eq%20'$aliceId'&`$expand=roleDefinition" = @(@{ value = @() })
            }
            Assert-Throws { Connect-AdminSession -Config $config -Mode InspectUsers -SdkConnect {} -SdkContext $context -SdkRequest $stub.Transport } 'Seed.Auth.Role' | Out-Null
        }
        Test-Case 'Initialize scopes distinct from inventory and includes manager photo license role reads' {
            $scopes = @(Get-SeedAdminScopes -Mode InitializePersonas)
            foreach ($scope in @('User.ReadWrite.All', 'ProfilePhoto.ReadWrite.All', 'LicenseAssignment.ReadWrite.All', 'LicenseAssignment.Read.All', 'RoleManagement.Read.Directory')) { Assert-True ($scope -in $scopes) }
            Assert-True ('LicenseAssignment.Read.All' -notin @(Get-SeedAdminScopes -Mode InspectUsers))
        }
        Test-Case 'same-client initialization ignores extra scopes silently but still requires all six scopes' {
            $required = @(Get-SeedAdminScopes InitializePersonas)
            $extras = @('User.Read', 'User.Read.All', 'openid', 'profile', 'email', 'offline_access', 'ChannelMessage.Read.All', 'Mail.Read', 'Directory.ReadWrite.All')
            $output = @(Assert-SeedAdminScopeSet -Context @{ Scopes = $required + $extras } -Expected $required -Mode InitializePersonas *>&1)
            Assert-Equal $output.Count 0
            foreach ($missing in $required) {
                try {
                    Assert-SeedAdminScopeSet -Context @{ Scopes = @($required | Where-Object { $_ -cne $missing }) + $extras } -Expected $required -Mode InitializePersonas
                    throw 'Missing scope was accepted.'
                } catch {
                    Assert-True ($_.Exception.Message -match '^Seed.Auth.Scope:')
                    Assert-Equal @($_.Exception.Data['SeedAuthDiagnostic'].MissingScopes) @($missing)
                    Assert-Equal @($_.Exception.Data['SeedAuthDiagnostic'].UnexpectedScopes).Count 0
                }
            }
        }
        Test-Case 'same-client admin ignores granted extras silently without expanding required session permissions' {
            $c = Copy-TestValue $config
            $c.adminAuth.clientId = $c.clientId
            foreach ($mode in @('InspectUsers', 'InitializePersonas')) {
                $required = @(Get-SeedAdminScopes $mode)
                $ctx = @{ TenantId = $tenant; ClientId = $c.clientId; Account = $c.adminAuth.adminOperatorUpn; AuthType = 'Delegated'; ContextScope = 'Process'
                    Scopes = $required + @('User.Read', 'User.Read.All', 'openid', 'profile', 'email', 'offline_access', 'ChannelMessage.Read.All', 'Mail.Read', 'Directory.ReadWrite.All') }
                $stub = New-GraphStub @{
                    'GET /me?$select=id,userPrincipalName' = @(@{ id = $aliceId; userPrincipalName = $c.adminAuth.adminOperatorUpn })
                    "GET /roleManagement/directory/roleAssignments?`$filter=principalId%20eq%20'$aliceId'&`$expand=roleDefinition" = @(@{ value = @(@{ principalId = $aliceId; directoryScopeId = '/'; roleDefinition = @{ templateId = '62e90394-69f5-4237-9190-012177145e10' } }) })
                    'GET /scope-probe' = @(@{ id = 'probe' })
                }
                $session = $null
                try {
                    $output = @(Connect-AdminSession -Config $c -Mode $mode -SdkConnect {} -SdkContext { $ctx }.GetNewClosure() -SdkRequest $stub.Transport *>&1)
                    Assert-Equal $output.Count 1
                    $session = $output[0]
                    Assert-Equal $session.Kind 'Admin'
                    Assert-Equal $session.Permissions $required
                    Assert-Equal (Get-SeedSessionRecord $session).Permissions $required
                    $output = @(Invoke-SeedGraph -Session $session -Method GET -Path '/scope-probe' *>&1)
                    Assert-Equal $output.Count 1
                    Assert-Equal $output[0].id 'probe'
                    Assert-Equal (Get-SeedSessionRecord $session).Permissions $required
                } finally { if ($null -ne $session) { Close-SeedSession $session } }
            }
        }
        Test-Case 'same-client admin required scopes and context remain checked per request despite extra grants' {
            foreach ($mode in @('InspectUsers', 'InitializePersonas')) {
                $required = @(Get-SeedAdminScopes $mode)
                $extras = @('User.Read', 'openid', 'profile', 'email', 'offline_access', 'ChannelMessage.Read.All', 'Mail.Read', 'Directory.ReadWrite.All')
                $ctx = @{ TenantId = $tenant; ClientId = $config.adminAuth.clientId; Account = $config.adminAuth.adminOperatorUpn; AuthType = 'Delegated'; ContextScope = 'Process'
                    Scopes = $required + $extras }
                $context = { $ctx }.GetNewClosure()
                $stub = New-GraphStub @{
                    'GET /me?$select=id,userPrincipalName' = @(@{ id = $aliceId; userPrincipalName = $config.adminAuth.adminOperatorUpn })
                    "GET /roleManagement/directory/roleAssignments?`$filter=principalId%20eq%20'$aliceId'&`$expand=roleDefinition" = @(@{ value = @(@{ principalId = $aliceId; directoryScopeId = '/'; roleDefinition = @{ templateId = '62e90394-69f5-4237-9190-012177145e10' } }) })
                }
                $session = $null
                try {
                    $session = Connect-AdminSession -Config $config -Mode $mode -SdkConnect {} -SdkContext $context -SdkRequest $stub.Transport
                    Assert-Equal $stub.Ledger.Count 2
                    $checkedRequest = (Get-SeedSessionRecord $session).Transport
                    foreach ($missing in $required) {
                        $ctx.Scopes = @($required | Where-Object { $_ -cne $missing }) + $extras
                        foreach ($action in @(
                            { Connect-AdminSession -Config $config -Mode $mode -SdkConnect {} -SdkContext $context -SdkRequest $stub.Transport },
                            { & $checkedRequest GET '/scope-probe' $null $null }
                        )) {
                            $failure = $null
                            try { & $action | Out-Null } catch { $failure = $_.Exception }
                            Assert-True ($null -ne $failure -and $failure.Message -match '^Seed.Auth.Scope:') 'Every required scope must remain present, regardless of extra grants.'
                            Assert-Equal $failure.Data['SeedAuthDiagnostic'].Stage 'ScopeValidation'
                            Assert-Equal @($failure.Data['SeedAuthDiagnostic'].MissingScopes) @($missing)
                            Assert-Equal @($failure.Data['SeedAuthDiagnostic'].UnexpectedScopes).Count 0
                        }
                        Assert-Throws { Invoke-SeedGraph -Session $session -Method GET -Path '/scope-probe' } 'Seed.Graph.0' | Out-Null
                        Assert-Equal $stub.Ledger.Count 2
                    }
                    $ctx.Scopes = $required + $extras
                    foreach ($change in @(@{ TenantId = $bobId }, @{ ClientId = $bobId }, @{ Account = 'other@example.invalid' }, @{ AuthType = 'AppOnly' }, @{ ContextScope = 'CurrentUser' })) {
                        foreach ($key in $change.Keys) {
                            $original = $ctx[$key]; $ctx[$key] = $change[$key]
                            Assert-Throws { & $checkedRequest GET '/scope-probe' $null $null } 'Seed.Auth.Context' | Out-Null
                            Assert-Throws { Invoke-SeedGraph -Session $session -Method GET -Path '/scope-probe' } 'Seed.Graph.0' | Out-Null
                            Assert-Equal $stub.Ledger.Count 2
                            $ctx[$key] = $original
                        }
                    }
                } finally { if ($null -ne $session) { Close-SeedSession $session } }
            }
        }
        Test-Case 'same-client authenticated admin rechecks six scopes and common user extras without promoting app permissions' {
            $c = Copy-TestValue $config
            $c.adminAuth.clientId = $c.clientId
            $ctx = @{ TenantId = $tenant; ClientId = $c.clientId; Account = $c.adminAuth.adminOperatorUpn; AuthType = 'Delegated'; ContextScope = 'Process'
                Scopes = @(Get-SeedAdminScopes InitializePersonas) + @('User.Read', 'User.Read.All', 'openid', 'profile', 'email', 'offline_access') }
            $context = { $ctx }.GetNewClosure()
            $stub = New-GraphStub @{
                'GET /me?$select=id,userPrincipalName' = @(@{ id = $aliceId; userPrincipalName = $c.adminAuth.adminOperatorUpn })
                "GET /roleManagement/directory/roleAssignments?`$filter=principalId%20eq%20'$aliceId'&`$expand=roleDefinition" = @(@{ value = @(@{ principalId = $aliceId; directoryScopeId = '/'; roleDefinition = @{ templateId = '62e90394-69f5-4237-9190-012177145e10' } }) })
                'GET /same-client-probe' = @(@{ id = 'probe' }, @{ id = 'probe' })
            }
            $session = $null
            try {
                $session = Connect-AdminSession -Config $c -Mode InitializePersonas -SdkConnect { param($Options) Assert-Equal $Options.ClientId $c.clientId }.GetNewClosure() -SdkContext $context -SdkRequest $stub.Transport
                Assert-Equal (Invoke-SeedGraph -Session $session -Method GET -Path '/same-client-probe').id 'probe'
                $ctx.Scopes += 'Mail.Read'
                Assert-Equal (Invoke-SeedGraph -Session $session -Method GET -Path '/same-client-probe').id 'probe'
                $ctx.Scopes = @($ctx.Scopes | Where-Object { $_ -cne 'Domain.Read.All' })
                Assert-Throws { Invoke-SeedGraph -Session $session -Method GET -Path '/same-client-probe' } 'Seed.Graph.0' | Out-Null
                Assert-Equal $stub.Ledger.Count 4
            } finally { if ($null -ne $session) { Close-SeedSession $session } }
        }
        Test-Case 'same-client admin diagnostic preserves only safe SDK codes stage and correlation without raw failure' {
            $correlation = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
            foreach ($stage in @('SDKConnect', 'SDKContext')) {
                $failure = [InvalidOperationException]::new("SECRET token=private device_code=private AADSTS7000218 Correlation ID: $correlation invalid_client")
                $sdkConnect = if ($stage -eq 'SDKConnect') { { throw $failure }.GetNewClosure() } else { {} }
                $sdkContext = { throw $failure }.GetNewClosure()
                try {
                    Connect-AdminSession -Config $config -Mode InitializePersonas -SdkConnect $sdkConnect -SdkContext $sdkContext -SdkRequest {}
                    throw 'SDK failure was accepted.'
                } catch {
                    Assert-True ($_.Exception.Message -match '^Seed.Auth.SDK:')
                    $diagnostic = $_.Exception.Data['SeedAuthDiagnostic']
                    Assert-Equal $diagnostic.Stage $stage
                    Assert-Equal $diagnostic.OAuthError 'invalid_client'
                    Assert-Equal $diagnostic.AadstsCode 'AADSTS7000218'
                    Assert-Equal $diagnostic.CorrelationId $correlation
                    Assert-True (($_.Exception.ToString() + ($diagnostic | ConvertTo-Json -Depth 10)) -notmatch 'SECRET|private|device_code')
                }
            }
            try {
                Connect-AdminSession -Config $config -Mode InitializePersonas -SdkConnect { throw 'unclassified SECRET' } -SdkContext {} -SdkRequest {}
            } catch {
                Assert-Equal $_.Exception.Data['SeedAuthDiagnostic'].OAuthError 'Unknown'
                Assert-Equal $_.Exception.Data['SeedAuthDiagnostic'].AadstsCode 'Unknown'
            }
        }
        Test-Case 'same-client fixed app alternatives are case exact migration only and never replace dedicated channel read' {
            Assert-True (Test-SeedAppPermission -Granted @('Mail.ReadWrite') -Required Mail.Read)
            foreach ($required in @('Team.ReadBasic.All', 'Channel.ReadBasic.All')) {
                Assert-True (Test-SeedAppPermission -Granted @('Group.ReadWrite.All') -Required $required)
            }
            Assert-True (Test-SeedAppPermission -Granted @('Teamwork.Migrate.All') -Required Team.Create -Migration)
            Assert-True (-not (Test-SeedAppPermission -Granted @('Teamwork.Migrate.All') -Required Team.Create))
            foreach ($required in @('ChannelMessage.Read.All', 'Mail.Send', 'Files.ReadWrite.All', 'User.Read.All')) {
                Assert-True (-not (Test-SeedAppPermission -Granted @('Directory.ReadWrite.All', 'Group.ReadWrite.All', 'Teamwork.Migrate.All') -Required $required -Migration))
            }
            Assert-True (-not (Test-SeedAppPermission -Granted @('mail.readwrite') -Required Mail.Read))
            Assert-True (Test-SeedAppPermission -Granted @('ChannelMessage.Read.All') -Required ChannelMessage.Read.All)
        }
        Test-Case 'binding and actual profiles resolve real actor IDs not public overrides' {
            $binding = New-TestBinding
            $stub = New-IdentityStub $binding
            $session = New-TestSession $stub
            $identity = Resolve-SeedIdentityContext -Session $session -Config $config -Personas $pack -Scenario $scenario -Binding $binding -PersonaPackFingerprint $hash
            Assert-Equal $identity.Roles.Lead.ObjectId $aliceId
            Assert-Equal $identity.Presenter.ObjectId $presenterId
            Assert-Equal $identity.BindingFingerprint (Get-SeedFingerprint $binding)
            Assert-Equal $stub.Ledger.Count 5
            Assert-True (@($stub.Ledger | Where-Object Method -ne GET).Count -eq 0)
        }
        Test-Case 'invalid missing cross-tenant duplicate stale bindings and public identity fail before Graph' {
            foreach ($kind in @('missing', 'tenant', 'duplicate', 'pack', 'instance', 'profile', 'photo', 'license', 'extra', 'presenter')) {
                $binding = New-TestBinding; $public = Copy-TestValue $pack
                switch ($kind) {
                    missing { $binding = $null }
                    tenant { $binding.tenantId = $bobId }
                    duplicate { $binding.users.bob.objectId = $aliceId }
                    pack { $binding.fingerprint = 'b' * 64 }
                    instance { $binding.instanceId = 'wrong' }
                    profile { $binding.users.alice.profile.department = 'changed' }
                    photo { $binding.users.alice.photo.sourceSha256 = 'b' * 64 }
                    license { $binding.users.alice.license.skuIds = @($bobId) }
                    extra { $public.people[0].objectId = $aliceId }
                    presenter { $binding.users.alice.upn = $config.presenterUpn }
                }
                $stub = New-GraphStub; $session = New-TestSession $stub
                Assert-Throws { Resolve-SeedIdentityContext -Session $session -Config $config -Personas $public -Scenario $scenario -Binding $binding -PersonaPackFingerprint $hash } 'Seed.(Binding|Input|Identity)' | Out-Null
                Assert-Equal $stub.Ledger.Count 0
            }
        }
        Test-Case 'actual disabled drifted absent user and Presenter stop resolution' {
            foreach ($kind in @('disabled', 'drift', 'absent', 'wrong-id', 'presenter-absent')) {
                $binding = New-TestBinding
                $routes = @{}
                $profile = New-TestProfile $binding alice
                switch ($kind) {
                    disabled { $profile.accountEnabled = $false }
                    drift { $profile.department = 'Other' }
                    absent { $profile = New-GraphStubError 404 }
                    wrong-id { $profile.id = $bobId }
                }
                $routes["GET /users/$aliceId`?`$select=id,userPrincipalName,displayName,jobTitle,department,companyName,officeLocation,usageLocation,accountEnabled,userType"] = @($profile)
                $routes["GET /users/$aliceId/manager?`$select=id"] = @(New-GraphStubError 404)
                $routes["GET /users/$bobId`?`$select=id,userPrincipalName,displayName,jobTitle,department,companyName,officeLocation,usageLocation,accountEnabled,userType"] = @(New-TestProfile $binding bob)
                $routes["GET /users/$bobId/manager?`$select=id"] = @(@{ id = $aliceId })
                $routes['GET /users/presenter%40example.invalid?$select=id,userPrincipalName,accountEnabled,userType'] = @(New-GraphStubError 404)
                $stub = New-GraphStub $routes; $session = New-TestSession $stub
                Assert-Throws { Resolve-SeedIdentityContext -Session $session -Config $config -Personas $pack -Scenario $scenario -Binding $binding -PersonaPackFingerprint $hash } 'Seed.(Identity|Graph)' | Out-Null
            }
        }
        Test-Case 'service checks only selected referenced personas and Presenter no implicit provisioning' {
            $identity = @{ Roles = @{ Lead = @{ ObjectId = $aliceId }; Unused = @{ ObjectId = $bobId } }; Presenter = @{ ObjectId = $presenterId } }
            $selected = Copy-TestValue $scenario
            $selected.Remove('teams'); $selected.Remove('sharepoint'); $selected.outlook.threads[0].messages = @($selected.outlook.threads[0].messages[0])
            $selected.outlook.threads[0].messages[0].toRoles = @('Presenter')
            $stub = New-GraphStub @{
                "GET /users/$aliceId/mailFolders/inbox?`$select=id" = @(@{ id = 'alice-inbox' })
                "GET /users/$presenterId/mailFolders/inbox?`$select=id" = @(@{ id = 'presenter-inbox' })
                "GET /users/$presenterId/drive?`$select=id,driveType,owner" = @(@{ id = 'presenter-drive'; owner = @{ user = @{ id = $presenterId } } })
            }
            $session = New-TestSession $stub
            $readiness = Test-SeedServices -Session $session -Scenario $selected -IdentityContext $identity
            Assert-True $readiness.Ready
            Assert-Equal $stub.Ledger.Count 3
            Assert-True (($stub.Ledger | ConvertTo-Json) -notmatch $bobId)
        }
        Test-Case 'mailbox drive not ready or owner mismatch fails closed GET-only' {
            $identity = @{ Roles = @{ Lead = @{ ObjectId = $aliceId } }; Presenter = @{ ObjectId = $presenterId } }
            foreach ($response in @((New-GraphStubError 404), (New-GraphStubError 403), @{ id = 'drive'; owner = @{ user = @{ id = $bobId } } })) {
                $stub = New-GraphStub @{ "GET /users/$presenterId/drive?`$select=id,driveType,owner" = @($response) }
                $session = New-TestSession $stub
                Assert-Throws { Test-SeedServices -Session $session -Scenario @{ onedrive = $scenario.onedrive } -IdentityContext $identity } 'Seed.(Service|Graph)' | Out-Null
                Assert-Equal @($stub.Ledger | Where-Object Method -ne GET).Count 0
            }
        }
        Test-Case 'operation plans require authoritative callbacks and full Presenter provenance' {
            $op = New-TestOperation
            $plan = @(Get-SeedOperationPlan -Session (New-TestSession (New-GraphStub)) -Operations @($op) -ResourceChecks @{})
            Assert-Equal $plan[0].Action 'Block'
            $plan = @(Get-SeedOperationPlan -Session (New-TestSession (New-GraphStub)) -Operations @($op) -ResourceChecks @{ outlook = { param($Session, $Operation) @{ State = 'Absent'; AbsenceVerified = $true; PresenterVerified = $true } } })
            Assert-Equal $plan[0].Action 'Create'
            Assert-Equal $plan[0].DataFingerprint $hash
            $plan = @(Get-SeedOperationPlan -Session (New-TestSession (New-GraphStub)) -Operations @($op) -ResourceChecks @{ outlook = { throw 'secret body' } })
            Assert-Equal $plan[0].Action 'Block'
            Assert-True (($plan | ConvertTo-Json -Depth 10) -notmatch 'secret body')
        }
        Test-Case 'operation failure diagnostics keep only a safe code instead of provider payloads' {
            $op = New-TestOperation
            $check = { throw 'Seed.Graph.403: https://example.invalid/?sig=private-value secret body' }
            $plan = @(Get-SeedOperationPlan -Session (New-TestSession (New-GraphStub)) -Operations @($op) -ResourceChecks @{ outlook = $check })
            Assert-Equal $plan[0].Action Block
            Assert-Equal $plan[0].FailureCode 'Seed.Graph.403'
            Assert-True (($plan | ConvertTo-Json -Depth 20) -notmatch 'private-value|secret body|example.invalid/\?')
        }
        Test-Case 'Graph failures preserve status and request category without leaking resource identifiers' {
            $s = New-TestSession (New-GraphStub)
            (Get-SeedSessionRecord $s).Transport = { throw (New-GraphStubError 400) }
            $failure = $null
            try { Invoke-SeedGraph -Session $s -Method GET -Path '/drives/private-drive/items/private-item/permissions' | Out-Null }
            catch { $failure = $_.Exception }
            Assert-True ($null -ne $failure)
            Assert-Equal $failure.Data['SeedDiagnostic'].RequestKind DrivePermissions
            Assert-Equal $failure.Data['StatusCode'] 400
            Assert-True (($failure.Data['SeedDiagnostic'] | ConvertTo-Json) -notmatch 'private-drive|private-item')
        }
        Test-Case 'unknown partial collisions and incomplete remote results never Create or Skip' {
            foreach ($state in @('Unknown', 'Partial', 'Existing', 'Absent')) {
                $reply = @{ State = $state; AbsenceVerified = $false; PresenterVerified = $true }
                $check = { param($s, $o) $reply }.GetNewClosure()
                $plan = @(Get-SeedOperationPlan -Session (New-TestSession (New-GraphStub)) -Operations @((New-TestOperation)) -ResourceChecks @{ outlook = $check })
                Assert-Equal $plan[0].Action 'Block'
            }
        }
        Test-Case 'journal new atomic context-bound no overwrite lock and exact operation gating' {
            $path = Join-Path $scratch 'journal.run-state.json'
            $context = New-TestContext; $operations = @((New-TestOperation))
            $state = New-SeedRunState -Path $path -RunId training01 -Context $context -Operations $operations
            Assert-Equal $state.status 'Planned'
            Assert-Throws { New-SeedRunState -Path $path -RunId training01 -Context $context -Operations $operations } 'Seed.State.Exists' | Out-Null
            $lock = Enter-SeedRunLock -Path $path
            try { Assert-Throws { Enter-SeedRunLock -Path $path } 'Seed.State.Lock' | Out-Null } finally { Exit-SeedRunLock $lock }
            $changed = Copy-TestValue $context; $changed.presenterUpn = 'other@example.invalid'
            Assert-Throws { Get-SeedRunState -Path $path -RunId training01 -Context $changed -Operations $operations } 'Seed.State.Context' | Out-Null
            Assert-Throws { Get-SeedRunState -Path $path -RunId training01 -Context $context -Operations @() } 'Seed.State.Operations' | Out-Null
            Write-SeedRunEvent -Path $path -RunId training01 -Context $context -Operations $operations -OperationId mail-1 -Workload outlook -Action Submit -Status Submitted | Out-Null
            Assert-Throws { Get-SeedRunState -Path $path -RunId training01 -Context $context -Operations $operations -ForImport } 'Seed.State.Blocked' | Out-Null
            $pending = Get-SeedRunState -Path $path -RunId training01 -Context $context -Operations $operations
            Assert-Equal $pending.events[-1].status 'Submitted'
        }
        Test-Case 'unknown persisted blocks replay and Completed requires exact authoritative evidence' {
            $path = Join-Path $scratch 'unknown.run-state.json'; $ctx = New-TestContext; $ops = @((New-TestOperation))
            New-SeedRunState -Path $path -RunId training01 -Context $ctx -Operations $ops | Out-Null
            Write-SeedRunEvent -Path $path -RunId training01 -Context $ctx -Operations $ops -OperationId mail-1 -Workload outlook -Action Submit -Status Submitted | Out-Null
            Write-SeedRunEvent -Path $path -RunId training01 -Context $ctx -Operations $ops -OperationId mail-1 -Workload outlook -Action Fail -Status Unknown -ErrorCode Transport | Out-Null
            $state = Get-SeedRunState -Path $path -RunId training01 -Context $ctx -Operations $ops
            Assert-Equal $state.status 'Blocked'
            Assert-Throws { Write-SeedRunEvent -Path $path -RunId training01 -Context $ctx -Operations $ops -OperationId mail-1 -Workload outlook -Action Verify -Status Verified -ObjectId remote -ReadBack @{ valid = $true } } 'Seed.State.Transition' | Out-Null
        }
        Test-Case 'verified journal digest and completed Skip require fresh authoritative read-back' {
            $path = Join-Path $scratch 'complete.run-state.json'; $ctx = New-TestContext; $ops = @((New-TestOperation))
            New-SeedRunState -Path $path -RunId training01 -Context $ctx -Operations $ops | Out-Null
            Write-SeedRunEvent -Path $path -RunId training01 -Context $ctx -Operations $ops -OperationId mail-1 -Workload outlook -Action Submit -Status Submitted | Out-Null
            Write-SeedRunEvent -Path $path -RunId training01 -Context $ctx -Operations $ops -OperationId mail-1 -Workload outlook -Action Verify -Status Verified -ObjectId remote -ReadBack @{ id = 'remote'; author = $aliceId } | Out-Null
            $state = Get-SeedRunState -Path $path -RunId training01 -Context $ctx -Operations $ops -ForImport
            Assert-Equal $state.status 'Completed'
            $proof = @{ State = 'Existing'; ToolOwned = $true; ContentVerified = $true; PresenterVerified = $true; ObjectId = 'remote'; DataFingerprint = $hash; EvidenceFingerprint = (Get-SeedFingerprint @{ id = 'remote'; author = $aliceId }) }
            $check = { param($s, $o) $proof }.GetNewClosure()
            $plan = @(Get-SeedOperationPlan -Session (New-TestSession (New-GraphStub)) -Operations $ops -ResourceChecks @{ outlook = $check } -RunState $state)
            Assert-Equal $plan[0].Action 'Skip'
            $proof.ObjectId = 'wrong'
            $plan = @(Get-SeedOperationPlan -Session (New-TestSession (New-GraphStub)) -Operations $ops -ResourceChecks @{ outlook = $check } -RunState $state)
            Assert-Equal $plan[0].Action 'Block'
        }
        Test-Case 'all writes need exact approval pending before transport unknown no retry' {
            $path = Join-Path $scratch 'write.run-state.json'; $ctx = New-TestContext; $ops = @((New-TestOperation))
            New-SeedRunState -Path $path -RunId training01 -Context $ctx -Operations $ops | Out-Null
            $observed = @{ Pending = $false }
            $response = {
                param($m, $p, $b, $r)
                $state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
                $observed.Pending = $state.results[0].status -eq 'Submitted'
                throw (New-GraphStubError 503)
            }.GetNewClosure()
            $stub = New-GraphStub @{ "POST /users/$aliceId/sendMail" = @($response) }
            $session = New-TestVerifiedSession $stub
            $body = @{ message = @{ subject = 'Test' }; saveToSentItems = $true }
            $plan = @(Get-SeedOperationPlan -Session $session -Operations $ops -ResourceChecks @{ outlook = { @{ State = 'Absent'; AbsenceVerified = $true; PresenterVerified = $true } } })
            $request = @{ OperationId = 'mail-1'; Method = 'POST'; Path = "/users/$aliceId/sendMail"; Body = $body }
            Assert-Throws { New-SeedWriteApproval -Session $session -Plan $plan -Requests @($request) -ConfirmTarget wrong -StatePath $path -RunId training01 -Context $ctx } 'Seed.Approval' | Out-Null
            New-SeedWriteApproval -Session $session -Plan $plan -Requests @($request) -ConfirmTarget "$tenant/training01" -StatePath $path -RunId training01 -Context $ctx | Out-Null
            Assert-Throws { Invoke-SeedGraph -Session $session -Method POST -Path "/users/$aliceId/sendMail" -Body @{ changed = $true } } 'Seed.Write' | Out-Null
            Assert-Equal $stub.Ledger.Count 0
            $message = Assert-Throws { Invoke-SeedGraph -Session $session -Method POST -Path "/users/$aliceId/sendMail" -Body $body } 'Seed.Graph.503'
            Assert-True ($message -notmatch 'SECRET|password|hidden')
            Assert-True $observed.Pending
            Assert-Equal $stub.Ledger.Count 1
            Assert-Equal (Get-SeedRunState -Path $path -RunId training01 -Context $ctx -Operations $ops).results[0].status 'Unknown'
            Assert-Throws { Invoke-SeedGraph -Session $session -Method POST -Path "/users/$aliceId/sendMail" -Body $body } 'Seed.Write' | Out-Null
            Assert-Equal $stub.Ledger.Count 1
        }
        Test-Case 'global preflight stays GET-only even malicious adapter and Block prevents approval' {
            $binding = New-TestBinding; $stub = New-IdentityStub $binding; $session = New-TestSession $stub
            $minimal = Copy-TestValue $scenario
            $minimal.Remove('outlook'); $minimal.Remove('teams'); $minimal.Remove('onedrive')
            $ops = @(@{ OperationId = 'site'; Workload = 'sharepoint'; TargetKey = 'site'; TargetId = $null; DataFingerprint = $hash; SideEffects = @('Create private site'); PresenterEvidence = @{ verified = $true; objectId = $presenterId } })
            $result = Invoke-SeedPreflight -Session $session -Config $config -Personas $pack -Scenario $minimal -Binding $binding -PersonaPackFingerprint $hash -Operations $ops -ResourceChecks @{ sharepoint = { param($s, $o) Invoke-SeedGraph -Session $s -Method POST -Path '/groups' -Body @{} } }
            Assert-True (-not $result.CanImport)
            Assert-Equal $result.Plan[0].Action 'Block'
            Assert-Equal @($stub.Ledger | Where-Object Method -ne GET).Count 0
        }
        Test-Case 'valid preflight is reusable normal session but provides no write authority' {
            $binding = New-TestBinding; $stub = New-IdentityStub $binding; $session = New-TestSession $stub
            $minimal = Copy-TestValue $scenario
            $minimal.Remove('outlook'); $minimal.Remove('teams'); $minimal.Remove('onedrive')
            $op = New-TestOperation; $op.Workload = 'sharepoint'
            $result = Invoke-SeedPreflight -Session $session -Config $config -Personas $pack -Scenario $minimal -Binding $binding -PersonaPackFingerprint $hash -Operations @($op) -ResourceChecks @{ sharepoint = { @{ State = 'Absent'; AbsenceVerified = $true; PresenterVerified = $true } } }
            Assert-True $result.CanImport
            Assert-Equal $result.Plan[0].Action 'Create'
            Assert-Throws { Invoke-SeedGraph -Session $session -Method POST -Path '/groups' -Body @{} } 'Seed.Write' | Out-Null
        }
        Test-Case 'journal tamper sequence foreign content extra results and secret evidence rejected' {
            foreach ($kind in @('sequence', 'extra', 'secret')) {
                $path = Join-Path $scratch "$kind.run-state.json"; $ctx = New-TestContext; $ops = @((New-TestOperation))
                New-SeedRunState -Path $path -RunId training01 -Context $ctx -Operations $ops | Out-Null
                if ($kind -eq 'secret') {
                    Write-SeedRunEvent -Path $path -RunId training01 -Context $ctx -Operations $ops -OperationId mail-1 -Workload outlook -Action Submit -Status Submitted | Out-Null
                    Assert-Throws { Write-SeedRunEvent -Path $path -RunId training01 -Context $ctx -Operations $ops -OperationId mail-1 -Workload outlook -Action Verify -Status Verified -ObjectId remote -ReadBack @{ token = 'secret' } } 'Seed.Secret' | Out-Null
                } else {
                    $state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
                    if ($kind -eq 'sequence') { $state.events[0].sequence = 10 } else { $state.results += @{ id = 'extra'; workload = 'outlook'; status = 'Planned' } }
                    $state | ConvertTo-Json -Depth 90 | Set-Content -LiteralPath $path
                    Assert-Throws { Get-SeedRunState -Path $path -RunId training01 -Context $ctx -Operations $ops } 'Seed.State' | Out-Null
                }
            }
        }
        Test-Case 'selected service permission matrix rejects missing required application roles' {
                $identity = @{ Roles = @{}; Presenter = @{ ObjectId = $presenterId } }
                foreach ($workload in @('outlook', 'onedrive', 'teams', 'sharepoint')) {
                    $stub = New-GraphStub
                    $session = New-TestSession $stub @{ roles = @('User.Read.All') }
                    Assert-Throws { Test-SeedServices -Session $session -Scenario @{ $workload = $scenario[$workload] } -IdentityContext $identity } 'Seed.Service.Scope' | Out-Null
                    Assert-Equal $stub.Ledger.Count 0
                }
            }
            Test-Case 'forged Completed state is never trusted by operation planner' {
                $ops = @((New-TestOperation))
                $forged = @{ status = 'Completed'; results = @(@{ id = 'mail-1'; workload = 'outlook'; status = 'Verified'; objectId = 'remote'; evidence = @{ sha256 = $hash } }) }
                $proof = @{ State = 'Existing'; ToolOwned = $true; ContentVerified = $true; PresenterVerified = $true; ObjectId = 'remote'; DataFingerprint = $hash; EvidenceFingerprint = $hash }
                $check = { $proof }.GetNewClosure()
                $plan = @(Get-SeedOperationPlan -Session (New-TestSession (New-GraphStub)) -Operations $ops -ResourceChecks @{ outlook = $check } -RunState $forged)
                Assert-Equal $plan[0].Action 'Block'
            }
            Test-Case 'completed evidence fingerprint tampering is rejected by journal history' {
                $path = Join-Path $scratch 'evidence.run-state.json'; $ctx = New-TestContext; $ops = @((New-TestOperation))
                New-SeedRunState -Path $path -RunId training01 -Context $ctx -Operations $ops | Out-Null
                Write-SeedRunEvent -Path $path -RunId training01 -Context $ctx -Operations $ops -OperationId mail-1 -Workload outlook -Action Submit -Status Submitted | Out-Null
                Write-SeedRunEvent -Path $path -RunId training01 -Context $ctx -Operations $ops -OperationId mail-1 -Workload outlook -Action Verify -Status Verified -ObjectId remote -ReadBack @{ id = 'remote' } | Out-Null
                $state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
                $state.results[0].evidence.sha256 = 'f' * 64
                $state | ConvertTo-Json -Depth 90 | Set-Content -LiteralPath $path
                Assert-Throws { Get-SeedRunState -Path $path -RunId training01 -Context $ctx -Operations $ops } 'Seed.State.Evidence' | Out-Null
            }
            Test-Case 'approved positive write stays pending until explicit read-back Verify' {
                $path = Join-Path $scratch 'positive.run-state.json'; $ctx = New-TestContext; $ops = @((New-TestOperation))
                New-SeedRunState -Path $path -RunId training01 -Context $ctx -Operations $ops | Out-Null
                $stub = New-GraphStub @{ "POST /users/$aliceId/sendMail" = @(@{ accepted = $true }) }
                $session = New-TestVerifiedSession $stub
                $body = @{ message = @{ subject = 'Approved' } }
                $plan = @(Get-SeedOperationPlan -Session $session -Operations $ops -ResourceChecks @{ outlook = { @{ State = 'Absent'; AbsenceVerified = $true; PresenterVerified = $true } } })
                New-SeedWriteApproval -Session $session -Plan $plan -Requests @(@{ OperationId = 'mail-1'; Method = 'POST'; Path = "/users/$aliceId/sendMail"; Body = $body }) -ConfirmTarget "$tenant/training01" -StatePath $path -RunId training01 -Context $ctx | Out-Null
                Assert-True (Invoke-SeedGraph -Session $session -Method POST -Path "/users/$aliceId/sendMail" -Body $body).accepted
                Assert-Equal (Get-SeedRunState -Path $path -RunId training01 -Context $ctx -Operations $ops).results[0].status 'Submitted'
                Write-SeedRunEvent -Path $path -RunId training01 -Context $ctx -Operations $ops -OperationId mail-1 -Workload outlook -Action Verify -Status Verified -ObjectId 'received-message' -ReadBack @{ id = 'received-message'; inbox = $presenterId } | Out-Null
                Assert-Equal (Get-SeedRunState -Path $path -RunId training01 -Context $ctx -Operations $ops).status 'Completed'
                Assert-Equal $stub.Ledger.Count 1
            }
            Test-Case 'approval cannot cross workload or mutate plan and invalid context is typed failure' {
                $path = Join-Path $scratch 'scope.run-state.json'; $ctx = New-TestContext; $ops = @((New-TestOperation))
                New-SeedRunState -Path $path -RunId training01 -Context $ctx -Operations $ops | Out-Null
                $session = New-TestVerifiedSession (New-GraphStub)
                $plan = @(Get-SeedOperationPlan -Session $session -Operations $ops -ResourceChecks @{ outlook = { @{ State = 'Absent'; AbsenceVerified = $true; PresenterVerified = $true } } })
                $request = @{ OperationId = 'mail-1'; Method = 'POST'; Path = '/groups'; Body = @{ displayName = 'Unrelated' } }
                Assert-Throws { New-SeedWriteApproval -Session $session -Plan $plan -Requests @($request) -ConfirmTarget "$tenant/training01" -StatePath $path -RunId training01 -Context $ctx } 'Seed.Approval.Workload' | Out-Null
                Assert-Throws { New-SeedWriteApproval -Session $session -Plan $plan -Requests @($request) -ConfirmTarget "$tenant/training01" -StatePath $path -RunId training01 -Context @{} } 'Seed.Input' | Out-Null
                $plan[0].SideEffects = @('Changed')
                Assert-Throws { New-SeedWriteApproval -Session $session -Plan $plan -Requests @($request) -ConfirmTarget "$tenant/training01" -StatePath $path -RunId training01 -Context $ctx } 'Seed.Approval.Plan' | Out-Null
            }
            Test-Case 'unrelated preexisting journal bytes are never overwritten' {
                $path = Join-Path $scratch 'foreign.run-state.json'
                [IO.File]::WriteAllText($path, 'foreign state belongs to another run')
                Assert-Throws { New-SeedRunState -Path $path -RunId training01 -Context (New-TestContext) -Operations @((New-TestOperation)) } 'Seed.State.Exists' | Out-Null
                Assert-Equal ([IO.File]::ReadAllText($path)) 'foreign state belongs to another run'
            }
            Test-Case 'two referenced roles cannot impersonate the same bound person' {
                $binding = New-TestBinding; $duplicate = Copy-TestValue $scenario
                $duplicate.roles.Analyst.personaId = 'alice'
                $stub = New-GraphStub; $session = New-TestSession $stub
                Assert-Throws { Resolve-SeedIdentityContext -Session $session -Config $config -Personas $pack -Scenario $duplicate -Binding $binding -PersonaPackFingerprint $hash } 'Seed.Identity.Duplicate' | Out-Null
                Assert-Equal $stub.Ledger.Count 0
            }
            Test-Case 'inventory explicitly marks optional evidence NotChecked and never grants SKU scope' {
                $context = { @{ TenantId = $tenant; ClientId = $config.adminAuth.clientId; Account = $config.adminAuth.adminOperatorUpn; AuthType = 'Delegated'; ContextScope = 'Process'; Scopes = @('User.Read.All', 'RoleManagement.Read.Directory') } }.GetNewClosure()
                $stub = New-GraphStub @{
                    'GET /me?$select=id,userPrincipalName' = @(@{ id = $aliceId; userPrincipalName = $config.adminAuth.adminOperatorUpn })
                    "GET /roleManagement/directory/roleAssignments?`$filter=principalId%20eq%20'$aliceId'&`$expand=roleDefinition" = @(@{ value = @(@{ principalId = $aliceId; directoryScopeId = '/'; roleDefinition = @{ templateId = 'fe930be7-5e62-47db-91af-98c3a49a38b1' } }) })
                    'GET /users?$select=id,displayName,userPrincipalName,jobTitle,department,companyName,accountEnabled,userType' = @(@{ value = @(@{ id = $presenterId; userPrincipalName = $config.presenterUpn; accountEnabled = $true; userType = 'Member' }) })
                }
                $session = New-TestSession $stub @{} InspectUsers
                $inventoryBinding = New-TestBinding | ConvertTo-Json -Depth 90 | ConvertFrom-Json
                $inventory = @(Get-DemoUserInventory -Session $session -PresenterUpn $config.presenterUpn -Binding $inventoryBinding)
                Assert-True $inventory[0].IsPresenter
                Assert-Equal $inventory[0].LicenseStatus 'NotChecked'
                Assert-Equal $inventory[0].ManagedStatus 'Unmanaged'
                Assert-True ('LicenseAssignment.Read.All' -notin $session.Permissions)
            }
        Test-Case 'late-bound new resource requests inherit original approval only with verified parent' {
            $path = Join-Path $scratch 'staged.run-state.json'; $ctx = New-TestContext
            $parent = New-TestOperation; $parent.OperationId = 'group'; $parent.Workload = 'teams'
            $child = New-TestOperation; $child.OperationId = 'owner'; $child.Workload = 'teams'
            $ops = @($parent, $child); $remote = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'
            New-SeedRunState -Path $path -RunId training01 -Context $ctx -Operations $ops | Out-Null
            $stub = New-GraphStub @{ 'POST /groups' = @(@{ id = $remote }); "POST /groups/$remote/owners/`$ref" = @(@{ accepted = $true }) }
            $session = New-TestVerifiedSession $stub
            $plan = @(Get-SeedOperationPlan -Session $session -Operations $ops -ResourceChecks @{ teams = { @{ State = 'Absent'; AbsenceVerified = $true; PresenterVerified = $true } } })
            $groupBody = @{ displayName = 'New resource' }
            New-SeedWriteApproval -Session $session -Plan $plan -Requests @(@{ OperationId = 'group'; Method = 'POST'; Path = '/groups'; Body = $groupBody }) -ConfirmTarget "$tenant/training01" -StatePath $path -RunId training01 -Context $ctx | Out-Null
            $request = @{ OperationId = 'owner'; Method = 'POST'; Path = "/groups/$remote/owners/`$ref"; Body = @{ '@odata.id' = "https://graph.microsoft.com/v1.0/users/$presenterId" } }
            $proof = @{
                OperationFingerprint = Get-SeedOperationDigest $child
                RequestFingerprint = Get-SeedRequestFingerprint POST $request.Path $request.Body $null
                MatchesPlan = $true; PresenterVerified = $true; ParentOperationId = 'group'; ParentObjectId = $remote
            }
            $check = { param($s, $o, $r) $proof }.GetNewClosure()
            $failedCheck = $null
            $beforeCheck = (Get-FileHash $path).Hash
            try { Add-SeedApprovedRequest -Session $session -Request $request -RequestCheck { throw 'Seed.Teams.Pending: Synthetic propagation delay.' } }
            catch { $failedCheck = $_.Exception }
            Assert-True ($null -ne $failedCheck -and $failedCheck.Data.Contains('SeedDiagnostic'))
            Assert-Equal $failedCheck.Data['SeedDiagnostic'].CauseCode 'Seed.Teams.Pending'
            Assert-Equal (Get-FileHash $path).Hash $beforeCheck
            Assert-Equal $stub.Ledger.Count 0
            Assert-Throws { Add-SeedApprovedRequest -Session $session -Request $request -RequestCheck $check } 'Seed.Approval.Parent' | Out-Null
            Invoke-SeedGraph -Session $session -Method POST -Path '/groups' -Body $groupBody | Out-Null
            Write-SeedRunEvent -Path $path -RunId training01 -Context $ctx -Operations $ops -OperationId group -Workload teams -Action Verify -Status Verified -ObjectId $remote -ReadBack @{ id = $remote; created = $true } | Out-Null
            Add-SeedApprovedRequest -Session $session -Request $request -RequestCheck $check | Out-Null
            Assert-True (Invoke-SeedGraph -Session $session -Method POST -Path $request.Path -Body $request.Body).accepted
            Assert-Equal $stub.Ledger.Count 2
            Assert-Throws { Add-SeedApprovedRequest -Session $session -Request $request -RequestCheck $check } 'Seed.Approval' | Out-Null
        }
        Test-Case 'all Python subprocess inputs reject credential objects before starting child' {
            Assert-Throws { Invoke-SeedPython -Code 'import json; print("{}")' -InputObject @{ password = 'hidden' } } 'Seed.Secret' | Out-Null
        }
        Test-Case 'partial run and changed operation fingerprints cannot be replayed or skipped' {
            $path = Join-Path $scratch 'partial.run-state.json'; $ctx = New-TestContext; $ops = @((New-TestOperation))
            New-SeedRunState -Path $path -RunId training01 -Context $ctx -Operations $ops | Out-Null
            Write-SeedRunEvent -Path $path -RunId training01 -Context $ctx -Operations $ops -OperationId mail-1 -Workload outlook -Action Submit -Status Submitted | Out-Null
            Write-SeedRunEvent -Path $path -RunId training01 -Context $ctx -Operations $ops -OperationId mail-1 -Workload outlook -Action Block -Status Partial | Out-Null
            Assert-Throws { Get-SeedRunState -Path $path -RunId training01 -Context $ctx -Operations $ops -ForImport } 'Seed.State.Blocked' | Out-Null
            $ops[0].DataFingerprint = 'b' * 64
            Assert-Throws { Get-SeedRunState -Path $path -RunId training01 -Context $ctx -Operations $ops } 'Seed.State.Operations' | Out-Null
        }
        Test-Case 'unused persona never triggers actual profile or manager queries' {
            $binding = New-TestBinding; $selected = Copy-TestValue $scenario
            $selected.Remove('outlook'); $selected.Remove('teams'); $selected.Remove('onedrive')
            $selected.sharepoint.sites[0].memberRoles = @()
            $stub = New-IdentityStub $binding; $session = New-TestSession $stub
            $identity = Resolve-SeedIdentityContext -Session $session -Config $config -Personas $pack -Scenario $selected -Binding $binding -PersonaPackFingerprint $hash
            Assert-Equal $identity.Roles.Count 2
            Assert-Equal $stub.Ledger.Count 3
            Assert-True (($stub.Ledger | ConvertTo-Json) -notmatch $bobId)
        }
        Test-Case 'normal injected sessions remain isolated from changing delegated SDK context' {
            $current = @{ Value = @{ TenantId = $tenant; ClientId = $config.adminAuth.clientId; Account = $config.adminAuth.adminOperatorUpn; AuthType = 'Delegated'; ContextScope = 'Process'; Scopes = @('User.Read.All', 'RoleManagement.Read.Directory') } }
            $context = { $current.Value }.GetNewClosure()
            $adminStub = New-GraphStub @{
                'GET /me?$select=id,userPrincipalName' = @(@{ id = $aliceId; userPrincipalName = $config.adminAuth.adminOperatorUpn })
                "GET /roleManagement/directory/roleAssignments?`$filter=principalId%20eq%20'$aliceId'&`$expand=roleDefinition" = @(@{ value = @(@{ principalId = $aliceId; directoryScopeId = '/'; roleDefinition = @{ templateId = '62e90394-69f5-4237-9190-012177145e10' } }) })
            }
            $adminSession = Connect-AdminSession -Config $config -Mode InspectUsers -SdkConnect {} -SdkContext $context -SdkRequest $adminStub.Transport
            $current.Value.Account = 'other@example.invalid'
            Assert-Throws { Invoke-SeedGraph -Session $adminSession -Method GET -Path '/users' } 'Seed.Graph.0' | Out-Null
            Assert-Equal $adminStub.Ledger.Count 2
            $appStub = New-GraphStub @{ 'GET /users' = @(@{ value = @() }) }
            $app = New-TestSession $appStub
            Assert-Equal @(Get-SeedGraphCollection -Session $app -Path '/users').Count 0
            Assert-Equal $appStub.Ledger.Count 1
        }
        Test-Case 'actual Graph channel site IDs and root folder raw uploads pass exact allowlist' {
            $cases = @(
                @{ Workload = 'teams'; Method = 'POST'; Path = "/teams/$aliceId/channels/19:channel@thread.tacv2/messages"; Body = @{ from = @{ user = @{ id = $aliceId } }; body = @{ content = 'Real author' } } },
                @{ Workload = 'sharepoint'; Method = 'POST'; Path = "/sites/example.sharepoint.com,$aliceId,$bobId/lists"; Body = @{ displayName = 'New List' } },
                @{ Workload = 'onedrive'; Method = 'POST'; Path = '/drives/drive-id/root/children'; Body = @{ name = 'New run folder'; folder = @{} } },
                @{ Workload = 'onedrive'; Method = 'PUT'; Path = '/drives/drive-id/items/run-folder:/file.bin:/content'; RawBody = [byte[]]@(1, 2, 255) }
            )
            $index = 0
            foreach ($case in $cases) {
                $index++; $path = Join-Path $scratch "endpoint-$index.run-state.json"; $ctx = New-TestContext
                $op = New-TestOperation; $op.Workload = $case.Workload; $ops = @($op)
                New-SeedRunState -Path $path -RunId training01 -Context $ctx -Operations $ops | Out-Null
                $stub = New-GraphStub @{ "$($case.Method) $($case.Path)" = @(@{ id = 'accepted' }) }; $session = New-TestVerifiedSession $stub
                $plan = @(Get-SeedOperationPlan -Session $session -Operations $ops -ResourceChecks @{ $case.Workload = { @{ State = 'Absent'; AbsenceVerified = $true; PresenterVerified = $true } } })
                $request = Copy-TestValue $case; $request.OperationId = 'mail-1'
                if ($case.ContainsKey('RawBody')) { $request.RawBody = $case.RawBody }
                New-SeedWriteApproval -Session $session -Plan $plan -Requests @($request) -ConfirmTarget "$tenant/training01" -StatePath $path -RunId training01 -Context $ctx | Out-Null
                $arguments = @{ Session = $session; Method = $case.Method; Path = $case.Path }
                if ($case.ContainsKey('Body')) { $arguments.Body = $case.Body } else { $arguments.RawBody = $case.RawBody }
                Assert-Equal (Invoke-SeedGraph @arguments).id 'accepted'
                Assert-Equal $stub.Ledger.Count 1
                if ($case.ContainsKey('RawBody')) { Assert-Equal $stub.Ledger[0].RawBody $case.RawBody }
            }
        }
        Test-Case 'global preflight denies even a previously approved valid content write' {
            $path = Join-Path $scratch 'readonly.run-state.json'; $ctx = New-TestContext; $ops = @((New-TestOperation))
            New-SeedRunState -Path $path -RunId training01 -Context $ctx -Operations $ops | Out-Null
            $binding = New-TestBinding; $stub = New-IdentityStub $binding; $session = New-TestVerifiedSession $stub
            $body = @{ message = @{ subject = 'Approved earlier' } }
            $plan = @(Get-SeedOperationPlan -Session $session -Operations $ops -ResourceChecks @{ outlook = { @{ State = 'Absent'; AbsenceVerified = $true; PresenterVerified = $true } } })
            New-SeedWriteApproval -Session $session -Plan $plan -Requests @(@{ OperationId = 'mail-1'; Method = 'POST'; Path = "/users/$aliceId/sendMail"; Body = $body }) -ConfirmTarget "$tenant/training01" -StatePath $path -RunId training01 -Context $ctx | Out-Null
            $selected = Copy-TestValue $scenario; $selected.Remove('outlook'); $selected.Remove('teams'); $selected.Remove('onedrive')
            $op = New-TestOperation; $op.Workload = 'sharepoint'
            $check = { param($s, $o) Invoke-SeedGraph -Session $s -Method POST -Path "/users/$aliceId/sendMail" -Body $body }.GetNewClosure()
            $result = Invoke-SeedPreflight -Session $session -Config $config -Personas $pack -Scenario $selected -Binding $binding -PersonaPackFingerprint $hash -Operations @($op) -ResourceChecks @{ sharepoint = $check }
            Assert-True (-not $result.CanImport)
            Assert-Equal @($stub.Ledger | Where-Object Method -ne GET).Count 0
            Assert-Equal (Get-SeedRunState -Path $path -RunId training01 -Context $ctx -Operations $ops).results[0].status 'Planned'
            Assert-Throws { Invoke-SeedGraph -Session $session -Method POST -Path "/users/$aliceId/sendMail" -Body $body } 'Seed.Write' | Out-Null
            Assert-Equal @($stub.Ledger | Where-Object Method -ne GET).Count 0
        }
        Test-Case 'state planner rejects selected operation subsets and foreign Presenter approval context' {
            $path = Join-Path $scratch 'subset.run-state.json'; $ctx = New-TestContext
            $ops = @((New-TestOperation), (New-TestOperation)); $ops[1].OperationId = 'mail-2'; $ops[1].TargetKey = 'mail-2'
            New-SeedRunState -Path $path -RunId training01 -Context $ctx -Operations $ops | Out-Null
            $state = Get-SeedRunState -Path $path -RunId training01 -Context $ctx -Operations $ops
            $plan = @(Get-SeedOperationPlan -Session (New-TestSession (New-GraphStub)) -Operations @($ops[0]) -RunState $state -ResourceChecks @{ outlook = { @{ State = 'Absent'; AbsenceVerified = $true; PresenterVerified = $true } } })
            Assert-Equal $plan[0].Action 'Block'
            $ctx.presenterUpn = 'foreign@example.invalid'
            $path = Join-Path $scratch 'presenter-context.run-state.json'; $one = @((New-TestOperation))
            New-SeedRunState -Path $path -RunId training01 -Context $ctx -Operations $one | Out-Null
            $session = New-TestSession (New-GraphStub) @{} Import
            $plan = @(Get-SeedOperationPlan -Session $session -Operations $one -ResourceChecks @{ outlook = { @{ State = 'Absent'; AbsenceVerified = $true; PresenterVerified = $true } } })
            Assert-Throws { New-SeedWriteApproval -Session $session -Plan $plan -Requests @(@{ OperationId = 'mail-1'; Method = 'POST'; Path = "/users/$aliceId/sendMail"; Body = @{} }) -ConfirmTarget "$tenant/training01" -StatePath $path -RunId training01 -Context $ctx } 'Seed.Approval' | Out-Null
        }
        Test-Case 'approval requires actual identity provenance and selected services before writes' {
            $path = Join-Path $scratch 'unbound.run-state.json'; $ctx = New-TestContext; $ops = @((New-TestOperation))
            New-SeedRunState -Path $path -RunId training01 -Context $ctx -Operations $ops | Out-Null
            $stub = New-GraphStub; $session = New-TestSession $stub @{} Import
            $plan = @(Get-SeedOperationPlan -Session $session -Operations $ops -ResourceChecks @{ outlook = { @{ State = 'Absent'; AbsenceVerified = $true; PresenterVerified = $true } } })
            Assert-Throws { New-SeedWriteApproval -Session $session -Plan $plan -Requests @(@{ OperationId = 'mail-1'; Method = 'POST'; Path = "/users/$aliceId/sendMail"; Body = @{} }) -ConfirmTarget "$tenant/training01" -StatePath $path -RunId training01 -Context $ctx } 'Seed.Approval.Identity' | Out-Null
            Assert-Equal $stub.Ledger.Count 0
        }
        Test-Case 'run capability lease prevents a second approved session from owning the same journal' {
            $path = Join-Path $scratch 'lease.run-state.json'; $ctx = New-TestContext; $ops = @((New-TestOperation))
            New-SeedRunState -Path $path -RunId training01 -Context $ctx -Operations $ops | Out-Null
            $request = @{ OperationId = 'mail-1'; Method = 'POST'; Path = "/users/$aliceId/sendMail"; Body = @{} }
            $first = New-TestVerifiedSession (New-GraphStub); $second = New-TestVerifiedSession (New-GraphStub)
            foreach ($session in @($first, $second)) {
                $plan = @(Get-SeedOperationPlan -Session $session -Operations $ops -ResourceChecks @{ outlook = { @{ State = 'Absent'; AbsenceVerified = $true; PresenterVerified = $true } } })
                if ($session -eq $first) {
                    New-SeedWriteApproval -Session $session -Plan $plan -Requests @($request) -ConfirmTarget "$tenant/training01" -StatePath $path -RunId training01 -Context $ctx | Out-Null
                } else {
                    Assert-Throws { New-SeedWriteApproval -Session $session -Plan $plan -Requests @($request) -ConfirmTarget "$tenant/training01" -StatePath $path -RunId training01 -Context $ctx } 'Seed.State.Lock' | Out-Null
                }
            }
        }
        Test-Case 'standard nested PSCustomObject inputs resolve without PowerShell method/null failures' {
                $binding = New-TestBinding; $stub = New-IdentityStub $binding; $session = New-TestSession $stub
                $customConfig = $config | ConvertTo-Json -Depth 90 | ConvertFrom-Json
                $customPack = $pack | ConvertTo-Json -Depth 90 | ConvertFrom-Json
                $customScenario = $scenario | ConvertTo-Json -Depth 90 | ConvertFrom-Json
                $customBinding = $binding | ConvertTo-Json -Depth 90 | ConvertFrom-Json
                $identity = Resolve-SeedIdentityContext -Session $session -Config $customConfig -Personas $customPack -Scenario $customScenario -Binding $customBinding -PersonaPackFingerprint $hash
                Assert-Equal $identity.Roles.Lead.ObjectId $aliceId
        }
        Test-Case 'approval cannot send as an unbound user Presenter or override Teams author' {
                $cases = @(
                    @{ Workload = 'outlook'; Path = '/users/dddddddd-dddd-4ddd-8ddd-dddddddddddd/sendMail'; Body = @{} },
                    @{ Workload = 'outlook'; Path = "/users/$presenterId/sendMail"; Body = @{} },
                    @{ Workload = 'teams'; Path = "/teams/$aliceId/channels/19:channel@thread.tacv2/messages"; Body = @{ from = @{ user = @{ id = $presenterId } }; body = @{ content = 'Impersonation' } } }
                )
                $index = 0
                foreach ($case in $cases) {
                    $index++; $path = Join-Path $scratch "actor-$index.run-state.json"; $ctx = New-TestContext; $op = New-TestOperation; $op.Workload = $case.Workload; $ops = @($op)
                    New-SeedRunState -Path $path -RunId training01 -Context $ctx -Operations $ops | Out-Null
                    $session = New-TestVerifiedSession (New-GraphStub)
                    $plan = @(Get-SeedOperationPlan -Session $session -Operations $ops -ResourceChecks @{ $case.Workload = { @{ State = 'Absent'; AbsenceVerified = $true; PresenterVerified = $true } } })
                    Assert-Throws { New-SeedWriteApproval -Session $session -Plan $plan -Requests @(@{ OperationId = 'mail-1'; Method = 'POST'; Path = $case.Path; Body = $case.Body }) -ConfirmTarget "$tenant/training01" -StatePath $path -RunId training01 -Context $ctx } 'Seed.Approval.Actor' | Out-Null
                }
            }
        Test-Case 'journal secret scrubbing covers preauthenticated URL keys and encoded query values' {
                foreach ($payload in @(@{ uploadUrl = 'https://example.invalid/private' }, @{ link = 'https://example.invalid/?%73ig=hidden' })) {
                    Assert-Throws { Get-SeedFingerprint $payload } 'Seed.Secret' | Out-Null
                }
        }
        Test-Case 'malformed transport status metadata never leaks unsanitized exception content' {
                    foreach ($field in @('StatusCode', 'RetryAfterSeconds')) {
                        $failure = New-GraphStubError 403
                        $failure.Data[$field] = 'SECRET-password-hidden'
                        $stub = New-GraphStub @{ 'GET /malformed' = @($failure) }; $session = New-TestSession $stub
                        $message = Assert-Throws { Invoke-SeedGraph -Session $session -Method GET -Path '/malformed' } 'Seed.Graph'
                        Assert-True ($message -notmatch 'SECRET|password|hidden')
                        Assert-Equal $stub.Ledger.Count 1
                    }
                }
                Test-Case 'global preflight accepts standard nested JSON objects without noisy method failures' {
                    $binding = New-TestBinding; $stub = New-IdentityStub $binding; $session = New-TestSession $stub
                    $selected = Copy-TestValue $scenario; $selected.Remove('outlook'); $selected.Remove('teams'); $selected.Remove('onedrive')
                    $selected = $selected | ConvertTo-Json -Depth 90 | ConvertFrom-Json
                    $op = New-TestOperation; $op.Workload = 'sharepoint'; $op = $op | ConvertTo-Json -Depth 90 | ConvertFrom-Json
                    $result = Invoke-SeedPreflight -Session $session -Config $config -Personas $pack -Scenario $selected -Binding $binding -PersonaPackFingerprint $hash -Operations @($op) -ResourceChecks @{ sharepoint = { @{ State = 'Absent'; AbsenceVerified = $true; PresenterVerified = $true } } }
                    Assert-True $result.CanImport
                }
        function New-TestExistingConfig([string]$Folder) {
            $c = Copy-TestValue $config
            $c.schemaVersion = '1.1'
            $c.personas = @{ accountSource = 'Existing'; packPath = (Join-Path $Folder 'personas.json'); instanceId = 'training01'; bindingPath = (Join-Path $Folder 'private.binding.json')
                accountMappings = @{ alice = 'existing-alice@example.invalid'; bob = 'existing-bob@example.invalid' } }
            return $c
        }
        function New-TestExistingEvidence([string]$Folder, $ExistingConfig) {
            # Binding plus its Completed BindExisting journal, built with the production binding builder and journal writer.
            $states = @{
                alice = @{ ObjectId = $aliceId; Upn = 'existing-alice@example.invalid'; ManagerObjectId = $null
                    Profile = @{ displayName = 'Alice Existing'; jobTitle = 'Lead'; department = 'Operations'; companyName = 'Fictional Test'; officeLocation = 'Test'; usageLocation = $null } }
                bob = @{ ObjectId = $bobId; Upn = 'existing-bob@example.invalid'; ManagerObjectId = $aliceId
                    Profile = @{ displayName = 'Bob Existing'; jobTitle = 'Analyst'; department = 'Operations'; companyName = 'Fictional Test'; officeLocation = $null; usageLocation = 'TW' } }
            }
            $events = @(foreach ($name in @('alice', 'bob')) {
                @{ sequence = @('alice', 'bob').IndexOf($name); attempt = 0; personaId = $name; kind = 'BindExisting'; status = 'Verified'; objectId = $states[$name].ObjectId; at = '2026-11-07T00:00:00Z'; readBack = $states[$name] }
            })
            $preview = @{ PackId = 'fixture'; PackFingerprint = $hash; Rows = @(@{ PersonaId = 'alice' }, @{ PersonaId = 'bob' }) }
            $binding = New-SeedExistingBinding -Config $ExistingConfig -Preview $preview -States $states -PlanFingerprint ('b' * 64) -JournalFingerprint (Get-SeedFingerprint @{ events = $events }) -At '2026-11-07T00:00:00Z'
            $journal = @{ schemaVersion = '1.1'; accountSource = 'Existing'; status = 'Completed'; plans = @(@{ attempt = 0; fingerprint = ('b' * 64) }); events = $events
                context = @{ tenantId = $tenant; packId = 'fixture'; instanceId = 'training01'; accountSource = 'Existing' }
                boundIds = @{ alice = $aliceId; bob = $bobId }; bindingFingerprint = (Get-SeedFingerprint $binding) }
            $journal.fingerprint = Get-SeedFingerprint $journal
            [IO.File]::WriteAllText($ExistingConfig.personas.bindingPath, ($binding | ConvertTo-Json -Depth 100 -Compress))
            [IO.File]::WriteAllText($ExistingConfig.personas.bindingPath + '.journal.json', ($journal | ConvertTo-Json -Depth 100 -Compress))
            return @{ Binding = $binding; Journal = $journal; States = $states }
        }
        function New-TestExistingStub($Evidence, [hashtable]$Overrides = @{}) {
            $select = 'id,userPrincipalName,displayName,jobTitle,department,companyName,officeLocation,usageLocation,accountEnabled,userType'
            $routes = @{ 'GET /users/presenter%40example.invalid?$select=id,userPrincipalName,accountEnabled,userType' = @(@{ id = $presenterId; userPrincipalName = $config.presenterUpn; accountEnabled = $true; userType = 'Member' }) }
            foreach ($name in @('alice', 'bob')) {
                $s = $Evidence.States[$name]
                $profile = Copy-TestValue $s.Profile
                $profile.id = $s.ObjectId; $profile.userPrincipalName = $s.Upn; $profile.accountEnabled = $true; $profile.userType = 'Member'
                $routes["GET /users/$($s.ObjectId)?`$select=$select"] = @($profile)
                $routes["GET /users/$($s.ObjectId)/manager?`$select=id"] = @($(if ($s.ManagerObjectId) { @{ id = $s.ManagerObjectId } } else { New-GraphStubError 404 }))
            }
            foreach ($key in $Overrides.Keys) { $routes[$key] = $Overrides[$key] }
            New-GraphStub $routes
        }
        Test-Case 'Existing admin session requires exactly read write and role-read scopes while granted extras stay ignored' {
            $existingScopes = @(Get-SeedAdminScopes -Mode InitializePersonas -AccountSource Existing)
            Assert-Equal @($existingScopes | Sort-Object) @('RoleManagement.Read.Directory', 'User.Read.All', 'User.ReadWrite.All')
            Assert-Equal @(Get-SeedAdminScopes InitializePersonas).Count 6
            $folder = Join-Path $scratch 'scopes'; New-Item -ItemType Directory -Path $folder | Out-Null
            $c = New-TestExistingConfig $folder; $c.adminAuth.clientId = $c.clientId
            $extras = @('ProfilePhoto.ReadWrite.All', 'LicenseAssignment.ReadWrite.All', 'Domain.Read.All', 'Mail.Read', 'User.Read')
            $ctx = @{ TenantId = $tenant; ClientId = $c.clientId; Account = $c.adminAuth.adminOperatorUpn; AuthType = 'Delegated'; ContextScope = 'Process'; Scopes = $existingScopes + $extras }
            $stub = New-GraphStub @{
                'GET /me?$select=id,userPrincipalName' = @(@{ id = $aliceId; userPrincipalName = $c.adminAuth.adminOperatorUpn })
                "GET /roleManagement/directory/roleAssignments?`$filter=principalId%20eq%20'$aliceId'&`$expand=roleDefinition" = @(@{ value = @(@{ principalId = $aliceId; directoryScopeId = '/'; roleDefinition = @{ templateId = '62e90394-69f5-4237-9190-012177145e10' } }) })
            }
            $session = Connect-AdminSession -Config $c -Mode InitializePersonas -SdkConnect { param($Options) Assert-Equal @($Options.Scopes | Sort-Object) @('RoleManagement.Read.Directory', 'User.Read.All', 'User.ReadWrite.All') }.GetNewClosure() -SdkContext { $ctx }.GetNewClosure() -SdkRequest $stub.Transport
            try { Assert-Equal @($session.Permissions | Sort-Object) @('RoleManagement.Read.Directory', 'User.Read.All', 'User.ReadWrite.All') } finally { Close-SeedSession $session }
            foreach ($missing in $existingScopes) {
                $ctx.Scopes = @($existingScopes | Where-Object { $_ -cne $missing }) + $extras
                $scopeFailure = $null
                try { Connect-AdminSession -Config $c -Mode InitializePersonas -SdkConnect {} -SdkContext { $ctx }.GetNewClosure() -SdkRequest $stub.Transport | Out-Null } catch { $scopeFailure = $_.Exception }
                Assert-True ($null -ne $scopeFailure -and $scopeFailure.Message -match '^Seed.Auth.Scope:') "Missing $missing must be rejected; got: $($scopeFailure.Message) $($scopeFailure.Data['SeedAuthDiagnostic'] | ConvertTo-Json -Compress)"
                Assert-Equal @($scopeFailure.Data['SeedAuthDiagnostic'].MissingScopes) @($missing)
            }
            $ctx.Scopes = $existingScopes
            $managedConfig = Copy-TestValue $config; $managedConfig.adminAuth.clientId = $managedConfig.clientId
            $managedFailure = $null
            try { Connect-AdminSession -Config $managedConfig -Mode InitializePersonas -SdkConnect {} -SdkContext { $ctx }.GetNewClosure() -SdkRequest $stub.Transport | Out-Null } catch { $managedFailure = $_.Exception }
            Assert-True ($null -ne $managedFailure -and $managedFailure.Message -match '^Seed.Auth.Scope:') "Managed needs its six scopes; got: $($managedFailure.Message) $($managedFailure.Data['SeedAuthDiagnostic'] | ConvertTo-Json -Compress) ctx=$($ctx | ConvertTo-Json -Compress) cfg=$($managedConfig.adminAuth | ConvertTo-Json -Compress)"
        }
        Test-Case 'Existing binding with null actual fields resolves real actors read-only with exact source evidence' {
            $folder = Join-Path $scratch 'existing-identity'; New-Item -ItemType Directory -Path $folder | Out-Null
            $c = New-TestExistingConfig $folder; $evidence = New-TestExistingEvidence $folder $c
            $stub = New-TestExistingStub $evidence; $session = New-TestSession $stub
            $existingPack = Get-Content -LiteralPath (Join-Path $root 'tests\fixtures\existing-personas.json') -Raw | ConvertFrom-Json -AsHashtable
            $identity = Resolve-SeedIdentityContext -Session $session -Config $c -Personas $existingPack -Scenario $scenario -Binding $evidence.Binding -PersonaPackFingerprint $hash
            Assert-Equal $identity.Roles.Lead.ObjectId $aliceId
            Assert-Equal $identity.Roles.Lead.AccountSource 'Existing'
            Assert-Equal $identity.Roles.Lead.Provenance 'ConfiguredExistingBindingAndReadBack'
            Assert-Equal $identity.Roles.Analyst.ProfileFingerprint $evidence.Binding.users.bob.profile.sha256
            Assert-Equal $identity.Presenter.ObjectId $presenterId
            Assert-Equal $stub.Ledger.Count 5
            Assert-True (@($stub.Ledger | Where-Object Method -ne GET).Count -eq 0)
        }
        Test-Case 'Existing binding rejects fake Provisioned bare mapping missing partial or tampered journal and swapped identity before Graph' {
            $existingPack = Get-Content -LiteralPath (Join-Path $root 'tests\fixtures\existing-personas.json') -Raw | ConvertFrom-Json -AsHashtable
            $index = 0
            foreach ($kind in @('fake-provisioned', 'no-journal', 'partial', 'tampered', 'swapped-id', 'mapping', 'target', 'needs-more-people')) {
                $index++; $folder = Join-Path $scratch "existing-reject-$index"; New-Item -ItemType Directory -Path $folder | Out-Null
                $c = New-TestExistingConfig $folder; $evidence = New-TestExistingEvidence $folder $c
                $binding = Copy-TestValue $evidence.Binding; $pack2 = Copy-TestValue $existingPack; $scenario2 = Copy-TestValue $scenario
                $journalPath = $c.personas.bindingPath + '.journal.json'
                switch ($kind) {
                    'fake-provisioned' { $binding = New-TestBinding }
                    'no-journal' { Remove-Item -LiteralPath $journalPath }
                    'partial' { $j = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json -AsHashtable; $j.Remove('fingerprint'); $j.status = 'Blocked'; $j.fingerprint = Get-SeedFingerprint $j; [IO.File]::WriteAllText($journalPath, ($j | ConvertTo-Json -Depth 100 -Compress)) }
                    'tampered' { $j = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json -AsHashtable; $j.events[0].objectId = $bobId; [IO.File]::WriteAllText($journalPath, ($j | ConvertTo-Json -Depth 100 -Compress)) }
                    'swapped-id' { $binding.users.alice.objectId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd' }
                    'mapping' { $c.personas.accountMappings.alice = 'someone-else@example.invalid' }
                    'target' { $pack2.people[0].profile.jobTitle = 'A different approved target' }
                    'needs-more-people' { $scenario2.roles.Analyst.personaId = 'carol'; $pack2.people += @{ personaId = 'carol'; profile = @{ jobTitle = 'Extra' } } }
                }
                $stub = New-GraphStub; $session = New-TestSession $stub
                $failure = Assert-Throws { Resolve-SeedIdentityContext -Session $session -Config $c -Personas $pack2 -Scenario $scenario2 -Binding $binding -PersonaPackFingerprint $hash } 'Seed.Binding'
                if ($kind -eq 'needs-more-people') { Assert-True ($failure -match 'needs 2 distinct selected people but only 1 are bound; 1 more') }
                Assert-Equal $stub.Ledger.Count 0
            }
        }
        Test-Case 'Existing actual profile with a missing field or wrong type is blocked rather than defaulted' {
            $existingPack = Get-Content -LiteralPath (Join-Path $root 'tests\fixtures\existing-personas.json') -Raw | ConvertFrom-Json -AsHashtable
            $index = 0
            foreach ($kind in @('missing-field', 'wrong-type', 'changed-id', 'drift')) {
                $index++; $folder = Join-Path $scratch "existing-actual-$index"; New-Item -ItemType Directory -Path $folder | Out-Null
                $c = New-TestExistingConfig $folder; $evidence = New-TestExistingEvidence $folder $c
                $select = 'id,userPrincipalName,displayName,jobTitle,department,companyName,officeLocation,usageLocation,accountEnabled,userType'
                $bad = Copy-TestValue $evidence.States.alice.Profile
                $bad.id = $aliceId; $bad.userPrincipalName = 'existing-alice@example.invalid'; $bad.accountEnabled = $true; $bad.userType = 'Member'
                switch ($kind) { 'missing-field' { $bad.Remove('officeLocation') } 'wrong-type' { $bad.jobTitle = 7 } 'changed-id' { $bad.id = $bobId } 'drift' { $bad.officeLocation = 'Moved' } }
                $routes = @{ "GET /users/$aliceId`?`$select=$select" = @($bad); "GET /users/$aliceId/manager?`$select=id" = @(New-GraphStubError 404) }
                $stub = New-TestExistingStub $evidence $routes; $session = New-TestSession $stub
                Assert-Throws { Resolve-SeedIdentityContext -Session $session -Config $c -Personas $existingPack -Scenario $scenario -Binding $evidence.Binding -PersonaPackFingerprint $hash } 'Seed.Identity.Profile' | Out-Null
                Assert-Equal @($stub.Ledger | Where-Object Method -ne GET).Count 0
            }
        }
    } finally {
        foreach ($record in @($script:SeedSessions.Values)) { Close-SeedSession $record.Handle }
        Remove-Item -LiteralPath $scratch -Recurse -Force
    }
}

$areas = if ($Area -eq 'All') { @('Identity', 'Personas', 'Storage', 'Outlook', 'Teams', 'Console') } else { @($Area) }
foreach ($selected in $areas) {
    $testFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -File | Where-Object { $_.Name -match "^$selected(?:\..+)?\.Tests\.ps1$" } | Sort-Object Name)
    foreach ($testFile in $testFiles) { . $testFile.FullName }
}
Write-Host "RESULT Passed=$script:Passed Failed=$script:Failed Area=$Area NetworkAttempts=$script:NetworkAttempts"
if ($script:Failed -gt 0 -or $script:NetworkAttempts -gt 0) { exit 1 }
