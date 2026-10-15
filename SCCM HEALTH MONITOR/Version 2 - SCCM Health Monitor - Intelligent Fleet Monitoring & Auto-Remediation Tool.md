```
#Requires -Version 5.1
<#
.SYNOPSIS
    SCCM Health Monitor - Intelligent Fleet Monitoring & Auto-Remediation Tool
.DESCRIPTION
    Parses 28 SCCM client logs, identifies root causes via a 15-pattern library, and
    displays a dark-themed WPF dashboard. Two targets are supported:

      Local machine         - scans the local CCM logs and enables the 8 remediation buttons.
      SCCM device collection - queries the SMS Provider for the members of a device collection
                              (type the Collection ID, or use Browse to pick one), then scans each
                              member's CCM logs over the ADMIN$ share in parallel. Scan only;
                              remediation actions always run on the local machine.
.NOTES
    Version  : 2.2
    Requires : Windows PowerShell 5.1 (ISE compatible), no extra modules
    Run As   : Administrator. Collection scans also need local admin on the target devices
               (ADMIN$ access) and at least Read-only Analyst rights on the SMS Provider.
    Run      : powershell.exe -ExecutionPolicy Bypass -File .\SCCM-HealthMonitor.ps1
#>

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

#region Configuration
$Script:Config = @{
    RefreshIntervalMinutes = 30
    LogWindowHours         = 2
    CCMLogPath             = "$env:windir\CCM\Logs"
    CCMCachePath           = "$env:windir\ccmcache"
    RemoteLogShare         = "ADMIN`$\CCM\Logs"
    ThrottleLimit          = 15
    Version                = "2.2"
}

$Script:LogSources = @(
    "AppDiscovery","AppEnforce","AppIntentEval","CAS","CCMEval","CCMExec",
    "CCMMessaging","CCMNotificationAgent","CCMRestart","CcmRepair",
    "ClientIDManagerStartup","ClientLocation","ContentTransferManager",
    "DataTransferService","execmgr","LocationServices","MaintenanceCoordinator",
    "PolicyAgent","PolicyEvaluator","RebootCoordinator","ScanAgent",
    "Scheduler","ServiceWindowManager","SoftwareCenterSystemTasks",
    "UpdatesDeployment","UpdatesHandler","UpdateStore","WUAHandler"
)

$Script:FailurePatterns = @(
    @{ ID=1;  Name="Disk Space Critical";       Regex="insufficient disk space|0x80070070|not enough space";                 Severity="Critical"; Remediation="Fix-DiskSpace" }
    @{ ID=2;  Name="BITS Transfer Failure";     Regex="BITS job failed|0x80200010|BG_E_NETWORK_DISCONNECTED";               Severity="High";     Remediation="Fix-BITSService" }
    @{ ID=3;  Name="CCM Cache Corruption";      Regex="cache.*corrupt|Failed to find.*cache|0x87d00607";                    Severity="High";     Remediation="Fix-CCMCache" }
    @{ ID=4;  Name="Policy Download Failure";   Regex="Failed to get client identity|policy download.*failed|0x87d00215";    Severity="High";     Remediation="Fix-PolicyAgent" }
    @{ ID=5;  Name="WUA Handler Error";         Regex="WUAHandler.*error|Failed to get supported updates|0x80070422";       Severity="High";     Remediation="Fix-WUAHandler" }
    @{ ID=6;  Name="CCM Service Crash";         Regex="CcmExec.*terminated|service.*stopped unexpectedly";                  Severity="Critical"; Remediation="Fix-CCMService" }
    @{ ID=7;  Name="Content Download Timeout";  Regex="Download.*timed out|content.*timeout|0x80072ee2";                    Severity="Medium";   Remediation="Fix-BITSService" }
    @{ ID=8;  Name="Hash Mismatch";             Regex="Hash.*mismatch|content.*validation.*failed|0x87d01107";              Severity="Medium";   Remediation="Fix-CCMCache" }
    @{ ID=9;  Name="Reboot Pending Block";      Regex="Reboot.*pending|pending reboot.*block|reboot.*required";             Severity="Medium";   Remediation="Fix-RebootPending" }
    @{ ID=10; Name="Network Location Fail";     Regex="Failed to get DP locations|No DP found|boundary.*not found";         Severity="Medium";   Remediation=$null }
    @{ ID=11; Name="App Install Failure";       Regex="Install.*returned.*error|installation.*failed|exit code (?!0\b)\d+"; Severity="High";     Remediation=$null }
    @{ ID=12; Name="WMI Repository Error";      Regex="WMI.*repository|Win32_.*failed|WMI.*error|0x80041001";               Severity="Critical"; Remediation="Fix-WMIRepository" }
    @{ ID=13; Name="Certificate Error";         Regex="certificate.*expired|SSL.*error|0x800B0101|PKI.*failed";             Severity="High";     Remediation=$null }
    @{ ID=14; Name="MP Communication Fail";     Regex="Failed to send.*MP|Management Point.*unreachable|0x87d00231";        Severity="High";     Remediation="Fix-PolicyAgent" }
    @{ ID=15; Name="Software Update Scan Fail"; Regex="Scan.*failed|UpdateStore.*error|0x80244010|0x8024400A";              Severity="Medium";   Remediation="Fix-WUAHandler" }
)

$Script:RemLog = New-Object System.Collections.Generic.List[string]
$Script:ScanResults = $null
$Script:AutoScanEnabled = $true
$Script:Mode = "Local"
$Script:Controls = @{}
$Script:Window = $null
$Script:AutoTimer = $null
$Script:FleetTimer = $null
$Script:Fleet = $null
$Script:SiteCodeCache = @{}
$Script:CollectionCache = $null
$Script:CollectionCacheServer = ""
$Script:PickerWindow = $null
$Script:PickerControls = @{}
$Script:PickedId = $null
#endregion

#region Helpers
function New-Brush {
    param([string]$Hex)
    return (New-Object System.Windows.Media.BrushConverter).ConvertFromString($Hex)
}

function Update-UiNow {
    # Flush pending UI changes so status text shows before a long blocking operation
    if ($Script:Window) {
        $Script:Window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
    }
}

function Write-RemLog {
    param([string]$Message, [switch]$Success, [switch]$Fail)
    $prefix = "[LOG] "
    if ($Success) { $prefix = "[OK]  " }
    elseif ($Fail) { $prefix = "[ERR] " }
    $Script:RemLog.Add("$(Get-Date -Format 'HH:mm:ss') $prefix$Message")
}

function Show-ScanError {
    param([string]$Message, [bool]$Silent = $false)
    $Script:Controls["txtStatus"].Text = $Message
    if (-not $Silent) {
        [System.Windows.MessageBox]::Show($Message, "SCCM Health Monitor", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
    }
}
#endregion

#region Device Scan Engine (shared by local scan and runspace-pool fleet scan)
# Self-contained on purpose: this block is also executed inside runspaces, so it
# must not reference $Script: variables or any function defined in this file.
$Script:DeviceScanBlock = {
    param($Computer, $LogPath, $Sources, $Patterns, $WindowHours)

    $result = [PSCustomObject]@{
        Computer    = $Computer
        Reachable   = $false
        LogsScanned = 0
        Entries     = 0
        Detections  = @()
        Error       = ""
    }

    try {
        if (-not (Test-Path -LiteralPath $LogPath)) {
            $result.Error = "Log path not reachable: $LogPath"
            return $result
        }

        $result.Reachable = $true
        $cutoff  = (Get-Date).AddHours(-$WindowHours)
        $culture = [System.Globalization.CultureInfo]::InvariantCulture
        $rxLine  = '<!\[LOG\[(?<msg>.*?)\]LOG\]!><time="(?<t>\d{2}:\d{2}:\d{2})[^"]*"\s+date="(?<d>\d{1,2}-\d{1,2}-\d{4})"'
        $all     = New-Object System.Collections.Generic.List[object]

        foreach ($log in $Sources) {
            $file = Join-Path $LogPath "$log.log"
            if (-not (Test-Path -LiteralPath $file)) { continue }
            if ((Get-Item -LiteralPath $file).LastWriteTime -lt $cutoff) { continue }

            $logHadEntries = $false
            $fs = $null
            $sr = $null
            try {
                # Shared read/write so actively-written CCM logs are not blocked
                $fs = New-Object System.IO.FileStream($file, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                $sr = New-Object System.IO.StreamReader($fs)
                while (-not $sr.EndOfStream) {
                    $line = $sr.ReadLine()
                    if ($line -match $rxLine) {
                        $msg   = $Matches['msg']
                        $stamp = "$($Matches['d']) $($Matches['t'])"
                        $ts    = [datetime]::MinValue
                        if ([datetime]::TryParseExact($stamp, "M-d-yyyy HH:mm:ss", $culture, [System.Globalization.DateTimeStyles]::None, [ref]$ts)) {
                            if ($ts -ge $cutoff) {
                                $logHadEntries = $true
                                $all.Add([PSCustomObject]@{ Timestamp = $ts; LogName = $log; Message = $msg.Trim() })
                            }
                        }
                    }
                }
            } catch {
                # Skip individual logs that cannot be read
            } finally {
                if ($sr) { $sr.Dispose() }
                if ($fs) { $fs.Dispose() }
            }
            if ($logHadEntries) { $result.LogsScanned++ }
        }

        $result.Entries = $all.Count
        $dets = New-Object System.Collections.Generic.List[object]
        foreach ($p in $Patterns) {
            $rx   = $p.Regex
            $hits = @($all | Where-Object { $_.Message -match $rx })
            if ($hits.Count -gt 0) {
                $latest = $hits | Sort-Object Timestamp -Descending | Select-Object -First 1
                $dets.Add([PSCustomObject]@{
                    Computer  = $Computer
                    PatternID = $p.ID
                    Count     = $hits.Count
                    LastSeen  = $latest.Timestamp
                    Logs      = (($hits | Select-Object -ExpandProperty LogName -Unique) -join ", ")
                    SampleMsg = $latest.Message
                })
            }
        }
        $result.Detections = $dets.ToArray()
    } catch {
        $result.Error = "$_"
    }
    return $result
}

function Merge-DeviceResults {
    param([object[]]$DeviceResults, [int]$Skipped = 0)

    $reached = @($DeviceResults | Where-Object { $_.Reachable })
    $failed  = @($DeviceResults | Where-Object { -not $_.Reachable })

    $allDet = New-Object System.Collections.Generic.List[object]
    foreach ($r in $reached) {
        foreach ($d in @($r.Detections)) {
            if ($null -ne $d) { $allDet.Add($d) }
        }
    }

    $logsTotal = 0
    foreach ($r in $reached) { $logsTotal += [int]$r.LogsScanned }

    $detections = New-Object System.Collections.Generic.List[object]
    foreach ($p in $Script:FailurePatterns) {
        $pid2 = $p.ID
        $hits = @($allDet | Where-Object { $_.PatternID -eq $pid2 })
        if ($hits.Count -gt 0) {
            $latest  = $hits | Sort-Object LastSeen -Descending | Select-Object -First 1
            $devices = @($hits | ForEach-Object { $_.Computer } | Sort-Object -Unique)
            $logs    = @($hits | ForEach-Object { $_.Logs -split ',\s*' } | Where-Object { $_ } | Sort-Object -Unique)
            $detections.Add([PSCustomObject]@{
                PatternID    = $p.ID
                Name         = $p.Name
                Severity     = $p.Severity
                Remediation  = $p.Remediation
                Count        = [int](($hits | Measure-Object -Property Count -Sum).Sum)
                LastSeen     = $latest.LastSeen
                Logs         = ($logs -join ", ")
                SampleMsg    = $latest.SampleMsg
                SampleDevice = $latest.Computer
                Devices      = $devices
            })
        }
    }

    $crit = @($detections | Where-Object { $_.Severity -eq "Critical" }).Count
    $high = @($detections | Where-Object { $_.Severity -eq "High" }).Count
    $health = "Healthy"
    if ($crit -gt 0) { $health = "Critical" }
    elseif ($high -gt 0) { $health = "Degraded" }
    elseif ($detections.Count -gt 0) { $health = "Warning" }
    if ($reached.Count -eq 0) { $health = "Unknown" }

    return [PSCustomObject]@{
        Timestamp      = Get-Date
        Detections     = $detections.ToArray()
        LogsScanned    = $logsTotal
        DevicesTotal   = @($DeviceResults).Count
        DevicesReached = $reached.Count
        DevicesFailed  = $failed
        Skipped        = $Skipped
        SystemHealth   = $health
    }
}

function Invoke-LogScan {
    $r = & $Script:DeviceScanBlock $env:COMPUTERNAME $Script:Config.CCMLogPath $Script:LogSources $Script:FailurePatterns $Script:Config.LogWindowHours
    $Script:ScanResults = Merge-DeviceResults -DeviceResults @($r) -Skipped 0
    return $Script:ScanResults
}
#endregion

#region SCCM Site Queries (SMS Provider via CIM, no ConfigurationManager module needed)
function Test-ServerName {
    param([string]$Name)
    return ($Name -match '^[A-Za-z0-9][A-Za-z0-9.\-]*$')
}

function Invoke-SiteQuery {
    param([string]$Server, [string]$Namespace, [string]$Query)
    try {
        return @(Get-CimInstance -ComputerName $Server -Namespace $Namespace -Query $Query -ErrorAction Stop)
    } catch {
        # Fall back to DCOM if WinRM to the provider is not available
        $opt  = New-CimSessionOption -Protocol Dcom
        $sess = New-CimSession -ComputerName $Server -SessionOption $opt -ErrorAction Stop
        try {
            return @(Get-CimInstance -CimSession $sess -Namespace $Namespace -Query $Query -ErrorAction Stop)
        } finally {
            Remove-CimSession $sess -ErrorAction SilentlyContinue
        }
    }
}

function Get-SiteCodeForServer {
    param([string]$Server)
    if ($Script:SiteCodeCache.ContainsKey($Server)) { return $Script:SiteCodeCache[$Server] }
    $rows = @(Invoke-SiteQuery -Server $Server -Namespace "root\sms" -Query "SELECT SiteCode, ProviderForLocalSite FROM SMS_ProviderLocation")
    $local = @($rows | Where-Object { $_.ProviderForLocalSite })
    $code = $null
    if ($local.Count -gt 0) { $code = [string]$local[0].SiteCode }
    elseif ($rows.Count -gt 0) { $code = [string]$rows[0].SiteCode }
    if (-not $code) { throw "No SMS Provider found on $Server." }
    $Script:SiteCodeCache[$Server] = $code
    return $code
}

function Get-CollectionMembers {
    param([string]$Server, [string]$SiteCode, [string]$CollectionID)
    $ns = "root\sms\site_$SiteCode"
    $q  = "SELECT * FROM SMS_R_System WHERE ResourceId IN (SELECT ResourceID FROM SMS_FullCollectionMembership WHERE CollectionID = '$CollectionID')"
    $rows = @(Invoke-SiteQuery -Server $Server -Namespace $ns -Query $q)

    $targets = New-Object System.Collections.Generic.List[object]
    $skipped = 0
    foreach ($r in $rows) {
        if (($r.Client -ne 1) -or ($r.Obsolete -eq 1)) { $skipped++; continue }
        $target = $null
        if ($r.DNSHostName) { $target = [string]$r.DNSHostName }
        elseif ($r.ResourceNames -and @($r.ResourceNames).Count -gt 0) { $target = [string]@($r.ResourceNames)[0] }
        else { $target = [string]$r.Name }
        if ([string]::IsNullOrWhiteSpace($target)) { $skipped++; continue }
        $targets.Add([PSCustomObject]@{ Name = [string]$r.Name; Target = $target })
    }
    $unique = @($targets.ToArray() | Sort-Object Target -Unique)
    return [PSCustomObject]@{ Targets = $unique; Skipped = $skipped }
}
#endregion

#region Remediation Functions (local machine only)
function Get-FolderSizeBytes {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return [double]0 }
    $sum = (Get-ChildItem $Path -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    if ($null -eq $sum) { return [double]0 }
    return [double]$sum
}

function Fix-CCMCache {
    Write-RemLog "Starting CCM cache remediation..."
    try {
        $before = Get-FolderSizeBytes $Script:Config.CCMCachePath
        $ui     = New-Object -ComObject UIResource.UIResourceMgr
        $cache  = $ui.GetCacheInfo()
        foreach ($el in @($cache.GetCacheElements())) {
            $cache.DeleteCacheElement($el.CacheElementID)
        }
        $after = Get-FolderSizeBytes $Script:Config.CCMCachePath
        $freed = [math]::Round(($before - $after) / 1GB, 2)
        Write-RemLog "CCM cache cleared. Freed: $freed GB" -Success
        return "SUCCESS: Cleared CCM cache, freed $freed GB"
    } catch {
        Write-RemLog "CCM cache remediation failed: $_" -Fail
        return "FAILED: $_"
    }
}

function Invoke-CCMSchedule {
    param([string]$ScheduleID)
    Invoke-CimMethod -Namespace "root\ccm" -ClassName "SMS_Client" -MethodName "TriggerSchedule" -Arguments @{ sScheduleID = $ScheduleID } -ErrorAction Stop | Out-Null
}

function Fix-PolicyAgent {
    Write-RemLog "Triggering full policy refresh..."
    try {
        $schedules = @(
            "{00000000-0000-0000-0000-000000000021}",  # Machine Policy Retrieval
            "{00000000-0000-0000-0000-000000000022}",  # Machine Policy Evaluation
            "{00000000-0000-0000-0000-000000000108}"   # Software Updates Assignments Evaluation
        )
        foreach ($s in $schedules) { Invoke-CCMSchedule -ScheduleID $s }
        Write-RemLog "Policy refresh triggered (3 schedules)" -Success
        return "SUCCESS: Policy refresh triggered"
    } catch {
        Write-RemLog "Policy refresh failed: $_" -Fail
        return "FAILED: $_"
    }
}

function Fix-WUAHandler {
    Write-RemLog "Resetting Windows Update Agent..."
    try {
        Stop-Service wuauserv -Force -ErrorAction SilentlyContinue
        Remove-Item "$env:SystemRoot\SoftwareDistribution\DataStore" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item "$env:SystemRoot\SoftwareDistribution\Download"  -Recurse -Force -ErrorAction SilentlyContinue
        Start-Service wuauserv -ErrorAction Stop
        Invoke-CCMSchedule -ScheduleID "{00000000-0000-0000-0000-000000000113}"  # Software Updates Scan
        Write-RemLog "WUA reset and scan triggered" -Success
        return "SUCCESS: WUA reset, SoftwareDistribution cleared, scan triggered"
    } catch {
        Write-RemLog "WUA remediation failed: $_" -Fail
        return "FAILED: $_"
    }
}

function Fix-BITSService {
    Write-RemLog "Repairing BITS service..."
    try {
        # Jobs must be enumerated/removed while the service is running
        $jobs = @(Get-BitsTransfer -AllUsers -ErrorAction SilentlyContinue)
        $jobCount = $jobs.Count
        if ($jobCount -gt 0) { $jobs | Remove-BitsTransfer -ErrorAction SilentlyContinue }
        Restart-Service BITS -Force -ErrorAction Stop
        $status = (Get-Service BITS).Status
        Write-RemLog "BITS restarted. Status: $status" -Success
        return "SUCCESS: BITS restarted, $jobCount stuck jobs cleared"
    } catch {
        Write-RemLog "BITS remediation failed: $_" -Fail
        return "FAILED: $_"
    }
}

function Fix-CCMService {
    Write-RemLog "Restarting CcmExec service..."
    try {
        Restart-Service CcmExec -Force -ErrorAction Stop
        Start-Sleep -Seconds 5
        $status = (Get-Service CcmExec).Status
        Write-RemLog "CcmExec restarted. Status: $status" -Success
        return "SUCCESS: CcmExec restarted. Status: $status"
    } catch {
        Write-RemLog "CcmExec restart failed: $_" -Fail
        return "FAILED: $_"
    }
}

function Fix-WMIRepository {
    Write-RemLog "Checking WMI repository..."
    try {
        $verify = (& winmgmt /verifyrepository 2>&1) | Out-String
        if ($verify -notmatch "inconsistent") {
            Write-RemLog "WMI repository is consistent - no repair needed" -Success
            return "SUCCESS: WMI repository is consistent, no action taken"
        }
        Write-RemLog "Repository inconsistent - attempting salvage..."
        & winmgmt /salvagerepository 2>&1 | Out-Null
        Start-Sleep -Seconds 3
        $verify2 = (& winmgmt /verifyrepository 2>&1) | Out-String
        if ($verify2 -match "inconsistent") {
            Write-RemLog "Salvage failed - resetting repository (last resort)..." -Fail
            & winmgmt /resetrepository 2>&1 | Out-Null
            return "WARNING: WMI repository reset. Reinstall/repair the ConfigMgr client afterward (ccmrepair)."
        }
        Write-RemLog "WMI repository salvaged" -Success
        return "SUCCESS: WMI repository salvaged"
    } catch {
        Write-RemLog "WMI repair failed: $_" -Fail
        return "FAILED: $_"
    }
}

function Fix-DiskSpace {
    Write-RemLog "Attempting disk space recovery..."
    try {
        Fix-CCMCache | Out-Null
        $freed = [double]0
        $tempPaths = @($env:TEMP, "$env:windir\Temp", "$env:windir\SoftwareDistribution\Download")
        foreach ($p in $tempPaths) {
            if (Test-Path $p) {
                $before = Get-FolderSizeBytes $p
                Get-ChildItem $p -File -Recurse -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-3) } |
                    Remove-Item -Force -ErrorAction SilentlyContinue
                $after = Get-FolderSizeBytes $p
                $freed += ($before - $after)
            }
        }
        $freedGB = [math]::Round($freed / 1GB, 2)
        Write-RemLog "Disk cleanup complete. Freed $freedGB GB (temp) plus CCM cache" -Success
        return "SUCCESS: Freed $freedGB GB from temp locations and cleared CCM cache"
    } catch {
        Write-RemLog "Disk cleanup failed: $_" -Fail
        return "FAILED: $_"
    }
}

function Fix-RebootPending {
    Write-RemLog "Checking pending reboot state..."
    $rebootKeys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
    )
    $found = @($rebootKeys | Where-Object { Test-Path $_ })
    if ($found.Count -gt 0) {
        # Safe: report only, never force a reboot
        Write-RemLog "Reboot pending detected at: $($found -join ', ')" -Fail
        return "INFO: Reboot pending - operator action required. Keys: $($found -join ', ')"
    }
    Write-RemLog "No pending reboot keys found" -Success
    return "SUCCESS: No reboot pending detected"
}

function Invoke-Remediation {
    param([string]$FunctionName)
    $Script:RemLog.Clear()
    switch ($FunctionName) {
        "Fix-CCMCache"      { return Fix-CCMCache }
        "Fix-PolicyAgent"   { return Fix-PolicyAgent }
        "Fix-WUAHandler"    { return Fix-WUAHandler }
        "Fix-BITSService"   { return Fix-BITSService }
        "Fix-CCMService"    { return Fix-CCMService }
        "Fix-WMIRepository" { return Fix-WMIRepository }
        "Fix-DiskSpace"     { return Fix-DiskSpace }
        "Fix-RebootPending" { return Fix-RebootPending }
        default             { return "ERROR: Unknown remediation function '$FunctionName'" }
    }
}

function Invoke-RemediationFromUI {
    param([string]$FunctionName)
    if ([string]::IsNullOrEmpty($FunctionName)) { return }
    $answer = [System.Windows.MessageBox]::Show(
        "Run $FunctionName on THIS machine ($env:COMPUTERNAME)?",
        "Confirm Remediation",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question)
    if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }

    $c = $Script:Controls
    $c["txtStatus"].Text = "Running $FunctionName ..."
    Update-UiNow
    $result = Invoke-Remediation -FunctionName $FunctionName
    $c["txtRemLog"].Text = ($Script:RemLog -join "`n") + "`n`nRESULT: $result"
    $c["svRemLog"].ScrollToBottom()
    $c["txtStatus"].Text = "Remediation complete: $FunctionName"
}
#endregion

#region Dashboard updates
function Update-Dashboard {
    param($Results)

    $c = $Script:Controls
    $c["txtLastScan"].Text    = "Last scan: $(Get-Date -Format 'HH:mm:ss')"
    $c["txtLogsScanned"].Text = [string]$Results.LogsScanned
    $c["txtDevices"].Text     = "$($Results.DevicesReached)/$($Results.DevicesTotal)"

    $detections = @($Results.Detections)
    $crit = @($detections | Where-Object { $_.Severity -eq "Critical" }).Count
    $high = @($detections | Where-Object { $_.Severity -eq "High" }).Count
    $med  = @($detections | Where-Object { $_.Severity -eq "Medium" }).Count

    $c["txtIssueCount"].Text = [string]$detections.Count
    $c["txtCritCount"].Text  = [string]$crit
    $c["txtHighMed"].Text    = "$high / $med"
    $c["txtHealth"].Text     = $Results.SystemHealth

    $healthColor = "#8B949E"
    if ($Results.SystemHealth -eq "Healthy")  { $healthColor = "#3FB950" }
    if ($Results.SystemHealth -eq "Warning")  { $healthColor = "#E3B341" }
    if ($Results.SystemHealth -eq "Degraded") { $healthColor = "#FF7B72" }
    if ($Results.SystemHealth -eq "Critical") { $healthColor = "#F85149" }
    $c["txtHealth"].Foreground = New-Brush $healthColor

    $order = @{ "Critical" = 0; "High" = 1; "Medium" = 2 }
    $sorted = $detections | Sort-Object @{ Expression = { if ($order.ContainsKey($_.Severity)) { $order[$_.Severity] } else { 3 } } }, @{ Expression = { $_.Count }; Descending = $true }

    $c["lvDetections"].Items.Clear()
    foreach ($d in $sorted) {
        $lastSeen = "-"
        if ($d.LastSeen) { $lastSeen = $d.LastSeen.ToString("MM-dd HH:mm:ss") }
        $autoFix = "No"
        if ($d.Remediation) { $autoFix = "YES" }
        $row = [PSCustomObject]@{
            Severity     = $d.Severity
            Name         = $d.Name
            Count        = $d.Count
            DevCount     = @($d.Devices).Count
            LastSeenStr  = $lastSeen
            Logs         = $d.Logs
            AutoFix      = $autoFix
            RemFunc      = $d.Remediation
            SampleMsg    = $d.SampleMsg
            SampleDevice = $d.SampleDevice
            DeviceList   = @($d.Devices)
        }
        $c["lvDetections"].Items.Add($row) | Out-Null
    }

    if ($Results.DevicesReached -eq 0) {
        $why = "No devices could be read."
        $first = @($Results.DevicesFailed) | Select-Object -First 1
        if ($first -and $first.Error) { $why = $first.Error }
        $c["txtStatus"].Text = "Scan finished but nothing was scanned. $why"
    } else {
        $c["txtStatus"].Text = "Scan complete at $(Get-Date -Format 'HH:mm:ss'). $($detections.Count) issue type(s) across $($Results.DevicesReached) device(s), $($Results.LogsScanned) log(s)."
    }
}

function Set-ModeUI {
    $c = $Script:Controls
    $isColl = ($Script:Mode -eq "Collection")
    $c["txtSiteServer"].IsEnabled   = $isColl
    $c["txtCollectionId"].IsEnabled = $isColl
    $c["btnBrowse"].IsEnabled       = $isColl
    foreach ($b in $c["pnlRemButtons"].Children) { $b.IsEnabled = (-not $isColl) }
    if ($isColl) {
        $c["btnDetailFix"].Visibility = [System.Windows.Visibility]::Collapsed
        $c["txtStatus"].Text = "Collection mode: scan only. Remediation buttons act on the local machine and are disabled here."
    } else {
        $c["txtStatus"].Text = "Local mode: scanning this machine."
    }
}

function Reset-ScanButton {
    $c = $Script:Controls
    $c["btnScan"].Content = "SCAN NOW"
    $c["btnScan"].IsEnabled = $true
    $c["pbScan"].Visibility = [System.Windows.Visibility]::Collapsed
}
#endregion

#region Collection picker
function Update-PickerList {
    $pc = $Script:PickerControls
    $f  = $pc["txtFilter"].Text.Trim()
    $pc["lvCollections"].Items.Clear()
    $shown = 0
    foreach ($col in @($Script:CollectionCache)) {
        $match = ($f -eq "")
        if (-not $match) {
            if ($col.Name.IndexOf($f, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $match = $true }
            elseif ($col.CollectionID.IndexOf($f, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $match = $true }
        }
        if ($match) {
            $pc["lvCollections"].Items.Add($col) | Out-Null
            $shown++
        }
    }
    $pc["txtCount"].Text = "$shown of $(@($Script:CollectionCache).Count) collections"
}

function Select-PickerItem {
    $sel = $Script:PickerControls["lvCollections"].SelectedItem
    if ($null -eq $sel) { return }
    $Script:PickedId = [string]$sel.CollectionID
    $Script:PickerWindow.Close()
}

function Show-CollectionPicker {
    param([string]$Server)
    $c = $Script:Controls

    if (-not (Test-ServerName $Server)) {
        Show-ScanError "Enter the site server (SMS Provider) name first, then click Browse."
        return $null
    }

    if (($null -eq $Script:CollectionCache) -or ($Script:CollectionCacheServer -ne $Server)) {
        $c["txtStatus"].Text = "Loading device collections from $Server ..."
        Update-UiNow
        try {
            $site = Get-SiteCodeForServer -Server $Server
            $rows = Invoke-SiteQuery -Server $Server -Namespace "root\sms\site_$site" -Query "SELECT CollectionID, Name, MemberCount FROM SMS_Collection WHERE CollectionType = 2"
            $list = foreach ($r in $rows) {
                [PSCustomObject]@{ CollectionID = [string]$r.CollectionID; Name = [string]$r.Name; MemberCount = [int]$r.MemberCount }
            }
            $Script:CollectionCache = @($list | Sort-Object Name)
            $Script:CollectionCacheServer = $Server
            $c["txtStatus"].Text = "Loaded $(@($Script:CollectionCache).Count) device collections from site $site."
        } catch {
            Show-ScanError "Could not load collections from ${Server}: $_"
            return $null
        }
    }

    [xml]$pxaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="Select Device Collection" Width="680" Height="520"
    WindowStartupLocation="CenterOwner" ShowInTaskbar="False"
    Background="#0D1117" FontFamily="Consolas">
  <Grid Margin="16">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>
    <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,10">
      <TextBlock Text="FILTER" Foreground="#58A6FF" FontSize="11" FontWeight="Bold"
                 VerticalAlignment="Center" Margin="0,0,8,0"/>
      <TextBox x:Name="txtFilter" Width="320" Padding="4" Background="#161B22" Foreground="#E6EDF3"
               BorderBrush="#30363D" CaretBrush="#E6EDF3"/>
      <TextBlock x:Name="txtCount" Foreground="#8B949E" FontSize="11"
                 VerticalAlignment="Center" Margin="12,0,0,0"/>
    </StackPanel>
    <ListView x:Name="lvCollections" Grid.Row="1" Background="Transparent" BorderBrush="#21262D"
              Foreground="#E6EDF3" FontSize="11" SelectionMode="Single">
      <ListView.View>
        <GridView>
          <GridViewColumn Header="ID"      Width="90"  DisplayMemberBinding="{Binding CollectionID}"/>
          <GridViewColumn Header="NAME"    Width="380" DisplayMemberBinding="{Binding Name}"/>
          <GridViewColumn Header="MEMBERS" Width="80"  DisplayMemberBinding="{Binding MemberCount}"/>
        </GridView>
      </ListView.View>
    </ListView>
    <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0">
      <Button x:Name="btnOk" Content="SELECT" Padding="18,6" Margin="0,0,8,0"
              Background="#1F6FEB" Foreground="#FFFFFF" BorderBrush="#388BFD" FontWeight="Bold"/>
      <Button x:Name="btnCancel" Content="CANCEL" Padding="18,6"
              Background="#1C2128" Foreground="#79C0FF" BorderBrush="#30363D"/>
    </StackPanel>
  </Grid>
</Window>
'@

    $preader = New-Object System.Xml.XmlNodeReader $pxaml
    $Script:PickerWindow = [Windows.Markup.XamlReader]::Load($preader)
    $Script:PickerWindow.Owner = $Script:Window
    $Script:PickerControls = @{}
    foreach ($n in @("txtFilter","txtCount","lvCollections","btnOk","btnCancel")) {
        $Script:PickerControls[$n] = $Script:PickerWindow.FindName($n)
    }
    $pc = $Script:PickerControls

    $pc["txtFilter"].Add_TextChanged({ Update-PickerList })
    $pc["lvCollections"].Add_MouseDoubleClick({ Select-PickerItem })
    $pc["btnOk"].Add_Click({ Select-PickerItem })
    $pc["btnCancel"].Add_Click({ $Script:PickedId = $null; $Script:PickerWindow.Close() })
    $Script:PickerWindow.Add_Loaded({ $Script:PickerControls["txtFilter"].Focus() | Out-Null })

    $Script:PickedId = $null
    Update-PickerList
    [void]$Script:PickerWindow.ShowDialog()
    return $Script:PickedId
}
#endregion

#region Fleet (collection) scan
function Start-FleetScan {
    param([switch]$Silent)
    $c = $Script:Controls
    if ($Script:Fleet) { return }

    $server = $c["txtSiteServer"].Text.Trim()
    $collId = $c["txtCollectionId"].Text.Trim().ToUpper()

    if (-not (Test-ServerName $server)) {
        Show-ScanError "Enter a valid site server (SMS Provider) name." ([bool]$Silent)
        return
    }
    if ($collId -notmatch '^[A-Z0-9]{8}$') {
        Show-ScanError "Enter an 8-character collection ID (for example SMS00001), or use Browse." ([bool]$Silent)
        return
    }

    $c["txtStatus"].Text = "Querying collection $collId on $server ..."
    $c["btnScan"].IsEnabled = $false
    Update-UiNow

    $members = $null
    $colName = ""
    try {
        $site = Get-SiteCodeForServer -Server $server
        $col  = @(Invoke-SiteQuery -Server $server -Namespace "root\sms\site_$site" -Query "SELECT CollectionID, Name, CollectionType, MemberCount FROM SMS_Collection WHERE CollectionID = '$collId'")
        if ($col.Count -eq 0) { throw "Collection $collId was not found on site $site." }
        if ($col[0].CollectionType -ne 2) { throw "Collection $collId ($($col[0].Name)) is not a device collection." }
        $colName = [string]$col[0].Name
        $members = Get-CollectionMembers -Server $server -SiteCode $site -CollectionID $collId
    } catch {
        $c["btnScan"].IsEnabled = $true
        Show-ScanError "Could not read the collection: $_" ([bool]$Silent)
        return
    }
    $c["btnScan"].IsEnabled = $true

    $targets = @($members.Targets)
    if ($targets.Count -eq 0) {
        Show-ScanError "Collection $collId ($colName) has no scannable client devices." ([bool]$Silent)
        return
    }

    $pool = [runspacefactory]::CreateRunspacePool(1, $Script:Config.ThrottleLimit)
    $pool.Open()
    $pending = New-Object System.Collections.ArrayList
    $blockText = $Script:DeviceScanBlock.ToString()

    foreach ($t in $targets) {
        $path = "\\$($t.Target)\$($Script:Config.RemoteLogShare)"
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($blockText)
        [void]$ps.AddArgument($t.Target)
        [void]$ps.AddArgument($path)
        [void]$ps.AddArgument($Script:LogSources)
        [void]$ps.AddArgument($Script:FailurePatterns)
        [void]$ps.AddArgument($Script:Config.LogWindowHours)
        $handle = $ps.BeginInvoke()
        [void]$pending.Add([PSCustomObject]@{ PS = $ps; Handle = $handle; Computer = $t.Target })
    }

    $Script:Fleet = @{
        Pool           = $pool
        Pending        = $pending
        Results        = (New-Object System.Collections.ArrayList)
        Total          = $targets.Count
        Skipped        = $members.Skipped
        CollectionID   = $collId
        CollectionName = $colName
    }

    $c["pbScan"].Maximum = $targets.Count
    $c["pbScan"].Value = 0
    $c["pbScan"].Visibility = [System.Windows.Visibility]::Visible
    $c["btnScan"].Content = "CANCEL SCAN"
    $c["txtStatus"].Text = "Fleet scan of $collId ($colName): 0/$($targets.Count) devices..."
    $Script:FleetTimer.Start()
}

function Update-FleetProgress {
    $f = $Script:Fleet
    if ($null -eq $f) { $Script:FleetTimer.Stop(); return }
    $c = $Script:Controls

    foreach ($j in @($f.Pending.ToArray())) {
        if ($j.Handle.IsCompleted) {
            $r = $null
            try {
                $out = @($j.PS.EndInvoke($j.Handle))
                if ($out.Count -gt 0) { $r = $out[$out.Count - 1] }
            } catch {
                $r = $null
            }
            if ($null -eq $r) {
                $r = [PSCustomObject]@{ Computer = $j.Computer; Reachable = $false; LogsScanned = 0; Entries = 0; Detections = @(); Error = "Scan returned no result" }
            }
            try { $j.PS.Dispose() } catch {}
            $f.Pending.Remove($j)
            [void]$f.Results.Add($r)
        }
    }

    $done = $f.Results.Count
    $bad  = @($f.Results.ToArray() | Where-Object { -not $_.Reachable }).Count
    $c["pbScan"].Value = $done
    $c["txtStatus"].Text = "Fleet scan of $($f.CollectionID): $done/$($f.Total) devices ($bad unreachable)..."

    if ($f.Pending.Count -eq 0) { Complete-FleetScan }
}

function Complete-FleetScan {
    $f = $Script:Fleet
    $c = $Script:Controls
    $Script:FleetTimer.Stop()
    try { $f.Pool.Close(); $f.Pool.Dispose() } catch {}
    $Script:Fleet = $null
    Reset-ScanButton

    $results = Merge-DeviceResults -DeviceResults @($f.Results.ToArray()) -Skipped $f.Skipped
    $Script:ScanResults = $results
    Update-Dashboard -Results $results

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("FLEET SCAN COMPLETE - $($f.CollectionID) ($($f.CollectionName))")
    $lines.Add("Devices read    : $($results.DevicesReached) of $($results.DevicesTotal)")
    $lines.Add("Skipped         : $($results.Skipped) (non-client, obsolete, or no name)")
    $failed = @($results.DevicesFailed)
    if ($failed.Count -gt 0) {
        $lines.Add("Unreachable     : $($failed.Count)")
        foreach ($d in ($failed | Select-Object -First 50)) {
            $lines.Add("  $($d.Computer) - $($d.Error)")
        }
        if ($failed.Count -gt 50) { $lines.Add("  ... and $($failed.Count - 50) more") }
    }
    $c["txtRemLog"].Text = ($lines -join "`n")
}

function Stop-FleetScan {
    $f = $Script:Fleet
    if ($null -eq $f) { return }
    $Script:FleetTimer.Stop()
    # Best effort: ask running scans to stop without blocking the UI on hung SMB calls
    foreach ($j in @($f.Pending.ToArray())) {
        try { [void]$j.PS.BeginStop($null, $null) } catch {}
    }
    $Script:Fleet = $null
    Reset-ScanButton
    $Script:Controls["txtStatus"].Text = "Fleet scan cancelled."
}

function Invoke-ScanFromUI {
    param([string]$Label = "Scanning", [switch]$Silent)
    $c = $Script:Controls
    if ($Script:Fleet) { return }

    if ($Script:Mode -eq "Collection") {
        Start-FleetScan -Silent:$Silent
        return
    }

    $c["txtStatus"].Text = "$Label $($Script:LogSources.Count) local logs..."
    $c["btnScan"].IsEnabled = $false
    Update-UiNow
    try {
        $results = Invoke-LogScan
        Update-Dashboard -Results $results
    } catch {
        $c["txtStatus"].Text = "Scan failed: $_"
    } finally {
        $c["btnScan"].IsEnabled = $true
    }
}
#endregion

#region Main window
function Start-SCCMDashboard {
    [xml]$xaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="SCCM Health Monitor v2.2"
    Width="1200" Height="860"
    MinWidth="980" MinHeight="640"
    WindowStartupLocation="CenterScreen"
    Background="#0D1117"
    FontFamily="Consolas">

  <Window.Resources>
    <Style x:Key="HeaderLabel" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#58A6FF"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Margin" Value="0,0,0,4"/>
    </Style>
    <Style x:Key="RemBtn" TargetType="Button">
      <Setter Property="Background" Value="#1C2128"/>
      <Setter Property="Foreground" Value="#79C0FF"/>
      <Setter Property="BorderBrush" Value="#30363D"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="10,6"/>
      <Setter Property="Margin" Value="0,0,6,6"/>
      <Setter Property="FontFamily" Value="Consolas"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Cursor" Value="Hand"/>
    </Style>
    <Style x:Key="ScanBtn" TargetType="Button">
      <Setter Property="Background" Value="#1F6FEB"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="BorderBrush" Value="#388BFD"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="20,8"/>
      <Setter Property="FontFamily" Value="Consolas"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Cursor" Value="Hand"/>
    </Style>
    <Style x:Key="InputBox" TargetType="TextBox">
      <Setter Property="Background" Value="#161B22"/>
      <Setter Property="Foreground" Value="#E6EDF3"/>
      <Setter Property="BorderBrush" Value="#30363D"/>
      <Setter Property="CaretBrush" Value="#E6EDF3"/>
      <Setter Property="FontFamily" Value="Consolas"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Padding" Value="4,3"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
  </Window.Resources>

  <Grid Margin="0">
    <Grid.RowDefinitions>
      <RowDefinition Height="56"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="160"/>
      <RowDefinition Height="36"/>
    </Grid.RowDefinitions>

    <!-- Title Bar -->
    <Border Grid.Row="0" Background="#161B22" BorderBrush="#30363D" BorderThickness="0,0,0,1">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="20,0">
          <Ellipse Width="10" Height="10" Fill="#3FB950" Margin="0,0,8,0"/>
          <TextBlock Text="SCCM HEALTH MONITOR" Foreground="#E6EDF3" FontSize="16"
                     FontWeight="Bold" VerticalAlignment="Center"/>
          <TextBlock Text=" v2.2" Foreground="#58A6FF" FontSize="12" VerticalAlignment="Center"
                     Margin="4,2,0,0"/>
          <TextBlock x:Name="txtHostname" Foreground="#8B949E" FontSize="11"
                     VerticalAlignment="Center" Margin="20,0,0,0"/>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,16,0">
          <TextBlock x:Name="txtLastScan" Foreground="#8B949E" FontSize="11"
                     VerticalAlignment="Center" Margin="0,0,16,0"/>
          <Button x:Name="btnScan" Content="SCAN NOW" Style="{StaticResource ScanBtn}"/>
          <Button x:Name="btnAutoScan" Content="AUTO: ON" Style="{StaticResource RemBtn}"
                  Margin="8,0,0,0"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- Target Bar -->
    <Border Grid.Row="1" Background="#0D1117" BorderBrush="#30363D" BorderThickness="0,0,0,1" Padding="20,8">
      <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
        <TextBlock Text="TARGET" Style="{StaticResource HeaderLabel}" VerticalAlignment="Center" Margin="0,0,12,0"/>
        <RadioButton x:Name="rbLocal" GroupName="target" Content="Local machine" IsChecked="True"
                     Foreground="#E6EDF3" FontSize="11" VerticalAlignment="Center" Margin="0,0,14,0"/>
        <RadioButton x:Name="rbCollection" GroupName="target" Content="SCCM device collection"
                     Foreground="#E6EDF3" FontSize="11" VerticalAlignment="Center" Margin="0,0,18,0"/>
        <TextBlock Text="Site server:" Foreground="#8B949E" FontSize="11" VerticalAlignment="Center" Margin="0,0,6,0"/>
        <TextBox x:Name="txtSiteServer" Style="{StaticResource InputBox}" Width="220"/>
        <TextBlock Text="Collection ID:" Foreground="#8B949E" FontSize="11" VerticalAlignment="Center" Margin="14,0,6,0"/>
        <TextBox x:Name="txtCollectionId" Style="{StaticResource InputBox}" Width="100" MaxLength="8" CharacterCasing="Upper"/>
        <Button x:Name="btnBrowse" Content="Browse..." Style="{StaticResource RemBtn}" Margin="8,0,0,0"/>
      </StackPanel>
    </Border>

    <!-- Stats Bar -->
    <Border Grid.Row="2" Background="#161B22" BorderBrush="#30363D" BorderThickness="0,0,0,1" Padding="20,12">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="2*"/>
        </Grid.ColumnDefinitions>

        <StackPanel Grid.Column="0">
          <TextBlock Text="SYSTEM HEALTH" Style="{StaticResource HeaderLabel}"/>
          <TextBlock x:Name="txtHealth" Text="-" FontSize="20" FontWeight="Bold" Foreground="#3FB950"/>
        </StackPanel>
        <StackPanel Grid.Column="1">
          <TextBlock Text="DEVICES" Style="{StaticResource HeaderLabel}"/>
          <TextBlock x:Name="txtDevices" Text="-" FontSize="20" FontWeight="Bold" Foreground="#E6EDF3"/>
        </StackPanel>
        <StackPanel Grid.Column="2">
          <TextBlock Text="LOGS SCANNED" Style="{StaticResource HeaderLabel}"/>
          <TextBlock x:Name="txtLogsScanned" Text="-" FontSize="20" FontWeight="Bold" Foreground="#E6EDF3"/>
        </StackPanel>
        <StackPanel Grid.Column="3">
          <TextBlock Text="ISSUE TYPES" Style="{StaticResource HeaderLabel}"/>
          <TextBlock x:Name="txtIssueCount" Text="-" FontSize="20" FontWeight="Bold" Foreground="#E6EDF3"/>
        </StackPanel>
        <StackPanel Grid.Column="4">
          <TextBlock Text="CRITICAL" Style="{StaticResource HeaderLabel}"/>
          <TextBlock x:Name="txtCritCount" Text="-" FontSize="20" FontWeight="Bold" Foreground="#F85149"/>
        </StackPanel>
        <StackPanel Grid.Column="5">
          <TextBlock Text="HIGH / MEDIUM" Style="{StaticResource HeaderLabel}"/>
          <TextBlock x:Name="txtHighMed" Text="-" FontSize="20" FontWeight="Bold" Foreground="#E3B341"/>
        </StackPanel>
        <StackPanel Grid.Column="6">
          <TextBlock Text="REMEDIATION ACTIONS (LOCAL)" Style="{StaticResource HeaderLabel}"/>
          <WrapPanel x:Name="pnlRemButtons"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- Main Content -->
    <Grid Grid.Row="3" Margin="0">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="2*"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <!-- Detection Table -->
      <Border Grid.Column="0" Background="#0D1117" BorderBrush="#21262D" BorderThickness="0,0,1,0">
        <Grid Margin="16,12">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <TextBlock Text="DETECTION LOG" Style="{StaticResource HeaderLabel}" FontSize="12"/>
          <ListView x:Name="lvDetections" Grid.Row="1"
                    Background="Transparent" BorderBrush="#21262D" BorderThickness="1"
                    Foreground="#E6EDF3" FontFamily="Consolas" FontSize="11">
            <ListView.View>
              <GridView>
                <GridViewColumn Header="SEV"       Width="70"  DisplayMemberBinding="{Binding Severity}"/>
                <GridViewColumn Header="PATTERN"   Width="190" DisplayMemberBinding="{Binding Name}"/>
                <GridViewColumn Header="HITS"      Width="50"  DisplayMemberBinding="{Binding Count}"/>
                <GridViewColumn Header="DEVICES"   Width="70"  DisplayMemberBinding="{Binding DevCount}"/>
                <GridViewColumn Header="LAST SEEN" Width="110" DisplayMemberBinding="{Binding LastSeenStr}"/>
                <GridViewColumn Header="LOGS"      Width="170" DisplayMemberBinding="{Binding Logs}"/>
                <GridViewColumn Header="AUTO-FIX"  Width="70"  DisplayMemberBinding="{Binding AutoFix}"/>
              </GridView>
            </ListView.View>
          </ListView>
        </Grid>
      </Border>

      <!-- Detail Panel -->
      <Border Grid.Column="1" Background="#0D1117">
        <Grid Margin="16,12">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>

          <TextBlock Text="ISSUE DETAIL" Style="{StaticResource HeaderLabel}" FontSize="12"/>

          <StackPanel Grid.Row="1" Margin="0,8,0,8">
            <TextBlock x:Name="txtDetailName" Text="Select a detection to view details."
                       Foreground="#79C0FF" FontSize="13" FontWeight="Bold" TextWrapping="Wrap"/>
            <TextBlock x:Name="txtDetailSev" Text="" Foreground="#8B949E" FontSize="11" Margin="0,4,0,0" TextWrapping="Wrap"/>
          </StackPanel>

          <Border Grid.Row="2" Background="#161B22" BorderBrush="#21262D" BorderThickness="1"
                  CornerRadius="4" Padding="10">
            <ScrollViewer VerticalScrollBarVisibility="Auto">
              <TextBlock x:Name="txtDetailSample" Text="Select a detection from the list..."
                         Foreground="#8B949E" FontSize="11" TextWrapping="Wrap"/>
            </ScrollViewer>
          </Border>

          <Button x:Name="btnDetailFix" Grid.Row="3" Content="AUTO-REMEDIATE THIS ISSUE (LOCAL)"
                  Style="{StaticResource ScanBtn}" Margin="0,8,0,0"
                  HorizontalAlignment="Stretch" Visibility="Collapsed"/>
        </Grid>
      </Border>
    </Grid>

    <!-- Output Log -->
    <Border Grid.Row="4" Background="#161B22" BorderBrush="#30363D" BorderThickness="0,1,0,0" Padding="16,8">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <TextBlock Text="OUTPUT" Style="{StaticResource HeaderLabel}" FontSize="12"/>
        <ScrollViewer Grid.Row="1" x:Name="svRemLog" VerticalScrollBarVisibility="Auto">
          <TextBlock x:Name="txtRemLog"
                     Text="Awaiting scan or remediation actions..."
                     Foreground="#3FB950" FontSize="11" TextWrapping="Wrap"/>
        </ScrollViewer>
      </Grid>
    </Border>

    <!-- Status Bar -->
    <Border Grid.Row="5" Background="#010409" BorderBrush="#21262D" BorderThickness="0,1,0,0" Padding="16,0">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock x:Name="txtStatus" Text="Ready. Click SCAN NOW to begin."
                   Foreground="#8B949E" FontSize="10" VerticalAlignment="Center"/>
        <ProgressBar x:Name="pbScan" Grid.Column="1" Width="220" Height="8" Margin="0,0,16,0"
                     Foreground="#3FB950" Background="#21262D" BorderThickness="0"
                     VerticalAlignment="Center" Visibility="Collapsed"/>
        <TextBlock Grid.Column="2" Text="SCCM Health Monitor | 28 Logs | 15 Patterns | 8 Remediations"
                   Foreground="#6E7681" FontSize="10" VerticalAlignment="Center"/>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $Script:Window = [Windows.Markup.XamlReader]::Load($reader)
    $window = $Script:Window

    $names = @("txtHostname","txtLastScan","txtHealth","txtDevices","txtLogsScanned","txtIssueCount",
               "txtCritCount","txtHighMed","txtStatus","txtDetailName","txtDetailSev",
               "txtDetailSample","txtRemLog","lvDetections","pnlRemButtons",
               "btnScan","btnAutoScan","btnDetailFix","svRemLog",
               "rbLocal","rbCollection","txtSiteServer","txtCollectionId","btnBrowse","pbScan")
    foreach ($n in $names) { $Script:Controls[$n] = $window.FindName($n) }
    $c = $Script:Controls

    $c["txtHostname"].Text = "  |  $env:COMPUTERNAME  ($env:USERDOMAIN\$env:USERNAME)"

    # Prefill the site server from the local client's current management point (editable guess)
    try {
        $auth = Get-CimInstance -Namespace "root\ccm" -ClassName "SMS_Authority" -ErrorAction Stop | Select-Object -First 1
        if ($auth -and $auth.CurrentManagementPoint) { $c["txtSiteServer"].Text = [string]$auth.CurrentManagementPoint }
    } catch {}

    # Always-visible remediation buttons (local machine only)
    $remediations = @(
        @{ Label = "Clear Cache";    Func = "Fix-CCMCache" }
        @{ Label = "Policy Refresh"; Func = "Fix-PolicyAgent" }
        @{ Label = "Reset WUA";      Func = "Fix-WUAHandler" }
        @{ Label = "Fix BITS";       Func = "Fix-BITSService" }
        @{ Label = "Restart CCM";    Func = "Fix-CCMService" }
        @{ Label = "Fix WMI";        Func = "Fix-WMIRepository" }
        @{ Label = "Free Disk";      Func = "Fix-DiskSpace" }
        @{ Label = "Reboot Check";   Func = "Fix-RebootPending" }
    )
    $remStyle = $window.FindResource("RemBtn")
    foreach ($rem in $remediations) {
        $btn = New-Object System.Windows.Controls.Button
        $btn.Content = $rem.Label
        $btn.Style   = $remStyle
        $btn.Tag     = $rem.Func
        $btn.Margin  = New-Object System.Windows.Thickness(0, 0, 6, 4)
        $btn.Padding = New-Object System.Windows.Thickness(8, 4, 8, 4)
        $btn.FontSize = 10
        $btn.Add_Click({
            param($sender, $e)
            Invoke-RemediationFromUI -FunctionName ([string]$sender.Tag)
        })
        $c["pnlRemButtons"].Children.Add($btn) | Out-Null
    }

    # Target mode switching
    $c["rbLocal"].Add_Checked({ $Script:Mode = "Local"; Set-ModeUI })
    $c["rbCollection"].Add_Checked({ $Script:Mode = "Collection"; Set-ModeUI })

    # Browse collections
    $c["btnBrowse"].Add_Click({
        $id = Show-CollectionPicker -Server $Script:Controls["txtSiteServer"].Text.Trim()
        if ($id) { $Script:Controls["txtCollectionId"].Text = $id }
    })

    # Detection selected
    $c["lvDetections"].Add_SelectionChanged({
        $cc  = $Script:Controls
        $sel = $cc["lvDetections"].SelectedItem
        if ($null -eq $sel) { return }
        $cc["txtDetailName"].Text = $sel.Name
        $cc["txtDetailSev"].Text  = "Severity: $($sel.Severity)  |  Hits: $($sel.Count)  |  Devices: $($sel.DevCount)  |  Logs: $($sel.Logs)"

        $text = "No sample message available."
        if ($sel.SampleMsg) { $text = [string]$sel.SampleMsg }
        $devs = @($sel.DeviceList)
        if (($Script:Mode -eq "Collection") -and ($devs.Count -gt 0)) {
            $text += "`n`nSample device: $($sel.SampleDevice)"
            $text += "`n`nAffected devices ($($devs.Count)):`n" + (($devs | Select-Object -First 300) -join "`n")
            if ($devs.Count -gt 300) { $text += "`n... and $($devs.Count - 300) more" }
        }
        $cc["txtDetailSample"].Text = $text

        if ($sel.RemFunc -and ($Script:Mode -eq "Local")) {
            $cc["btnDetailFix"].Visibility = [System.Windows.Visibility]::Visible
            $cc["btnDetailFix"].Tag = $sel.RemFunc
        } else {
            $cc["btnDetailFix"].Visibility = [System.Windows.Visibility]::Collapsed
            $cc["btnDetailFix"].Tag = $null
        }
    })

    # Detail fix button
    $c["btnDetailFix"].Add_Click({
        Invoke-RemediationFromUI -FunctionName ([string]$Script:Controls["btnDetailFix"].Tag)
    })

    # Scan / cancel button
    $c["btnScan"].Add_Click({
        if ($Script:Fleet) { Stop-FleetScan }
        else { Invoke-ScanFromUI -Label "Scanning" }
    })

    # Fleet progress poller
    $Script:FleetTimer = New-Object System.Windows.Threading.DispatcherTimer
    $Script:FleetTimer.Interval = [TimeSpan]::FromMilliseconds(500)
    $Script:FleetTimer.Add_Tick({ Update-FleetProgress })

    # Auto-scan timer (re-scans whichever target is selected)
    $Script:AutoTimer = New-Object System.Windows.Threading.DispatcherTimer
    $Script:AutoTimer.Interval = [TimeSpan]::FromMinutes($Script:Config.RefreshIntervalMinutes)
    $Script:AutoTimer.Add_Tick({
        if ($Script:AutoScanEnabled -and (-not $Script:Fleet)) {
            Invoke-ScanFromUI -Label "Auto-scan running:" -Silent
        }
    })
    $Script:AutoTimer.Start()

    $c["btnAutoScan"].Foreground = New-Brush "#3FB950"
    $c["btnAutoScan"].Add_Click({
        $Script:AutoScanEnabled = -not $Script:AutoScanEnabled
        $cc = $Script:Controls
        if ($Script:AutoScanEnabled) {
            $cc["btnAutoScan"].Content = "AUTO: ON"
            $cc["btnAutoScan"].Foreground = New-Brush "#3FB950"
        } else {
            $cc["btnAutoScan"].Content = "AUTO: OFF"
            $cc["btnAutoScan"].Foreground = New-Brush "#F85149"
        }
    })

    # Initial state and first (local) scan after the window is drawn
    Set-ModeUI
    $window.Add_ContentRendered({
        if ($null -eq $Script:ScanResults) { Invoke-ScanFromUI -Label "Initial scan of" }
    })

    $window.Add_Closed({
        $Script:AutoTimer.Stop()
        $Script:FleetTimer.Stop()
        if ($Script:Fleet) { Stop-FleetScan }
    })

    $window.ShowDialog() | Out-Null
}
#endregion

#region Entry Point
Write-Host ""
Write-Host "  ==============================================" -ForegroundColor Cyan
Write-Host "    SCCM Health Monitor v$($Script:Config.Version)" -ForegroundColor Cyan
Write-Host "    28 Logs | 15 Patterns | 8 Remediations" -ForegroundColor Cyan
Write-Host "  ==============================================" -ForegroundColor Cyan
Write-Host ""

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")
if (-not $isAdmin) {
    Write-Warning "Not running as Administrator. Remediations and remote (ADMIN`$) log reads may fail."
}

if (-not (Test-Path $Script:Config.CCMLogPath)) {
    Write-Warning "CCM log path not found: $($Script:Config.CCMLogPath)"
    Write-Warning "Local mode needs the ConfigMgr client. Collection mode still works from any machine."
}

Write-Host "Launching dashboard..." -ForegroundColor Green
Start-SCCMDashboard
#endregion
```