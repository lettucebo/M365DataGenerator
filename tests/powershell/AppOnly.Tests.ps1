Test-Case 'app-only token renewal preserves handle mode and rejects before capability or transport' {
    $stub = New-GraphStub
    $s = New-TestSession $stub @{} Import
    $record = Get-SeedSessionRecord $s
    $auth = $record.AppAuth; $state = @{ Calls = 0; Guards = 0 }
    $token = New-TestToken
    $auth.Acquire = { $state.Calls++; $token }.GetNewClosure()
    $auth.ExpiresAt = 0
    Assert-SeedAppSessionReady $s
    Assert-Equal $state.Calls 1
    Assert-True ([object]::ReferenceEquals($record.Handle,$s))
    Assert-Equal $s.Mode Import
    $auth.ExpiresAt = 0
    $auth.Acquire = { throw 'sensitive renewal failure' }
    $record.PersonaWriteGuard = { $state.Guards++ }.GetNewClosure()
    Assert-Throws { Invoke-SeedGraph -Session $s -Method POST -Path '/users' -Body @{} -AdminCapability ([object]::new()) } 'Seed.Auth.Acquire' | Out-Null
    Assert-Equal $state.Guards 0
    Assert-Equal $stub.Ledger.Count 0
    $auth.Acquire = { New-TestToken @{ roles = @('Unrelated.Extra') } }
    Assert-Throws { Assert-SeedAppSessionReady $s } 'Seed.Auth.Roles' | Out-Null
    Assert-Equal $stub.Ledger.Count 0
}
Test-Case 'app-only all six modes reject foreign or delegated tokens and ignore extra grants' {
    $c = Copy-TestValue $config; $c.adminAuth.clientId = $c.clientId
    foreach ($mode in @('InspectUsers','InitializePersonas','Preflight','Verify','Import','RunAll')) {
        $roles = @('User.ReadWrite.All','Domain.Read.All','LicenseAssignment.Read.All','Extra.Ignored')
        $token = New-TestToken @{ roles = $roles }
        $s = Connect-SeedSession -Config $c -Mode $mode -TokenProvider { $token }.GetNewClosure() -Transport {}
        Assert-Equal $s.Kind App
        Assert-Throws { Invoke-SeedGraph -Session $s -Method POST -Path '/users' -Body @{} } 'Seed.Write' | Out-Null
        Assert-Throws { Invoke-SeedGraph -Session $s -Method PATCH -Path "/users/$aliceId" -Body @{} -AdminCapability ([object]::new()) } 'Seed.Write' | Out-Null
        foreach ($change in @(@{ tid = $client },@{ appid = $tenant },@{ aud = 'foreign' },@{ iss = 'foreign' },@{ scp = 'User.Read' },@{ exp = 1 })) {
            $bad = New-TestToken $change
            $provider = { $bad }.GetNewClosure()
            Assert-Throws { Connect-SeedSession -Config $c -Mode $mode -TokenProvider $provider -Transport {} } 'Seed.Auth.Token' | Out-Null
        }
    }
    $c.adminAuth.clientId = $tenant
    Assert-Throws { Connect-SeedSession -Config $c -Mode InspectUsers -TokenProvider {} -Transport {} } 'Seed.Auth.Migration' | Out-Null
}
Test-Case 'app-only management fixed substitutions report every missing prerequisite without SDK reads' {
    Assert-Equal @(Get-SeedManagementAppRoles InspectUsers) @('User.Read.All')
    Assert-Equal @(Get-SeedManagementAppRoles InitializePersonas -AccountSource Existing) @('User.ReadWrite.All')
    foreach ($required in @('User.Read.All','ProfilePhoto.ReadWrite.All','LicenseAssignment.ReadWrite.All')) {
        Assert-True (Test-SeedAppPermission -Granted @('User.ReadWrite.All') -Required $required)
        Assert-True (-not (Test-SeedAppPermission -Granted @('Directory.ReadWrite.All') -Required $required))
    }
    $token = New-TestToken @{ roles = @('User.ReadWrite.All','Extra.Ignored') }
    $provider = { $token }.GetNewClosure()
    $message = Assert-Throws { Connect-SeedSession -Config $config -Mode InitializePersonas -TokenProvider $provider -Transport { throw 'must not send' } } 'Seed.Auth.Roles'
    Assert-True ($message -match 'Domain.Read.All' -and $message -match 'LicenseAssignment.Read.All')
}
Test-Case 'app-only actual HTTP photo transport preserves JPEG authorization no redirect errors and exact raw content type' {
    $name = $config.clientSecretEnvironmentVariable
    $prior = [Environment]::GetEnvironmentVariable($name,'Process')
    [Environment]::SetEnvironmentVariable($name,'offline-fixture-not-a-credential','Process')
    try {
        $token = New-TestToken @{ roles = @('User.ReadWrite.All','Domain.Read.All','LicenseAssignment.Read.All') }
        $state = @{ Calls = [Collections.Generic.List[object]]::new(); Status = 200 }
        $bytes = [byte[]]@(255,216,0,128,255,217)
        $send = {
            param($options)
            if ($options.Uri -like 'https://login.microsoftonline.com/*') { return @{ access_token = $token } }
            $state.Calls.Add($options)
            if ($options.Method -ceq 'GET') {
                $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]$state.Status)
                $response.Content = [Net.Http.ByteArrayContent]::new($bytes)
                return $response
            }
        }.GetNewClosure()
        $s = Connect-SeedSession -Config $config -Mode InitializePersonas -Send $send
        $path = "/users/$aliceId/photo/`$value"
        $actual = Invoke-SeedGraph -Session $s -Method GET -Path $path
        Assert-True ($actual -is [byte[]]); Assert-Equal $actual $bytes
        $record = Get-SeedSessionRecord $s
        # Exercise the production transport's PUT assembly; persona authorization is covered by the complete batch tests.
        & $record.Transport PUT $path $null $bytes
        Assert-Equal $state.Calls[-1].ContentType 'image/jpeg'
        & $record.Transport PUT "/drives/drive/items/item/content" $null $bytes
        Assert-Equal $state.Calls[-1].ContentType 'application/octet-stream'
        foreach ($call in $state.Calls) {
            Assert-Equal $call.Headers.Authorization "Bearer $token"
            Assert-Equal $call.MaximumRedirection 0
        }
        $state.Status = 404
        Assert-Throws { Invoke-SeedGraph -Session $s -Method GET -Path $path } 'Seed.Graph.404' | Out-Null
        $state.Status = 302
        Assert-Throws { Invoke-SeedGraph -Session $s -Method GET -Path $path } 'Seed.Graph.302' | Out-Null
        Assert-Throws { Connect-SeedSession -Config $config -Send $send -TokenProvider {} -Transport {} } 'Seed.Injection' | Out-Null
    } finally { [Environment]::SetEnvironmentVariable($name,$prior,'Process') }
}
