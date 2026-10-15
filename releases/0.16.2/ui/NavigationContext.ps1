# Navigation contains public object IDs only. It never owns credentials or starts work.
function NavigationField {param($Value,[string]$Name,$Default=$null)
 if($Value -is [Collections.IDictionary]){if($Value.Contains($Name)){return $Value[$Name]}}
 elseif($null -ne $Value -and $Value.PSObject.Properties[$Name]){return $Value.$Name};return $Default
}
function NavigationVariable {param([string]$Name,$Default=$null)
 $v=Get-Variable -Name $Name -Scope Script -ErrorAction SilentlyContinue;if($v){return $v.Value};return $Default
}
function SetNavigationContext {param([string]$Section,[string]$View,[string]$TargetId='',$ReturnTo=$null)
 $old=NavigationVariable 'NavigationContext';$revision=[int](NavigationField $old 'Revision' 0)
 if(-not $PSBoundParameters.ContainsKey('ReturnTo') -and (NavigationField $old 'Section' '') -ceq $Section -and (NavigationField $old 'View' '') -ceq $View -and (NavigationField $old 'TargetId' '') -ceq $TargetId){$ReturnTo=NavigationField $old 'ReturnTo'}
 if((NavigationField $old 'Section' '') -cne $Section -or (NavigationField $old 'View' '') -cne $View -or (NavigationField $old 'TargetId' '') -cne $TargetId){$revision++}
 $script:NavigationContext=@{Section=$Section;View=$View;TargetId=$TargetId;Revision=$revision;ReturnTo=$ReturnTo}
}
function SyncNavigationContext {param([string]$Page,[string]$Title='')
 $role=[string](NavigationVariable 'Role' '');$deploy=NavigationVariable 'DeployUI';$line=NavigationVariable 'LineProfileUI';$current=NavigationVariable 'NavigationContext'
 switch($Page){
  'home'{SetNavigationContext 'home' 'home';return}
  'nodes'{SetNavigationContext 'nodes' 'nodes';return}
  'line-profiles'{SetNavigationContext 'nodes' $(if(NavigationField $line 'MaintenanceMode' $false){'line-maintenance'}else{'line-profiles'}) ([string](NavigationField $line 'Id' ''));return}
  'automatic-tcp'{SetNavigationContext 'nodes' 'automatic-tcp' ([string](NavigationField (NavigationVariable 'AutoTCP') 'Id' ''));return}
  'line-recovery'{SetNavigationContext 'nodes' 'line-recovery' ([string](NavigationField (NavigationVariable 'RecoveryContext') 'Id' ''));return}
  'setup'{
   switch($role){
    'servers'{
     if((NavigationField $current 'View' '') -notin @('server-list','server-detail')){SetNavigationContext 'nodes' 'server-list'};return
    }
    'devices'{SetNavigationContext 'nodes' 'server-detail' ([string](NavigationField (NavigationField $deploy 'Management') 'ServerId' ''));return}
    'deployment-center'{SetNavigationContext 'setup' 'deployment-center';return}
    'operation-history'{SetNavigationContext 'setup' 'operation-history';return}
    'operation-record'{SetNavigationContext 'setup' 'operation-record' ([string](NavigationField $deploy 'RecordDetailId' ''));return}
    'deployment'{
     $id=[string](NavigationField (NavigationField $deploy 'Run') 'RunId' (NavigationField $deploy 'ServerId' ''))
     SetNavigationContext 'setup' 'deployment' $id;return
    }
    'product-pair'{SetNavigationContext ([string](NavigationField (NavigationField $deploy 'PairReturnContext') 'Section' 'setup')) 'product-pair' ([string](NavigationField $deploy 'EnrollmentId' ''));return}
    'product-recovery'{SetNavigationContext ([string](NavigationField (NavigationField $deploy 'RecoveryReturnContext') 'Section' 'setup')) 'product-recovery' ([string](NavigationField (NavigationField $deploy 'Management') 'ServerId' ''));return}
    'migration'{SetNavigationContext 'setup' 'migration';return}
    'purchase'{SetNavigationContext 'setup' 'purchase';return}
    default{SetNavigationContext 'setup' ('wizard-'+$role) ([string](NavigationVariable 'Step' 0));return}
   }
  }
  default{SetNavigationContext 'settings' $Page;return}
 }
}
function CaptureNavigationContext {
 SyncNavigationContext ([string](NavigationVariable 'Page' 'home'))
 $c=NavigationVariable 'NavigationContext';$deploy=NavigationVariable 'DeployUI';$line=NavigationVariable 'LineProfileUI'
 return [pscustomobject]@{Section=[string]$c.Section;View=[string]$c.View;TargetId=[string]$c.TargetId;Revision=[int]$c.Revision;Page=[string](NavigationVariable 'Page' 'home');Role=[string](NavigationVariable 'Role' '');LineId=[string](NavigationField $line 'Id' '');ServerId=[string](NavigationField (NavigationField $deploy 'Management') 'ServerId' (NavigationField $deploy 'ServerId' ''));RunId=[string](NavigationField (NavigationField $deploy 'Run') 'RunId' '');ReturnTo=$c.ReturnTo}
}
function TestNavigationContext {param($Context)
 if(-not $Context){return $false};$current=CaptureNavigationContext
 return ($current.Section -ceq [string](NavigationField $Context 'Section' '') -and $current.View -ceq [string](NavigationField $Context 'View' '') -and $current.TargetId -ceq [string](NavigationField $Context 'TargetId' '') -and $current.Revision -eq [int](NavigationField $Context 'Revision' -1))
}
function ReturnNavigationContext {param($Context=$null)
 if(-not $Context){$Context=NavigationField (NavigationVariable 'NavigationContext') 'ReturnTo'}
 $view=[string](NavigationField $Context 'View' '');$target=[string](NavigationField $Context 'TargetId' '')
 switch($view){
  'home'{ShowHome;return}
  'nodes'{ShowNodes;FetchNodes;return}
  'line-profiles'{if($target){LoadLineConnections $target}else{ShowNodes;FetchNodes};return}
  'line-maintenance'{if($target){LoadLineConnections $target -MaintenanceMode}else{ShowNodes;FetchNodes};return}
  'operation-history'{ShowUnifiedOperationHistory;return}
  'operation-record'{if($target){ShowOperationRecordDetail $target -ReturnContext (NavigationField $Context 'ReturnTo')}else{ShowUnifiedOperationHistory};return}
  'server-list'{ShowServerListUI;return}
  'server-detail'{if($target){SelectServerUI $target}else{ShowServerListUI};return}
  'product-pair'{ShowProductPairing;return}
  'product-recovery'{ShowManagementRecovery;return}
  'migration'{ShowMigration;return}
  'purchase'{ShowPurchasePreparation;return}
  default{ShowSetupCenter;return}
 }
}
