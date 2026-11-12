$teamsScratch = Join-Path $root ('tests\.scratch\t5-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $teamsScratch -Force | Out-Null
foreach ($file in @('Seed-OneDriveOwnership', 'Invoke-SeedSharePoint', 'Invoke-UploadFiles', 'Invoke-SeedEmails', 'Invoke-SeedTeamsChannel')) {
    $path = Join-Path $root "engine\$file.ps1"
    if (Test-Path -LiteralPath $path) { . $path }
}
function Copy-TeamsValue($v) { $v | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -DateKind String }
function New-TeamsEnvironment([string]$InputFault = '', [switch]$WithAssets, [string[]]$GrantedRoles = @(), [string]$Title = '') {
    $dir = Join-Path $teamsScratch ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    foreach ($f in @('personas.json', 'alice.jpg', 'bob.jpg', 'rights.txt')) { Copy-Item (Join-Path $root "tests\fixtures\$f") $dir }
    $p = Get-Content (Join-Path $dir 'personas.json') -Raw | ConvertFrom-Json -AsHashtable
    $p.people[1].displayName = 'Bob & <分析>'
    $p | ConvertTo-Json -Depth 100 | Set-Content (Join-Path $dir 'personas.json') -Encoding utf8
    $s = Get-Content (Join-Path $root 'tests\fixtures\scenario.json') -Raw | ConvertFrom-Json -AsHashtable
    foreach ($k in @('outlook', 'sharepoint')) { $s.Remove($k) }
    if ($WithAssets) {
        $s.onedrive.drives[0].ownerRole = 'Presenter'
        $s.teams.channels[0].messages[0].assetRefs = @('metrics')
        $s.teams.channels[0].messages[0].bodyHtml += '<p><a href="{{asset:metrics}}">Metrics</a></p>'
    } else { $s.Remove('onedrive'); $s.Remove('workbooks'); $s.assets = @() }
    $channel = Copy-TeamsValue $s.teams.channels[0]
    $channel.id = 'decisions'; $channel.displayName = 'Decisions'
    $channel.messages[0].id = 'decision'; $channel.messages[0].replies[0].id = 'decision-reply'
    $s.teams.channels += $channel
    switch ($InputFault) {
        Duplicate { $s.teams.channels[1].messages[0].id = 'post' }
        Unknown { $s.teams.channels[0].messages[0].fromRole = 'Unknown' }
        Future {
            $s.scenario.anchorDate = [DateTimeOffset]::UtcNow.AddDays(3).ToString('yyyy-MM-dd')
            $s.teams.channels[0].messages[0].createdDateTime = [DateTimeOffset]::UtcNow.AddDays(1).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
            $s.teams.channels[0].messages[0].replies[0].createdDateTime = [DateTimeOffset]::UtcNow.AddDays(2).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        }
        Fractional { $s.teams.channels[0].messages[0].createdDateTime = '2026-10-29T02:00:00.00000001Z' }
        NoPresenter {
            foreach ($channel in $s.teams.channels) { $channel.memberRoles = @('Lead', 'Analyst') }
        }
    }
    if ($Title) { $s.scenario.title = $Title }
    $s | ConvertTo-Json -Depth 100 | Set-Content (Join-Path $dir 'scenario.json') -Encoding utf8
    # Invalid semantic inputs deliberately remain unprepared; adapter must not accept them.
    if ($InputFault -in @('Duplicate', 'Unknown')) {
        return @{ Scenario = $s; PreparedPath = (Join-Path $dir 'unprepared'); Dir = $dir }
    }
    & (Join-Path $root '.venv\Scripts\python.exe') (Join-Path $root 'generator\build_scenario.py') --pack (Join-Path $dir 'scenario.json') --personas (Join-Path $dir 'personas.json') --output (Join-Path $dir 'prepared') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Teams fixture build failed.' }
    $s = Get-Content (Join-Path $dir 'prepared\scenario.json') -Raw | ConvertFrom-Json -AsHashtable -DateKind String
    $m = Get-Content (Join-Path $dir 'prepared\prepared-manifest.json') -Raw | ConvertFrom-Json -AsHashtable
    $c = Get-Content (Join-Path $root 'tests\fixtures\managed-config.json') -Raw | ConvertFrom-Json -AsHashtable
    $ids = @{ alice = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'; bob = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'; Presenter = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc' }
    $binding = @{ tenantId = $c.tenantId; packId = $p.packId; version = '1.0'; fingerprint = $m.personaPackFingerprint; instanceId = 'training01'; users = @{}; status = 'Provisioned'; serviceStatus = 'NotVerified' }
    $model = @{ Ledger = [Collections.Generic.List[object]]::new(); Profiles = @{}; Upns = @{}; Ids = $ids
        Group = $null; Team = $null; Channels = @{}; Messages = @{}; Members = @{}; GroupMembers = @{}; Owners = @(); CompletedChannels = @()
        CompletedTeam = $false; Fault = ''; Counter = 0; StatePath = Join-Path $dir 'teams.run-state.json'; Items = @{}; Uploads = @{} }
    $model.Items.root = @{ id = 'root'; name = 'root'; folder = @{}; parentReference = @{ driveId = 'drive' }; webUrl = 'https://example.sharepoint.com/personal/p/Documents' }
    foreach ($person in $p.people) {
        $profile = @{ usageLocation = 'TW'; managerObjectId = $(if ($person.managerRef) { $ids[$person.managerRef] } else { $null }) }
        foreach ($f in @('displayName', 'jobTitle', 'department', 'companyName', 'officeLocation')) { $profile[$f] = $person[$f] }
        $profile.sha256 = Get-SeedFingerprint $profile; $profile.verifiedAt = '2026-10-29T00:00:00Z'
        $photo = @($p.avatarAssets | Where-Object id -eq $person.avatarAssetId)[0]
        $upn = "demo-$($person.alias)@example.invalid"
        $binding.users[$person.personaId] = @{ objectId = $ids[$person.personaId]; upn = $upn; profile = $profile
            photo = @{ avatarAssetId = $photo.id; sourceSha256 = $photo.sha256; verifiedSha256 = ('a' * 64); verifiedAt = '2026-10-29T00:00:00Z' }
            license = @{ profileId = 'standard'; skuIds = @($c.personas.licenseProfiles.standard.skuIds); verifiedAt = '2026-10-29T00:00:00Z' }
            status = 'Provisioned'; serviceStatus = 'NotVerified' }
        $model.Profiles[$ids[$person.personaId]] = $profile; $model.Upns[$ids[$person.personaId]] = $upn
    }
    $model.Upns[$ids.Presenter] = $c.presenterUpn
    $transport = {
        param($Method, $Path, $Body, $RawBody)
        $model.Ledger.Add(@{ Method = $Method; Path = $Path; Body = $(if ($null -ne $Body) { Copy-TeamsValue $Body } else { $null }) })
        if ($Method -ne 'GET') {
            $j = Get-Content $model.StatePath -Raw | ConvertFrom-Json -AsHashtable
            if ($j.events[-1].action -cne 'Submit') { throw 'Missing durable Submit.' }
            if ($model.Fault -eq 'Lost') { throw (New-GraphStubError 504) }
        }
        if ($Method -eq 'GET' -and $Path -match '^/users/([^/?]+)(.*)$') {
            $id = [uri]::UnescapeDataString($Matches[1]); $tail = $Matches[2]
            if ($tail.StartsWith('/drive')) { return @{ id = 'drive'; owner = @{ user = @{ id = $model.Ids.Presenter } } } }
            if ($id -eq $c.presenterUpn -or $id -eq $model.Ids.Presenter) {
                return @{ id = $model.Ids.Presenter; userPrincipalName = $c.presenterUpn; displayName = 'Presenter & Owner'; accountEnabled = $true; userType = 'Member' }
            }
            if ($tail.StartsWith('/manager')) {
                if (-not $model.Profiles[$id].managerObjectId) { throw (New-GraphStubError 404) }
                return @{ id = $model.Profiles[$id].managerObjectId }
            }
            $v = Copy-TeamsValue $model.Profiles[$id]
            foreach ($k in @('sha256', 'verifiedAt', 'managerObjectId')) { $v.Remove($k) }
            $v.id = $id; $v.userPrincipalName = $model.Upns[$id]; $v.accountEnabled = $true; $v.userType = 'Member'
            if ($model.Fault -eq 'Profile') { $v.displayName = 'Wrong' }
            return $v
        }
        if ($Path -eq '/drives/drive/root') { return Copy-TeamsValue $model.Items.root }
        if ($Path -match '^/drives/drive/items/([^/:?]+)(.*)$') {
            $id = $Matches[1]; $tail = $Matches[2]
            if ($tail -eq '/children') {
                if ($Method -eq 'GET') { return @{ value = @($model.Items.Values | Where-Object { $_.parentReference.ContainsKey('id') -and $_.parentReference.id -ceq $id }) } }
                $model.Counter++; $key = "folder-$($model.Counter)"
                $model.Items[$key] = @{ id = $key; name = $Body.name; folder = @{}; parentReference = @{ id = $id; driveId = 'drive' }; webUrl = "https://example.sharepoint.com/files/$key" }
                return @{ id = $key }
            }
            if ($tail -match '^:/([^/]+):/createUploadSession$' -and $Method -eq 'POST') {
                $model.Uploads.allocation = @{ Parent = $id; Name = [uri]::UnescapeDataString($Matches[1]) }
                return @{ uploadUrl = 'https://example.sharepoint.com/upload?sig=private'; expirationDateTime = [DateTimeOffset]::UtcNow.AddHours(1).ToString('o'); nextExpectedRanges = @('0-') }
            }
            if ($tail -eq '/permissions') { return @{ value = @(@{ roles = @('owner'); grantedToV2 = @{ user = @{ id = $model.Ids.Presenter } } }) } }
            return Copy-TeamsValue $model.Items[$id]
        }
        if ($Path -match '^/groups\?') {
            $values = @()
            if ($null -ne $model.Group) { $values = @((Copy-TeamsValue $model.Group)) }
            if ($model.Fault -eq 'DuplicateGroup') { $values += (Copy-TeamsValue $model.Group) }
            if ($model.Fault -eq 'Pagination') { return @{ value = @(); '@odata.nextLink' = 'https://foreign.invalid/v1.0/groups' } }
            return @{ value = $values }
        }
        if ($Path -eq '/teams' -and $Method -eq 'POST') {
            if ($null -ne $model.Team) { throw 'Cannot adopt existing team.' }
            if ($Body.'@microsoft.graph.teamCreationMode' -cne 'migration') { throw 'Initial migration mode required.' }
            $tid = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'
            $model.Group = @{ id = $tid; displayName = $Body.displayName; description = $Body.description; groupTypes = @('Unified'); visibility = 'Private'; resourceProvisioningOptions = @('Team') }
            $model.Team = @{ id = $tid; displayName = $Body.displayName; description = $Body.description; createdDateTime = $Body.createdDateTime; webUrl = "https://teams.microsoft.com/l/team/actual?groupId=$tid" }
            $model.Channels.primary = @{ id = 'primary'; displayName = 'General'; description = ''; membershipType = 'standard'; migrationMode = 'inProgress'; createdDateTime = $Body.createdDateTime; webUrl = 'https://teams.microsoft.com/l/channel/primary/General' }
            return $null # Official asynchronous 202 with no decoded JSON body.
        }
        if ($Path -match '^/groups/[^/?]+(.*)$') {
            $tail = $Matches[1]
            if ($tail -match '^/owners/\$ref$' -and $Method -eq 'POST') {
                if (-not $model.CompletedTeam) { throw 'Ownership before migration completion.' }
                $model.Owners += ($Body.'@odata.id' -split '/')[-1]; return $null
            }
            if ($tail.StartsWith('/owners')) {
                $owners = $(if ($model.Fault -eq 'Owner') { @() } else { @($model.Owners) })
                return @{ value = @($owners | ForEach-Object { @{ id = $_ } }) }
            }
            if ($tail -ceq '/members/$ref' -and $Method -ceq 'POST') {
                if (-not $model.CompletedTeam) { throw 'Group membership before migration completion.' }
                $uid = ($Body.'@odata.id' -split '/')[-1]
                if ($model.GroupMembers.ContainsKey($uid)) { throw 'Group member already added.' }
                $model.GroupMembers[$uid] = @{ id = $uid }
                return $null
            }
            if ($tail.StartsWith('/members')) {
                if ($model.Fault -ceq 'GroupMemberDelay') { return @{ value = @() } }
                $values = @($model.GroupMembers.Values | ForEach-Object { Copy-TeamsValue $_ })
                if ($model.Fault -ceq 'DuplicateGroupMember') { $values += $values[0] }
                if ($model.Fault -ceq 'MalformedGroupMember') { $values += @{ id = $null } }
                return @{ value = $values }
            }
            return Copy-TeamsValue $model.Group
        }
        if ($Path -match '^/teams/[^/?]+(.*)$') {
            $tail = $Matches[1]
            if ($tail -eq '/completeMigration' -and $Method -eq 'POST') {
                if ($model.CompletedChannels.Count -ne $model.Channels.Count) { throw 'Both migration levels required, including General.' }
                $model.CompletedTeam = $true; return $null
            }
            if ($tail -eq '/primaryChannel') {
                $v = Copy-TeamsValue $model.Channels.primary
                if ($model.Fault -eq 'ChannelTime') { $v.createdDateTime = '2026-10-30T00:00:00Z' }
                return $v
            }
            if ($tail -match '^/members(?:\?|$)') {
                if ($Method -eq 'GET') {
                    $v = @($model.Members.Values | ForEach-Object { Copy-TeamsValue $_ })
                    if ($model.Fault -eq 'Membership') { $v = @($v | Where-Object userId -NE $model.Ids.bob) }
                    return @{ value = $v }
                }
                if (-not $model.CompletedTeam) { throw 'Membership while still migrating.' }
                $uid = ($Body.'user@odata.bind' -split '/')[-1]
                if ($uid -cne $model.Ids.Presenter -and -not $model.Members.ContainsKey($model.Ids.Presenter)) { throw 'Presenter must already be an actual Team owner before adding actors.' }
                $model.Members[$uid] = @{ id = "member-$uid"; userId = $uid; tenantId = $c.tenantId; roles = @($Body.roles) }
                return Copy-TeamsValue $model.Members[$uid]
            }
            if ($tail -match '^/channels(?:\?|$)') {
                if ($Method -eq 'GET') { return @{ value = @($model.Channels.Values | ForEach-Object { Copy-TeamsValue $_ }) } }
                if ($model.CompletedTeam -or $Body.'@microsoft.graph.channelCreationMode' -cne 'migration' -or $Body.membershipType -cne 'standard') { throw 'Standard migration channels only.' }
                $model.Counter++; $cid = "channel-$($model.Counter)"
                $model.Channels[$cid] = @{ id = $cid; displayName = $Body.displayName; description = $Body.description; membershipType = 'standard'; migrationMode = 'inProgress'; createdDateTime = $Body.createdDateTime; webUrl = "https://teams.microsoft.com/l/channel/$cid/Decisions" }
                return Copy-TeamsValue $model.Channels[$cid]
            }
            if ($tail -match '^/channels/([^/?]+)(.*)$') {
                $cid = [uri]::UnescapeDataString($Matches[1]); $rest = $Matches[2]
                if ($rest -eq '/completeMigration' -and $Method -eq 'POST') {
                    if ($model.Fault -in @('LostThirdCompletionAck', 'IncompleteCompletion')) {
                        if (-not $model.ContainsKey('CompletionAttempts')) { $model.CompletionAttempts = 0 }
                        $model.CompletionAttempts++
                        if ($model.Fault -ceq 'IncompleteCompletion' -or $model.CompletionAttempts -lt 3) {
                            throw (New-GraphStubError 502)
                        }
                        $model.CompletedChannels += $cid
                        $model.Channels[$cid].migrationMode = 'completed'
                        if ($model.CompletionAttempts -eq 3) { throw (New-GraphStubError 502) }
                        return $null
                    }
                    if ($model.Fault -ceq 'RetryableComplete' -and -not $model.ContainsKey('CompletionFaultSeen')) {
                        $model.CompletionFaultSeen = $true
                        throw (New-GraphStubError 502)
                    }
                    $model.CompletedChannels += $cid
                    $model.Channels[$cid].migrationMode = 'completed'
                    if ($model.Fault -in @('LostCompletionAck', 'MissingCompletionMode') -and -not $model.ContainsKey('CompletionFaultSeen')) {
                        $model.CompletionFaultSeen = $true
                        throw (New-GraphStubError 502)
                    }
                    return $null
                }
                if ($rest -match '^/messages(?:/([^/?]+)/replies)?(?:/([^/?]+))?(?:\?.*)?$') {
                    $parent = $Matches[1]; $detail = $Matches[2]
                    if (-not $parent -and $detail) { $mid = $detail; $parent = '' } else { $mid = $detail }
                    if ($Method -eq 'POST') {
                        if ($cid -in $model.CompletedChannels -or $model.CompletedTeam) { throw 'Posting after completion.' }
                        if ($parent -and -not $model.Messages.ContainsKey($parent)) { throw 'Unknown actual root.' }
                        $model.Counter++; $mid = "message-$($model.Counter)"
                        $v = Copy-TeamsValue $Body
                        $v.id = $mid; $v.replyToId = $(if ($parent) { $parent } else { $null }); $v.webUrl = "https://teams.microsoft.com/l/message/$cid/$mid"
                        $v.channelIdentity = @{ teamId = $model.Team.id; channelId = $cid }
                        $v.messageType = 'message'; $v.deletedDateTime = $null
                        $model.Messages[$mid] = $v
                        if ($model.Fault -eq 'LostRoot') { throw (New-GraphStubError 504) }
                        return Copy-TeamsValue $v
                    }
                    $values = @($model.Messages.Values | Where-Object { $_.channelIdentity.channelId -ceq $cid -and $_.replyToId -ceq $(if ($parent) { $parent } else { $null }) })
                    if ($mid) {
                        $v = Copy-TeamsValue $model.Messages[$mid]
                        switch ($model.Fault) {
                            Actor { $v.from.user.id = $model.Ids.bob }
                            Content { $v.body.content += '<p>Changed decision.</p>' }
                            Time { $v.createdDateTime = '2026-10-28T00:00:00Z' }
                            Mention { if ($v.mentions.Count) { $v.mentions[0].mentioned.user.id = $model.Ids.alice } }
                            Parent { $v.replyToId = 'foreign-root' }
                            Link { $v.webUrl = '' }
                        }
                        return $v
                    }
                    if ($model.Fault -ceq 'DelayedCollections' -and $values.Count) {
                        if (-not $model.ContainsKey('CollectionPolls')) { $model.CollectionPolls = @{} }
                        $pollKey = "$cid/$parent"
                        if (-not $model.CollectionPolls.ContainsKey($pollKey)) { $model.CollectionPolls[$pollKey] = 0 }
                        $model.CollectionPolls[$pollKey]++
                        if ($model.CollectionPolls[$pollKey] -lt 9) { return @{ value = @() } }
                    }
                    if ($model.Fault -in @('SystemLifecycleEvents', 'UserLifecycleEvent', 'ForeignLifecycleEvent') -and -not $parent) {
                        $system = @{
                            id = "system-$cid"; messageType = 'unknownFutureValue'; replyToId = $null; from = $null
                            eventDetail = @{ '@odata.type' = '#microsoft.graph.channelAddedEventMessageDetail' }
                            channelIdentity = @{ teamId = $model.Team.id; channelId = $cid }
                        }
                        if ($model.Fault -ceq 'UserLifecycleEvent') { $system.from = @{ user = @{ id = $model.Ids.alice } } }
                        if ($model.Fault -ceq 'ForeignLifecycleEvent') { $system.channelIdentity.channelId = 'foreign' }
                        $values += $system
                    }
                    if ($model.Fault -eq 'ExtraMessage' -and $values.Count) { $extra = Copy-TeamsValue $values[0]; $extra.id = 'unplanned'; $values += $extra }
                    return @{ value = @($values | ForEach-Object { Copy-TeamsValue $_ }) }
                }
                $channelResult = Copy-TeamsValue $model.Channels[$cid]
                if ($model.Fault -ceq 'MissingCompletionMode' -and $rest.Contains('migrationMode')) { $channelResult.Remove('migrationMode') }
                return $channelResult
            }
            $v = Copy-TeamsValue $model.Team
            if ($model.Fault -eq 'TeamTime') { $v.createdDateTime = '2026-10-30T00:00:00Z' }
            return $v
        }
        throw "Unconfigured offline Teams request: $Method $Path"
    }.GetNewClosure()
    $claims = @{ tid = $c.tenantId; appid = $c.clientId; aud = 'https://graph.microsoft.com'; iss = "https://sts.windows.net/$($c.tenantId)/"; exp = [DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds()
        roles = @('User.Read.All', 'Team.Create', 'Teamwork.Migrate.All', 'TeamMember.ReadWrite.All', 'Group.ReadWrite.All', 'Team.ReadBasic.All', 'Channel.ReadBasic.All', 'ChannelMessage.Read.All', 'Files.ReadWrite.All') }
    if ($GrantedRoles.Count -gt 0) { $claims.roles = $GrantedRoles }
    $encode = { param($v) [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($v | ConvertTo-Json -Compress))).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
    $jwt = "$(& $encode @{ alg = 'RS256' }).$(& $encode $claims).offline"
    $upload = {
        param($Url, $Bytes, $Headers)
        if ($null -eq $Bytes) { return @{ expirationDateTime = [DateTimeOffset]::UtcNow.AddHours(1).ToString('o'); nextExpectedRanges = @('0-') } }
        $j = Get-Content $model.StatePath -Raw | ConvertFrom-Json -AsHashtable
        if ($j.events[-1].action -cne 'Submit') { throw 'Missing durable upload Submit.' }
        $a = $model.Uploads.allocation
        $model.Items.asset = @{ id = 'asset'; name = $a.Name; size = $Bytes.Length; eTag = 'file-v1'; cTag = 'content-v1'
            parentReference = @{ id = $a.Parent; driveId = 'drive' }; webUrl = 'https://example.sharepoint.com/files/actual&metrics.xlsx'
            file = @{ hashes = @{ sha256Hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant() } } }
        return Copy-TeamsValue $model.Items.asset
    }.GetNewClosure()
    $session = Connect-SeedSession -Config $c -Mode Import -TokenProvider { $jwt }.GetNewClosure() -Transport $transport -Delay { param($Seconds) } -UploadTransport $upload
    $identity = Resolve-SeedIdentityContext -Session $session -Config $c -Personas $p -Scenario $s -Binding $binding -PersonaPackFingerprint $m.personaPackFingerprint
    Test-SeedServices -Session $session -Scenario $s -IdentityContext $identity | Out-Null
    $context = @{ tenantId = $c.tenantId; clientId = $c.clientId; scenarioId = $s.scenario.id; personaPackId = $p.packId
        personaPackFingerprint = $m.personaPackFingerprint; instanceId = 'training01'; bindingFingerprint = $identity.BindingFingerprint
        preparedFingerprint = $m.fingerprint; presenterUpn = $c.presenterUpn }
    return @{ Session = $session; Model = $model; Scenario = $s; Context = $context; Config = $c; PreparedPath = (Join-Path $dir 'prepared'); StatePath = $model.StatePath }
}
function Get-TeamsTestAdapter($e, [string]$RunId = 'training01') {
    Get-SeedTeamsAdapter -Session $e.Session -Scenario $e.Scenario -PreparedPath $e.PreparedPath -Context $e.Context -RunId $RunId -StatePath $e.StatePath
}
function Start-TeamsTestRun($e, $a) {
    $plan = @(Get-SeedOperationPlan -Session $e.Session -Operations $a.Operations -ResourceChecks $a.ResourceChecks)
    Assert-Equal @($plan | Where-Object Action -eq Block).Count 0
    New-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $a.Operations | Out-Null
    New-SeedWriteApproval -Session $e.Session -Plan $plan -Requests $a.Requests -ConfirmTarget "$($e.Config.tenantId)/training01" -StatePath $e.StatePath -RunId training01 -Context $e.Context | Out-Null
    $output = Invoke-SeedTeamsChannel -Session $e.Session -Adapter $a -Plan $plan -AssetUrlMap @{}
    return @{ Plan = $plan; Output = $output }
}
try {
    Test-Case 'same-client exact approved migration write accepts Migrate but refuses ordinary and changed Team body' {
        $e = New-TeamsEnvironment -GrantedRoles @('User.Read.All', 'Group.ReadWrite.All', 'Teamwork.Migrate.All', 'TeamMember.ReadWrite.All', 'ChannelMessage.Read.All')
        try {
            $a = Get-TeamsTestAdapter $e
            $plan = @(Get-SeedOperationPlan -Session $e.Session -Operations $a.Operations -ResourceChecks $a.ResourceChecks)
            $record = Get-SeedSessionRecord $e.Session
            $rules = @{}
            Add-SeedExactRequestRule -Record $record -Plan $plan -Request $a.Requests[0] -Rules $rules
            Assert-Equal $rules.Count 1
            $changed = Copy-TeamsValue $a.Requests[0]
            $changed.Body.displayName += ' changed'
            Assert-Throws { Add-SeedExactRequestRule -Record $record -Plan $plan -Request $changed -Rules @{} } 'Seed.Approval.Teams' | Out-Null
            $ordinary = Copy-TeamsValue $plan
            $ordinary[0].TeamsScope.InitialRequest.Body.Remove('@microsoft.graph.teamCreationMode')
            $request = Copy-TeamsValue $a.Requests[0]
            $request.Body.Remove('@microsoft.graph.teamCreationMode')
            Assert-Throws { Add-SeedExactRequestRule -Record $record -Plan $ordinary -Request $request -Rules @{} } 'Seed.Approval.Scope' | Out-Null
            $request.Body.'@microsoft.graph.teamCreationMode' = 'Migration'
            $ordinary[0].TeamsScope.InitialRequest.Body.'@microsoft.graph.teamCreationMode' = 'Migration'
            Assert-Throws { Add-SeedExactRequestRule -Record $record -Plan $ordinary -Request $request -Rules @{} } 'Seed.Approval.Scope' | Out-Null
            $ordinary[0].Remove('TeamsScope')
            Assert-Throws { Add-SeedExactRequestRule -Record $record -Plan $ordinary -Request $request -Rules @{} } 'Seed.Approval.Scope' | Out-Null
            Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count 0
        } finally { Close-SeedSession $e.Session }
    }
    Test-Case 'Teams mention rendering accepts canonical alternate markup and preserves escaped actual names' {
        $scope = @{ BodyHtml = "<p><AT ID='0'>An&#97;lyst</AT> review.</p>"; AssetRefs = @(); AuthorId = 'author'; AuthorName = 'A'
            CreatedDateTime = '2026-10-29T00:00:00.000Z'; Mentions = @(@{ id = 0; role = 'Analyst'; mentionText = 'Bob & <分析>'
                mentioned = @{ user = @{ id = 'actual'; displayName = 'Bob & <分析>'; userIdentityType = 'aadUser' } } }) }
        $body = Get-SeedTeamsMessageBody $scope @{}
        Assert-True ($body.body.content.Contains('<at id="0">Bob &amp; &lt;分析&gt;</at>')) 'Canonical single quotes and entity mention labels must also be regenerated.'
    }
    Test-Case 'Teams server tbody normalization preserves cells mentions links and rejects hidden or misplaced groups' {
        $expected = '<p><at id="0">Actor &amp; One</at></p><table><tr><th>Count</th></tr><tr><td>18</td></tr></table><p><a href="https://example.sharepoint.com/file">Proof</a></p>'
        $actual = $expected.Replace('<table>', '<table><tbody>').Replace('</table>', '</tbody></table>')
        $proof = Compare-SeedTeamsHtml $expected $actual
        Assert-True ($proof.Count -gt 0)
        foreach ($bad in @(
            $actual.Replace('18', '19'),
            $actual.Replace('<tr><td>18</td></tr>', ''),
            $actual.Replace('id="0"', 'id="1"'),
            $actual.Replace('/file', '/other'),
            $actual.Replace('<tbody>', '<tbody style="display:none">'),
            $actual.Replace('</tbody>', ''),
            ('<tbody>' + $expected + '</tbody>')
        )) {
            Assert-Throws { Compare-SeedTeamsHtml $expected $bad } 'Seed.Teams.Content' | Out-Null
        }
    }
    Test-Case 'Teams channel completion uses authoritative mode after a gateway failure without duplicating content' {
        foreach ($fault in @('LostCompletionAck', 'RetryableComplete', 'LostThirdCompletionAck')) {
            $e = New-TeamsEnvironment
            try {
                $e.Model.Fault = $fault
                $a = Get-TeamsTestAdapter $e
                Assert-True (Start-TeamsTestRun $e $a).Output.Verified
                $extra = $(if ($fault -ceq 'RetryableComplete') { 1 } elseif ($fault -ceq 'LostThirdCompletionAck') { 2 } else { 0 })
                Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count ($a.Operations.Count + $extra)
                Assert-Equal $e.Model.CompletedChannels.Count $e.Model.Channels.Count
            } finally { Close-SeedSession $e.Session }
        }
    }
    Test-Case 'Teams in-progress gateway completion is bounded to three posts under one durable submission' {
        $e = New-TeamsEnvironment
        try {
            $e.Model.Fault = 'IncompleteCompletion'
            $a = Get-TeamsTestAdapter $e
            Assert-Throws { Start-TeamsTestRun $e $a } 'Seed.Teams.Stopped' | Out-Null
            Assert-Equal $e.Model.CompletionAttempts 3
            $state = Get-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $a.Operations
            $unknown = @($state.results | Where-Object status -ceq Unknown)
            Assert-Equal $unknown.Count 1
            Assert-Equal @($state.events | Where-Object { $_.action -ceq 'Submit' -and $_.id -ceq $unknown[0].id }).Count 1
        } finally { Close-SeedSession $e.Session }
    }
    Test-Case 'Teams missing owner is pending but foreign or duplicate owners remain hard failures' {
        $e = New-TeamsEnvironment
        try {
            $t = @{ TeamOperationId = 'team'; Ids = @{ team = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee' }; PresenterId = $e.Model.Ids.Presenter }
            $op = @{ TeamsScope = @{ Kind = 'Owner' } }
            Assert-Throws { Get-SeedTeamsSnapshot $e.Session $t $op } 'Seed.Teams.Pending' | Out-Null
            $e.Model.Owners = @($t.PresenterId)
            Assert-Equal (Get-SeedTeamsSnapshot $e.Session $t $op).id $t.PresenterId
            foreach ($owners in @(@('foreign'), @($t.PresenterId, 'foreign'), @($t.PresenterId, $t.PresenterId))) {
                $e.Model.Owners = $owners
                Assert-Throws { Get-SeedTeamsSnapshot $e.Session $t $op } 'Seed.Teams.Owner' | Out-Null
            }
            Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count 0
        } finally { Close-SeedSession $e.Session }
    }
    Test-Case 'Teams backing group member propagation is pending without weakening exact tenant role or duplicate checks' {
        $e = New-TeamsEnvironment
        try {
            $uid = $e.Model.Ids.Presenter
            $e.Model.Members[$uid] = @{ id = 'presenter-member'; userId = $uid; tenantId = $e.Config.tenantId; roles = @('owner') }
            $e.Model.GroupMembers[$uid] = @{ id = $uid }
            $t = @{ TeamOperationId = 'team'; Ids = @{ team = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee' }; Context = $e.Context }
            $op = @{ OperationId = 'presenter-member'; TeamsScope = @{ Kind = 'Member'; UserId = $uid; Body = @{ roles = @('owner') } } }
            $e.Model.Fault = 'GroupMemberDelay'
            Assert-Throws { Get-SeedTeamsSnapshot $e.Session $t $op } 'Seed.Teams.Pending' | Out-Null
            $e.Model.Fault = ''
            Assert-Equal (Get-SeedTeamsSnapshot $e.Session $t $op).userId $uid
            $e.Model.Fault = 'DuplicateGroupMember'
            Assert-Throws { Get-SeedTeamsSnapshot $e.Session $t $op } 'Seed.Teams.Member' | Out-Null
            $e.Model.Fault = ''
            $e.Model.Members[$uid].roles = @()
            Assert-Throws { Get-SeedTeamsSnapshot $e.Session $t $op } 'Seed.Teams.Member' | Out-Null
            $e.Model.Members[$uid].roles = @('owner')
            $e.Model.Members[$uid].tenantId = 'foreign'
            Assert-Throws { Get-SeedTeamsSnapshot $e.Session $t $op } 'Seed.Teams.Member' | Out-Null
            Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count 0
        } finally { Close-SeedSession $e.Session }
    }
    Test-Case 'Teams explicitly creates separately proved backing group memberships for every approved actor and Presenter' {
        $e = New-TeamsEnvironment
        try {
            $a = Get-TeamsTestAdapter $e
            $run = Start-TeamsTestRun $e $a
            Assert-True $run.Output.Verified
            $groupWrites = @($e.Model.Ledger | Where-Object { $_.Method -ceq 'POST' -and $_.Path -match '/groups/[^/]+/members/\$ref$' })
            Assert-Equal $groupWrites.Count $e.Model.Ids.Count
            Assert-Equal $e.Model.GroupMembers.Count $e.Model.Ids.Count
            Assert-Equal $e.Model.Members.Count $e.Model.Ids.Count
            Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count $a.Operations.Count
            foreach ($member in @($a.Operations | Where-Object { $_.TeamsScope.Kind -ceq 'Member' })) {
                $parent = @($a.Operations | Where-Object OperationId -CEQ $member.TeamsScope.ParentOperationId)[0]
                Assert-Equal $parent.TeamsScope.Kind 'GroupMember'
                Assert-Equal $parent.TeamsScope.UserId $member.TeamsScope.UserId
                Assert-True ($member.TeamsScope.Dependencies -ccontains $parent.OperationId)
                $groupPost = @($e.Model.Ledger | Where-Object { $_.Method -ceq 'POST' -and $_.Path -match '/groups/[^/]+/members/\$ref$' -and $_.Body.'@odata.id' -ceq $parent.TeamsScope.Body.'@odata.id' })[0]
                $teamPost = @($e.Model.Ledger | Where-Object { $_.Method -ceq 'POST' -and $_.Path -match '/teams/[^/]+/members$' -and $_.Body.'user@odata.bind' -ceq $parent.TeamsScope.Body.'@odata.id' })[0]
                Assert-True ($e.Model.Ledger.IndexOf($groupPost) -lt $e.Model.Ledger.IndexOf($teamPost))
            }
            $owned = Get-SeedTeamsRecord $e.Session $a
            $groupOp = @($a.Operations | Where-Object { $_.TeamsScope.Kind -ceq 'GroupMember' })[0]
            $foreign = Get-SeedTeamsRequest $e.Session $owned $groupOp
            $foreign.Body = @{ '@odata.id' = 'https://graph.microsoft.com/v1.0/users/ffffffff-ffff-4fff-8fff-ffffffffffff' }
            Assert-Throws {
                Add-SeedExactRequestRule -Record (Get-SeedSessionRecord $e.Session) -Plan @($run.Plan | Where-Object OperationId -CEQ $groupOp.OperationId) -Request $foreign -Rules @{} -DynamicResolved
            } 'Seed.Approval.Actor' | Out-Null
            $state = Get-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $a.Operations -ForImport
            Set-SeedTeamsRunState $e.Session $a $state
            $before = @($e.Model.Ledger | Where-Object Method -ne GET).Count
            $plan = @(Get-SeedOperationPlan -Session $e.Session -Operations $a.Operations -ResourceChecks $a.ResourceChecks -RunState $state)
            Assert-Equal @($plan | Where-Object Action -eq Skip).Count $a.Operations.Count
            Assert-True (Invoke-SeedTeamsChannel $e.Session $a $plan @{}).Verified
            Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count $before
        } finally { Close-SeedSession $e.Session }
    }
    Test-Case 'Teams explicit group member proof permits pending only for missing identities and rejects malformed or duplicate evidence' {
        $e = New-TeamsEnvironment
        try {
            $uid = $e.Model.Ids.Presenter
            $t = @{ TeamOperationId = 'team'; Ids = @{ team = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee' } }
            $op = @{ TeamsScope = @{ Kind = 'GroupMember'; UserId = $uid } }
            Assert-Throws { Get-SeedTeamsSnapshot $e.Session $t $op } 'Seed.Teams.Pending' | Out-Null
            $e.Model.GroupMembers[$uid] = @{ id = $uid }
            Assert-Equal (Get-SeedTeamsSnapshot $e.Session $t $op).id $uid
            foreach ($fault in @('DuplicateGroupMember', 'MalformedGroupMember')) {
                $e.Model.Fault = $fault
                Assert-Throws { Get-SeedTeamsSnapshot $e.Session $t $op } 'Seed.Teams.Member' | Out-Null
            }
            Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count 0
        } finally { Close-SeedSession $e.Session }
    }
    Test-Case 'Teams failed completion with missing authoritative mode remains Unknown with one completion attempt' {
        $e = New-TeamsEnvironment
        try {
            $e.Model.Fault = 'MissingCompletionMode'
            $a = Get-TeamsTestAdapter $e
            Assert-Throws { Start-TeamsTestRun $e $a } 'Seed.Teams.Stopped' | Out-Null
            Assert-Equal @($e.Model.Ledger | Where-Object { $_.Method -ceq 'POST' -and $_.Path -match '/channels/[^/]+/completeMigration$' }).Count 1
            $state = Get-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $a.Operations
            Assert-Equal @($state.results | Where-Object status -ceq Unknown).Count 1
        } finally { Close-SeedSession $e.Session }
    }
    Test-Case 'Teams service lifecycle events are not scenario messages but user and foreign events still block' {
        $e = New-TeamsEnvironment
        try {
            $e.Model.Fault = 'SystemLifecycleEvents'
            $a = Get-TeamsTestAdapter $e
            Assert-True (Start-TeamsTestRun $e $a).Output.Verified
            $before = @($e.Model.Ledger | Where-Object Method -ne GET).Count
            foreach ($fault in @('UserLifecycleEvent', 'ForeignLifecycleEvent')) {
                $e.Model.Fault = $fault
                Assert-Throws { Test-SeedTeams -Session $e.Session -Adapter $a -AssetUrlMap @{} } 'Seed.Teams.Verify' | Out-Null
            }
            Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count $before
        } finally { Close-SeedSession $e.Session }
    }
    Test-Case 'Teams propagation sets reject malformed duplicate and unplanned IDs instead of treating them as pending' {
        Assert-Throws { Assert-SeedTeamsMessageSet -Actual @('known', 'known') -Expected @('known') } 'Seed.Teams.Collection' | Out-Null
        Assert-Throws { Assert-SeedTeamsMessageSet -Actual @('other') -Expected @('known') } 'Seed.Teams.Collection' | Out-Null
        Assert-Throws { Assert-SeedTeamsMessageSet -Actual @($null) -Expected @() } 'Seed.Teams.Collection' | Out-Null
        Assert-Throws { Assert-SeedTeamsMessageSet -Actual @() -Expected @('known') } 'Seed.Teams.Pending' | Out-Null
    }
    Test-Case 'Teams delayed complete-migration collections are GET-polled without posting any operation twice' {
        $e = New-TeamsEnvironment
        try {
            $e.Model.Fault = 'DelayedCollections'
            $a = Get-TeamsTestAdapter $e
            $result = Start-TeamsTestRun $e $a
            Assert-True $result.Output.Verified
            Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count $a.Operations.Count
            Assert-True (@($e.Model.CollectionPolls.Values | Where-Object { $_ -ge 9 }).Count -gt 0)
            $e.Model.Fault = 'ExtraMessage'
            $before = @($e.Model.Ledger | Where-Object Method -ne GET).Count
            Assert-Throws { Test-SeedTeams -Session $e.Session -Adapter $a -AssetUrlMap @{} } 'Seed.Teams.Verify' | Out-Null
            Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count $before
        } finally { Close-SeedSession $e.Session }
    }
    Test-Case 'Teams authentic adapter is implemented' {
        Assert-True ([bool](Get-Command Get-SeedTeamsAdapter -ErrorAction SilentlyContinue)) 'T5 Teams adapter is not implemented.'
    }
    Test-Case 'Teams standard root reply multiple authors mentions both migration levels real membership and full rerun' {
        $e = New-TeamsEnvironment
        try {
            $a = Get-TeamsTestAdapter $e
            Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count 0
            $r = Start-TeamsTestRun $e $a
            Assert-True $r.Output.Verified
            Assert-Equal $r.Output.Messages.Count 4
            Assert-True $e.Model.CompletedTeam
            Assert-Equal $e.Model.CompletedChannels.Count 2
            Assert-Equal $e.Model.Members.Count 3
            Assert-Equal @($e.Model.Members[$e.Model.Ids.Presenter].roles) @('owner')
            $posts = @($e.Model.Ledger | Where-Object { $_.Method -eq 'POST' -and $_.Path -match '/messages(?:/[^/]+/replies)?$' })
            Assert-Equal $posts[0].Body.from.user.id $e.Model.Ids.alice
            Assert-Equal $posts[1].Body.from.user.id $e.Model.Ids.bob
            Assert-True ($posts[0].Body.body.content.Contains('<at id="0">Bob &amp; &lt;分析&gt;</at>'))
            Assert-Equal $posts[0].Body.mentions[0].mentionText 'Bob & <分析>'
            Assert-Equal $posts[0].Body.mentions[0].mentioned.user.id $e.Model.Ids.bob
            Assert-True ($posts[1].Path.EndsWith('/' + $r.Output.Messages[0].id + '/replies'))
            $state = Get-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $a.Operations -ForImport
            Set-SeedTeamsRunState $e.Session $a $state
            $before = @($e.Model.Ledger | Where-Object Method -ne GET).Count
            $plan = @(Get-SeedOperationPlan -Session $e.Session -Operations $a.Operations -ResourceChecks $a.ResourceChecks -RunState $state)
            Assert-Equal @($plan | Where-Object Action -eq Skip).Count $a.Operations.Count
            $again = Invoke-SeedTeamsChannel -Session $e.Session -Adapter $a -Plan $plan -AssetUrlMap @{}
            Assert-True $again.Verified
            Assert-True (Test-SeedTeams -Session $e.Session -Adapter $a).Verified
            Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count $before
            Assert-Equal $r.Output.ResourceLinkIndex.Count 3
            $fresh = New-TeamsEnvironment
            try {
                foreach ($k in @('Group', 'Team', 'Channels', 'Messages', 'Members', 'GroupMembers', 'Owners', 'CompletedChannels', 'CompletedTeam')) { $fresh.Model[$k] = $e.Model[$k] }
                $fresh.StatePath = $e.StatePath; $fresh.Model.StatePath = $e.StatePath
                $a2 = Get-TeamsTestAdapter $fresh
                $s2 = Get-SeedRunState -Path $fresh.StatePath -RunId training01 -Context $fresh.Context -Operations $a2.Operations -ForImport
                Set-SeedTeamsRunState $fresh.Session $a2 $s2
                Assert-True (Test-SeedTeams $fresh.Session $a2).Verified
                $p2 = @(Get-SeedOperationPlan -Session $fresh.Session -Operations $a2.Operations -ResourceChecks $a2.ResourceChecks -RunState $s2)
                Assert-Equal @($p2 | Where-Object Action -eq Skip).Count $a2.Operations.Count
                Assert-True (Invoke-SeedTeamsChannel $fresh.Session $a2 $p2 @{}).Verified
                Assert-Equal @($fresh.Model.Ledger | Where-Object Method -ne GET).Count 0
            } finally { Close-SeedSession $fresh.Session }
        } finally { Close-SeedSession $e.Session }
    }
    Test-Case 'Teams visible name is the scenario title plus a short run suffix and only the description keeps the full ownership marker' {
        $e = New-TeamsEnvironment
        try {
            $a = Get-TeamsTestAdapter $e
            $ns = Get-SeedFingerprint @{ context = $e.Context; runId = 'training01' }
            $body = $a.Requests[0].Body
            Assert-Equal $body.displayName ($e.Scenario.scenario.title + ' [' + $ns.Substring(0, 8) + ']')
            Assert-Equal $body.description "M365Seed:$ns"
            $r = Start-TeamsTestRun $e $a
            Assert-True $r.Output.Verified
            Assert-Equal $e.Model.Group.displayName $body.displayName
            Assert-Equal $e.Model.Team.displayName $body.displayName
            Assert-Equal $r.Output.Team.displayName $body.displayName
            Assert-Equal $r.Output.ResourceLinkIndex[0].displayName $body.displayName
            Assert-True ($e.Model.Team.displayName -notmatch 'Demo|M365Seed')
            Assert-Equal @($e.Model.Ledger | Where-Object { $_.Method -ceq 'POST' -and $_.Path -ceq '/teams' }).Count 1
        } finally { Close-SeedSession $e.Session }
    }
    Test-Case 'Teams rejects a blank padded overlong control or format title before any write' {
        $titles = [ordered]@{ Blank = '   '; Padded = ' Offline training '; Long = ('T' * 201); Control = "Offline`u{7}training"; Format = "Offline`u{200B}training" }
        foreach ($kind in $titles.Keys) {
            $e = New-TeamsEnvironment -Title $titles[$kind]
            try {
                Assert-Throws { Get-TeamsTestAdapter $e } 'Seed\.Input\.TeamName' | Out-Null
                Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count 0
            } finally { Close-SeedSession $e.Session }
        }
    }
    Test-Case 'Teams absence lookup quote-escapes and percent-encodes a 200 character CJK title' {
        $title = ("O'Neil 澄流計畫：" + ('品' * 200)).Substring(0, 200)
        $e = New-TeamsEnvironment -Title $title
        try {
            $a = Get-TeamsTestAdapter $e
            $name = $a.Requests[0].Body.displayName
            Assert-Equal $name.Length 211
            $null = @(Get-SeedOperationPlan -Session $e.Session -Operations $a.Operations -ResourceChecks $a.ResourceChecks)
            $lookups = @($e.Model.Ledger | Where-Object { $_.Method -ceq 'GET' -and $_.Path.StartsWith('/groups?') })
            Assert-True ($lookups.Count -gt 0) 'The new namespace must be proven absent through the groups lookup.'
            foreach ($call in $lookups) {
                Assert-True ($call.Path.Contains('O%27%27Neil%20%E6%BE%84%E6%B5%81%E8%A8%88%E7%95%AB'))
                Assert-True ($call.Path -cmatch '^[\x21-\x7e]+$') 'The lookup path must contain only percent-encoded ASCII.'
                Assert-True ([uri]::UnescapeDataString($call.Path).Contains('$filter=displayName eq ''' + $name.Replace("'", "''") + '''&$select='))
            }
            Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count 0
        } finally { Close-SeedSession $e.Session }
    }
    Test-Case 'Teams future relative to wall clock is rejected even when anchor permits it' {
        $e = New-TeamsEnvironment Future
        try { Assert-Throws { Get-TeamsTestAdapter $e } 'Seed.Teams.Time' | Out-Null; Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count 0 }
        finally { Close-SeedSession $e.Session }
    }
    Test-Case 'Teams rejects submillisecond import instants rather than silently truncating history' {
        $e = New-TeamsEnvironment Fractional
        try { Assert-Throws { Get-TeamsTestAdapter $e } 'Seed.Teams.Time' | Out-Null }
        finally { Close-SeedSession $e.Session }
    }
    Test-Case 'Teams rejects duplicate unknown edited scenario and fake adapter before writes' {
        $e = New-TeamsEnvironment
        try {
            foreach ($fault in @('Duplicate', 'Unknown')) {
                $s = Copy-TeamsValue $e.Scenario
                if ($fault -eq 'Duplicate') { $s.teams.channels[1].messages[0].id = 'post' } else { $s.teams.channels[0].messages[0].fromRole = 'Unknown' }
                Assert-Throws { Get-SeedTeamsAdapter -Session $e.Session -Scenario $s -PreparedPath $e.PreparedPath -Context $e.Context -RunId training01 -StatePath $e.StatePath } 'Seed.Teams' | Out-Null
            }
            $a = Get-TeamsTestAdapter $e
            Assert-Throws { Test-SeedTeams $e.Session ([pscustomobject]@{ AdapterId = $a.AdapterId }) } 'Seed.Teams.Adapter' | Out-Null
            $a.Operations[0].TeamsScope.Body.displayName = 'foreign'
            Assert-Throws { Get-SeedOperationPlan -Session $e.Session -Operations $a.Operations -ResourceChecks $a.ResourceChecks | ForEach-Object { if ($_.Action -eq 'Block') { throw 'Seed.Teams.Block' } } } 'Seed.Teams' | Out-Null
            Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count 0
        } finally { Close-SeedSession $e.Session }
    }
    Test-Case 'Teams owned existing team duplicate group and foreign paging never adopted' {
        foreach ($fault in @('Existing', 'DuplicateGroup', 'Pagination')) {
            $e = New-TeamsEnvironment
            try {
                $a = Get-TeamsTestAdapter $e
                if ($fault -ne 'Pagination') { $e.Model.Group = @{ id = 'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee'; displayName = $a.Operations[0].TeamsScope.Body.displayName } }
                $e.Model.Fault = $fault
                $plan = @(Get-SeedOperationPlan -Session $e.Session -Operations $a.Operations -ResourceChecks $a.ResourceChecks)
                Assert-Equal @($plan | Where-Object Action -eq Block).Count $a.Operations.Count
                Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count 0
            } finally { Close-SeedSession $e.Session }
        }
    }
    Test-Case 'Teams completed readback blocks wrong author time content parent mention owner membership links and extras' {
        $e = New-TeamsEnvironment
        try {
            $a = Get-TeamsTestAdapter $e; $null = Start-TeamsTestRun $e $a
            $before = @($e.Model.Ledger | Where-Object Method -ne GET).Count
            foreach ($fault in @('Actor', 'Time', 'TeamTime', 'ChannelTime', 'Content', 'Parent', 'Mention', 'Owner', 'Membership', 'Link', 'ExtraMessage', 'Profile')) {
                $e.Model.Fault = $fault
                Assert-Throws { Test-SeedTeams -Session $e.Session -Adapter $a } 'Seed.Teams.Verify' | Out-Null
            }
            Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count $before
        } finally { Close-SeedSession $e.Session }
    }
    Test-Case 'Teams lost accepted writes retain Unknown and never partial repair' {
        foreach ($fault in @('Lost', 'LostRoot')) {
            $e = New-TeamsEnvironment
            try {
                $a = Get-TeamsTestAdapter $e; $e.Model.Fault = $fault
                Assert-Throws { Start-TeamsTestRun $e $a } 'Seed.Teams.Stopped' | Out-Null
                $state = Get-Content $e.StatePath -Raw | ConvertFrom-Json -AsHashtable
                Assert-Equal $state.status 'Blocked'
                Assert-Equal @($state.results | Where-Object status -eq Unknown).Count 1
                if ($fault -ceq 'LostRoot') {
                    Assert-Equal $e.Model.Messages.Count 1
                    Assert-Equal @($e.Model.Ledger | Where-Object { $_.Method -ceq 'POST' -and $_.Path.EndsWith('/messages') }).Count 1
                    Assert-True (-not $e.Model.CompletedTeam)
                }
                $before = @($e.Model.Ledger | Where-Object Method -ne GET).Count
                Assert-Throws { Get-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $a.Operations -ForImport } 'Seed.State.Blocked' | Out-Null
                Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count $before
            } finally { Close-SeedSession $e.Session }
        }
    }
    Test-Case 'Teams exact upfront root request and late bound message scope cannot be exchanged' {
        $e = New-TeamsEnvironment
        try {
            $a = Get-TeamsTestAdapter $e
            $plan = @(Get-SeedOperationPlan -Session $e.Session -Operations $a.Operations -ResourceChecks $a.ResourceChecks)
            New-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $a.Operations | Out-Null
            $request = Copy-TeamsValue $a.Requests[0]; $request.Body.displayName = 'arbitrary'
            Assert-Throws { New-SeedWriteApproval -Session $e.Session -Plan $plan -Requests @($request) -ConfirmTarget "$($e.Config.tenantId)/training01" -StatePath $e.StatePath -RunId training01 -Context $e.Context } 'Seed.Approval.Teams' | Out-Null
            Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count 0
        } finally { Close-SeedSession $e.Session }
    }
    Test-Case 'Teams integrates authentic Storage URLs and rejects copied mutated or stale asset maps without writes' {
        $e = New-TeamsEnvironment -WithAssets
        try {
            Assert-Throws { Get-TeamsTestAdapter $e } 'Seed.Teams.Asset' | Out-Null
            $storage = Get-SeedStorageAdapter -Session $e.Session -Scenario $e.Scenario -PreparedPath $e.PreparedPath -Context $e.Context -RunId training01 -StatePath $e.StatePath
            $a = Get-TeamsTestAdapter $e
            $ops = @($storage.Operations) + @($a.Operations)
            $checks = @{ onedrive = $storage.ResourceChecks.onedrive; teams = $a.ResourceChecks.teams }
            $plan = @(Get-SeedOperationPlan -Session $e.Session -Operations $ops -ResourceChecks $checks)
            Assert-Equal @($plan | Where-Object Action -eq Block).Count 0
            New-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $ops | Out-Null
            New-SeedWriteApproval -Session $e.Session -Plan $plan -Requests (@($storage.Requests) + @($a.Requests)) -ConfirmTarget "$($e.Config.tenantId)/training01" -StatePath $e.StatePath -RunId training01 -Context $e.Context | Out-Null
            $map = (Invoke-UploadFiles -Session $e.Session -Adapter $storage -Plan $plan).AssetUrlMap
            $before = @($e.Model.Ledger | Where-Object Method -ne GET).Count
            Assert-Throws { Invoke-SeedTeamsChannel -Session $e.Session -Adapter $a -Plan $plan -AssetUrlMap (Copy-TeamsValue $map) } 'Seed.Teams.Asset' | Out-Null
            Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count $before
            $result = Invoke-SeedTeamsChannel -Session $e.Session -Adapter $a -Plan $plan -AssetUrlMap $map
            Assert-True $result.Verified
            $post = @($e.Model.Ledger | Where-Object { $_.Method -ceq 'POST' -and $_.Path.EndsWith('/messages') })[0]
            Assert-True ($post.Body.body.content.Contains('href="https://example.sharepoint.com/files/actual&amp;metrics.xlsx"'))
            $before = @($e.Model.Ledger | Where-Object Method -ne GET).Count
            $map.metrics.webUrl = 'https://example.sharepoint.com/files/fake'
            Assert-Throws { Test-SeedTeams $e.Session $a $map } 'Seed.Teams.Verify' | Out-Null
            Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count $before
        } finally { Close-SeedSession $e.Session }
    }
    Test-Case 'Teams corrupt accepted message is Unknown with actual ID and is not polled as propagation' {
        $e = New-TeamsEnvironment
        try {
            $a = Get-TeamsTestAdapter $e; $e.Model.Fault = 'Content'
            Assert-Throws { Start-TeamsTestRun $e $a } 'Seed.Teams.Stopped' | Out-Null
            $j = Get-Content $e.StatePath -Raw | ConvertFrom-Json -AsHashtable
            $unknown = @($j.results | Where-Object status -eq Unknown)
            Assert-Equal $unknown.Count 1
            Assert-True ([bool]@($j.events | Where-Object { $_.action -ceq 'Fail' -and $_.id -ceq $unknown[0].id })[0].objectId)
            $details = @($e.Model.Ledger | Where-Object { $_.Method -ceq 'GET' -and $_.Path -match '/messages/[^/]+$' })
            Assert-Equal $details.Count 1
        } finally { Close-SeedSession $e.Session }
    }
    Test-Case 'Teams missing required v1 read role fails closed and never substitutes beta' {
        $e = New-TeamsEnvironment
        try {
            $r = Get-SeedSessionRecord $e.Session
            $r.Permissions = @($r.Permissions | Where-Object { $_ -cne 'ChannelMessage.Read.All' })
            Assert-Throws { Get-TeamsTestAdapter $e } 'Seed.Teams.Scope' | Out-Null
            Assert-Equal @($e.Model.Ledger | Where-Object { $_.Path -match 'beta' -or $_.Method -cne 'GET' }).Count 0
        } finally { Close-SeedSession $e.Session }
    }
    Test-Case 'Teams standard inherited access plans Presenter owner even when not an explicit channel participant' {
        $e = New-TeamsEnvironment NoPresenter
        try {
            $a = Get-TeamsTestAdapter $e
            $presenter = @($a.Operations | Where-Object { $_.TeamsScope.Kind -ceq 'Member' -and $_.TeamsScope.UserId -ceq $e.Model.Ids.Presenter })
            Assert-Equal $presenter.Count 1
            Assert-Equal @($presenter[0].TeamsScope.Body.roles) @('owner')
            $plan = @(Get-SeedOperationPlan -Session $e.Session -Operations $a.Operations -ResourceChecks $a.ResourceChecks)
            Assert-Equal @($plan | Where-Object Action -eq Create).Count $a.Operations.Count
            Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count 0
        } finally { Close-SeedSession $e.Session }
    }
    Test-Case 'Teams late binding rejects changed actual author content channel and root without Submit' {
        $e = New-TeamsEnvironment
        try {
            $a = Get-TeamsTestAdapter $e
            $plan = @(Get-SeedOperationPlan -Session $e.Session -Operations $a.Operations -ResourceChecks $a.ResourceChecks)
            New-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $a.Operations | Out-Null
            New-SeedWriteApproval -Session $e.Session -Plan $plan -Requests $a.Requests -ConfirmTarget "$($e.Config.tenantId)/training01" -StatePath $e.StatePath -RunId training01 -Context $e.Context | Out-Null
            Write-SeedGraph -Session $e.Session -Request $a.Requests[0] | Out-Null
            $t = Get-SeedTeamsRecord $e.Session $a
            $snapshot = Get-SeedTeamsSnapshot $e.Session $t $a.Operations[0]
            $t.Ids[$t.TeamOperationId] = $snapshot.id
            Write-SeedRunEvent -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $a.Operations -OperationId $t.TeamOperationId -Workload teams -Action Verify -Status Verified -ObjectId $snapshot.id -ReadBack $snapshot | Out-Null
            $rootOp = @($a.Operations | Where-Object { $_.TeamsScope.Kind -ceq 'Root' })[0]
            foreach ($fault in @('Author', 'Body', 'Channel', 'Root')) {
                $q = Get-SeedTeamsRequest $e.Session $t $rootOp
                switch ($fault) {
                    Author { $q.Body.from.user.id = $e.Model.Ids.bob }
                    Body { $q.Body.body.content = '<p>Changed.</p>' }
                    Channel { $q.Path = $q.Path.Replace('/primary/', '/foreign/') }
                    Root { $q.Path += '/foreign/replies' }
                }
                $before = $e.Model.Ledger.Count
                Assert-Throws { Write-SeedGraph -Session $e.Session -Request $q -RequestCheck $a.RequestCheck } 'Seed.Approval.Check' | Out-Null
                Assert-Equal @($e.Model.Ledger | Select-Object -Skip $before | Where-Object Method -ne GET).Count 0
            }
            $j = Get-Content $e.StatePath -Raw | ConvertFrom-Json -AsHashtable
            Assert-Equal @($j.events | Where-Object action -eq Submit).Count 1
        } finally { Close-SeedSession $e.Session }
    }
} finally {
    Remove-Item -LiteralPath $teamsScratch -Recurse -Force
}
