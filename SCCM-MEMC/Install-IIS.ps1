<# Get-Module servermanager- Install's required IIS server components for MP-DP-WSUS #>
Install-WindowsFeature Web-Windows-Auth
Install-WindowsFeature Web-ISAPI-Ext
Install-WindowsFeature Web-Metabase
Install-WindowsFeature Web-WMI
Install-WindowsFeature BITS
Install-WindowsFeature RDC
Install-WindowsFeature NET-Framework-Features -source \yournetwork\yourshare\sxs
Install-WindowsFeature Web-Asp-Net
Install-WindowsFeature Web-Asp-Net45
Install-WindowsFeature NET-HTTP-Activation
Install-WindowsFeature NET-Non-HTTP-Activation

#OR
#dism.exe /online /norestart /enable-feature /ignorecheck /featurename:"IIS-WebServerRole" /featurename:"IIS-WebServer" /featurename:"IIS-CommonHttpFeatures" /featurename:"IIS-StaticContent" /featurename:"IIS-DefaultDocument" /featurename:"IIS-DirectoryBrowsing" /featurename:"IIS-HttpErrors" /featurename:"IIS-HttpRedirect" /featurename:"IIS-WebServerManagementTools" /featurename:"IIS-IIS6ManagementCompatibility"  /featurename:"IIS-Metabase" /featurename:"IIS-WindowsAuthentication"  /featurename:"IIS-WMICompatibility"  /featurename:"IIS-ISAPIExtensions" /featurename:"IIS-ManagementScriptingTools" /featurename:"MSRDC-Infrastructure" /featurename:"IIS-ManagementService"

