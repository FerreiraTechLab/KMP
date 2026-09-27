package.path = "KMP/game/?.lua;" .. package.path
local Control = require("seed_control")
local calls = {}
local function rpc(method, params)
    calls[#calls + 1] = {method = method, params = params}
    if method == "aria2.tellActive" then
        return {{gid = "seed", status = "active", seeder = "true"},
            {gid = "download", status = "active", seeder = "false"}}
    end
    if method == "aria2.tellWaiting" then
        return {{gid = "paused", status = "paused", seeder = "true"}}
    end
    return "OK"
end
assert(Control.pauseAll(rpc) == 1)
assert(calls[2].method == "aria2.forcePause" and calls[2].params[1] == "seed")
assert(Control.resumeAll(rpc) == 1)
assert(calls[4].method == "aria2.unpause" and calls[4].params[1] == "paused")
print("seed control tests: ok")
