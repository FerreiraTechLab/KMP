package.path = "KMP/game/?.lua;" .. package.path
local Torrent = require("torrent")
local hash = "0123456789abcdef0123456789abcdef01234567"
local calls = {}
local backend = Torrent.new(function(method, params)
    calls[#calls + 1] = {method = method, params = params}
    if method == "aria2.addUri" then return "abcdef1234567890" end
    if method == "aria2.tellStatus" then
        return {
            status = "active", totalLength = "1024", completedLength = "512",
            downloadSpeed = "2048", uploadSpeed = "128",
            infoHash = hash
        }
    end
    return "OK"
end)

local gid = assert(backend:start({magnet = "magnet:?xt=urn:btih:" .. hash}, "/tmp/kmp"))
assert(gid == "abcdef1234567890")
assert(calls[1].method == "aria2.addUri")
assert(calls[1].params[2]["max-upload-limit"] == "100K")
local status = assert(backend:status(gid, hash))
assert(status.percent == 50 and status.downloadBytesPerSecond == 2048)
assert(backend:status(gid, string.rep("a", 40)) == nil)
assert(backend:stop(gid) == "OK")

local peerBackend = Torrent.new(function(_, params) return params[1][1] end,
    {peer = "192.168.1.10:6881"})
local peerMagnet = assert(peerBackend:start({magnet = "magnet:?xt=urn:btih:" .. hash}, "/tmp/kmp"))
assert(peerMagnet:find("&x.pe=192.168.1.10:6881", 1, true))
print("torrent tests: ok")
