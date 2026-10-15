#requires -Version 5.1
Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'DeploymentStore.psm1') -DisableNameChecking

<#
Root is the explicit DATA root (the parent of Product), never an implicit default.
Exports return whitelist summaries, not source documents, credentials or replies.
Id = SourceKind:SourceId. Classification = Continue / Prepared / Draft / History.
Continue can contain a blocked item: CanResume is local checkpoint eligibility,
not permission to apply, authenticate, probe or bypass DeploymentFlow's review.
AttentionRequired overrides a terminal status and keeps a prepared problem visible.

Only operation-history/visibility.json is committed. Legacy archive.json is read
through this query layer; a unified override is valid until that marker changes.
Main must use this layer for BOTH old and new history views. No source migration.
Clear previews are read-only and user/root-bound; commit rechecks the full snapshot
under nonwaiting session/store/registry/task/run/line/history locks. Lock files are
coordination metadata. No processes, network, identity state or source assets change.
Asset retention is separate from hiding a terminal non-current history row.
DataRetentionReasons documents assets retained; ProtectionReasons blocks hiding.
New-TCHistoryClearPreview -Ids seals a nonempty canonical selection. Omit -Ids
for all records. Counts describe that scope; the stale digest still covers Root.
Missing/corrupt/unsafe references fail closed. All retained source data is available
to undo display hiding, including generations whose actual identity is archived.
#>

function OHField { param($Value,[string]$Name,$Default=$null) Get-TCDField $Value $Name $Default }
function OHArrayField {
    param($Value,[string]$Name)
    if($Value -is [Collections.IDictionary]){return ($Value.Contains($Name) -and $Value[$Name] -is [array])}
    return ($null -ne $Value -and $null -ne $Value.PSObject.Properties[$Name] -and $Value.$Name -is [array])
}
function OHFail { param([string]$Code) throw ('[TC:'+ $Code +'] 操作历史未修改，请重新查询或预览。') }
function OHLocalPath {
    param([string]$Path)
    if(-not $Path -or $Path -notmatch '^[A-Za-z]:[\\/]' -or $Path -match '[\x00-\x1f\x7f"*?<>|]' -or $Path.Substring(2).Contains(':')){OHFail UnsafePath}
    try{$full=[IO.Path]::GetFullPath($Path)}catch{OHFail UnsafePath}
    foreach($part in $full.Substring(3).Split([char[]]@('\','/'),[StringSplitOptions]::None)){
        if($part.EndsWith('.') -or $part.EndsWith(' ') -or $part -match '^(?i:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)'){OHFail UnsafePath}
    }
    $cursor=$full
    while($cursor){
        $exists=$false;$attributes=0
        try{$attributes=[IO.File]::GetAttributes($cursor);$exists=$true}catch [IO.FileNotFoundException]{}catch [IO.DirectoryNotFoundException]{}catch{OHFail UnsafePath}
        if($exists -and ($attributes -band [IO.FileAttributes]::ReparsePoint)){OHFail UnsafePath}
        $parent=[IO.Path]::GetDirectoryName($cursor);if($parent -eq $cursor){break};$cursor=$parent
    }
    return $full
}
function OHRoot {
    param([string]$Root)
    $full=(OHLocalPath $Root).TrimEnd('\','/')
    if($full.Length -lt 4 -or -not [IO.Directory]::Exists($full)){OHFail HistoryRootInvalid}
    return $full
}
function OHPath {
    param([string]$Root,[string]$Path)
    $full=OHLocalPath $Path
    if(-not $full.StartsWith($Root+'\',[StringComparison]::OrdinalIgnoreCase)){OHFail HistoryUnsafeReference}
    return $full
}
function OHId {
    param([string]$Id)
    if($Id -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'){OHFail HistoryInvalidId}
    return (Assert-TCDId $Id)
}
function OHKey {
    param([string]$Kind,[string]$Id)
    if($Kind -cnotin @('DeploymentRun','LegacyLinuxJob','ManagementIntent')){OHFail HistoryInvalidId}
    return $Kind+':'+(OHId $Id)
}
function OHText {
    param($Value,[string]$Default='')
    if($Value -isnot [string] -or $Value.Length -gt 120 -or $Value -match '(?i)(private.?key|password|passphrase|secret|token|credential|-----BEGIN|[A-Za-z0-9+/]{43}=)'){return $Default}
    return ($Value -replace '[\x00-\x1f\x7f]',' ').Trim()
}
function OHCode {param($Value) if($Value -is [string] -and $Value -cmatch '^[A-Za-z][A-Za-z0-9_]{0,63}$'){return $Value};return ''}
function OHTime {
    param($Value)
    try{
        if($Value -is [DateTime]){return $Value.ToUniversalTime().ToString('o')}
        if($Value -is [DateTimeOffset]){return $Value.ToUniversalTime().ToString('o')}
        if($Value -isnot [string] -or $Value -notmatch '^\d{4}-\d\d-\d\dT'){return ''}
        return [DateTimeOffset]::Parse($Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime().ToString('o')
    }catch{return ''}
}
function OHReason {param($Record,[string]$Reason) if(-not $Record.Reasons.Contains($Reason)){$Record.Reasons.Add($Reason)}}
function OHGlobal {param($Context,[string]$Reason) if(-not $Context.GlobalReasons.Contains($Reason)){$Context.GlobalReasons.Add($Reason)}}
function OHFileStamp {
    param($Context,[string]$Path,[switch]$PresenceOnly)
    $p=OHPath $Context.Root $Path
    if([IO.Directory]::Exists($p)){OHFail HistoryUnsafeReference}
    if(-not [IO.File]::Exists($p)){return 'missing'}
    if($PresenceOnly){$f=Get-Item -LiteralPath $p -Force -ErrorAction Stop;return [string]$f.Length+':'+$f.LastWriteTimeUtc.Ticks}
    return (Get-FileHash -LiteralPath $p -Algorithm SHA256 -ErrorAction Stop).Hash
}
function OHTrack {
    param($Context,[string]$Path,[switch]$PresenceOnly)
    $p=OHPath $Context.Root $Path
    if($Context.Files.ContainsKey($p)){
        $old=$Context.Files[$p]
        if((OHFileStamp $Context $p -PresenceOnly:$old.PresenceOnly) -cne $old.Stamp){OHFail HistorySnapshotChanged}
        if(-not $old.PresenceOnly){return $old.Stamp}
    }
    $stamp=OHFileStamp $Context $p -PresenceOnly:$PresenceOnly
    $Context.Files[$p]=[pscustomobject]@{Path=$p;Stamp=$stamp;PresenceOnly=[bool]$PresenceOnly}
    return $stamp
}
function OHRead {
    param($Context,[string]$Path)
    $p=OHPath $Context.Root $Path
    if($Context.Documents.ContainsKey($p)){return $Context.Documents[$p]}
    $before=OHTrack $Context $p
    if($before -eq 'missing'){$Context.Documents[$p]=$null;return $null}
    try{$doc=Read-TCDJson $p -MaxBytes 4194304 -ErrorAction Stop}catch{OHGlobal $Context ReferenceMetadataInvalid;$Context.Documents[$p]=$null;return $null}
    if((OHFileStamp $Context $p) -cne $before){OHFail HistorySnapshotChanged}
    $Context.Documents[$p]=$doc
    return $doc
}
function OHChildren {
    param($Context,[string]$Path,[switch]$Files)
    $p=OHPath $Context.Root $Path
    if([IO.File]::Exists($p)){OHFail HistoryUnsafeReference}
    $items=@()
    if([IO.Directory]::Exists($p)){
        $items=@(Get-ChildItem -LiteralPath $p -Force -ErrorAction Stop | Where-Object {if($Files){-not $_.PSIsContainer -and $_.Name.EndsWith('.json',[StringComparison]::OrdinalIgnoreCase)}else{$_.PSIsContainer}} | Sort-Object Name)
        foreach($item in $items){$null=OHPath $Context.Root $item.FullName}
    }
    $Context.Directories[$p+'|'+[bool]$Files]=[pscustomobject]@{Path=$p;Files=[bool]$Files;Names=@($items|ForEach-Object {$_.Name})}
    return $items
}
function OHBusy {
    param($Context,[string]$Path)
    $p=OHPath $Context.Root $Path
    if($p -in $Context.OwnedLocks -or -not [IO.File]::Exists($p)){return $false}
    $stream=$null
    try{$stream=[IO.File]::Open($p,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None);return $false}
    catch{return $true}finally{if($stream){$stream.Dispose()}}
}
function OHLockFact {
    param($Context,[string]$Path,[string]$RecordId,[string]$ServerId)
    $p=OHPath $Context.Root $Path;$busy=OHBusy $Context $p
    $Context.Locks[$p]=[pscustomobject]@{Path=$p;Busy=$busy;RecordId=$RecordId;ServerId=$ServerId}
    if($busy){
        if($RecordId){OHReason $Context.ById[$RecordId] ActiveLease}
        elseif($ServerId){foreach($r in $Context.Records){if($ServerId -in $r.ServerIds){OHReason $r ActiveLease}}}
        else{OHGlobal $Context ActiveStoreLock}
    }
}
function OHNewRecord {
    param($Context,[string]$Kind,[string]$Id,[string]$Directory,$Doc,$Result)
    $key=OHKey $Kind $Id
    $r=[pscustomobject]@{Id=$key;SourceKind=$Kind;SourceId=$Id;Directory=$Directory;Doc=$Doc;Result=$Result;ServerIds=@();IdentityState='Missing';Reasons=(New-Object 'Collections.Generic.List[string]');DataRetentionReasons=@();Tokens=@();LegacyHidden=$false;LegacyDigest='missing';Status='Unknown';Stage='';Operation='';UpdatedAtUtc='';HasCheckpoint=$false;IsPrepared=$false;Ended=$false;AttentionRequired=$false;Classification='History';CanResume=$false;NextAction='ViewHistory';HiddenRequested=$false;Hidden=$false;CanClear=$false}
    $Context.Records.Add($r);$Context.ById[$key]=$r
    if(-not $Doc -or (OHField $Doc SchemaVersion 0) -ne 1){OHReason $r SourceMetadataInvalid;return $r}
    $idField=@{DeploymentRun='RunId';LegacyLinuxJob='JobId';ManagementIntent='OperationId'}[$Kind]
    if((OHField $Doc $idField '') -cne $Id){OHReason $r SourceIdentityMismatch}
    if($Kind -eq 'ManagementIntent' -and (OHField $Doc Kind '') -cne 'TradeChannel.ManagementIntent'){OHReason $r SourceMetadataInvalid}
    $r.Status=OHCode (OHField $Doc Status (OHField $Doc State ''))
    if($Kind -eq 'LegacyLinuxJob'){
        $r.Status=if($Result){OHCode (OHField $Result Status '')}else{'Pending'}
        if($Result -and ((OHField $Result JobId '') -cne $Id -or (OHField $Result Operation '') -cne (OHField $Doc Operation '') -or -not (OHTime (OHField $Result FinishedAtUtc)))){OHReason $r SourceIdentityMismatch}
        $markerPath=Join-Path $Directory 'archive.json';$marker=OHRead $Context $markerPath;$r.LegacyDigest=$Context.Files[$markerPath].Stamp
        if($marker){
            if((OHField $marker SchemaVersion 0) -ne 1 -or (OHField $marker JobId '') -cne $Id -or (OHField $marker Archived) -isnot [bool]){OHReason $r VisibilityMetadataInvalid}
            else{$r.LegacyHidden=[bool]$marker.Archived}
        }
    }
    $r.Stage=OHCode (OHField $Doc Stage (OHField $Result Stage ''))
    $r.Operation=OHCode (OHField $Doc Operation (OHField $Doc Intent ''))
    $r.UpdatedAtUtc=OHTime (OHField $Doc UpdatedAtUtc (OHField $Result FinishedAtUtc (OHField $Doc CreatedAtUtc)))
    if(-not $r.Operation -or -not $r.Status -or -not $r.UpdatedAtUtc){OHReason $r SourceMetadataInvalid}
    return $r
}
function OHWalk {
    param($Value,[scriptblock]$Visit,[int]$Depth=0)
    if($Depth -gt 36){OHFail HistoryReferenceTooDeep}
    if($null -eq $Value -or $Value -is [string] -or $Value -is [ValueType]){return}
    if($Value -is [Collections.IEnumerable] -and $Value -isnot [Collections.IDictionary]){foreach($v in $Value){OHWalk $v $Visit ($Depth+1)};return}
    $names=if($Value -is [Collections.IDictionary]){@($Value.Keys)}else{@($Value.PSObject.Properties|ForEach-Object {$_.Name})}
    foreach($name in $names){
        $v=OHField $Value ([string]$name);& $Visit ([string]$name) $v $Value
        # Never interpret serialized secrets, transport payloads or crypto blobs.
        if($name -notmatch '(?i)^(Bytes|Protected|Password|Passphrase|PrivateKey|Secret|Token|Invite|PairRequest|EncryptedAuthorization|Credential|InputDigest|SessionRef|AttemptSessionRef)$'){OHWalk $v $Visit ($Depth+1)}
    }
}
function OHRisk {
    param($Record,$Value)
    OHWalk $Value {
        param($name,$v,$parent)
        if($name -in @('OutcomeUnknown','RecoveryRequired','ProbeRecoveryRequired','AttentionRequired','CleanupError','UnresolvedTcpMutation') -and $v){OHReason $Record $(if($name -eq 'AttentionRequired'){'AttentionRequired'}elseif($name -eq 'CleanupError'){'CleanupIncomplete'}else{'OutcomeOrRecoveryUnresolved'})}
        if($name -in @('CleanupComplete','OwnershipKnown') -and $null -ne $v -and $v -ne $true){OHReason $Record $(if($name -eq 'OwnershipKnown'){'OwnershipUnknown'}else{'CleanupIncomplete'})}
        if($name -in @('State','Status') -and $v -in @('OutcomeUnknown','NeedsRecovery','Unknown','AuthorizedReturnPending')){OHReason $Record OutcomeOrRecoveryUnresolved}
        if($name -eq 'Code' -and $v -in @('ProbeCleanupFailed','ProbeOwnershipUnknown','OwnershipMismatch')){OHReason $Record CleanupIncomplete}
    }
    foreach($field in @('DispatchIntent','StopTransaction','CandidateTransaction')){
        $intent=OHField $Value $field
        if((OHField $intent State '') -in @('Prepared','Dispatched','Running','OutcomeUnknown','NeedsRecovery')){OHReason $Record PendingIntent}
    }
    if(OHField $Value PendingOperationId){OHReason $Record PendingIntent}
    if((OHField $Value ProfileProbeState '') -in @('Running','Checking','Preparing')){OHReason $Record ActiveOperation}
}
function OHBinding {
    param($Context,$Record)
    $d=$Record.Doc;$ids=New-Object 'Collections.Generic.List[string]'
    $direct=[string](OHField $d ServerRecordId '')
    if($direct){if($Context.ServersById.ContainsKey($direct)){$ids.Add($direct)}else{OHReason $Record IdentityReferenceMissing}}
    foreach($s in $Context.Servers){
        $kind=@{DeploymentRun='Deployment';LegacyLinuxJob='Legacy';ManagementIntent='Management'}[$Record.SourceKind]
        if(($Record.SourceKind -eq 'LegacyLinuxJob' -and $Record.SourceId -in @(OHField $s SourceJobIds @())) -or @((OHField $s ArchivedTasks @())|Where-Object {(OHField $_ Kind '') -ceq $kind -and (OHField $_ Id '') -ceq $Record.SourceId}).Count){if(-not $ids.Contains($s.LocalRecordId)){$ids.Add($s.LocalRecordId)}}
    }
    $binding=OHField $d ServerInfo (OHField $d ServerBinding)
    if(-not $binding -and $Record.Result){$binding=OHField (OHField $Record.Result Data) ServerInfo}
    $owner=[string](OHField $binding RemoteOwnerId (OHField $d RemoteOwnerId ''))
    $public=[string](OHField (OHField $binding Node $binding) ServerPublicKey (OHField $d ServerPublicKey ''))
    if(-not $ids.Count -and $owner -and $public){foreach($s in $Context.Servers){if((OHField $s RemoteOwnerId '') -ceq $owner -and (OHField $s ServerPublicKey '') -ceq $public){$ids.Add($s.LocalRecordId)}}}
    $Record.ServerIds=@($ids.ToArray())
    if(@($ids|Where-Object {(OHField $Context.ServersById[$_] RecordState 'Active') -ceq 'Archived'}).Count){$Record.IdentityState='Archived';return}
    if($ids.Count -gt 1){$Record.IdentityState='Ambiguous';OHReason $Record IdentityAmbiguous;return}
    if($ids.Count -eq 1){
        $s=$Context.ServersById[$ids[0]];$Record.IdentityState='Active'
        if((OHField $s RecordState 'Active') -cne 'Active'){$Record.IdentityState='Unverified';OHReason $Record IdentityUnverified}
        foreach($pair in @(@('RemoteOwnerId',$owner),@('ServerPublicKey',$public))){if($pair[1] -and (OHField $s $pair[0]) -and $pair[1] -cne (OHField $s $pair[0])){$Record.IdentityState='Mismatch';OHReason $Record IdentityMismatch}}
        $response=OHField $d ClientResponse (OHField (OHField $Record.Result Data) ClientResponse)
        $rp=[string](OHField $response ServerPublicKey '')
        if($rp -and (OHField $s ServerPublicKey) -and $rp -cne (OHField $s ServerPublicKey)){$Record.IdentityState='Mismatch';OHReason $Record IdentityMismatch}
    }
}
function OHTokens {
    param($Value)
    $found=New-Object 'Collections.Generic.List[string]'
    # Ownership tokens come from results/checkpoints, not a management action's
    # Input.DeviceId (renaming a device does not own its original authorization).
    $owned=if((OHField $Value Kind '') -eq 'TradeChannel.ManagementIntent'){@{ClientRequest=(OHField $Value ClientRequest);ClientResponse=(OHField $Value ClientResponse);Data=(OHField $Value Data)}}else{$Value}
    OHWalk $owned {param($name,$v,$parent)
        if($name -in @('RequestId','DeviceId','EnrollmentId','ClientPublicKey','CandidateNodeId') -and $v -is [string] -and $v -and -not $found.Contains($name+':'+$v)){$found.Add($name+':'+$v)}
    }
    return @($found.ToArray())
}
function OHProtectReference {
    param($Context,[string]$Key,[string]$Reason,[string]$Owner)
    if($Context.ById.ContainsKey($Key)){
        if($Key -cne $Owner){OHReason $Context.ById[$Key] $Reason}
    }else{OHGlobal $Context ReferenceTargetMissing}
}
function OHReferences {
    param($Context,$Value,[string]$Reason,[string]$Owner='', [int]$Depth=0)
    if($Depth -gt 36){OHGlobal $Context ReferenceMetadataInvalid;return}
    OHWalk $Value {
        param($name,$v,$parent)
        if($name -eq 'SourceId' -and (OHField $parent SourceKind) -in @('DeploymentRun','LegacyLinuxJob','ManagementIntent')){
            try{OHProtectReference $Context (OHKey (OHField $parent SourceKind) ([string]$v)) $Reason $Owner}catch{OHGlobal $Context ReferenceMetadataInvalid}
        }
        $idKinds=@{RunId='DeploymentRun';DeploymentRunId='DeploymentRun';SourceRunId='DeploymentRun';RunIds='DeploymentRun';JobId='LegacyLinuxJob';RequestJobId='LegacyLinuxJob';ParentJobId='LegacyLinuxJob';SourceJobId='LegacyLinuxJob';SourceJobIds='LegacyLinuxJob';ApplyJobId='LegacyLinuxJob';FinalizeJobId='LegacyLinuxJob';ManagementOperationId='ManagementIntent'}
        $probeRun=($name -eq 'RunId' -and (OHField $parent NodeId) -and ((OHField $parent CandidateHash) -or (OHField $parent CandidateSHA256)))
        if($idKinds.ContainsKey($name) -and -not $probeRun){
            foreach($id in @($v)){if($id){try{OHProtectReference $Context (OHKey $idKinds[$name] ([string]$id)) $Reason $Owner}catch{OHGlobal $Context ReferenceMetadataInvalid}}}
        }
        if($name -in @('LineId','SourceNodeId','CandidateNodeId','TCLineId','TCManagedNodeId','NodeId','AliasIds','RequestId','DeviceId','EnrollmentId','ClientPublicKey')){
            foreach($id in @($v)){
                if(-not $id){continue}
                foreach($r in $Context.Records){
                    $tokenName=if($name -in @('LineId','SourceNodeId','TCLineId','TCManagedNodeId','NodeId','AliasIds')){'CandidateNodeId'}else{$name}
                    if($r.Id -cne $Owner -and ($tokenName+':'+[string]$id) -in $r.Tokens){OHReason $r $Reason}
                }
            }
        }
        $pathNames=@('ManifestPath','ProfileManifestPath','CandidateManifestPath','SourceManifestPath','TCSourceManifestPath','TCProfileManifestPath','PreviousManifestPath','RollbackManifestPath','OriginalManifestPath','CandidatePath','ProbePath','RequestDirectory','ConfigPath','ResponsePath','AuthorizationPath','IdentityPath')
        $snapshot=($name -eq 'Path' -and $null -ne (OHField $parent Exists))
        if(($name -in $pathNames -or $snapshot) -and $v){
            $pathReason=if($name -in @('PreviousManifestPath','RollbackManifestPath','OriginalManifestPath') -and $Reason -in @('CurrentConnectionReference','ConnectionTransactionReference','RollbackReference')){'RollbackReference'}else{$Reason}
            try{
                $p=OHPath $Context.Root ([string]$v)
                $null=OHTrack $Context $p -PresenceOnly
                if([IO.Directory]::Exists($p)){OHFail HistoryUnsafeReference}
            }catch{
                # RequestDirectory and IdentityPath legitimately name directories.
                if($name -in @('RequestDirectory','IdentityPath')){try{$p=OHPath $Context.Root ([string]$v);if(-not [IO.Directory]::Exists($p)){OHGlobal $Context ReferenceTargetMissing}}catch{OHGlobal $Context UnsafeReference}}
                else{OHGlobal $Context UnsafeReference;return}
            }
            foreach($r in $Context.Records){if($r.Id -cne $Owner -and ($p.Equals($r.Directory,[StringComparison]::OrdinalIgnoreCase) -or $p.StartsWith($r.Directory+'\',[StringComparison]::OrdinalIgnoreCase))){OHReason $r $pathReason}}
            if($name -match 'ManifestPath$' -and -not $Context.Followed.ContainsKey($p+'|'+$Reason)){
                $Context.Followed[$p+'|'+$Reason]=$true
                $m=OHRead $Context $p
                if(-not $m){OHGlobal $Context ReferenceTargetMissing}else{OHReferences $Context $m $pathReason $Owner ($Depth+1)}
            }
        }
        # ConnectionTransactions stores rollback documents as byte snapshots.
        if($name -eq 'Bytes' -and (OHField $parent Exists) -eq $true -and (OHField $parent Path)){
            $bytes=$null
            try{
                if($v -isnot [string] -or $v.Length -gt 5592408){throw 'snapshot'}
                $bytes=[Convert]::FromBase64String($v)
                $sha=[Security.Cryptography.SHA256]::Create()
                try{$hash=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','')}finally{$sha.Dispose()}
                if((OHField $parent SHA256 '') -ine $hash){throw 'snapshot'}
                $saved=[Text.Encoding]::UTF8.GetString($bytes)|ConvertFrom-Json -ErrorAction Stop
                $savedReason=if($Reason -in @('ConnectionTransactionReference','CurrentConnectionReference','RollbackReference')){'RollbackReference'}else{$Reason}
                OHReferences $Context $saved $savedReason $Owner ($Depth+1)
            }catch{OHGlobal $Context ReferenceMetadataInvalid}finally{if($bytes){[Array]::Clear($bytes,0,$bytes.Length)}}
        }
    }
}
function OHPrepared {
    param($Context,$Record)
    $d=$Record.Doc;$nodeId=[string](OHField $d CandidateNodeId '')
    $manifestPath=[string](OHField $d CandidateManifestPath '')
    if(-not $nodeId -or -not $manifestPath){return $false}
    try{
        $null=OHId $nodeId;$m=OHRead $Context $manifestPath
        $nodes=@((OHField $Context.Index nodes @())|Where-Object {(OHField $_ id '') -ceq $nodeId})
        if(-not $m -or $nodes.Count -ne 1 -or (OHField $m SyntaxValidated) -ne $true){throw 'binding'}
        $boundNode=[string](OHField $m TCLineId (OHField $m TCManagedNodeId (OHField $m node_id '')))
        if($boundNode -cne $nodeId){throw 'binding'}
        $s=if($Record.ServerIds.Count -eq 1){$Context.ServersById[$Record.ServerIds[0]]}else{$null}
        if(-not $s -or -not (OHField $s ServerPublicKey) -or (OHField $m ServerPublicKey '') -cne (OHField $s ServerPublicKey)){throw 'identity'}
        $request=OHField $d ClientRequest;$response=OHField $d ClientResponse
        if(-not $request -or -not $response -or -not (OHField $request RequestId) -or (OHField $request RequestId) -cne (OHField $response RequestId) -or -not (OHField $request ClientPublicKey) -or (OHField $request ClientPublicKey) -cne (OHField $m ClientPublicKey) -or (OHField $response ClientPublicKey) -cne (OHField $m ClientPublicKey)){throw 'device'}
        if((OHTrack $Context ([string](OHField $m CandidatePath ''))) -ine [string](OHField $m CandidateSHA256 '')){throw 'hash'}
        $line=OHField $Context.Lines $nodeId
        if(-not $line -or (OHField $line SchemaVersion 0) -ne 2 -or (OHField $line LineId '') -cne $nodeId){throw 'line'}
        $allowed=@([string](OHField $line SourceManifestPath ''),[string](OHField $nodes[0] manifestPath ''))+@((OHField $line Profiles @())|ForEach-Object {[string](OHField $_ ManifestPath '')})
        if(-not @($allowed|Where-Object {$_ -and [IO.Path]::GetFullPath($_).Equals([IO.Path]::GetFullPath($manifestPath),[StringComparison]::OrdinalIgnoreCase)}).Count){throw 'pointer'}
        foreach($mode in @('Udp','Tcp')){
            $profiles=@((OHField $line Profiles @())|Where-Object {(OHField $_ Id '') -ceq $mode -and (OHField $_ PreparationState '') -ceq 'SyntaxValidated'})
            if($profiles.Count -ne 1){return $false}
            $profile=$profiles[0];$mp=[string](OHField $profile ManifestPath '');$pm=OHRead $Context $mp
            if(-not $pm -or (OHTrack $Context $mp) -ine [string](OHField $profile ManifestSHA256 '') -or (OHField $pm TCLineId '') -cne $nodeId -or (OHField $pm TCProfileId '') -cne $mode -or (OHField $pm ServerPublicKey '') -cne (OHField $m ServerPublicKey '') -or (OHField $pm ClientPublicKey '') -cne (OHField $m ClientPublicKey '') -or (OHTrack $Context ([string](OHField $pm CandidatePath ''))) -ine [string](OHField $profile CandidateSHA256 '')){throw 'profile'}
        }
        return $true
    }catch{OHReason $Record CandidateBindingInvalid;return $false}
}
function OHClassify {
    param($Context,$Record)
    $d=$Record.Doc;$result=$Record.Result
    OHRisk $Record $d;OHRisk $Record $result
    $Record.AttentionRequired=([bool](OHField $d AttentionRequired $false))
    if($Record.Stage -eq 'ReadyInactive' -or (OHField $d CandidateNodeId)){
        if((OHField (OHField $d Recommendation) Status '') -in @('Unavailable','Inconclusive','Blocked','NoRecommendation') -or (OHField (OHField $d Validation) Status '') -in @('Failed','Inconclusive','Blocked') -or (OHField $d ProfileProbeState '') -in @('Interrupted','Failed','Blocked')){$Record.AttentionRequired=$true;OHReason $Record AttentionRequired}
    }
    $known=@('Complete','Completed','Cancelled','Rejected','ReconciledByUser','Failed','WaitingUser','Idle','Running','Pending','Dispatching','Prepared','Dispatched','OutcomeUnknown','NeedsRecovery','PartialDeployment','CompletedWithWarnings','AuthorizedReturnPending')
    if($Record.Status -notin $known){OHReason $Record UnknownState}
    if($Record.Status -in @('Running','Pending','Dispatching','Prepared','Dispatched')){OHReason $Record ActiveOperation}
    $assets=@('public.response.json','client-response.json','client.conf','public.request.json','client.key','client.state.json','authorization.dpapi.json','connection-bundle.dpapi.json')
    if($Record.SourceKind -ne 'ManagementIntent'){foreach($leaf in $assets){if((OHTrack $Context (Join-Path $Record.Directory $leaf) -PresenceOnly) -cne 'missing'){OHReason $Record UniqueRecoveryData;$Record.HasCheckpoint=$true}}}
    $client=Join-Path $Record.Directory 'client';$null=OHPath $Context.Root $client
    if([IO.Directory]::Exists($client)){foreach($leaf in @('public.request.json','client.key','client.state.json')){if((OHTrack $Context (Join-Path $client $leaf) -PresenceOnly) -cne 'missing'){OHReason $Record UniqueRecoveryData;$Record.HasCheckpoint=$true}}}
    foreach($field in @('ClientRequest','ClientResponse','CandidateTransaction','UnresolvedTcpMutation')){if(OHField $d $field){OHReason $Record UniqueRecoveryData;$Record.HasCheckpoint=$true}}
    if((OHField (OHField $d LastRemoteMutation) Mutating) -eq $true){OHReason $Record UniqueRecoveryData;$Record.HasCheckpoint=$true}
    if((OHField $d RequestJobId) -or (OHField $d RequestId) -or (OHField (OHField $result Data) ClientResponse)){$Record.HasCheckpoint=$true;OHReason $Record UniqueRecoveryData}
    if((OHField $d CandidateNodeId) -or (OHField $d CandidateManifestPath)){$Record.HasCheckpoint=$true;OHReason $Record CandidateReference}
    if((OHField $d Plan) -or (OHField $d ManagementPlan) -or (OHField $d ServerInfo) -or (OHField $d DispatchIntent) -or (OHField $d PendingOperationId)){$Record.HasCheckpoint=$true}
    if($Record.SourceKind -eq 'LegacyLinuxJob' -and ((OHField (OHField $result Data) PlanId) -or (OHField (OHField $result Data) ClientResponse))){$Record.HasCheckpoint=$true}
    if($Record.ServerIds.Count -eq 1 -and $Record.SourceKind -eq 'DeploymentRun'){
        $s=$Context.ServersById[$Record.ServerIds[0]]
        if((OHField (OHField $s Reinstall) ConfirmedAtUtc) -and (OHField $s PinnedHostKey)){$Record.HasCheckpoint=$true}
    }
    $terminal=$Record.Status -in @('Complete','Completed','Cancelled','Rejected','ReconciledByUser')
    if($Record.Status -eq 'Failed'){
        # Failed alone says nothing about dispatch, recovery, or side effects.
        $readOnly=$Record.Operation -in @('Inspect','Plan','Status','inspect','plan','status','server_info','devices','Deploy','Pairing','PrepareTcp')
        $intent=OHField $d DispatchIntent
        $noMutation=((OHField $intent State '') -eq 'Rejected' -or ((OHField $intent Mutating $false) -eq $false -and $Record.Stage -in @('PrepareAccess','Inspect','Plan','Console','Transport','')))
        $terminal=($readOnly -and $noMutation)
        if($Record.SourceKind -eq 'LegacyLinuxJob'){$terminal=($readOnly -and $null -ne $result -and (OHField $result OutcomeUnknown $true) -eq $false)}
        if((OHField (OHField $d LastRemoteMutation) Mutating) -eq $true -or (OHField $d ClientResponse) -or (OHField $d CandidateTransaction)){$terminal=$false}
        if(-not $terminal){OHReason $Record UnconfirmedFailure}
    }
    $Record.Ended=$terminal
    $Record.IsPrepared=if($Record.SourceKind -eq 'DeploymentRun' -and $Record.HasCheckpoint -and $Record.IdentityState -ne 'Archived'){OHPrepared $Context $Record}else{$false}
    $problem=@($Record.Reasons|Where-Object {$_ -in @('ActiveLease','ActiveOperation','PendingIntent','OutcomeOrRecoveryUnresolved','CleanupIncomplete','OwnershipUnknown','AttentionRequired','UnconfirmedFailure','CandidateBindingInvalid','IdentityMismatch','IdentityReferenceMissing','IdentityAmbiguous','UnknownState','SourceMetadataInvalid','SourceIdentityMismatch')}).Count -gt 0
    $unsettled=@($Record.Reasons|Where-Object {$_ -in @('ActiveLease','ActiveOperation','PendingIntent','OutcomeOrRecoveryUnresolved','CleanupIncomplete','OwnershipUnknown','UnconfirmedFailure','CandidateBindingInvalid','UnknownState','SourceMetadataInvalid','SourceIdentityMismatch')}).Count -gt 0
    $legacyNeedsNext=$false
    if($Record.SourceKind -eq 'LegacyLinuxJob' -and $Record.Status -eq 'Completed'){
        $data=OHField $result Data
        if($Record.Operation -eq 'Plan' -and (OHField $data PlanId)){
            $expires=OHTime (OHField $data PlanExpiresAt)
            $legacyNeedsNext=($expires -and [DateTimeOffset]$expires -gt [DateTimeOffset]::UtcNow)
        }
        if($Record.Operation -in @('Apply','Authorize','Finalize') -and $Record.HasCheckpoint -and (OHTrack $Context (Join-Path $Record.Directory 'client.conf') -PresenceOnly) -eq 'missing'){$legacyNeedsNext=$true}
    }
    if($Record.IdentityState -eq 'Archived'){$Record.Classification='History';$Record.NextAction='ViewHistory'}
    elseif($Record.IsPrepared -and -not $unsettled){$Record.Classification='Prepared';$Record.NextAction=if($Record.AttentionRequired){'CheckPreparation'}else{'ViewLine'}}
    elseif($unsettled -and ($Record.HasCheckpoint -or $Record.SourceKind -eq 'ManagementIntent' -or $Record.Status -in @('Running','Pending','OutcomeUnknown','NeedsRecovery'))){$Record.Classification='Continue';$Record.NextAction='Reconcile'}
    elseif($Record.AttentionRequired -and -not $terminal){$Record.Classification='Continue';$Record.NextAction='CheckPreparation'}
    elseif($legacyNeedsNext){$Record.Classification='Continue';$Record.NextAction='CompletePreparation'}
    elseif($Record.HasCheckpoint -and (-not $terminal -or $Record.Stage -in @('MaterializeCandidate','MaterializeTcp','PreparingProbePath','CheckingProfiles','ReadyInactive') -or $Record.Status -in @('PartialDeployment','CompletedWithWarnings'))){$Record.Classification='Continue';$Record.NextAction='CompletePreparation'}
    elseif($Record.SourceKind -eq 'ManagementIntent' -and -not $terminal){$Record.Classification='Continue';$Record.NextAction='Reconcile'}
    elseif($Record.SourceKind -eq 'DeploymentRun' -and -not $Record.HasCheckpoint -and (-not $terminal -or $Record.Status -eq 'Failed')){$Record.Classification='Draft';$Record.NextAction='EditDraft'}
    elseif(-not $terminal -and $Record.SourceKind -eq 'LegacyLinuxJob'){$Record.Classification='Draft';$Record.NextAction='EditDraft'}
    else{$Record.Classification='History';$Record.NextAction=if($Record.AttentionRequired){'CheckPreparation'}else{'ViewHistory'}}
    if($Record.Classification -eq 'Continue' -or ($Record.Classification -eq 'Prepared' -and -not $terminal) -or $Record.Classification -eq 'Draft'){OHReason $Record $(if($Record.Classification -eq 'Draft'){'InputDraft'}else{'ActionablePreparation'})}
    if(-not $terminal){OHReason $Record NotFinished}
    $Record.CanResume=($Record.Classification -eq 'Continue' -and $Record.IdentityState -eq 'Active' -and -not $problem)
    if($Record.Classification -eq 'Continue' -and $Record.IdentityState -in @('Missing','Mismatch','Ambiguous','Unverified')){$Record.CanResume=$false;$Record.NextAction='RepairIdentity'}
}
function OHVisibility {
    param($Context)
    $path=Join-Path $Context.Root 'operation-history\visibility.json';$store=OHRead $Context $path
    if(-not $store -and $Context.Files[$path].Stamp -cne 'missing'){OHFail HistoryVisibilityInvalid}
    if(-not $store){$store=[pscustomobject]@{SchemaVersion=1;Revision=0;Entries=@();Commits=@()}}
    if((OHField $store SchemaVersion 0) -ne 1 -or (OHField $store Revision -1) -lt 0 -or -not (OHArrayField $store Entries) -or -not (OHArrayField $store Commits)){OHFail HistoryVisibilityInvalid}
    $seen=@{}
    foreach($entry in $store.Entries){
        $key=OHKey ([string](OHField $entry SourceKind '')) ([string](OHField $entry SourceId ''))
        if((OHField $entry Id '') -cne $key -or (OHField $entry Hidden) -isnot [bool] -or $seen.ContainsKey($key)){OHFail HistoryVisibilityInvalid}
        $seen[$key]=$entry
    }
    foreach($r in $Context.Records){
        foreach($reason in $Context.GlobalReasons){OHReason $r $reason}
        if($Context.GlobalReasons.Count -or $r.Reasons.Contains('ActiveLease')){$r.CanResume=$false}
        # These facts retain raw assets, not terminal non-current display rows.
        # Live/current/rollback/unknown/cleanup/attention reasons remain hard.
        if($r.Ended){
            $soft=@('UniqueRecoveryData','CandidateReference','LineReference','IdentityReference','ProbeReference','RetainedOperationReference','RetainedTransactionReference')
            $r.DataRetentionReasons=@($r.Reasons|Where-Object {$_ -in $soft}|Sort-Object -Unique)
            foreach($reason in $r.DataRetentionReasons){$null=$r.Reasons.Remove($reason)}
        }
        $entry=$seen[$r.Id];$r.HiddenRequested=$r.LegacyHidden
        if($entry -and ($r.SourceKind -ne 'LegacyLinuxJob' -or (OHField $entry LegacyMarkerDigest '') -ceq $r.LegacyDigest)){$r.HiddenRequested=[bool]$entry.Hidden}
        $r.CanClear=($r.Reasons.Count -eq 0)
        # Protected/actionable data remains discoverable even after a legacy hide.
        $r.Hidden=($r.HiddenRequested -and $r.CanClear)
    }
    $Context.Visibility=$store
}
function OHSnapshot {
    param([string]$Root,[string[]]$OwnedLocks=@())
    $c=[pscustomobject]@{Root=(OHRoot $Root);OwnedLocks=$OwnedLocks;Files=@{};Directories=@{};Documents=@{};Followed=@{};Locks=@{};Records=(New-Object 'Collections.Generic.List[object]');ById=@{};Servers=@();ServersById=@{};LinkedNodes=@{};Lines=@{};Index=$null;Visibility=$null;GlobalReasons=(New-Object 'Collections.Generic.List[string]');Digest=''}
    $registry=OHRead $c (Join-Path $c.Root 'servers\registry.json')
    if($registry){
        if((OHField $registry SchemaVersion 0) -ne 1 -or -not (OHArrayField $registry Servers)){OHGlobal $c RegistryMetadataInvalid}
        else{foreach($s in $registry.Servers){try{$id=OHId ([string](OHField $s LocalRecordId ''));if($c.ServersById.ContainsKey($id)){throw 'duplicate'};$c.ServersById[$id]=$s;$c.Servers+=,$s}catch{OHGlobal $c RegistryMetadataInvalid}}}
    }
    foreach($spec in @(@{Kind='DeploymentRun';Relative='deployments\runs';Leaf='state.json'},@{Kind='LegacyLinuxJob';Relative='linux-jobs';Leaf='job.json'})){
        foreach($dir in @(OHChildren $c (Join-Path $c.Root $spec.Relative))){
            try{$id=OHId $dir.Name}catch{OHGlobal $c ForeignSourceDirectory;continue}
            $d=OHRead $c (Join-Path $dir.FullName $spec.Leaf);$result=$null
            if($spec.Kind -eq 'LegacyLinuxJob'){$result=OHRead $c (Join-Path $dir.FullName 'result.json')}
            $null=OHNewRecord $c $spec.Kind $id $dir.FullName $d $result
        }
    }
    foreach($file in @(OHChildren $c (Join-Path $c.Root 'deployments\management-intents') -Files)){
        try{$id=OHId $file.BaseName}catch{OHGlobal $c ForeignSourceFile;continue}
        $d=OHRead $c $file.FullName;$null=OHNewRecord $c ManagementIntent $id $file.FullName $d $null
    }
    $c.Index=OHRead $c (Join-Path $c.Root 'Product\index.json')
    if($c.Index -and ((OHField $c.Index schemaVersion 0) -ne 1 -or -not (OHArrayField $c.Index nodes))){OHGlobal $c LineMetadataInvalid}
    foreach($dir in @(OHChildren $c (Join-Path $c.Root 'Product\lines'))){
        $line=OHRead $c (Join-Path $dir.FullName 'line.json')
        if($line){if((OHField $line SchemaVersion 0) -ne 2 -or (OHField $line LineId '') -cne $dir.Name -or -not (OHArrayField $line Profiles)){OHGlobal $c LineMetadataInvalid};$c.Lines[$dir.Name]=$line}
        OHLockFact $c (Join-Path $dir.FullName '.line.lock') '' ''
    }
    foreach($s in $c.Servers){
        $valid=@()
        foreach($id in @(OHField $s LinkedNodeIds @())){
            $nodes=@((OHField $c.Index nodes @())|Where-Object {(OHField $_ id '') -ceq $id})
            if($nodes.Count -ne 1){continue} # Retired/missing links are not prepared lines.
            try{
                $null=OHId ([string]$id);$m=OHRead $c ([string](OHField $nodes[0] manifestPath ''))
                $local=[string](OHField $m TCLineId (OHField $m TCManagedNodeId (OHField $m node_id '')))
                if(-not $m -or -not (OHField $s ServerPublicKey) -or (OHField $m ServerPublicKey '') -cne (OHField $s ServerPublicKey) -or ($local -and $local -cne $id)){OHGlobal $c RegistryBindingMismatch;continue}
                $valid+=,[string]$id
            }catch{OHGlobal $c UnsafeReference}
        }
        $c.LinkedNodes[$s.LocalRecordId]=@($valid|Select-Object -Unique)
    }
    foreach($r in $c.Records){
        OHBinding $c $r;$r.Tokens=@((OHTokens $r.Doc)+(OHTokens $r.Result)|Select-Object -Unique)
        if($r.SourceKind -ne 'ManagementIntent'){OHLockFact $c (Join-Path $r.Directory $(if($r.SourceKind -eq 'DeploymentRun'){'.run.lock'}else{'.execution.lock'})) $r.Id '';if($r.SourceKind -eq 'LegacyLinuxJob'){OHLockFact $c (Join-Path $r.Directory '.archive.lock') $r.Id ''}}
        OHClassify $c $r
    }
    foreach($r in $c.Records){
        $unresolved=@($r.Reasons|Where-Object {$_ -in @('ActiveOperation','PendingIntent','OutcomeOrRecoveryUnresolved','CleanupIncomplete','OwnershipUnknown','AttentionRequired','UnconfirmedFailure','UnknownState','SourceMetadataInvalid','SourceIdentityMismatch')}).Count -gt 0
        $reason=if(-not $r.Ended -or $unresolved -or $r.Classification -eq 'Continue'){'OperationReference'}else{'RetainedOperationReference'}
        OHReferences $c $r.Doc $reason $r.Id;OHReferences $c $r.Result $reason $r.Id
    }
    if($c.Index){OHReferences $c $c.Index LineReference}
    foreach($line in $c.Lines.Values){OHReferences $c $line LineReference}
    foreach($spec in @(@('deployment.json','CurrentConnectionReference'),@('runtime.json','CurrentConnectionReference'),@('ui-preferences.json','CurrentConnectionReference'),@('runtime-observer.json','CurrentConnectionReference'))){
        $doc=OHRead $c (Join-Path $c.Root $spec[0]);if($doc){OHReferences $c $doc $spec[1]
            if($spec[0] -eq 'runtime.json' -and ((OHField $doc State 'Unknown') -notin @('Stopped','Disconnected','StoppedWithError') -or (OHField $doc CleanupError $false) -or (OHField $doc OwnershipKnown $true) -ne $true) -and -not (OHField $doc ManifestPath)){OHGlobal $c RuntimeReferenceUnknown}
        }
    }
    $currentDocs=@('deployment.json','runtime.json','runtime-observer.json'|ForEach-Object {$c.Documents[(Join-Path $c.Root $_)]})
    foreach($key in @($c.Followed.Keys|Where-Object {$_.EndsWith('|CurrentConnectionReference',[StringComparison]::Ordinal)})){$currentDocs+=,$c.Documents[$key.Substring(0,$key.LastIndexOf('|'))]}
    $currentTransactions=@($currentDocs|Where-Object {$null -ne $_}|ForEach-Object {@((OHField $_ TransactionId ''),(OHField $_ TCTransactionId ''))}|Where-Object {$_}|Select-Object -Unique)
    foreach($file in @(OHChildren $c (Join-Path $c.Root 'connection-transactions') -Files)){
        $tx=OHRead $c $file.FullName
        if($tx){
            $pending=(OHField $tx Status 'Unknown') -notin @('Completed','RolledBack','ResolvedStopped')
            $reason=if($pending -or (OHField $tx Id $file.BaseName) -in $currentTransactions){'ConnectionTransactionReference'}else{'RetainedTransactionReference'}
            OHReferences $c $tx $reason
            if($pending -and -not (OHField $tx Target) -and -not (OHField $tx Original)){OHGlobal $c TransactionReferenceUnknown}
        }
    }
    foreach($dir in @(OHChildren $c (Join-Path $c.Root 'probes'))){
        $owner=OHRead $c (Join-Path $dir.FullName 'ownership.json');$result=OHRead $c (Join-Path $dir.FullName 'result.json')
        $unsafe=($owner -and ((OHField $owner State 'Unknown') -ne 'Stopped' -or ((OHField $owner TraceGuid) -and (OHField $owner TraceState '') -ne 'Stopped'))) -or ($result -and (OHField $result CleanupComplete $false) -ne $true)
        if(-not $owner -and (OHTrack $c (Join-Path $dir.FullName 'candidate.private.json') -PresenceOnly) -cne 'missing'){$unsafe=$true}
        if($owner){OHReferences $c $owner ProbeReference};if($result){OHReferences $c $result ProbeReference}
        if($unsafe){
            $node=[string](OHField $owner NodeId (OHField $result NodeId ''));$matched=@($c.Records|Where-Object {('CandidateNodeId:'+$node) -in $_.Tokens})
            if($node -and $matched.Count){foreach($r in $matched){OHReason $r CleanupIncomplete;$r.CanResume=$false;if($r.IdentityState -ne 'Archived'){$r.Classification='Continue';$r.NextAction='Reconcile'}}}else{OHGlobal $c ProbeOwnershipUnknown}
        }
    }
    # Identity metadata is public; protected crypto and private-key files are never read.
    foreach($dir in @(OHChildren $c (Join-Path $c.Root 'identities'))){
        $enrollment=OHRead $c (Join-Path $dir.FullName 'enrollment.json')
        $pending=($enrollment -and (OHField $enrollment State 'Unknown') -notin @('Completed','Cancelled','Rejected','Expired'))
        foreach($doc in @($enrollment,(OHRead $c (Join-Path $dir.FullName 'public.request.json')))){if($doc){OHReferences $c $doc $(if($pending){'PendingIdentityReference'}else{'IdentityReference'})}}
    }
    foreach($s in $c.Servers){OHLockFact $c (Join-Path $c.Root ('servers\.task-'+$s.LocalRecordId+'.lock')) '' $s.LocalRecordId}
    foreach($relative in @('.session.lock','.preferences.lock','Product\.store.lock','servers\.registry.lock','linux-jobs\.bridge.lock','operation-history\.history.lock')){OHLockFact $c (Join-Path $c.Root $relative) '' ''}
    OHVisibility $c
    # Verify all content and memberships again; never approve a torn read.
    foreach($file in @($c.Files.Values)){if((OHFileStamp $c $file.Path -PresenceOnly:$file.PresenceOnly) -cne $file.Stamp){OHFail HistorySnapshotChanged}}
    foreach($dir in @($c.Directories.Values)){
        $names=@();if([IO.Directory]::Exists($dir.Path)){$names=@(Get-ChildItem -LiteralPath $dir.Path -Force -ErrorAction Stop|Where-Object {if($dir.Files){-not $_.PSIsContainer -and $_.Name.EndsWith('.json',[StringComparison]::OrdinalIgnoreCase)}else{$_.PSIsContainer}}|Sort-Object Name|ForEach-Object {$null=OHPath $c.Root $_.FullName;$_.Name})}
        if((Get-TCDDigest $names) -cne (Get-TCDDigest $dir.Names)){OHFail HistorySnapshotChanged}
    }
    $c.Digest=Get-TCDDigest ([ordered]@{Root=$c.Root.ToLowerInvariant();Files=@($c.Files.Values|Sort-Object Path);Directories=@($c.Directories.Values|Sort-Object Path,Files);Locks=@($c.Locks.Values|Sort-Object Path);Records=@($c.Records|ForEach-Object {[ordered]@{Id=$_.Id;Reasons=@($_.Reasons|Sort-Object);Hidden=$_.Hidden;Classification=$_.Classification;Identity=$_.IdentityState}})})
    return $c
}
function OHPublic {
    param($Record)
    $issue=OHField $Record.Doc AccessIssue
    [pscustomobject][ordered]@{SchemaVersion=1;Id=$Record.Id;SourceKind=$Record.SourceKind;SourceId=$Record.SourceId;ServerRecordId=$(if($Record.ServerIds.Count -eq 1){$Record.ServerIds[0]}else{$null});ServerRecordIds=@($Record.ServerIds);IdentityState=$Record.IdentityState;Name=(OHText (OHField $Record.Doc Name) '操作记录');Operation=$Record.Operation;Status=$Record.Status;Stage=$Record.Stage;UpdatedAtUtc=$Record.UpdatedAtUtc;AutoSavedAtUtc=(OHTime (OHField $Record.Doc AutoSavedAtUtc));AccessIssue=(OHCode (OHField $issue Code $issue));AttentionRequired=$Record.AttentionRequired;IsPrepared=$Record.IsPrepared;Classification=$Record.Classification;NextAction=$Record.NextAction;CanResume=$Record.CanResume;Hidden=$Record.Hidden;HiddenRequested=$Record.HiddenRequested;Archived=$Record.Hidden;LegacyArchived=$Record.LegacyHidden;CanClear=$Record.CanClear;Protected=(-not $Record.CanClear);ProtectionReasons=@($Record.Reasons|Sort-Object -Unique);DataRetentionReasons=@($Record.DataRetentionReasons)}
}
function Get-TCOperationHistory {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[switch]$IncludeHidden)
    $ErrorActionPreference='Stop';$c=OHSnapshot $Root
    return @($c.Records|Where-Object {$IncludeHidden -or -not $_.Hidden}|ForEach-Object {OHPublic $_}|Sort-Object UpdatedAtUtc,Id -Descending)
}
function Get-TCDeploymentCenter {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root)
    $ErrorActionPreference='Stop';$c=OHSnapshot $Root
    $records=@($c.Records|Where-Object {-not $_.Hidden}|ForEach-Object {OHPublic $_}|Sort-Object UpdatedAtUtc,Id -Descending)
    $servers=@();$cards=@();$draftServers=@();$archivedServers=@()
    foreach($s in $c.Servers){
        $id=$s.LocalRecordId;$linked=@($c.LinkedNodes[$id])
        $source=@($records|Where-Object {$id -in $_.ServerRecordIds});$allSourceIds=@($c.Records|Where-Object {$id -in $_.ServerIds}|ForEach-Object {$_.Id})
        $live=@($source|Where-Object {$_.Classification -in @('Continue','Prepared') -or $_.AttentionRequired})
        $connection=OHField $s Connection
        $realIdentity=((OHField $s RemoteOwnerId) -and (OHField $s ServerPublicKey) -and (OHField $s NodeId))
        $fresh=$false
        try{
            $address=$null;$confirmed=OHTime (OHField (OHField $s Reinstall) ConfirmedAtUtc)
            $fresh=($confirmed -and [DateTimeOffset]$confirmed -le [DateTimeOffset]::UtcNow.AddMinutes(5) -and (OHField $s PinnedHostKey '') -cmatch '^SHA256:[A-Za-z0-9+/]{43}=?$' -and [Net.IPAddress]::TryParse([string](OHField $connection Host ''),[ref]$address) -and $address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and [int](OHField $connection Port 0) -ge 1 -and [int](OHField $connection Port 0) -le 65535 -and (OHField $connection User '') -cmatch '^[a-z_][a-z0-9_-]{0,31}$')
        }catch{$fresh=$false}
        $summary=[pscustomobject]@{ServerRecordId=$id;LocalRecordId=$id;Name=(OHText (OHField $s Name) '服务器');Host=(OHText (OHField $connection Host));RecordState=(OHCode (OHField $s RecordState 'Active'));Classification='Draft';LinkedNodeIds=$linked;SourceIds=$allSourceIds;CanResume=$false}
        if($summary.RecordState -eq 'Archived'){$summary.Classification='History';$archivedServers+=,$summary;continue}
        if($summary.RecordState -ne 'Active' -or (-not $live.Count -and -not $realIdentity -and -not $linked.Count -and -not $fresh)){$draftServers+=,$summary;continue}
        $summary.Classification=if(@($live|Where-Object Classification -eq 'Continue').Count -or ($fresh -and -not $linked.Count -and -not $realIdentity)){'Continue'}elseif(@($live|Where-Object Classification -eq 'Prepared').Count -or $linked.Count){'Prepared'}else{'Available'}
        $servers+=,$summary
        $primary=@($live|Sort-Object @{Expression={if($_.ProtectionReasons -contains 'OutcomeOrRecoveryUnresolved'){0}elseif($_.AttentionRequired){1}elseif($_.Classification -eq 'Continue'){2}else{3}}},@{Expression='UpdatedAtUtc';Descending=$true},Id|Select-Object -First 1)
        $summary.CanResume=($primary.Count -gt 0 -and $primary[0].CanResume) -or ($fresh -and -not $primary.Count -and $summary.Classification -eq 'Continue')
        $cards+=,[pscustomobject]@{Id=('ServerRecord:'+$id);ServerRecordId=$id;Name=$summary.Name;Classification=$summary.Classification;PrimaryId=$(if($primary.Count){$primary[0].Id}else{$null});NextAction=$(if($primary.Count){$primary[0].NextAction}elseif($linked.Count){'ViewLine'}elseif($fresh){'BeginDeployment'}else{'ManageServer'});CanResume=$summary.CanResume;SourceIds=$allSourceIds;LinkedNodeIds=$linked}
    }
    # Unbound actionable records still surface; never manufacture a server from IP.
    foreach($r in @($records|Where-Object {$_.Classification -in @('Continue','Prepared') -and $_.ServerRecordIds.Count -ne 1})){
        $cards+=,[pscustomobject]@{Id=$r.Id;ServerRecordId=$null;Name=$r.Name;Classification=$r.Classification;PrimaryId=$r.Id;NextAction=$r.NextAction;CanResume=$false;SourceIds=@($r.Id);LinkedNodeIds=@()}
    }
    [pscustomobject][ordered]@{SchemaVersion=1;Servers=@($servers);Cards=@($cards);ContinueRuns=@($records|Where-Object Classification -eq 'Continue');PreparedRuns=@($records|Where-Object Classification -eq 'Prepared');Drafts=@($records|Where-Object Classification -eq 'Draft');History=@($records|Where-Object Classification -eq 'History');DraftServers=@($draftServers);ArchivedServers=@($archivedServers);HiddenCount=@($c.Records|Where-Object Hidden).Count;Diagnostics=@($c.GlobalReasons|Sort-Object -Unique);NetworkChanged=$false;RemoteChanges=$false}
}
function OHProtectToken {
    param($Value)
    Add-Type -AssemblyName System.Security
    $bytes=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Value -Depth 8 -Compress))
    try{return [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect($bytes,[Text.Encoding]::UTF8.GetBytes('TradeChannel.OperationHistory.v1'),[Security.Cryptography.DataProtectionScope]::CurrentUser))}finally{[Array]::Clear($bytes,0,$bytes.Length)}
}
function OHSelectionIds {
    param([AllowNull()][AllowEmptyCollection()][string[]]$Ids,$Context=$null)
    if(-not $Ids -or -not $Ids.Count){OHFail HistorySelectionEmpty}
    $keys=@()
    foreach($id in $Ids){
        if($id -cnotmatch '^(DeploymentRun|LegacyLinuxJob|ManagementIntent):(.+)$'){OHFail HistoryInvalidId}
        $key=OHKey $matches[1] $matches[2]
        if($Context -and -not $Context.ById.ContainsKey($key)){OHFail HistoryRecordMissing}
        $keys+=,$key
    }
    return @($keys|Sort-Object -Unique)
}
function OHReadToken {
    param([string]$Root,[string]$Token)
    $bytes=$null
    try{
        if(-not $Token -or $Token.Length -gt 1048576){throw 'token'}
        Add-Type -AssemblyName System.Security
        $bytes=[Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($Token),[Text.Encoding]::UTF8.GetBytes('TradeChannel.OperationHistory.v1'),[Security.Cryptography.DataProtectionScope]::CurrentUser)
        $v=[Text.Encoding]::UTF8.GetString($bytes)|ConvertFrom-Json -ErrorAction Stop
        if($v.SchemaVersion -notin @(1,2) -or $v.RootDigest -cne (Get-TCDDigest $Root.ToLowerInvariant()) -or $v.CandidateIds -isnot [array] -or $v.SnapshotDigest -cnotmatch '^[a-f0-9]{64}$'){throw 'binding'}
        if($v.SchemaVersion -eq 1){
            # Already issued v1 tokens retain their original all-record meaning.
            if($v.PSObject.Properties['Scope'] -or $v.PSObject.Properties['SelectedIds']){throw 'v1 scope'}
            $v|Add-Member NoteProperty Scope 'All';$v|Add-Member NoteProperty SelectedIds @()
        }else{
            if($v.Scope -cnotin @('All','Selected') -or $v.SelectedIds -isnot [array]){throw 'scope'}
            if($v.Scope -ceq 'All'){if($v.SelectedIds.Count){throw 'all selection'}}
            else{
                $selected=@(OHSelectionIds $v.SelectedIds)
                if((Get-TCDDigest $selected) -cne (Get-TCDDigest $v.SelectedIds)){throw 'selection'}
                if(@($v.CandidateIds|Where-Object {$_ -cnotin $selected}).Count){throw 'expanded candidate scope'}
            }
        }
        if($v.CandidateIds.Count -and (Get-TCDDigest @(OHSelectionIds $v.CandidateIds)) -cne (Get-TCDDigest $v.CandidateIds)){throw 'candidates'}
        return $v
    }catch{OHFail HistoryPreviewInvalid}finally{if($bytes){[Array]::Clear($bytes,0,$bytes.Length)}}
}
function New-TCHistoryClearPreview {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[AllowNull()][AllowEmptyCollection()][string[]]$Ids)
    $ErrorActionPreference='Stop';$c=OHSnapshot $Root
    $scope='All';$selected=@();$records=@($c.Records.ToArray())
    if($PSBoundParameters.ContainsKey('Ids')){$scope='Selected';$selected=@(OHSelectionIds $Ids $c);$records=@($c.Records|Where-Object {$_.Id -cin $selected})}
    $eligible=@($records|Where-Object {$_.CanClear -and -not $_.Hidden}|ForEach-Object {OHPublic $_}|Sort-Object Id)
    $protected=@($records|Where-Object {-not $_.CanClear}|ForEach-Object {OHPublic $_}|Sort-Object Id)
    $expiry=[DateTimeOffset]::UtcNow.AddMinutes(10).ToUnixTimeSeconds()
    $token=OHProtectToken @{SchemaVersion=2;Scope=$scope;SelectedIds=$selected;RootDigest=(Get-TCDDigest $c.Root.ToLowerInvariant());SnapshotDigest=$c.Digest;CandidateIds=@($eligible|ForEach-Object {$_.Id});ExpiresAt=$expiry}
    [pscustomobject][ordered]@{SchemaVersion=1;Scope=$scope;SelectedIds=$selected;PreviewToken=$token;ExpiresAtUtc=[DateTimeOffset]::FromUnixTimeSeconds($expiry).UtcDateTime.ToString('o');Eligible=$eligible;Protected=$protected;EligibleCount=$eligible.Count;ProtectedCount=$protected.Count;HiddenCount=@($records|Where-Object Hidden).Count;Diagnostics=@($c.GlobalReasons|Sort-Object -Unique);DisplayOnly=$true;NetworkChanged=$false;RemoteChanges=$false}
}
function OHOpenLocks {
    param($Context)
    $handles=New-Object 'Collections.Generic.List[object]';$owned=New-Object 'Collections.Generic.List[string]'
    $paths=@((Join-Path $Context.Root '.session.lock'))
    if([IO.Directory]::Exists((Join-Path $Context.Root 'Product'))){$paths+=Join-Path $Context.Root 'Product\.store.lock'}
    $paths+=Join-Path $Context.Root '.preferences.lock'
    $paths+=@($Context.Locks.Keys|Where-Object {$_ -notin $paths -and [IO.Directory]::Exists([IO.Path]::GetDirectoryName($_))}|Sort-Object)
    $history=Join-Path $Context.Root 'operation-history';$null=New-TCDDirectory (OHPath $Context.Root $history)
    $paths+=Join-Path $history '.history.lock'
    try{
        foreach($p in @($paths|Select-Object -Unique)){
            $p=OHPath $Context.Root $p
            # Nonwaiting acquisition avoids lock-order inversions with old writers.
            try{$h=[IO.File]::Open($p,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch{OHFail HistoryBusy}
            $handles.Add($h);$owned.Add($p)
        }
        return [pscustomobject]@{Handles=$handles;Paths=@($owned.ToArray())}
    }catch{for($i=$handles.Count-1;$i -ge 0;$i--){$handles[$i].Dispose()};throw}
}
function OHCloseLocks {param($Locks) if($Locks){for($i=$Locks.Handles.Count-1;$i -ge 0;$i--){$Locks.Handles[$i].Dispose()}}}
function OHWriteVisibility {
    param($Context,[string[]]$Ids,[bool]$Hidden,$Receipt)
    $store=$Context.Visibility;$entries=@($store.Entries|Where-Object {(OHField $_ Id '') -notin $Ids})
    foreach($id in $Ids){$r=$Context.ById[$id];$entries+=,[pscustomobject]@{Id=$id;SourceKind=$r.SourceKind;SourceId=$r.SourceId;Hidden=$Hidden;LegacyMarkerDigest=$r.LegacyDigest;UpdatedAtUtc=[DateTime]::UtcNow.ToString('o')}}
    $commits=@($store.Commits);if($Receipt){$commits+=,$Receipt}
    $path=OHPath $Context.Root (Join-Path $Context.Root 'operation-history\visibility.json')
    Write-TCDJson $path ([ordered]@{SchemaVersion=1;Revision=([long]$store.Revision+1);Entries=@($entries|Sort-Object Id);Commits=$commits})
}
function OHClearResult {
    param($Receipt,[bool]$AlreadyApplied)
    [pscustomobject][ordered]@{Scope=(OHField $Receipt Scope 'All');SelectedIds=@(OHField $Receipt SelectedIds @());ClearedIds=@($Receipt.ClearedIds);ClearedCount=$(if($AlreadyApplied){0}else{@($Receipt.ClearedIds).Count});ProtectedCount=$Receipt.ProtectedCount;AlreadyApplied=$AlreadyApplied;DisplayOnly=$true;DataDeleted=$false;ServerChanged=$false;NetworkChanged=$false;RemoteChanges=$false}
}
function Clear-TCOperationHistory {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$PreviewToken)
    $ErrorActionPreference='Stop';$rootPath=OHRoot $Root;$token=OHReadToken $rootPath $PreviewToken;$tokenHash=Get-TCDDigest $PreviewToken
    $before=OHSnapshot $rootPath;$locks=$null
    try{
        $locks=OHOpenLocks $before;$c=OHSnapshot $rootPath $locks.Paths
        $receipts=@($c.Visibility.Commits|Where-Object {(OHField $_ TokenDigest '') -ceq $tokenHash})
        if($receipts.Count -eq 1){return OHClearResult $receipts[0] $true}
        if($receipts.Count -gt 1){OHFail HistoryVisibilityInvalid}
        if($token.ExpiresAt -lt [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -or $token.ExpiresAt -gt [DateTimeOffset]::UtcNow.AddMinutes(11).ToUnixTimeSeconds() -or $token.SnapshotDigest -cne $c.Digest){OHFail HistoryPreviewStale}
        $records=@($c.Records.ToArray())
        if($token.Scope -ceq 'Selected'){
            $selected=@(OHSelectionIds $token.SelectedIds $c)
            $records=@($c.Records|Where-Object {$_.Id -cin $selected})
        }
        $eligible=@($records|Where-Object {$_.CanClear -and -not $_.Hidden}|Sort-Object Id|ForEach-Object {$_.Id})
        if($token.ExpiresAt -lt [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -or $token.ExpiresAt -gt [DateTimeOffset]::UtcNow.AddMinutes(11).ToUnixTimeSeconds() -or $token.SnapshotDigest -cne $c.Digest -or (Get-TCDDigest $token.CandidateIds) -cne (Get-TCDDigest $eligible)){OHFail HistoryPreviewStale}
        # Re-scan immediately before the atomic metadata commit. Legacy intent
        # writers do not share a history lock; content/membership changes abort.
        $again=OHSnapshot $rootPath $locks.Paths
        if($again.Digest -cne $c.Digest){OHFail HistoryPreviewStale}
        $receipt=[pscustomobject]@{TokenDigest=$tokenHash;Scope=$token.Scope;SelectedIds=@($token.SelectedIds);ClearedIds=$eligible;ProtectedCount=@($records|Where-Object {-not $_.CanClear}).Count;AppliedAtUtc=[DateTime]::UtcNow.ToString('o')}
        if($eligible.Count){OHWriteVisibility $c $eligible $true $receipt}
        return OHClearResult $receipt $false
    }finally{OHCloseLocks $locks}
}
function Restore-TCOperationHistory {
    [CmdletBinding()]param([Parameter(Mandatory=$true)][string]$Root,[Parameter(Mandatory=$true)][string]$Id)
    $ErrorActionPreference='Stop'
    if($Id -cnotmatch '^(DeploymentRun|LegacyLinuxJob|ManagementIntent):(.+)$'){OHFail HistoryInvalidId}
    $key=OHKey $matches[1] $matches[2];$before=OHSnapshot $Root;$locks=$null
    if(-not $before.ById.ContainsKey($key)){OHFail HistoryRecordMissing}
    try{
        $locks=OHOpenLocks $before;$c=OHSnapshot $before.Root $locks.Paths
        if(-not $c.ById.ContainsKey($key)){OHFail HistoryRecordMissing}
        $r=$c.ById[$key];$restored=$r.HiddenRequested
        if($restored){OHWriteVisibility $c @($key) $false $null;$r.HiddenRequested=$false;$r.Hidden=$false}
        [pscustomobject][ordered]@{Id=$key;Restored=$restored;AlreadyVisible=(-not $restored);Record=(OHPublic $r);DisplayOnly=$true;IdentityRevalidated=$false;ServerChanged=$false;DataDeleted=$false;NetworkChanged=$false;RemoteChanges=$false}
    }finally{OHCloseLocks $locks}
}
Export-ModuleMember -Function Get-TCOperationHistory,Get-TCDeploymentCenter,New-TCHistoryClearPreview,Clear-TCOperationHistory,Restore-TCOperationHistory
