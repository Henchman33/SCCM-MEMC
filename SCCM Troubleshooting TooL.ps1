#Requires -Version 5.1
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Data.SqlClient

# ========================================
# SCCM Troubleshooting Tool – FINAL (visible toggle + HTML export + VISIBLE TABS)
# ========================================

# Install/Import ImportExcel
if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
    try { Install-Module -Name ImportExcel -Force -Scope CurrentUser -ErrorAction Stop }
    catch { [System.Windows.Forms.MessageBox]::Show("Failed to install ImportExcel.", "Module Missing") }
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
$Database   = "CM_P01"          # <<< CHANGE TO YOUR DB

# -------------------------------
# Form
# -------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text  = "SCCM Troubleshooting Tool – Dark Mode + HTML Reports"
$form.Size  = New-Object System.Drawing.Size(1450,850)
$form.StartPosition = "CenterScreen"
$form.Font  = New-Object System.Drawing.Font("Segoe UI",9)

# -------------------------------
# Theme persistence
# -------------------------------
$modeFile = "$env:TEMP\SCCM_GUI_Mode.txt"
$script:darkMode = if (Test-Path $modeFile) { (Get-Content $modeFile) -eq "Dark" } else { $true }

# -------------------------------
# Colour tables
# -------------------------------
$dark = @{
    Back   = [System.Drawing.Color]::FromArgb(30,30,30)
    Fore   = [System.Drawing.Color]::White
    Panel  = [System.Drawing.Color]::FromArgb(45,45,48)
    GridB  = [System.Drawing.Color]::FromArgb(30,30,30)
    GridF  = [System.Drawing.Color]::White
    HeadB  = [System.Drawing.Color]::FromArgb(62,62,66)
    HeadF  = [System.Drawing.Color]::White
    BtnB   = [System.Drawing.Color]::FromArgb(62,62,66)
}
$light = @{
    Back   = [System.Drawing.Color]::White
    Fore   = [System.Drawing.Color]::Black
    Panel  = [System.Drawing.Color]::FromArgb(240,240,240)
    GridB  = [System.Drawing.Color]::White
    GridF  = [System.Drawing.Color]::Black
    HeadB  = [System.Drawing.Color]::FromArgb(220,220,220)
    HeadF  = [System.Drawing.Color]::Black
    BtnB   = [System.Drawing.Color]::FromArgb(200,200,200)
}

# -------------------------------
# Theme applicator
# -------------------------------
function Set-Theme {
    param([hashtable]$t)
    $form.BackColor                = $t.Back
    $form.ForeColor                = $t.Fore
    $topPanel.BackColor            = $t.Back
    $tabControl.BackColor          = $t.Panel
    $tabControl.ForeColor          = $t.Fore

    foreach ($tab in $tabControl.TabPages) {
        $tab.BackColor = $t.Back
        foreach ($c in $tab.Controls) {
            if ($c -is [System.Windows.Forms.TextBox] -or $c -is [System.Windows.Forms.Label]) {
                $c.BackColor = $t.Panel; $c.ForeColor = $t.Fore
            }
            elseif ($c -is [System.Windows.Forms.DataGridView]) {
                $c.BackgroundColor = $t.GridB
                $c.DefaultCellStyle.BackColor = $t.Panel
                $c.DefaultCellStyle.ForeColor = $t.Fore
                $c.ColumnHeadersDefaultCellStyle.BackColor = $t.HeadB
                $c.ColumnHeadersDefaultCellStyle.ForeColor = $t.HeadF
                $c.GridColor = if ($script:darkMode) {[System.Drawing.Color]::FromArgb(60,60,60)} else {[System.Drawing.Color]::LightGray}
                $c.EnableHeadersVisualStyles = $false
            }
            elseif ($c -is [System.Windows.Forms.Button]) {
                $c.BackColor = $t.BtnB; $c.ForeColor = $t.Fore
                $c.FlatStyle = "Flat"
                $c.FlatAppearance.BorderColor = if ($script:darkMode) {[System.Drawing.Color]::Gray} else {[System.Drawing.Color]::DarkGray}
            }
            elseif ($c -is [System.Windows.Forms.Panel]) {
                $c.BackColor = $t.Back
            }
        }
    }
    $btnToggle.Text = if ($script:darkMode) {"Light Mode"} else {"Dark Mode"}
}
Set-Theme $dark

# -------------------------------
# Tooltip
# -------------------------------
$tooltip = New-Object System.Windows.Forms.ToolTip
$tooltip.BackColor = $dark.Panel
$tooltip.ForeColor = $dark.Fore

# -------------------------------
# Tab control (fills the rest)
# -------------------------------
$tabControl = New-Object System.Windows.Forms.TabControl
$tabControl.Dock = "Fill"
$tabControl.BackColor = $dark.Panel
$tabControl.ForeColor = $dark.Fore
$form.Controls.Add($tabControl)   # ← ADDED FIRST

# -------------------------------
# Top panel (global buttons) – added AFTER tab control
# -------------------------------
$topPanel = New-Object System.Windows.Forms.Panel
$topPanel.Height = 50
$topPanel.BackColor = $dark.Back
$topPanel.Dock = "Top"            # ← forces it to the top
$form.Controls.Add($topPanel)     # ← ADDED SECOND

# -------------------------------
# Tabs
# -------------------------------
$tabs = @("Dashboard","Client Health","Logs","Inventory","Deployments","Server Update Compliance")
$tabPages = @{}
foreach ($t in $tabs) {
    $p = New-Object System.Windows.Forms.TabPage
    $p.Text = $t
    $p.BackColor = $dark.Back
    $tabPages[$t] = $p
    $tabControl.TabPages.Add($p)
}

# -------------------------------
# Dark/Light toggle button
# -------------------------------
$btnToggle = New-Object System.Windows.Forms.Button
$btnToggle.Text = "Light Mode"
$btnToggle.Location = New-Object System.Drawing.Point(1200,10)
$btnToggle.AutoSize = $true
$btnToggle.Add_Click({
    $script:darkMode = -not $script:darkMode
    Set-Theme $(if ($script:darkMode) {$dark} else {$light})
    if ($script:darkMode) { "Dark" | Out-File $modeFile -Force } else { "Light" | Out-File $modeFile -Force }
    $tooltip.BackColor = if ($script:darkMode) {$dark.Panel} else {$light.Panel}
    $tooltip.ForeColor = if ($script:darkMode) {$dark.Fore} else {$light.Fore}
})
$topPanel.Controls.Add($btnToggle)
$tooltip.SetToolTip($btnToggle,"Toggle Dark / Light mode")

# -------------------------------
# HTML export button
# -------------------------------
$btnHTML = New-Object System.Windows.Forms.Button
$btnHTML.Text = "Export HTML Report"
$btnHTML.Location = New-Object System.Drawing.Point(1050,10)
$btnHTML.AutoSize = $true
$btnHTML.Add_Click({
    $dir = "C:\TEMP\SCCM GUI TOOL REPORTS"
    if(-not (Test-Path $dir)) { New-Item $dir -ItemType Directory -Force | Out-Null }
    $ts  = Get-Date -Format "yyyyMMdd_HHmmss"
    $path= "$dir\Report_$ts.html"

    $html = @"
<!DOCTYPE html><html><head><title>SCCM Report – $ts</title>
<style>
    body{font-family:Segoe UI;margin:20px;background:#f9f9f9;color:#333}
    h1,h2{color:#1e88e5}
    table{width:100%;border-collapse:collapse;margin:20px 0}
    th,td{border:1px solid #ddd;padding:10px;text-align:left}
    th{background:#1e88e5;color:#fff}
    tr:nth-child(even){background:#f2f2f2}
    .section{margin-bottom:40px}
</style></head><body>
<h1>SCCM Troubleshooting Report</h1>
<p><strong>Generated:</strong> $(Get-Date)</p>
<p><strong>Server:</strong> $env:COMPUTERNAME | <strong>DB:</strong> $Database</p><hr>
"@

    function Add-Grid { param($title,$data)
        if(-not $data -or $data.Count -eq 0){ $html+="<div class='section'><h2>$title</h2><p>No data.</p></div>"; return }
        $html+="<div class='section'><h2>$title</h2><table><tr>"
        $data[0].PSObject.Properties.Name | % { $html+="<th>$_</th>" }
        $html+="</tr>"
        foreach($r in $data){
            $html+="<tr>"
            $data[0].PSObject.Properties.Name | % {
                $v = $r.$_
                if($v -is [datetime]){$v=$v.ToString("yyyy-MM-dd HH:mm")}
                $v=[System.Web.HttpUtility]::HtmlEncode($v)
                $html+="<td>$v</td>"
            }
            $html+="</tr>"
        }
        $html+="</table></div>"
    }

    $script:html = $html
    Add-Grid "Client Health"          $global:clientData
    Add-Grid "Inventory"              $global:invData
    Add-Grid "Deployments"            $global:depData
    Add-Grid "Server Update Compliance" $global:compData

    $script:html += "<p style='text-align:center;color:#777;font-size:0.8em'>Generated by SCCM GUI Tool</p></body></html>"
    $script:html | Out-File $path -Encoding UTF8
    Start-Process $path
    [System.Windows.Forms.MessageBox]::Show("HTML saved:`n$path","Success")
})
$topPanel.Controls.Add($btnHTML)
$tooltip.SetToolTip($btnHTML,"Export all current grids to HTML (C:\TEMP\SCCM GUI TOOL REPORTS)")

# ========================================
# Helper functions (unchanged)
# ========================================
function Invoke-SQLQuery { param([string]$q)
    try{
        $c = New-Object System.Data.SqlClient.SqlConnection("Server=$SQLServer;Database=$Database;Integrated Security=True;")
        $d = New-Object System.Data.SqlClient.SqlCommand($q,$c)
        $c.Open()
        $a = New-Object System.Data.SqlClient.SqlDataAdapter($d)
        $s = New-Object System.Data.DataSet
        $a.Fill($s)|Out-Null
        $c.Close()
        $s.Tables[0]
    }catch{
        $msg="SQL Error: $($_.Exception.Message)"
        $msg|Out-File "$env:TEMP\SCCM_Error_$(Get-Date -f 'yyyyMMdd_HHmmss').log" -Append
        [pscustomobject]@{Error=$msg}
    }
}
function Get-SCCMClientInfo { param([string]$ComputerName=$env:COMPUTERNAME)
    try{
        if($SCCMCmdletsAvailable){
            $d=Get-CMDevice -Name $ComputerName -Fast -ErrorAction Stop
            [pscustomobject]@{ComputerName=$ComputerName;ClientInstalled=$true;Version=$d.ClientVersion;LastHealth=$d.LastHealthCheckTime;Status="OK (Cmdlet)"}
        }else{
            $c=Get-CimInstance -Namespace root\ccm -ClassName SMS_Client -ComputerName $ComputerName -ErrorAction Stop
            [pscustomobject]@{ComputerName=$ComputerName;ClientInstalled=$true;Version=$c.ClientVersion;LastHealth="N/A";Status="OK (WMI)"}
        }
    }catch{
        [pscustomobject]@{ComputerName=$ComputerName;ClientInstalled=$false;Version="N/A";LastHealth="N/A";Status="Error: $($_.Exception.Message)"}
    }
}
function Get-SoftwareInventoryStatus { param([string]$ComputerName)
    try{
        $hw=Get-CimInstance -Namespace root\ccm\invagt -ClassName InventoryActionStatus -Filter "InventoryActionID='{00000000-0000-0000-0000-000000000001}'" -ComputerName $ComputerName -ErrorAction Stop
        $sw=Get-CimInstance -Namespace root\ccm\invagt -ClassName InventoryActionStatus -Filter "InventoryActionID='{00000000-0000-0000-0000-000000000002}'" -ComputerName $ComputerName -ErrorAction Stop
        [pscustomobject]@{ComputerName=$ComputerName;LastHardwareScan=$hw.LastCycleTime;LastSoftwareScan=$sw.LastCycleTime;Status="OK"}
    }catch{
        [pscustomobject]@{ComputerName=$ComputerName;LastHardwareScan="N/A";LastSoftwareScan="N/A";Status="Error: $($_.Exception.Message)"}
    }
}
function Trigger-InventoryScan { param([string]$ComputerName,[string]$Type)
    $id = if($Type -eq "Hardware"){"{00000000-0000-0000-0000-000000000001}"}else{"{00000000-0000-0000-0000-000000000002}"}
    try{Invoke-CimMethod -Namespace root\ccm -ClassName SMS_Client -MethodName TriggerSchedule -Arguments @{sScheduleID=$id} -ComputerName $ComputerName -ErrorAction Stop|Out-Null;"$Type Scan Triggered"}catch{"Failed: $($_.Exception.Message)"}
}
function Get-DeploymentStatus { param([string]$SiteServer,[string]$SiteCode,[string]$Filter="*")
    try{
        $ns="root\sms\site_$SiteCode"
        $d=Get-CimInstance -ComputerName $SiteServer -Namespace $ns -ClassName SMS_DeploymentSummary -Filter "FeatureType=2" -ErrorAction Stop
        $d|%{
            [pscustomobject]@{Name=$_.SoftwareName;Success=$_.NumberSuccess;Error=$_.NumberErrors;InProgress=$_.NumberInProgress;Total=$_.NumberTargets;Status="OK"}
        }|Where{$_.Name -like "*$Filter*"}
    }catch{[pscustomobject]@{Name="Error";Status=$_.Exception.Message}}
}
function Get-ServerComplianceDashboard { param([string]$CollectionID="All")
    $cf = if($CollectionID -eq "All"){""}else{"AND FCM.CollectionID='$CollectionID'"}
    $q = @"
SELECT RS.Name0 AS MachineName,
       RS.Resource_Domain_OR_Workgr0 AS Domain,
       STUFF((SELECT '; ' + IP.IP_Addresses0 FROM v_RA_System_IPAddresses IP WHERE IP.ResourceID=RS.ResourceID AND IP.IP_Addresses0 NOT LIKE '%:%' FOR XML PATH('')),1,2,'') AS IPv4Address,
       CH.ClientVersion,
       CH.LastEvaluationHealthyTime AS LastHeartbeat,
       STUFF((SELECT '; ' + UI.Title + ' (KB' + UI.ArticleID + ')' FROM v_Update_ComplianceStatus UCS JOIN v_UpdateInfo UI ON UCS.CI_ID=UI.CI_ID WHERE UCS.ResourceID=RS.ResourceID AND UCS.Status=2 FOR XML PATH('')),1,2,'') AS MissingUpdates,
       STUFF((SELECT '; KB' + UI.ArticleID + ': 0x' + CONVERT(VARCHAR(8),UCS.ErrorCode,2) FROM v_Update_ComplianceStatusAll UCS JOIN v_UpdateInfo UI ON UCS.CI_ID=UI.CI_ID WHERE UCS.ResourceID=RS.ResourceID AND UCS.Status=4 FOR XML PATH('')),1,2,'') AS UpdateErrors
FROM v_R_System RS
JOIN v_GS_OPERATING_SYSTEM OS ON RS.ResourceID=OS.ResourceID
LEFT JOIN v_CH_ClientSummary CH ON RS.ResourceID=CH.ResourceID
LEFT JOIN v_FullCollectionMembership FCM ON RS.ResourceID=FCM.ResourceID
WHERE OS.Caption0 LIKE '%Server%' AND RS.Client0=1 $cf
ORDER BY RS.Name0
"@
    Invoke-SQLQuery $q
}
function Export-ToExcel { param($Data,$FileName)
    $dlg = [System.Windows.Forms.SaveFileDialog]::new()
    $dlg.Filter = "Excel Files|*.xlsx"
    $dlg.FileName = "$FileName.xlsx"
    if($dlg.ShowDialog() -eq "OK"){
        $Data|Export-Excel -Path $dlg.FileName -AutoSize -TableName $FileName -FreezeTopRow -BoldTopRow
        [System.Windows.Forms.MessageBox]::Show("Exported to $($dlg.FileName)","Success")
    }
}

# ========================================
# Search filter (universal)
# ========================================
function Add-SearchFilter {
    param($Grid,$Tab,$Y=90)
    $p = New-Object System.Windows.Forms.Panel
    $p.Location = New-Object System.Drawing.Point(20,$Y)
    $p.Size     = New-Object System.Drawing.Size(1350,30)
    $p.BackColor = $dark.Back

    $l = New-Object System.Windows.Forms.Label; $l.Text="Search:"; $l.Location=New-Object System.Drawing.Point(0,5); $l.AutoSize=$true; $p.Controls.Add($l)
    $t = New-Object System.Windows.Forms.TextBox; $t.Location=New-Object System.Drawing.Point(60,3); $t.Width=300; $p.Controls.Add($t)
    $c = New-Object System.Windows.Forms.Button; $c.Text="Clear"; $c.Location=New-Object System.Drawing.Point(370,1); $c.AutoSize=$true; $p.Controls.Add($c)

    $orig = @()
    $t.Add_TextChanged({
        $f=$t.Text.Trim()
        if($f -eq ""){$Grid.DataSource=$orig}
        else{
            $Grid.DataSource = $orig|Where{
                $r=$_; $m=$false
                foreach($prop in $r.PSObject.Properties){
                    if($prop.Value -and $prop.Value.ToString() -match [regex]::Escape($f)){$m=$true;break}
                };$m
            }
        }
    })
    $c.Add_Click({$t.Text="";$Grid.DataSource=$orig})
    $Tab.Controls.Add($p)
    return $t,$orig
}

# ========================================
# TAB: Client Health
# ========================================
$l = New-Object System.Windows.Forms.Label; $l.Text="Computers (comma-separated):"; $l.Location=New-Object System.Drawing.Point(20,20); $l.AutoSize=$true
$tabPages["Client Health"].Controls.Add($l)
$txtC = New-Object System.Windows.Forms.TextBox; $txtC.Location=New-Object System.Drawing.Point(20,50); $txtC.Width=350; $txtC.Text=$env:COMPUTERNAME
$tabPages["Client Health"].Controls.Add($txtC)

$btnC = New-Object System.Windows.Forms.Button; $btnC.Text="Check Client Health"; $btnC.Location=New-Object System.Drawing.Point(380,48); $btnC.AutoSize=$true
$btnC.Add_Click({ $global:clientData = $txtC.Text -split ','|%{$_.Trim()}|%{Get-SCCMClientInfo -ComputerName $_}; $gridC.DataSource = $global:clientData; $global:clientOrig = $global:clientData })
$tooltip.SetToolTip($btnC,"Query client health via WMI or Cmdlets")
$tabPages["Client Health"].Controls.Add($btnC)

$btnEC = New-Object System.Windows.Forms.Button; $btnEC.Text="Export to Excel"; $btnEC.Location=New-Object System.Drawing.Point(550,48); $btnEC.AutoSize=$true
$btnEC.Add_Click({ if($global:clientData){Export-ToExcel $global:clientData "SCCM_Client_Health"} })
$tooltip.SetToolTip($btnEC,"Export filtered results")
$tabPages["Client Health"].Controls.Add($btnEC)

$gridC = New-Object System.Windows.Forms.DataGridView; $gridC.Location=New-Object System.Drawing.Point(20,130); $gridC.Size=New-Object System.Drawing.Size(1400,360); $gridC.AutoSizeColumnsMode="Fill"
$tabPages["Client Health"].Controls.Add($gridC)

Add-SearchFilter -Grid $gridC -Tab $tabPages["Client Health"] -Y 90 | Out-Null
$global:clientOrig = @()

# ========================================
# TAB: Logs
# ========================================
$l = New-Object System.Windows.Forms.Label; $l.Text="Log Path:"; $l.Location=New-Object System.Drawing.Point(20,20); $l.AutoSize=$true
$tabPages["Logs"].Controls.Add($l)
$txtL = New-Object System.Windows.Forms.TextBox; $txtL.Location=New-Object System.Drawing.Point(20,50); $txtL.Width=550; $txtL.Text="\\$env:COMPUTERNAME\ADMIN$\ccm\logs"
$tabPages["Logs"].Controls.Add($txtL)

$btnB = New-Object System.Windows.Forms.Button; $btnB.Text="Browse Folder"; $btnB.Location=New-Object System.Drawing.Point(580,48); $btnB.AutoSize=$true
$btnB.Add_Click({$fb=New-Object System.Windows.Forms.FolderBrowserDialog; if($fb.ShowDialog() -eq "OK"){$txtL.Text=$fb.SelectedPath}})
$tooltip.SetToolTip($btnB,"Select log folder")
$tabPages["Logs"].Controls.Add($btnB)

$btnLoad = New-Object System.Windows.Forms.Button; $btnLoad.Text="Load Log Files"; $btnLoad.Location=New-Object System.Drawing.Point(720,48); $btnLoad.AutoSize=$true
$btnLoad.Add_Click({if(Test-Path $txtL.Text){$global:logOrig = Get-ChildItem "$($txtL.Text)\*.log"|Select Name,LastWriteTime,@{N="SizeKB";E={[math]::Round($_.Length/1KB,2)}}; $listL.DataSource = $global:logOrig}})
$tooltip.SetToolTip($btnLoad,"List .log files")
$tabPages["Logs"].Controls.Add($btnLoad)

$btnCM = New-Object System.Windows.Forms.Button; $btnCM.Text="Open in CMTrace"; $btnCM.Location=New-Object System.Drawing.Point(850,48); $btnCM.AutoSize=$true
$btnCM.Add_Click({$s=$listL.SelectedItems[0]; if($s){$f=Join-Path $txtL.Text $s.Name; $cm="C:\Windows\CCM\CMTrace.exe"; if(Test-Path $cm){Start-Process $cm "`"$f`""}else{[System.Windows.Forms.MessageBox]::Show("CMTrace not found","Error")}}})
$tooltip.SetToolTip($btnCM,"Open selected log in CMTrace")
$tabPages["Logs"].Controls.Add($btnCM)

$listL = New-Object System.Windows.Forms.ListView; $listL.Location=New-Object System.Drawing.Point(20,90); $listL.Size=New-Object System.Drawing.Size(500,400); $listL.View="Details"; $listL.FullRowSelect=$true
$listL.Columns.Add("Name",300); $listL.Columns.Add("Modified",150); $listL.Columns.Add("SizeKB",100)
$tabPages["Logs"].Controls.Add($listL)

$txtV = New-Object System.Windows.Forms.TextBox; $txtV.Location=New-Object System.Drawing.Point(530,90); $txtV.Size=New-Object System.Drawing.Size(840,400); $txtV.Multiline=$true; $txtV.ScrollBars="Vertical"; $txtV.Font=New-Object System.Drawing.Font("Consolas",9)
$tabPages["Logs"].Controls.Add($txtV)
$listL.Add_DoubleClick({$s=$listL.SelectedItems[0]; if($s){$txtV.Text=(Get-Content (Join-Path $txtL.Text $s.Name) -Tail 500)-join "`r`n"}})

# ListView search panel
$p = New-Object System.Windows.Forms.Panel; $p.Location=New-Object System.Drawing.Point(20,500); $p.Size=New-Object System.Drawing.Size(500,30)
$l = New-Object System.Windows.Forms.Label; $l.Text="Search Logs:"; $l.Location=New-Object System.Drawing.Point(0,5); $l.AutoSize=$true; $p.Controls.Add($l)
$txtS = New-Object System.Windows.Forms.TextBox; $txtS.Location=New-Object System.Drawing.Point(80,3); $txtS.Width=300; $p.Controls.Add($txtS)
$btnClr = New-Object System.Windows.Forms.Button; $btnClr.Text="Clear"; $btnClr.Location=New-Object System.Drawing.Point(390,1); $btnClr.AutoSize=$true; $p.Controls.Add($btnClr)
$tabPages["Logs"].Controls.Add($p)

$global:logOrig = @()
$txtS.Add_TextChanged({$f=$txtS.Text.Trim(); if($f -eq "" -or -not $global:logOrig){$listL.DataSource=$global:logOrig}else{$listL.DataSource = $global:logOrig|Where{$_.Name -match [regex]::Escape($f) -or $_.LastWriteTime.ToString() -match [regex]::Escape($f) -or $_.SizeKB.ToString() -match [regex]::Escape($f)}}})
$btnClr.Add_Click({$txtS.Text="";$listL.DataSource=$global:logOrig})

# ========================================
# TAB: Inventory
# ========================================
$l = New-Object System.Windows.Forms.Label; $l.Text="Computer:"; $l.Location=New-Object System.Drawing.Point(20,20); $l.AutoSize=$true
$tabPages["Inventory"].Controls.Add($l)
$txtI = New-Object System.Windows.Forms.TextBox; $txtI.Location=New-Object System.Drawing.Point(20,50); $txtI.Width=250; $txtI.Text=$env:COMPUTERNAME
$tabPages["Inventory"].Controls.Add($txtI)

$btnI = New-Object System.Windows.Forms.Button; $btnI.Text="Check Inventory Status"; $btnI.Location=New-Object System.Drawing.Point(280,48); $btnI.AutoSize=$true
$btnI.Add_Click({$global:invData = Get-SoftwareInventoryStatus -ComputerName $txtI.Text; $gridI.DataSource = @($global:invData); $global:invOrig = $global:invData})
$tooltip.SetToolTip($btnI,"Show last HW/SW scan times")
$tabPages["Inventory"].Controls.Add($btnI)

$btnHW = New-Object System.Windows.Forms.Button; $btnHW.Text="Trigger Hardware Scan"; $btnHW.Location=New-Object System.Drawing.Point(20,90); $btnHW.AutoSize=$true
$btnHW.Add_Click({[System.Windows.Forms.MessageBox]::Show((Trigger-InventoryScan -ComputerName $txtI.Text -Type "Hardware"))})
$tooltip.SetToolTip($btnHW,"Force HW inventory")
$tabPages["Inventory"].Controls.Add($btnHW)

$btnSW = New-Object System.Windows.Forms.Button; $btnSW.Text="Trigger Software Scan"; $btnSW.Location=New-Object System.Drawing.Point(180,90); $btnSW.AutoSize=$true
$btnSW.Add_Click({[System.Windows.Forms.MessageBox]::Show((Trigger-InventoryScan -ComputerName $txtI.Text -Type "Software"))})
$tooltip.SetToolTip($btnSW,"Force SW inventory")
$tabPages["Inventory"].Controls.Add($btnSW)

$btnEI = New-Object System.Windows.Forms.Button; $btnEI.Text="Export to Excel"; $btnEI.Location=New-Object System.Drawing.Point(350,88); $btnEI.AutoSize=$true
$btnEI.Add_Click({if($global:invData){Export-ToExcel @($global:invData) "SCCM_Inventory"}})
$tooltip.SetToolTip($btnEI,"Export filtered inventory")
$tabPages["Inventory"].Controls.Add($btnEI)

$gridI = New-Object System.Windows.Forms.DataGridView; $gridI.Location=New-Object System.Drawing.Point(20,170); $gridI.Size=New-Object System.Drawing.Size(1400,310); $gridI.AutoSizeColumnsMode="Fill"
$tabPages["Inventory"].Controls.Add($gridI)

Add-SearchFilter -Grid $gridI -Tab $tabPages["Inventory"] -Y 130 | Out-Null
$global:invOrig = @()

# ========================================
# TAB: Deployments
# ========================================
$l = New-Object System.Windows.Forms.Label; $l.Text="Site Server:"; $l.Location=New-Object System.Drawing.Point(20,20); $l.AutoSize=$true
$tabPages["Deployments"].Controls.Add($l)
$txtSrv = New-Object System.Windows.Forms.TextBox; $txtSrv.Location=New-Object System.Drawing.Point(20,50); $txtSrv.Width=200
$tabPages["Deployments"].Controls.Add($txtSrv)

$l = New-Object System.Windows.Forms.Label; $l.Text="Site Code:"; $l.Location=New-Object System.Drawing.Point(230,20); $l.AutoSize=$true
$tabPages["Deployments"].Controls.Add($l)
$txtCode = New-Object System.Windows.Forms.TextBox; $txtCode.Location=New-Object System.Drawing.Point(230,50); $txtCode.Width=80
$tabPages["Deployments"].Controls.Add($txtCode)

$l = New-Object System.Windows.Forms.Label; $l.Text="Name Filter:"; $l.Location=New-Object System.Drawing.Point(320,20); $l.AutoSize=$true
$tabPages["Deployments"].Controls.Add($l)
$txtF = New-Object System.Windows.Forms.TextBox; $txtF.Location=New-Object System.Drawing.Point(320,50); $txtF.Width=180; $txtF.Text="*"
$tabPages["Deployments"].Controls.Add($txtF)

$btnD = New-Object System.Windows.Forms.Button; $btnD.Text="Load Deployment Status"; $btnD.Location=New-Object System.Drawing.Point(510,48); $btnD.AutoSize=$true
$btnD.Add_Click({$global:depData = Get-DeploymentStatus -SiteServer $txtSrv.Text -SiteCode $txtCode.Text -Filter $txtF.Text; $gridD.DataSource = $global:depData; $global:depOrig = $global:depData})
$tooltip.SetToolTip($btnD,"Load deployment summary")
$tabPages["Deployments"].Controls.Add($btnD)

$btnED = New-Object System.Windows.Forms.Button; $btnED.Text="Export to Excel"; $btnED.Location=New-Object System.Drawing.Point(680,48); $btnED.AutoSize=$true
$btnED.Add_Click({if($global:depData){Export-ToExcel $global:depData "SCCM_Deployments"}})
$tooltip.SetToolTip($btnED,"Export filtered deployments")
$tabPages["Deployments"].Controls.Add($btnED)

$gridD = New-Object System.Windows.Forms.DataGridView; $gridD.Location=New-Object System.Drawing.Point(20,130); $gridD.Size=New-Object System.Drawing.Size(1400,360); $gridD.AutoSizeColumnsMode="Fill"
$tabPages["Deployments"].Controls.Add($gridD)

Add-SearchFilter -Grid $gridD -Tab $tabPages["Deployments"] -Y 90 | Out-Null
$global:depOrig = @()

# ========================================
# TAB: Server Update Compliance
# ========================================
$l = New-Object System.Windows.Forms.Label; $l.Text="Collection ID ('All' for all servers):"; $l.Location=New-Object System.Drawing.Point(20,20); $l.AutoSize=$true
$tabPages["Server Update Compliance"].Controls.Add($l)
$txtColl = New-Object System.Windows.Forms.TextBox; $txtColl.Location=New-Object System.Drawing.Point(20,50); $txtColl.Width=250; $txtColl.Text="All"
$tabPages["Server Update Compliance"].Controls.Add($txtColl)

$btnComp = New-Object System.Windows.Forms.Button; $btnComp.Text="Load Server Compliance Dashboard"; $btnComp.Location=New-Object System.Drawing.Point(280,48); $btnComp.AutoSize=$true
$btnComp.Add_Click({$global:compData = Get-ServerComplianceDashboard -CollectionID $txtColl.Text; $gridComp.DataSource = $global:compData; $global:compOrig = $global:compData})
$tooltip.SetToolTip($btnComp,"Full Patch-Tuesday compliance report")
$tabPages["Server Update Compliance"].Controls.Add($btnComp)

$btnECmp = New-Object System.Windows.Forms.Button; $btnECmp.Text="Export to Excel"; $btnECmp.Location=New-Object System.Drawing.Point(520,48); $btnECmp.AutoSize=$true
$btnECmp.Add_Click({if($global:compData){Export-ToExcel $global:compData "SCCM_Server_Update_Compliance"}})
$tooltip.SetToolTip($btnECmp,"Export filtered compliance")
$tabPages["Server Update Compliance"].Controls.Add($btnECmp)

$gridComp = New-Object System.Windows.Forms.DataGridView; $gridComp.Location=New-Object System.Drawing.Point(20,130); $gridComp.Size=New-Object System.Drawing.Size(1400,560); $gridComp.AutoSizeColumnsMode="Fill"
$tabPages["Server Update Compliance"].Controls.Add($gridComp)

Add-SearchFilter -Grid $gridComp -Tab $tabPages["Server Update Compliance"] -Y 90 | Out-Null
$global:compOrig = @()

# ========================================
# Show the form
# ========================================
$form.ShowDialog() | Out-Null
