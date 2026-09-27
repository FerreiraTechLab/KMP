package.path = "KMP/game/?.lua;" .. package.path
local SeedStatus = require("seed_status")
local hash = "0123456789abcdef0123456789abcdef01234567"
local methods = {}
local function rpc(method)
    methods[#methods + 1] = method
    if method == "aria2.tellActive" then return {} end
    if method == "aria2.tellWaiting" then
        return {{gid = "abc", status = "paused", infoHash = hash, seeder = "true",
            connections = "0", uploadSpeed = "0", uploadLength = "2048", totalLength = "1024"}}
    end
    error(method)
end
local result = assert(SeedStatus.find(rpc, hash))
assert(result.found and result.paused and result.ratio == 2)
assert(result.uploaded == 2048 and #methods == 2)

local missing = assert(SeedStatus.find(function() return {} end, hash))
assert(not missing.found)
print("seed status tests: ok")
