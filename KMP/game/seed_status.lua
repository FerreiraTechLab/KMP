local SeedStatus = {}

local KEYS = {"gid", "status", "infoHash", "seeder", "connections",
    "uploadSpeed", "uploadLength", "totalLength"}

function SeedStatus.find(rpc, expectedHash)
    if type(rpc) ~= "function" or type(expectedHash) ~= "string" then
        return nil, "consulta inválida"
    end
    local groups = {
        {"aria2.tellActive", {KEYS}},
        {"aria2.tellWaiting", {0, 1000, KEYS}},
        {"aria2.tellStopped", {0, 1000, KEYS}},
    }
    for _, query in ipairs(groups) do
        local items, err = rpc(query[1], query[2])
        if not items then return nil, err or "daemon indisponível" end
        for _, item in ipairs(items) do
            if type(item.infoHash) == "string" and
               item.infoHash:lower() == expectedHash:lower() then
                local total = tonumber(item.totalLength) or 0
                local uploaded = tonumber(item.uploadLength) or 0
                return {found = true, phase = item.status or "unknown",
                    seeding = item.seeder == "true" and item.status == "active",
                    paused = item.status == "paused",
                    connections = tonumber(item.connections) or 0,
                    uploadSpeed = tonumber(item.uploadSpeed) or 0,
                    uploaded = uploaded,
                    ratio = total > 0 and uploaded / total or 0}
            end
        end
    end
    return {found = false}
end

return SeedStatus
