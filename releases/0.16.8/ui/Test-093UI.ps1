# New management paths are captured requests only, never actual mutations.
Fixture;ShowNodes
AssertUI ($script:Controls.ContainsKey('EditProviderpvbat') -and $script:Controls.ContainsKey('DeleteProviderpvbat') -and $script:Controls.ContainsKey('RefreshProviderpvbat')) 'provider CRUD and path refresh are visible product controls'
$script:Actions.Clear();ClickUI 'EditProviderpvbat'
AssertUI ($script:ProviderForm.Editing -and $script:ProviderForm.Id -eq 'pv-bat' -and -not $script:Controls.ProviderFieldDirectory.IsReadOnly) 'provider edit retains identity and unlocks path fields'
$script:ProviderForm.Directory='C:\Fixture\Provider';ClickUI 'RegisterProvider'
AssertUI (@(Requests)[0].Request.Action -eq 'ProviderUpdate' -and @(Requests)[0].Request.Id -eq 'pv-bat') 'editing sends update rather than creating another identity'
Fixture;ShowNodes;$script:Actions.Clear();ClickUI 'DeleteProviderpvbat'
AssertUI ((DialogOpen) -and @(Requests).Count -eq 0) 'provider removal requires explicit confirmation and changes no live route';ClickDialog 'DialogCancel'
Fixture;ShowNodes;$script:Actions.Clear();ClickUI 'ManageTradeDomains'
CompleteUI ([pscustomobject]@{Domains=@('trade.example.com');AppliedDomains=@();NeedsPolicyUpdate=$true;NetworkChanged=$false})
AssertUI ($script:Controls.ContainsKey('AddTradeDomain') -and $script:Controls.ContainsKey('ResetTradeDomains')) 'trade domains have add and reset controls';Snapshot '37-trade-domain-management'
$script:Controls.TradeDomainInput.Text='new.trade.example.com';$script:Actions.Clear();ClickUI 'AddTradeDomain'
AssertUI (@(Requests)[0].Request.Action -eq 'TradeDomainEdit' -and @(Requests)[0].Request.Operation -eq 'Add' -and @(Requests)[0].Request.Domain -eq 'new.trade.example.com') 'domain edits save intent without activation'
Fixture;$script:Role='linux';$script:Linux.Stage=0;$script:Linux.Busy=$false;ShowLinux
AssertUI ($script:Controls.ContainsKey('LinuxTaskManagement')) 'archive management is reachable even when no recent jobs remain'
$script:Actions.Clear();ClickUI 'LinuxTaskManagement'
CompleteUI ([pscustomobject]@{Items=@([pscustomobject]@{JobId='fixture-done';Name='Completed';Host='203.0.113.70';Operation='Apply';Status='Completed';Archived=$false},[pscustomobject]@{JobId='fixture-archive';Name='Archived';Host='203.0.113.80';Operation='Apply';Status='Completed';Archived=$true})})
AssertUI ($script:Controls.ContainsKey('ShowArchivedTasks')) 'task manager includes archived view toggle';Snapshot '38-task-management'
$script:Actions.Clear();ArchiveLinuxTask 'fixture-done' $true;ClickDialog 'DialogConfirm'
AssertUI (@(Requests)[0].Request.Action -eq 'LinuxArchive' -and @(Requests)[0].Request.Id -eq 'fixture-done' -and @(Requests)[0].Request.Archived) 'archive is local metadata only and retains correct job identity'
Fixture;ShowNodes;$script:Actions.Clear();ClickUI 'RecommendedAgents'
AssertUI (@(Requests)[0].Request.AgentIds.Count -eq 22 -and -not @(Requests)[0].Request.ContainsKey('Exit') -and -not @(Requests)[0].Request.ContainsKey('NodeId')) 'recommended AI selection does not request a trading switch'
$script:Role='client';$script:Step=0;$script:ProviderFormOpen=$false
