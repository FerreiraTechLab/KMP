local SeedControl = {}
local KEYS = {"gid", "status", "seeder"}

function SeedControl.pauseAll(rpc)
    local active, err = rpc("aria2.tellActive", {KEYS})
    if not active then return nil, err end
    local count = 0
    for _, item in ipairs(active) do
        if item.seeder == "true" and item.status == "active" then
            local ok, pauseError = rpc("aria2.forcePause", {item.gid})
            if not ok then return nil, pauseError end
            count = count + 1
        end
    end
    return count
end

function SeedControl.resumeAll(rpc)
    local waiting, err = rpc("aria2.tellWaiting", {0, 1000, KEYS})
    if not waiting then return nil, err end
    local count = 0
    for _, item in ipairs(waiting) do
        if item.seeder == "true" and item.status == "paused" then
            local ok, resumeError = rpc("aria2.unpause", {item.gid})
            if not ok then return nil, resumeError end
            count = count + 1
        end
    end
    return count
end

return SeedControl
