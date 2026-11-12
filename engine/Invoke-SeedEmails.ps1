function Get-SeedOutlookRecord {
    param($Session, $Adapter)
    $record = Get-SeedSessionRecord $Session
    if ($null -eq $Adapter -or -not $Adapter.PSObject.Properties['AdapterId'] -or -not $record.Contains('OutlookAdapters') -or
        -not $record.OutlookAdapters.ContainsKey($Adapter.AdapterId)) { throw 'Seed.Outlook.Adapter: Authentic session-bound adapter required.' }
    $outlook = $record.OutlookAdapters[$Adapter.AdapterId]
    if (-not [object]::ReferenceEquals($outlook.Handle, $Adapter) -or
        (Get-SeedFingerprint $Adapter.Operations) -cne $outlook.OperationsFingerprint -or
        (Get-SeedFingerprint @{ requests = @($Adapter.Requests) }) -cne $outlook.RequestsFingerprint -or
        -not [object]::ReferenceEquals($Adapter.RequestCheck, $outlook.RequestCheck) -or
        -not [object]::ReferenceEquals($Adapter.ResourceChecks.outlook, $outlook.ResourceCheck)) { throw 'Seed.Outlook.Adapter: Adapter scope or callbacks changed.' }
    return $outlook
}

function Read-SeedOutlookPrepared {
    param([string]$PreparedPath, $Scenario)
    $code = @'
import hashlib,json,sys
from pathlib import Path
sys.path.insert(0,str(Path.cwd()))
from generator.validate_pack import canonical_bytes,load_json,reject_reparse,safe_path,validate_files
from generator.build_scenario import persona_fingerprint
d=json.load(sys.stdin); root=Path(d["root"])
def sha(b): return hashlib.sha256(b).hexdigest()
def fail(): raise ValueError("invalid prepared package")
reject_reparse(root)
m=load_json(root/"prepared-manifest.json"); c=load_json(root/"COMPLETE.json")
if m["fingerprint"] != sha(canonical_bytes({k:v for k,v in m.items() if k!="fingerprint"})): fail()
if c!={"schemaVersion":"1.0","fingerprint":m["fingerprint"],"manifestSha256":sha((root/"prepared-manifest.json").read_bytes())}: fail()
if load_json(root/"scenario.json")!=d["scenario"]: fail()
seen=set(); dirs=set(); expected_dirs=set()
for name,digest in m["files"].items():
    p=safe_path(root,name)
    if sha(p.read_bytes())!=digest: fail()
    for parent in p.relative_to(root).parents:
        if str(parent)!=".": expected_dirs.add(str(parent))
for p in root.rglob("*"):
    reject_reparse(p); rel=str(p.relative_to(root))
    if p.is_file():
        if rel not in ("prepared-manifest.json","COMPLETE.json"): seen.add(rel)
    elif p.is_dir(): dirs.add(rel)
    else: fail()
if seen!=set(m["files"]) or dirs!=expected_dirs: fail()
sf=sha(canonical_bytes({p.name:sha(p.read_bytes()) for p in Path("schemas").glob("*.schema.json")}))
bf=sha(canonical_bytes({n:sha((Path("generator")/n).read_bytes()) for n in ("build_scenario.py","validate_pack.py")}))
if m["schemaFingerprint"]!=sf or m["builderFingerprint"]!=bf: fail()
if validate_files(root/"scenario.json",root/"personas"/"personas.json"): fail()
if persona_fingerprint(root/"personas"/"personas.json")!=m["personaPackFingerprint"]: fail()
for a in m["assets"]:
    if sha(safe_path(root,a["relativePath"]).read_bytes())!=a["sha256"]: fail()
if len({a["id"] for a in m["assets"]})!=len(m["assets"]) or set(a["id"] for a in m["assets"])!=set(a["id"] for a in d["scenario"]["assets"]): fail()
print(json.dumps(m))
'@
    try { return Invoke-SeedPython -Code $code -InputObject @{ root = $PreparedPath; scenario = $Scenario } }
    catch { throw 'Seed.Outlook.Prepared: Exact complete canonical prepared package and source bytes required.' }
}

function Assert-SeedOutlookActors {
    param($Session, $Outlook)
    $record = Get-SeedSessionRecord $Session
    if ($null -eq $record.Identity -or (Get-SeedFingerprint $record.Identity) -cne $Outlook.IdentityFingerprint -or
        $null -eq $record.ServiceGate -or 'outlook' -cnotin $record.ServiceGate.Workloads -or
        $record.ServiceGate.ActorFingerprint -cne $record.Identity.ActorFingerprint) { throw 'Seed.Outlook.Identity: Current T2 identity and service provenance required.' }
    foreach ($permission in @('Mail.Read', 'Mail.Send')) {
        if (-not (Test-SeedAppPermission -Granted $record.Permissions -Required $permission)) { throw 'Seed.Outlook.Scope: Mail.Read and Mail.Send application roles required.' }
    }
    foreach ($role in $Outlook.Roles) {
        $actor = $record.Identity.Roles[$role]
        $profile = ConvertTo-SeedMap (Invoke-SeedGraph -Session $Session -Method GET -Path "/users/$($actor.ObjectId)?`$select=id,userPrincipalName,displayName,jobTitle,department,companyName,officeLocation,usageLocation,accountEnabled,userType")
        if ($profile.id -ine $actor.ObjectId -or $profile.userPrincipalName -ine $actor.Upn -or
            $profile.accountEnabled -cne $true -or $profile.userType -cne 'Member') { throw 'Seed.Outlook.Identity: Actual enabled mailbox identity changed.' }
        if ($role -cne 'Presenter') {
            $values = @{ managerObjectId = $null }
            foreach ($f in @('displayName', 'jobTitle', 'department', 'companyName', 'officeLocation', 'usageLocation')) { $values[$f] = $profile[$f] }
            try { $values.managerObjectId = (Invoke-SeedGraph -Session $Session -Method GET -Path "/users/$($actor.ObjectId)/manager?`$select=id").id }
            catch { if ($_.Exception.Message -notlike 'Seed.Graph.404:*') { throw } }
            if ((Get-SeedFingerprint $values) -cne $actor.ProfileFingerprint) { throw 'Seed.Outlook.Identity: Applied profile or manager changed.' }
        }
        $folder = ConvertTo-SeedMap (Invoke-SeedGraph -Session $Session -Method GET -Path "/users/$($actor.ObjectId)/mailFolders/inbox?`$select=id")
        Assert-SeedFields $folder @('id') 'Seed.Outlook.Mailbox'
        if ([string]::IsNullOrWhiteSpace($folder.id)) { throw 'Seed.Outlook.Mailbox: Actual Inbox required.' }
        if ($Outlook.Inboxes.ContainsKey($actor.ObjectId) -and $Outlook.Inboxes[$actor.ObjectId] -cne $folder.id) { throw 'Seed.Outlook.Mailbox: Inbox identity changed.' }
        $Outlook.Inboxes[$actor.ObjectId] = $folder.id
    }
}

function New-SeedOutlookMessageBody {
    param($Scope, [string]$Html)
    $message = @{
        subject = $Scope.Subject; body = @{ contentType = 'HTML'; content = $Html }
        toRecipients = @($Scope.ToAddresses | ForEach-Object { @{ emailAddress = @{ address = $_ } } })
        ccRecipients = @($Scope.CcAddresses | ForEach-Object { @{ emailAddress = @{ address = $_ } } })
    }
    if ($Scope.Kind -ceq 'Send') {
        $message.internetMessageHeaders = @(@{ name = 'x-m365seed-message'; value = $Scope.Marker })
        return @{ message = $message; saveToSentItems = $true }
    }
    return @{ message = $message }
}

function Get-SeedOutlookAdapter {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Scenario, [Parameter(Mandatory)][string]$PreparedPath,
        [Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$RunId, [Parameter(Mandatory)][string]$StatePath)
    $record = Get-SeedSessionRecord $Session
    if ($record.Kind -cne 'App' -or -not $record.Contains('Identity') -or $null -eq $record.Identity -or
        -not $record.Contains('ServiceGate') -or $null -eq $record.ServiceGate) { throw 'Seed.Outlook.Identity: Run T2 identity and service checks first.' }
    $Scenario = ConvertTo-SeedMap $Scenario; $Context = ConvertTo-SeedMap $Context
    try { Assert-SeedSchema $Scenario scenario; $StatePath = Assert-SeedStatePath $StatePath }
    catch { throw 'Seed.Outlook.Input: Canonical scenario and safe journal path required.' }
    $PreparedPath = [IO.Path]::GetFullPath($PreparedPath)
    $manifest = Read-SeedOutlookPrepared $PreparedPath $Scenario
    if (-not $Scenario.Contains('outlook') -or [string]::IsNullOrWhiteSpace($RunId) -or
        $Context.tenantId -ine $record.TenantId -or $Context.clientId -ine $record.ClientId -or
        $Context.presenterUpn -ine $record.Identity.Presenter.Upn -or $Context.scenarioId -cne $Scenario.scenario.id -or
        $Context.personaPackId -cne $Scenario.scenario.personaPackId -or
        $Context.preparedFingerprint -cne $manifest.fingerprint -or $Context.personaPackFingerprint -cne $manifest.personaPackFingerprint -or
        $Context.personaPackFingerprint -cne $record.Identity.PersonaPackFingerprint -or $Context.bindingFingerprint -cne $record.Identity.BindingFingerprint -or
        $Context.instanceId -cne $record.Identity.InstanceId -or $Context.scenarioId -cne $record.Identity.ScenarioId) { throw 'Seed.Outlook.Context: Exact prepared, identity and run context required.' }
    $outlook = @{
        Session = $Session; Context = $Context; RunId = $RunId; StatePath = $StatePath; Scenario = $Scenario; PreparedPath = $PreparedPath
        IdentityFingerprint = Get-SeedFingerprint $record.Identity; PresenterId = $record.Identity.Presenter.ObjectId
        Roles = @(@(Get-SeedReferencedRoles $Scenario outlook) + @('Presenter') | Sort-Object -Unique)
        Operations = [Collections.Generic.List[object]]::new(); ById = @{}; LogicalIds = @{}; Inboxes = @{}
        Ids = @{}; Evidence = @{}; RunState = $null; AssetUrlMap = $null; Assets = @{}; Resolved = @{}
    }
    $actorIds = @{}
    foreach ($role in $outlook.Roles) {
        if (-not $record.Identity.Roles.ContainsKey($role)) { throw 'Seed.Outlook.Actor: All mailbox roles must be T2-resolved.' }
        $actor = $record.Identity.Roles[$role]
        if ($actorIds.ContainsKey($actor.ObjectId)) { throw 'Seed.Outlook.Actor: Distinct roles must use distinct actual mailbox IDs.' }
        $actorIds[$actor.ObjectId] = $true
    }
    foreach ($thread in $Scenario.outlook.threads) {
        $namespace = (Get-SeedFingerprint @{ context = $Context; runId = $RunId; threadId = $thread.id }).Substring(0, 32)
        foreach ($message in $thread.messages) {
            $key = "outlook/$($thread.id)/$($message.id)"
            $id = 'm' + (Get-SeedFingerprint $key).Substring(0, 30)
            $sender = $record.Identity.Roles[$message.fromRole]
            if ($message.fromRole -ceq 'Presenter' -or $sender.ObjectId -ieq $outlook.PresenterId) { throw 'Seed.Outlook.Actor: Presenter never authors historical mail.' }
            $parent = ''
            if ($message.action -ceq 'reply') {
                if (-not $outlook.LogicalIds.ContainsKey($message.parentId)) { throw 'Seed.Outlook.Parent: Earlier exact thread parent required.' }
                $parent = $outlook.LogicalIds[$message.parentId]
                $prior = $outlook.ById[$parent].OutlookScope
                if ($prior.ThreadId -cne $thread.id -or $sender.Upn.ToLowerInvariant() -cnotin (@($prior.ToAddresses) + @($prior.CcAddresses))) { throw 'Seed.Outlook.Parent: Reply author must have received the exact earlier parent.' }
            }
            $scope = @{
                Kind = $(if ($message.action -ceq 'send') { 'Send' } else { 'Reply' }); ThreadId = $thread.id; MessageId = $message.id; StoryId = $thread.storyId
                ParentOperationId = $parent; SenderId = $sender.ObjectId; SenderUpn = $sender.Upn.ToLowerInvariant()
                ToAddresses = @($message.toRoles | ForEach-Object { $record.Identity.Roles[$_].Upn.ToLowerInvariant() } | Sort-Object)
                CcAddresses = @($message.ccRoles | ForEach-Object { $record.Identity.Roles[$_].Upn.ToLowerInvariant() } | Sort-Object)
                Subject = "$($message.subject) [M365Seed:$namespace]"; BodyHtml = $message.bodyHtml; AssetRefs = @($message.assetRefs)
                Marker = Get-SeedFingerprint @{ context = $Context; runId = $RunId; thread = $thread.id; message = $message }
                InitialRequest = $null; Assets = @{}
            }
            $recipients = @($scope.ToAddresses) + @($scope.CcAddresses)
            if ($record.Identity.Presenter.Upn.ToLowerInvariant() -cnotin $recipients -or @($recipients | Sort-Object -Unique).Count -ne $recipients.Count) { throw 'Seed.Outlook.Presenter: Presenter required in every exact To/CC set.' }
            foreach ($assetId in $scope.AssetRefs) {
                $asset = @($manifest.assets | Where-Object id -CEQ $assetId)
                if ($asset.Count -ne 1) { throw 'Seed.Outlook.Asset: Exact prepared asset required.' }
                $matches = @()
                if ($record.Contains('StorageAdapters')) {
                    foreach ($storage in $record.StorageAdapters.Values) {
                        if ($storage.RunId -cne $RunId -or $storage.StatePath -cne $StatePath -or
                            (Get-SeedFingerprint $storage.Context) -cne (Get-SeedFingerprint $Context)) { continue }
                        $null = Get-SeedStorageRecord $Session $storage.Handle
                        foreach ($op in $storage.Operations) {
                            if ($op.StorageScope.Kind -ceq 'Content' -and $op.StorageScope.AssetId -ceq $assetId -and $op.StorageScope.Sha256 -ceq $asset[0].sha256) { $matches += $op }
                        }
                    }
                }
                if ($matches.Count -ne 1) { throw 'Seed.Outlook.Asset: Declare one authentic same-run Storage content operation before planning mail.' }
                $a = @{ Sha256 = $asset[0].sha256; Workload = $asset[0].destination.workload; OperationId = $matches[0].OperationId }
                $scope.Assets[$assetId] = $a; $outlook.Assets[$assetId] = $a
            }
            if ($scope.Kind -ceq 'Send' -and $scope.AssetRefs.Count -eq 0) {
                $scope.InitialRequest = @{ Method = 'POST'; Path = "/users/$($scope.SenderId)/sendMail"; Body = New-SeedOutlookMessageBody $scope $scope.BodyHtml }
            }
            $op = @{
                OperationId = $id; Workload = 'outlook'; TargetKey = $key; TargetId = $null; OutlookScope = $scope
                DataFingerprint = Get-SeedFingerprint @{ context = $Context; runId = $RunId; scope = $scope; identity = $outlook.IdentityFingerprint }
                ActorFingerprint = $outlook.IdentityFingerprint; PresenterEvidence = @{ verified = $true; objectId = $outlook.PresenterId }
                SideEffects = @("Send one real $($scope.Kind) as $($scope.SenderId) to the exact To/CC set including Presenter; subject: $($scope.Subject). No resend or repair.")
            }
            if ($outlook.ById.ContainsKey($id) -or $outlook.LogicalIds.ContainsKey($message.id)) { throw 'Seed.Outlook.Duplicate: Distinct logical messages required.' }
            $outlook.Operations.Add($op); $outlook.ById[$id] = $op; $outlook.LogicalIds[$message.id] = $id
        }
    }
    Assert-SeedOutlookActors $Session $outlook
    $check = { param($s, $o) Get-SeedOutlookProof -Session $s -Outlook $outlook -Operation $o }.GetNewClosure()
    $validator = { param($s, $o, $r) Test-SeedOutlookRequest -Session $s -Outlook $outlook -Operation $o -Request $r }.GetNewClosure()
    $requests = @($outlook.Operations | Where-Object { $null -ne $_.OutlookScope.InitialRequest } | ForEach-Object {
        @{ OperationId = $_.OperationId; Method = 'POST'; Path = $_.OutlookScope.InitialRequest.Path; Body = $_.OutlookScope.InitialRequest.Body }
    })
    $handle = [pscustomobject]@{ AdapterId = [guid]::NewGuid().ToString(); Operations = @($outlook.Operations.ToArray()); ResourceChecks = @{ outlook = $check }; Requests = $requests; RequestCheck = $validator }
    $outlook.Handle = $handle; $outlook.OperationsFingerprint = Get-SeedFingerprint $handle.Operations; $outlook.RequestsFingerprint = Get-SeedFingerprint @{ requests = @($requests) }
    $outlook.ResourceCheck = $check; $outlook.RequestCheck = $validator
    if (-not $record.Contains('OutlookAdapters')) { $record.OutlookAdapters = @{} }
    $record.OutlookAdapters[$handle.AdapterId] = $outlook
    return $handle
}

function Set-SeedOutlookRunState {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Adapter, [Parameter(Mandatory)]$RunState)
    $outlook = Get-SeedOutlookRecord $Session $Adapter
    if (-not $script:SeedValidatedStates.ContainsKey((Get-SeedFingerprint $RunState)) -or
        $RunState.runId -cne $outlook.RunId -or (Get-SeedFingerprint $RunState.context) -cne (Get-SeedFingerprint $outlook.Context) -or
        $RunState.status -cnotin @('Planned', 'Completed')) { throw 'Seed.Outlook.State: Exact T2-validated Planned or globally Completed journal required; no partial resume.' }
    foreach ($op in $outlook.Operations) {
        $marker = @($RunState.events | Where-Object { $_.action -ceq 'Plan' -and $_.id -ceq $op.OperationId -and $_.workload -ceq 'outlook' })
        $result = @($RunState.results | Where-Object { $_.id -ceq $op.OperationId -and $_.workload -ceq 'outlook' })
        if ($marker.Count -ne 1 -or $marker[0].objectId -cne ('plan-sha256:' + (Get-SeedOperationDigest $op)) -or $result.Count -ne 1 -or
            ($RunState.status -ceq 'Completed' -and $result[0].status -cne 'Verified')) { throw 'Seed.Outlook.State: Complete exact Outlook operation set required.' }
    }
    Assert-SeedOutlookJournal $outlook $RunState
    $outlook.RunState = ConvertTo-SeedMap $RunState; $outlook.Ids.Clear(); $outlook.Evidence.Clear()
    foreach ($r in $RunState.results) {
        if ($r.workload -ceq 'outlook' -and $r.status -ceq 'Verified' -and $outlook.ById.ContainsKey($r.id)) { $outlook.Ids[$r.id] = $r.objectId }
    }
}

function Assert-SeedOutlookJournal {
    param($Outlook, $RunState)
    try {
        $path = Assert-SeedStatePath $Outlook.StatePath
        if ((Get-Item -LiteralPath $path).Length -gt 16777216) { throw 'oversized' }
        $current = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 100
        if ((Get-SeedFingerprint $current) -cne (Get-SeedFingerprint $RunState)) { throw 'changed' }
    } catch { throw 'Seed.Outlook.State: Durable journal differs from the exact validated state; preserve it without repair.' }
}

function Resolve-SeedOutlookAssets {
    param($Session, $Outlook, $AssetUrlMap = $null)
    if ($Outlook.Assets.Count -eq 0) { return @{ Assets = @{}; Parents = @{} } }
    $record = Get-SeedSessionRecord $Session
    if ($null -eq $AssetUrlMap) { $AssetUrlMap = $Outlook.AssetUrlMap }
    if ($null -eq $AssetUrlMap -and $null -ne $Outlook.RunState -and $Outlook.RunState.status -ceq 'Completed' -and $record.Contains('StorageAdapters')) {
        foreach ($s in $record.StorageAdapters.Values) {
            if ($s.RunId -ceq $Outlook.RunId -and (Get-SeedFingerprint $s.Context) -ceq (Get-SeedFingerprint $Outlook.Context) -and
                $null -ne $s.RunState -and $s.RunState.status -ceq 'Completed') {
                $AssetUrlMap = (Test-SeedStorage -Session $Session -Adapter $s.Handle).AssetUrlMap
                break
            }
        }
    }
    $provenance = @()
    if ($record.Contains('StorageAssetMaps')) {
        $provenance = @($record.StorageAssetMaps | Where-Object { [object]::ReferenceEquals($_.Map, $AssetUrlMap) })
    }
    if ($provenance.Count -ne 1 -or $provenance[0].RunId -cne $Outlook.RunId -or
        $provenance[0].ContextFingerprint -cne (Get-SeedFingerprint $Outlook.Context) -or
        (Get-SeedFingerprint $AssetUrlMap) -cne $provenance[0].Fingerprint) { throw 'Seed.Outlook.Asset: Only an unchanged same-session, same-run verified Storage result is accepted.' }
    $storage = Get-SeedStorageRecord $Session $provenance[0].Adapter
    Assert-SeedStorageActors $Session $storage; Assert-SeedStorageSources $storage
    $state = $Outlook.RunState
    if ($null -ne $record.Approval) {
        $a = $record.Approval
        if ($a.RunId -cne $Outlook.RunId -or $a.Path -cne $Outlook.StatePath -or
            (Get-SeedFingerprint $a.Context) -cne (Get-SeedFingerprint $Outlook.Context)) { throw 'Seed.Outlook.Asset: Active approval belongs to a different global run.' }
        $state = Get-SeedRunState -Path $a.Path -RunId $a.RunId -Context $a.Context -Operations $a.Operations
    }
    if ($null -eq $state -or $state.status -cnotin @('Running', 'Completed')) { throw 'Seed.Outlook.Asset: Verified Storage operations in the exact global journal required.' }
    $resolved = @{}; $parents = @{}
    foreach ($assetId in $Outlook.Assets.Keys) {
        if (-not $AssetUrlMap.Contains($assetId)) { throw 'Seed.Outlook.Asset: Referenced asset map key missing.' }
        $expected = $Outlook.Assets[$assetId]; $entry = $AssetUrlMap[$assetId]
        $op = $storage.ById[$expected.OperationId]
        if ($null -eq $op -or $entry.sourceSha256 -cne $expected.Sha256 -or $entry.presenterVerified -cne $true -or
            $entry.targetWorkload -cne $(if ($expected.Workload -ceq 'onedrive') { 'OneDrive' } else { 'SharePoint' })) { throw 'Seed.Outlook.Asset: Source, workload or Presenter proof differs.' }
        $snapshot = Get-SeedStorageSnapshot $Session $storage $op
        $result = @($state.results | Where-Object { $_.id -ceq $op.OperationId -and $_.workload -ceq $op.Workload -and $_.status -ceq 'Verified' })
        if ($result.Count -ne 1 -or $result[0].objectId -cne $entry.resourceId -or $snapshot.id -cne $entry.resourceId -or
            $snapshot.webUrl -cne $entry.webUrl -or $snapshot.sha256 -cne $entry.sourceSha256 -or
            (Get-SeedFingerprint $snapshot) -cne $result[0].evidence.sha256) { throw 'Seed.Outlook.Asset: Current authoritative Storage content, link or receipt differs.' }
        $resolved[$assetId] = $entry.webUrl
        $parents[$assetId] = @{ OperationId = $op.OperationId; ObjectId = $snapshot.id }
    }
    $Outlook.AssetUrlMap = $AssetUrlMap
    return @{ Assets = $resolved; Parents = $parents }
}

function Get-SeedOutlookHtml {
    param($Scope, $Assets)
    $html = $Scope.BodyHtml
    foreach ($assetId in $Scope.AssetRefs) {
        if (-not $Assets.ContainsKey($assetId)) { throw 'Seed.Outlook.Asset: Resolve every declared asset before sending.' }
        $html = $html.Replace('{{asset:' + $assetId + '}}', [Net.WebUtility]::HtmlEncode($Assets[$assetId]))
    }
    if ($html.Contains('{{') -or $html.Contains('}}')) { throw 'Seed.Outlook.Asset: Unresolved template syntax is never sent.' }
    return $html
}

function Compare-SeedOutlookBody {
    param([string]$ExpectedHtml, [string]$ActualHtml)
    $code = @'
import json,re,sys
from html.parser import HTMLParser
d=json.load(sys.stdin)
TAGS={"p","br","strong","em","b","i","u","table","thead","tbody","tr","th","td","a","ul","ol","li"}
class Proof(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True); self.stack=[]; self.events=[]; self.head=False
    def handle_starttag(self,t,attrs):
        a=dict(attrs)
        if len(a)!=len(attrs): raise ValueError("duplicate attribute")
        if t not in TAGS|{"html","head","body","meta","style","div","span"}: raise ValueError("unsupported server HTML")
        if t=="head": self.head=True
        if self.head:
            if t not in {"head","meta","style"}: raise ValueError("unsupported head")
            if t=="meta" and (set(a)-{"charset","http-equiv","content"} or a.get("http-equiv","content-type").lower()!="content-type"): raise ValueError("unsupported meta")
        else:
            if set(a)-({"href","style","class","dir","lang"} if t=="a" else {"style","class","dir","lang"}): raise ValueError("unsupported attributes")
            for item in a.get("style","").split(";"):
                if not item.strip(): continue
                k,_,v=item.partition(":")
                if k.strip().lower() not in {"margin","margin-top","margin-bottom","margin-left","margin-right","font-family","font-size","color","background-color","border","border-collapse","padding","text-align","line-height"}: raise ValueError("unsupported presentation")
                if re.search(r"(?i)(url|expression|transparent|(^|[ :])0(?:px|pt|em)?$)",v.strip()) and k.strip().lower() not in {"margin","margin-top","margin-bottom","margin-left","margin-right","padding","border"}: raise ValueError("hidden presentation")
            if t not in {"html","body","span"}:
                n={"b":"strong","i":"em","div":"p"}.get(t,t)
                event={"start":n}
                if t=="a": event["href"]=a.get("href","")
                self.events.append(event)
        if t not in {"br","meta"}: self.stack.append(t)
    def handle_endtag(self,t):
        if not self.stack or self.stack.pop()!=t: raise ValueError("unbalanced HTML")
        if t=="head": self.head=False; return
        if not self.head and t not in {"html","body","span"}: self.events.append({"end":{"b":"strong","i":"em","div":"p"}.get(t,t)})
    def handle_startendtag(self,t,a):
        if t not in {"br","meta"}: raise ValueError("unsupported self closing tag")
        self.handle_starttag(t,a)
    def handle_data(self,s):
        if self.head:
            if s.strip(): raise ValueError("unverified head text or stylesheet")
            return
        s=re.sub(r"\s+"," ",s)
        if not s.strip(): return
        if self.events and "text" in self.events[-1]: self.events[-1]["text"]+=s
        else: self.events.append({"text":s})
    def handle_decl(self,d):
        if d.lower()!="doctype html": raise ValueError("unsupported declaration")
    def handle_pi(self,d): raise ValueError("processing instruction")
    def proof(self,s):
        if "{{" in s or "}}" in s or len(s)>2097152: raise ValueError("unresolved or oversized body")
        self.feed(s)
        if self.rawdata: raise ValueError("incomplete HTML")
        self.close()
        if self.stack: raise ValueError("unclosed HTML")
        for e in self.events:
            if "text" in e: e["text"]=e["text"].strip()
        return self.events
e=Proof().proof(d["expected"]); a=Proof().proof(d["actual"])
if e!=a: raise ValueError("full body differs")
print(json.dumps(a,ensure_ascii=False))
'@
    try {
        $proof = Invoke-SeedPython -Code $code -InputObject @{ expected = $ExpectedHtml; actual = $ActualHtml }
        return ,@($proof)
    } catch { throw 'Seed.Outlook.Body: Full normalized HTML, formatting, text and links must match; no subject/count-only proof.' }
}

function Get-SeedOutlookCollection {
    param($Session, [string]$MailboxId, [string]$Field, [string]$Value)
    if ($Field -cnotin @('subject', 'internetMessageId')) { throw 'Seed.Outlook.Query: Exact mailbox correlation only.' }
    $filter = [uri]::EscapeDataString("$Field eq '$($Value.Replace("'", "''"))'")
    return @(Get-SeedGraphCollection -Session $Session -Path "/users/$MailboxId/mailFolders/inbox/messages?`$filter=$filter&`$select=id,subject,internetMessageId&`$top=100" -MaxPages 20)
}

function Read-SeedOutlookMessage {
    param($Session, $Outlook, [string]$MailboxId, [string]$MessageId)
    if ([string]::IsNullOrWhiteSpace($MessageId)) { throw 'Seed.Outlook.Message: Actual mailbox-local message ID required.' }
    $path = "/users/$MailboxId/mailFolders/inbox/messages/" + [uri]::EscapeDataString($MessageId) +
        '?$select=id,parentFolderId,internetMessageId,conversationId,subject,from,sender,toRecipients,ccRecipients,bccRecipients,isDraft,body,internetMessageHeaders'
    $message = ConvertTo-SeedMap (Invoke-SeedGraph -Session $Session -Method GET -Path $path)
    Assert-SeedFields $message @('id', 'parentFolderId', 'internetMessageId', 'conversationId', 'subject', 'from', 'sender', 'toRecipients', 'ccRecipients', 'bccRecipients', 'isDraft', 'body', 'internetMessageHeaders') 'Seed.Outlook.Message'
    if ($message.id -cne $MessageId -or $message.parentFolderId -cne $Outlook.Inboxes[$MailboxId] -or
        $message.isDraft -isnot [bool] -or $message.isDraft -or [string]::IsNullOrWhiteSpace($message.conversationId) -or
        $message.internetMessageId -cnotmatch '^<[^<>\s]+@[^<>\s]+>$') { throw 'Seed.Outlook.Message: Actual Inbox message identity or Internet ID is invalid.' }
    return $message
}

function Get-SeedOutlookHeaders {
    param($Message)
    $headers = @{}
    foreach ($h in $Message.internetMessageHeaders) {
        $name = ([string]$h.name).ToLowerInvariant()
        if ($name -cnotin @('message-id', 'in-reply-to', 'references', 'x-m365seed-message')) { continue }
        if ($headers.ContainsKey($name) -or $h.value -isnot [string]) { throw 'Seed.Outlook.Headers: Duplicate or malformed proof header.' }
        $headers[$name] = ([string]$h.value -replace '\r?\n[ \t]+', ' ').Trim()
    }
    if (-not $headers.ContainsKey('message-id') -or $headers['message-id'] -cne $Message.internetMessageId) { throw 'Seed.Outlook.Headers: Message-ID header must match the authoritative Internet ID.' }
    return $headers
}

function Assert-SeedOutlookMessage {
    param($Session, $Outlook, $Operation, $Message, [string]$ParentInternetId, [string[]]$References = @())
    $scope = $Operation.OutlookScope
    if ($Message.subject -cne $scope.Subject -or $Message.from.emailAddress.address -ine $scope.SenderUpn -or
        $Message.sender.emailAddress.address -ine $scope.SenderUpn -or @($Message.bccRecipients).Count -ne 0 -or
        $Message.body.contentType -ine 'html') { throw 'Seed.Outlook.Content: Exact subject, actual author/sender and HTML required.' }
    foreach ($pair in @(@('toRecipients', 'ToAddresses'), @('ccRecipients', 'CcAddresses'))) {
        $addresses = @($Message[$pair[0]] | ForEach-Object { $_.emailAddress.address.ToLowerInvariant() } | Sort-Object)
        if (($addresses -join "`n") -cne (@($scope[$pair[1]]) -join "`n")) { throw 'Seed.Outlook.Recipients: Complete exact To/CC set including Presenter required.' }
    }
    $headers = Get-SeedOutlookHeaders $Message
    if ($scope.Kind -ceq 'Send') {
        if (-not $headers.ContainsKey('x-m365seed-message') -or $headers['x-m365seed-message'] -cne $scope.Marker -or
            $headers.ContainsKey('in-reply-to') -or $headers.ContainsKey('references')) { throw 'Seed.Outlook.Headers: Exact root run marker and root headers required.' }
    } else {
        if (-not $headers.ContainsKey('in-reply-to') -or $headers['in-reply-to'] -cne $ParentInternetId -or
            -not $headers.ContainsKey('references') -or (($headers['references'] -split '\s+') -join ' ') -cne ($References -join ' ')) { throw 'Seed.Outlook.Parent: Exact In-Reply-To and complete References chain required, never a cross-mailbox conversation ID assumption.' }
    }
    $body = Compare-SeedOutlookBody (Get-SeedOutlookHtml $scope $Outlook.Resolved) $Message.body.content
    return @{
        id = $Message.id; inboxId = $Message.parentFolderId; internetMessageId = $Message.internetMessageId; conversationId = $Message.conversationId
        subject = $Message.subject; from = $scope.SenderUpn; sender = $scope.SenderUpn; to = @($scope.ToAddresses); cc = @($scope.CcAddresses)
        headers = $headers; body = $body
    }
}

function Find-SeedOutlookMessage {
    param($Session, $Outlook, [string]$MailboxId, [string]$Field, [string]$Value, [string[]]$ExcludeIds = @(), [switch]$Poll)
    $attempts = $(if ($Poll) { 31 } else { 1 })
    for ($i = 0; $i -lt $attempts; $i++) {
        $messages = @(Get-SeedOutlookCollection $Session $MailboxId $Field $Value | Where-Object { $_.internetMessageId -cnotin $ExcludeIds })
        if ($messages.Count -gt 1) { throw 'Seed.Outlook.Collision: Ambiguous Inbox messages; never select the newest or use counts as content proof.' }
        if ($messages.Count -eq 1) {
            $message = Read-SeedOutlookMessage $Session $Outlook $MailboxId $messages[0].id
            if ($message[$Field] -cne $Value) { throw 'Seed.Outlook.Correlation: Inbox detail must preserve the exact queried subject or cross-mailbox Internet ID.' }
            return $message
        }
        if ($i + 1 -lt $attempts) { & (Get-SeedSessionRecord $Session).Delay 2 | Out-Null }
    }
    throw 'Seed.Outlook.Timeout: Bounded Inbox GET polling exhausted; never resend.'
}

function Get-SeedOutlookSnapshot {
    param($Session, $Outlook, $Operation, [switch]$Poll)
    $scope = $Operation.OutlookScope; $parent = $null; $references = @()
    if ($scope.ParentOperationId) {
        $parent = Get-SeedOutlookSnapshot $Session $Outlook $Outlook.ById[$scope.ParentOperationId] -Poll:$Poll
        $references = @($parent.references) + @($parent.internetMessageId)
    }
    $exclude = @($Outlook.Evidence.Values | Where-Object { $_.operationId -cne $Operation.OperationId } | ForEach-Object { $_.internetMessageId })
    if ($Outlook.Ids.ContainsKey($Operation.OperationId)) {
        $presenter = Read-SeedOutlookMessage $Session $Outlook $Outlook.PresenterId $Outlook.Ids[$Operation.OperationId]
        $located = Find-SeedOutlookMessage $Session $Outlook $Outlook.PresenterId internetMessageId $presenter.internetMessageId
        if ($located.id -cne $presenter.id) { throw 'Seed.Outlook.Receipt: Presenter mailbox-local ID differs from receipt.' }
    } else {
        $presenter = Find-SeedOutlookMessage $Session $Outlook $Outlook.PresenterId subject $scope.Subject -ExcludeIds $exclude -Poll:$Poll
        $Outlook.Ids[$Operation.OperationId] = $presenter.id
    }
    $parentInternetId = $(if ($null -ne $parent) { $parent.internetMessageId } else { '' })
    $proof = Assert-SeedOutlookMessage $Session $Outlook $Operation $presenter $parentInternetId $references
    $receipts = @{ $Outlook.PresenterId = $proof }
    $record = Get-SeedSessionRecord $Session
    $recipients = @(@($scope.ToAddresses) + @($scope.CcAddresses) | Sort-Object)
    foreach ($address in $recipients) {
        $actor = @($record.Identity.Roles.Values | Where-Object { $_.Upn -ieq $address })[0]
        if ($actor.ObjectId -ieq $Outlook.PresenterId) { continue }
        $mail = Find-SeedOutlookMessage $Session $Outlook $actor.ObjectId internetMessageId $presenter.internetMessageId -Poll:$Poll
        $receipts[$actor.ObjectId] = Assert-SeedOutlookMessage $Session $Outlook $Operation $mail $parentInternetId $references
    }
    $snapshot = @{
        operationId = $Operation.OperationId; threadId = $scope.ThreadId; messageId = $scope.MessageId
        presenterMessageId = $presenter.id; internetMessageId = $presenter.internetMessageId; references = $references
        parentOperationId = $scope.ParentOperationId; parentInternetMessageId = $parentInternetId; mailboxes = $receipts
    }
    $Outlook.Ids[$Operation.OperationId] = $presenter.id
    $Outlook.Evidence[$Operation.OperationId] = $snapshot
    return $snapshot
}

function Get-SeedOutlookRequest {
    param($Session, $Outlook, $Operation, $Assets)
    $scope = $Operation.OutlookScope
    $request = @{ OperationId = $Operation.OperationId; Method = 'POST'; Body = New-SeedOutlookMessageBody $scope (Get-SeedOutlookHtml $scope $Assets.Assets) }
    $parentId = ''; $parentObjectId = ''
    if ($scope.Kind -ceq 'Send') {
        $request.Path = "/users/$($scope.SenderId)/sendMail"
        if ($scope.AssetRefs.Count -gt 0) {
            $parent = $Assets.Parents[$scope.AssetRefs[0]]; $parentId = $parent.OperationId; $parentObjectId = $parent.ObjectId
        }
    } else {
        $parent = Get-SeedOutlookSnapshot $Session $Outlook $Outlook.ById[$scope.ParentOperationId] -Poll
        $mail = Find-SeedOutlookMessage $Session $Outlook $scope.SenderId internetMessageId $parent.internetMessageId -Poll
        $null = Assert-SeedOutlookMessage $Session $Outlook $Outlook.ById[$scope.ParentOperationId] $mail $parent.parentInternetMessageId $parent.references
        $request.Path = "/users/$($scope.SenderId)/messages/" + [uri]::EscapeDataString($mail.id) + '/reply'
        $parentId = $scope.ParentOperationId; $parentObjectId = $parent.presenterMessageId
    }
    return @{ Request = $request; ParentOperationId = $parentId; ParentObjectId = $parentObjectId }
}

function Test-SeedOutlookRequest {
    param($Session, $Outlook, $Operation, $Request)
    $null = Get-SeedOutlookRecord $Session $Outlook.Handle
    if (-not $Outlook.ById.ContainsKey($Operation.OperationId) -or
        (Get-SeedOperationDigest $Operation) -cne (Get-SeedOperationDigest $Outlook.ById[$Operation.OperationId]) -or
        $null -ne $Operation.OutlookScope.InitialRequest) { throw 'Seed.Outlook.Request: Exact upfront late-bound scope required.' }
    Assert-SeedOutlookActors $Session $Outlook
    $assets = Resolve-SeedOutlookAssets $Session $Outlook
    $expected = Get-SeedOutlookRequest $Session $Outlook $Outlook.ById[$Operation.OperationId] $assets
    if ($Operation.OutlookScope.ParentOperationId) {
        $approval = (Get-SeedSessionRecord $Session).Approval
        $state = Get-SeedRunState -Path $approval.Path -RunId $approval.RunId -Context $approval.Context -Operations $approval.Operations
        $receipt = @($state.results | Where-Object { $_.id -ceq $expected.ParentOperationId -and $_.workload -ceq 'outlook' -and $_.status -ceq 'Verified' })
        if ($receipt.Count -ne 1 -or $receipt[0].objectId -cne $expected.ParentObjectId -or
            $receipt[0].evidence.sha256 -cne (Get-SeedFingerprint $Outlook.Evidence[$expected.ParentOperationId])) { throw 'Seed.Outlook.Parent: Fresh full parent proof must match its already Verified receipt before replying.' }
    }
    $digest = Get-SeedRequestFingerprint $Request.Method $Request.Path $Request.Body $null
    if ($Request.Contains('RawBody') -or $digest -cne (Get-SeedRequestFingerprint $expected.Request.Method $expected.Request.Path $expected.Request.Body $null)) { throw 'Seed.Outlook.Request: Exact actual sender mailbox, parent ID, recipients, subject, headers and resolved body required.' }
    return @{
        OperationFingerprint = Get-SeedOperationDigest $Operation; RequestFingerprint = $digest; MatchesPlan = $true; PresenterVerified = $true
        ParentOperationId = $expected.ParentOperationId; ParentObjectId = $expected.ParentObjectId
    }
}

function Get-SeedOutlookProof {
    param($Session, $Outlook, $Operation)
    $null = Get-SeedOutlookRecord $Session $Outlook.Handle
    if (-not $Outlook.ById.ContainsKey($Operation.OperationId) -or
        (Get-SeedOperationDigest $Operation) -cne (Get-SeedOperationDigest $Outlook.ById[$Operation.OperationId])) { throw 'Seed.Outlook.Scope: Resource check only covers original adapter scope.' }
    Assert-SeedOutlookActors $Session $Outlook
    $manifest = Read-SeedOutlookPrepared $Outlook.PreparedPath $Outlook.Scenario
    if ($manifest.fingerprint -cne $Outlook.Context.preparedFingerprint) { throw 'Seed.Outlook.Prepared: Prepared context changed.' }
    if ($null -ne $Outlook.RunState -and $Outlook.RunState.status -ceq 'Completed') {
        Assert-SeedOutlookJournal $Outlook $Outlook.RunState
        $assets = Resolve-SeedOutlookAssets $Session $Outlook
        $Outlook.Resolved = $assets.Assets
        $snapshot = Get-SeedOutlookSnapshot $Session $Outlook $Outlook.ById[$Operation.OperationId]
        Test-SeedOutlookCollections $Session $Outlook
        return @{ State = 'Existing'; ToolOwned = $true; ContentVerified = $true; PresenterVerified = $true
            ObjectId = $snapshot.presenterMessageId; DataFingerprint = $Operation.DataFingerprint; EvidenceFingerprint = Get-SeedFingerprint $snapshot }
    }
    if ($null -ne $Outlook.RunState -and $Outlook.RunState.status -cne 'Planned') { throw 'Seed.Outlook.State: No partial resume.' }
    foreach ($op in $Outlook.Operations) {
        foreach ($mailbox in $Outlook.Inboxes.Keys) {
            if (@(Get-SeedOutlookCollection $Session $mailbox subject $op.OutlookScope.Subject).Count -ne 0) { throw 'Seed.Outlook.Collision: Existing run subjects are never adopted without a complete exact receipt.' }
        }
    }
    return @{ State = 'Absent'; AbsenceVerified = $true; PresenterVerified = $true }
}

function Test-SeedOutlookCollections {
    param($Session, $Outlook)
    foreach ($mailbox in $Outlook.Inboxes.Keys) {
        foreach ($subject in @($Outlook.Operations.OutlookScope.Subject | Sort-Object -Unique)) {
            $actual = @(Get-SeedOutlookCollection $Session $mailbox subject $subject | ForEach-Object { $_.id } | Sort-Object)
            $expected = @()
            foreach ($op in $Outlook.Operations) {
                if ($op.OutlookScope.Subject -cne $subject) { continue }
                if (-not $Outlook.Evidence.ContainsKey($op.OperationId)) {
                    $null = Get-SeedOutlookSnapshot $Session $Outlook $op
                }
                $snapshot = $Outlook.Evidence[$op.OperationId]
                if ($snapshot.mailboxes.ContainsKey($mailbox)) { $expected += $snapshot.mailboxes[$mailbox].id }
            }
            $expected = @($expected | Sort-Object)
            if (($actual -join "`n") -cne ($expected -join "`n")) { throw 'Seed.Outlook.Collection: Complete exact Inbox ID set differs; missing, additional or duplicate run messages block Skip.' }
        }
    }
}

function Get-SeedOutlookOutput {
    param($Outlook, [bool]$Verified)
    $messages = @($Outlook.Operations | ForEach-Object { $Outlook.Evidence[$_.OperationId] })
    $threads = @($Outlook.Scenario.outlook.threads | ForEach-Object {
        $threadId = $_.id
        @{ threadId = $threadId; messages = @($messages | Where-Object threadId -CEQ $threadId) }
    })
    return @{ Messages = $messages; Threads = $threads; Verified = $Verified }
}

function Test-SeedOutlook {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Adapter, $AssetUrlMap = $null)
    $outlook = Get-SeedOutlookRecord $Session $Adapter
    $record = Get-SeedSessionRecord $Session; $record.ReadOnlyDepth++
    try {
        if ($null -eq $outlook.RunState -or $outlook.RunState.status -cne 'Completed') { throw 'Seed.Outlook.State: Globally Completed exact journal required.' }
        Assert-SeedOutlookJournal $outlook $outlook.RunState
        Assert-SeedOutlookActors $Session $outlook
        $manifest = Read-SeedOutlookPrepared $outlook.PreparedPath $outlook.Scenario
        if ($manifest.fingerprint -cne $outlook.Context.preparedFingerprint) { throw 'Seed.Outlook.Prepared: Source changed.' }
        $assets = Resolve-SeedOutlookAssets $Session $outlook $AssetUrlMap; $outlook.Resolved = $assets.Assets
        $outlook.Evidence.Clear()
        foreach ($op in $outlook.Operations) {
            $snapshot = Get-SeedOutlookSnapshot $Session $outlook $op
            $receipt = @($outlook.RunState.results | Where-Object { $_.id -ceq $op.OperationId -and $_.workload -ceq 'outlook' })[0]
            if ($snapshot.presenterMessageId -cne $receipt.objectId -or (Get-SeedFingerprint $snapshot) -cne $receipt.evidence.sha256) { throw 'Seed.Outlook.Receipt: Full current authoritative content differs from receipt.' }
        }
        Test-SeedOutlookCollections $Session $outlook
        return Get-SeedOutlookOutput $outlook $true
    } catch { throw 'Seed.Outlook.Verify: Complete Inbox identity, authors, recipients, headers, parents, resolved body or Storage provenance not proven.' }
    finally { $record.ReadOnlyDepth-- }
}

function Invoke-SeedEmails {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)]$Adapter, [Parameter(Mandatory)][object[]]$Plan,
        [Parameter(Mandatory)][AllowEmptyCollection()]$AssetUrlMap)
    $outlook = Get-SeedOutlookRecord $Session $Adapter
    $selected = @($Plan | Where-Object { $_.Workload -ceq 'outlook' -and $outlook.ById.ContainsKey($_.OperationId) })
    if ($selected.Count -ne $outlook.Operations.Count -or @($Plan | Where-Object Action -eq Block).Count -gt 0 -or
        @($selected | Where-Object Action -notin @('Create', 'Skip')).Count -gt 0) { throw 'Seed.Outlook.Plan: Whole global preflight and complete Outlook operation set required.' }
    foreach ($op in $selected) {
        $comparison = ConvertTo-SeedMap $op
        if ($op.Action -ceq 'Skip') {
            if (-not $outlook.Ids.ContainsKey($op.OperationId) -or $op.TargetId -cne $outlook.Ids[$op.OperationId]) { throw 'Seed.Outlook.Plan: Exact completed mailbox ID required.' }
            $comparison.TargetId = $null
        }
        if ((Get-SeedOperationDigest $comparison) -cne (Get-SeedOperationDigest $outlook.ById[$op.OperationId])) { throw 'Seed.Outlook.Plan: Exact upfront mail scope changed.' }
    }
    if (@($selected | Where-Object Action -eq Skip).Count -eq $selected.Count) { return Test-SeedOutlook -Session $Session -Adapter $Adapter -AssetUrlMap $AssetUrlMap }
    if (@($selected | Where-Object Action -eq Skip).Count -gt 0) { throw 'Seed.Outlook.Plan: No mixed partial resume.' }
    $record = Get-SeedSessionRecord $Session; $approval = $record.Approval
    if ($null -eq $approval -or $approval.Path -cne $outlook.StatePath -or $approval.RunId -cne $outlook.RunId -or
        (Get-SeedFingerprint $Plan) -cne $approval.PlanFingerprint) { throw 'Seed.Outlook.Approval: Exact global approval must precede all sends.' }
    Assert-SeedOutlookActors $Session $outlook
    $manifest = Read-SeedOutlookPrepared $outlook.PreparedPath $outlook.Scenario
    if ($manifest.fingerprint -cne $outlook.Context.preparedFingerprint) { throw 'Seed.Outlook.Prepared: Source changed.' }
    $assets = Resolve-SeedOutlookAssets $Session $outlook $AssetUrlMap; $outlook.Resolved = $assets.Assets
    foreach ($op in $outlook.Operations) {
        $html = Get-SeedOutlookHtml $op.OutlookScope $outlook.Resolved
        $null = Compare-SeedOutlookBody $html $html
    }
    foreach ($op in $outlook.Operations) {
        $id = $null
        try {
            $request = (Get-SeedOutlookRequest $Session $outlook $op $assets).Request
            Write-SeedGraph -Session $Session -Request $request -RequestCheck $outlook.RequestCheck | Out-Null
            $snapshot = Get-SeedOutlookSnapshot $Session $outlook $op -Poll
            $id = $snapshot.presenterMessageId
            Write-SeedRunEvent -Path $approval.Path -RunId $approval.RunId -Context $approval.Context -Operations $approval.Operations -OperationId $op.OperationId -Workload outlook -Action Verify -Status Verified -ObjectId $id -ReadBack $snapshot | Out-Null
        } catch {
            $diagnostic = @{
                Stage = 'MailReadBack'; HttpStatus = (Get-SeedGraphFailure $_.Exception).Status
                ExceptionType = $_.Exception.GetType().FullName
            }
            if ($_.Exception.Data.Contains('SeedDiagnostic')) { $diagnostic = $_.Exception.Data['SeedDiagnostic'] }
            $code = [regex]::Match($_.Exception.Message, '\bSeed\.[A-Za-z0-9_.]+').Value
            $diagnostic.ErrorCode = $(if ($code) { $code } else { 'Seed.Outlook.ReadBack' })
            Write-Host ('[OutlookDiagnostic] ' + ($diagnostic | ConvertTo-Json -Compress))
            $state = Get-SeedRunState -Path $approval.Path -RunId $approval.RunId -Context $approval.Context -Operations $approval.Operations
            $result = @($state.results | Where-Object { $_.id -ceq $op.OperationId -and $_.workload -ceq 'outlook' })[0]
            if ($result.status -ceq 'Submitted') {
                if ($null -eq $id -and $outlook.Ids.ContainsKey($op.OperationId)) { $id = $outlook.Ids[$op.OperationId] }
                Write-SeedRunEvent -Path $approval.Path -RunId $approval.RunId -Context $approval.Context -Operations $approval.Operations -OperationId $op.OperationId -Workload outlook -Action Fail -Status Unknown -ObjectId $id -ErrorCode OutlookReadBackUnknown | Out-Null
            }
            $failure = [InvalidOperationException]::new('Seed.Outlook.Stopped: Preserve journal and delivered mail; unknown or partial operations are never resent, resumed or repaired.')
            $failure.Data['SeedDiagnostic'] = $diagnostic
            throw $failure
        }
    }
    $state = Get-SeedRunState -Path $approval.Path -RunId $approval.RunId -Context $approval.Context -Operations $approval.Operations
    if ($state.status -ceq 'Completed') {
        Set-SeedOutlookRunState $Session $Adapter $state
        return Test-SeedOutlook -Session $Session -Adapter $Adapter -AssetUrlMap $AssetUrlMap
    }
    return Get-SeedOutlookOutput $outlook $false
}
