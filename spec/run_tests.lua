#!/usr/bin/env luajit
table.unpack = table.unpack or unpack
-- =============================================================================
-- spec/run_tests.lua
-- =============================================================================
--
-- Runs every spec/*_spec.lua file using a minimal in-process harness.
-- Designed to be invoked from the plugin's root directory:
--
--   $ luajit spec/run_tests.lua
--
-- It sets up the search paths so test files can require modules from
-- both the syncery plugin (syncery_ann/...) and the test helpers
-- (spec.test_helpers).  Each spec file is run in a fresh-ish
-- environment (package.loaded entries for syncery_ann are cleared
-- between specs).
--
-- =============================================================================


-- Make `./?.lua` and `./?/init.lua` work for both the spec helpers
-- and the modules under test.
local plugin_root = arg[0]:match("(.*)/spec/run_tests%.lua$") or "."
package.path = plugin_root .. "/?.lua;"
            .. plugin_root .. "/?/init.lua;"
            .. package.path

-- System Lua libraries — we install cjson and lfs from apt; these
-- paths are correct on Debian/Ubuntu.  Fail noisily if not present.
package.path  = package.path  .. ";/usr/share/lua/5.1/?.lua"
                              .. ";/usr/share/lua/5.1/?/init.lua"
package.cpath = package.cpath .. ";/usr/lib/x86_64-linux-gnu/lua/5.1/?.so"

-- Windows compat: patch os.execute and io.open so that Unix shell idioms
-- (mkdir -p, rm -rf, touch) and /tmp/ paths work from the test suite without
-- touching any spec file.  Zero effect on Linux — the `if` is never entered.
if package.config:sub(1,1) == "\\" then
    local tmp = (os.getenv("TEMP") or os.getenv("TMP") or "C:\\Temp"):gsub("\\", "/")

    -- Translate a /tmp/ prefix to the real Windows temp directory.
    -- DECLARED FIRST so all closures below capture it as a local.
    local function translate_path(path)
        return path and path:gsub("^/tmp/", tmp .. "/")
    end

    -- Like translate_path but also strips surrounding single/double quotes.
    local function translate(path)
        return path:gsub("^['\"](.*)['\"]$", "%1"):gsub("^/tmp/", tmp .. "/")
    end

    -- Declare ALL orig_* variables BEFORE the os.execute closure so that
    -- every handler inside it captures local (not global) variable slots.
    -- Assignments happen below, after the closure is defined.
    local orig_execute
    local orig_open
    local orig_dofile
    local orig_loadfile
    local orig_remove
    local orig_rename

    orig_execute = os.execute
    os.execute = function(cmd)
        if cmd:match("^mkdir%s+-p%s+") then
            local rest = cmd:match("^mkdir%s+-p%s+(.+)$")
            -- Spec files may append 2>/dev/null to suppress "File exists"
            -- on Linux; strip it so the Windows handler doesn't include it
            -- in the directory name.
            rest = rest:gsub("%s+2>/dev/null%s*$", "")
            -- Some specs pass multiple space-separated paths: mkdir -p 'a' 'b'
            local paths = {}
            for p in rest:gmatch("'([^']+)'") do
                table.insert(paths, translate_path(p))
            end
            -- Also handle unquoted paths (rare but used)
            if #paths == 0 then
                table.insert(paths, translate_path(rest:gsub("^['\"](.*)['\"]$", "%1")))
            end
            local cmds = {}
            for _, p in ipairs(paths) do
                table.insert(cmds, 'cmd /c md "' .. p .. '" 2>nul')
            end
            for _, c in ipairs(cmds) do
                orig_execute(c)
            end
            return true
        elseif cmd:match("^rm%s+-rf%s+") then
            local rest = cmd:match("^rm%s+-rf%s+(.+)$"):gsub("%s+2>/dev/null%s*$", "")
            local path = translate(rest)
            -- Delegate to os.remove, which is already patched for Windows
            -- (removes files directly, falls back to rmdir /s /q for
            -- directories).  The old approach of if-exist "path\*" in a
            -- cmd.exe one-liner doesn't work reliably with forward-slash
            -- paths.  This is the same os.remove the Lua-native `rmdir`
            -- equivalent uses, so behaviour is consistent.  Best-effort:
            -- rm -rf always reports success.
            os.remove(path)
            return true
        elseif cmd:match("^touch%s+") then
            local path = translate(cmd:match("^touch%s+(.+)$"))
            return orig_execute('cmd /c if exist "' .. path .. '\\*" (copy /b nul +,,"' .. path .. '" >nul ) else (type nul > "' .. path .. '" 2>nul )')
        elseif cmd:match("^printf%s+") then
            -- printf 'FORMAT_STRING' > OUTPUT_FILE  — write content directly via Lua
            local format_str, outfile = cmd:match("^printf%s+'([^']+)'%s*>%s*(.+)$")
            if format_str and outfile then
                outfile = translate_path(outfile:gsub("^['\"](.*)['\"]$", "%1"))
                local content = format_str:gsub("\\n", "\n"):gsub("%%%%", "%%")
                local f = orig_open(outfile, "w")
                if f then f:write(content); f:close(); return true end
            end
            return orig_execute(cmd)
        else
            return orig_execute(cmd)
        end
    end

    -- Patch io.open, os.rename, os.remove to translate /tmp/ → real Windows
    -- temp so that every I/O path — not just spec helpers — lands in the
    -- correct directory, regardless of whether the spec stores its own
    -- test_root variable or uses h.test_root.

    orig_open = io.open
    io.open = function(path, mode)
        return orig_open(translate_path(path), mode)
    end

    -- dofile/loadfile use C-level I/O, not the patched io.open,
    -- so they must be intercepted directly for path translation.
    orig_dofile = dofile
    dofile = function(path)
        return orig_dofile(translate_path(path))
    end
    orig_loadfile = loadfile
    loadfile = function(path, mode, env)
        return orig_loadfile(translate_path(path), mode, env)
    end

    -- Must capture orig_remove BEFORE orig_rename because rename's
    -- Windows-compat patch needs it to delete the destination.
    orig_remove = os.remove
    os.remove = function(path)
        path = translate_path(path)
        local ok, err = orig_remove(path)
        if ok then return ok end
        -- Windows os.remove cannot delete directories; fall back to rmdir
        return orig_execute('cmd /c rmdir /s /q "' .. path .. '" 2>nul')
    end

    -- lfs is a C module whose functions (attributes, dir, mkdir, rmdir)
    -- take file-system paths.  Wrap them so /tmp/ is translated on the
    -- way in, just like io.open/os.rename.
    do
        local lfs_loaded = false
        local orig_require = require
        require = function(name)
            local mod = orig_require(name)
            if name == "lfs" and not lfs_loaded then
                lfs_loaded = true
                local function wrap_lfs_fn(fn)
                    return function(...)
                        local args = {...}
                        for i = 1, #args do
                            if type(args[i]) == "string" then
                                args[i] = translate_path(args[i])
                            end
                        end
                        return fn(table.unpack(args))
                    end
                end
                mod.attributes = wrap_lfs_fn(mod.attributes)
                mod.dir        = wrap_lfs_fn(mod.dir)
                mod.mkdir      = wrap_lfs_fn(mod.mkdir)
                mod.rmdir      = wrap_lfs_fn(mod.rmdir)
            end
            return mod
        end
    end

    orig_rename = os.rename
    os.rename = function(old, new)
        old = translate_path(old)
        new = translate_path(new)
        -- Windows rename(2) fails if the destination exists (unlike POSIX
        -- which atomically replaces it).  Remove the destination first to
        -- match the POSIX semantics that JsonStore.write and other code
        -- rely on for the temp-then-rename pattern.
        orig_remove(new)
        return orig_rename(old, new)
    end
end


local helpers = require("spec.test_helpers")


-- ----------------------------------------------------------------------------
-- Find spec files
-- ----------------------------------------------------------------------------

local lfs = require("lfs")

local function find_specs(dir)
    local results = {}
    for entry in lfs.dir(dir) do
        if entry:match("_spec%.lua$") then
            table.insert(results, dir .. "/" .. entry)
        end
    end
    table.sort(results)
    return results
end


local spec_files = find_specs(plugin_root .. "/spec")
if #spec_files == 0 then
    io.stderr:write("no spec files found in " .. plugin_root .. "/spec\n")
    os.exit(1)
end


-- ----------------------------------------------------------------------------
-- Run each spec
-- ----------------------------------------------------------------------------

local function clear_syncery_modules()
    -- Make sure each spec starts with a fresh require of the modules
    -- under test.  Otherwise state leaks between specs (e.g. paths.lua
    -- holds a storage_mode set by a previous test).
    for key in pairs(package.loaded) do
        if key:match("^syncery_ann/")
                or key:match("^syncery_progress/")
                -- Phase 7 modules.  Both are already covered by the
                -- broad `^syncery_progress/` / `^syncery_lifecycle/`
                -- patterns above and below; listed explicitly so the
                -- stateful-module inventory stays greppable (the
                -- journal writes a file, wifi_backoff holds an
                -- in-flight attempt).
                or key:match("^syncery_progress/sync_journal")
                or key:match("^syncery_lifecycle/wifi_backoff")
                or key:match("^syncery_transports/")
                or key:match("^syncery_migration/")
                or key:match("^syncery_lifecycle/")
                or key:match("^syncery_ui/menu")
                or key:match("^syncery_ui/status_ui")
                or key:match("^syncery_ui/trash")
                or key:match("^syncery_ui/booklist")
                or key:match("^syncery_ui/status_section")
                or key:match("^syncery_ui/status_panel")
                or key == "syncery_ui"
                or key == "syncery_storage_mode"
                or key == "syncery_settings"
                -- syncery_util is stateless, but menu_test_support.lua
                -- installs a FAKE syncery_util into package.loaded; without
                -- clearing it that fake leaks into later specs (e.g.
                -- move_file_spec, which needs the real Util.move_file).
                or key == "syncery_util"
                or key == "spec.test_helpers" then
            package.loaded[key] = nil
        end
    end
end


local total_failed = 0
local total_passed = 0

for _, spec_path in ipairs(spec_files) do
    clear_syncery_modules()
    helpers = require("spec.test_helpers")
    helpers.reset_counters()

    local spec_name = spec_path:match("([^/]+)%.lua$")
    io.stdout:write("Running " .. spec_name .. " ...\n")

    local ok, err = pcall(dofile, spec_path)
    if not ok then
        io.stderr:write("  CRASH " .. spec_name .. " — " .. tostring(err) .. "\n")
        total_failed = total_failed + 1
    else
        local passed = helpers.report(spec_name)
        if passed then
            total_passed = total_passed + 1
        else
            total_failed = total_failed + 1
        end
    end

    helpers.teardown()
end


-- Clean up stale ./syncery/ tree from earlier test runs.  Created
-- when default_hash_root() falls back to "./syncery" (DataStorage not
-- available).  Safe to remove — not part of source tree.
--
-- On Windows, os.execute is patched (falls through to orig_execute
-- for cmd /c rmdir).  On Linux, rm -rf works natively.
do
    local artifact = plugin_root .. "/syncery"
    local lfs = require("lfs")
    if lfs.attributes(artifact, "mode") == "directory" then
        if package.config:sub(1,1) == "\\" then
            os.execute('cmd /c rmdir /s /q "' .. artifact .. '" 2>nul')
        else
            os.execute("rm -rf '" .. artifact .. "' 2>/dev/null")
        end
    end
end

-- Clean up Windows test artifacts that specs create in /tmp/ but never
-- explicitly remove (booklist_scan_spec creates 0-byte devsel_*.epub stubs).
-- On Linux these sit in a tmpfs mount that is wiped on reboot; on Windows
-- they would accumulate in %TEMP% indefinitely.
if package.config:sub(1,1) == "\\" then
    pcall(function()
        local tmp = (os.getenv("TEMP") or os.getenv("TMP") or "C:\\Temp"):gsub("\\", "/")
        local lfs = require("lfs")
        local ok, iter, obj = pcall(lfs.dir, tmp)
        if ok then
            for f in iter, obj do
                if type(f) == "string" and f:match("^devsel_.*%.epub$") then
                    local path = tmp .. "/" .. f
                    local attr = lfs.attributes(path)
                    if attr and attr.mode == "file" then
                        os.remove(path)
                    end
                end
            end
        end
    end)
end

io.stdout:write(string.format(
    "\nDone: %d spec(s) passed, %d failed\n", total_passed, total_failed))

os.exit(total_failed == 0 and 0 or 1)
