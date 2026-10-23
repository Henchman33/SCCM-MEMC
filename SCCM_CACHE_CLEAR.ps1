#discovery script - Find the number of folders on the $MinDays =
$MinDays = 60
$UIResourceMgr = New-Object -ComObject UIResource.UIResourceMgr
$Cache = $UIResourceMgr.GetCacheInfo()
($Cache.GetCacheElements() |
where-object {[datetime]$_.LastReferenceTime -lt (get-date).adddays(-$mindays)} |
Measure-object).Count

#For remediation script, use the following PowerShell script to clean the content older than 14 days:

This script will clean the content (folders) older than 14 days.

#remediate script - Deleted Folders with $MinDays = 
$MinDays = 60
$UIResourceMgr = New-Object -ComObject UIResource.UIResourceMgr
$Cache = $UIResourceMgr.GetCacheInfo()
$Cache.GetCacheElements() |
where-object {[datetime]$_.LastReferenceTime -lt (get-date).adddays(-$mindays)} |
foreach {
$Cache.DeleteCacheElement($_.CacheElementID)
}
