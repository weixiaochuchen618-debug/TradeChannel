#requires -Version 5.1
[CmdletBinding()]param([Parameter(Mandatory=$true)][string]$InboxPath,[Parameter(Mandatory=$true)][int]$OwnerProcessId,[Parameter(Mandatory=$true)][long]$OwnerStartedTicks,[switch]$IsolatedTest,[string]$TestRoot)
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$env:PSModulePath=Join-Path $PSHOME 'Modules'
# This reader belongs to one console; it is never installed as a service or task.
# Its mailbox carries IDs, never scripts, arbitrary paths or mutation actions.
$package=Split-Path $PSScriptRoot -Parent
$root=if($IsolatedTest){[IO.Path]::GetFullPath($TestRoot).TrimEnd('\')}else{Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'TradeChannel'}
if($IsolatedTest -and (-not ($root+'\').StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($root) -cnotmatch '^TradeChannel-worker-fixture-[a-f0-9]{32}$')){throw 'Invalid isolated read root'}
$jobRoot=[IO.Path]::GetFullPath((Join-Path $root 'Product\jobs')).TrimEnd('\')
$inbox=[IO.Path]::GetFullPath($InboxPath)
if([IO.Path]::GetDirectoryName($inbox) -ine $jobRoot -or [IO.Path]::GetFileName($inbox) -cnotmatch '^read-[a-f0-9]{32}\.inbox\.json$'){throw 'Invalid reader mailbox'}
$readerId=[IO.Path]::GetFileName($inbox).Substring(5,32)
function AssertReadPath {param([string]$Path)
 $cursor=$Path
 while($cursor){if([IO.File]::Exists($cursor) -or [IO.Directory]::Exists($cursor)){if(([IO.File]::GetAttributes($cursor) -band [IO.FileAttributes]::ReparsePoint) -ne 0){throw 'Reader path contains a reparse point'}};$cursor=[IO.Path]::GetDirectoryName($cursor)}
}
function ReadReaderJson {param([string]$Path)
 $stream=$null;$textReader=$null
 try{
  # UI publication and request cleanup use atomic replacement/deletion. Permit
  # those operations while reading a stable, bounded snapshot of this file.
  $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
  if($stream.Length -gt 4096){throw 'Reader message too large'}
  $textReader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true)
  return $textReader.ReadToEnd()|ConvertFrom-Json
 }finally{if($textReader){$textReader.Dispose()}elseif($stream){$stream.Dispose()}}
}
AssertReadPath $inbox
$owner=Get-Process -Id $OwnerProcessId -ErrorAction Stop
if($owner.StartTime.ToUniversalTime().Ticks -ne $OwnerStartedTicks -or $owner.SessionId -ne [Diagnostics.Process]::GetCurrentProcess().SessionId){$owner.Dispose();throw 'Reader owner changed'}
$wake=[Threading.EventWaitHandle]::OpenExisting('Local\TradeChannel.Read.'+$readerId)
$lastRequest='';$lastWork=[DateTime]::UtcNow
try{
 while(-not $owner.HasExited -and ([DateTime]::UtcNow-$lastWork).TotalSeconds -lt 120){
  if([IO.File]::Exists($inbox+'.stop')){break}
  if([IO.File]::Exists($inbox)){
   AssertReadPath $inbox
   $mail=ReadReaderJson $inbox
   if($mail.ReaderId -cne $readerId -or $mail.RequestId -cnotmatch '^[a-f0-9]{32}$'){throw 'Reader mailbox identity invalid'}
   if($mail.RequestId -cne $lastRequest){
    $id=[string]$mail.RequestId;$requestPath=Join-Path $jobRoot ($id+'.request.json');$resultPath=Join-Path $jobRoot ($id+'.result.json')
    AssertReadPath $requestPath;AssertReadPath $resultPath
    $readRequest=ReadReaderJson $requestPath
    if($readRequest.RequestId -cne $id){throw 'Read request identity changed'}
    $arguments=@{RequestPath=$requestPath;ResultPath=$resultPath;ReadSession=$true}
    if($IsolatedTest){$arguments.IsolatedTest=$true;$arguments.TestRoot=$root}
    & (Join-Path $package 'Worker.ps1') @arguments
    $readRequest=$null;$arguments=$null;$lastRequest=$id;$lastWork=[DateTime]::UtcNow
   }
  }
  $null=$wake.WaitOne(1000)
 }
}finally{
 $wake.Dispose();$owner.Dispose()
 foreach($path in @($inbox,($inbox+'.stop'),($inbox+'.partial'))){if([IO.File]::Exists($path)){[IO.File]::Delete($path)}}
}
