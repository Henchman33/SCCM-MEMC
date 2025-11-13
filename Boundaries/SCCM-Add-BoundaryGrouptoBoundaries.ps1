<#✅ Reads boundaries from a CSV file
✅ Assigns them to the boundary group “US NV RNO”
✅ Includes a Dry-Run toggle at the top for easy testing
✅ Logs actions and creates a summary report in C:\Temp\BoundariesLogs

✅ Script with Dry-Run Toggle
PowerShell# ==============================# CONFIGURATION# ==============================$BoundaryGroupName = "US NV RNO"   # Boundary Group Name$CsvPath = "C:\Temp\BoundariesLogs\adigtcomRNOboundary.csv"  # Path to CSV file$DryRun = $true                                # Set to $true for Dry-Run, $false for actual execution$LogPath = "C:\Temp\BoundariesLogs"$LogFile = Join-Path $LogPath "BoundaryAssignment.log"$SummaryFile = Join-Path $LogPath "BoundarySummary.csv"# ==============================# Import Configuration Manager moduleImport-Module ($Env:SMS_ADMIN_UI_PATH.Substring(0,$Env:SMS_ADMIN_UI_PATH.Length-5) + '\ConfigurationManager.psd1')# Connect to SCCM sitecd "X:\\"   # Replace X with your site code (e.g., CD "ABC:")# Ensure log directory existsif (!(Test-Path $LogPath)) {    New-Item -ItemType Directory -Path $LogPath -Force}# Initialize summary list$Summary = @()# Function to log messagesfunction Write-Log {    param([string]$Message)    $Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")    Add-Content -Path $LogFile -Value "$Timestamp - $Message"}Write-Host "Starting boundary assignment from CSV..." -ForegroundColor CyanWrite-Host "Boundary Group: $BoundaryGroupName" -ForegroundColor CyanWrite-Host "CSV Path: $CsvPath" -ForegroundColor CyanWrite-Host "Dry-Run Mode: $DryRun" -ForegroundColor Cyantry {    # Load CSV    if (!(Test-Path $CsvPath)) {        throw "CSV file not found at $CsvPath"    }    $CsvData = Import-Csv -Path $CsvPath    # Get Boundary Group    $BoundaryGroup = Get-CMBoundaryGroup | Where-Object { $_.Name -eq $BoundaryGroupName }    if ($BoundaryGroup) {        foreach ($Row in $CsvData) {            $BoundaryName = $Row.DisplayName            $Status = ""            try {                $Boundary = Get-CMBoundary | Where-Object { $_.DisplayName -eq $BoundaryName }                if ($Boundary) {                    if ($Boundary.GroupCount -eq 0) {                        if ($DryRun) {                            $Status = "Dry-Run: Would Add"                            Write-Host "✔ [Dry-Run] Would add: $BoundaryName" -ForegroundColor Green                            Write-Log "[Dry-Run] Would add boundary '$BoundaryName' to group '$BoundaryGroupName'."                        } else {                            Add-CMBoundaryToGroup -BoundaryGroupId $BoundaryGroup.GroupID -BoundaryId $Boundary.BoundaryID                            $Status = "Added"                            Write-Host "✔ Added: $BoundaryName" -ForegroundColor Green                            Write-Log "Added boundary '$BoundaryName' (ID: $($Boundary.BoundaryID)) to group '$BoundaryGroupName'."                        }                    } else {                        $Status = "Skipped (Already in $($Boundary.GroupCount) group(s))"                        Write-Host "⚠ Skipped: $BoundaryName - Already in $($Boundary.GroupCount) group(s)" -ForegroundColor Yellow                        Write-Log "Skipped boundary '$BoundaryName' because it is already in $($Boundary.GroupCount) group(s)."                    }                } else {                    $Status = "Not Found"                    Write-Host "✖ Boundary not found: $BoundaryName" -ForegroundColor Red                    Write-Log "Boundary '$BoundaryName' not found in SCCM."                }            } catch {                $Status = "Error: $($_.Exception.Message)"                Write-Host "✖ Error processing $BoundaryName: $($_.Exception.Message)" -ForegroundColor Red                Write-Log "Error processing boundary '$BoundaryName': $($_.Exception.Message)"            }            # Add to summary            $Summary += [PSCustomObject]@{                BoundaryDisplayName = $BoundaryName                Status              = $Status            }        }        # Export summary to CSV        $Summary | Export-Csv -Path $SummaryFile -NoTypeInformation        Write-Host "Process completed. Log: $LogFile | Summary: $SummaryFile" -ForegroundColor Cyan    } else {        throw "Boundary Group '$BoundaryGroupName' not found!"    }} catch {    Write-Log "Critical error: $($_.Exception.Message)"    Write-Host "Critical error occurred: $($_.Exception.Message)" -ForegroundColor Red}Show more lines

✅ How to Use:

Open in PowerShell ISE
Set $DryRun = $true to preview changes
Set $DryRun = $false to apply changes
Run the script
#>


# ==============================
# CONFIGURATION
# ==============================
$BoundaryGroupName = "xx xx rrr"   # Boundary Group Name
$CsvPath = "C:\Temp\BoundariesLogs\adigtcomRNOboundary.csv"  # Path to CSV file
$DryRun = $true                                # Set to $true for Dry-Run, $false for actual execution
$LogPath = "C:\Temp\BoundariesLogs"
$LogFile = Join-Path $LogPath "BoundaryAssignment.log"
$SummaryFile = Join-Path $LogPath "BoundarySummary.csv"
# ==============================

# Import Configuration Manager module
Import-Module ($Env:SMS_ADMIN_UI_PATH.Substring(0,$Env:SMS_ADMIN_UI_PATH.Length-5) + '\ConfigurationManager.psd1')

# Connect to SCCM site
cd "X:\\"   # Replace X with your site code (e.g., CD "ABC:")

# Ensure log directory exists
if (!(Test-Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath -Force
}

# Initialize summary list
$Summary = @()

# Function to log messages
function Write-Log {
    param([string]$Message)
    $Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    Add-Content -Path $LogFile -Value "$Timestamp - $Message"
}

Write-Host "Starting boundary assignment from CSV..." -ForegroundColor Cyan
Write-Host "Boundary Group: $BoundaryGroupName" -ForegroundColor Cyan
Write-Host "CSV Path: $CsvPath" -ForegroundColor Cyan
Write-Host "Dry-Run Mode: $DryRun" -ForegroundColor Cyan

try {
    # Load CSV
    if (!(Test-Path $CsvPath)) {
        throw "CSV file not found at $CsvPath"
    }
    $CsvData = Import-Csv -Path $CsvPath

    # Get Boundary Group
    $BoundaryGroup = Get-CMBoundaryGroup | Where-Object { $_.Name -eq $BoundaryGroupName }

    if ($BoundaryGroup) {
        foreach ($Row in $CsvData) {
            $BoundaryName = $Row.DisplayName
            $Status = ""

            try {
                $Boundary = Get-CMBoundary | Where-Object { $_.DisplayName -eq $BoundaryName }

                if ($Boundary) {
                    if ($Boundary.GroupCount -eq 0) {
                        if ($DryRun) {
                            $Status = "Dry-Run: Would Add"
                            Write-Host "✔ [Dry-Run] Would add: $BoundaryName" -ForegroundColor Green
                            Write-Log "[Dry-Run] Would add boundary '$BoundaryName' to group '$BoundaryGroupName'."
                        } else {
                            Add-CMBoundaryToGroup -BoundaryGroupId $BoundaryGroup.GroupID -BoundaryId $Boundary.BoundaryID
                            $Status = "Added"
                            Write-Host "✔ Added: $BoundaryName" -ForegroundColor Green
                            Write-Log "Added boundary '$BoundaryName' (ID: $($Boundary.BoundaryID)) to group '$BoundaryGroupName'."
                        }
                    } else {
                        $Status = "Skipped (Already in $($Boundary.GroupCount) group(s))"
                        Write-Host "⚠ Skipped: $BoundaryName - Already in $($Boundary.GroupCount) group(s)" -ForegroundColor Yellow
                        Write-Log "Skipped boundary '$BoundaryName' because it is already in $($Boundary.GroupCount) group(s)."
                    }
                } else {
                    $Status = "Not Found"
                    Write-Host "✖ Boundary not found: $BoundaryName" -ForegroundColor Red
                    Write-Log "Boundary '$BoundaryName' not found in SCCM."
                }
            } catch {
                $Status = "Error: $($_.Exception.Message)"
                Write-Host "✖ Error processing $BoundaryName: $($_.Exception.Message)" -ForegroundColor Red
                Write-Log "Error processing boundary '$BoundaryName': $($_.Exception.Message)"
            }

            # Add to summary
            $Summary += [PSCustomObject]@{
                BoundaryDisplayName = $BoundaryName
                Status              = $Status
            }
        }

        # Export summary to CSV
        $Summary | Export-Csv -Path $SummaryFile -NoTypeInformation
        Write-Host "Process completed. Log: $LogFile | Summary: $SummaryFile" -ForegroundColor Cyan
    } else {
        throw "Boundary Group '$BoundaryGroupName' not found!"
    }
} catch {
    Write-Log "Critical error: $($_.Exception.Message)"
    Write-Host "Critical error occurred: $($_.Exception.Message)" -ForegroundColor Red
}
