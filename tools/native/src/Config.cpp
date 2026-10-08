// SPDX-License-Identifier: GPL-3.0-or-later

#include "Config.h"

#include <windows.h>

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <shared_mutex>
#include <sstream>
#include <string>
#include <string_view>

#include "Log.h"

namespace dag::config {

namespace {

std::filesystem::path ConfigPath()
{
    wchar_t buf[MAX_PATH];
    const DWORD n = GetEnvironmentVariableW(L"LOCALAPPDATA", buf, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return {};
    std::filesystem::path p = buf;
    p /= L"Larian Studios";
    p /= L"Baldur's Gate 3";
    p /= L"Script Extender";
    p /= L"DarkAndGate";
    p /= L"native-config.toml";
    return p;
}

std::string Trim(std::string_view s)
{
    size_t a = 0, b = s.size();
    while (a < b && std::isspace(static_cast<unsigned char>(s[a]))) ++a;
    while (b > a && std::isspace(static_cast<unsigned char>(s[b - 1]))) --b;
    return std::string(s.substr(a, b - a));
}

bool ParseBool(const std::string& v, bool& out)
{
    if (v == "true" || v == "True" || v == "1") { out = true; return true; }
    if (v == "false" || v == "False" || v == "0") { out = false; return true; }
    return false;
}

bool ParseFloat(const std::string& v, float& out)
{
    char* end = nullptr;
    const float f = std::strtof(v.c_str(), &end);
    if (end == v.c_str()) return false;
    out = f;
    return true;
}

bool ParseInt(const std::string& v, int& out)
{
    char* end = nullptr;
    const long i = std::strtol(v.c_str(), &end, 10);
    if (end == v.c_str()) return false;
    out = static_cast<int>(i);
    return true;
}

void Assign(AllConfig& cfg, const std::string& section,
            const std::string& key,     const std::string& value)
{
    if (section == "dag.camera") {
        if      (key == "enabled")              ParseBool(value, cfg.camera.enabled);
        else if (key == "recommit_vt58")        ParseBool(value, cfg.camera.recommit_vt58);
        else if (key == "eye_height")           ParseFloat(value, cfg.camera.eye_height);
        else if (key == "debug_lift_m")         ParseFloat(value, cfg.camera.debug_lift_m);
        else if (key == "head_bone")            ParseBool(value, cfg.camera.head_bone);
        else if (key == "hide_head")            ParseBool(value, cfg.camera.hide_head);
        else if (key == "vt58_override")        ParseBool(value, cfg.camera.vt58_override);
        else if (key == "instant_follow")       ParseBool(value, cfg.camera.instant_follow);
        else if (key == "legacy_y_write")       ParseBool(value, cfg.camera.legacy_y_write);
        else if (key == "legacy_forward_write") ParseBool(value, cfg.camera.legacy_forward_write);
    } else if (section == "dag.mouselook") {
        if      (key == "enabled")             ParseBool(value, cfg.mouselook.enabled);
        else if (key == "sensitivity_yaw")     ParseFloat(value, cfg.mouselook.sensitivity_yaw);
        else if (key == "sensitivity_pitch")   ParseFloat(value, cfg.mouselook.sensitivity_pitch);
        else if (key == "invert_pitch")        ParseBool(value, cfg.mouselook.invert_pitch);
        else if (key == "pause_in_ui")         ParseBool(value, cfg.mouselook.pause_in_ui);
        else if (key == "character_facing")    ParseBool(value, cfg.mouselook.character_facing);
    } else if (section == "dag.anim") {
        if      (key == "enabled")        ParseBool(value, cfg.anim.enabled);
        else if (key == "hit_stop")       ParseBool(value, cfg.anim.hit_stop);
        else if (key == "hit_stop_ms")    ParseInt (value, cfg.anim.hit_stop_ms);
    } else if (section == "dag.bone") {
        if      (key == "enabled")        ParseBool(value, cfg.bone.enabled);
    } else if (section == "dag.raycast") {
        if      (key == "enabled")        ParseBool(value, cfg.raycast.enabled);
    }
}

std::shared_mutex g_lock;
AllConfig         g_cfg;
bool              g_loaded = false;
FILETIME          g_lastMtime = {};

bool StatMtime(const std::filesystem::path& p, FILETIME& out)
{
    WIN32_FILE_ATTRIBUTE_DATA fad = {};
    if (!GetFileAttributesExW(p.c_str(), GetFileExInfoStandard, &fad)) return false;
    out = fad.ftLastWriteTime;
    return true;
}

AllConfig LoadFromDisk()
{
    AllConfig cfg;  // defaults

    const auto path = ConfigPath();
    std::ifstream f(path);
    if (!f) {
        dag::log::Writef("Config: %ls not found, using defaults", path.c_str());
        return cfg;
    }

    std::string section;
    std::string line;
    int lineNo = 0;
    while (std::getline(f, line)) {
        ++lineNo;
        auto hash = line.find('#');
        if (hash != std::string::npos) line.erase(hash);
        auto trimmed = Trim(line);
        if (trimmed.empty()) continue;

        if (trimmed.front() == '[' && trimmed.back() == ']') {
            section = trimmed.substr(1, trimmed.size() - 2);
            continue;
        }

        auto eq = trimmed.find('=');
        if (eq == std::string::npos) {
            dag::log::Writef("Config: bad line %d: %s", lineNo, trimmed.c_str());
            continue;
        }
        auto key = Trim(trimmed.substr(0, eq));
        auto val = Trim(trimmed.substr(eq + 1));
        if (val.size() >= 2 && val.front() == '"' && val.back() == '"') {
            val = val.substr(1, val.size() - 2);
        }
        Assign(cfg, section, key, val);
    }

    // Dump every effective switch so stale TOML keys can't silently
    // leave old behaviour on. If a key is missing from the file, the
    // struct default (declared in Config.h) wins and prints here.
    dag::log::Writef(
        "Config: effective. camera.enabled=%d vt58_override=%d instant_follow=%d "
        "legacy_y_write=%d legacy_forward_write=%d "
        "eye_height=%.3f debug_lift_m=%.3f head_bone=%d hide_head=%d recommit_vt58=%d",
        cfg.camera.enabled, cfg.camera.vt58_override, cfg.camera.instant_follow,
        cfg.camera.legacy_y_write, cfg.camera.legacy_forward_write,
        cfg.camera.eye_height, cfg.camera.debug_lift_m,
        cfg.camera.head_bone, cfg.camera.hide_head, cfg.camera.recommit_vt58);
    dag::log::Writef(
        "Config: effective. mouselook.enabled=%d sens_yaw=%.3f sens_pitch=%.3f "
        "invert_pitch=%d pause_in_ui=%d char_facing=%d",
        cfg.mouselook.enabled, cfg.mouselook.sensitivity_yaw,
        cfg.mouselook.sensitivity_pitch, cfg.mouselook.invert_pitch,
        cfg.mouselook.pause_in_ui, cfg.mouselook.character_facing);
    dag::log::Writef(
        "Config: effective. anim.enabled=%d hit_stop=%d hit_stop_ms=%d "
        "bone.enabled=%d raycast.enabled=%d",
        cfg.anim.enabled, cfg.anim.hit_stop, cfg.anim.hit_stop_ms,
        cfg.bone.enabled, cfg.raycast.enabled);
    return cfg;
}

}  // namespace

AllConfig Load()
{
    return LoadFromDisk();
}

const AllConfig& Get()
{
    std::shared_lock<std::shared_mutex> rl(g_lock);
    if (g_loaded) return g_cfg;
    rl.unlock();
    {
        std::unique_lock<std::shared_mutex> wl(g_lock);
        if (!g_loaded) {
            g_cfg = LoadFromDisk();
            StatMtime(ConfigPath(), g_lastMtime);
            g_loaded = true;
        }
    }
    rl.lock();
    return g_cfg;
}

bool PollAndReload()
{
    FILETIME now = {};
    if (!StatMtime(ConfigPath(), now)) return false;
    {
        std::shared_lock<std::shared_mutex> rl(g_lock);
        if (CompareFileTime(&now, &g_lastMtime) == 0) return false;
    }
    AllConfig next = LoadFromDisk();
    {
        std::unique_lock<std::shared_mutex> wl(g_lock);
        g_cfg       = next;
        g_lastMtime = now;
    }
    dag::log::Writef("Config: reloaded (mtime changed)");
    return true;
}

}  // namespace dag::config
