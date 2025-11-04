<# How To Use:
   Toggle Dark/Light,Click Light Mode / Dark Mode (top-right)
   HTML Report,Click Export HTML Report → opens in browser
   Report Location,C:\TEMP\SCCM GUI TOOL REPORTS\Report_YYYYMMDD_HHmmss.html
#>
#Requires -Version 5.1
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Data.SqlClient

# ========================================
# SCCM Troubleshooting Tool – FINAL with DARK MODE TOGGLE + HTML REPORT
# ========================================

# Install/Import ImportExcel
if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
    try { Install-Module -Name ImportExcel -Force -Scope CurrentUser -ErrorAction Stop }
    catch { [System.Windows.Forms.MessageBox]::Show("Failed to install ImportExcel. Run: Install-Module ImportExcel", "Module Missing") }
}
Import-Module ImportExcel -ErrorAction SilentlyContinue

# Load SCCM Module
$SCCMModulePath = "${env:SMS_ADMIN_UI_PATH}\..\ConfigurationManager.psd1"
if (Test-Path $SCCMModulePath) {
    Import-Module $SCCMModulePath -Force -ErrorAction SilentlyContinue
    $SCCMCmdletsAvailable = $true
} else { $SCCMCmdletsAvailable = $false }

# SQL Settings
$SQLServer = $env:COMPUTERNAME
$Database = "CM_P01"  # CHANGE TO YOUR DB

# Create Form
$form = New-Object System.Windows.Forms.Form
$form.Text = "SCCM Troubleshooting Tool – Dark Mode + HTML Reports"
$form.Size = New-Object System.Drawing.Size(1450, 850)
$form.StartPosition = "CenterScreen"
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

# Mode Persistence
$modeFile = "$env:TEMP\SCCM_GUI_Mode.txt"
$darkMode = if (Test-Path $modeFile) { (Get-Content $modeFile) -eq "Dark" } else { $true }

# Colors
$dark = @{
    Back = [System.Drawing.Color]::FromArgb(30, 30, 30)
    Fore = [System.Drawing.Color]::White
    Panel = [System.Drawing.Color]::FromArgb(45, 45, 48)
    GridBack = [System.Drawing.Color]::FromArgb(30, 30, 30)
    GridFore = [System.Drawing.Color]::White
    HeaderBack = [System.Drawing.Color]::FromArgb(62, 62, 66)
    HeaderFore = [System.Drawing.Color]::White
    ButtonBack = [System.Drawing.Color]::FromArgb(62, 62, 66)
}
$light = @{
    Back = [System.Drawing.Color]::White
    Fore = [System.Drawing.Color]::Black
    Panel = [System.Drawing.Color]::FromArgb(240, 240, 240)
    GridBack = [System.Drawing.Color]::White
    GridFore = [System.Drawing.Color]::Black
    HeaderBack = [System.Drawing.Color]::FromArgb(220, 220, 220)
    HeaderFore = [System.Drawing.Color]::Black
    ButtonBack = [System.Drawing.Color]::FromArgb(200, 200, 200)
}

# Apply Initial Theme
function Set-Theme {
    param([hashtable]$Theme)
    $form.BackColor = $Theme.Back
    $form.ForeColor = $Theme.Fore
    $tabControl.BackColor = $Theme.Panel
    $tabControl.ForeColor = $Theme.Fore
    foreach ($tab in $tabControl.TabPages) {
        $tab.BackColor = $Theme.Back
        foreach ($ctrl in $tab.Controls) {
            if ($ctrl -is [System.Windows.Forms.TextBox] -or $ctrl -is [System.Windows.Forms.Label]) {
                $ctrl.BackColor = $Theme.Panel
                $ctrl.ForeColor = $Theme.Fore
            } elseif ($ctrl -is [System.Windows.Forms.DataGridView]) {
                $ctrl.BackgroundColor = $Theme.GridBack
                $ctrl.DefaultCellStyle.BackColor = $Theme.Panel
                $ctrl.DefaultCellStyle.ForeColor = $Theme.Fore
                $ctrl.ColumnHeadersDefaultCellStyle.BackColor = $Theme.HeaderBack
                $ctrl.ColumnHeadersDefaultCellStyle.ForeColor = $Theme.HeaderFore
                $ctrl.GridColor = if ($darkMode) { [System.Drawing.Color]::FromArgb(60,60,60) } else { [System.Drawing.Color]::LightGray }
                $ctrl.EnableHeadersVisualStyles = $false
            } elseif ($ctrl -is [System.Windows.Forms.Button]) {
                $ctrl.BackColor = $Theme.ButtonBack
                $ctrl.ForeColor = $Theme.Fore
                $ctrl.FlatStyle = "Flat"
                $ctrl.FlatAppearance.BorderColor = if ($darkMode) { [System.Drawing.Color]::Gray } else { [System.Drawing.Color]::DarkGray }
            } elseif ($ctrl -is [System.Windows.Forms.Panel]) {
                $ctrl.BackColor = $Theme.Back
            }
        }
    }
    $btnToggle.Text = if ($darkMode) { "Light Mode" } else { "Dark Mode" }
}
$darkMode = $true
Set-Theme $dark

# ToolTip
$tooltip = New-Object System.Windows.Forms.ToolTip
$tooltip.BackColor = if ($darkMode) { $dark.Panel } else { $light.Panel }
$tooltip.ForeColor = if ($darkMode) { $dark.Fore } else { $light.Fore }

# Tab Control
$tabControl = New-Object System.Windows.Forms.TabControl
$tabControl.Dock = "Fill"
$form.Controls.Add($tabControl)

# Tabs
$tabs = @("Dashboard", "Client Health", "Logs", "Inventory", "Deployments", "Server Update Compliance")
$tabPages = @{}
foreach ($t in $tabs) {
    $tab = New-Object System.Windows.Forms.TabPage
    $tab.Text = $t
    $tab.BackColor = $dark.Back
    $tabPages[$t] = $tab
    $tabControl.TabPages.Add($tab)
}

# Toggle Button (Top-Right)
$btnToggle = New-Object System.Windows.Forms.Button
$btnToggle.Text = "Light Mode"
$btnToggle.Location = New-Object System.Drawing.Point(1250, 10)
$btnToggle.AutoSize = $true
$btnToggle.Add_Click({
    $script:darkMode = -not $darkMode
    Set-Theme $(if ($darkMode) { $dark } else { $light })
    "Dark" | Out-File $modeFile -Force
    $tooltip.BackColor = if ($darkMode) { $dark.Panel } else { $light.Panel }
    $tooltip.ForeColor = if ($darkMode) { $dark.Fore } else { $light.Fore }
})
$form.Controls.Add($btnToggle)
$tooltip.SetToolTip($btnToggle, "Toggle between Dark and Light mode")

# HTML Report Button
$btnHTML = New-Object System.Windows.Forms.Button
$btnHTML.Text = "Export HTML Report"
$btnHTML.Location = New-Object System.Drawing.Point(1100, 10)
$btnHTML.AutoSize = $true
$btnHTML.Add_Click({
    $reportDir = "C:\TEMP\SCCM GUI TOOL REPORTS"
    if (-not (Test-Path $reportDir)) { New-Item $reportDir -ItemType Directory -Force | Out-Null }
    $timestamp = Get-Date -f "yyyyMMdd_HHmmss"
    $htmlPath = "$reportDir\Report_$timestamp.html"

    $html = @"
<!DOCTYPE html>
<html><head><title>SCCM Troubleshooting Report – $timestamp</title>
<style>
    body { font-family: Segoe UI, sans-serif; margin: 20px; background: #f9f9f9; color: #333; }
    h1, h2 { color: #1e88e5; }
    table { width: 100%; border-collapse: collapse; margin: 20px 0; }
    th, td { border: 1px solid #ddd; padding: 10px; text-align: left; }
    th { background: #1e88e5; color: white; }
    tr:nth-child(even) { background: #f2f2f2; }
    .section { margin-bottom: 40px; page-break-after: always; }
    .footer { text-align: center; margin-top: 50px; font-size: 0.8em; color: #777; }
</style></head><body>
<h1>SCCM Troubleshooting Report</h1>
<p><strong>Generated:</strong> $(Get-Date)</p>
<p><strong>Server:</strong> $env:COMPUTERNAME | <strong>Site DB:</strong> $Database</p>
<hr>
"@

    # Helper to add grid data
    function Add-GridToHTML {
        param($Title, $Data)
        if (-not $Data -or $Data.Count -eq 0) {
            $html += "<div class='section'><h2>$Title</h2><p>No data available.</p></div>"
            return
        }
        $html += "<div class='section'><h2>$Title</h2><table><tr>"
        $props = $Data[0].PSObject.Properties.Name
        foreach ($p in $props) { $html += "<th>$p</th>" }
        $html += "</tr>"
        foreach ($row in $Data) {
            $html += "<tr>"
            foreach ($p in $props) {
                $val = $row.$p
                if ($val -is [DateTime]) { $val = $val.ToString("yyyy-MM-dd HH:mm") }
                $val = [System.Web.HttpUtility]::HtmlEncode($val)
                $html += "<td>$val</td>"
            }
            $html += "</tr>"
        }
        $html += "</table></div>"
        return $html
    }

    $script:html = $html
    Add-GridToHTML "Client Health" $global:clientData | Out-Null
    Add-GridToHTML "Software Inventory" $global:invData | Out-Null
    Add-GridToHTML "Deployments" $global:depData | Out-Null
    Add-GridToHTML "Server Update Compliance" $global:compData | Out-Null

    $script:html += "<div class='footer'>Generated by SCCM GUI Tool | $(Get-Date)</div></body></html>"
    $script:html | Out-File $htmlPath -Encoding UTF8
    Start-Process $htmlPath
    [System.Windows.Forms.MessageBox]::Show("HTML Report saved to:`n$htmlPath", "Export Success", "OK", "Information")
})
$form.Controls.Add($btnHTML)
$tooltip.SetToolTip($btnHTML, "Export all current data to a styled HTML report in C:\TEMP\SCCM GUI TOOL REPORTS")

# ========================================
# Helper Functions (unchanged)
# ========================================
function Invoke-SQLQuery { param([string]$Query)
    try {
        $conn = New-Object System.Data.SqlClient.SqlConnection("Server=$SQLServer;Database=$Database;Integrated Security=True;")
        $cmd = New-Object System.Data.SqlClient.SqlCommand($Query, $conn)
        $conn.Open()
        $adapter = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
        $ds = New-Object System.Data.DataSet
        $adapter.Fill($ds) | Out-Null
        $conn.Close()
        return $ds.Tables[0]
    } catch {
        $msg = "SQL Error: $($_.Exception.Message)"
        $msg | Out-File "$env:TEMP\SCCM_Error_$(Get-Date -f 'yyyyMMdd_HHmmss').log" -Append
        return [PSCustomObject]@{ Error = $msg }
    }
}

function Get-SCCMClientInfo { param([string]$ComputerName = $env:COMPUTERNAME)
    try {
        if ($SCCMCmdletsAvailable) {
            $dev = Get-CMDevice -Name $ComputerName -Fast -ErrorAction Stop
            return [PSCustomObject]@{ ComputerName=$ComputerName; ClientInstalled=$true; Version=$dev.ClientVersion; LastHealth=$dev.LastHealthCheckTime; Status="OK (Cmdlet)" }
        }
        $client = Get-CimInstance -Namespace "root\ccm" -ClassName "SMS_Client" -ComputerName $ComputerName -ErrorAction Stop
        return [PSCustomObject]@{ ComputerName=$ComputerName; ClientInstalled=$true; Version=$client.ClientVersion; LastHealth="N/A"; Status="OK (WMI)" }
    } catch {
        return [PSCustomObject]@{ ComputerName=$ComputerName; ClientInstalled=$false; Version="N/A"; LastHealth="N/A"; Status="Error: $($_.Exception.Message)" }
    }
}

function Get-SoftwareInventoryStatus { param([string]$ComputerName)
    try {
        $hw = Get-CimInstance -Namespace "root\ccm\invagt" -ClassName "InventoryActionStatus" -Filter "InventoryActionID='{00000000-0000-0000-0000-000000000001}'" -ComputerName $ComputerName -ErrorAction Stop
        $sw = Get-CimInstance -Namespace "root\ccm\invagt" -ClassName "InventoryActionStatus" -Filter "InventoryActionID='{00000000-0000-0000-0000-000000000002}'" -ComputerName $ComputerName -ErrorAction Stop
        return [PSCustomObject]@{ ComputerName=$ComputerName; LastHardwareScan=$hw.LastCycleTime; LastSoftwareScan=$sw.LastCycleTime; Status="OK" }
    } catch {
        return [PSCustomObject]@{ ComputerName=$ComputerName; LastHardwareScan="N/A"; LastSoftwareScan="N/A"; Status="Error: $($_.Exception.Message)" }
    }
}

function Trigger-InventoryScan { param([string]$ComputerName, [string]$Type)
    $id = if ($Type -eq "Hardware") { "{00000000-0000-0000-0000-000000000001}" } else { "{00000000-0000-0000-0000-000000000002}" }
    try { Invoke-CimMethod -Namespace "root\ccm" -ClassName "SMS_Client" -MethodName "TriggerSchedule" -Arguments @{ sScheduleID = $id } -ComputerName $ComputerName -ErrorAction Stop | Out-Null; return "$Type Scan Triggered" }
    catch { return "Failed: $($_.Exception.Message)" }
}

function Get-DeploymentStatus { param([string]$SiteServer, [string]$SiteCode, [string]$Filter = "*")
    try {
        $ns = "root\sms\site_$SiteCode"
        $deps = Get-CimInstance -ComputerName $SiteServer -Namespace $ns -ClassName "SMS_DeploymentSummary" -Filter "FeatureType=2" -ErrorAction Stop
        return $deps | ForEach-Object {
            [PSCustomObject]@{ Name=$_.SoftwareName; Success=$_.NumberSuccess; Error=$_.NumberErrors; InProgress=$_.NumberInProgress; Total=$_.NumberTargets; Status="OK" }
        } | Where-Object { $_.Name -like "*$Filter*" }
    } catch { return [PSCustomObject]@{ Name="Error"; Status=$_.Exception.Message } }
}

function Get-ServerComplianceDashboard { param([string]$CollectionID = "All")
    $collFilter = if ($CollectionID -eq "All") { "" } else { "AND FCM.CollectionID = '$CollectionID'" }
    $query = @"
SELECT 
    RS.Name0 AS MachineName,
    RS.Resource_Domain_OR_Workgr0 AS Domain,
    STUFF((SELECT '; ' + IP.IP_Addresses0 FROM v_RA_System_IPAddresses IP WHERE IP.ResourceID = RS.ResourceID AND IP.IP_Addresses0 NOT LIKE '%:%' FOR XML PATH('')), 1, 2, '') AS IPv4Address,
    CH.ClientVersion,
    CH.LastEvaluationHealthyTime AS LastHeartbeat,
    STUFF((SELECT '; ' + UI.Title + ' (KB' + UI.ArticleID + ')' FROM v_Update_ComplianceStatus UCS JOIN v_UpdateInfo UI ON UCS.CI_ID = UI.CI_ID WHERE UCS.ResourceID = RS.ResourceID AND UCS.Status = 2 FOR XML PATH('')), 1, 2, '') AS MissingUpdates,
    STUFF((SELECT '; KB' + UI.ArticleID + ': 0x' + CONVERT(VARCHAR(8), UCS.ErrorCode, 2) FROM v_Update_ComplianceStatusAll UCS JOIN v_UpdateInfo UI ON UCS.CI_ID = UI.CI_ID WHERE UCS.ResourceID = RS.ResourceID AND UCS.Status = 4 FOR XML PATH('')), 1, 2, '') AS UpdateErrors
FROM v_R_System RS
JOIN v_GS_OPERATING_SYSTEM OS ON RS.ResourceID = OS.ResourceID
LEFT JOIN v_CH_ClientSummary CH ON RS.ResourceID = CH.ResourceID
LEFT JOIN v_FullCollectionMembership FCM ON RS.ResourceID = FCM.ResourceID
WHERE OS.Caption0 LIKE '%Server%' AND RS.Client0 = 1
$collFilter
ORDER BY RS.Name0
"@
    return Invoke-SQLQuery -Query $query
}

function Export-ToExcel { param($Data, $FileName)
    try {
        $path = [System.Windows.Forms.SaveFileDialog]::new()
        $path.Filter = "Excel Files|*.xlsx"
        $path.FileName = "$FileName.xlsx"
        if ($path.ShowDialog() -eq "OK") {
            $Data | Export-Excel -Path $path.FileName -AutoSize -TableName $FileName -FreezeTopRow -BoldTopRow
            [System.Windows.Forms.MessageBox]::Show("Exported to $($path.FileName)", "Success")
        }
    } catch { [System.Windows.Forms.MessageBox]::Show("Export failed: $($_.Exception.Message)", "Error") }
}

# ========================================
# SEARCH FILTER FUNCTION
# ========================================
function Add-SearchFilter {
    param($Grid, $TabPage, $YPosition = 90)
    $searchPanel = New-Object System.Windows.Forms.Panel
    $searchPanel.Location = New-Object System.Drawing.Point(20, $YPosition)
    $searchPanel.Size = New-Object System.Drawing.Size(1350, 30)
    $searchPanel.BackColor = $dark.Back

    $lblSearch = New-Object System.Windows.Forms.Label
    $lblSearch.Text = "Search:"
    $lblSearch.Location = New-Object System.Drawing.Point(0, 5)
    $lblSearch.AutoSize = $true
    $searchPanel.Controls.Add($lblSearch)

    $txtSearch = New-Object System.Windows.Forms.TextBox
    $txtSearch.Location = New-Object System.Drawing.Point(60, 3)
    $txtSearch.Width = 300
    $searchPanel.Controls.Add($txtSearch)

    $btnClear = New-Object System.Windows.Forms.Button
    $btnClear.Text = "Clear"
    $btnClear.Location = New-Object System.Drawing.Point(370, 1)
    $btnClear.AutoSize = $true
    $searchPanel.Controls.Add($btnClear)

    $originalData = @()
    $txtSearch.Add_TextChanged({
        $filter = $txtSearch.Text.Trim()
        if ($filter -eq "") {
            $Grid.DataSource = $originalData
        } else {
            $filtered = $originalData | Where-Object {
                $row = $_
                $match = $false
                foreach ($prop in $row.PSObject.Properties) {
                    if ($prop.Value -and $prop.Value.ToString() -match [regex]::Escape($filter)) {
                        $match = $true; break
                    }
                }
                $match
            }
            $Grid.DataSource = $filtered
        }
    })

    $btnClear.Add_Click({ $txtSearch.Text = ""; $Grid.DataSource = $originalData })

    $TabPage.Controls.Add($searchPanel)
    return $txtSearch, $originalData
}

# ========================================
# TAB: Client Health
# ========================================
$lblClient = New-Object System.Windows.Forms.Label; $lblClient.Text = "Computers (comma-separated):"; $lblClient.Location = New-Object System.Drawing.Point(20,20); $lblClient.AutoSize = $true
$tabPages["Client Health"].Controls.Add($lblClient)
$txtClient = New-Object System.Windows.Forms.TextBox; $txtClient.Location = New-Object System.Drawing.Point(20,50); $txtClient.Width = 350; $txtClient.Text = $env:COMPUTERNAME
$tabPages["Client Health"].Controls.Add($txtClient)

$btnClient = New-Object System.Windows.Forms.Button; $btnClient.Text = "Check Client Health"; $btnClient.Location = New-Object System.Drawing.Point(380,48); $btnClient.AutoSize = $true
$btnClient.Add_Click({
    $comps = $txtClient.Text -split ',' | ForEach-Object {$_.Trim()}
    $global:clientData = foreach($c in $comps) { Get-SCCMClientInfo -ComputerName $c }
    $gridClient.DataSource = $global:clientData
    $global:clientOriginal = $global:clientData
})
$tooltip.SetToolTip($btnClient, "Check SCCM client health via WMI or Cmdlets.")
$tabPages["Client Health"].Controls.Add($btnClient)

$btnExportClient = New-Object System.Windows.Forms.Button; $btnExportClient.Text = "Export to Excel"; $btnExportClient.Location = New-Object System.Drawing.Point(550,48); $btnExportClient.AutoSize = $true
$btnExportClient.Add_Click({ if ($global:clientData) { Export-ToExcel -Data $global:clientData -FileName "SCCM_Client_Health" } })
$tooltip.SetToolTip($btnExportClient, "Export filtered client health to Excel.")
$tabPages["Client Health"].Controls.Add($btnExportClient)

$gridClient = New-Object System.Windows.Forms.DataGridView; $gridClient.Location = New-Object System.Drawing.Point(20,130); $gridClient.Size = New-Object System.Drawing.Size(1400,360); $gridClient.AutoSizeColumnsMode = "Fill"
$tabPages["Client Health"].Controls.Add($gridClient)

$searchClient = Add-SearchFilter -Grid $gridClient -TabPage $tabPages["Client Health"] -YPosition 90
$global:clientOriginal = @()

# ========================================
# TAB: Logs
# ========================================
$lblLogPath = New-Object System.Windows.Forms.Label; $lblLogPath.Text = "Log Path:"; $lblLogPath.Location = New-Object System.Drawing.Point(20,20); $lblLogPath.AutoSize = $true
$tabPages["Logs"].Controls.Add($lblLogPath)
$txtLogPath = New-Object System.Windows.Forms.TextBox; $txtLogPath.Location = New-Object System.Drawing.Point(20,50); $txtLogPath.Width = 550; $txtLogPath.Text = "\\$env:COMPUTERNAME\ADMIN$\ccm\logs"
$tabPages["Logs"].Controls.Add($txtLogPath)

$btnBrowse = New-Object System.Windows.Forms.Button; $btnBrowse.Text = "Browse Folder"; $btnBrowse.Location = New-Object System.Drawing.Point(580,48); $btnBrowse.AutoSize = $true
$btnBrowse.Add_Click({ $fb = New-Object System.Windows.Forms.FolderBrowserDialog; if ($fb.ShowDialog() -eq "OK") { $txtLogPath.Text = $fb.SelectedPath } })
$tooltip.SetToolTip($btnBrowse, "Browse to log directory.")
$tabPages["Logs"].Controls.Add($btnBrowse)

$btnLoad = New-Object System.Windows.Forms.Button; $btnLoad.Text = "Load Log Files"; $btnLoad.Location = New-Object System.Drawing.Point(720,48); $btnLoad.AutoSize = $true
$btnLoad.Add_Click({
    if (Test-Path $txtLogPath.Text) {
        $logs = Get-ChildItem "$($txtLogPath.Text)\*.log" | Select Name, LastWriteTime, @{Name="SizeKB";Expression={[math]::Round($_.Length/1KB,2)}}
        $global:logOriginal = $logs
        $listLogs.DataSource = $logs
    }
})
$tooltip.SetToolTip($btnLoad, "List all .log files.")
$tabPages["Logs"].Controls.Add($btnLoad)

$btnCMTrace = New-Object System.Windows.Forms.Button; $btnCMTrace.Text = "Open in CMTrace"; $btnCMTrace.Location = New-Object System.Drawing.Point(850,48); $btnCMTrace.AutoSize = $true
$btnCMTrace.Add_Click({
    $sel = $listLogs.SelectedItems[0]
    if ($sel) {
        $file = Join-Path $txtLogPath.Text $sel.Name
        $cmtrace = "C:\Windows\CCM\CMTrace.exe"
        if (Test-Path $cmtrace) { Start-Process $cmtrace "`"$file`"" } else { [System.Windows.Forms.MessageBox]::Show("CMTrace not found", "Error") }
    }
})
$tooltip.SetToolTip($btnCMTrace, "Open log in CMTrace.")
$tabPages["Logs"].Controls.Add($btnCMTrace)

$listLogs = New-Object System.Windows.Forms.ListView; $listLogs.Location = New-Object System.Drawing.Point(20,90); $listLogs.Size = New-Object System.Drawing.Size(500,400); $listLogs.View = "Details"; $listLogs.FullRowSelect = $true
$listLogs.Columns.Add("Name",300); $listLogs.Columns.Add("Modified",150); $listLogs.Columns.Add("SizeKB",100)
$tabPages["Logs"].Controls.Add($listLogs)

$txtLogView = New-Object System.Windows.Forms.TextBox; $txtLogView.Location = New-Object System.Drawing.Point(530,90); $txtLogView.Size = New-Object System.Drawing.Size(840,400); $txtLogView.Multiline = $true; $txtLogView.ScrollBars = "Vertical"; $txtLogView.Font = New-Object System.Drawing.Font("Consolas",9)
$tabPages["Logs"].Controls.Add($txtLogView)
$listLogs.Add_DoubleClick({ $sel = $listLogs.SelectedItems[0]; if ($sel) { $txtLogView.Text = (Get-Content (Join-Path $txtLogPath.Text $sel.Name) -Tail 500) -join "`r`n" } })

# Search for ListView
$searchLogPanel = New-Object System.Windows.Forms.Panel; $searchLogPanel.Location = New-Object System.Drawing.Point(20, 500); $searchLogPanel.Size = New-Object System.Drawing.Size(500, 30)
$lblLogSearch = New-Object System.Windows.Forms.Label; $lblLogSearch.Text = "Search Logs:"; $lblLogSearch.Location = New-Object System.Drawing.Point(0,5); $lblLogSearch.AutoSize = $true
$searchLogPanel.Controls.Add($lblLogSearch)
$txtLogSearch = New-Object System.Windows.Forms.TextBox; $txtLogSearch.Location = New-Object System.Drawing.Point(80,3); $txtLogSearch.Width = 300
$searchLogPanel.Controls.Add($txtLogSearch)
$btnClearLog = New-Object System.Windows.Forms.Button; $btnClearLog.Text = "Clear"; $btnClearLog.Location = New-Object System.Drawing.Point(390,1); $btnClearLog.AutoSize = $true
$searchLogPanel.Controls.Add($btnClearLog)
$tabPages["Logs"].Controls.Add($searchLogPanel)

$global:logOriginal = @()
$txtLogSearch.Add_TextChanged({
    $filter = $txtLogSearch.Text.Trim()
    if ($filter -eq "" -or -not $global:logOriginal) {
        $listLogs.DataSource = $global:logOriginal
    } else {
        $filtered = $global:logOriginal | Where-Object {
            $_.Name -match [regex]::Escape($filter) -or
            $_.LastWriteTime.ToString() -match [regex]::Escape($filter) -or
            $_.SizeKB.ToString() -match [regex]::Escape($filter)
        }
        $listLogs.DataSource = $filtered
    }
})
$btnClearLog.Add_Click({ $txtLogSearch.Text = ""; $listLogs.DataSource = $global:logOriginal })

# ========================================
# TAB: Inventory
# ========================================
$lblInv = New-Object System.Windows.Forms.Label; $lblInv.Text = "Computer:"; $lblInv.Location = New-Object System.Drawing.Point(20,20); $lblInv.AutoSize = $true
$tabPages["Inventory"].Controls.Add($lblInv)
$txtInv = New-Object System.Windows.Forms.TextBox; $txtInv.Location = New-Object System.Drawing.Point(20,50); $txtInv.Width = 250; $txtInv.Text = $env:COMPUTERNAME
$tabPages["Inventory"].Controls.Add($txtInv)

$btnInv = New-Object System.Windows.Forms.Button; $btnInv.Text = "Check Inventory Status"; $btnInv.Location = New-Object System.Drawing.Point(280,48); $btnInv.AutoSize = $true
$btnInv.Add_Click({ $global:invData = Get-SoftwareInventoryStatus -ComputerName $txtInv.Text; $gridInv.DataSource = @($global:invData); $global:invOriginal = $global:invData })
$tooltip.SetToolTip($btnInv, "Show last HW/SW scan times.")
$tabPages["Inventory"].Controls.Add($btnInv)

$btnHW = New-Object System.Windows.Forms.Button; $btnHW.Text = "Trigger Hardware Scan"; $btnHW.Location = New-Object System.Drawing.Point(20,90); $btnHW.AutoSize = $true
$btnHW.Add_Click({ [System.Windows.Forms.MessageBox]::Show((Trigger-InventoryScan -ComputerName $txtInv.Text -Type "Hardware")) })
$tooltip.SetToolTip($btnHW, "Force hardware scan.")
$tabPages["Inventory"].Controls.Add($btnHW)

$btnSW = New-Object System.Windows.Forms.Button; $btnSW.Text = "Trigger Software Scan"; $btnSW.Location = New-Object System.Drawing.Point(180,90); $btnSW.AutoSize = $true
$btnSW.Add_Click({ [System.Windows.Forms.MessageBox]::Show((Trigger-InventoryScan -ComputerName $txtInv.Text -Type "Software")) })
$tooltip.SetToolTip($btnSW, "Force software scan.")
$tabPages["Inventory"].Controls.Add($btnSW)

$btnExportInv = New-Object System.Windows.Forms.Button; $btnExportInv.Text = "Export to Excel"; $btnExportInv.Location = New-Object System.Drawing.Point(350,88); $btnExportInv.AutoSize = $true
$btnExportInv.Add_Click({ if ($global:invData) { Export-ToExcel -Data @($global:invData) -FileName "SCCM_Inventory" } })
$tooltip.SetToolTip($btnExportInv, "Export filtered inventory.")
$tabPages["Inventory"].Controls.Add($btnExportInv)

$gridInv = New-Object System.Windows.Forms.DataGridView; $gridInv.Location = New-Object System.Drawing.Point(20,170); $gridInv.Size = New-Object System.Drawing.Size(1400,310); $gridInv.AutoSizeColumnsMode = "Fill"
$tabPages["Inventory"].Controls.Add($gridInv)

$searchInv = Add-SearchFilter -Grid $gridInv -TabPage $tabPages["Inventory"] -YPosition 130
$global:invOriginal = @()

# ========================================
# TAB: Deployments
# ========================================
$lblDepSrv = New-Object System.Windows.Forms.Label; $lblDepSrv.Text = "Site Server:"; $lblDepSrv.Location = New-Object System.Drawing.Point(20,20); $lblDepSrv.AutoSize = $true
$tabPages["Deployments"].Controls.Add($lblDepSrv)
$txtDepSrv = New-Object System.Windows.Forms.TextBox; $txtDepSrv.Location = New-Object System.Drawing.Point(20,50); $txtDepSrv.Width = 200
$tabPages["Deployments"].Controls.Add($txtDepSrv)

$lblDepCode = New-Object System.Windows.Forms.Label; $lblDepCode.Text = "Site Code:"; $lblDepCode.Location = New-Object System.Drawing.Point(230,20); $lblDepCode.AutoSize = $true
$tabPages["Deployments"].Controls.Add($lblDepCode)
$txtDepCode = New-Object System.Windows.Forms.TextBox; $txtDepCode.Location = New-Object System.Drawing.Point(230,50); $txtDepCode.Width = 80
$tabPages["Deployments"].Controls.Add($txtDepCode)

$lblDepFilter = New-Object System.Windows.Forms.Label; $lblDepFilter.Text = "Name Filter:"; $lblDepFilter.Location = New-Object System.Drawing.Point(320,20); $lblDepFilter.AutoSize = $true
$tabPages["Deployments"].Controls.Add($lblDepFilter)
$txtDepFilter = New-Object System.Windows.Forms.TextBox; $txtDepFilter.Location = New-Object System.Drawing.Point(320,50); $txtDepFilter.Width = 180; $txtDepFilter.Text = "*"
$tabPages["Deployments"].Controls.Add($txtDepFilter)

$btnDep = New-Object System.Windows.Forms.Button; $btnDep.Text = "Load Deployment Status"; $btnDep.Location = New-Object System.Drawing.Point(510,48); $btnDep.AutoSize = $true
$btnDep.Add_Click({ $global:depData = Get-DeploymentStatus -SiteServer $txtDepSrv.Text -SiteCode $txtDepCode.Text -Filter $txtDepFilter.Text; $gridDep.DataSource = $global:depData; $global:depOriginal = $global:depData })
$tooltip.SetToolTip($btnDep, "Load deployment success/failure.")
$tabPages["Deployments"].Controls.Add($btnDep)

$btnExportDep = New-Object System.Windows.Forms.Button; $btnExportDep.Text = "Export to Excel"; $btnExportDep.Location = New-Object System.Drawing.Point(680,48); $btnExportDep.AutoSize = $true
$btnExportDep.Add_Click({ if ($global:depData) { Export-ToExcel -Data $global:depData -FileName "SCCM_Deployments" } })
$tooltip.SetToolTip($btnExportDep, "Export filtered deployments.")
$tabPages["Deployments"].Controls.Add($btnExportDep)

$gridDep = New-Object System.Windows.Forms.DataGridView; $gridDep.Location = New-Object System.Drawing.Point(20,130); $gridDep.Size = New-Object System.Drawing.Size(1400,360); $gridDep.AutoSizeColumnsMode = "Fill"
$tabPages["Deployments"].Controls.Add($gridDep)

$searchDep = Add-SearchFilter -Grid $gridDep -TabPage $tabPages["Deployments"] -YPosition 90
$global:depOriginal = @()

# ========================================
# TAB: Server Update Compliance
# ========================================
$lblColl = New-Object System.Windows.Forms.Label; $lblColl.Text = "Collection ID ('All' for all servers):"; $lblColl.Location = New-Object System.Drawing.Point(20,20); $lblColl.AutoSize = $true
$tabPages["Server Update Compliance"].Controls.Add($lblColl)
$txtColl = New-Object System.Windows.Forms.TextBox; $txtColl.Location = New-Object System.Drawing.Point(20,50); $txtColl.Width = 250; $txtColl.Text = "All"
$tabPages["Server Update Compliance"].Controls.Add($txtColl)

$btnLoadComp = New-Object System.Windows.Forms.Button; $btnLoadComp.Text = "Load Server Compliance Dashboard"; $btnLoadComp.Location = New-Object System.Drawing.Point(280,48); $btnLoadComp.AutoSize = $true
$btnLoadComp.Add_Click({ $global:compData = Get-ServerComplianceDashboard -CollectionID $txtColl.Text; $gridComp.DataSource = $global:compData; $global:compOriginal = $global:compData })
$tooltip.SetToolTip($btnLoadComp, "Full Patch Tuesday report.")
$tabPages["Server Update Compliance"].Controls.Add($btnLoadComp)

$btnExportComp = New-Object System.Windows.Forms.Button; $btnExportComp.Text = "Export to Excel"; $btnExportComp.Location = New-Object System.Drawing.Point(520,48); $btnExportComp.AutoSize = $true
$btnExportComp.Add_Click({ if ($global:compData) { Export-ToExcel -Data $global:compData -FileName "SCCM_Server_Update_Compliance" } })
$tooltip.SetToolTip($btnExportComp, "Export filtered compliance.")
$tabPages["Server Update Compliance"].Controls.Add($btnExportComp)

$gridComp = New-Object System.Windows.Forms.DataGridView; $gridComp.Location = New-Object System.Drawing.Point(20,130); $gridComp.Size = New-Object System.Drawing.Size(1400,560); $gridComp.AutoSizeColumnsMode = "Fill"
$tabPages["Server Update Compliance"].Controls.Add($gridComp)

$searchComp = Add-SearchFilter -Grid $gridComp -TabPage $tabPages["Server Update Compliance"] -YPosition 90
$global:compOriginal = @()

# ========================================
# Show Form
# ========================================
$form.ShowDialog() | Out-Null
