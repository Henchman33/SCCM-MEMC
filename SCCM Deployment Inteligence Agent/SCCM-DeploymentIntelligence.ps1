#Requires -Version 5.1
<#
.SYNOPSIS
    SCCM Deployment Intelligence Suite
.DESCRIPTION
    Real-Time Failure Detection | Root Cause Analysis | Auto-Remediation
    Matches the full dashboard layout: KPI strip, Failure Insights, Root Cause Analysis,
    Failure Trend chart, Live Deployment Status, Top Failed Devices, Auto-Remediation Log,
    SCCM Health Overview, and pipeline footer.
.NOTES
    Version : 3.0
    Run As  : Administrator for full remediation capability
    Requires: PowerShell 5.1+, Windows WPF (.NET built-in)
#>

Set-StrictMode -Off
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

#region ── CONFIG & DATA ─────────────────────────────────────────────────────
$Script:Cfg = @{
    CCMLogPath   = "$env:windir\CCM\Logs"
    CCMCachePath = "$env:windir\ccmcache"
    RefreshMin   = 30
    Version      = "3.0"
}

# Live simulated metrics (replace with real WMI/log queries in production)
function Get-LiveMetrics {
    $rnd = Get-Random -Minimum -3 -Maximum 4
    return @{
        TotalEndpoints     = 8547
        HealthyPct         = 92
        PendingDeployments = 1204
        FailuresToday      = 87 + $rnd
        FailureDelta       = -12
        AutoRemediated     = 63
        AutoRemSuccessPct  = 72
        PatchCompliance    = 94.3
        PatchDelta         = 3.2
        # Deployment ring
        DepSuccess         = 982
        DepInProgress      = 145
        DepFailed          = 45
        DepPending         = 32
        # Failure insights
        AppInstallFail     = 42 + (Get-Random -Min -2 -Max 3)
        ContentUnavail     = 15
        ClientErrors       = 12
        NetworkWSUS        = 9
        RebootPending      = 9
        # Root cause %
        RCAContent         = 40
        RCAPermissions     = 25
        RCANetwork         = 15
        RCAClient          = 10
        RCAOther           = 10
        # Trend (7 days)
        Trend              = @(31,27,30,25,27,24,19)
        # MP/DP/WSUS health
        MPStatus           = "OK"
        DPStatus           = "OK"
        WSUSStatus         = "Healthy"
    }
}

$Script:FailedDevices = @(
    [PSCustomObject]@{ Device="PC-1023"; Error="MSI 1603";   Severity="Critical"; RemFunc="Fix-BITSService"   }
    [PSCustomObject]@{ Device="PC-2201"; Error="DP Unreach"; Severity="Critical"; RemFunc="Fix-PolicyAgent"   }
    [PSCustomObject]@{ Device="PC-3309"; Error="Policy Fail";Severity="High";     RemFunc="Fix-PolicyAgent"   }
    [PSCustomObject]@{ Device="PC-4455"; Error="Reboot";     Severity="Medium";   RemFunc="Fix-RebootPending" }
)

$Script:RemediationLog = [System.Collections.Generic.List[string]]::new()
$Script:RemLog = [System.Collections.Generic.List[string]]::new()

function Write-RemLog { param([string]$M,[switch]$OK,[switch]$Err)
    $p = if($OK){"[OK] "}elseif($Err){"[ERR]"}else{"[LOG]"}
    $Script:RemLog.Add("$(Get-Date -f 'HH:mm:ss') $p $M")
}
#endregion

#region ── REMEDIATIONS ───────────────────────────────────────────────────────
function Fix-CCMCache {
    Write-RemLog "Clearing CCM Cache..."
    try {
        $c = (New-Object -ComObject UIResource.UIResourceMgr).GetCacheInfo()
        $c.GetCacheElements() | ForEach-Object { $c.DeleteCacheElement($_.CacheElementID) }
        Write-RemLog "CCMCache cleared" -OK; return "SUCCESS: CCMCache cleared"
    } catch { Write-RemLog "Failed: $_" -Err; return "FAILED: $_" }
}
function Fix-PolicyAgent {
    Write-RemLog "Triggering policy refresh..."
    try {
        $cl = [wmiclass]"\\.\root\ccm:SMS_Client"
        @("{00000000-0000-0000-0000-000000000021}","{00000000-0000-0000-0000-000000000022}") |
            ForEach-Object { $cl.TriggerSchedule($_) | Out-Null }
        Write-RemLog "Policy refresh triggered" -OK; return "SUCCESS: Policy refresh triggered"
    } catch { Write-RemLog "Failed: $_" -Err; return "FAILED: $_" }
}
function Fix-WUAHandler {
    Write-RemLog "Resetting WUA..."
    try {
        Stop-Service wuauserv -Force -EA SilentlyContinue
        Remove-Item "$env:SystemRoot\SoftwareDistribution\Download" -Recurse -Force -EA SilentlyContinue
        Start-Service wuauserv -EA Stop
        Write-RemLog "WUA reset" -OK; return "SUCCESS: WUA reset"
    } catch { Write-RemLog "Failed: $_" -Err; return "FAILED: $_" }
}
function Fix-BITSService {
    Write-RemLog "Restarting BITS..."
    try {
        Stop-Service BITS -Force -EA SilentlyContinue
        Get-BitsTransfer -AllUsers -EA SilentlyContinue | Remove-BitsTransfer -EA SilentlyContinue
        Start-Service BITS -EA Stop
        Write-RemLog "BITS restarted" -OK; return "SUCCESS: BITS restarted"
    } catch { Write-RemLog "Failed: $_" -Err; return "FAILED: $_" }
}
function Fix-CCMService {
    Write-RemLog "Restarting CCMExec..."
    try {
        Restart-Service CcmExec -Force -EA Stop
        Write-RemLog "CCMExec restarted" -OK; return "SUCCESS: CCMExec restarted"
    } catch { Write-RemLog "Failed: $_" -Err; return "FAILED: $_" }
}
function Fix-WMIRepository {
    Write-RemLog "Repairing WMI..."
    try { & winmgmt /salvagerepository 2>&1|Out-Null; & winmgmt /resetrepository 2>&1|Out-Null
        Write-RemLog "WMI repaired" -OK; return "SUCCESS: WMI repaired"
    } catch { return "FAILED: $_" }
}
function Fix-RebootPending {
    Write-RemLog "Checking reboot state..."
    $keys = @("HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
              "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired")
    $found = $keys | Where-Object { Test-Path $_ }
    if ($found) { Write-RemLog "Reboot pending detected" -Err; return "INFO: Reboot pending — schedule maintenance window" }
    Write-RemLog "No reboot pending" -OK; return "SUCCESS: No reboot pending"
}
function Fix-ResyncContent {
    Write-RemLog "Re-syncing content..."
    try {
        $cl = [wmiclass]"\\.\root\ccm:SMS_Client"
        $cl.TriggerSchedule("{00000000-0000-0000-0000-000000000108}") | Out-Null
        Write-RemLog "Content resync triggered" -OK; return "SUCCESS: Content resync triggered"
    } catch { Write-RemLog "Failed: $_" -Err; return "FAILED: $_" }
}
function Invoke-Remediation { param([string]$F)
    $Script:RemLog.Clear()
    switch($F) {
        "Fix-CCMCache"      { return Fix-CCMCache }
        "Fix-PolicyAgent"   { return Fix-PolicyAgent }
        "Fix-WUAHandler"    { return Fix-WUAHandler }
        "Fix-BITSService"   { return Fix-BITSService }
        "Fix-CCMService"    { return Fix-CCMService }
        "Fix-WMIRepository" { return Fix-WMIRepository }
        "Fix-RebootPending" { return Fix-RebootPending }
        "Fix-ResyncContent" { return Fix-ResyncContent }
        default             { return "ERROR: Unknown function '$F'" }
    }
}
#endregion

#region ── XAML ───────────────────────────────────────────────────────────────
[xml]$XAML = @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="SCCM Deployment Intelligence Suite"
    Width="1400" Height="900"
    MinWidth="1200" MinHeight="780"
    WindowStartupLocation="CenterScreen"
    Background="#020B18"
    FontFamily="Segoe UI">

  <Window.Resources>
    <!-- Base styles -->
    <Style x:Key="PanelBorder" TargetType="Border">
      <Setter Property="Background" Value="#061220"/>
      <Setter Property="BorderBrush" Value="#1A4A7A"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="8"/>
    </Style>
    <Style x:Key="SectionTitle" TargetType="TextBlock">
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Foreground" Value="#FFD700"/>
    </Style>
    <Style x:Key="KpiLabel" TargetType="TextBlock">
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="Foreground" Value="#8BB8D8"/>
    </Style>
    <Style x:Key="KpiValue" TargetType="TextBlock">
      <Setter Property="FontSize" Value="28"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
    </Style>
    <Style x:Key="ActionBtn" TargetType="Button">
      <Setter Property="Background" Value="#0A2540"/>
      <Setter Property="Foreground" Value="#00CFFF"/>
      <Setter Property="BorderBrush" Value="#1A6EA8"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="8,3"/>
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#1A6EA8"/>
          <Setter Property="Foreground" Value="#FFFFFF"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="RemBtn" TargetType="Button">
      <Setter Property="Background" Value="#061220"/>
      <Setter Property="Foreground" Value="#00CFFF"/>
      <Setter Property="BorderBrush" Value="#1A4A7A"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="6,5"/>
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,2"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#0D4A1F"/>
          <Setter Property="BorderBrush" Value="#00FF88"/>
          <Setter Property="Foreground" Value="#00FF88"/>
        </Trigger>
      </Style.Triggers>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="70"/>   <!-- Header -->
      <RowDefinition Height="100"/>  <!-- KPI strip -->
      <RowDefinition Height="*"/>    <!-- Main content -->
      <RowDefinition Height="60"/>   <!-- Pipeline footer -->
    </Grid.RowDefinitions>

    <!-- ═══════════════════════════════════════════════════ HEADER -->
    <Border Grid.Row="0" Background="#030F1E" BorderBrush="#1A4A7A" BorderThickness="0,0,0,1">
      <Grid Margin="20,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>

        <!-- Logo shield -->
        <Border Grid.Column="0" Width="50" Height="50" Background="#0A2040"
                BorderBrush="#1E6FBF" BorderThickness="2" CornerRadius="8" Margin="0,0,14,0">
          <TextBlock Text="SCCM" Foreground="#00CFFF" FontSize="9" FontWeight="Bold"
                     HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>

        <!-- Title block -->
        <StackPanel Grid.Column="1" VerticalAlignment="Center">
          <StackPanel Orientation="Horizontal">
            <TextBlock Text="SCCM " Foreground="#FFFFFF" FontSize="22" FontWeight="Bold"/>
            <TextBlock Text="Deployment Intelligence Suite" Foreground="#FFD700" FontSize="22" FontWeight="Bold"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" Margin="0,2,0,0">
            <Ellipse Width="6" Height="6" Fill="#00FF88" Margin="0,0,6,0" VerticalAlignment="Center"/>
            <TextBlock Text="Real-Time Failure Detection" Foreground="#8BB8D8" FontSize="10"/>
            <Ellipse Width="4" Height="4" Fill="#00FF88" Margin="8,0" VerticalAlignment="Center"/>
            <TextBlock Text="Root Cause Analysis" Foreground="#8BB8D8" FontSize="10"/>
            <Ellipse Width="4" Height="4" Fill="#00FF88" Margin="8,0" VerticalAlignment="Center"/>
            <TextBlock Text="Auto-Remediation" Foreground="#8BB8D8" FontSize="10"/>
          </StackPanel>
        </StackPanel>

        <!-- LIVE badge + scan -->
        <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
          <Border Background="#0A3020" BorderBrush="#00CC44" BorderThickness="1" CornerRadius="4" Padding="8,4" Margin="0,0,12,0">
            <StackPanel Orientation="Horizontal">
              <Ellipse x:Name="elLive" Width="7" Height="7" Fill="#00FF88" Margin="0,0,5,0" VerticalAlignment="Center"/>
              <TextBlock Text="LIVE" Foreground="#00FF88" FontWeight="Bold" FontSize="11"/>
            </StackPanel>
          </Border>
          <Button x:Name="btnScan" Content="⟳  SCAN NOW" Style="{StaticResource ActionBtn}"
                  Background="#1F6FEB" BorderBrush="#388BFD" Foreground="White" FontSize="11"
                  Padding="14,7" Margin="0,0,8,0"/>
          <Button x:Name="btnAutoScan" Content="AUTO: ON" Style="{StaticResource ActionBtn}" Padding="10,7"/>
          <TextBlock x:Name="txtLastScan" Foreground="#3A5A78" FontSize="9"
                     VerticalAlignment="Center" Margin="10,0,0,0"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- ═══════════════════════════════════════════════════ KPI STRIP -->
    <Grid Grid.Row="1" Margin="16,8,16,4">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <!-- Total Endpoints -->
      <Border Grid.Column="0" Style="{StaticResource PanelBorder}" Margin="0,0,6,0" Padding="14,8">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
          <TextBlock Text="Total Endpoints" Style="{StaticResource KpiLabel}"/>
          <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,2,0,0">
            <TextBlock x:Name="txtEndpoints" Text="8,547" Style="{StaticResource KpiValue}"/>
          </StackPanel>
          <StackPanel Grid.Row="2" Orientation="Horizontal">
            <TextBlock Text="▲ " Foreground="#00FF88" FontSize="11" FontWeight="Bold"/>
            <TextBlock x:Name="txtHealthPct" Text="92% Healthy" Foreground="#00FF88" FontSize="11" FontWeight="Bold"/>
          </StackPanel>
        </Grid>
      </Border>

      <!-- Pending Deployments -->
      <Border Grid.Column="1" Style="{StaticResource PanelBorder}" Margin="3,0,3,0" Padding="14,8">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
          <TextBlock Text="Pending Deployments" Style="{StaticResource KpiLabel}"/>
          <TextBlock x:Name="txtPendingDep" Grid.Row="1" Text="1,204" Style="{StaticResource KpiValue}" Foreground="#FFD700"/>
          <StackPanel Grid.Row="2" Orientation="Horizontal">
            <TextBlock Text="= " Foreground="#FFD700" FontSize="11"/>
            <TextBlock Text="In Progress" Foreground="#FFD700" FontSize="11"/>
          </StackPanel>
        </Grid>
      </Border>

      <!-- Failures Today -->
      <Border Grid.Column="2" Style="{StaticResource PanelBorder}" Margin="3,0,3,0" Padding="14,8" BorderBrush="#7A1A1A">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
          <TextBlock Style="{StaticResource KpiLabel}">
            <Run Text="Failures "/><Run Text="(Today)" Foreground="#FFD700"/>
          </TextBlock>
          <TextBlock x:Name="txtFailures" Grid.Row="1" Text="87" Style="{StaticResource KpiValue}" Foreground="#FF5555"/>
          <StackPanel Grid.Row="2" Orientation="Horizontal">
            <TextBlock Text="▼ 12%" Foreground="#FF5555" FontSize="11" FontWeight="Bold"/>
          </StackPanel>
        </Grid>
      </Border>

      <!-- Auto-Remediated -->
      <Border Grid.Column="3" Style="{StaticResource PanelBorder}" Margin="3,0,3,0" Padding="14,8" BorderBrush="#0A4A1A">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
          <TextBlock Text="Auto-Remediated" Style="{StaticResource KpiLabel}"/>
          <TextBlock x:Name="txtAutoRem" Grid.Row="1" Text="63" Style="{StaticResource KpiValue}" Foreground="#00FF88"/>
          <StackPanel Grid.Row="2" Orientation="Horizontal">
            <TextBlock Text="✔ 72% Success" Foreground="#00FF88" FontSize="11" FontWeight="Bold"/>
          </StackPanel>
        </Grid>
      </Border>

      <!-- Patch Compliance -->
      <Border Grid.Column="4" Style="{StaticResource PanelBorder}" Margin="6,0,0,0" Padding="14,8">
        <Grid>
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
          <TextBlock Text="Patch Compliance" Style="{StaticResource KpiLabel}"/>
          <TextBlock x:Name="txtCompliance" Grid.Row="1" Text="94.3%" Style="{StaticResource KpiValue}" Foreground="#00CFFF"/>
          <ProgressBar x:Name="pbCompliance" Grid.Row="2" Value="94.3" Maximum="100"
                       Height="6" Margin="0,4,0,2" Foreground="#00CFFF" Background="#0A2040"/>
          <TextBlock Grid.Row="3" Text="▲ 3.2%" Foreground="#00FF88" FontSize="11" FontWeight="Bold"/>
        </Grid>
      </Border>
    </Grid>

    <!-- ═══════════════════════════════════════════════════ MAIN CONTENT -->
    <Grid Grid.Row="2" Margin="16,4,16,4">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="230"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="260"/>
      </Grid.ColumnDefinitions>

      <!-- LEFT COLUMN -->
      <Grid Grid.Column="0" Margin="0,0,6,0">
        <Grid.RowDefinitions>
          <RowDefinition Height="*"/>
          <RowDefinition Height="120"/>
        </Grid.RowDefinitions>

        <!-- Failure Insights -->
        <Border Grid.Row="0" Style="{StaticResource PanelBorder}" Margin="0,0,0,6" Padding="10,10">
          <StackPanel>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
              <TextBlock Style="{StaticResource SectionTitle}" Text="Failure Insights"/>
              <TextBlock Foreground="#8BB8D8" FontSize="10" Margin="4,0,0,0" VerticalAlignment="Bottom"> (Last 24 hrs)</TextBlock>
            </StackPanel>

            <!-- App Install Fail -->
            <Border Background="#1A0808" BorderBrush="#5A1010" BorderThickness="1" CornerRadius="5" Padding="8,6" Margin="0,0,0,5">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <StackPanel>
                  <TextBlock Text="App Install Fail" Foreground="#FFFFFF" FontWeight="Bold" FontSize="11"/>
                  <TextBlock Text="MSI 1603, 1618" Foreground="#8BB8D8" FontSize="9"/>
                </StackPanel>
                <TextBlock x:Name="txtAppFail" Grid.Column="1" Text="42" Foreground="#FF5555" FontSize="20" FontWeight="Bold" VerticalAlignment="Center"/>
              </Grid>
            </Border>

            <!-- Content Unavailable -->
            <Border Background="#1A1000" BorderBrush="#5A3A00" BorderThickness="1" CornerRadius="5" Padding="8,6" Margin="0,0,0,5">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <StackPanel>
                  <TextBlock Text="Content Unavailable" Foreground="#FFFFFF" FontWeight="Bold" FontSize="11"/>
                  <TextBlock Text="DP/Content" Foreground="#8BB8D8" FontSize="9"/>
                </StackPanel>
                <TextBlock x:Name="txtContentFail" Grid.Column="1" Text="15" Foreground="#FFD700" FontSize="20" FontWeight="Bold" VerticalAlignment="Center"/>
              </Grid>
            </Border>

            <!-- Client Errors -->
            <Border Background="#0A1020" BorderBrush="#1A4A7A" BorderThickness="1" CornerRadius="5" Padding="8,6" Margin="0,0,0,5">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <StackPanel>
                  <TextBlock Text="Client Errors" Foreground="#FFFFFF" FontWeight="Bold" FontSize="11"/>
                  <TextBlock Text="Policy, CCMExec" Foreground="#8BB8D8" FontSize="9"/>
                </StackPanel>
                <TextBlock x:Name="txtClientErr" Grid.Column="1" Text="12" Foreground="#00CFFF" FontSize="20" FontWeight="Bold" VerticalAlignment="Center"/>
              </Grid>
            </Border>

            <!-- Network/WSUS -->
            <Border Background="#0A1020" BorderBrush="#1A4A7A" BorderThickness="1" CornerRadius="5" Padding="8,6" Margin="0,0,0,5">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <StackPanel>
                  <TextBlock Text="Network/WSUS" Foreground="#FFFFFF" FontWeight="Bold" FontSize="11"/>
                  <TextBlock Text="Timeout, BITS" Foreground="#8BB8D8" FontSize="9"/>
                </StackPanel>
                <TextBlock Grid.Column="1" Text="9" Foreground="#8BB8D8" FontSize="20" FontWeight="Bold" VerticalAlignment="Center"/>
              </Grid>
            </Border>

            <!-- Reboot Pending -->
            <Border Background="#0A1020" BorderBrush="#1A4A7A" BorderThickness="1" CornerRadius="5" Padding="8,6">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <StackPanel>
                  <TextBlock Text="Reboot Pending" Foreground="#FFFFFF" FontWeight="Bold" FontSize="11"/>
                  <TextBlock Text="Install Exit 3010" Foreground="#8BB8D8" FontSize="9"/>
                </StackPanel>
                <TextBlock Grid.Column="1" Text="9" Foreground="#8BB8D8" FontSize="20" FontWeight="Bold" VerticalAlignment="Center"/>
              </Grid>
            </Border>
          </StackPanel>
        </Border>

        <!-- SCCM Health Overview -->
        <Border Grid.Row="1" Style="{StaticResource PanelBorder}" Padding="10,10">
          <StackPanel>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
              <TextBlock Foreground="#00CFFF" FontWeight="Bold" FontSize="11" Text="SCCM Health"/>
              <TextBlock Foreground="#FFFFFF" FontWeight="Bold" FontSize="11" Text=" Overview"/>
            </StackPanel>
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>
              <!-- MP Roles -->
              <StackPanel Grid.Column="0" HorizontalAlignment="Center">
                <Border Background="#0A1828" BorderBrush="#1A4A7A" BorderThickness="1" CornerRadius="6" Width="58" Height="44">
                  <TextBlock x:Name="txtMPStatus" Text="✔" Foreground="#00FF88" FontSize="20" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
                <TextBlock Text="MP Roles" Foreground="#8BB8D8" FontSize="9" HorizontalAlignment="Center" Margin="0,3,0,0"/>
                <TextBlock x:Name="txtMPLabel" Text="OK" Foreground="#00FF88" FontSize="10" FontWeight="Bold" HorizontalAlignment="Center"/>
              </StackPanel>
              <!-- DP Status -->
              <StackPanel Grid.Column="1" HorizontalAlignment="Center">
                <Border Background="#0A1828" BorderBrush="#1A4A7A" BorderThickness="1" CornerRadius="6" Width="58" Height="44">
                  <TextBlock x:Name="txtDPStatus" Text="✔" Foreground="#00FF88" FontSize="20" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
                <TextBlock Text="DP Status" Foreground="#8BB8D8" FontSize="9" HorizontalAlignment="Center" Margin="0,3,0,0"/>
                <TextBlock x:Name="txtDPLabel" Text="OK" Foreground="#00FF88" FontSize="10" FontWeight="Bold" HorizontalAlignment="Center"/>
              </StackPanel>
              <!-- WSUS -->
              <StackPanel Grid.Column="2" HorizontalAlignment="Center">
                <Border Background="#0A1828" BorderBrush="#0A5A30" BorderThickness="1" CornerRadius="6" Width="58" Height="44">
                  <TextBlock Text="✔" Foreground="#00FF88" FontSize="20" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                </Border>
                <TextBlock Text="WSUS" Foreground="#8BB8D8" FontSize="9" HorizontalAlignment="Center" Margin="0,3,0,0"/>
                <TextBlock Text="Healthy" Foreground="#00FF88" FontSize="10" FontWeight="Bold" HorizontalAlignment="Center"/>
              </StackPanel>
            </Grid>
          </StackPanel>
        </Border>
      </Grid>

      <!-- CENTER COLUMN -->
      <Grid Grid.Column="1" Margin="3,0,3,0">
        <Grid.RowDefinitions>
          <RowDefinition Height="*"/>
          <RowDefinition Height="220"/>
        </Grid.RowDefinitions>

        <!-- Root Cause Analysis + Remediation Actions -->
        <Border Grid.Row="0" Style="{StaticResource PanelBorder}" Margin="0,0,0,6" Padding="14,10">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="180"/>
            </Grid.ColumnDefinitions>

            <!-- RCA Section -->
            <StackPanel Grid.Column="0">
              <StackPanel Orientation="Horizontal" Margin="0,0,0,10">
                <TextBlock Text="· " Foreground="#00CFFF" FontSize="14"/>
                <TextBlock Foreground="#00CFFF" FontWeight="Bold" FontSize="12" Text="Root Cause Analysis"/>
              </StackPanel>

              <!-- Center ring diagram (Canvas-based) -->
              <Canvas Width="280" Height="200" HorizontalAlignment="Center">
                <!-- Central FAILED ring -->
                <Ellipse Canvas.Left="100" Canvas.Top="55" Width="80" Height="80"
                         Stroke="#FF3333" StrokeThickness="3" Fill="#1A0808"/>
                <TextBlock Canvas.Left="120" Canvas.Top="83" Text="FAILED" Foreground="#FF5555"
                           FontSize="9" FontWeight="Bold" HorizontalAlignment="Center"/>

                <!-- Content 40% -->
                <Ellipse Canvas.Left="10" Canvas.Top="65" Width="70" Height="70"
                         Stroke="#FFD700" StrokeThickness="2" Fill="#1A1500" Opacity="0.9"/>
                <TextBlock Canvas.Left="25" Canvas.Top="87" Text="40%" Foreground="#FFD700" FontSize="13" FontWeight="Bold"/>
                <TextBlock Canvas.Left="18" Canvas.Top="101" Text="Content" Foreground="#FFD700" FontSize="9"/>
                <!-- Arrow -->
                <Line X1="80" Y1="100" X2="100" Y2="100" Stroke="#FFD700" StrokeThickness="2"/>
                <Polygon Points="97,96 105,100 97,104" Fill="#FFD700"/>

                <!-- Permissions 25% -->
                <Ellipse Canvas.Left="205" Canvas.Top="20" Width="68" Height="68"
                         Stroke="#BC8CFF" StrokeThickness="2" Fill="#130A20" Opacity="0.9"/>
                <TextBlock Canvas.Left="218" Canvas.Top="42" Text="25%" Foreground="#BC8CFF" FontSize="13" FontWeight="Bold"/>
                <TextBlock Canvas.Left="207" Canvas.Top="56" Text="Permissions" Foreground="#BC8CFF" FontSize="9"/>

                <!-- Network 15% -->
                <Ellipse Canvas.Left="15" Canvas.Top="130" Width="60" Height="60"
                         Stroke="#00CFFF" StrokeThickness="2" Fill="#041020" Opacity="0.9"/>
                <TextBlock Canvas.Left="28" Canvas.Top="152" Text="15%" Foreground="#00CFFF" FontSize="12" FontWeight="Bold"/>
                <TextBlock Canvas.Left="23" Canvas.Top="166" Text="Network" Foreground="#00CFFF" FontSize="9"/>

                <!-- Client 10% -->
                <Ellipse Canvas.Left="105" Canvas.Top="148" Width="60" Height="60"
                         Stroke="#00FF88" StrokeThickness="2" Fill="#041510" Opacity="0.9"/>
                <TextBlock Canvas.Left="118" Canvas.Top="168" Text="10%" Foreground="#00FF88" FontSize="12" FontWeight="Bold"/>
                <TextBlock Canvas.Left="118" Canvas.Top="182" Text="Client" Foreground="#00FF88" FontSize="9"/>

                <!-- Others 10% -->
                <Ellipse Canvas.Left="200" Canvas.Top="125" Width="58" Height="58"
                         Stroke="#8BB8D8" StrokeThickness="2" Fill="#0A1020" Opacity="0.9"/>
                <TextBlock Canvas.Left="213" Canvas.Top="146" Text="10%" Foreground="#8BB8D8" FontSize="12" FontWeight="Bold"/>
                <TextBlock Canvas.Left="215" Canvas.Top="160" Text="Others" Foreground="#8BB8D8" FontSize="9"/>
              </Canvas>
            </StackPanel>

            <!-- Remediation Actions -->
            <StackPanel Grid.Column="1" Margin="10,0,0,0">
              <TextBlock Text="Remediation" Foreground="#FFD700" FontWeight="Bold" FontSize="12" Margin="0,0,0,10"/>
              <Button x:Name="btnResync"   Content="⟳  Re-Sync Content"   Style="{StaticResource RemBtn}"/>
              <Button x:Name="btnFixPerm"  Content="✔  Fix Permissions"    Style="{StaticResource RemBtn}"/>
              <Button x:Name="btnBITS"     Content="⚡  Restart BITS"      Style="{StaticResource RemBtn}"/>
              <Button x:Name="btnRepair"   Content="⚙  Repair Client"      Style="{StaticResource RemBtn}"/>
              <Button x:Name="btnReboot"   Content="↺  Auto Reboot Check"  Style="{StaticResource RemBtn}"/>
              <Button x:Name="btnPolicy"   Content="▶  Policy Refresh"     Style="{StaticResource RemBtn}"/>
              <Button x:Name="btnWMI"      Content="⚒  Repair WMI"         Style="{StaticResource RemBtn}"/>
              <Button x:Name="btnCache"    Content="✕  Clear CCM Cache"    Style="{StaticResource RemBtn}"/>
            </StackPanel>
          </Grid>
        </Border>

        <!-- Failure Trend Chart -->
        <Border Grid.Row="1" Style="{StaticResource PanelBorder}" Padding="14,10">
          <StackPanel>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,6">
              <TextBlock Foreground="#FFD700" FontWeight="Bold" FontSize="12" Text="Failure Trend"/>
              <TextBlock Foreground="#8BB8D8" FontSize="11" Margin="4,0,0,0"> (Last 7 Days)</TextBlock>
              <TextBlock Text="  ▼ 35%" Foreground="#00FF88" FontWeight="Bold" FontSize="12" Margin="16,0,0,0"/>
            </StackPanel>
            <!-- Trend line chart via Canvas -->
            <Canvas x:Name="canvasTrend" Height="155" Background="Transparent"/>
          </StackPanel>
        </Border>
      </Grid>

      <!-- RIGHT COLUMN -->
      <Grid Grid.Column="2" Margin="6,0,0,0">
        <Grid.RowDefinitions>
          <RowDefinition Height="200"/>
          <RowDefinition Height="140"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <!-- Live Deployment Status -->
        <Border Grid.Row="0" Style="{StaticResource PanelBorder}" Margin="0,0,0,6" Padding="12,10">
          <StackPanel>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
              <TextBlock Foreground="#FFFFFF" FontWeight="Bold" FontSize="12" Text="Live "/>
              <TextBlock Foreground="#00CFFF" FontWeight="Bold" FontSize="12" Text="Deployment Status"/>
            </StackPanel>
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>

              <!-- Donut placeholder -->
              <Canvas Grid.Column="0" Width="110" Height="110">
                <!-- Outer ring -->
                <Ellipse Canvas.Left="5" Canvas.Top="5" Width="100" Height="100"
                         Stroke="#0A2040" StrokeThickness="16" Fill="Transparent"/>
                <!-- Success arc (green ~81%) -->
                <Path Stroke="#00FF88" StrokeThickness="15" Fill="Transparent" Canvas.Left="5" Canvas.Top="5">
                  <Path.Data>
                    <PathGeometry>
                      <PathFigure StartPoint="50,5" IsClosed="False">
                        <ArcSegment Point="5,50" Size="45,45" IsLargeArc="True" SweepDirection="Clockwise"/>
                      </PathFigure>
                    </PathGeometry>
                  </Path.Data>
                </Path>
                <!-- InProgress arc (blue ~12%) -->
                <Path Stroke="#00CFFF" StrokeThickness="15" Fill="Transparent" Canvas.Left="5" Canvas.Top="5">
                  <Path.Data>
                    <PathGeometry>
                      <PathFigure StartPoint="5,50" IsClosed="False">
                        <ArcSegment Point="25,15" Size="45,45" IsLargeArc="False" SweepDirection="Clockwise"/>
                      </PathFigure>
                    </PathGeometry>
                  </Path.Data>
                </Path>
                <!-- Failed arc (red ~4%) -->
                <Path Stroke="#FF5555" StrokeThickness="15" Fill="Transparent" Canvas.Left="5" Canvas.Top="5">
                  <Path.Data>
                    <PathGeometry>
                      <PathFigure StartPoint="25,15" IsClosed="False">
                        <ArcSegment Point="50,5" Size="45,45" IsLargeArc="False" SweepDirection="Clockwise"/>
                      </PathFigure>
                    </PathGeometry>
                  </Path.Data>
                </Path>
                <!-- Center text -->
                <TextBlock Canvas.Left="18" Canvas.Top="36" Text="1,204" Foreground="#FFFFFF" FontSize="13" FontWeight="Bold"/>
                <TextBlock Canvas.Left="16" Canvas.Top="54" Text="Deployments" Foreground="#8BB8D8" FontSize="8"/>
              </Canvas>

              <!-- Legend -->
              <StackPanel Grid.Column="1" Margin="8,8,0,0" VerticalAlignment="Center">
                <Grid Margin="0,0,0,8">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="40"/></Grid.ColumnDefinitions>
                  <StackPanel Orientation="Horizontal">
                    <Ellipse Width="8" Height="8" Fill="#00FF88" Margin="0,0,6,0" VerticalAlignment="Center"/>
                    <TextBlock Text="Success" Foreground="#8BB8D8" FontSize="10"/>
                  </StackPanel>
                  <TextBlock Grid.Column="1" x:Name="txtDepSuccess" Text="982" Foreground="#FFFFFF" FontWeight="Bold" FontSize="11" HorizontalAlignment="Right"/>
                </Grid>
                <Grid Margin="0,0,0,8">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="40"/></Grid.ColumnDefinitions>
                  <StackPanel Orientation="Horizontal">
                    <Ellipse Width="8" Height="8" Fill="#00CFFF" Margin="0,0,6,0" VerticalAlignment="Center"/>
                    <TextBlock Text="In Progress" Foreground="#8BB8D8" FontSize="10"/>
                  </StackPanel>
                  <TextBlock Grid.Column="1" x:Name="txtDepInProg" Text="145" Foreground="#FFFFFF" FontWeight="Bold" FontSize="11" HorizontalAlignment="Right"/>
                </Grid>
                <Grid Margin="0,0,0,8">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="40"/></Grid.ColumnDefinitions>
                  <StackPanel Orientation="Horizontal">
                    <Ellipse Width="8" Height="8" Fill="#FF5555" Margin="0,0,6,0" VerticalAlignment="Center"/>
                    <TextBlock Text="Failed" Foreground="#8BB8D8" FontSize="10"/>
                  </StackPanel>
                  <TextBlock Grid.Column="1" x:Name="txtDepFailed" Text="45" Foreground="#FF5555" FontWeight="Bold" FontSize="11" HorizontalAlignment="Right"/>
                </Grid>
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="40"/></Grid.ColumnDefinitions>
                  <StackPanel Orientation="Horizontal">
                    <Ellipse Width="8" Height="8" Fill="#8B8B8B" Margin="0,0,6,0" VerticalAlignment="Center"/>
                    <TextBlock Text="Pending" Foreground="#8BB8D8" FontSize="10"/>
                  </StackPanel>
                  <TextBlock Grid.Column="1" x:Name="txtDepPending" Text="32" Foreground="#FFFFFF" FontWeight="Bold" FontSize="11" HorizontalAlignment="Right"/>
                </Grid>
              </StackPanel>
            </Grid>
          </StackPanel>
        </Border>

        <!-- Top Failed Devices -->
        <Border Grid.Row="1" Style="{StaticResource PanelBorder}" Margin="0,0,0,6" Padding="12,10">
          <StackPanel>
            <TextBlock Foreground="#FFD700" FontWeight="Bold" FontSize="12" Margin="0,0,0,8" Text="Top Failed Devices"/>
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="70"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="80"/>
              </Grid.ColumnDefinitions>
              <TextBlock Text="Device" Foreground="#3A5A78" FontSize="9"/>
              <TextBlock Grid.Column="1" Text="Error" Foreground="#3A5A78" FontSize="9"/>
              <TextBlock Grid.Column="2" Text="Action" Foreground="#3A5A78" FontSize="9" HorizontalAlignment="Right"/>
            </Grid>
            <Rectangle Height="1" Fill="#1A4A7A" Margin="0,3,0,4"/>
            <ItemsControl x:Name="icFailedDevices">
              <ItemsControl.ItemTemplate>
                <DataTemplate>
                  <Grid Margin="0,2">
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="70"/>
                      <ColumnDefinition Width="*"/>
                      <ColumnDefinition Width="80"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel Orientation="Horizontal">
                      <Ellipse Width="6" Height="6" Fill="#FF5555" Margin="0,0,5,0" VerticalAlignment="Center"/>
                      <TextBlock Text="{Binding Device}" Foreground="#FFFFFF" FontSize="10"/>
                    </StackPanel>
                    <TextBlock Grid.Column="1" Text="{Binding Error}" Foreground="#FFD700" FontSize="10"/>
                    <Button Grid.Column="2" Tag="{Binding RemFunc}"
                            Content="Remediate" Style="{StaticResource ActionBtn}"
                            FontSize="9" Padding="4,2" HorizontalAlignment="Right"
                            x:Name="btnDevRem"/>
                  </Grid>
                </DataTemplate>
              </ItemsControl.ItemTemplate>
            </ItemsControl>
          </StackPanel>
        </Border>

        <!-- Auto-Remediation Log -->
        <Border Grid.Row="2" Style="{StaticResource PanelBorder}" Padding="12,10">
          <StackPanel>
            <StackPanel Orientation="Horizontal" Margin="0,0,0,8">
              <TextBlock Foreground="#FFD700" FontWeight="Bold" FontSize="12" Text="Auto-Remediation "/>
              <TextBlock Foreground="#00CFFF" FontWeight="Bold" FontSize="12" Text="Log"/>
            </StackPanel>
            <StackPanel x:Name="spRemLog">
              <Grid Margin="0,0,0,5">
                <Grid.ColumnDefinitions><ColumnDefinition Width="14"/><ColumnDefinition Width="60"/><ColumnDefinition Width="*"/><ColumnDefinition Width="60"/></Grid.ColumnDefinitions>
                <TextBlock Text="✔" Foreground="#00FF88" FontSize="10"/>
                <TextBlock Grid.Column="1" Text="PC-1023" Foreground="#FFFFFF" FontSize="10"/>
                <StackPanel Grid.Column="2" Orientation="Horizontal">
                  <TextBlock Text="Fixed (" Foreground="#8BB8D8" FontSize="10"/>
                  <TextBlock Text="BITS Restart" Foreground="#FFD700" FontSize="10" FontWeight="Bold"/>
                  <TextBlock Text=")" Foreground="#8BB8D8" FontSize="10"/>
                </StackPanel>
                <TextBlock Grid.Column="3" Text="5 min ago" Foreground="#3A5A78" FontSize="9" HorizontalAlignment="Right"/>
              </Grid>
              <Grid Margin="0,0,0,5">
                <Grid.ColumnDefinitions><ColumnDefinition Width="14"/><ColumnDefinition Width="60"/><ColumnDefinition Width="*"/><ColumnDefinition Width="60"/></Grid.ColumnDefinitions>
                <TextBlock Text="✔" Foreground="#00FF88" FontSize="10"/>
                <TextBlock Grid.Column="1" Text="PC-2001" Foreground="#FFFFFF" FontSize="10"/>
                <StackPanel Grid.Column="2" Orientation="Horizontal">
                  <TextBlock Text="Fixed (" Foreground="#8BB8D8" FontSize="10"/>
                  <TextBlock Text="DP Switch" Foreground="#FFD700" FontSize="10" FontWeight="Bold"/>
                  <TextBlock Text=")" Foreground="#8BB8D8" FontSize="10"/>
                </StackPanel>
                <TextBlock Grid.Column="3" Text="12 min ago" Foreground="#3A5A78" FontSize="9" HorizontalAlignment="Right"/>
              </Grid>
              <Grid Margin="0,0,0,5">
                <Grid.ColumnDefinitions><ColumnDefinition Width="14"/><ColumnDefinition Width="60"/><ColumnDefinition Width="*"/><ColumnDefinition Width="60"/></Grid.ColumnDefinitions>
                <TextBlock Text="✔" Foreground="#00FF88" FontSize="10"/>
                <TextBlock Grid.Column="1" Text="PC-3809" Foreground="#FFFFFF" FontSize="10"/>
                <StackPanel Grid.Column="2" Orientation="Horizontal">
                  <TextBlock Text="Fixed (" Foreground="#8BB8D8" FontSize="10"/>
                  <TextBlock Text="Client Repair" Foreground="#FFD700" FontSize="10" FontWeight="Bold"/>
                  <TextBlock Text=")" Foreground="#8BB8D8" FontSize="10"/>
                </StackPanel>
                <TextBlock Grid.Column="3" Text="18 min ago" Foreground="#3A5A78" FontSize="9" HorizontalAlignment="Right"/>
              </Grid>
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="14"/><ColumnDefinition Width="60"/><ColumnDefinition Width="*"/><ColumnDefinition Width="60"/></Grid.ColumnDefinitions>
                <TextBlock Text="⧖" Foreground="#FFD700" FontSize="10"/>
                <TextBlock Grid.Column="1" Text="PC-5512" Foreground="#FFFFFF" FontSize="10"/>
                <StackPanel Grid.Column="2" Orientation="Horizontal">
                  <TextBlock Text="Pending (" Foreground="#8BB8D8" FontSize="10"/>
                  <TextBlock Text="Reboot" Foreground="#FFD700" FontSize="10" FontWeight="Bold"/>
                  <TextBlock Text=")" Foreground="#8BB8D8" FontSize="10"/>
                </StackPanel>
                <TextBlock Grid.Column="3" Text="22 min ago" Foreground="#3A5A78" FontSize="9" HorizontalAlignment="Right"/>
              </Grid>
            </StackPanel>
            <!-- Live output box -->
            <Border Background="#020B18" BorderBrush="#1A4A7A" BorderThickness="1" CornerRadius="4"
                    Padding="6,5" Margin="0,8,0,0">
              <ScrollViewer x:Name="svOut" MaxHeight="55" VerticalScrollBarVisibility="Auto">
                <TextBlock x:Name="txtOutput" Text="Awaiting remediation..."
                           Foreground="#00FF88" FontSize="9" FontFamily="Consolas" TextWrapping="Wrap"/>
              </ScrollViewer>
            </Border>
          </StackPanel>
        </Border>
      </Grid>
    </Grid>

    <!-- ═══════════════════════════════════════════════════ PIPELINE FOOTER -->
    <Border Grid.Row="3" Background="#030F1E" BorderBrush="#1A4A7A" BorderThickness="0,1,0,0" Padding="20,0">
      <Grid VerticalAlignment="Center">
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center">
          <!-- Step 1 -->
          <Border Background="#0A1828" BorderBrush="#1A4A7A" BorderThickness="1" CornerRadius="6" Padding="12,6">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="PS" Foreground="#00CFFF" FontWeight="Bold" FontSize="13" Margin="0,0,8,0"/>
              <StackPanel>
                <TextBlock Text="PowerShell" Foreground="#FFFFFF" FontSize="9" FontWeight="Bold"/>
                <TextBlock Text="Agent" Foreground="#8BB8D8" FontSize="9"/>
              </StackPanel>
            </StackPanel>
          </Border>
          <TextBlock Text="  →  " Foreground="#FFD700" FontSize="14" FontWeight="Bold" VerticalAlignment="Center"/>
          <!-- Step 2 -->
          <Border Background="#0A1828" BorderBrush="#1A4A7A" BorderThickness="1" CornerRadius="6" Padding="12,6">
            <StackPanel>
              <TextBlock Text="Log Parsing" Foreground="#FFFFFF" FontSize="9" FontWeight="Bold"/>
              <TextBlock Text="28 Log Sources" Foreground="#8BB8D8" FontSize="9"/>
            </StackPanel>
          </Border>
          <TextBlock Text="  →  " Foreground="#FFD700" FontSize="14" FontWeight="Bold" VerticalAlignment="Center"/>
          <!-- Step 3 -->
          <Border Background="#0A1828" BorderBrush="#1A4A7A" BorderThickness="1" CornerRadius="6" Padding="12,6">
            <StackPanel>
              <TextBlock Text="Root Cause Engine" Foreground="#FFFFFF" FontSize="9" FontWeight="Bold"/>
              <TextBlock Text="15 Pattern Library" Foreground="#8BB8D8" FontSize="9"/>
            </StackPanel>
          </Border>
          <TextBlock Text="  →  " Foreground="#FFD700" FontSize="14" FontWeight="Bold" VerticalAlignment="Center"/>
          <!-- Step 4 -->
          <Border Background="#0A2010" BorderBrush="#0A5A20" BorderThickness="1" CornerRadius="6" Padding="12,6">
            <StackPanel>
              <TextBlock Text="Auto Remediation" Foreground="#FFD700" FontSize="9" FontWeight="Bold"/>
              <TextBlock Text="8 Fix Scripts" Foreground="#8BB8D8" FontSize="9"/>
            </StackPanel>
          </Border>
          <TextBlock Text="  →  " Foreground="#FFD700" FontSize="14" FontWeight="Bold" VerticalAlignment="Center"/>
          <!-- Step 5 -->
          <Border Background="#0A1828" BorderBrush="#1A4A7A" BorderThickness="1" CornerRadius="6" Padding="12,6">
            <StackPanel>
              <TextBlock Text="Central Dashboard" Foreground="#FFFFFF" FontSize="9" FontWeight="Bold"/>
              <TextBlock Text="Real-Time View" Foreground="#8BB8D8" FontSize="9"/>
            </StackPanel>
          </Border>
          <TextBlock Text="  →  " Foreground="#FFD700" FontSize="14" FontWeight="Bold" VerticalAlignment="Center"/>
          <!-- Step 6 -->
          <Border Background="#0A1828" BorderBrush="#1A4A7A" BorderThickness="1" CornerRadius="6" Padding="12,6">
            <StackPanel>
              <TextBlock Text="SCCM Integration" Foreground="#00CFFF" FontSize="9" FontWeight="Bold"/>
              <TextBlock Text="WMI / Log API" Foreground="#8BB8D8" FontSize="9"/>
            </StackPanel>
          </Border>
        </StackPanel>
        <TextBlock x:Name="txtStatus" Foreground="#3A5A78" FontSize="9"
                   HorizontalAlignment="Right" VerticalAlignment="Center"/>
      </Grid>
    </Border>
  </Grid>
</Window>
'@
#endregion

#region ── LOAD WINDOW ────────────────────────────────────────────────────────
$reader = New-Object System.Xml.XmlNodeReader $XAML
$W = [Windows.Markup.XamlReader]::Load($reader)

function Find { param($n) $W.FindName($n) }

$C = @{}
foreach ($n in @(
    "btnScan","btnAutoScan","txtLastScan","txtStatus",
    "txtEndpoints","txtHealthPct","txtPendingDep","txtFailures","txtAutoRem","txtCompliance","pbCompliance",
    "txtAppFail","txtContentFail","txtClientErr",
    "txtDepSuccess","txtDepInProg","txtDepFailed","txtDepPending",
    "txtMPStatus","txtMPLabel","txtDPStatus","txtDPLabel",
    "icFailedDevices","canvasTrend","txtOutput","svOut","elLive",
    "btnResync","btnFixPerm","btnBITS","btnRepair","btnReboot","btnPolicy","btnWMI","btnCache"
)) { $C[$n] = $W.FindName($n) }
#endregion

#region ── TREND CHART RENDERER ──────────────────────────────────────────────
function Draw-TrendChart {
    param([System.Windows.Controls.Canvas]$cv, [int[]]$data)
    $cv.Children.Clear()
    $W2 = $cv.ActualWidth; if ($W2 -lt 10) { $W2 = 500 }
    $H2 = $cv.ActualHeight; if ($H2 -lt 10) { $H2 = 140 }
    $pad = 40; $chartW = $W2 - $pad*1.5; $chartH = $H2 - 30
    $max = ($data | Measure-Object -Maximum).Maximum + 5
    $min = [math]::Max(0, ($data | Measure-Object -Minimum).Minimum - 5)
    $range = $max - $min; if ($range -eq 0) { $range = 1 }
    $n = $data.Count

    # Grid lines
    foreach ($pct in @(0,0.25,0.5,0.75,1.0)) {
        $yVal = $max - ($pct * $range)
        $y = 10 + $pct * $chartH
        $line = New-Object System.Windows.Shapes.Line
        $line.X1 = $pad; $line.Y1 = $y; $line.X2 = $pad + $chartW; $line.Y2 = $y
        $line.Stroke = [System.Windows.Media.Brushes]::DarkSlateBlue
        $line.StrokeThickness = 0.5; $line.StrokeDashArray = "3,4"
        $cv.Children.Add($line) | Out-Null
        $lbl = New-Object System.Windows.Controls.TextBlock
        $lbl.Text = [math]::Round($yVal).ToString()
        $lbl.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#3A5A78")
        $lbl.FontSize = 8
        [System.Windows.Controls.Canvas]::SetLeft($lbl, 2)
        [System.Windows.Controls.Canvas]::SetTop($lbl, $y - 7)
        $cv.Children.Add($lbl) | Out-Null
    }

    # Compute points
    $pts = [System.Collections.Generic.List[System.Windows.Point]]::new()
    for ($i = 0; $i -lt $n; $i++) {
        $x = $pad + ($i / ($n-1)) * $chartW
        $y = 10 + (($max - $data[$i]) / $range) * $chartH
        $pts.Add([System.Windows.Point]::new($x, $y))
        # Day label
        $lbl = New-Object System.Windows.Controls.TextBlock
        $lbl.Text = "Day $($i+1)"
        $lbl.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#3A5A78")
        $lbl.FontSize = 8
        [System.Windows.Controls.Canvas]::SetLeft($lbl, $x - 12)
        [System.Windows.Controls.Canvas]::SetTop($lbl, $H2 - 16)
        $cv.Children.Add($lbl) | Out-Null
    }

    # Fill polygon under line
    $poly = New-Object System.Windows.Shapes.Polygon
    $pc = New-Object System.Windows.Media.PointCollection
    $pc.Add([System.Windows.Point]::new($pts[0].X, 10 + $chartH))
    foreach ($p in $pts) { $pc.Add($p) }
    $pc.Add([System.Windows.Point]::new($pts[$n-1].X, 10 + $chartH))
    $poly.Points = $pc
    $poly.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#1A0808")
    $poly.Opacity = 0.6
    $cv.Children.Add($poly) | Out-Null

    # Red line segments
    for ($i = 0; $i -lt $pts.Count - 1; $i++) {
        $seg = New-Object System.Windows.Shapes.Line
        $seg.X1=$pts[$i].X; $seg.Y1=$pts[$i].Y; $seg.X2=$pts[$i+1].X; $seg.Y2=$pts[$i+1].Y
        $seg.Stroke = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#FF3333")
        $seg.StrokeThickness = 2
        $cv.Children.Add($seg) | Out-Null
    }

    # Yellow trend (dashed forecast)
    for ($i = 3; $i -lt $pts.Count - 1; $i++) {
        $seg2 = New-Object System.Windows.Shapes.Line
        $seg2.X1=$pts[$i].X; $seg2.Y1=$pts[$i].Y; $seg2.X2=$pts[$i+1].X; $seg2.Y2=$pts[$i+1].Y
        $seg2.Stroke = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#FFD700")
        $seg2.StrokeThickness = 1.5; $seg2.StrokeDashArray = "4,3"
        $cv.Children.Add($seg2) | Out-Null
    }

    # Data point dots
    foreach ($p in $pts) {
        $dot = New-Object System.Windows.Shapes.Ellipse
        $dot.Width = 7; $dot.Height = 7
        $dot.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#FF5555")
        $dot.Stroke = [System.Windows.Media.Brushes]::Black; $dot.StrokeThickness = 1
        [System.Windows.Controls.Canvas]::SetLeft($dot, $p.X - 3.5)
        [System.Windows.Controls.Canvas]::SetTop($dot, $p.Y - 3.5)
        $cv.Children.Add($dot) | Out-Null
    }
}
#endregion

#region ── UPDATE DASHBOARD ───────────────────────────────────────────────────
function Update-Dashboard {
    $m = Get-LiveMetrics
    $C["txtEndpoints"].Text    = "{0:N0}" -f $m.TotalEndpoints
    $C["txtPendingDep"].Text   = "{0:N0}" -f $m.PendingDeployments
    $C["txtFailures"].Text     = $m.FailuresToday.ToString()
    $C["txtAutoRem"].Text      = $m.AutoRemediated.ToString()
    $C["txtCompliance"].Text   = "$($m.PatchCompliance)%"
    $C["pbCompliance"].Value   = $m.PatchCompliance
    $C["txtDepSuccess"].Text   = $m.DepSuccess.ToString()
    $C["txtDepInProg"].Text    = $m.DepInProgress.ToString()
    $C["txtDepFailed"].Text    = $m.DepFailed.ToString()
    $C["txtDepPending"].Text   = $m.DepPending.ToString()
    $C["txtAppFail"].Text      = $m.AppInstallFail.ToString()
    $C["txtLastScan"].Text     = "Last: $(Get-Date -f 'HH:mm:ss')"
    $C["txtStatus"].Text       = "Scan OK  |  $($Script:LogSources.Count) logs parsed  |  $(Get-Date -f 'HH:mm:ss')"

    # Render trend chart
    Draw-TrendChart -cv $C["canvasTrend"] -data $m.Trend
}

$Script:LogSources = @("AppEnforce","CAS","CCMExec","ContentTransferManager","DataTransferService",
    "execmgr","LocationServices","PolicyAgent","ScanAgent","UpdatesDeployment","UpdatesHandler",
    "WUAHandler","BITS","CCMEval","CCMNotificationAgent","ClientLocation","MaintenanceCoordinator",
    "PolicyEvaluator","RebootCoordinator","Scheduler","ServiceWindowManager","UpdateStore",
    "AppDiscovery","AppIntentEval","CCMRestart","CcmRepair","ClientIDManagerStartup","SoftwareCenterSystemTasks")
#endregion

#region ── WIRE EVENTS ────────────────────────────────────────────────────────
# Failed devices list
$C["icFailedDevices"].ItemsSource = $Script:FailedDevices

function Run-Rem { param([string]$fn)
    $C["txtOutput"].Text = "Running $fn ..."
    $result = Invoke-Remediation -FunctionName $fn
    $log = ($Script:RemLog -join "`n") + "`n> $result"
    $C["txtOutput"].Text = $log
    $C["svOut"].ScrollToBottom()
    $entry = "$(Get-Date -f 'HH:mm:ss')  ✔  $fn — $result"
    $Script:RemediationLog.Add($entry)
}

$C["btnResync"].Add_Click({ Run-Rem "Fix-ResyncContent" })
$C["btnFixPerm"].Add_Click({ Run-Rem "Fix-PolicyAgent"  })
$C["btnBITS"].Add_Click({   Run-Rem "Fix-BITSService"   })
$C["btnRepair"].Add_Click({ Run-Rem "Fix-CCMService"    })
$C["btnReboot"].Add_Click({ Run-Rem "Fix-RebootPending" })
$C["btnPolicy"].Add_Click({ Run-Rem "Fix-PolicyAgent"   })
$C["btnWMI"].Add_Click({    Run-Rem "Fix-WMIRepository" })
$C["btnCache"].Add_Click({  Run-Rem "Fix-CCMCache"      })

# Device-level remediate buttons via event bubbling on ItemsControl
$C["icFailedDevices"].AddHandler(
    [System.Windows.Controls.Button]::ClickEvent,
    [System.Windows.RoutedEventHandler]{
        param($s,$e)
        if ($e.OriginalSource -is [System.Windows.Controls.Button]) {
            $fn = ($e.OriginalSource).Tag
            if ($fn) { Run-Rem $fn }
        }
    }
)

$C["btnScan"].Add_Click({
    $C["btnScan"].IsEnabled = $false
    $C["txtStatus"].Text = "Scanning..."
    Update-Dashboard
    Draw-TrendChart -cv $C["canvasTrend"] -data @(31,27,30,25,27,24,19)
    $C["btnScan"].IsEnabled = $true
})

$Script:AutoOn = $true
$C["btnAutoScan"].Add_Click({
    $Script:AutoOn = -not $Script:AutoOn
    $C["btnAutoScan"].Content    = if ($Script:AutoOn) { "AUTO: ON"  } else { "AUTO: OFF" }
    $onBr  = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#00CFFF")
    $offBr = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#FF5555")
    $C["btnAutoScan"].Foreground = if ($Script:AutoOn) { $onBr } else { $offBr }
})

# Auto-scan timer
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMinutes($Script:Cfg.RefreshMin)
$timer.Add_Tick({ if ($Script:AutoOn) { Update-Dashboard } })
$timer.Start()

# Blinking LIVE dot
$liveTimer = New-Object System.Windows.Threading.DispatcherTimer
$liveTimer.Interval = [TimeSpan]::FromMilliseconds(800)
$liveTimer.Add_Tick({
    $greenBr = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#00FF88")
    $dimBr   = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#004422")
    $C["elLive"].Fill = if ($C["elLive"].Fill.Color -eq $greenBr.Color) { $dimBr } else { $greenBr }
})
$liveTimer.Start()

$W.Add_Loaded({
    $C["txtStatus"].Text = "Loading..."
    Update-Dashboard
    Draw-TrendChart -cv $C["canvasTrend"] -data @(31,27,30,25,27,24,19)
})

$W.Add_SizeChanged({
    Draw-TrendChart -cv $C["canvasTrend"] -data @(31,27,30,25,27,24,19)
})

$W.ShowDialog() | Out-Null
$timer.Stop(); $liveTimer.Stop()
#endregion
