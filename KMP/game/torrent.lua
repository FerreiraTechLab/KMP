-- Protocol-independent transfer state backed by aria2 JSON-RPC.
-- `rpc(method, params)` is supplied by the runtime transport and returns
-- the decoded `result` or nil plus a readable error.
local Torrent = {}
Torrent.__index = Torrent

local STATUS_KEYS = {
    "status", "totalLength", "completedLength", "downloadSpeed",
    "uploadSpeed", "errorCode", "errorMessage", "infoHash", "seeder",
    "numSeeders", "connections", "files", "followedBy"
}

function Torrent.new(rpc, settings)
    assert(type(rpc) == "function", "rpc function required")
    settings = settings or {}
    return setmetatable({rpc = rpc, settings = settings}, Torrent)
end

function Torrent:start(item, directory)
    if type(item) ~= "table" or type(item.magnet) ~= "string" or
       type(directory) ~= "string" or directory == "" then
        return nil, "pacote ou destino inválido"
    end
    local options = {
        dir = directory,
        ["continue"] = "true",
        ["check-integrity"] = "true",
        ["bt-max-peers"] = tostring(self.settings.maxPeers or 20),
        ["max-upload-limit"] = self.settings.uploadLimit or "100K",
        ["seed-time"] = tostring(self.settings.seedMinutes or 120),
        ["seed-ratio"] = tostring(self.settings.seedRatio or 1.0)
    }
    return self.rpc("aria2.addUri", {{item.magnet}, options})
end

function Torrent:status(gid, expectedHash)
    if type(gid) ~= "string" or not gid:match("^[0-9a-fA-F]+$") then
        return nil, "identificador de transferência inválido"
    end
    local raw, err = self.rpc("aria2.tellStatus", {gid, STATUS_KEYS})
    if not raw then return nil, err or "falha ao consultar a transferência" end
    if raw.followedBy and raw.followedBy[1] then
        return {phase = "metadata", nextGid = raw.followedBy[1]}
    end
    local hash = raw.infoHash
    if hash and expectedHash and hash:lower() ~= expectedHash:lower() then
        return nil, "infoHash do torrent não corresponde ao catálogo"
    end
    local total = tonumber(raw.totalLength) or 0
    local done = tonumber(raw.completedLength) or 0
    local phase = raw.status or "unknown"
    if phase == "active" and raw.seeder == "true" then phase = "seeding" end
    local result = {
        phase = phase,
        totalBytes = total,
        downloadedBytes = done,
        percent = total > 0 and math.min(100, math.floor(done * 100 / total)) or 0,
        downloadBytesPerSecond = tonumber(raw.downloadSpeed) or 0,
        uploadBytesPerSecond = tonumber(raw.uploadSpeed) or 0,
        connections = tonumber(raw.connections) or 0,
        seeders = tonumber(raw.numSeeders) or 0,
        errorCode = raw.errorCode,
        errorMessage = raw.errorMessage,
        files = raw.files,
        infoHash = hash
    }
    if phase == "complete" and not hash then
        return nil, "transferência concluída sem metadados BitTorrent"
    end
    return result
end

function Torrent:stop(gid)
    if type(gid) ~= "string" or not gid:match("^[0-9a-fA-F]+$") then
        return nil, "identificador de transferência inválido"
    end
    return self.rpc("aria2.forceRemove", {gid})
end

return Torrent
