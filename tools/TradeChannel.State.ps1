#requires -Version 5.1
# Runtime snapshots are atomically replaced by the supervisor. Allow rename/delete
# sharing and retry transient Windows file-sharing conflicts, without hiding a
# persistent read error or treating an unreadable state as "not running".
function Read-TradeChannelState {
    [CmdletBinding()]
    param([string]$Path='C:\ProgramData\TradeChannel\runtime.json', [int]$Attempts=12)
    if($Attempts -lt 1 -or $Attempts -gt 40){throw 'Invalid state read retry bound.'}
    for($attempt=0;$attempt -lt $Attempts;$attempt++){
        $stream=$null;$reader=$null
        try{
            $sharing=[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
            $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,$sharing)
            $reader=New-Object IO.StreamReader($stream,[Text.Encoding]::UTF8,$true)
            $raw=$reader.ReadToEnd()
            if([string]::IsNullOrWhiteSpace($raw)){throw 'Runtime state was empty; refusing to infer channel status.'}
            return ($raw|ConvertFrom-Json -ErrorAction Stop)
        }catch{
            $errorItem=$_
            $cause=$_.Exception
            while($cause.InnerException){$cause=$cause.InnerException}
            if(-not ($cause -is [IO.IOException]) -or $attempt -eq ($Attempts-1)){throw $errorItem}
        }finally{
            if($reader){$reader.Dispose()}elseif($stream){$stream.Dispose()}
        }
        Start-Sleep -Milliseconds 50
    }
}
