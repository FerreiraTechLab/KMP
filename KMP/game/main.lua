-- ============================================================
-- KDownloader PM - catálogo versionado e transferência BitTorrent
-- ============================================================

local Json = require("json")
local Catalog = require("catalog")
local APP_VERSION = require("version")
local CATALOG_URL = os.getenv("KMP_CATALOG_URL") or ""
local CATALOG_SYNC = os.getenv("KMP_CATALOG_SYNC") or ""
local CATALOG_SOURCES = os.getenv("KMP_CATALOG_SOURCES") or ""
local CATALOG_PUBLIC_KEY = os.getenv("KMP_CATALOG_PUBLIC_KEY") or ""
local CATALOG_STATE = os.getenv("KMP_CATALOG_STATE") or ""
local CATALOG_PENDING = os.getenv("KMP_CATALOG_PENDING") or ""
local CATALOG_DOWNLOADS = os.getenv("KMP_CATALOG_DOWNLOADS") or ""
local CATALOG_ACTIVE = os.getenv("KMP_CATALOG_ACTIVE") or ""

local sdPaths = { "/roms/ports", "/roms2/ports" }
local sdLabels = { "SD1 (/roms)", "SD2 (/roms2)" }
local currentSd = 1
local scrollY = 0

local scale = 1
local offsetX = 0
local offsetY = 0

local appState = "splash"
local splashTimer = 0
local logoImg = nil

local showMenu = false
local menuSelected = 1
local powerMenuSelected = 1
local showSearch = false
local searchQuery = ""
local searchSelected = 1
local searchChars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
local showDetails = false
local detailsSeed = {loading = false, found = false}
local catalogTrust = {
    configured = false, verified = false, active = false, sequence = 0,
    mirrors = 0, healthyMirrors = 0, fingerprint = "", expiresAt = "", error = ""
}

local showRestartPopup = false
local restartPopupTimer = 0

local showUninstallPopup = false
local gameToUninstall = nil

local installedPorts = {}
local uninstallerSelectedIdx = 1
local uninstallerScrollY = 0
local uninstallError = ""

local bgm = nil
local bgmVolume = 0.5
local isMusicPaused = false

local catalog = {}
local catalogAll = {}
local selectedIdx = 1
local fontTitle, fontItem, fontSub, fontSmall
local syncStatus = "Conectando..."
local isOffline = true
local syncing = false
local syncStartedAt = 0

local download = {
    active = false,
    phase = "none",
    progress = 0,
    ext_progress = 0,
    game = nil,
    statusText = "Aguarde, verificando conexao...",
    statusColor = {0.55, 0.62, 0.72},
    speedBps = 0
}

local function isWindows() return love.system.getOS() == "Windows" end

local function isInstalled(game)
    local basePorts = sdPaths[currentSd]
    if isWindows() then basePorts = "." end

    local manifest = basePorts .. "/.kmp/manifests/" .. game.install.portId .. ".json"
    local handle = io.open(manifest, "r")
    if handle then handle:close(); return true end
    return false
end

local function checkLocalFiles()
    for _, game in ipairs(catalogAll) do
        game.installed = isInstalled(game)
    end
end

local function applySearch()
    catalog = Catalog.search(catalogAll, searchQuery)
    selectedIdx = 1
    scrollY = 0
end

local function startSeedStatus(game)
    detailsSeed = {loading = false, found = false}
    if not game or not game.installed then return end
    local endpoint = os.getenv("KMP_ARIA2_RPC")
    local secret = os.getenv("KMP_ARIA2_SECRET")
    if not endpoint or endpoint == "" or not secret or secret == "" then
        detailsSeed.error = "daemon BitTorrent indisponivel"
        return
    end
    detailsSeed.loading = true
    while love.thread.getChannel("seed_status_done"):pop() do end
    local worker = love.thread.newThread([[
        local endpoint, secret, infoHash = ...
        local Rpc = require("aria2_rpc")
        local SeedStatus = require("seed_status")
        local ok, result, err = pcall(SeedStatus.find, Rpc.new(endpoint, secret), infoHash)
        if not ok then result, err = nil, tostring(result) end
        love.thread.getChannel("seed_status_done"):push(
            result or {error = err or "status indisponivel"})
    ]])
    worker:start(endpoint, secret, game.infoHash)
end

local function startSeedAction(action, game)
    if detailsSeed.loading then return end
    local endpoint = os.getenv("KMP_ARIA2_RPC")
    local secret = os.getenv("KMP_ARIA2_SECRET")
    if not endpoint or not secret then return end
    if (action == "pause_one" or action == "resume_one") and not detailsSeed.gid then return end
    detailsSeed.loading = true
    while love.thread.getChannel("seed_action_done"):pop() do end
    local worker = love.thread.newThread([[
        local endpoint, secret, action, gid = ...
        local Rpc = require("aria2_rpc")
        local Control = require("seed_control")
        local rpc = Rpc.new(endpoint, secret)
        local ok, result, err
        if action == "pause_one" then
            result, err = rpc("aria2.forcePause", {gid}); ok = result ~= nil
        elseif action == "resume_one" then
            result, err = rpc("aria2.unpause", {gid}); ok = result ~= nil
        elseif action == "pause_all" then
            result, err = Control.pauseAll(rpc); ok = result ~= nil
        else
            result, err = Control.resumeAll(rpc); ok = result ~= nil
        end
        love.thread.getChannel("seed_action_done"):push({ok = ok, action = action,
            count = type(result) == "number" and result or nil, error = err})
    ]])
    worker:start(endpoint, secret, action, detailsSeed.gid or "")
end

local function scanInstalledPorts()
    installedPorts = {}
    uninstallError = ""
    local function scanDir(basePath, label)
        local seen = {}
        local manifests = io.popen('ls -1 "' .. basePath .. '/.kmp/manifests/"*.json 2>/dev/null')
        if manifests then
            for manifestPath in manifests:lines() do
                local file = io.open(manifestPath, "r")
                local data = file and file:read("*a")
                if file then file:close() end
                local record = data and Json.decode(data)
                if record and type(record.portId) == "string" and
                   record.portId:match("^[a-z0-9][a-z0-9_-]*$") then
                    local script = record.portId .. ".sh"
                    for _, root in ipairs(record.roots or {}) do
                        if type(root) == "string" and root:match("%.sh$") then script = root; break end
                    end
                    seen[script] = true
                    table.insert(installedPorts, {
                        name = record.id or record.portId,
                        filename = script,
                        path = basePath,
                        label = label,
                        portId = record.portId,
                        managed = true
                    })
                end
            end
            manifests:close()
        end
        local h = io.popen('ls -1 "' .. basePath .. '"/*.sh 2>/dev/null')
        if h then
            for file in h:lines() do
                local name = file:match("([^/]+)%.sh$")
                if name and not seen[name .. ".sh"] then
                    table.insert(installedPorts, {
                        name = name,
                        filename = name .. ".sh",
                        path = basePath,
                        label = label,
                        managed = false
                    })
                end
            end
            h:close()
        end
    end
    
    if isWindows() then
        scanDir(".", "PC (Simulado)")
    else
        scanDir("/roms/ports", "SD1")
        scanDir("/roms2/ports", "SD2")
    end
    
    uninstallerSelectedIdx = 1
    uninstallerScrollY = 0
end

function startSync()
    catalog = {}
    catalogAll = {}
    syncStatus = "Sincronizando..."
    download.statusText = "Conectando ao servidor..."
    download.statusColor = {0.55, 0.62, 0.72}
    isOffline = false
    syncing = true
    syncStartedAt = love.timer.getTime()

    local distributed = CATALOG_SYNC ~= "" and CATALOG_SOURCES ~= "" and
        CATALOG_PUBLIC_KEY ~= "" and CATALOG_ACTIVE ~= "" and
        (os.getenv("KMP_ARIA2_RPC") or "") ~= ""
    if not distributed and CATALOG_URL == "" then
        syncStatus = "Sem Catálogo"
        download.statusText = "Configure KMP/catalog-url.txt."
        download.statusColor = {1.0, 0.3, 0.3}
        isOffline = true
        syncing = false
        return
    end

    local savePath = distributed and CATALOG_ACTIVE or
        (isWindows() and "kpm_catalog.json" or "/tmp/kpm_catalog.json")
    if distributed then
        local resultPath = "/tmp/kmp_catalog_sync_result.json"
        os.remove(resultPath)
        local sync_thread = love.thread.newThread([[
            local script, sources, publicKey, state, pending, downloads,
                active, endpoint, secret, resultPath = ...
            local function quote(value) return "'" .. tostring(value):gsub("'", "'\\''") .. "'" end
            local command = "python3 " .. quote(script) .. " sync" ..
                " --sources " .. quote(sources) .. " --public-key " .. quote(publicKey) ..
                " --state " .. quote(state) .. " --pending " .. quote(pending) ..
                " --downloads " .. quote(downloads) .. " --active " .. quote(active) ..
                " --rpc " .. quote(endpoint) .. " --secret " .. quote(secret) ..
                " > " .. quote(resultPath) .. " 2>&1"
            local result = os.execute(command)
            local ok = result == true or result == 0
            love.thread.getChannel("sync_done"):push({distributed = true, ok = ok})
        ]])
        sync_thread:start(CATALOG_SYNC, CATALOG_SOURCES, CATALOG_PUBLIC_KEY,
            CATALOG_STATE, CATALOG_PENDING, CATALOG_DOWNLOADS, CATALOG_ACTIVE,
            os.getenv("KMP_ARIA2_RPC"), os.getenv("KMP_ARIA2_SECRET"), resultPath)
        return
    end
    os.remove(savePath)

    local sync_thread = love.thread.newThread([[
        local url, path = ...
        local function quote(value) return "'" .. tostring(value):gsub("'", "'\\''") .. "'" end
        os.execute('curl -L --fail --silent --show-error --max-time 20 -A "Mozilla/5.0" ' ..
            quote(url) .. ' -o ' .. quote(path) .. ' 2>/dev/null')
        love.thread.getChannel("sync_done"):push(true)
    ]])
    sync_thread:start(CATALOG_URL, savePath)
end

local function decodeCatalog(content)
    if type(content) ~= "string" or #content < 5 then return nil, "servidor não retornou dados" end
    if #content > 8 * 1024 * 1024 then return nil, "catálogo excede 8 MB" end
    local head = content:sub(1, 200):lower()
    if head:find("<!doctype", 1, true) or head:find("<html", 1, true) then
        return nil, "servidor devolveu HTML"
    end
    local parsed, errorMessage = Json.decode(content)
    if type(parsed) ~= "table" then return nil, errorMessage or "JSON inválido" end
    if parsed.error then return nil, "script: " .. tostring(parsed.error):sub(1, 60) end
    local items, validationError = Catalog.validate(parsed)
    if not items then return nil, validationError end
    for _, item in ipairs(items) do
        item.filename = item.packageFile
        item.size = item.sizeBytes < 1048576 and
            string.format("%.1f KB", item.sizeBytes / 1024) or
            string.format("%.1f MB", item.sizeBytes / 1048576)
    end
    return items
end

local function saveCatalogCache(content)
    if not love.filesystem.write("catalog-cache.json.tmp", content) then return end
    local saveDirectory = love.filesystem.getSaveDirectory()
    os.rename(saveDirectory .. "/catalog-cache.json.tmp", saveDirectory .. "/catalog-cache.json")
end

function finishSync(event)
    syncing = false
    local distributed = type(event) == "table" and event.distributed
    local savePath = distributed and CATALOG_ACTIVE or
        (isWindows() and "kpm_catalog.json" or "/tmp/kpm_catalog.json")
    local file = io.open(savePath, "r")
    local content = file and file:read("*a") or nil
    if file then file:close() end
    local items, errorMessage = decodeCatalog(content)
    local fromCache = distributed and not event.ok or false
    if not items and not distributed then
        local cached = love.filesystem.read("catalog-cache.json")
        items = decodeCatalog(cached)
        fromCache = items ~= nil
    end
    if not items then
        syncStatus = "Modo Offline"
        download.statusText = errorMessage or "Sem Internet ou catálogo válido."
        download.statusColor = {1.0, 0.3, 0.3}
        isOffline = true
        return
    end
    catalogAll = items
    applySearch()
    if not fromCache and not distributed then saveCatalogCache(content) end
    checkLocalFiles()
    local mode = distributed and "Distribuído" or "Online"
    syncStatus = (fromCache and "Offline" or mode) .. " (" .. #catalogAll .. " ports)"
    download.statusText = fromCache and "Usando catálogo salvo." or "Lista sincronizada com sucesso!"
    download.statusColor = {0.2, 0.85, 0.45}
    isOffline = fromCache
end

function love.load()
    local screenW, screenH = love.graphics.getDimensions()
    scale = math.min(screenW / 640, screenH / 480)
    offsetX = math.floor((screenW - (640 * scale)) / 2)
    offsetY = math.floor((screenH - (480 * scale)) / 2)

    fontTitle = love.graphics.newFont(18)
    fontItem  = love.graphics.newFont(16)
    fontSub   = love.graphics.newFont(12)
    fontSmall = love.graphics.newFont(12)

    if not love.filesystem.getInfo("/roms/ports") and love.filesystem.getInfo("/roms2/ports") then
        currentSd = 2
    end

    if love.filesystem.getInfo("logo.png") then
        logoImg = love.graphics.newImage("logo.png")
    end

    if love.audio and love.filesystem.getInfo("bgm.ogg") then
        bgm = love.audio.newSource("bgm.ogg", "stream")
    elseif love.audio and love.filesystem.getInfo("bgm.mp3") then
        bgm = love.audio.newSource("bgm.mp3", "stream")
    end

    if bgm then
        bgm:setLooping(true)
        bgm:setVolume(bgmVolume)
        bgm:play()
    end

    startSync()
end

function love.update(dt)
    if showDetails and detailsSeed.loading then
        local actionEvent = love.thread.getChannel("seed_action_done"):pop()
        if actionEvent then
            if actionEvent.ok then
                local labels = {pause_one = "Semeacao pausada.", resume_one = "Semeacao retomada.",
                    pause_all = "Todos os seeds foram pausados.",
                    resume_all = "Todos os seeds foram retomados."}
                download.statusText = labels[actionEvent.action] or "Semeacao atualizada."
                download.statusColor = {0.2, 0.85, 0.45}
            else
                download.statusText = "Erro na semeacao: " .. tostring(actionEvent.error or "indisponivel")
                download.statusColor = {1.0, 0.3, 0.3}
            end
            startSeedStatus(catalog[selectedIdx])
        end
    end
    if showDetails and detailsSeed.loading then
        local seedEvent = love.thread.getChannel("seed_status_done"):pop()
        if seedEvent then
            detailsSeed = seedEvent
            detailsSeed.loading = false
        end
    end
    if appState == "splash" then
        splashTimer = splashTimer + dt
        if syncing then
            local syncEvent = love.thread.getChannel("sync_done"):pop()
            if syncEvent then
                finishSync(syncEvent)
            elseif love.timer.getTime() - syncStartedAt >= 12 and CATALOG_ACTIVE ~= "" then
                finishSync({distributed = true, ok = false})
            end
        else
            if splashTimer >= 2.0 then
                appState = "main"
            end
        end
        return
    end

    if syncing then
        local syncEvent = love.thread.getChannel("sync_done"):pop()
        if syncEvent then
            finishSync(syncEvent)
        end
    end

    if restartPopupTimer > 0 then
        restartPopupTimer = restartPopupTimer - dt
        if restartPopupTimer <= 0 then
            showRestartPopup = false
        end
    end

    local torrentEvent = love.thread.getChannel("torrent_event"):pop()
    if torrentEvent and download.active then
        if torrentEvent.kind == "progress" then
            download.phase = "baixando"
            download.progress = torrentEvent.percent or 0
            download.speedBps = torrentEvent.speed or 0
            download.downloadedBytes = torrentEvent.done or 0
            download.totalBytes = torrentEvent.total or 0
            local route = torrentEvent.transport == "webseed" and "mirror HTTPS" or
                (torrentEvent.transport == "peers" and "peers" or nil)
            download.statusText = torrentEvent.waiting and "Procurando fontes..." or
                string.format("Baixando via %s... (%d%%)", route or "rede", download.progress)
            download.statusColor = {0.0, 0.82, 1.0}
        elseif torrentEvent.kind == "installing" then
            download.phase = "extraindo"
            download.progress = 100
            download.statusText = "Verificado. Instalando pacote..."
            download.statusColor = {0.7, 0.4, 1.0}
        elseif torrentEvent.kind == "done" then
            download.active = false
            download.phase = "none"
            download.progress = 100
            download.ext_progress = 100
            download.statusText = "Concluído! " .. download.game.name .. " instalado."
            download.statusColor = {0.2, 0.85, 0.45}
            checkLocalFiles()
            showRestartPopup = true
            restartPopupTimer = 8
        elseif torrentEvent.kind == "error" then
            download.active = false
            download.phase = "none"
            download.statusText = "Erro: " .. tostring(torrentEvent.message)
            download.statusColor = {1.0, 0.3, 0.3}
        end
    end

end

local function shellQuote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function startTorrentDownload(game)
    local endpoint = os.getenv("KMP_ARIA2_RPC")
    local secret = os.getenv("KMP_ARIA2_SECRET")
    local installer = os.getenv("KMP_INSTALLER")
    if not endpoint or not secret or not installer or isWindows() then
        download.statusText = "BitTorrent indisponível neste dispositivo."
        download.statusColor = {1.0, 0.3, 0.3}
        return
    end
    local basePorts = sdPaths[currentSd]
    local directory = basePorts .. "/.kmp/torrents/" .. game.id
    local df = io.popen("df -Pk " .. shellQuote(basePorts) .. " 2>/dev/null | tail -1")
    local line = df and df:read("*l") or ""
    if df then df:close() end
    local availableKb = tonumber((line or ""):match("^%S+%s+%d+%s+%d+%s+(%d+)"))
    if not availableKb or availableKb * 1024 < game.sizeBytes * 3 + 64 * 1024 * 1024 then
        download.statusText = "Espaço insuficiente ou cartão indisponível."
        download.statusColor = {1.0, 0.3, 0.3}
        return
    end
    if not os.execute("mkdir -p " .. shellQuote(directory)) then
        download.statusText = "Não foi possível preparar o cartão SD."
        download.statusColor = {1.0, 0.3, 0.3}
        return
    end
    download.active = true
    download.phase = "baixando"
    download.progress = 0
    download.speedBps = 0
    download.game = game
    download.statusText = "Procurando peers..."
    download.statusColor = {0.0, 0.82, 1.0}
    while love.thread.getChannel("torrent_cancel"):pop() do end

    local worker = love.thread.newThread([[
        local game, basePorts, directory, endpoint, secret, installer = ...
        require("love.timer")
        local Json = require("json")
        local Rpc = require("aria2_rpc")
        local Torrent = require("torrent")
        local channel = love.thread.getChannel("torrent_event")
        local cancel = love.thread.getChannel("torrent_cancel")
        local function quote(value) return "'" .. tostring(value):gsub("'", "'\\''") .. "'" end
        local function fail(message) channel:push({kind = "error", message = message}) end
        local backend = Torrent.new(Rpc.new(endpoint, secret), {peer = os.getenv("KMP_PEER")})
        local gid, err = backend:start(game, directory)
        if not gid then fail(err or "aria2c não iniciou o torrent"); return end
        local lastProgress = 0
        local lastActivity = love.timer.getTime()
        local lastState = nil
        while true do
            if cancel:pop() then
                backend:stop(gid)
                fail("download interrompido; os dados podem ser retomados")
                return
            end
            local state, statusError
            for attempt = 1, 3 do
                state, statusError = backend:status(gid, game.infoHash)
                if state then break end
                love.timer.sleep(1)
            end
            if not state then fail(statusError or "falha de rede"); return end
            lastState = state
            if state.nextGid then
                gid = state.nextGid
            elseif state.phase == "error" or state.phase == "removed" then
                local message = state.errorMessage or "transferência interrompida"
                if state.errorCode == "9" then message = "sem espaço no cartão SD" end
                fail(message)
                return
            elseif state.phase == "seeding" or state.phase == "complete" then
                if not state.infoHash then fail("torrent sem infoHash verificado"); return end
                if type(state.files) ~= "table" or #state.files ~= 1 or
                   state.files[1].path ~= directory .. "/" .. game.packageFile then
                    fail("torrent não contém o ZIP esperado")
                    return
                end
                channel:push({kind = "installing"})
                local itemFile = directory .. "/item.json"
                local handle = io.open(itemFile, "w")
                if not handle then fail("não foi possível registrar o pacote"); return end
                handle:write(Json.encode(game))
                handle:close()
                local command = "python3 " .. quote(installer) .. " install " ..
                    quote(directory .. "/" .. game.packageFile) .. " " ..
                    quote(basePorts) .. " " .. quote(itemFile) .. " 2>&1"
                local process = io.popen(command)
                if not process then fail("instalador indisponível"); return end
                local output = process:read("*a")
                local ok = process:close()
                if not ok then fail((output or "falha na instalação"):sub(1, 160)); return end
                channel:push({kind = "done"})
                return
            else
                if state.downloadedBytes > lastProgress or state.connections > 0 then
                    lastProgress = state.downloadedBytes
                    lastActivity = love.timer.getTime()
                elseif love.timer.getTime() - lastActivity > 180 then
                    backend:stop(gid)
                    if lastState.totalBytes == 0 then
                        fail("Metadados indisponiveis: nenhum peer encontrado por DHT ou tracker.")
                    elseif lastState.webSeedsConfigured then
                        fail("Mirrors HTTPS e peers ficaram indisponiveis por 3 minutos.")
                    else
                        fail("Nenhum peer alcancavel; verifique NAT, firewall ou seeds ativos.")
                    end
                    return
                end
                channel:push({kind = "progress", percent = state.percent,
                    speed = state.downloadBytesPerSecond, done = state.downloadedBytes,
                    total = state.totalBytes,
                    waiting = state.totalBytes == 0 or state.transport == "waiting",
                    transport = state.transport})
            end
            love.timer.sleep(1)
        end
    ]])
    worker:start(game, basePorts, directory, endpoint, secret, installer)
end

function love.threaderror(thread, errorMessage)
    syncing = false
    download.active = false
    download.phase = "none"
    download.statusText = "Erro interno: " .. tostring(errorMessage):sub(1, 100)
    download.statusColor = {1.0, 0.3, 0.3}
end

function startDownload(game)
    if not game or download.active or game.installed then return end
    return startTorrentDownload(game)
end

local function handleToggleSD()
    currentSd = (currentSd == 1) and 2 or 1
    checkLocalFiles()
end

local function toggleMusic()
    if not bgm then return end
    isMusicPaused = not isMusicPaused
    if isMusicPaused then
        bgm:pause()
    else
        bgm:play()
    end
end

local function handleReboot()
    if isWindows() then love.event.quit() else os.execute("sudo reboot") end
end

local function handleShutdown()
    if isWindows() then love.event.quit() else os.execute("sudo poweroff") end
end

local function handleActionExit()
    if bgm then bgm:stop() end
    os.exit(0)
end

local function loadCatalogTrust()
    catalogTrust = {configured = false, verified = false, active = false,
        sequence = 0, mirrors = 0, healthyMirrors = 0,
        fingerprint = "", expiresAt = "", error = ""}
    if CATALOG_SYNC == "" or CATALOG_SOURCES == "" or CATALOG_PUBLIC_KEY == "" then
        return
    end
    local command = "python3 " .. shellQuote(CATALOG_SYNC) .. " status" ..
        " --sources " .. shellQuote(CATALOG_SOURCES) ..
        " --public-key " .. shellQuote(CATALOG_PUBLIC_KEY) ..
        " --state " .. shellQuote(CATALOG_STATE) ..
        " --pending " .. shellQuote(CATALOG_PENDING) ..
        " --active " .. shellQuote(CATALOG_ACTIVE) .. " 2>/dev/null"
    local process = io.popen(command)
    local output = process and process:read("*a") or ""
    local ok = process and process:close()
    local parsed = output ~= "" and Json.decode(output) or nil
    if ok and type(parsed) == "table" and parsed.ok then
        catalogTrust = parsed
        catalogTrust.error = ""
    else
        catalogTrust.error = type(parsed) == "table" and parsed.error or "Status indisponível"
    end
end

local function handleNavUp()
    if download.active or syncing or #catalog == 0 then return end
    selectedIdx = selectedIdx - 1
    if selectedIdx < 1 then selectedIdx = #catalog end
end

local function handleNavDown()
    if download.active or syncing or #catalog == 0 then return end
    selectedIdx = selectedIdx + 1
    if selectedIdx > #catalog then selectedIdx = 1 end
end

local function handleNavPageUp()
    if download.active or syncing or #catalog == 0 then return end
    selectedIdx = selectedIdx - 5
    if selectedIdx < 1 then selectedIdx = 1 end
end

local function handleNavPageDown()
    if download.active or syncing or #catalog == 0 then return end
    selectedIdx = selectedIdx + 5
    if selectedIdx > #catalog then selectedIdx = #catalog end
end

local function handleActionConfirm()
    if download.active or syncing or #catalog == 0 then return end
    local game = catalog[selectedIdx]
    showDetails = true
    startSeedStatus(game)
end

local function handleActionReload()
    if download.active or syncing then return end
    startSync()
end

local function handleUninstallerNavUp()
    if #installedPorts == 0 then return end
    uninstallerSelectedIdx = uninstallerSelectedIdx - 1
    if uninstallerSelectedIdx < 1 then uninstallerSelectedIdx = #installedPorts end
end

local function handleUninstallerNavDown()
    if #installedPorts == 0 then return end
    uninstallerSelectedIdx = uninstallerSelectedIdx + 1
    if uninstallerSelectedIdx > #installedPorts then uninstallerSelectedIdx = 1 end
end

local function handleUninstallerPageUp()
    if #installedPorts == 0 then return end
    uninstallerSelectedIdx = uninstallerSelectedIdx - 5
    if uninstallerSelectedIdx < 1 then uninstallerSelectedIdx = 1 end
end

local function handleUninstallerPageDown()
    if #installedPorts == 0 then return end
    uninstallerSelectedIdx = uninstallerSelectedIdx + 5
    if uninstallerSelectedIdx > #installedPorts then uninstallerSelectedIdx = #installedPorts end
end

local function executeUninstall()
    if gameToUninstall then
        if not gameToUninstall.managed then
            uninstallError = "Port legado sem manifesto: remova manualmente."
        else
            local installer = os.getenv("KMP_INSTALLER")
            if not installer then
                uninstallError = "Instalador indisponível."
            else
                local command = "python3 " .. shellQuote(installer) .. " uninstall " ..
                    shellQuote(gameToUninstall.path) .. " " .. shellQuote(gameToUninstall.portId) .. " 2>&1"
                local process = io.popen(command)
                local output = process and process:read("*a") or "Instalador indisponível"
                local ok = process and process:close()
                if ok then
                    scanInstalledPorts()
                    checkLocalFiles()
                else
                    uninstallError = (output or "Falha na remoção"):sub(1, 100)
                end
            end
        end
        showUninstallPopup = false
        gameToUninstall = nil
    end
end

function love.keypressed(key)
    if appState == "splash" then return end

    if appState == "catalog_trust" then
        if key == "a" or key == "b" or key == "return" or key == "space" or
           key == "escape" or key == "q" or key == "backspace" then
            appState = "main"
            showMenu = true
        end
        return
    end

    if showRestartPopup then
        if key == "return" or key == "b" or key == "space" or key == "a" or key == "escape" or key == "x" then
            showRestartPopup = false
            restartPopupTimer = 0
        end
        return
    end

    if showSearch then
        if key == "left" then searchSelected = math.max(1, searchSelected - 1)
        elseif key == "right" then searchSelected = math.min(#searchChars, searchSelected + 1)
        elseif key == "up" then searchSelected = math.max(1, searchSelected - 6)
        elseif key == "down" then searchSelected = math.min(#searchChars, searchSelected + 6)
        elseif key == "return" then
            searchQuery = searchQuery .. searchChars:sub(searchSelected, searchSelected)
            applySearch()
        elseif key == "backspace" then
            searchQuery = searchQuery:sub(1, -2)
            applySearch()
        elseif key == "escape" then showSearch = false end
        return
    end

    if showDetails then
        local game = catalog[selectedIdx]
        if key == "return" and game.installed then
            startSeedAction(detailsSeed.paused and "resume_one" or "pause_one", game)
        elseif key == "return" then
            showDetails = false
            startDownload(game)
        elseif key == "x" and game.installed then startSeedAction("pause_all", game)
        elseif key == "y" and game.installed then startSeedAction("resume_all", game)
        elseif key == "b" or key == "space" or key == "escape" or key == "backspace" then
            showDetails = false
        end
        return
    end

    if appState == "uninstaller" then
        if showUninstallPopup then
            if key == "b" or key == "return" then
                executeUninstall()
            elseif key == "a" or key == "space" or key == "escape" or key == "q" or key == "backspace" then
                showUninstallPopup = false
                gameToUninstall = nil
            end
        else
            if key == "up" or key == "w" then handleUninstallerNavUp()
            elseif key == "down" or key == "s" then handleUninstallerNavDown()
            elseif key == "pageup" then handleUninstallerPageUp()
            elseif key == "pagedown" then handleUninstallerPageDown()
            elseif key == "b" or key == "return" then
                if #installedPorts > 0 then
                    gameToUninstall = installedPorts[uninstallerSelectedIdx]
                    if gameToUninstall.managed then
                        showUninstallPopup = true
                    else
                        uninstallError = "Port legado sem manifesto: remoção manual."
                    end
                end
            elseif key == "a" or key == "space" or key == "escape" or key == "q" or key == "backspace" then
                appState = "main"
            end
        end
        return
    end

    if appState == "power_menu" then
        if key == "up" or key == "w" then
            powerMenuSelected = powerMenuSelected - 1
            if powerMenuSelected < 1 then powerMenuSelected = 3 end
        elseif key == "down" or key == "s" then
            powerMenuSelected = powerMenuSelected + 1
            if powerMenuSelected > 3 then powerMenuSelected = 1 end
        elseif key == "b" or key == "return" then
            if powerMenuSelected == 1 then handleActionExit()
            elseif powerMenuSelected == 2 then handleReboot()
            elseif powerMenuSelected == 3 then handleShutdown() end
        elseif key == "a" or key == "space" or key == "escape" or key == "q" or key == "backspace" then
            appState = "main"
            showMenu = true
        end
        return
    end

    if showMenu then
        if key == "up" or key == "w" then
            menuSelected = menuSelected - 1
            if menuSelected < 1 then menuSelected = 5 end
        elseif key == "down" or key == "s" then
            menuSelected = menuSelected + 1
            if menuSelected > 5 then menuSelected = 1 end
        elseif key == "b" or key == "return" then
            if menuSelected == 1 then handleToggleSD()
            elseif menuSelected == 2 then
                showMenu = false
                showSearch = true
            elseif menuSelected == 3 then
                showMenu = false
                scanInstalledPorts()
                appState = "uninstaller"
            elseif menuSelected == 4 then
                showMenu = false
                loadCatalogTrust()
                appState = "catalog_trust"
            elseif menuSelected == 5 then
                showMenu = false
                appState = "power_menu"
                powerMenuSelected = 1
            end
        elseif key == "a" or key == "space" or key == "escape" or key == "q" or key == "backspace" then
            showMenu = false
        end
        return
    end

    if download.active then
        if key == "escape" or key == "q" or key == "backspace" then
            love.thread.getChannel("torrent_cancel"):push(true)
            download.statusText = "Interrompendo download..."
        end
        return
    end
    if syncing then return end

    if key == "up" or key == "w" then handleNavUp()
    elseif key == "down" or key == "s" then handleNavDown()
    elseif key == "pageup" then handleNavPageUp()
    elseif key == "pagedown" then handleNavPageDown()
    elseif key == "b" or key == "return" then handleActionConfirm()
    elseif key == "x" then toggleMusic()
    elseif key == "y" then handleActionReload()
    elseif key == "space" or key == "escape" or key == "a" or key == "q" or key == "backspace" then
        showMenu = true
        menuSelected = 1
    end
end

function love.textinput(text)
    if showSearch and text:match("^[%w%s_-]+$") and #searchQuery < 40 then
        searchQuery = searchQuery .. text
        applySearch()
    end
end

function love.gamepadpressed(joystick, button)
    if appState == "splash" then return end

    if appState == "catalog_trust" then
        if button == "a" or button == "b" or button == "back" or button == "start" then
            appState = "main"
            showMenu = true
        end
        return
    end

    if showRestartPopup then
        if button == "a" or button == "b" or button == "back" or button == "start" then
            showRestartPopup = false
            restartPopupTimer = 0
        end
        return
    end

    if showSearch then
        if button == "dpleft" then searchSelected = math.max(1, searchSelected - 1)
        elseif button == "dpright" then searchSelected = math.min(#searchChars, searchSelected + 1)
        elseif button == "dpup" then searchSelected = math.max(1, searchSelected - 6)
        elseif button == "dpdown" then searchSelected = math.min(#searchChars, searchSelected + 6)
        elseif button == "a" then
            searchQuery = searchQuery .. searchChars:sub(searchSelected, searchSelected)
            applySearch()
        elseif button == "y" then
            searchQuery = searchQuery:sub(1, -2)
            applySearch()
        elseif button == "b" or button == "back" or button == "start" then showSearch = false end
        return
    end

    if showDetails then
        local game = catalog[selectedIdx]
        if button == "a" and game.installed then
            startSeedAction(detailsSeed.paused and "resume_one" or "pause_one", game)
        elseif button == "a" then
            showDetails = false
            startDownload(game)
        elseif button == "x" and game.installed then
            startSeedAction("pause_all", game)
        elseif button == "y" and game.installed then
            startSeedAction("resume_all", game)
        elseif button == "b" or button == "back" or button == "start" then showDetails = false end
        return
    end

    if appState == "uninstaller" then
        if showUninstallPopup then
            if button == "a" then
                executeUninstall()
            elseif button == "b" or button == "back" or button == "start" then
                showUninstallPopup = false
                gameToUninstall = nil
            end
        else
            if button == "dpup" then handleUninstallerNavUp()
            elseif button == "dpdown" then handleUninstallerNavDown()
            elseif button == "leftshoulder" then handleUninstallerPageUp()
            elseif button == "rightshoulder" then handleUninstallerPageDown()
            elseif button == "a" then
                if #installedPorts > 0 then
                    gameToUninstall = installedPorts[uninstallerSelectedIdx]
                    if gameToUninstall.managed then
                        showUninstallPopup = true
                    else
                        uninstallError = "Port legado sem manifesto: remoção manual."
                    end
                end
            elseif button == "b" or button == "back" or button == "start" then
                appState = "main"
            end
        end
        return
    end

    if appState == "power_menu" then
        if button == "dpup" then
            powerMenuSelected = powerMenuSelected - 1
            if powerMenuSelected < 1 then powerMenuSelected = 3 end
        elseif button == "dpdown" then
            powerMenuSelected = powerMenuSelected + 1
            if powerMenuSelected > 3 then powerMenuSelected = 1 end
        elseif button == "a" then
            if powerMenuSelected == 1 then handleActionExit()
            elseif powerMenuSelected == 2 then handleReboot()
            elseif powerMenuSelected == 3 then handleShutdown() end
        elseif button == "b" or button == "back" or button == "start" then
            appState = "main"
            showMenu = true
        end
        return
    end

    if showMenu then
        if button == "dpup" then
            menuSelected = menuSelected - 1
            if menuSelected < 1 then menuSelected = 5 end
        elseif button == "dpdown" then
            menuSelected = menuSelected + 1
            if menuSelected > 5 then menuSelected = 1 end
        elseif button == "a" then
            if menuSelected == 1 then handleToggleSD()
            elseif menuSelected == 2 then
                showMenu = false
                showSearch = true
            elseif menuSelected == 3 then
                showMenu = false
                scanInstalledPorts()
                appState = "uninstaller"
            elseif menuSelected == 4 then
                showMenu = false
                loadCatalogTrust()
                appState = "catalog_trust"
            elseif menuSelected == 5 then
                showMenu = false
                appState = "power_menu"
                powerMenuSelected = 1
            end
        elseif button == "b" or button == "back" or button == "start" then
            showMenu = false
        end
        return
    end

    if download.active then
        if button == "b" or button == "back" or button == "start" then
            love.thread.getChannel("torrent_cancel"):push(true)
            download.statusText = "Interrompendo download..."
        end
        return
    end
    if syncing then return end

    if button == "dpup" then handleNavUp()
    elseif button == "dpdown" then handleNavDown()
    elseif button == "leftshoulder" then handleNavPageUp()
    elseif button == "rightshoulder" then handleNavPageDown()
    elseif button == "a" then handleActionConfirm()
    elseif button == "x" then toggleMusic()
    elseif button == "y" then handleActionReload()
    elseif button == "back" or button == "start" then
        showMenu = true
        menuSelected = 1
    end
end

function love.gamepadaxis(joystick, axis, value)
    if appState == "splash" or showRestartPopup or showSearch or showDetails or download.active or syncing then return end
    
    if axis == "lefty" then
        if value < -0.6 then
            if appState == "power_menu" then
                powerMenuSelected = powerMenuSelected - 1
                if powerMenuSelected < 1 then powerMenuSelected = 3 end
            elseif appState == "uninstaller" and not showUninstallPopup then
                handleUninstallerNavUp()
            elseif showMenu then
                menuSelected = menuSelected - 1
                if menuSelected < 1 then menuSelected = 5 end
            elseif not showMenu and appState == "main" then 
                handleNavUp() 
            end
        elseif value > 0.6 then
            if appState == "power_menu" then
                powerMenuSelected = powerMenuSelected + 1
                if powerMenuSelected > 3 then powerMenuSelected = 1 end
            elseif appState == "uninstaller" and not showUninstallPopup then
                handleUninstallerNavDown()
            elseif showMenu then
                menuSelected = menuSelected + 1
                if menuSelected > 5 then menuSelected = 1 end
            elseif not showMenu and appState == "main" then 
                handleNavDown() 
            end
        end
    end
end

function love.draw()
    love.graphics.clear(0, 0, 0)
    love.graphics.push()
    love.graphics.translate(offsetX, offsetY)
    love.graphics.scale(scale, scale)
    love.graphics.setColor(0.06, 0.07, 0.10)
    love.graphics.rectangle("fill", 0, 0, 640, 480)

    if appState == "splash" then
        if logoImg then
            local iw, ih = logoImg:getDimensions()
            love.graphics.setColor(1, 1, 1)
            love.graphics.draw(logoImg, 320 - iw/2, 200 - ih/2)
        end
        love.graphics.setColor(0.0, 0.82, 1.0)
        love.graphics.setFont(fontItem)
        local dots = math.floor(splashTimer * 3) % 4
        local strDots = string.rep(".", dots)
        love.graphics.printf("Carregando Sistema" .. strDots, 0, 380, 640, "center")
        love.graphics.setColor(0.45, 0.52, 0.62)
        love.graphics.setFont(fontSub)
        love.graphics.printf("v" .. APP_VERSION, 0, 410, 640, "center")
    
    elseif appState == "uninstaller" then
        love.graphics.setColor(1.0, 0.3, 0.3)
        love.graphics.rectangle("fill", 24, 18, 46, 22, 4, 4)
        love.graphics.setColor(1, 1, 1)
        love.graphics.setFont(fontSub)
        love.graphics.printf("KPM", 24, 23, 46, "center")

        love.graphics.setFont(fontTitle)
        love.graphics.setColor(0.96, 0.97, 1.0)
        love.graphics.print("Gerenciador de Ports (Desinstalador)", 78, 19)
        love.graphics.setFont(fontSub)
        love.graphics.setColor(0.45, 0.52, 0.62)
        love.graphics.printf("v" .. APP_VERSION, 540, 24, 76, "right")

        love.graphics.setColor(1, 1, 1, 0.06)
        love.graphics.line(24, 52, 616, 52)

        if #installedPorts == 0 then
            love.graphics.setColor(0.45, 0.52, 0.62)
            love.graphics.setFont(fontItem)
            love.graphics.printf("Nenhum port encontrado nos cartoes SD.", 0, 190, 640, "center")
        else
            local startY = 64
            local rowH = 68
            local visibleRows = 6

            if uninstallerSelectedIdx * rowH - uninstallerScrollY > visibleRows * rowH then
                uninstallerScrollY = (uninstallerSelectedIdx - visibleRows) * rowH
            elseif uninstallerSelectedIdx * rowH - uninstallerScrollY < rowH then
                uninstallerScrollY = (uninstallerSelectedIdx - 1) * rowH
            end

            for i, port in ipairs(installedPorts) do
                local y = startY + (i - 1) * rowH - uninstallerScrollY
                
                if y >= 60 and y <= 410 then
                    local isSel = (i == uninstallerSelectedIdx)

                    if isSel then
                        love.graphics.setColor(1.0, 0.3, 0.3, 0.12)
                        love.graphics.rectangle("fill", 24, y, 592, 58, 8, 8)
                        love.graphics.setColor(1.0, 0.3, 0.3, 0.85)
                        love.graphics.setLineWidth(1.5)
                        love.graphics.rectangle("line", 24, y, 592, 58, 8, 8)
                        love.graphics.setColor(1.0, 0.3, 0.3)
                        love.graphics.rectangle("fill", 24, y + 11, 4, 36, 2, 2)
                    else
                        love.graphics.setColor(1, 1, 1, 0.02)
                        love.graphics.rectangle("fill", 24, y, 592, 58, 8, 8)
                    end

                    love.graphics.setColor(0.92, 0.94, 0.98)
                    love.graphics.setFont(fontItem)
                    love.graphics.print(port.name, 44, y + 10)

                    love.graphics.setColor(0.40, 0.46, 0.56)
                    love.graphics.setFont(fontSub)
                    love.graphics.print(port.filename, 44, y + 33)

                    love.graphics.setColor(0.2, 0.85, 0.45, 0.15)
                    love.graphics.rectangle("fill", 520, y + 25, 80, 18, 4, 4)
                    love.graphics.setColor(0.2, 0.85, 0.45)
                    love.graphics.setFont(fontSub)
                    love.graphics.printf(port.managed and port.label or "LEGADO", 520, y + 28, 80, "center")
                end
            end
        end

        love.graphics.setColor(0.04, 0.04, 0.07, 0.95)
        love.graphics.rectangle("fill", 0, 442, 640, 38)
        love.graphics.setColor(1, 1, 1, 0.06)
        love.graphics.line(0, 442, 640, 442)

        love.graphics.setFont(fontSub)
        love.graphics.setColor(0.40, 0.46, 0.56)

        love.graphics.setColor(0.35, 0.3, 0.1)
        love.graphics.rectangle("fill", 24, 450, 18, 18, 4, 4)
        love.graphics.setColor(0.95, 0.85, 0.2)
        love.graphics.printf("A", 24, 453, 18, "center")
        love.graphics.setColor(0.40, 0.46, 0.56)
        love.graphics.print("Desinstalar", 48, 453)

        love.graphics.setColor(0.15, 0.25, 0.4)
        love.graphics.rectangle("fill", 150, 450, 18, 18, 4, 4)
        love.graphics.setColor(0.3, 0.6, 1.0)
        love.graphics.printf("B", 150, 453, 18, "center")
        love.graphics.setColor(0.40, 0.46, 0.56)
        love.graphics.print("Voltar", 174, 453)

        if uninstallError ~= "" then
            love.graphics.setColor(1.0, 0.4, 0.4)
            love.graphics.printf(uninstallError, 24, 425, 590, "left")
        end

        if showUninstallPopup and gameToUninstall then
            love.graphics.setColor(0, 0, 0, 0.85)
            love.graphics.rectangle("fill", 0, 0, 640, 480)
            love.graphics.setColor(0.15, 0.1, 0.12, 0.98)
            love.graphics.rectangle("fill", 120, 160, 400, 160, 12, 12)
            love.graphics.setColor(1.0, 0.3, 0.3, 0.6)
            love.graphics.setLineWidth(2)
            love.graphics.rectangle("line", 120, 160, 400, 160, 12, 12)
            love.graphics.setColor(1.0, 0.3, 0.3)
            love.graphics.setFont(fontTitle)
            love.graphics.printf("ATENCAO: DESINSTALAR", 120, 180, 400, "center")
            love.graphics.setColor(0.96, 0.97, 1.0)
            love.graphics.setFont(fontItem)
            love.graphics.printf("Apagar " .. gameToUninstall.name .. "?", 120, 215, 400, "center")
            love.graphics.setColor(0.75, 0.82, 0.92)
            love.graphics.setFont(fontSub)
            love.graphics.printf("Os arquivos instalados serao apagados de " .. gameToUninstall.label .. ".",
                120, 245, 400, "center")
            love.graphics.setColor(0.45, 0.52, 0.62)
            love.graphics.setFont(fontSub)
            love.graphics.printf("A: Sim (Apagar)    B: Nao (Cancelar)", 120, 280, 400, "center")
        end

    else
        -- ==============================================
        -- TELA PRINCIPAL (CATALOGO EXPANDIDO)
        -- ==============================================
        love.graphics.setColor(0.0, 0.82, 1.0)
        love.graphics.rectangle("fill", 24, 18, 46, 22, 4, 4)
        love.graphics.setColor(1, 1, 1)
        love.graphics.setFont(fontSub)
        love.graphics.printf("KPM", 24, 23, 46, "center")

        love.graphics.setFont(fontTitle)
        love.graphics.setColor(0.96, 0.97, 1.0)
        love.graphics.print("KDownloader PM", 78, 19)

        love.graphics.setFont(fontSub)
        love.graphics.setColor(0.45, 0.52, 0.62)
        love.graphics.print("v" .. APP_VERSION, 220, 24)

        love.graphics.setColor(0.35, 0.42, 0.52)
        love.graphics.print("Destino: " .. sdLabels[currentSd], 300, 24)

        if isOffline then
            love.graphics.setColor(1.0, 0.3, 0.3, 0.15)
            love.graphics.rectangle("fill", 430, 18, 186, 22, 11, 11)
            love.graphics.setColor(1.0, 0.4, 0.4)
        else
            love.graphics.setColor(0.0, 0.82, 1.0, 0.15)
            love.graphics.rectangle("fill", 430, 18, 186, 22, 11, 11)
            love.graphics.setColor(0.0, 0.82, 1.0)
        end
        love.graphics.setFont(fontSub)
        love.graphics.printf(syncStatus, 430, 23, 186, "center")

        love.graphics.setColor(1, 1, 1, 0.06)
        love.graphics.line(24, 52, 616, 52)

        if #catalog == 0 then
            love.graphics.setColor(0.45, 0.52, 0.62)
            love.graphics.setFont(fontItem)
            if #catalogAll > 0 then
                love.graphics.printf("Nenhum resultado para: " .. searchQuery, 0, 190, 640, "center")
            elseif syncStatus:find("(0 ports)", 1, true) then
                love.graphics.printf("Nenhum homebrew no catálogo.", 0, 190, 640, "center")
            elseif isOffline then
                love.graphics.printf("Conexao ou leitura falhou.", 0, 190, 640, "center")
                love.graphics.setFont(fontSub)
                love.graphics.setColor(1.0, 0.4, 0.4)
                love.graphics.printf("Aperte (X) para tentar de novo", 0, 220, 640, "center")
            else
                love.graphics.printf("Aguardando lista de ports...", 0, 190, 640, "center")
            end
        else
            local startY = 64
            local rowH = 68
            local visibleRows = 6

            if selectedIdx * rowH - scrollY > visibleRows * rowH then
                scrollY = (selectedIdx - visibleRows) * rowH
            elseif selectedIdx * rowH - scrollY < rowH then
                scrollY = (selectedIdx - 1) * rowH
            end

            for i, game in ipairs(catalog) do
                local y = startY + (i - 1) * rowH - scrollY
                
                if y >= 60 and y <= 410 then
                    local isSel = (i == selectedIdx)

                    if isSel then
                        love.graphics.setColor(0.0, 0.82, 1.0, 0.12)
                        love.graphics.rectangle("fill", 24, y, 592, 58, 8, 8)
                        love.graphics.setColor(0.0, 0.82, 1.0, 0.85)
                        love.graphics.setLineWidth(1.5)
                        love.graphics.rectangle("line", 24, y, 592, 58, 8, 8)
                        love.graphics.setColor(0.0, 0.82, 1.0)
                        love.graphics.rectangle("fill", 24, y + 11, 4, 36, 2, 2)
                    else
                        love.graphics.setColor(1, 1, 1, 0.02)
                        love.graphics.rectangle("fill", 24, y, 592, 58, 8, 8)
                    end

                    love.graphics.setColor(0.92, 0.94, 0.98)
                    love.graphics.setFont(fontItem)
                    love.graphics.print(game.name, 44, y + 10)

                    love.graphics.setColor(0.40, 0.46, 0.56)
                    love.graphics.setFont(fontSub)
                    love.graphics.print(game.filename, 44, y + 33)

                    love.graphics.setFont(fontSmall)
                    love.graphics.setColor(0.55, 0.62, 0.72)
                    love.graphics.printf(game.size or "Port", 430, y + 12, 170, "right")

                    if game.installed then
                        love.graphics.setColor(0.2, 0.85, 0.45, 0.15)
                        love.graphics.rectangle("fill", 520, y + 25, 80, 18, 4, 4)
                        love.graphics.setColor(0.2, 0.85, 0.45)
                        love.graphics.setFont(fontSub)
                        love.graphics.printf("INSTALADO", 520, y + 28, 80, "center")
                    else
                        love.graphics.setColor(1, 1, 1, 0.05)
                        love.graphics.rectangle("fill", 540, y + 25, 60, 18, 4, 4)
                        love.graphics.setColor(0.45, 0.52, 0.62)
                        love.graphics.setFont(fontSub)
                        love.graphics.printf("NUVEM", 540, y + 28, 60, "center")
                    end
                end
            end
        end

        -- ============================================================
        -- POPUP DE DOWNLOAD COM PORCENTAGEM E VELOCIDADE
        -- ============================================================
        if download.active then
            love.graphics.setColor(0, 0, 0, 0.80)
            love.graphics.rectangle("fill", 0, 0, 640, 480)

            love.graphics.setColor(0.1, 0.15, 0.22, 0.98)
            love.graphics.rectangle("fill", 120, 150, 400, 180, 14, 14)
            love.graphics.setColor(0.0, 0.82, 1.0, 0.6)
            love.graphics.setLineWidth(2)
            love.graphics.rectangle("line", 120, 150, 400, 180, 14, 14)

            love.graphics.setColor(0.96, 0.97, 1.0)
            love.graphics.setFont(fontTitle)
            if download.phase == "baixando" then
                love.graphics.printf("BAIXANDO PORT...", 120, 170, 400, "center")
            elseif download.phase == "extraindo" then
                love.graphics.printf("VALIDANDO E INSTALANDO...", 120, 170, 400, "center")
            end

            love.graphics.setColor(0.75, 0.82, 0.92)
            love.graphics.setFont(fontItem)
            local gameName = download.game and download.game.name or "Arquivo"
            love.graphics.printf(gameName, 120, 205, 400, "center")

            love.graphics.setColor(1, 1, 1, 0.1)
            love.graphics.rectangle("fill", 150, 245, 340, 16, 8, 8)

            if download.phase == "baixando" then
                love.graphics.setColor(0.0, 0.82, 1.0)
                love.graphics.rectangle("fill", 150, 245, 340 * (download.progress / 100), 16, 8, 8)
            elseif download.phase == "extraindo" then
                love.graphics.setColor(0.7, 0.4, 1.0)
                love.graphics.rectangle("fill", 150, 245, 340, 16, 8, 8)
            end

            love.graphics.setColor(0.96, 0.97, 1.0)
            love.graphics.setFont(fontSub)
            
            local infoText = ""
            if download.phase == "baixando" then
                local speedStr = "0 KB/s"
                if download.speedBps then
                    if download.speedBps > 1024 * 1024 then
                        speedStr = string.format("%.1f MB/s", download.speedBps / (1024 * 1024))
                    else
                        speedStr = string.format("%.1f KB/s", download.speedBps / 1024)
                    end
                end
                if download.game and download.game.magnet then
                    infoText = string.format("%d%%   |   %.1f / %.1f MB   |   %s",
                        math.floor(download.progress), (download.downloadedBytes or 0) / 1048576,
                        (download.totalBytes or 0) / 1048576, speedStr)
                else
                    infoText = string.format("Progresso: %d%%   |   Velocidade: %s", math.floor(download.progress), speedStr)
                end
            else
                infoText = "Download verificado; preparando instalação."
            end

            love.graphics.printf(infoText, 120, 280, 400, "center")
        end

        -- ============================================================
        -- RODAPÉ DA TELA PRINCIPAL (SEM D-PAD, NOMES INTEIROS, Y VERDE)
        -- ============================================================
        love.graphics.setColor(0.04, 0.04, 0.07, 0.95)
        love.graphics.rectangle("fill", 0, 422, 640, 58)
        love.graphics.setColor(1, 1, 1, 0.06)
        love.graphics.line(0, 422, 640, 422)

        -- Texto de status sincronizado posicionado acima na barra
        love.graphics.setColor(download.statusColor)
        love.graphics.setFont(fontSmall)
        love.graphics.print(download.statusText, 24, 429)

        love.graphics.setFont(fontSub)
        love.graphics.setColor(0.40, 0.46, 0.56)
        
        -- DETALHES (A)
        love.graphics.setColor(0.35, 0.3, 0.1)
        love.graphics.rectangle("fill", 24, 452, 18, 18, 4, 4)
        love.graphics.setColor(0.95, 0.85, 0.2)
        love.graphics.printf("A", 24, 455, 18, "center")
        love.graphics.setColor(0.40, 0.46, 0.56)
        love.graphics.print("Detalhes", 47, 455)

        -- ATUALIZAR LISTA (Y - Verde clássico do console)
        love.graphics.setColor(0.15, 0.35, 0.2)
        love.graphics.rectangle("fill", 125, 452, 18, 18, 4, 4)
        love.graphics.setColor(0.2, 0.85, 0.45)
        love.graphics.printf("Y", 125, 455, 18, "center")
        love.graphics.setColor(0.40, 0.46, 0.56)
        love.graphics.print("Atualizar", 148, 455)

        -- MUSICA (X)
        love.graphics.setColor(0.15, 0.25, 0.4)
        love.graphics.rectangle("fill", 235, 452, 18, 18, 4, 4)
        love.graphics.setColor(0.3, 0.6, 1.0)
        love.graphics.printf("X", 235, 455, 18, "center")
        love.graphics.setColor(0.40, 0.46, 0.56)
        local musText = isMusicPaused and "Musica: Off" or "Musica: On"
        if not bgm then musText = "Musica" end
        love.graphics.print(musText, 258, 455)

        -- MENU (SELECT)
        love.graphics.setColor(0.35, 0.15, 0.15)
        love.graphics.rectangle("fill", 365, 452, 32, 18, 4, 4)
        love.graphics.setColor(0.9, 0.2, 0.2)
        love.graphics.printf("SEL", 365, 455, 32, "center")
        love.graphics.setColor(0.40, 0.46, 0.56)
        love.graphics.print("Menu", 403, 455)

        if showMenu then
            love.graphics.setColor(0, 0, 0, 0.85)
            love.graphics.rectangle("fill", 0, 0, 640, 480)

            love.graphics.setColor(0.1, 0.15, 0.22, 0.98)
            love.graphics.rectangle("fill", 170, 65, 300, 355, 12, 12)

            love.graphics.setColor(0.0, 0.82, 1.0, 0.6)
            love.graphics.setLineWidth(2)
            love.graphics.rectangle("line", 170, 65, 300, 355, 12, 12)

            love.graphics.setColor(0.96, 0.97, 1.0)
            love.graphics.setFont(fontTitle)
            love.graphics.printf("MENU DE OPCOES", 170, 80, 300, "center")

            love.graphics.setColor(1, 1, 1, 0.1)
            love.graphics.line(190, 110, 450, 110)

            local opt1_y = 130
            if menuSelected == 1 then
                love.graphics.setColor(0.0, 0.82, 1.0, 0.2)
                love.graphics.rectangle("fill", 190, opt1_y - 6, 260, 36, 6, 6)
                love.graphics.setColor(0.0, 0.82, 1.0)
                love.graphics.rectangle("line", 190, opt1_y - 6, 260, 36, 6, 6)
                love.graphics.setColor(1, 1, 1)
            else love.graphics.setColor(0.6, 0.65, 0.75) end
            love.graphics.setFont(fontItem)
            love.graphics.printf("Mudar Destino: " .. sdLabels[currentSd], 170, opt1_y, 300, "center")

            local opt2_y = 175
            if menuSelected == 2 then
                love.graphics.setColor(1.0, 0.3, 0.3, 0.2)
                love.graphics.rectangle("fill", 190, opt2_y - 6, 260, 36, 6, 6)
                love.graphics.setColor(1.0, 0.3, 0.3)
                love.graphics.rectangle("line", 190, opt2_y - 6, 260, 36, 6, 6)
                love.graphics.setColor(1, 1, 1)
            else love.graphics.setColor(0.6, 0.65, 0.75) end
            love.graphics.printf("Pesquisar por nome", 170, opt2_y, 300, "center")

            local opt3_y = 220
            if menuSelected == 3 then
                love.graphics.setColor(0.85, 0.65, 0.2, 0.2)
                love.graphics.rectangle("fill", 190, opt3_y - 6, 260, 36, 6, 6)
                love.graphics.setColor(0.85, 0.65, 0.2)
                love.graphics.rectangle("line", 190, opt3_y - 6, 260, 36, 6, 6)
                love.graphics.setColor(1, 1, 1)
            else love.graphics.setColor(0.6, 0.65, 0.75) end
            love.graphics.printf("Desinstalador de Ports", 170, opt3_y, 300, "center")

            local opt4_y = 265
            if menuSelected == 4 then
                love.graphics.setColor(0.85, 0.65, 0.2, 0.2)
                love.graphics.rectangle("fill", 190, opt4_y - 6, 260, 36, 6, 6)
                love.graphics.setColor(0.85, 0.65, 0.2)
                love.graphics.rectangle("line", 190, opt4_y - 6, 260, 36, 6, 6)
                love.graphics.setColor(1, 1, 1)
            else love.graphics.setColor(0.6, 0.65, 0.75) end
            love.graphics.printf("Confianca do Catalogo", 170, opt4_y, 300, "center")

            local opt5_y = 310
            if menuSelected == 5 then
                love.graphics.setColor(1.0, 0.3, 0.3, 0.2)
                love.graphics.rectangle("fill", 190, opt5_y - 6, 260, 36, 6, 6)
                love.graphics.setColor(1.0, 0.3, 0.3)
                love.graphics.rectangle("line", 190, opt5_y - 6, 260, 36, 6, 6)
                love.graphics.setColor(1, 1, 1)
            else love.graphics.setColor(0.6, 0.65, 0.75) end
            love.graphics.printf("Sair", 170, opt5_y, 300, "center")

            love.graphics.setColor(0.45, 0.52, 0.62)
            love.graphics.setFont(fontSub)
            love.graphics.printf("A: Confirmar   B: Voltar", 170, 385, 300, "center")
        end

        if showSearch then
            love.graphics.setColor(0, 0, 0, 0.88)
            love.graphics.rectangle("fill", 0, 0, 640, 480)
            love.graphics.setColor(0.1, 0.15, 0.22)
            love.graphics.rectangle("fill", 105, 42, 430, 395, 12, 12)
            love.graphics.setColor(0.0, 0.82, 1.0)
            love.graphics.setFont(fontTitle)
            love.graphics.printf("PESQUISAR HOME BREWS", 105, 60, 430, "center")
            love.graphics.setFont(fontItem)
            love.graphics.setColor(1, 1, 1)
            love.graphics.printf(searchQuery == "" and "(todos)" or searchQuery, 125, 102, 390, "center")
            for i = 1, #searchChars do
                local column = (i - 1) % 6
                local row = math.floor((i - 1) / 6)
                local x, y = 150 + column * 58, 145 + row * 42
                love.graphics.setColor(i == searchSelected and 0.0 or 0.2,
                    i == searchSelected and 0.65 or 0.25,
                    i == searchSelected and 0.9 or 0.35)
                love.graphics.rectangle("fill", x, y, 42, 34, 5, 5)
                love.graphics.setColor(1, 1, 1)
                love.graphics.printf(searchChars:sub(i, i), x, y + 6, 42, "center")
            end
            love.graphics.setFont(fontSub)
            love.graphics.setColor(0.7, 0.8, 0.9)
            love.graphics.printf("A: letra   Y: apagar   B: voltar", 105, 410, 430, "center")
        end

        if showDetails and catalog[selectedIdx] then
            local game = catalog[selectedIdx]
            love.graphics.setColor(0, 0, 0, 0.88)
            love.graphics.rectangle("fill", 0, 0, 640, 480)
            love.graphics.setColor(0.1, 0.15, 0.22)
            love.graphics.rectangle("fill", 70, 65, 500, 350, 12, 12)
            love.graphics.setColor(0.0, 0.82, 1.0)
            love.graphics.setFont(fontTitle)
            love.graphics.printf(game.name, 90, 85, 460, "center")
            love.graphics.setColor(0.85, 0.9, 0.95)
            love.graphics.setFont(fontSub)
            love.graphics.printf("Versão: " .. (game.version or "-") .. "   |   Licença: " .. (game.license or "-") ..
                "   |   Tamanho: " .. (game.size or "-"), 90, 125, 460, "center")
            love.graphics.setFont(fontItem)
            love.graphics.printf(game.description or "Sem descrição", 95, 160, 450, "center")
            love.graphics.setFont(fontSub)
            love.graphics.setColor(0.5, 0.6, 0.7)
            love.graphics.printf("Destino: " .. sdLabels[currentSd], 90, 245, 460, "center")
            if game.installed then
                love.graphics.setColor(0.2, 0.85, 0.45)
                love.graphics.printf("INSTALADO", 90, 270, 460, "center")
                love.graphics.setColor(0.68, 0.76, 0.86)
                local seedText = "Semeacao: consultando..."
                if not detailsSeed.loading then
                    if detailsSeed.error then seedText = "Semeacao: " .. detailsSeed.error
                    elseif not detailsSeed.found then seedText = "Semeacao: torrent fora do daemon"
                    elseif detailsSeed.seeding then seedText = "Semeacao: ativa"
                    elseif detailsSeed.paused then seedText = "Semeacao: pausada (bateria ou usuario)"
                    else seedText = "Semeacao: " .. tostring(detailsSeed.phase or "inativa") end
                end
                love.graphics.printf(seedText, 90, 298, 460, "center")
                if detailsSeed.found then
                    love.graphics.printf(string.format(
                        "Enviado: %.1f MB  |  Ratio: %.2f  |  Upload: %.1f KB/s  |  Peers: %d",
                        (detailsSeed.uploaded or 0) / 1048576, detailsSeed.ratio or 0,
                        (detailsSeed.uploadSpeed or 0) / 1024, detailsSeed.connections or 0),
                        85, 324, 470, "center")
                end
                love.graphics.setColor(0.5, 0.6, 0.7)
                local oneAction = detailsSeed.paused and "A: retomar este" or "A: pausar este"
                love.graphics.printf(oneAction .. "   X: pausar todos   Y: retomar todos",
                    75, 355, 490, "center")
                love.graphics.printf("B: voltar", 90, 382, 460, "center")
            else
                love.graphics.printf("A: instalar   B: voltar", 90, 380, 460, "center")
            end
        end

        if appState == "catalog_trust" then
            love.graphics.setColor(0, 0, 0, 0.9)
            love.graphics.rectangle("fill", 0, 0, 640, 480)
            love.graphics.setColor(0.08, 0.12, 0.18, 0.99)
            love.graphics.rectangle("fill", 70, 55, 500, 365, 12, 12)
            local trusted = catalogTrust.configured and catalogTrust.verified and catalogTrust.active
            love.graphics.setColor(trusted and 0.2 or 0.95, trusted and 0.85 or 0.65,
                trusted and 0.45 or 0.2, 0.8)
            love.graphics.setLineWidth(2)
            love.graphics.rectangle("line", 70, 55, 500, 365, 12, 12)
            love.graphics.setFont(fontTitle)
            love.graphics.printf("CONFIANCA DO CATALOGO", 90, 78, 460, "center")

            love.graphics.setFont(fontItem)
            love.graphics.setColor(trusted and 0.2 or 0.95, trusted and 0.85 or 0.65,
                trusted and 0.45 or 0.2)
            local stateText = "Modo legado (sem chave oficial)"
            if catalogTrust.configured and trusted then stateText = "Catalogo oficial verificado"
            elseif catalogTrust.configured then stateText = "Catalogo oficial aguardando verificacao" end
            love.graphics.printf(stateText, 95, 120, 450, "center")

            love.graphics.setFont(fontSub)
            love.graphics.setColor(0.78, 0.84, 0.92)
            local sequence = tonumber(catalogTrust.sequence) or 0
            love.graphics.print("Sequencia aceita:", 105, 175)
            love.graphics.printf(tostring(sequence), 310, 175, 220, "right")
            love.graphics.print("Mirrors saudaveis/configurados:", 105, 207)
            love.graphics.printf(string.format("%d/%d", tonumber(catalogTrust.healthyMirrors) or 0,
                tonumber(catalogTrust.mirrors) or 0), 310, 207, 220, "right")
            love.graphics.print("Snapshot ativo:", 105, 239)
            love.graphics.printf(catalogTrust.active and "sim" or "nao", 310, 239, 220, "right")
            love.graphics.print("Validade do head:", 105, 271)
            love.graphics.printf(catalogTrust.expiresAt ~= "" and catalogTrust.expiresAt or "-",
                270, 271, 260, "right")

            love.graphics.setColor(0.48, 0.58, 0.7)
            love.graphics.print("Fingerprint Ed25519 (SHA-256):", 105, 310)
            love.graphics.setColor(0.86, 0.9, 0.96)
            love.graphics.printf(catalogTrust.fingerprint ~= "" and catalogTrust.fingerprint or "-",
                105, 334, 430, "center")
            if catalogTrust.error and catalogTrust.error ~= "" then
                love.graphics.setColor(1.0, 0.35, 0.35)
                love.graphics.printf(catalogTrust.error, 105, 360, 430, "center")
            end
            love.graphics.setColor(0.48, 0.58, 0.7)
            love.graphics.printf("A/B: Voltar", 105, 390, 430, "center")
        end

        if appState == "power_menu" then
            love.graphics.setColor(0, 0, 0, 0.85)
            love.graphics.rectangle("fill", 0, 0, 640, 480)

            love.graphics.setColor(0.1, 0.15, 0.22, 0.98)
            love.graphics.rectangle("fill", 170, 120, 300, 240, 12, 12)

            love.graphics.setColor(0.85, 0.65, 0.2, 0.6)
            love.graphics.setLineWidth(2)
            love.graphics.rectangle("line", 170, 120, 300, 240, 12, 12)

            love.graphics.setColor(0.96, 0.97, 1.0)
            love.graphics.setFont(fontTitle)
            love.graphics.printf("OPCOES DE SAIDA", 170, 135, 300, "center")

            love.graphics.setColor(1, 1, 1, 0.1)
            love.graphics.line(190, 165, 450, 165)

            local p1_y = 185
            if powerMenuSelected == 1 then
                love.graphics.setColor(0.0, 0.82, 1.0, 0.2)
                love.graphics.rectangle("fill", 190, p1_y - 6, 260, 36, 6, 6)
                love.graphics.setColor(0.0, 0.82, 1.0)
                love.graphics.rectangle("line", 190, p1_y - 6, 260, 36, 6, 6)
                love.graphics.setColor(1, 1, 1)
            else love.graphics.setColor(0.6, 0.65, 0.75) end
            love.graphics.setFont(fontItem)
            love.graphics.printf("Sair do Aplicativo", 170, p1_y, 300, "center")

            local p2_y = 235
            if powerMenuSelected == 2 then
                love.graphics.setColor(0.85, 0.65, 0.2, 0.2)
                love.graphics.rectangle("fill", 190, p2_y - 6, 260, 36, 6, 6)
                love.graphics.setColor(0.85, 0.65, 0.2)
                love.graphics.rectangle("line", 190, p2_y - 6, 260, 36, 6, 6)
                love.graphics.setColor(1, 1, 1)
            else love.graphics.setColor(0.6, 0.65, 0.75) end
            love.graphics.printf("Reiniciar Console", 170, p2_y, 300, "center")

            local p3_y = 285
            if powerMenuSelected == 3 then
                love.graphics.setColor(1.0, 0.3, 0.3, 0.2)
                love.graphics.rectangle("fill", 190, p3_y - 6, 260, 36, 6, 6)
                love.graphics.setColor(1.0, 0.3, 0.3)
                love.graphics.rectangle("line", 190, p3_y - 6, 260, 36, 6, 6)
                love.graphics.setColor(1, 1, 1)
            else love.graphics.setColor(0.6, 0.65, 0.75) end
            love.graphics.printf("Desligar Dispositivo", 170, p3_y, 300, "center")

            love.graphics.setColor(0.45, 0.52, 0.62)
            love.graphics.setFont(fontSub)
            love.graphics.printf("A: Confirmar   B: Voltar", 170, 330, 300, "center")
        end

        if showRestartPopup then
            love.graphics.setColor(0, 0, 0, 0.7)
            love.graphics.rectangle("fill", 0, 0, 640, 480)
            love.graphics.setColor(0.1, 0.15, 0.22, 0.98)
            love.graphics.rectangle("fill", 100, 160, 440, 170, 14, 14)
            love.graphics.setColor(0.2, 0.85, 0.45)
            love.graphics.setLineWidth(2)
            love.graphics.rectangle("line", 100, 160, 440, 170, 14, 14)
            love.graphics.circle("fill", 320, 200, 24)
            love.graphics.setColor(1, 1, 1)
            love.graphics.setFont(fontTitle)
            love.graphics.printf("v", 305, 190, 30, "center")
            love.graphics.setColor(0.96, 0.97, 1.0)
            love.graphics.setFont(fontTitle)
            love.graphics.printf("Instalado com sucesso!", 100, 238, 440, "center")
            love.graphics.setColor(0.75, 0.82, 0.92)
            love.graphics.setFont(fontItem)
            love.graphics.printf("Reinicie o aparelho para o jogo\naparecer no menu de Ports.", 100, 272, 440, "center")
            love.graphics.setColor(0.45, 0.52, 0.62)
            love.graphics.setFont(fontSub)
            love.graphics.printf("Aperte qualquer botao para fechar", 100, 312, 440, "center")
        end
    end

    love.graphics.pop()
end
