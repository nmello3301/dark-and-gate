# Releasing a build

What to do with every build that leaves this PC: a friend zip (`scripts\make-friend-package.ps1`) or a public release.

## Antivirus false positives

**What happened (2026-10-13).** Windows Defender quarantined Ch4nKyy's Mod Loader (`bin\version.dll`) three times as `Trojan:Win32/Posilod.CA!cl`: once in `downloaded_mods\`, twice in the game's `bin`. `!cl` means a cloud machine-learning verdict, not a known-malware signature. Each time the process that opened the file was `powershell.exe` (our scripts reading it); the game had loaded the same DLL for days without a detection. Our own files (`DarkAndGate.dll`, the friend zips, INSTALL.bat, the `.ps1` scripts) were never flagged.

**For each public build:**

1. **Submit it to Microsoft as a software developer:** https://www.microsoft.com/wdsi/filesubmission
   - Upload `DarkAndGate.dll` and the release zip. If something is already detected, choose "incorrectly detected" and give the detection name; otherwise ask for a clean determination.
   - Note the submission ID in the release notes. Microsoft's answer can take days, so submit before announcing the build.
2. **Keep the DLL plain:**
   - a Release build (MSVC `/O2` + LTCG);
   - a version resource (`tools/native/src/DarkAndGate.rc`: ProductName, CompanyName, FileDescription, FileVersion = `<version>+<build stamp>`);
   - no packer, no obfuscation, no PDB path.
   - Check with `dumpbin /headers`: only the usual sections (`.text .rdata .data .pdata .rsrc .reloc`).
3. **Keep the scripts plain** (INSTALL.bat, install.ps1, COLLECT-LOGS.bat, mp-collect-logs.ps1):
   - one readable `powershell.exe -NoProfile -ExecutionPolicy Bypass -File <script>` line, echoed before it runs;
   - no hidden windows, no `-EncodedCommand`, no downloads at runtime, no `Invoke-Expression`;
   - no `Unblock-File` / Mark-of-the-Web stripping;
   - no reading or changing Windows Defender state (`Get-Mp*`, `Set-Mp*`, `Add-MpPreference`). Exclusions are the player's own step (FRIEND-README step 0);
   - never open `version.dll`, only stat it: opening it from a script is what triggered the detections above.
4. Optional: look the SHA-256 up on VirusTotal by hash. Uploading a file shares it with every vendor, so only upload public builds.

## Code signing (before the first public release)

An unsigned DLL starts every build with no reputation. An Authenticode signature lets SmartScreen and Defender reputation follow the publisher across builds instead.

- **Options to compare** (check eligibility and price at the time):
  - Microsoft's cloud signing service (Trusted Signing);
  - SignPath Foundation's free signing for open-source projects;
  - a regular OV code-signing certificate (since 2023 the key has to live on a hardware token or HSM).
- **How to sign:** `signtool sign /fd SHA256 /tr <timestamp server> /td SHA256`. Sign every DLL the release ships, and always timestamp so signatures outlive the certificate.
- Never sign or redistribute other people's binaries (`version.dll`, BG3WASD, NCT, the Script Extender).
