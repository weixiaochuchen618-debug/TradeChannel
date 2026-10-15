#requires -Version 5.1
[CmdletBinding()]param([string]$PackageRoot,[string]$SourceFile,[string]$ReportPath,[switch]$ObserveOnly,[string[]]$Modes=@('python_missing','sudo_denied','drop_partial','missing_exit','backend_127','backend_sudo_text','backend_success'),[string[]]$Actions=@('inspect','apply'))
$ErrorActionPreference='Stop'
if($PSVersionTable.PSVersion.Major -ne 5){throw 'Use Windows PowerShell 5.1 for the actual Framework executor.'}
if(-not $PackageRoot){$PackageRoot=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent}
if(-not $SourceFile){$SourceFile=Join-Path $PackageRoot 'deployment\TradeChannelDeployHost.cs'}
$SourceFile=[IO.Path]::GetFullPath($SourceFile)
$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('TC-StartupSSH-'+[guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($fixtureRoot)
$cases=New-Object 'Collections.Generic.List[object]'
$executor=$null;$fixtureProcess=$null;$binding=$null

function Read-Exact {param([IO.Stream]$Stream,[int]$Count)
 $bytes=New-Object byte[] $Count;$offset=0
 while($offset -lt $Count){$pending=$Stream.BeginRead($bytes,$offset,$Count-$offset,$null,$null);if(-not $pending.AsyncWaitHandle.WaitOne(5000)){throw 'Fixture pipe read expired'};$size=$Stream.EndRead($pending);if($size -le 0){throw 'Fixture pipe closed'};$offset+=$size}
 return ,$bytes
}
function Request {param([hashtable]$Body)
 $Body.RunId=$binding.RunId;$Body.InstanceId=$binding.InstanceId
 $pipe=New-Object IO.Pipes.NamedPipeClientStream('.',$binding.PipeName,[IO.Pipes.PipeDirection]::InOut,[IO.Pipes.PipeOptions]::Asynchronous,[Security.Principal.TokenImpersonationLevel]::Impersonation)
 try{
  $pipe.Connect(3000);$bytes=[Text.Encoding]::UTF8.GetBytes(($Body|ConvertTo-Json -Depth 8 -Compress))
  $length=[BitConverter]::GetBytes($bytes.Length);$pipe.Write($length,0,4);$pipe.Write($bytes,0,$bytes.Length);$pipe.Flush();[Array]::Clear($bytes,0,$bytes.Length)
  $size=[BitConverter]::ToInt32((Read-Exact $pipe 4),0);if($size -lt 2 -or $size -gt 4MB){throw 'Fixture invalid response size'}
  return ([Text.Encoding]::UTF8.GetString((Read-Exact $pipe $size))|ConvertFrom-Json)
 }finally{$pipe.Dispose();if($Body.ContainsKey('Credential')){$Body.Credential.Clear();$Body.Remove('Credential')}}
}
function Await-Result {param([string]$Context)
 $deadline=[DateTime]::UtcNow.AddSeconds($(if($mode -eq 'stall_payload'){40}else{15}))
 do{$reply=Request @{Command='Poll'};if($reply.Status -notin @('Connecting','Running')){return $reply};Start-Sleep -Milliseconds 25}while([DateTime]::UtcNow -lt $deadline)
 throw ('Fixture bounded execution deadline expired: '+$Context+' '+$reply.Status+'/'+$reply.Code)
}
try{
 $compiler=Join-Path ([Environment]::GetFolderPath('Windows')) 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
 $exe=Join-Path $fixtureRoot 'TradeChannelDeployHost.exe'
 & $compiler /nologo /target:exe /platform:x64 ('/out:'+$exe) /reference:System.Web.Extensions.dll ('/reference:'+(Join-Path $PackageRoot 'assets\lib\Renci.SshNet.dll')) $SourceFile
 if($LASTEXITCODE -ne 0){throw 'Isolated executor compilation failed'}
 foreach($mode in $Modes){
  foreach($action in $Actions){
   $caseRoot=Join-Path $fixtureRoot ($mode+'-'+$action);$null=[IO.Directory]::CreateDirectory($caseRoot)
   $metadata=Join-Path $caseRoot 'fixture.json'
   $fixture=Join-Path $PSScriptRoot 'loopback_startup_fixture.py'
   $fixtureProcess=Start-Process -FilePath 'python.exe' -ArgumentList ('-B "'+$fixture+'" "'+$metadata+'" '+$mode) -WindowStyle Hidden -PassThru -RedirectStandardError (Join-Path $caseRoot 'fixture.stderr')
   $deadline=[DateTime]::UtcNow.AddSeconds(10)
   while(-not (Test-Path -LiteralPath $metadata)){if($fixtureProcess.HasExited -or [DateTime]::UtcNow -ge $deadline){throw 'Loopback SSH fixture failed to start'};Start-Sleep -Milliseconds 25}
   $target=[IO.File]::ReadAllText($metadata,[Text.Encoding]::UTF8)|ConvertFrom-Json
   $state=Join-Path $caseRoot 'state';$null=[IO.Directory]::CreateDirectory($state)
   $binding=@{RunId=[guid]::NewGuid().ToString('D');InstanceId=[guid]::NewGuid().ToString('D');PipeName=('TCDeploy-'+[guid]::NewGuid().ToString('N'))}
   $arguments=@($binding.PipeName,$binding.RunId,$binding.InstanceId,$state,$PackageRoot)|ForEach-Object {'"'+$_+'"'}
   $executor=Start-Process -FilePath $exe -ArgumentList ($arguments -join ' ') -WindowStyle Hidden -PassThru
   $null=Request @{Command='Poll'}
   $user=if($mode -in @('sudo_denied','backend_sudo_text')){'fixture'}else{'root'}
   $null=Request @{Command='Authenticate';Connection=@{Host='127.0.0.1';Port=[int]$target.Port;User=$user};Credential=@{Kind='Password';Password='TC_Isolated_Startup_Only_31!'};PinnedFingerprint=[string]$target.Fingerprint}
   $authenticated=Await-Result ($mode+'/'+$action+'/Authenticate');if($authenticated.Code -cne 'Authenticated'){throw ('Fixture authentication failed: '+$authenticated.Code)}
   $clock=[Diagnostics.Stopwatch]::StartNew()
   $inputValue=if($action -eq 'apply'){@{PlanId=[guid]::NewGuid().ToString('D')}}else{@{}}
   $null=Request @{Command='Execute';Operation=$action;OperationId=[guid]::NewGuid().ToString('D');Input=$inputValue}
   $reply=Await-Result ($mode+'/'+$action+'/Execute');$clock.Stop()
   $expectedStatus=if($mode -eq 'backend_success'){'Completed'}elseif($mode -like 'backend_*' -or $action -eq 'inspect'){'Failed'}else{'OutcomeUnknown'}
   $expectedCode=switch($mode){'python_missing'{'RemotePrerequisiteMissing'};'sudo_denied'{'RemotePrivilegeDenied'};'stall_payload'{'ConnectionTimeout'};default{''}}
   $codeOk=if($mode -eq 'backend_success'){$reply.Code -ceq 'Completed'}elseif($mode -like 'backend_*'){$reply.Code -ceq 'FixtureBackendRejected'}elseif($expectedCode){$reply.Code -ceq $expectedCode}else{$reply.Code -notin @('Completed','RemotePrerequisiteMissing','RemotePrivilegeDenied')}
   $statsPath=[IO.Path]::ChangeExtension($metadata,'stats.json');$deadline=[DateTime]::UtcNow.AddSeconds(2)
   while(-not (Test-Path -LiteralPath $statsPath) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 25}
   $stats=[IO.File]::ReadAllText($statsPath,[Text.Encoding]::UTF8)|ConvertFrom-Json
   $null=Request @{Command='Close'};$gracefulExit=$executor.WaitForExit(3000);if(-not $gracefulExit){$executor.Kill();$null=$executor.WaitForExit(3000)};$executor.Dispose();$executor=$null;$binding=$null
   $files=@(Get-ChildItem -LiteralPath $state -Recurse -File)
   $leaks=@($files|Where-Object {[IO.File]::ReadAllText($_.FullName,[Text.Encoding]::UTF8).Contains('TC_Isolated_Startup_Only_31!')})
   $bounded=if($mode -eq 'stall_payload'){$clock.Elapsed.TotalSeconds -ge 1 -and $clock.Elapsed.TotalSeconds -lt 35}else{$clock.Elapsed.TotalSeconds -lt 8}
   $passed=($codeOk -and $reply.Status -ceq $expectedStatus -and $bounded -and $leaks.Count -eq 0 -and -not $stats.BackendExecuted -and $stats.Commands -eq 1 -and $stats.BootstrapSyntaxValid -and $gracefulExit)
   $cases.Add([pscustomobject]@{Mode=$mode;Action=$action;Passed=$passed;Code=$reply.Code;Status=$reply.Status;ExpectedStatus=$expectedStatus;ElapsedMilliseconds=$clock.ElapsedMilliseconds;FailureStage=@($reply.Events|Where-Object FailureStage|Select-Object -Last 1 -ExpandProperty FailureStage);BytesReceived=$stats.BytesReceived;BackendExecuted=$stats.BackendExecuted;BootstrapSyntaxValid=$stats.BootstrapSyntaxValid;GracefulExecutorExit=$gracefulExit;PasswordLeaks=$leaks.Count})
   if(-not $fixtureProcess.HasExited){$fixtureProcess.Kill();$null=$fixtureProcess.WaitForExit(3000)};$fixtureProcess.Dispose();$fixtureProcess=$null
  }
 }
 $allPassed=(@($cases|Where-Object {-not $_.Passed}).Count -eq 0)
 $report=[pscustomobject]@{Passed=$allPassed;Cases=$cases.ToArray();Runtime=$PSVersionTable.PSVersion.ToString();SourceSHA256=(Get-FileHash -LiteralPath $SourceFile -Algorithm SHA256).Hash;ExecutableSHA256=(Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash;NetworkScope='127.0.0.1 only';RealRemoteServersTouched=$false;BackendExecuted=$false}
 if($ReportPath){[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($report|ConvertTo-Json -Depth 7),(New-Object Text.UTF8Encoding($true)))}
 $report|ConvertTo-Json -Depth 7
 if(-not $allPassed -and -not $ObserveOnly){throw 'Actual SSH startup failure matrix failed'}
}catch{
 if($ReportPath -and $caseRoot){$fixtureStats=$null;$statsPath=[IO.Path]::ChangeExtension($metadata,'stats.json');if(Test-Path -LiteralPath $statsPath){$fixtureStats=[IO.File]::ReadAllText($statsPath,[Text.Encoding]::UTF8)|ConvertFrom-Json};$fixtureError=Get-Content -LiteralPath (Join-Path $caseRoot 'fixture.stderr') -Raw -Encoding UTF8;$snapshot=if($binding){Request @{Command='Poll'}}else{$null};$failure=[pscustomobject]@{Passed=$false;Cases=$cases.ToArray();ErrorType=$_.Exception.GetType().Name;Error=$_.Exception.Message;Mode=$mode;Action=$action;Fixture=$fixtureStats;FixtureError=$fixtureError;Executor=$snapshot;SourceSHA256=(Get-FileHash -LiteralPath $SourceFile -Algorithm SHA256).Hash};[IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportPath),($failure|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($true)))}
 throw
}finally{
 if($executor){try{if($binding){$null=Request @{Command='Cancel'};$null=Request @{Command='Close'}}}catch{};if(-not $executor.HasExited){$executor.Kill();$null=$executor.WaitForExit(3000)};$executor.Dispose()}
 if($fixtureProcess){if(-not $fixtureProcess.HasExited){$fixtureProcess.Kill();$null=$fixtureProcess.WaitForExit(3000)};$fixtureProcess.Dispose()}
 $full=[IO.Path]::GetFullPath($fixtureRoot);$boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(-not $full.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -cnotmatch '^TC-StartupSSH-[a-f0-9]{32}$'){throw 'Fixture cleanup boundary rejected'}
 Remove-Item -LiteralPath $full -Recurse -Force
}
