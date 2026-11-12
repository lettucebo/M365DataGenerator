$outlookScratch = Join-Path $root ('tests\.scratch\t4-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $outlookScratch -Force | Out-Null
foreach ($file in @('Seed-OneDriveOwnership', 'Invoke-SeedSharePoint', 'Invoke-UploadFiles', 'Invoke-SeedEmails')) {
    $path = Join-Path $root "engine\$file.ps1"
    if (Test-Path -LiteralPath $path) { . $path }
}
function Copy-OutlookValue($v) { $v | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -DateKind String }
function New-OutlookEnvironment([switch]$WithAssets, [switch]$Branch) {
    $dir = Join-Path $outlookScratch ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    foreach ($file in @('personas.json', 'alice.jpg', 'bob.jpg', 'rights.txt')) {
        Copy-Item (Join-Path $root "tests\fixtures\$file") $dir
    }
    & (Join-Path $root '.venv\Scripts\python.exe') -c 'from PIL import Image; import sys; Image.new("RGB",(16,16),(50,100,150)).save(sys.argv[1])' (Join-Path $dir 'charlie.jpg')
    $p = Get-Content (Join-Path $dir 'personas.json') -Raw | ConvertFrom-Json -AsHashtable
    $person = Copy-OutlookValue $p.people[1]
    $person.personaId = 'charlie'; $person.alias = 'charlie'; $person.displayName = 'Charlie Reviewer'; $person.avatarAssetId = 'charlie-photo'
    $p.people += $person
    $photo = Copy-OutlookValue $p.avatarAssets[1]
    $photo.id = 'charlie-photo'; $photo.path = 'charlie.jpg'; $photo.sha256 = (Get-FileHash (Join-Path $dir 'charlie.jpg')).Hash.ToLowerInvariant()
    $p.avatarAssets += $photo
    $p | ConvertTo-Json -Depth 100 | Set-Content (Join-Path $dir 'personas.json') -Encoding utf8
    $s = Get-Content (Join-Path $root 'tests\fixtures\scenario.json') -Raw | ConvertFrom-Json -AsHashtable
    $s.Remove('teams'); $s.Remove('sharepoint')
    $s.roles.Reviewer = @{ personaId = 'charlie'; businessUnitId = 'ops'; responsibility = 'Review' }
    $s.onedrive.drives[0].ownerRole = 'Presenter'
    $s.outlook.threads[0].messages[0].toRoles = @('Analyst', 'Reviewer')
    $s.outlook.threads[0].messages[0].subject = "Metrics & O'Brien — 決策"
    $s.outlook.threads[0].messages[0].bodyHtml = '<p>Review <a href="{{asset:metrics}}">metrics &amp; figures</a>.</p><table><tr><th>Plan</th><th>Value</th></tr><tr><td>A</td><td>12</td></tr></table>'
    $s.outlook.threads[0].messages[1].toRoles = @('Lead', 'Reviewer', 'Presenter')
    $s.outlook.threads[0].messages[1].ccRoles = @()
    $s.outlook.threads[0].messages += @{
        id = 'mail-3'; action = 'reply'; parentId = 'mail-2'; fromRole = 'Reviewer'
        toRoles = @('Lead', 'Analyst'); ccRoles = @('Presenter'); subject = 'Re: Metrics'
        bodyHtml = '<p>Decision: <em>approved</em>. Use 12 units.<br>Owner: Lead.</p>'; assetRefs = @()
    }
    if ($Branch) { $s.outlook.threads[0].messages[2].parentId = 'mail-1' }
    if (-not $WithAssets) {
        $s.Remove('onedrive'); $s.Remove('workbooks'); $s.assets = @()
        $s.outlook.threads[0].messages[0].bodyHtml = '<p>Review <strong>metrics &amp; figures</strong>.</p><ul><li>12 units</li><li>Owner: Lead</li></ul>'
        $s.outlook.threads[0].messages[0].assetRefs = @()
    }
    $s | ConvertTo-Json -Depth 100 | Set-Content (Join-Path $dir 'scenario.json') -Encoding utf8
    & (Join-Path $root '.venv\Scripts\python.exe') (Join-Path $root 'generator\build_scenario.py') --pack (Join-Path $dir 'scenario.json') --personas (Join-Path $dir 'personas.json') --output (Join-Path $dir 'prepared') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Outlook fixture build failed.' }
    $s = Get-Content (Join-Path $dir 'prepared\scenario.json') -Raw | ConvertFrom-Json -AsHashtable
    $m = Get-Content (Join-Path $dir 'prepared\prepared-manifest.json') -Raw | ConvertFrom-Json -AsHashtable
    $c = Get-Content (Join-Path $root 'tests\fixtures\managed-config.json') -Raw | ConvertFrom-Json -AsHashtable
    $ids = @{ alice = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'; bob = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'; charlie = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd'; Presenter = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc' }
    $binding = @{ tenantId = $c.tenantId; packId = $p.packId; version = '1.0'; fingerprint = $m.personaPackFingerprint; instanceId = 'training01'; users = @{}; status = 'Provisioned'; serviceStatus = 'NotVerified' }
    $profiles = @{}; $upns = @{}
    foreach ($person in $p.people) {
        $profile = @{ usageLocation = 'TW'; managerObjectId = $(if ($person.managerRef) { $ids[$person.managerRef] } else { $null }) }
        foreach ($f in @('displayName', 'jobTitle', 'department', 'companyName', 'officeLocation')) { $profile[$f] = $person[$f] }
        $profile.sha256 = Get-SeedFingerprint $profile; $profile.verifiedAt = '2026-10-29T00:00:00Z'
        $photo = @($p.avatarAssets | Where-Object id -eq $person.avatarAssetId)[0]
        $upn = "demo-$($person.alias)@example.invalid"
        $binding.users[$person.personaId] = @{
            objectId = $ids[$person.personaId]; upn = $upn; profile = $profile
            photo = @{ avatarAssetId = $photo.id; sourceSha256 = $photo.sha256; verifiedSha256 = ('a' * 64); verifiedAt = '2026-10-29T00:00:00Z' }
            license = @{ profileId = 'standard'; skuIds = @($c.personas.licenseProfiles.standard.skuIds); verifiedAt = '2026-10-29T00:00:00Z' }
            status = 'Provisioned'; serviceStatus = 'NotVerified'
        }
        $profiles[$ids[$person.personaId]] = $profile; $upns[$ids[$person.personaId]] = $upn
    }
    $upns[$ids.Presenter] = $c.presenterUpn
    $model = @{
        Ledger = [Collections.Generic.List[object]]::new(); Mail = @{}; Sent = @(); Counter = 0; Fault = ''; Polls = @{}; Waits = @()
        Ids = $ids; Upns = $upns; Profiles = $profiles; Presenter = $ids.Presenter
        StatePath = Join-Path $dir 'outlook.run-state.json'; Items = @{}; Uploads = @{}
    }
    foreach ($id in $upns.Keys) { $model.Mail[$id] = @{} }
    $model.Items.root = @{ id = 'root'; name = 'root'; folder = @{}; parentReference = @{ driveId = 'drive' }; webUrl = 'https://example.sharepoint.com/personal/p/Documents' }
    $transport = {
        param($Method, $Path, $Body, $RawBody)
        $model.Ledger.Add(@{ Method = $Method; Path = $Path; Body = $(if ($Body) { Copy-OutlookValue $Body } else { $null }) })
        if ($Method -ne 'GET') {
            $j = Get-Content $model.StatePath -Raw | ConvertFrom-Json -AsHashtable
            if ($j.events[-1].action -cne 'Submit' -or $j.events[-1].status -cne 'Submitted') { throw 'Missing durable Submit.' }
        }
        if ($Path -match '^/users/([^/]+)/mailFolders/inbox(.*)$' -and $Method -ceq 'GET') {
            $id = $Matches[1]; $tail = $Matches[2]
            if ($model.Fault -eq 'Mailbox' -and $id -eq $model.Ids.charlie) { throw (New-GraphStubError 404) }
            if ($tail.StartsWith('?')) { return @{ id = "inbox-$id" } }
            if ($tail -match '^/messages/([^?]+)') {
                $key = [uri]::UnescapeDataString($Matches[1])
                if (-not $model.Mail[$id].ContainsKey($key)) { throw (New-GraphStubError 404) }
                $msg = Copy-OutlookValue $model.Mail[$id][$key]
                switch ($model.Fault) {
                    Author { $msg.from.emailAddress.address = 'wrong@example.invalid' }
                    Sender { $msg.sender.emailAddress.address = 'wrong@example.invalid' }
                    Recipients { $msg.toRecipients = @() }
                    Presenter { $msg.ccRecipients = @(); $msg.toRecipients = @($msg.toRecipients | Where-Object { $_.emailAddress.address -ne $c.presenterUpn }) }
                    Body { $msg.body.content += '<p>Changed decision.</p>' }
                    Header { $msg.internetMessageHeaders[0].value = '<wrong@example.invalid>' }
                    Parent { $msg.internetMessageHeaders = @($msg.internetMessageHeaders | Where-Object name -ne 'In-Reply-To') }
                    MessageId { $msg.id = 'foreign' }
                    CrossMailboxInternet {
                        if ($id -ne $model.Presenter) {
                            $msg.internetMessageId = '<different-copy@example.invalid>'
                            $msg.internetMessageHeaders[0].value = $msg.internetMessageId
                        }
                    }
                }
                return $msg
            }
            $decoded = [uri]::UnescapeDataString($tail)
            if ($model.Fault -eq 'Pagination') { return @{ value = @(); '@odata.nextLink' = 'https://foreign.invalid/v1.0/users' } }
            $model.Polls[$id] = $(if ($model.Polls.ContainsKey($id)) { $model.Polls[$id] + 1 } else { 1 })
            if ($model.Fault -eq 'Timeout' -and $id -eq $model.Presenter) { return @{ value = @() } }
            if ($model.Fault -in @('MissingParent', 'DelayedParent') -and $decoded.Contains('internetMessageId eq') -and
                $id -eq $model.Ids.bob -and (Test-Path -LiteralPath $model.StatePath)) {
                $j = Get-Content $model.StatePath -Raw | ConvertFrom-Json -AsHashtable
                if (@($j.results | Where-Object status -eq Verified).Count -gt 0) {
                    if ($model.Fault -eq 'MissingParent') { return @{ value = @() } }
                    if (-not $model.ContainsKey('ParentPolls')) { $model.ParentPolls = 0 }
                    $model.ParentPolls++
                    if ($model.ParentPolls -le 2) { return @{ value = @() } }
                }
            }
            $values = @($model.Mail[$id].Values)
            if ($decoded -match "subject eq '((?:[^']|'')*)'") { $subject = $Matches[1].Replace("''", "'"); $values = @($values | Where-Object subject -CEQ $subject) }
            if ($decoded -match "internetMessageId eq '((?:[^']|'')*)'") { $mid = $Matches[1].Replace("''", "'"); $values = @($values | Where-Object internetMessageId -CEQ $mid) }
            $visibleAfter = $(if ($model.Fault -ceq 'DelayedLong') { 9 } else { 3 })
            if ($model.Fault -in @('Delayed', 'DelayedLong') -and $model.Sent.Count -gt 0 -and $model.Polls[$id] -lt $visibleAfter) {
                $values = @($values | Where-Object { $_.internetMessageId -cne $model.Sent[-1].InternetMessageId })
            }
            return @{ value = @($values | ForEach-Object { @{ id = $_.id; subject = $_.subject; internetMessageId = $_.internetMessageId } }) }
        }
        if ($Path -match '^/users/([^/]+)/(sendMail|messages/([^/]+)/reply)$' -and $Method -ceq 'POST') {
            $actor = $Matches[1]; $kind = $Matches[2]; $parentKey = $Matches[3]
            if ($actor -eq $model.Presenter) { throw 'Presenter cannot send.' }
            $parent = $null
            if ($kind -ne 'sendMail') {
                if (-not $model.Mail[$actor].ContainsKey($parentKey)) { throw 'Reply target is not in the actual author Inbox.' }
                $parent = $model.Mail[$actor][$parentKey]
            }
            $model.Counter++; $number = $model.Counter; $mid = "<actual-$number@example.invalid>"
            $message = $Body.message
            $headers = @(@{ name = 'Message-ID'; value = $mid })
            if ($parent) {
                $headers += @{ name = 'In-Reply-To'; value = $parent.internetMessageId }
                $previous = @($parent.internetMessageHeaders | Where-Object name -eq 'References')
                $refs = $(if ($previous.Count) { $previous[0].value + ' ' } else { '' }) + $parent.internetMessageId
                $headers += @{ name = 'References'; value = $refs }
            } else { $headers += @(Copy-OutlookValue @{ h = $message.internetMessageHeaders }).h }
            $recorded = @{ Actor = $actor; Parent = $(if ($parent) { $parent.internetMessageId } else { '' }); InternetMessageId = $mid; Message = (Copy-OutlookValue $message) }
            $model.Sent += $recorded
            if ($model.Fault -in @('Delayed', 'DelayedLong')) { $model.Polls.Clear() }
            foreach ($recipient in @($message.toRecipients) + @($message.ccRecipients)) {
                $upn = $recipient.emailAddress.address
                $mailbox = @($model.Upns.Keys | Where-Object { $model.Upns[$_] -eq $upn })[0]
                $key = "local-$number-$mailbox"
                $content = $message.body.content.Replace('<strong>', '<b>').Replace('</strong>', '</b>').Replace('<p>', '<p style="margin:0">')
                $model.Mail[$mailbox][$key] = @{
                    id = $key; parentFolderId = "inbox-$mailbox"; internetMessageId = $mid
                    conversationId = "different-conversation-$mailbox"; subject = $message.subject
                    from = @{ emailAddress = @{ address = $model.Upns[$actor] } }; sender = @{ emailAddress = @{ address = $model.Upns[$actor] } }
                    toRecipients = (Copy-OutlookValue @{ r = @($message.toRecipients) }).r; ccRecipients = (Copy-OutlookValue @{ r = @($message.ccRecipients) }).r
                    bccRecipients = @(); isDraft = $false
                    body = @{ contentType = 'html'; content = "<html><head><meta charset=`"utf-8`"></head><body>$content</body></html>" }
                    internetMessageHeaders = (Copy-OutlookValue @{ h = $headers }).h
                }
            }
            if ($model.Fault -eq 'Lost' -or ($model.Fault -eq 'LostReply' -and $parent)) { throw (New-GraphStubError 504) }
            return $null
        }
        if ($Path -match '^/users/([^/?]+)(.*)$' -and $Method -ceq 'GET') {
            $id = [uri]::UnescapeDataString($Matches[1]); $tail = $Matches[2]
            if ($tail.StartsWith('/drive')) { return @{ id = 'drive'; owner = @{ user = @{ id = $model.Presenter } } } }
            if ($id -eq $c.presenterUpn -or $id -eq $model.Presenter) { return @{ id = $model.Presenter; userPrincipalName = $c.presenterUpn; accountEnabled = $true; userType = 'Member' } }
            if ($tail.StartsWith('/manager')) {
                if (-not $model.Profiles[$id].managerObjectId) { throw (New-GraphStubError 404) }
                return @{ id = $model.Profiles[$id].managerObjectId }
            }
            $profile = Copy-OutlookValue $model.Profiles[$id]
            foreach ($f in @('managerObjectId', 'sha256', 'verifiedAt')) { $profile.Remove($f) }
            $profile.id = $id; $profile.userPrincipalName = $model.Upns[$id]; $profile.accountEnabled = $true; $profile.userType = 'Member'
            if ($model.Fault -eq 'Profile') { $profile.department = 'changed' }
            return $profile
        }
        if ($Path -eq '/drives/drive/root') { return Copy-OutlookValue $model.Items.root }
        if ($Path -match '^/drives/drive/items/([^/:?]+)(.*)$') {
            $id = $Matches[1]; $tail = $Matches[2]
            if ($tail -eq '/children') {
                if ($Method -eq 'GET') { return @{ value = @($model.Items.Values | Where-Object { $_.parentReference.ContainsKey('id') -and $_.parentReference.id -eq $id }) } }
                $model.Counter++; $key = "folder-$($model.Counter)"
                $model.Items[$key] = @{ id = $key; name = $Body.name; folder = @{}; parentReference = @{ id = $id; driveId = 'drive' }; webUrl = "https://example.sharepoint.com/files/$key" }
                return @{ id = $key }
            }
            if ($tail -match '^:/([^/]+):/createUploadSession$' -and $Method -eq 'POST') {
                $model.Uploads.allocation = @{ Parent = $id; Name = [uri]::UnescapeDataString($Matches[1]) }
                return @{ uploadUrl = 'https://example.sharepoint.com/upload?sig=private'; expirationDateTime = [DateTimeOffset]::UtcNow.AddHours(1).ToString('o'); nextExpectedRanges = @('0-') }
            }
            if ($tail -eq '/permissions') { return @{ value = @(@{ roles = @('owner'); grantedToV2 = @{ user = @{ id = $model.Presenter } } }) } }
            return Copy-OutlookValue $model.Items[$id]
        }
        throw "Unconfigured offline request: $Method $Path"
    }.GetNewClosure()
    $claims = @{ tid = $c.tenantId; appid = $c.clientId; aud = 'https://graph.microsoft.com'; iss = "https://sts.windows.net/$($c.tenantId)/"; exp = [DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds(); roles = @('User.Read.All', 'Mail.Read', 'Mail.Send', 'Files.ReadWrite.All') }
    $encode = { param($v) [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($v | ConvertTo-Json -Compress))).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
    $jwt = "$(& $encode @{ alg = 'RS256' }).$(& $encode $claims).offline"
    $upload = {
        param($Url, $Bytes, $Headers)
        if ($null -eq $Bytes) { return @{ expirationDateTime = [DateTimeOffset]::UtcNow.AddHours(1).ToString('o'); nextExpectedRanges = @('0-') } }
        $j = Get-Content $model.StatePath -Raw | ConvertFrom-Json -AsHashtable
        if ($j.events[-1].action -ne 'Submit') { throw 'Missing durable upload Submit.' }
        $allocation = $model.Uploads.allocation
        $item = @{ id = 'asset-item'; name = $allocation.Name; size = $Bytes.Length; eTag = 'file-v1'; cTag = 'content-v1'
            parentReference = @{ id = $allocation.Parent; driveId = 'drive' }; webUrl = 'https://example.sharepoint.com/files/actual&metrics.xlsx'
            file = @{ hashes = @{ sha256Hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant() } } }
        $model.Items[$item.id] = $item
        return Copy-OutlookValue $item
    }.GetNewClosure()
    $delay = { param($Seconds) $model.Waits += $Seconds }.GetNewClosure()
    $session = Connect-SeedSession -Config $c -Mode Import -TokenProvider { $jwt }.GetNewClosure() -Transport $transport -Delay $delay -UploadTransport $upload
    $identity = Resolve-SeedIdentityContext -Session $session -Config $c -Personas $p -Scenario $s -Binding $binding -PersonaPackFingerprint $m.personaPackFingerprint
    Test-SeedServices -Session $session -Scenario $s -IdentityContext $identity | Out-Null
    $context = @{ tenantId = $c.tenantId; clientId = $c.clientId; scenarioId = $s.scenario.id; personaPackId = $p.packId
        personaPackFingerprint = $m.personaPackFingerprint; instanceId = 'training01'; bindingFingerprint = $identity.BindingFingerprint
        preparedFingerprint = $m.fingerprint; presenterUpn = $c.presenterUpn }
    return @{ Session = $session; Model = $model; Scenario = $s; Context = $context; Config = $c; PreparedPath = (Join-Path $dir 'prepared'); StatePath = $model.StatePath }
}
function Get-OutlookTestAdapter($e, [string]$RunId = 'training01') {
    Get-SeedOutlookAdapter -Session $e.Session -Scenario $e.Scenario -PreparedPath $e.PreparedPath -Context $e.Context -RunId $RunId -StatePath $e.StatePath
}
function Start-OutlookTestRun($e, $a, $storage = $null) {
    $ops = @($a.Operations); $checks = $a.ResourceChecks; $requests = @($a.Requests)
    if ($storage) { $ops = @($storage.Operations) + $ops; $checks = @{ outlook = $a.ResourceChecks.outlook; onedrive = $storage.ResourceChecks.onedrive }; $requests = @($storage.Requests) + $requests }
    $plan = @(Get-SeedOperationPlan -Session $e.Session -Operations $ops -ResourceChecks $checks)
    Assert-Equal @($plan | Where-Object Action -eq Block).Count 0
    New-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $ops | Out-Null
    New-SeedWriteApproval -Session $e.Session -Plan $plan -Requests $requests -ConfirmTarget "$($e.Config.tenantId)/training01" -StatePath $e.StatePath -RunId training01 -Context $e.Context | Out-Null
    $map = @{}
    if ($storage) { $map = (Invoke-UploadFiles -Session $e.Session -Adapter $storage -Plan $plan).AssetUrlMap }
    $result = Invoke-SeedEmails -Session $e.Session -Adapter $a -Plan $plan -AssetUrlMap $map
    return @{ Output = $result; Plan = $plan; Operations = $ops; Checks = $checks; Map = $map }
}
try {
    Test-Case 'Outlook native REST object inbox responses preserve delivery verification and zero-write reruns' {
        $e = New-OutlookEnvironment
        $record = Get-SeedSessionRecord $e.Session
        $transport = $record.Transport
        $record.Transport = {
            param($Method, $Path, $Body, $RawBody)
            $value = & $transport $Method $Path $Body $RawBody
            if ($Method -ceq 'GET' -and $value -is [Collections.IDictionary]) {
                return $value | ConvertTo-Json -Depth 100 | ConvertFrom-Json
            }
            return $value
        }.GetNewClosure()
        $a = Get-OutlookTestAdapter $e
        $run = Start-OutlookTestRun $e $a
        Assert-True $run.Output.Verified
        $state = Get-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $a.Operations -ForImport
        Set-SeedOutlookRunState -Session $e.Session -Adapter $a -RunState $state
        $plan = @(Get-SeedOperationPlan -Session $e.Session -Operations $a.Operations -ResourceChecks $a.ResourceChecks -RunState $state)
        Assert-Equal @($plan | Where-Object Action -ne Skip).Count 0
        $before = @($e.Model.Ledger | Where-Object Method -ne GET).Count
        $null = Invoke-SeedEmails -Session $e.Session -Adapter $a -Plan $plan -AssetUrlMap @{}
        Assert-True (Test-SeedOutlook -Session $e.Session -Adapter $a).Verified
        Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count $before
    }
    Test-Case 'Outlook native REST object with an empty inbox ID is still rejected before writes' {
        $e = New-OutlookEnvironment
        $record = Get-SeedSessionRecord $e.Session
        $transport = $record.Transport
        $record.Transport = {
            param($Method, $Path, $Body, $RawBody)
            if ($Method -ceq 'GET' -and $Path -match '/mailFolders/inbox\?') { return [pscustomobject]@{ id = '' } }
            & $transport $Method $Path $Body $RawBody
        }.GetNewClosure()
        Assert-Throws { Get-OutlookTestAdapter $e } 'Seed.Outlook.Mailbox' | Out-Null
        Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count 0
    }
    Test-Case 'Outlook normalized body proof never ignores changed links decisions hidden CSS quoted content or tokens' {
        $expected = '<p>Decision <strong>approved</strong>: <a href="https://example.invalid/a?x=1&amp;y=2">12 units</a>.</p><table><tr><td>12</td></tr></table>'
        $normalized = '<html><head><meta charset="utf-8"></head><body><p style="margin:0">Decision <b>approved</b>: <a href="https://example.invalid/a?x=1&amp;y=2">12 units</a>.</p><table><tr><td>12</td></tr></table></body></html>'
        Assert-True (@(Compare-SeedOutlookBody $expected $normalized).Count -gt 0)
        foreach ($actual in @(
            $expected.Replace('/a?', '/b?'), $expected.Replace('<td>12</td>', '<td>13</td>'),
            "<html><head><style>body{display:none}</style></head><body>$expected</body></html>",
            ($expected + '<p>Quoted decision: rejected.</p>'), '<p>{{asset:unknown}}</p>', '<p>incomplete'
        )) { Assert-Throws { Compare-SeedOutlookBody $expected $actual } 'Seed.Outlook.Body' | Out-Null }
    }
    Test-Case 'Outlook three actual authors complete delivery then full rerun and readonly Verify have zero writes' {
        Assert-True ([bool](Get-Command Get-SeedOutlookAdapter -ErrorAction SilentlyContinue)) 'T4 Outlook adapter is not implemented.'
        $e = New-OutlookEnvironment; $a = Get-OutlookTestAdapter $e
        $run = Start-OutlookTestRun $e $a
        Assert-True $run.Output.Verified
        Assert-Equal @($run.Output.Messages).Count 3
        Assert-Equal @($run.Output.Threads).Count 1
        Assert-Equal @($e.Model.Sent.Actor | Sort-Object -Unique).Count 3
        Assert-Equal @($e.Model.Ledger | Where-Object { $_.Method -ne 'GET' }).Count 3
        Assert-True (@($e.Model.Ledger | Where-Object { $_.Method -ne 'GET' -and $_.Path -like "*/$($e.Model.Presenter)/*" }).Count -eq 0)
        Assert-True ($e.Model.Sent[0].Message.subject -match '\[M365Seed:[0-9a-f]{32}\]')
        foreach ($sent in $e.Model.Sent) {
            Assert-True ($e.Config.presenterUpn -in @(@($sent.Message.toRecipients) + @($sent.Message.ccRecipients) | ForEach-Object { $_.emailAddress.address }))
        }
        Assert-Equal $e.Model.Sent[1].Parent $e.Model.Sent[0].InternetMessageId
        Assert-Equal $e.Model.Sent[2].Parent $e.Model.Sent[1].InternetMessageId
        $state = Get-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $a.Operations -ForImport
        Assert-Equal $state.status Completed
        Set-SeedOutlookRunState -Session $e.Session -Adapter $a -RunState $state
        $plan = @(Get-SeedOperationPlan -Session $e.Session -Operations $a.Operations -ResourceChecks $a.ResourceChecks -RunState $state)
        Assert-Equal @($plan | Where-Object Action -ne Skip).Count 0
        $again = Invoke-SeedEmails -Session $e.Session -Adapter $a -Plan $plan -AssetUrlMap @{}
        Assert-Equal $again.Messages $run.Output.Messages
        Assert-True (Test-SeedOutlook -Session $e.Session -Adapter $a).Verified
        Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count 3
    }
    Test-Case 'Outlook real Storage provenance late resolves links under one global approval' {
        $e = New-OutlookEnvironment -WithAssets
        $storage = Get-SeedStorageAdapter -Session $e.Session -Scenario $e.Scenario -PreparedPath $e.PreparedPath -Context $e.Context -RunId training01 -StatePath $e.StatePath
        $a = Get-OutlookTestAdapter $e
        Assert-Equal @($a.Requests).Count 0
        $run = Start-OutlookTestRun $e $a $storage
        Assert-True $run.Output.Verified
        Assert-True ($e.Model.Sent[0].Message.body.content.Contains('href="https://example.sharepoint.com/files/actual&amp;metrics.xlsx"'))
        Assert-True (-not ($e.Model.Sent[0].Message.body.content.Contains('{{')))
        $state = Get-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $run.Operations -ForImport
        Set-SeedStorageRunState -Session $e.Session -Adapter $storage -RunState $state
        Set-SeedOutlookRunState -Session $e.Session -Adapter $a -RunState $state
        $before = @($e.Model.Ledger | Where-Object Method -ne GET).Count
        $plan = @(Get-SeedOperationPlan -Session $e.Session -Operations $run.Operations -ResourceChecks $run.Checks -RunState $state)
        Assert-Equal @($plan | Where-Object Action -ne Skip).Count 0
        $map = (Invoke-UploadFiles -Session $e.Session -Adapter $storage -Plan $plan).AssetUrlMap
        Assert-True (Invoke-SeedEmails -Session $e.Session -Adapter $a -Plan $plan -AssetUrlMap $map).Verified
        Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count $before
    }
    Test-Case 'Outlook completed receipts block false Skip on author sender recipients body headers parent and actual IDs' {
        $e = New-OutlookEnvironment; $a = Get-OutlookTestAdapter $e; Start-OutlookTestRun $e $a | Out-Null
        $state = Get-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $a.Operations
        Set-SeedOutlookRunState -Session $e.Session -Adapter $a -RunState $state
        foreach ($fault in @('Author', 'Sender', 'Recipients', 'Presenter', 'Body', 'Header', 'Parent', 'MessageId', 'Mailbox', 'Profile', 'Pagination')) {
            $e.Model.Fault = $fault
            $plan = @(Get-SeedOperationPlan -Session $e.Session -Operations $a.Operations -ResourceChecks $a.ResourceChecks -RunState $state)
            Assert-True (@($plan | Where-Object Action -eq Block).Count -gt 0) "Missing block: $fault"
            Assert-Throws { Test-SeedOutlook -Session $e.Session -Adapter $a } 'Seed.Outlook' | Out-Null
        }
        $e.Model.Fault = ''
        $inbox = $e.Model.Mail[$e.Model.Presenter]
        $duplicate = Copy-OutlookValue @($inbox.Values)[0]
        $duplicate.id = 'extra-local-id'; $duplicate.internetMessageId = '<duplicate@example.invalid>'; $duplicate.internetMessageHeaders[0].value = $duplicate.internetMessageId
        $inbox[$duplicate.id] = $duplicate
        $plan = @(Get-SeedOperationPlan -Session $e.Session -Operations $a.Operations -ResourceChecks $a.ResourceChecks -RunState $state)
        Assert-True (@($plan | Where-Object Action -eq Block).Count -gt 0) 'Additional run message must block even when every receipted message still exists.'
        Assert-Throws { Test-SeedOutlook -Session $e.Session -Adapter $a } 'Seed.Outlook' | Out-Null
        $inbox.Remove($duplicate.id)
        $changed = Copy-OutlookValue $state; $changed.results[0].objectId = 'foreign'
        $changed | ConvertTo-Json -Depth 100 | Set-Content $e.StatePath -Encoding utf8
        $plan = @(Get-SeedOperationPlan -Session $e.Session -Operations $a.Operations -ResourceChecks $a.ResourceChecks -RunState $state)
        Assert-True (@($plan | Where-Object Action -eq Block).Count -gt 0) 'Stale in-memory receipt must not hide a changed durable journal.'
        Assert-Throws { Test-SeedOutlook -Session $e.Session -Adapter $a } 'Seed.Outlook' | Out-Null
        Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count 3
    }
    Test-Case 'Outlook delayed delivery beyond the old window completes with one POST per message' {
        $e = New-OutlookEnvironment; $a = Get-OutlookTestAdapter $e
        $e.Model.Polls.Clear(); $e.Model.Fault = 'DelayedLong'
        Assert-True (Start-OutlookTestRun $e $a).Output.Verified
        Assert-Equal $e.Model.Sent.Count 3
        Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count 3
        Assert-True ($e.Model.Waits.Count -gt 12)
        Assert-Equal @($e.Model.Waits | Where-Object { $_ -ne 2 }).Count 0
    }
    Test-Case 'Outlook accepted timeout and accepted-but-lost sends stop Unknown without resending' {
        foreach ($fault in @('Timeout', 'Lost', 'LostReply')) {
            $e = New-OutlookEnvironment; $a = Get-OutlookTestAdapter $e
            $e.Model.Polls.Clear(); $e.Model.Fault = $fault
            Assert-Throws { Start-OutlookTestRun $e $a } 'Seed.Outlook.Stopped' | Out-Null
            $state = Get-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $a.Operations
            Assert-Equal $state.status Blocked
            Assert-Equal @($state.results | Where-Object status -eq Unknown).Count 1
            Assert-Equal $e.Model.Sent.Count $(if ($fault -eq 'LostReply') { 2 } else { 1 })
            Assert-True ($e.Model.Waits.Count -le 30)
            Assert-True (($e.Model.Waits | Measure-Object -Sum).Sum -le 60)
            Assert-Throws { Get-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $a.Operations -ForImport } 'Seed.State.Blocked' | Out-Null
            Assert-Throws { Set-SeedOutlookRunState -Session $e.Session -Adapter $a -RunState $state } 'Seed.Outlook' | Out-Null
            Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count $e.Model.Sent.Count
        }
    }
    Test-Case 'Outlook bounded delayed delivery succeeds but missing author parent stops without submitting reply' {
        $e = New-OutlookEnvironment; $a = Get-OutlookTestAdapter $e; $e.Model.Polls.Clear(); $e.Model.Fault = 'Delayed'
        Assert-True (Start-OutlookTestRun $e $a).Output.Verified
        Assert-True ($e.Model.Waits.Count -gt 0)
        $e = New-OutlookEnvironment; $a = Get-OutlookTestAdapter $e; $e.Model.Fault = 'DelayedParent'
        Assert-True (Start-OutlookTestRun $e $a).Output.Verified
        Assert-True ($e.Model.Waits.Count -gt 0)
        $e = New-OutlookEnvironment; $a = Get-OutlookTestAdapter $e; $e.Model.Fault = 'MissingParent'
        Assert-Throws { Start-OutlookTestRun $e $a } 'Seed.Outlook.Stopped' | Out-Null
        Assert-Equal $e.Model.Sent.Count 1
        $state = Get-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $a.Operations
        Assert-Throws { Get-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $a.Operations -ForImport } 'Seed.State.Blocked' | Out-Null
        Assert-Equal @($state.events | Where-Object action -eq Submit).Count 1
    }
    Test-Case 'Outlook adapter context scope roots collision and forged completed state fail closed' {
        $e = New-OutlookEnvironment; $a = Get-OutlookTestAdapter $e
        $other = Get-OutlookTestAdapter $e 'other-run'
        Assert-True ($a.Requests[0].Body.message.subject -cne $other.Requests[0].Body.message.subject)
        $forged = @{ status = 'Completed'; runId = 'training01'; context = $e.Context; results = @() }
        Assert-Throws { Set-SeedOutlookRunState -Session $e.Session -Adapter $a -RunState $forged } 'Seed.Outlook' | Out-Null
        $bad = [pscustomobject]@{ AdapterId = $a.AdapterId; Operations = $a.Operations; Requests = $a.Requests; ResourceChecks = $a.ResourceChecks; RequestCheck = $a.RequestCheck }
        Assert-Throws { Invoke-SeedEmails -Session $e.Session -Adapter $bad -Plan @($a.Operations) -AssetUrlMap @{} } 'Seed.Outlook.Adapter' | Out-Null
        $subject = $a.Requests[0].Body.message.subject
        $e.Model.Mail[$e.Model.Presenter].collision = @{ id = 'collision'; subject = $subject; internetMessageId = '<foreign@example.invalid>' }
        $plan = @(Get-SeedOperationPlan -Session $e.Session -Operations $a.Operations -ResourceChecks $a.ResourceChecks)
        Assert-True (@($plan | Where-Object Action -eq Block).Count -gt 0)
        Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count 0
    }
    Test-Case 'Outlook initial exact request cannot replace sender subject body or Presenter recipients' {
        foreach ($fault in @('Subject', 'Body', 'Mailbox', 'Recipients')) {
            $e = New-OutlookEnvironment; $a = Get-OutlookTestAdapter $e
            $plan = @(Get-SeedOperationPlan -Session $e.Session -Operations $a.Operations -ResourceChecks $a.ResourceChecks)
            New-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $a.Operations | Out-Null
            $r = Copy-OutlookValue $a.Requests[0]
            switch ($fault) {
                Subject { $r.Body.message.subject = 'foreign' }
                Body { $r.Body.message.body.content = '<p>foreign</p>' }
                Mailbox { $r.Path = "/users/$($e.Model.Ids.bob)/sendMail" }
                Recipients { $r.Body.message.ccRecipients = @() }
            }
            Assert-Throws { New-SeedWriteApproval -Session $e.Session -Plan $plan -Requests @($r) -ConfirmTarget "$($e.Config.tenantId)/training01" -StatePath $e.StatePath -RunId training01 -Context $e.Context } 'Seed.Approval.Outlook' | Out-Null
            Assert-Equal @($e.Model.Ledger | Where-Object Method -ne GET).Count 0
        }
    }
    Test-Case 'Outlook arbitrary asset maps and unresolved tokens are rejected before any mail write' {
        $e = New-OutlookEnvironment -WithAssets
        $storage = Get-SeedStorageAdapter -Session $e.Session -Scenario $e.Scenario -PreparedPath $e.PreparedPath -Context $e.Context -RunId training01 -StatePath $e.StatePath
        $a = Get-OutlookTestAdapter $e
        $plan = @(Get-SeedOperationPlan -Session $e.Session -Operations $a.Operations -ResourceChecks $a.ResourceChecks)
        $fake = @{ metrics = @{ webUrl = 'https://example.sharepoint.com/files/fake.xlsx'; targetWorkload = 'OneDrive'; resourceId = 'fake'; sourceSha256 = ('a' * 64); presenterVerified = $true } }
        Assert-Throws { Invoke-SeedEmails -Session $e.Session -Adapter $a -Plan $plan -AssetUrlMap $fake } 'Seed.Outlook' | Out-Null
        Assert-Equal $e.Model.Sent.Count 0
        $e = New-OutlookEnvironment; $e.Scenario.outlook.threads[0].messages[0].bodyHtml = '<p>{{asset:unknown}}</p>'
        Assert-Throws { Get-OutlookTestAdapter $e } 'Seed.Outlook' | Out-Null
    }
    Test-Case 'Outlook full readback rejects cross-mailbox Internet ID mismatch during first delivery' {
        $e = New-OutlookEnvironment; $a = Get-OutlookTestAdapter $e; $e.Model.Fault = 'CrossMailboxInternet'
        Assert-Throws { Start-OutlookTestRun $e $a } 'Seed.Outlook.Stopped' | Out-Null
        $state = Get-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $a.Operations
        Assert-Equal $state.status Blocked
        Assert-Equal @($state.results | Where-Object status -eq Unknown).Count 1
        Assert-Equal $e.Model.Sent.Count 1
    }
    Test-Case 'Outlook exact late binding rejects changed parent sender body headers and recipients before Submit' {
        $e = New-OutlookEnvironment; $a = Get-OutlookTestAdapter $e
        $plan = @(Get-SeedOperationPlan -Session $e.Session -Operations $a.Operations -ResourceChecks $a.ResourceChecks)
        New-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $a.Operations | Out-Null
        New-SeedWriteApproval -Session $e.Session -Plan $plan -Requests $a.Requests -ConfirmTarget "$($e.Config.tenantId)/training01" -StatePath $e.StatePath -RunId training01 -Context $e.Context | Out-Null
        Write-SeedGraph -Session $e.Session -Request $a.Requests[0] | Out-Null
        $o = Get-SeedOutlookRecord $e.Session $a
        $snapshot = Get-SeedOutlookSnapshot $e.Session $o $a.Operations[0]
        Write-SeedRunEvent -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $a.Operations -OperationId $a.Operations[0].OperationId -Workload outlook -Action Verify -Status Verified -ObjectId $snapshot.presenterMessageId -ReadBack $snapshot | Out-Null
        $expected = (Get-SeedOutlookRequest $e.Session $o $a.Operations[1] @{ Assets = @{}; Parents = @{} }).Request
        foreach ($fault in @('Parent', 'Sender', 'Body', 'Header', 'Recipients', 'Subject')) {
            $request = Copy-OutlookValue $expected
            switch ($fault) {
                Parent { $request.Path = "/users/$($e.Model.Ids.bob)/messages/foreign/reply" }
                Sender { $request.Path = $request.Path.Replace($e.Model.Ids.bob, $e.Model.Ids.charlie) }
                Body { $request.Body.message.body.content = '<p>Wrong decision.</p>' }
                Header { $request.Body.message.internetMessageHeaders = @(@{ name = 'x-foreign'; value = 'foreign' }) }
                Recipients { $request.Body.message.toRecipients = @() }
                Subject { $request.Body.message.subject = 'foreign' }
            }
            Assert-Throws { Write-SeedGraph -Session $e.Session -Request $request -RequestCheck $a.RequestCheck } 'Seed.Approval|Seed.Outlook' | Out-Null
        }
        Assert-Equal $e.Model.Sent.Count 1
        $state = Get-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $a.Operations
        Assert-Equal @($state.events | Where-Object action -eq Submit).Count 1
        $replacement = '<replacement-parent@example.invalid>'
        foreach ($mailbox in $e.Model.Mail.Values) {
            foreach ($mail in $mailbox.Values) {
                $mail.internetMessageId = $replacement
                $mail.internetMessageHeaders[0].value = $replacement
            }
        }
        Assert-Throws { Write-SeedGraph -Session $e.Session -Request $expected -RequestCheck $a.RequestCheck } 'Seed.Approval|Seed.Outlook' | Out-Null
        Assert-Equal $e.Model.Sent.Count 1
    }
    Test-Case 'Outlook Storage map copies mutations missing keys and changed remote bytes cannot authorize sending' {
        $e = New-OutlookEnvironment -WithAssets
        $storage = Get-SeedStorageAdapter -Session $e.Session -Scenario $e.Scenario -PreparedPath $e.PreparedPath -Context $e.Context -RunId training01 -StatePath $e.StatePath
        $a = Get-OutlookTestAdapter $e
        $ops = @($storage.Operations) + @($a.Operations)
        $checks = @{ outlook = $a.ResourceChecks.outlook; onedrive = $storage.ResourceChecks.onedrive }
        $plan = @(Get-SeedOperationPlan -Session $e.Session -Operations $ops -ResourceChecks $checks)
        New-SeedRunState -Path $e.StatePath -RunId training01 -Context $e.Context -Operations $ops | Out-Null
        New-SeedWriteApproval -Session $e.Session -Plan $plan -Requests @($storage.Requests) -ConfirmTarget "$($e.Config.tenantId)/training01" -StatePath $e.StatePath -RunId training01 -Context $e.Context | Out-Null
        $map = (Invoke-UploadFiles -Session $e.Session -Adapter $storage -Plan $plan).AssetUrlMap
        $copy = Copy-OutlookValue $map
        Assert-Throws { Invoke-SeedEmails -Session $e.Session -Adapter $a -Plan $plan -AssetUrlMap $copy } 'Seed.Outlook.Asset' | Out-Null
        foreach ($field in @('webUrl', 'sourceSha256', 'resourceId', 'targetWorkload', 'presenterVerified')) {
            $saved = $map.metrics[$field]
            $map.metrics[$field] = $(if ($field -eq 'presenterVerified') { $false } else { 'foreign' })
            Assert-Throws { Invoke-SeedEmails -Session $e.Session -Adapter $a -Plan $plan -AssetUrlMap $map } 'Seed.Outlook.Asset' | Out-Null
            $map.metrics[$field] = $saved
        }
        $saved = $map.metrics; $map.Remove('metrics')
        Assert-Throws { Invoke-SeedEmails -Session $e.Session -Adapter $a -Plan $plan -AssetUrlMap $map } 'Seed.Outlook.Asset' | Out-Null
        $map.metrics = $saved
        $e.Model.Items['asset-item'].file.hashes.sha256Hash = '0' * 64
        Assert-Throws { Invoke-SeedEmails -Session $e.Session -Adapter $a -Plan $plan -AssetUrlMap $map } 'Seed.Storage|Seed.Outlook.Asset' | Out-Null
        Assert-Equal $e.Model.Sent.Count 0
    }
    Test-Case 'Outlook branch reply uses its declared parent rather than the most recent message' {
        $e = New-OutlookEnvironment -Branch; $a = Get-OutlookTestAdapter $e
        Assert-True (Start-OutlookTestRun $e $a).Output.Verified
        Assert-Equal $e.Model.Sent[2].Parent $e.Model.Sent[0].InternetMessageId
    }
} finally {
    foreach ($session in @($script:SeedSessions.Values | ForEach-Object { $_.Handle })) { Close-SeedSession $session }
    Remove-Item -LiteralPath $outlookScratch -Recurse -Force
}
