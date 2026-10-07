# Ghidra MCP setup (bethington/ghidra-mcp)

The LaurieWired GhidraMCP 1.4 release doesn't cleanly target Ghidra 12.1.4
(unresolved API drift + zip-layout bug on install). We use
[bethington/ghidra-mcp](https://github.com/bethington/ghidra-mcp) instead,
built from source against our actual Ghidra install.

## What's installed

- **Source:** `tools/ghidra-mcp-src/` — cloned from upstream. Build uses
  the included Gradle wrapper (no Maven needed despite what the setup
  script claims).
- **Extension (built artifact):**
  `C:\Users\nicol\AppData\Roaming\ghidra\ghidra_12.1.4_PUBLIC\Extensions\GhidraMCP\`
  — Gradle's `installUserExtension` task placed it here. Ghidra also saw
  a copy at `<ghidra>\Extensions\Ghidra\GhidraMCP-7.0.0.zip`.
- **Config patch:**
  `C:\Users\nicol\AppData\Roaming\ghidra\ghidra_12.1.4_PUBLIC\FrontEndTool.xml`
  — Gradle's `patchGhidraUserConfig` added the plugin to the enabled list.
- **Python bridge:** `tools/ghidra-mcp-src/python/bridge_mcp_ghidra/`.
  Entry point `bridge-mcp-ghidra`. Deps declared in
  `tools/ghidra-mcp-src/pyproject.toml`; `uv run --directory` resolves
  them from `uv.lock` on first invocation.
- **MCP registration:** `.mcp.json` at repo root uses stdio transport.

## Default ports

- Ghidra HTTP server (plugin side): `http://127.0.0.1:8089/`.
- Bridge uses stdio to Claude Code; no inbound port.

## Rebuilding after a Ghidra update

From a PowerShell in `tools/ghidra-mcp-src/`:

```powershell
$env:JAVA_HOME = "C:\Program Files\Eclipse Adoptium\jdk-21.0.12.101-hotspot"
$env:PATH = "$env:JAVA_HOME\bin;$env:PATH"
$env:GHIDRA_INSTALL_DIR = "C:\Users\nicol\Downloads\ghidra_12.1.4_PUBLIC_20260921\ghidra_12.1.4_PUBLIC"
.\gradlew.bat deploy --no-daemon --console=plain
```

If the Ghidra version bumps, edit `tools/ghidra-mcp-src/pom.xml` so
`<ghidra.version>` matches the new install, then run deploy again.

## One-time GUI steps on your end

Ghidra side (deps are deployed, you just need to launch + enable):

1. Launch:
   `C:\Users\nicol\Downloads\ghidra_12.1.4_PUBLIC_20260921\ghidra_12.1.4_PUBLIC\ghidraRun.bat`
2. On first launch, Ghidra should detect the installed extension and
   enable it automatically (`FrontEndTool.xml` has been patched). If
   you see a "configure new extensions" dialog, confirm `GhidraMCP` is
   checked and restart Ghidra when prompted.
3. `File` → `Open Project...` → `C:\Tools\GhidraProjects\BG3\BG3.gpr`.
4. Double-click `bg3.exe` → the CodeBrowser tool opens.
5. In CodeBrowser: `File` → `Configure` → confirm `GhidraMCPPlugin`
   is checked. The HTTP server starts on `127.0.0.1:8089`.

Claude Code side (one-time, after a `.mcp.json` change):

- Restart this Claude Code session, or run `/mcp` to reload the server
  list. Then you can call `list_instances`, `connect_instance`, and the
  analysis tools (`get_metadata`, function listings, decompilation).

## Troubleshooting

- **Gradle complains about Java:** The deploy expects `JAVA_HOME`
  pointing to the JDK 21 install at
  `C:\Program Files\Eclipse Adoptium\jdk-21.0.12.101-hotspot`. The
  commands above set it per-shell; if you want it permanent, set
  the system env var.
- **Plugin doesn't show up in Ghidra:** check
  `%APPDATA%\ghidra\ghidra_12.1.4_PUBLIC\Extensions\GhidraMCP\extension.properties`
  exists. If not, re-run `.\gradlew.bat deploy`.
- **MCP server shows no tools in Claude Code:** check Ghidra is
  running with bg3.exe open; the bridge calls Ghidra's HTTP server
  on first `connect_instance`. Without a program loaded, the tool
  surface is empty.
- **Port conflict on 8089:** change the Ghidra plugin's listen port
  via Ghidra's `Edit` → `Tool Options` → `GhidraMCP HTTP Server`.
  Update `.mcp.json` and this doc if you do.
