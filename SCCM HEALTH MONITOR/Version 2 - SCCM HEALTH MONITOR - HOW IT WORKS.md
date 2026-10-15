I added both options, a collection picker and a typed Collection ID, in SCCM-HealthMonitor.ps1 (v2.2). I haven’t run it, so treat it as untested until you’ve tried it in your environment.

**How it works**

- **Target bar:** A new bar under the title lets you choose Local machine or SCCM device collection. Local behaves as before.
- **Collection mode:** You get a Site server box, a Collection ID box, and a Browse button. You can type an 8-character ID like `SMS00001` or click Browse to filter and pick from a list of all device collections with their member counts. The site server is prefilled from the local client’s management point, which may not be your SMS Provider, so correct it if needed.
- **Site queries:** It uses CIM against the SMS Provider (WinRM, with a DCOM fallback), so no ConfigurationManager module is needed. It discovers the site code from the server, confirms the ID exists and is a device collection, then pulls the members.
- **Fleet scan:** Members are scanned in parallel (15 at a time) by reading each device’s logs through `\\<fqdn>\ADMIN$\CCM\Logs`. The same parsing code now runs for local and fleet scans. A progress bar shows how far along it is, and SCAN NOW turns into CANCEL SCAN while it runs.
- **Results:** The detection table gains a DEVICES column, and the stats bar shows devices reached out of total. Selecting a detection lists the affected devices. Unreachable devices and their errors go in the output pane. Non-client and obsolete records are skipped and counted.

**Things to know**

- **Rights:** You need local admin on the targets (for `ADMIN$`) and at least Read-only Analyst on the SMS Provider.
- **Remediation:** The buttons are disabled in collection mode because they only act on the machine you run the tool from. Remote remediation, for example through `Invoke-Command` with a confirmation, is a separate feature. I can add it if you want.
- **Auto-scan:** It re-scans whichever target is selected, and failures during auto-scans show in the status bar rather than as popups.
- **Name resolution:** It uses each device’s DNS host name from the site database, which should help across your child domains. Devices with an empty DNS name fall back to the NetBIOS name and may fail to resolve.
- **Cancel:** It is best effort. A scan stuck on a hung SMB connection can linger in the background until that connection times out.

I also made the log window a config value, `LogWindowHours`, set to 2 hours.