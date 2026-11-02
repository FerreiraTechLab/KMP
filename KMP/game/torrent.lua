-- Protocol-independent transfer state backed by aria2 JSON-RPC.
-- `rpc(method, params)` is supplied by the runtime transport and returns
-- the decoded `result` or nil plus a readable error.
local Torrent = {}
Torrent.__index = Torrent
local Json = require("json")

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

function Torrent:find(expectedHash, expectedDirectory)
    if type(expectedHash) ~= "string" or not expectedHash:match("^[0-9a-fA-F]+$") then
        return nil
    end
    local keys = {"gid", "status", "infoHash", "dir"}
    local groups = {
        {"aria2.tellActive", {keys}},
        {"aria2.tellWaiting", {0, 1000, keys}},
        {"aria2.tellStopped", {0, 1000, keys}},
    }
    for _, query in ipairs(groups) do
        local items = self.rpc(query[1], query[2])
        if type(items) == "table" then
            for _, item in ipairs(items) do
                if type(item.infoHash) == "string" and
                   item.infoHash:lower() == expectedHash:lower() and
                   type(item.gid) == "string" and item.gid:match("^[0-9a-fA-F]+$") then
                    if type(expectedDirectory) == "string" and expectedDirectory ~= "" and
                       type(item.dir) == "string" and item.dir ~= "" and
                       item.dir ~= expectedDirectory then
                        local removed, removeError = self.rpc("aria2.forceRemove", {item.gid})
                        if removed == nil then
                            return nil, removeError or "falha ao substituir torrent em diretório antigo"
                        end
                        self.rpc("aria2.removeDownloadResult", {item.gid})
                        return nil
                    elseif item.status == "paused" then
                        local resumed, err = self.rpc("aria2.unpause", {item.gid})
                        if resumed == nil then return nil, err or "não foi possível retomar o torrent" end
                    elseif item.status == "error" or item.status == "removed" then
                        self.rpc("aria2.removeDownloadResult", {item.gid})
                        return nil
                    end
                    return item.gid, nil, true
                end
            end
        end
    end
    return nil
end

function Torrent:forget(expectedHash)
    if type(expectedHash) ~= "string" or not expectedHash:match("^[0-9a-fA-F]+$") then
        return nil, "infoHash inválido"
    end
    local keys = {"gid", "status", "infoHash"}
    local groups = {
        {"aria2.tellActive", {keys}},
        {"aria2.tellWaiting", {0, 1000, keys}},
        {"aria2.tellStopped", {0, 1000, keys}},
    }
    for _, query in ipairs(groups) do
        local items, err = self.rpc(query[1], query[2])
        if items == nil then return nil, err or "falha ao consultar torrents" end
        for _, item in ipairs(type(items) == "table" and items or {}) do
            if type(item.infoHash) == "string" and
               item.infoHash:lower() == expectedHash:lower() and type(item.gid) == "string" then
                if item.status == "active" or item.status == "waiting" or item.status == "paused" then
                    local removed, removeError = self.rpc("aria2.forceRemove", {item.gid})
                    if removed == nil then return nil, removeError or "falha ao remover torrent anterior" end
                else
                    self.rpc("aria2.removeDownloadResult", {item.gid})
                end
            end
        end
    end
    local saved, saveError = self.rpc("aria2.saveSession", {})
    if saved == nil then return nil, saveError or "falha ao persistir remoção do torrent" end
    return true
end

function Torrent:start(item, directory)
    if type(item) ~= "table" or type(item.magnet) ~= "string" or
       type(directory) ~= "string" or directory == "" then
        return nil, "pacote ou destino inválido"
    end
    local existing, findError, reused = self:find(item.infoHash, directory)
    if findError then return nil, findError end
    if existing then return existing, nil, reused end
    local magnet = item.magnet
    if self.settings.peerOnly then
        magnet = magnet:gsub("&ws=[^&]*", "")
    end
    if self.settings.peer then
        if not self.settings.peer:match("^%d+%.%d+%.%d+%.%d+:%d+$") then
            return nil, "peer direto inválido; use IPv4:porta"
        end
        magnet = magnet .. "&x.pe=" .. self.settings.peer
    end
    -- Nós públicos do catálogo assinado: um peer sempre alcançável e uma ponte de
    -- hole punching, mesmo antes de trackers e DHT responderem.
    for _, node in ipairs(type(item.seedNodes) == "table" and item.seedNodes or {}) do
        if type(node) == "string" and node:match("^%d+%.%d+%.%d+%.%d+:%d+$") then
            magnet = magnet .. "&x.pe=" .. node
        end
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
    if self.settings.downloadLimit then
        options["max-download-limit"] = self.settings.downloadLimit
    end
    if not self.settings.peerOnly and type(item.torrent) == "string" and item.torrent ~= "" then
        return self.rpc("aria2.addTorrent", {item.torrent, Json.array(), options})
    end
    return self.rpc("aria2.addUri", {{magnet}, options})
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
    local webSeedsConfigured = false
    local webSeedActive = false
    for _, file in ipairs(type(raw.files) == "table" and raw.files or {}) do
        for _, uri in ipairs(type(file.uris) == "table" and file.uris or {}) do
            if type(uri.uri) == "string" and uri.uri:match("^https?://") then
                webSeedsConfigured = true
                if uri.status == "used" then webSeedActive = true end
            end
        end
    end
    local connections = tonumber(raw.connections) or 0
    local transport = webSeedActive and connections > 0 and "hybrid" or
        (webSeedActive and "webseed" or (connections > 0 and "peers" or "waiting"))
    local result = {
        phase = phase,
        totalBytes = total,
        downloadedBytes = done,
        percent = total > 0 and math.min(100, math.floor(done * 100 / total)) or 0,
        downloadBytesPerSecond = tonumber(raw.downloadSpeed) or 0,
        uploadBytesPerSecond = tonumber(raw.uploadSpeed) or 0,
        connections = connections,
        seeders = tonumber(raw.numSeeders) or 0,
        errorCode = raw.errorCode,
        errorMessage = raw.errorMessage,
        files = raw.files,
        infoHash = hash, transport = transport,
        webSeedsConfigured = webSeedsConfigured
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
