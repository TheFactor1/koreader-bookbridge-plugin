-- Runs against a real update server. Env: BASE (server URL), PLUGIN_DIR
-- (scratch dir pre-seeded with an OLDER main.lua/_meta.lua).
local BASE = assert(os.getenv("BASE"), "BASE unset")
local DIR = getPluginDir()
local fails = 0
local function check(ok, label, detail)
  if not ok then fails = fails + 1 end
  print((ok and "PASS  " or "FAIL  ") .. label .. (detail and ("  -- " .. detail) or ""))
end

-- 1. A device running an older build must see exactly what changed.
local info, code, err = doCheckManifest(BASE, nil)
check(info ~= nil, "manifest fetched", err or ("HTTP " .. tostring(code)))
if not info then print("=== " .. fails .. " failure(s)") os.exit(1) end

-- Read-only mode: report exactly what the menu would say for this plugin
-- directory, and change nothing. Safe to point at the live install.
if os.getenv("CHECK_ONLY") then
  print(("       dir      %s"):format(DIR))
  print(("       server   v%s build %s"):format(tostring(info.version), tostring(info.build)))
  if #info.changed == 0 then
    print(("       menu     \"You're up to date (v%s build %s).\""):format(tostring(info.version), tostring(info.build)))
  else
    print(("       menu     \"A different build of v%s build %s is available.  Changed: %s\"")
      :format(tostring(info.version), tostring(info.build), table.concat(info.changed, ", ")))
  end
  os.exit(0)
end
check(info.manifest == true and info.version ~= nil, "manifest parsed",
  "version=" .. tostring(info.version) .. " build=" .. tostring(info.build))
check(not info.unverifiable, "local files hashable (ffi/sha2 present)")
check(#info.changed == 1 and info.changed[1] == "main.lua",
  "detects the stale file", "changed={" .. table.concat(info.changed, ",") .. "}")

-- 2. A stale/incorrect manifest must be refused, not installed. This is the
--    guard that makes "forgot to run make-manifest.sh" a safe failure.
local bad = { manifest = true, base = info.base, version = info.version, files = {
  ["main.lua"]  = { sha256 = string.rep("0", 64) },
  ["_meta.lua"] = info.files["_meta.lua"],
} }
local before = sha256OfFile(DIR .. "/main.lua")
local applied, apply_err = doApplyUpdate(bad, nil)
check(applied == nil, "checksum mismatch refused", tostring(apply_err):sub(1, 60))
check(sha256OfFile(DIR .. "/main.lua") == before, "refused install left the old file intact")
local leftover = io.open(DIR .. "/main.lua.update-tmp")
check(leftover == nil, "no temp files left behind")
if leftover then leftover:close() end

-- 3. The real install.
local ok2, err2 = doApplyUpdate(info, nil)
check(ok2 == true, "update installed", tostring(err2))
check(sha256OfFile(DIR .. "/main.lua") == info.files["main.lua"].sha256:lower(),
  "installed file matches the manifest checksum")
local chunk = loadfile(DIR .. "/main.lua")
check(chunk ~= nil, "installed file compiles")

-- 4. Re-checking now reports up to date.
local info2 = doCheckManifest(BASE, nil)
check(info2 ~= nil and #info2.changed == 0, "re-check reports up to date",
  info2 and ("changed=" .. #info2.changed) or "no manifest")

-- 5. A bad base URL fails cleanly rather than throwing.
-- The everyday failure: a Kindle away from home can't see the server at
-- all. That must read as unreachable, not as an HTTP status code.
local none, _c, none_err = doCheckManifest("http://127.0.0.1:9/nope", nil)
check(none == nil and none_err ~= nil, "unreachable server reports an error", tostring(none_err))
check(none_err ~= nil and tostring(none_err):find("Couldn't reach") ~= nil,
  "unreachable error names the real problem", tostring(none_err))

-- A server that answers but has no manifest is a different failure again.
local nf, nf_code, nf_err = doCheckManifest(BASE .. "/nope", nil)
check(nf == nil and nf_code == 404, "missing manifest reports HTTP 404", tostring(nf_err))

print("=== " .. fails .. " failure(s)")
os.exit(fails == 0 and 0 or 1)
