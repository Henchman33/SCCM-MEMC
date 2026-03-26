COMMENT : This script check and install the software updates available in
          software center on clients remotly with nice logging info
VERSION : 1.0
#>

# Determine script location
$ScriptDir = Split-Path $script:MyInvocation.MyCommand.Path
$log      = "$ScriptDir\InstallUpdates.log"
$date     = Get-Date -Format "dd-MM-yyyy hh:mm:ss"
# Get list of clients from notepad
"---------------------  Script executed on $date (DD-MM-YYYY hh:mm:ss) ---------------------" + "`r`n" | Out-File $log -append
ForEach ($system in Get-Content $ScriptDir"\clients.txt")
{
$wmicheck=$null
$wmicheck =Get-WmiObject -ComputerName $system -namespace root\cimv2 -Class Win32_BIOS -ErrorAction SilentlyContinue
if ($wmicheck)
{
# Get list of all instances of CCM_SoftwareUpdate from root\CCM\ClientSDK for missing updates https://msdn.microsoft.com/en-us/library/jj155450.aspx?f=255&MSPPError=-2147217396
$TargetedUpdates= Get-WmiObject -ComputerName $system -Namespace root\CCM\ClientSDK -Class CCM_SoftwareUpdate -Filter ComplianceState=0
$approvedUpdates= ($TargetedUpdates |Measure-Object).count
$pendingpatches=($TargetedUpdates |Where-Object {$TargetedUpdates.EvaluationState -ne 8} |Measure-Object).count
$rebootpending=($TargetedUpdates |Where-Object {$TargetedUpdates.EvaluationState -eq 8} |Measure-Object).count
if ($pendingpatches -gt 0) 
{
  try {
	$MissingUpdatesReformatted = @($TargetedUpdates | ForEach-Object {if($_.ComplianceState -eq 0){[WMI]$_.__PATH}}) 
	# The following is the invoke of the CCM_SoftwareUpdatesManager.InstallUpdates with our found updates 
	$InstallReturn = Invoke-WmiMethod -ComputerName $system -Class CCM_SoftwareUpdatesManager -Name InstallUpdates -ArgumentList (,$MissingUpdatesReformatted) -Namespace root\ccm\clientsdk 
	"$system,Targeted Patches :$approvedUpdates,Pending patches:$pendingpatches,Reboot Pending patches :$rebootpending,initiated $pendingpatches patches for install" | Out-File $log -append
	  }
	catch {"$System,pending patches - $pendingpatches but unable to install them ,please check Further" | Out-File $log -append }
}
else {"$system,Targeted Patches :$approvedUpdates,Pending patches:$pendingpatches,Reboot Pending patches :$rebootpending,Compliant" | Out-File $log -append }
}
else {"$system,Unable to connect to remote system ,please check further" | Out-File $log -append }
}
