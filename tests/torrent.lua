package.path = "KMP/game/?.lua;" .. package.path
local Torrent = require("torrent")
local hash = "0123456789abcdef0123456789abcdef01234567"
local calls = {}
local backend = Torrent.new(function(method, params)
    calls[#calls + 1] = {method = method, params = params}
    if method == "aria2.tellActive" or method == "aria2.tellWaiting" or
       method == "aria2.tellStopped" then return {} end
    if method == "aria2.addUri" then return "abcdef1234567890" end
    if method == "aria2.tellStatus" then
        return {
            status = "active", totalLength = "1024", completedLength = "512",
            downloadSpeed = "2048", uploadSpeed = "128",
            infoHash = hash, connections = "1",
            files = {{uris = {{uri = "https://mirror.example/game.zip", status = "used"}}}}
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
assert(status.transport == "hybrid" and status.webSeedsConfigured)

assert(backend:start({
    magnet = "magnet:?xt=urn:btih:" .. hash,
    torrent = "ZDQ6aW5mb2Rl"
}, "/tmp/kmp"))
assert(calls[#calls].method == "aria2.addTorrent")
assert(require("json").encode(calls[#calls].params[2]) == "[]")
assert(backend:status(gid, string.rep("a", 40)) == nil)
assert(backend:stop(gid) == "OK")

local reused = Torrent.new(function(method, params)
    if method == "aria2.tellActive" then
        return {{gid = "feed1234", status = "active", infoHash = hash}}
    end
    if method == "aria2.tellWaiting" or method == "aria2.tellStopped" then return {} end
    error("torrent existente não deveria ser cadastrado novamente: " .. method)
end)
local reusedGid, reusedError, wasReused = reused:start(
    {magnet = "magnet:?xt=urn:btih:" .. hash, infoHash = hash}, "/tmp/kmp")
assert(reusedGid == "feed1234" and not reusedError and wasReused)

local replaced = {}
local moved = Torrent.new(function(method, params)
    replaced[#replaced + 1] = method
    if method == "aria2.tellActive" then
        return {{gid = "0dd1234", status = "complete", infoHash = hash,
            dir = "/tmp/old-location"}}
    end
    if method == "aria2.tellWaiting" or method == "aria2.tellStopped" then return {} end
    if method == "aria2.forceRemove" or method == "aria2.removeDownloadResult" then return "OK" end
    if method == "aria2.addUri" then return "new1234" end
    error("RPC inesperado: " .. method)
end)
local movedGid, movedError, movedReused = moved:start(
    {magnet = "magnet:?xt=urn:btih:" .. hash, infoHash = hash}, "/tmp/new-location")
assert(movedGid == "new1234" and not movedError and not movedReused)
assert(table.concat(replaced, ","):find("aria2.forceRemove,aria2.removeDownloadResult", 1, true),
    table.concat(replaced, ","))

local resumed = false
local paused = Torrent.new(function(method, params)
    if method == "aria2.tellActive" then return {} end
    if method == "aria2.tellWaiting" then
        return {{gid = "dead1234", status = "paused", infoHash = hash}}
    end
    if method == "aria2.unpause" then resumed = params[1]; return "OK" end
    return {}
end)
assert(paused:start({magnet = "magnet:?xt=urn:btih:" .. hash, infoHash = hash}, "/tmp/kmp") == "dead1234")
assert(resumed == "dead1234")

local peerBackend = Torrent.new(function(method, params)
    if method:match("^aria2%.tell") then return {} end
    return params[1][1]
end,
    {peer = "192.168.1.10:6881"})
local peerMagnet = assert(peerBackend:start({magnet = "magnet:?xt=urn:btih:" .. hash}, "/tmp/kmp"))
assert(peerMagnet:find("&x.pe=192.168.1.10:6881", 1, true))

local peerOnlyMethod
local peerOnly = Torrent.new(function(method, params)
    if method:match("^aria2%.tell") then return {} end
    peerOnlyMethod = method
    return params[1][1]
end, {peer = "192.168.1.10:6881", peerOnly = true})
local peerOnlyMagnet = assert(peerOnly:start({
    magnet = "magnet:?xt=urn:btih:" .. hash .. "&ws=https%3A%2F%2Fmirror.example%2Fgame.zip",
    torrent = "ZDQ6aW5mb2Rl", infoHash = hash
}, "/tmp/kmp"))
assert(peerOnlyMethod == "aria2.addUri")
assert(not peerOnlyMagnet:find("&ws=", 1, true))
assert(peerOnlyMagnet:find("&x.pe=192.168.1.10:6881", 1, true))

-- Nós públicos do catálogo entram como peers diretos, inclusive no teste só P2P.
local seededMagnet = assert(peerOnly:start({
    magnet = "magnet:?xt=urn:btih:" .. hash, infoHash = hash,
    seedNodes = {"163.176.18.211:6881", "inválido&x=1", 7}
}, "/tmp/kmp"))
assert(seededMagnet:find("&x.pe=163.176.18.211:6881", 1, true))
assert(not seededMagnet:find("inválido", 1, true))

local limitedOptions
local limitedPeerOnly = Torrent.new(function(method, params)
    if method:match("^aria2%.tell") then return {} end
    limitedOptions = params[2]
    return "cafe1234"
end, {peerOnly = true, downloadLimit = "1M"})
assert(limitedPeerOnly:start({magnet = "magnet:?xt=urn:btih:" .. hash,
    infoHash = hash}, "/tmp/kmp"))
assert(limitedOptions["max-download-limit"] == "1M")

local forgottenGid
local forgetBackend = Torrent.new(function(method, params)
    if method == "aria2.tellActive" then
        return {{gid = "face1234", status = "active", infoHash = hash}}
    end
    if method == "aria2.tellWaiting" or method == "aria2.tellStopped" then return {} end
    if method == "aria2.forceRemove" then forgottenGid = params[1]; return "OK" end
    if method == "aria2.saveSession" then return "OK" end
    error("RPC inesperado: " .. method)
end)
assert(forgetBackend:forget(hash))
assert(forgottenGid == "face1234")
-- Itens com torrent embutido recebem os nós públicos por kmp.addPeers, inclusive ao
-- reaproveitar um torrent existente; sem nós, o método não é chamado.
local peerCalls = {}
local seeded = Torrent.new(function(method, params)
    peerCalls[#peerCalls + 1] = {method = method, params = params}
    if method == "aria2.tellActive" or method == "aria2.tellWaiting" or method == "aria2.tellStopped" then return {} end
    if method == "aria2.addTorrent" then return "seed1234" end
    if method == "kmp.addPeers" then return #params[2] end
    error("RPC inesperado: " .. method)
end)
assert(seeded:start({magnet = "magnet:?xt=urn:btih:" .. hash, infoHash = hash, torrent = "ZDQ6aW5mb2Rl",
    seedNodes = {"163.176.18.211:6881", "inválido"}}, "/tmp/kmp") == "seed1234")
local last = peerCalls[#peerCalls]
assert(last.method == "kmp.addPeers" and last.params[1] == "seed1234")
assert(#last.params[2] == 1 and last.params[2][1] == "163.176.18.211:6881")
local before = #peerCalls
assert(seeded:addPeers("seed1234", {seedNodes = {}}) == 0 and #peerCalls == before)
local noPeerMethod = Torrent.new(function(method)
    if method == "aria2.tellActive" or method == "aria2.tellWaiting" or method == "aria2.tellStopped" then return {} end
    if method == "aria2.addTorrent" then return "aria1234" end
    return nil, "método desconhecido"
end)
assert(noPeerMethod:start({magnet = "magnet:?xt=urn:btih:" .. hash, infoHash = hash, torrent = "ZDQ6aW5mb2Rl",
    seedNodes = {"163.176.18.211:6881"}}, "/tmp/kmp") == "aria1234", "aria2 sem kmp.addPeers continua funcionando")

print("torrent tests: ok")
