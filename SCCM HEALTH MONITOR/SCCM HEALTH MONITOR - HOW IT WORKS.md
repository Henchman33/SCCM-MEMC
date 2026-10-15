

**ISSUES FIXED 10-14-2026**

- **Selection handler:** `Add_SelectionChanged` at line 669 had no `{ }` script block, which is what the parser read as an incomplete hash literal. I added the block.
- **XAML handler attribute:** The XAML also had `SelectionChanged="DetectionSelected"`. That attribute makes `XamlReader.Load` fail outright in PowerShell, so I removed it.
- **Empty function bodies:** `function Start-SCCMDashboard {}` and `function Update-Dashboard {}` were empty, with their real code sitting outside. The final call was `Start-SCCMDashboard {})`. All three are now proper functions with a plain call at the bottom.
- **Stray braces and quoting:** `ForEach-Object {}` was followed by an orphaned block. `YES` and `No` were unquoted, as were `$controls[lvDetections]` and the “Scan complete...” string. The sort expression was written as `Critical{0}High{1}...`.
- **Encoding damage:** The file had mojibake in region names, emoji and box characters. Everything is ASCII now, which also matches your no-emoji rule.
- **Leftover chat text:** The pasted-in prose comments at the top are removed.

**Logic bugs**

- **Log parsing:** The SCCM log format has separate `time="..."` and `date="..."` fields, but the code tried to parse a combined `MM-dd-yyyy` value from `time`. The message-stripping regex also used `]LOG]>` where the format is `]LOG]!>`. Both are fixed. Logs are now opened with shared read/write access so active logs don’t throw.
- **BITS fix:** It stopped BITS before listing jobs, which can’t work. It now removes the jobs first and then restarts the service.
- **Policy refresh:** It used the deprecated `wmic` fallback. It now uses `Invoke-CimMethod` for all triggers.
- **WMI repair:** It ran `/resetrepository` unconditionally, which can break the ConfigMgr client. It now verifies first, tries a salvage, and resets only as a last resort.
- **Remediation buttons:** They were using the blue scan style. They now use the intended `RemBtn` style.
- **Brush colors:** Colors are now set with a `BrushConverter` instead of raw strings.
- **Variable scoping:** UI state is in `$Script:Controls` so the event handlers can reach it.
- **Parameter rename:** I renamed the `-Error` switch on `Write-RemLog` to `-Fail`, since it shadowed `$Error`.

I also added a confirmation prompt before any remediation runs. I tightened pattern 6 by dropping the `SMS Agent Host` match, which appears in normal log lines and would have caused constant false Critical hits. Pattern 9 (`reboot.*required`) is also loose and may fire on informational lines, so you may want to tune it.