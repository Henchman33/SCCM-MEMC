
```
#Requires -Version 5.1
<#
.SYNOPSIS
    SCCM Health Monitor - Intelligent Fleet Monitoring & Auto-Remediation Tool
.DESCRIPTION
    Parses 28 SCCM client logs every 30 minutes, identifies root causes via a 15-pattern
    library, provides 8 built-in remediation functions, and displays a dark-themed WPF dashboard.
.NOTES
    Version  : 2.1
    Requires : Windows PowerShell 5.1 (ISE compatible), no extra modules
    Run As   : Local Administrator recommended for full remediation capability
    Run      : powershell.exe -ExecutionPolicy Bypass -File .\SCCM-HealthMonitor.ps1
#>

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

#region Configuration
$Script:Config = @{
    RefreshIntervalMinutes = 30
    CCMLogPath             = "$env:windir\CCM\Logs"
    CCMCachePath           = "$env:windir\ccmcache"
    Version                = "2.1"
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
$Script:Controls = @{}
$Script:Window = $null
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
#endregion

#region Log Parsing Engine
function Get-SCCMLogEntries {
    param([string]$LogName, [int]$MaxAgeHours = 24)

    $entries = New-Object System.Collections.Generic.List[object]
    $logFile = Join-Path $Script:Config.CCMLogPath "$LogName.log"
    if (-not (Test-Path $logFile)) { return @() }

    $cutoff  = (Get-Date).AddHours(-$MaxAgeHours)
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $pattern = '<!\[LOG\[(?<msg>.*?)\]LOG\]!><time="(?<t>\d{2}:\d{2}:\d{2})[^"]*"\s+date="(?<d>\d{1,2}-\d{1,2}-\d{4})"'

    $fs = $null
    $sr = $null
    try {
        # Open with shared read/write so actively-written CCM logs are not blocked
        $fs = New-Object System.IO.FileStream($logFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sr = New-Object System.IO.StreamReader($fs)
        while (-not $sr.EndOfStream) {
            $line = $sr.ReadLine()
            if ($line -match $pattern) {
                $msg = $Matches['msg']
                $stamp = "$($Matches['d']) $($Matches['t'])"
                $ts = [datetime]::MinValue
                if ([datetime]::TryParseExact($stamp, "M-d-yyyy HH:mm:ss", $culture, [System.Globalization.DateTimeStyles]::None, [ref]$ts)) {
                    if ($ts -ge $cutoff) {
                        $entries.Add([PSCustomObject]@{
                            Timestamp = $ts
                            LogName   = $LogName
                            Message   = $msg.Trim()
                        })
                    }
                }
            }
        }
    } catch {
        # Skip logs that cannot be read
    } finally {
        if ($sr) { $sr.Dispose() }
        if ($fs) { $fs.Dispose() }
    }
    return $entries.ToArray()
}

function Invoke-LogScan {
    $results = [PSCustomObject]@{
        Timestamp    = Get-Date
        Detections   = @()
        LogsScanned  = 0
        TotalEntries = 0
        SystemHealth = "Unknown"
    }

    $allEntries = New-Object System.Collections.Generic.List[object]
    foreach ($log in $Script:LogSources) {
        $found = @(Get-SCCMLogEntries -LogName $log -MaxAgeHours ([int]($Script:Config.RefreshIntervalMinutes * 2 / 60) + 1))
        if ($found.Count -gt 0) {
            $results.LogsScanned++
            $allEntries.AddRange($found)
        }
    }
    $results.TotalEntries = $allEntries.Count

    $detections = New-Object System.Collections.Generic.List[object]
    foreach ($p in $Script:FailurePatterns) {
        $rx = $p.Regex
        $hits = @($allEntries | Where-Object { $_.Message -match $rx })
        if ($hits.Count -gt 0) {
            $latest = $hits | Sort-Object Timestamp -Descending | Select-Object -First 1
            $detections.Add([PSCustomObject]@{
                PatternID   = $p.ID
                Name        = $p.Name
                Severity    = $p.Severity
                Remediation = $p.Remediation
                Count       = $hits.Count
                LastSeen    = $latest.Timestamp
                Logs        = (($hits | Select-Object -ExpandProperty LogName -Unique) -join ", ")
                SampleMsg   = $latest.Message
            })
        }
    }
    $results.Detections = $detections.ToArray()

    $critCount = @($results.Detections | Where-Object { $_.Severity -eq "Critical" }).Count
    $highCount = @($results.Detections | Where-Object { $_.Severity -eq "High" }).Count
    if ($critCount -gt 0) { $results.SystemHealth = "Critical" }
    elseif ($highCount -gt 0) { $results.SystemHealth = "Degraded" }
    elseif ($results.Detections.Count -gt 0) { $results.SystemHealth = "Warning" }
    else { $results.SystemHealth = "Healthy" }

    $Script:ScanResults = $results
    return $results
}
#endregion

#region Remediation Functions
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
        "Run $FunctionName on $env:COMPUTERNAME ?",
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

#region Dashboard
function Update-Dashboard {
    param($Results)

    $c = $Script:Controls
    $c["txtLastScan"].Text   = "Last scan: $(Get-Date -Format 'HH:mm:ss')"
    $c["txtLogsScanned"].Text = [string]$Results.LogsScanned

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
            Severity    = $d.Severity
            Name        = $d.Name
            Count       = $d.Count
            LastSeenStr = $lastSeen
            Logs        = $d.Logs
            AutoFix     = $autoFix
            RemFunc     = $d.Remediation
            SampleMsg   = $d.SampleMsg
        }
        $c["lvDetections"].Items.Add($row) | Out-Null
    }

    $c["txtStatus"].Text = "Scan complete at $(Get-Date -Format 'HH:mm:ss'). $($detections.Count) issue(s) found across $($Results.LogsScanned) log(s)."
}

function Start-ScanFromUI {
    param([string]$Label = "Scanning")
    $c = $Script:Controls
    $c["txtStatus"].Text = "$Label $($Script:LogSources.Count) logs..."
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

function Start-SCCMDashboard {
    [xml]$xaml = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="SCCM Health Monitor v2.1"
    Width="1200" Height="820"
    MinWidth="900" MinHeight="600"
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
  </Window.Resources>

  <Grid Margin="0">
    <Grid.RowDefinitions>
      <RowDefinition Height="56"/>
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
          <TextBlock Text=" v2.1" Foreground="#58A6FF" FontSize="12" VerticalAlignment="Center"
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

    <!-- Stats Bar -->
    <Border Grid.Row="1" Background="#161B22" BorderBrush="#30363D" BorderThickness="0,0,0,1" Padding="20,12">
      <Grid>
        <Grid.ColumnDefinitions>
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
          <TextBlock Text="LOGS SCANNED" Style="{StaticResource HeaderLabel}"/>
          <TextBlock x:Name="txtLogsScanned" Text="-" FontSize="20" FontWeight="Bold" Foreground="#E6EDF3"/>
        </StackPanel>
        <StackPanel Grid.Column="2">
          <TextBlock Text="ISSUES FOUND" Style="{StaticResource HeaderLabel}"/>
          <TextBlock x:Name="txtIssueCount" Text="-" FontSize="20" FontWeight="Bold" Foreground="#E6EDF3"/>
        </StackPanel>
        <StackPanel Grid.Column="3">
          <TextBlock Text="CRITICAL" Style="{StaticResource HeaderLabel}"/>
          <TextBlock x:Name="txtCritCount" Text="-" FontSize="20" FontWeight="Bold" Foreground="#F85149"/>
        </StackPanel>
        <StackPanel Grid.Column="4">
          <TextBlock Text="HIGH / MEDIUM" Style="{StaticResource HeaderLabel}"/>
          <TextBlock x:Name="txtHighMed" Text="-" FontSize="20" FontWeight="Bold" Foreground="#E3B341"/>
        </StackPanel>
        <StackPanel Grid.Column="5">
          <TextBlock Text="REMEDIATION ACTIONS" Style="{StaticResource HeaderLabel}"/>
          <WrapPanel x:Name="pnlRemButtons"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- Main Content -->
    <Grid Grid.Row="2" Margin="0">
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
                <GridViewColumn Header="PATTERN"   Width="200" DisplayMemberBinding="{Binding Name}"/>
                <GridViewColumn Header="HITS"      Width="50"  DisplayMemberBinding="{Binding Count}"/>
                <GridViewColumn Header="LAST SEEN" Width="120" DisplayMemberBinding="{Binding LastSeenStr}"/>
                <GridViewColumn Header="LOGS"      Width="200" DisplayMemberBinding="{Binding Logs}"/>
                <GridViewColumn Header="AUTO-FIX"  Width="80"  DisplayMemberBinding="{Binding AutoFix}"/>
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

          <Button x:Name="btnDetailFix" Grid.Row="3" Content="AUTO-REMEDIATE THIS ISSUE"
                  Style="{StaticResource ScanBtn}" Margin="0,8,0,0"
                  HorizontalAlignment="Stretch" Visibility="Collapsed"/>
        </Grid>
      </Border>
    </Grid>

    <!-- Remediation Log -->
    <Border Grid.Row="3" Background="#161B22" BorderBrush="#30363D" BorderThickness="0,1,0,0" Padding="16,8">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <TextBlock Text="REMEDIATION OUTPUT" Style="{StaticResource HeaderLabel}" FontSize="12"/>
        <ScrollViewer Grid.Row="1" x:Name="svRemLog" VerticalScrollBarVisibility="Auto">
          <TextBlock x:Name="txtRemLog"
                     Text="Awaiting remediation actions..."
                     Foreground="#3FB950" FontSize="11" TextWrapping="Wrap"/>
        </ScrollViewer>
      </Grid>
    </Border>

    <!-- Status Bar -->
    <Border Grid.Row="4" Background="#010409" BorderBrush="#21262D" BorderThickness="0,1,0,0" Padding="16,0">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock x:Name="txtStatus" Text="Ready. Click SCAN NOW to begin."
                   Foreground="#8B949E" FontSize="10" VerticalAlignment="Center"/>
        <TextBlock Grid.Column="1" Text="SCCM Health Monitor | 28 Logs | 15 Patterns | 8 Remediations"
                   Foreground="#6E7681" FontSize="10" VerticalAlignment="Center"/>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

    $reader = New-Object System.Xml.XmlNodeReader $xaml
    $Script:Window = [Windows.Markup.XamlReader]::Load($reader)
    $window = $Script:Window

    $names = @("txtHostname","txtLastScan","txtHealth","txtLogsScanned","txtIssueCount",
               "txtCritCount","txtHighMed","txtStatus","txtDetailName","txtDetailSev",
               "txtDetailSample","txtRemLog","lvDetections","pnlRemButtons",
               "btnScan","btnAutoScan","btnDetailFix","svRemLog")
    foreach ($n in $names) { $Script:Controls[$n] = $window.FindName($n) }
    $c = $Script:Controls

    $c["txtHostname"].Text = "  |  $env:COMPUTERNAME  ($env:USERDOMAIN\$env:USERNAME)"

    # Build the always-visible remediation buttons
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

    # Detection selected
    $c["lvDetections"].Add_SelectionChanged({
        $cc  = $Script:Controls
        $sel = $cc["lvDetections"].SelectedItem
        if ($null -eq $sel) { return }
        $cc["txtDetailName"].Text = $sel.Name
        $cc["txtDetailSev"].Text  = "Severity: $($sel.Severity)  |  Hits: $($sel.Count)  |  Logs: $($sel.Logs)"
        if ($sel.SampleMsg) { $cc["txtDetailSample"].Text = $sel.SampleMsg }
        else { $cc["txtDetailSample"].Text = "No sample message available." }
        if ($sel.RemFunc) {
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

    # Manual scan
    $c["btnScan"].Add_Click({
        Start-ScanFromUI -Label "Scanning"
    })

    # Auto-scan timer
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMinutes($Script:Config.RefreshIntervalMinutes)
    $timer.Add_Tick({
        if ($Script:AutoScanEnabled) { Start-ScanFromUI -Label "Auto-scan running:" }
    })
    $timer.Start()

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

    # Initial scan after the window is first drawn
    $window.Add_ContentRendered({
        if ($null -eq $Script:ScanResults) { Start-ScanFromUI -Label "Initial scan of" }
    })

    $window.Add_Closed({ $timer.Stop() }.GetNewClosure())

    $window.ShowDialog() | Out-Null
    $timer.Stop()
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
    Write-Warning "Not running as Administrator. Some remediations may fail. Re-launch as Admin for full functionality."
}

if (-not (Test-Path $Script:Config.CCMLogPath)) {
    Write-Warning "CCM log path not found: $($Script:Config.CCMLogPath)"
    Write-Warning "This tool is designed to run ON a machine with the ConfigMgr client installed."
    Write-Warning "Launching anyway - detections will be empty on non-client machines."
}

Write-Host "Launching dashboard..." -ForegroundColor Green
Start-SCCMDashboard
#endregion
```
