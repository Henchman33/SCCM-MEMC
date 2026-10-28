
#requires -RunAsAdministrator
<#
.SYNOPSIS
    Cleans the Configuration Manager (SCCM) client cache.

.DESCRIPTION
    Uses the ConfigMgr client COM interface to remove cached content.
    Supports preview mode before performing cleanup.

.NOTES
    Run in Windows PowerShell ISE as Administrator.
    Test on a small number of clients before production use.
#>

# Set to $true to preview without deleting anything.
$WhatIfMode = $false

$ErrorActionPreference = "Stop"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Configuration Manager Cache Cleanup" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

try {
    # Verify the ConfigMgr client COM interface
    $UIResource = New-Object -ComObject UIResource.UIResourceMgr

    # Get cache information
    $CacheInfo = $UIResource.GetCacheInfo()
    $CacheElements = $CacheInfo.GetCacheElements()

    if (-not $CacheElements -or $CacheElements.Count -eq 0) {
        Write-Host "CCMCache is already empty." -ForegroundColor Green
        return
    }

    $CachePath = $CacheInfo.Location
    Write-Host "Cache location: $CachePath"
    Write-Host "Cache entries found: $($CacheElements.Count)"
    Write-Host ""

    $FreedBytes = 0
    $RemovedCount = 0
    $FailedCount = 0

    foreach ($Element in $CacheElements) {
        $SizeMB = [math]::Round(
            ($Element.ContentSize * 1KB) / 1MB, 2
        )

        Write-Host (
            "Cache ID: {0} | Size: {1} MB | Last reference: {2}" -f
            $Element.CacheElementID,
            $SizeMB,
            $Element.LastReferenced
        )

        if ($WhatIfMode) {
            Write-Host "  PREVIEW: Would attempt to remove this entry." `
                -ForegroundColor Yellow
            continue
        }

        try {
            # Delete using the ConfigMgr cache API
            $CacheInfo.DeleteCacheElement(
                $Element.CacheElementID
            )

            $RemovedCount++
            $FreedBytes += ($Element.ContentSize * 1KB)

            Write-Host "  Removal requested." -ForegroundColor Green
        }
        catch {
            $FailedCount++
            Write-Warning (
                "Could not remove cache ID {0}: {1}" -f
                $Element.CacheElementID, $_.Exception.Message
            )
        }
    }

    Write-Host ""
    Write-Host "--------------- Summary ---------------" `
        -ForegroundColor Cyan

    if ($WhatIfMode) {
        Write-Host "Preview only: no cache entries were deleted." `
            -ForegroundColor Yellow
        Write-Host "Review the entries, then set `$WhatIfMode = `$false."
    }
    else {
        Write-Host "Removal requests: $RemovedCount"
        Write-Host "Failed requests:  $FailedCount"
        Write-Host (
            "Estimated content size requested for removal: {0:N2} MB" -f
            ($FreedBytes / 1MB)
        )
    }
}
catch {
    Write-Error "Cache cleanup failed: $($_.Exception.Message)"
    Write-Host (
        "Verify the ConfigMgr client is installed and running, " +
        "and rerun PowerShell ISE as Administrator."
    ) -ForegroundColor Red
}
