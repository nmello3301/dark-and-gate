# tools/native/ — Dark and Gate native plugin

Loads via Ch4nKyy's Mod Loader as `<BG3>/bin/NativeMods/DarkAndGate.dll`.

**Status:** M1a scaffold. The DLL writes a version file on load and
nothing else. Hooks arrive in follow-up commits once the Lua↔DLL
communication path is signed off — see
`docs/native-bridge-design.md`.

## Prerequisites

- Visual Studio Community 2022 with the **Desktop development with C++**
  workload.
- CMake 3.21+ (bundled with VS).
- vcpkg (optional for M1a; required once DKUtil / spdlog are pulled in).

## Build

From a Developer PowerShell in this directory:

```powershell
cmake --preset vs2022-windows
cmake --build out/build --config Release
```

Output: `out/build/Release/DarkAndGate.dll`.

## Install

Copy the DLL into the mod loader's folder:

```powershell
Copy-Item .\out\build\Release\DarkAndGate.dll `
  "C:\Program Files (x86)\Steam\steamapps\common\Baldurs Gate 3\bin\NativeMods\DarkAndGate.dll"
```

A helper script `scripts/deploy-native.ps1` will land next to
`scripts/deploy.ps1` once we have more than one build target.

## Smoke test

1. Launch BG3. The DLL loads via Ch4nKyy's Mod Loader during startup.
2. The DLL writes
   `%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Script Extender\DarkAndGate\native-version.txt`
   with a single line: `DarkAndGate <version> <build-kind> pid=<N> t=<ms>`.
3. On session load, our Lua side (`Shared/NativeBridge.lua`) reads the
   file and logs `[Client] Native: DarkAndGate 0.1.0 scaffold pid=... t=...`.
4. Console command `!dag_native_version` re-reads and prints.

If Lua logs the line, DLL loaded and Lua can see it. That's the whole
M1a kickoff smoke test. Everything else is additive.

## Hook plan

See `docs/native-bridge-design.md` for the full bridge discussion. In
order of planned implementation under M1a:

1. **Camera follow + mouselook** (combined — same hook). Reads config
   from a watched TOML, hooks the game's `UpdateCamera` and SDL mouse
   path. Templates: NCT (`reference/BG3_NativeCameraTweaks/src/Hooks.cpp`)
   and BG3WASD (`reference/BG3WASD/src/Hooks/`).
2. `GetBoneWorldPos(entity, bone) → vec3`. Reads from the shared skeleton
   `Pose` the SE Lua binding hides. Reports hit events into a shared
   output file / Osiris event (TBD when we build it).
3. `SetAnimPlaySpeed`, `CancelAnim`. Hooks the animation subsystem.
4. `RaycastHitNormal`. Wraps the game's physics raycast with the normal
   that SE's Lua binding reads as `(0,0,0)`.

## License

GPL-3.0-or-later. Hook signatures and some glue cribbed from NCT
(`reference/BG3_NativeCameraTweaks`) and BG3WASD (`reference/BG3WASD`),
both GPL-3-compatible.
