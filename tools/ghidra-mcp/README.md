# tools/ghidra-mcp/ — Ghidra MCP bridge

A Python bridge that talks to the GhidraMCP plugin's HTTP server and
exposes Ghidra's analysis to Claude Code via the Model Context Protocol.

## What's installed

- **Ghidra plugin:** `GhidraMCP-12.1.4.zip` dropped into
  `<ghidra-install>\Extensions\Ghidra\`. Patched from upstream 11.3.2 →
  12.1.4 to pass Ghidra's version check. The internal API calls are the
  same, so unless Ghidra 12 changed one of the methods the plugin uses,
  it should load. If it breaks at runtime, see the "Fallback" section
  below.
- **MCP bridge:** `tools/ghidra-mcp/bridge_mcp_ghidra.py` from
  `LaurieWired/GhidraMCP@1.4`. Uses PEP 723 inline deps (`requests`,
  `mcp>=1.2.0`), so `uv run --script` auto-installs them.
- **MCP registration:** `.mcp.json` at repo root. Claude Code picks it
  up automatically.

## One-time manual steps (GUI)

1. Launch Ghidra via `C:\Users\nicol\Downloads\ghidra_12.1.4_PUBLIC_20260921\ghidra_12.1.4_PUBLIC\ghidraRun.bat`.
2. If this is the first launch after dropping the zip in, Ghidra will
   prompt to install new extensions — accept. Otherwise:
   `File` → `Install Extensions` → confirm `GhidraMCP` is checked.
3. Restart Ghidra when prompted.
4. Open the BG3 project: `File` → `Open Project...` →
   `C:\Tools\GhidraProjects\BG3\BG3.gpr`.
5. Double-click `bg3.exe` in the project tree to open it in the
   CodeBrowser tool.
6. In the CodeBrowser tool: `File` → `Configure` → `Developer` →
   check `GhidraMCPPlugin`. The HTTP server starts on
   `http://127.0.0.1:8080/`.

## Verifying from Claude Code

Once Ghidra is open with bg3.exe loaded and the plugin enabled:

- The `ghidra` MCP server appears in Claude Code's MCP list.
- Tools include `get_metadata`, `list_functions`, `decompile_function`,
  `search_strings`, etc.
- Smoke test: `get_metadata` returns program info; `list_functions`
  with a small limit returns function names.

## Fallback if the plugin fails at runtime

GhidraMCP 1.4 was built against Ghidra 11.3.2. Our patch only bumps
the version string; if Ghidra 12 removed a plugin API the plugin
depends on, it'll throw at load. In that case:

1. Check `<ghidra>/support/` logs for the exception.
2. Try one of the open PRs in `LaurieWired/GhidraMCP` that target
   12.1.2 (as of 2026-10-08: PR #164, PR #166). Clone the PR branch,
   build the extension zip with `./gradlew`, and drop it in the same
   Extensions folder.
3. Last resort: patch `src/main/java/com/lauriewired/GhidraMCPPlugin.java`
   to work around the specific API changes.

Nothing in the Dark and Gate build depends on Ghidra-MCP being alive —
it's an investigation tool for M1a hook pattern-matching, not a runtime
dependency.
