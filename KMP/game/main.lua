-- ============================================================
-- KDownloader PM - catálogo versionado e transferência BitTorrent
-- ============================================================

local Json = require("json")
local Catalog = require("catalog")
local utf8 = require("utf8")
local APP_VERSION = require("version")
local CATALOG_URL = os.getenv("KMP_CATALOG_URL") or ""
local CATALOG_SYNC = os.getenv("KMP_CATALOG_SYNC") or ""
local CATALOG_SOURCES = os.getenv("KMP_CATALOG_SOURCES") or ""
local CATALOG_PUBLIC_KEY = os.getenv("KMP_CATALOG_PUBLIC_KEY") or ""
local CATALOG_STATE = os.getenv("KMP_CATALOG_STATE") or ""
local CATALOG_PENDING = os.getenv("KMP_CATALOG_PENDING") or ""
local CATALOG_DOWNLOADS = os.getenv("KMP_CATALOG_DOWNLOADS") or ""
local CATALOG_ACTIVE = os.getenv("KMP_CATALOG_ACTIVE") or ""
-- Resultado da última sincronização, ao lado do estado do catálogo para entrar no pacote de
-- diagnóstico; sem o estado (modo de teste), fica no /tmp como antes.
local CATALOG_SYNC_RESULT = (CATALOG_STATE:match("^(.*)/[^/]+$") or "") ~= "" and
    CATALOG_STATE:match("^(.*)/[^/]+$") .. "/last-sync.json" or "/tmp/kmp_catalog_sync_result.json"
local PYTHON = os.getenv("KMP_PYTHON") or "python3"
local TEST_MODE = os.getenv("KMP_TEST_MODE") == "1"
local DIAGNOSTIC_TOOL = os.getenv("KMP_DIAGNOSTIC") or ""
local SELF_UPDATE_TOOL = os.getenv("KMP_SELF_UPDATE") or ""
local CLIENT_BASE = os.getenv("KMP_CLIENT_BASE") or ""
local GAME_DIR = os.getenv("KMP_GAME_DIR") or ""
local CONF_DIR = os.getenv("KMP_CONF_DIR") or ""
local DIAGNOSTIC_OUTPUT = os.getenv("KMP_DIAGNOSTIC_OUTPUT") or ""
local COMMUNITY_CONTROL = os.getenv("KMP_COMMUNITY_CONTROL") or ""
local COMMUNITY_SETTINGS = os.getenv("KMP_COMMUNITY_SETTINGS") or ""
local COMMUNITY_DIRECTORY = os.getenv("KMP_COMMUNITY_DIRECTORY") or ""
local RPC_ENDPOINT = os.getenv("KMP_ARIA2_RPC") or ""
local RPC_SECRET = os.getenv("KMP_ARIA2_SECRET") or ""

local sdPaths = { "/roms/ports", "/roms2/ports" }
local sdLabels = { "SD1 (/roms)", "SD2 (/roms2)" }
local currentSd = 1
local scrollY = 0
local scrollTarget = 0

-- Loja: abas filtram o catálogo e a grade mostra três cartões por linha.
local STORE_TABS = {"Início", "Instalados", "Atualizações"}
local storeTab = 1
local GRID_COLUMNS = 3
local GRID_TOP, GRID_BOTTOM = 116, 418
local CARD_W, CARD_H, CARD_GAP = 188, 140, 12
local detailsScroll = 0
local detailsScrollMax = 0
local detailsScrollStep = 19
-- Direcional segurado repete o movimento; o analógico vira direcional com histerese.
local heldInput = nil
local axisDirection = {leftx = 0, lefty = 0}
local updateHeldInput
-- Redesenhar a 60 quadros por segundo com a tela parada consumia mais de um terço da CPU
-- de um console; o Client cai para 8 quadros quando ninguém mexe nele.
local lastInputAt, lastFrameAt = 0, 0
local ACTIVE_FRAME, IDLE_FRAME, IDLE_AFTER = 1 / 30, 1 / 8, 3

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
local detailsSeedLastRefresh = 0
local detailsSeedRefreshInterval = 2
local catalogTrust = {
    configured = false, verified = false, active = false, sequence = 0,
    mirrors = 0, healthyMirrors = 0, fingerprint = "", expiresAt = "", error = ""
}
local diagnostic = {active = false, ok = false, message = "", path = ""}
local communityEnabled = true
local testEvents = {}
local testInstalledPorts = nil

local function recordTestEvent(action, values)
    if not TEST_MODE then return end
    local event = values or {}
    event.action = action
    table.insert(testEvents, event)
end

local function readCommunitySetting()
    local handle = io.open(COMMUNITY_SETTINGS, "r")
    if not handle then return true end
    for line in handle:lines() do
        if line:match("^community_node=0%s*$") then handle:close(); return false end
        if line:match("^community_node=1%s*$") then handle:close(); return true end
    end
    handle:close(); return true
end

local function toggleCommunity()
    if TEST_MODE then
        communityEnabled = not communityEnabled
        recordTestEvent("community_node", {enabled = communityEnabled})
        return
    end
    if COMMUNITY_CONTROL == "" or COMMUNITY_SETTINGS == "" or CATALOG_ACTIVE == "" or
       COMMUNITY_DIRECTORY == "" or RPC_ENDPOINT == "" or RPC_SECRET == "" then
        syncStatus = "Nó comunitário indisponível."
        return
    end
    local action = communityEnabled and "disable" or "enable"
    local command = string.format("%q %q %q --settings %q --catalog %q --directory %q --rpc %q --secret %q",
        PYTHON, COMMUNITY_CONTROL, action, COMMUNITY_SETTINGS, CATALOG_ACTIVE,
        COMMUNITY_DIRECTORY, RPC_ENDPOINT, RPC_SECRET)
    local ok = os.execute(command)
    if ok == true or ok == 0 then
        communityEnabled = not communityEnabled
        syncStatus = communityEnabled and "Nó comunitário ativado." or "Nó comunitário desativado."
    else
        syncStatus = "Falha ao alterar o nó comunitário."
    end
end

local showRestartPopup = false
local restartPopupTimer = 0
local showClientUpdatePopup = false
-- Download pendente de um port que o autor não listou para este firmware: {game, peerOnly}.
local firmwareWarning = nil

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
local catalogRevocations = {}
local clientUpdate = nil
local clientUpdateNotice = nil
local incompatiblePorts = 0
local selectedIdx = 1
local fontTitle, fontItem, fontSub, fontSmall, fontTiny, fontBig, fontIcon, fontIconBig
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

local function installedRecord(game)
    local basePorts = game.isClientUpdate and CLIENT_BASE ~= "" and CLIENT_BASE or sdPaths[currentSd]
    if isWindows() then basePorts = "." end

    local manifest = basePorts .. "/.kmp/manifests/" .. game.install.portId .. ".json"
    local handle = io.open(manifest, "r")
    if not handle then return nil end
    local content = handle:read("*a")
    handle:close()
    local record = Json.decode(content)
    if type(record) == "table" and record.portId == game.install.portId then return record end
    return nil
end

local function inStoreTab(game)
    if storeTab == 2 then return game.installed end
    if storeTab == 3 then return game.installed and (game.updateAvailable or game.revocation ~= nil) end
    return true
end

-- Refaz a lista visível; com keepSelection o mesmo port continua selecionado.
local function refreshView(keepSelection)
    local selectedId = keepSelection and catalog[selectedIdx] and catalog[selectedIdx].id
    catalog = {}
    for _, game in ipairs(Catalog.search(catalogAll, searchQuery)) do
        if inStoreTab(game) then catalog[#catalog + 1] = game end
    end
    selectedIdx = 1
    for index, game in ipairs(catalog) do
        if game.id == selectedId then selectedIdx = index; break end
    end
    if not selectedId then scrollY, scrollTarget = 0, 0 end
end

local function countTab(tab)
    local saved, count = storeTab, 0
    storeTab = tab
    for _, game in ipairs(catalogAll) do
        if inStoreTab(game) then count = count + 1 end
    end
    storeTab = saved
    return count
end

local function checkLocalFiles()
    for _, game in ipairs(catalogAll) do
        local record = installedRecord(game)
        game.installed = record ~= nil
        game.installedVersion = record and record.version or nil
        game.installedRevision = record and record.revision or nil
        game.installedVariantId = record and record.variantId or nil
        game.installedInfoHash = record and record.infoHash or nil
        game.installedPackageFile = record and record.packageFile or nil
        game.installedPackageSha256 = record and record.packageSha256 or nil
        game.revocation = record and record.packageSha256 and
            catalogRevocations[record.packageSha256] or nil
        game.downloadRevocation = game.packageSha256 and
            catalogRevocations[game.packageSha256] or nil
        game.updateAvailable = record ~= nil and Catalog.isUpdate(
            record.version, game.version, record.revision, game.revision)
    end
    refreshView(true)
end

local function applySearch()
    refreshView(false)
end

local function switchTab(delta)
    storeTab = (storeTab - 1 + delta) % #STORE_TABS + 1
    refreshView(false)
end

local function startSeedStatus(game)
    if TEST_MODE then
        detailsSeed = {loading = false, found = game and game.installed == true,
            seeding = game and game.installed == true, paused = false, gid = "test-gid",
            uploaded = 0, ratio = 0, uploadSpeed = 0, connections = 0,
            portMapping = {active = true, method = "upnp", addressScope = "public"}}
        return
    end
    if not game or not game.installed then
        detailsSeed = {loading = false, found = false}
        return
    end
    local endpoint = os.getenv("KMP_ARIA2_RPC")
    local secret = os.getenv("KMP_ARIA2_SECRET")
    if not endpoint or endpoint == "" or not secret or secret == "" then
        detailsSeed.error = "daemon BitTorrent indisponivel"
        return
    end
    detailsSeed.loading = true
    while love.thread.getChannel("seed_status_done"):pop() do end
    local worker = love.thread.newThread([[
        local endpoint, secret, infoHash, mappingPath = ...
        local Json = require("json")
        local Rpc = require("aria2_rpc")
        local SeedStatus = require("seed_status")
        local ok, result, err = pcall(SeedStatus.find, Rpc.new(endpoint, secret), infoHash)
        if not ok then result, err = nil, tostring(result) end
        result = result or {error = err or "status indisponivel"}
        local mappingFile = io.open(mappingPath, "rb")
        if mappingFile then
            local raw = mappingFile:read("*a")
            mappingFile:close()
            local decodedOk, mapping = pcall(Json.decode, raw)
            if decodedOk and type(mapping) == "table" then result.portMapping = mapping end
        end
        love.thread.getChannel("seed_status_done"):push(
            result)
    ]])
    worker:start(endpoint, secret, game.installedInfoHash or game.infoHash,
        CONF_DIR .. "/daemon/port-mapping.json")
end

local function startSeedAction(action, game)
    if TEST_MODE then
        recordTestEvent(action, {id = game and game.id})
        if action == "pause_one" then detailsSeed.paused, detailsSeed.seeding = true, false end
        if action == "resume_one" then detailsSeed.paused, detailsSeed.seeding = false, true end
        return
    end
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
    if TEST_MODE and testInstalledPorts then
        for _, port in ipairs(testInstalledPorts) do table.insert(installedPorts, port) end
        uninstallerSelectedIdx = 1
        uninstallerScrollY = 0
        return
    end
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
                        itemId = record.id,
                        infoHash = record.infoHash,
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
        (os.getenv("KMP_ARIA2_RPC") or "") ~= "" and PYTHON ~= ""
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
        local resultPath = CATALOG_SYNC_RESULT
        os.remove(resultPath)
        local sync_thread = love.thread.newThread([[
            local python, script, sources, publicKey, state, pending, downloads,
                active, endpoint, secret, resultPath = ...
            local function quote(value) return "'" .. tostring(value):gsub("'", "'\\''") .. "'" end
            local command = quote(python) .. " " .. quote(script) .. " sync" ..
                " --sources " .. quote(sources) .. " --public-key " .. quote(publicKey) ..
                " --state " .. quote(state) .. " --pending " .. quote(pending) ..
                " --downloads " .. quote(downloads) .. " --active " .. quote(active) ..
                " --rpc " .. quote(endpoint) .. " --secret " .. quote(secret) ..
                " > " .. quote(resultPath) .. " 2>&1"
            local result = os.execute(command)
            local ok = result == true or result == 0
            love.thread.getChannel("sync_done"):push({distributed = true, ok = ok})
        ]])
        sync_thread:start(PYTHON, CATALOG_SYNC, CATALOG_SOURCES, CATALOG_PUBLIC_KEY,
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
    local items, validationError, metadata = Catalog.validate(parsed)
    if not items then return nil, validationError end
    for _, item in ipairs(items) do
        item.catalogSequence = metadata and metadata.sequence or 0
        item.seedNodes = metadata and metadata.seedNodes or {}
        item.filename = item.packageFile
        item.size = item.sizeBytes < 1048576 and
            string.format("%.1f KB", item.sizeBytes / 1024) or
            string.format("%.1f MB", item.sizeBytes / 1048576)
    end
    return items, nil, metadata
end

local function saveCatalogCache(content)
    if not love.filesystem.write("catalog-cache.json.tmp", content) then return end
    local saveDirectory = love.filesystem.getSaveDirectory()
    os.rename(saveDirectory .. "/catalog-cache.json.tmp", saveDirectory .. "/catalog-cache.json")
end

-- Motivo da última falha de sincronização, já traduzido para o usuário.
local function syncFailureReason()
    local file = io.open(CATALOG_SYNC_RESULT, "r")
    if not file then return nil end
    local content = file:read("*a") or ""
    file:close()
    local parsed = Json.decode(content)
    local errorText = type(parsed) == "table" and parsed.error or nil
    if type(errorText) ~= "string" then
        -- Sem JSON (por exemplo, um traceback do Python), usa a última linha não vazia.
        errorText = content:match("([^\n]+)%s*$")
    end
    return Catalog.syncFailureMessage(errorText)
end

function finishSync(event)
    syncing = false
    local distributed = type(event) == "table" and event.distributed
    local savePath = distributed and CATALOG_ACTIVE or
        (isWindows() and "kpm_catalog.json" or "/tmp/kpm_catalog.json")
    local file = io.open(savePath, "r")
    local content = file and file:read("*a") or nil
    if file then file:close() end
    local items, errorMessage, metadata = decodeCatalog(content)
    local fromCache = distributed and not event.ok or false
    if not items and not distributed then
        local cached = love.filesystem.read("catalog-cache.json")
        items, errorMessage, metadata = decodeCatalog(cached)
        fromCache = items ~= nil
    end
    local failure = distributed and not event.ok and syncFailureReason() or nil
    if not items then
        syncStatus = "Modo Offline"
        download.statusText = failure or errorMessage or "Sem Internet ou catálogo válido."
        download.statusColor = {1.0, 0.3, 0.3}
        isOffline = true
        return
    end
    catalogAll = {}
    clientUpdate = nil
    for _, item in ipairs(items) do
        if item.id == "kmp-client" then
            if Catalog.isUpdate(APP_VERSION, item.version) then
                item.isClientUpdate = true
                clientUpdate = item
            end
        else
            table.insert(catalogAll, item)
        end
    end
    catalogRevocations = {}
    for _, entry in ipairs((metadata and metadata.revocations) or {}) do
        catalogRevocations[entry.packageSha256] = entry
    end
    if clientUpdate and clientUpdate.packageSha256 then
        clientUpdate.downloadRevocation = catalogRevocations[clientUpdate.packageSha256]
    end
    incompatiblePorts = metadata and metadata.incompatible or 0
    applySearch()
    if not fromCache and not distributed then saveCatalogCache(content) end
    checkLocalFiles()
    local mode = distributed and "Distribuído" or "Online"
    syncStatus = (fromCache and "Offline" or mode) .. " (" .. #catalogAll .. " ports)"
    if incompatiblePorts > 0 then
        syncStatus = syncStatus .. " | " .. incompatiblePorts .. " incompatível(is)"
    end
    download.statusText = fromCache and (failure and ("Catálogo salvo. " .. failure) or "Usando catálogo salvo.") or
        "Lista sincronizada com sucesso!"
    download.statusColor = {0.2, 0.85, 0.45}
    if clientUpdateNotice then
        download.statusText, download.statusColor = clientUpdateNotice.text, clientUpdateNotice.color
        clientUpdateNotice = nil
    end
    isOffline = fromCache
end

-- O KMP.sh aplica a atualização depois que a interface fecha; sem este aviso, uma
-- falha (com volta à versão anterior) só aparecia no log.
local function readClientUpdateResult()
    if CLIENT_BASE == "" then return end
    local path = CLIENT_BASE .. "/.kmp/client-update/result.json"
    local handle = io.open(path, "r")
    if not handle then return end
    local result = Json.decode(handle:read("*a") or "")
    handle:close()
    os.remove(path)
    if type(result) ~= "table" then return end
    if result.ok then
        clientUpdateNotice = {text = "KMP atualizado para v" .. tostring(result.version or APP_VERSION) .. ".",
            color = {0.2, 0.85, 0.45}}
    else
        clientUpdateNotice = {text = ("Atualização do KMP falhou; versão anterior mantida: " ..
            tostring(result.error or "erro desconhecido")):sub(1, 140), color = {1.0, 0.3, 0.3}}
    end
    download.statusText, download.statusColor = clientUpdateNotice.text, clientUpdateNotice.color
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
    fontTiny  = love.graphics.newFont(10)
    fontBig   = love.graphics.newFont(22)
    fontIcon  = love.graphics.newFont(22)
    fontIconBig = love.graphics.newFont(34)

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

    communityEnabled = readCommunitySetting()
    startSync()
    readClientUpdateResult()
end

local function throttleFrame()
    if not love.timer.sleep then return end
    local now = love.timer.getTime()
    local busy = appState == "splash" or download.active or syncing or heldInput or showRestartPopup or
        firmwareWarning ~= nil or
        now - lastInputAt < IDLE_AFTER or math.abs(scrollTarget - scrollY) > 0.5
    local wait = (busy and ACTIVE_FRAME or IDLE_FRAME) - (now - lastFrameAt)
    if wait > 0 then love.timer.sleep(wait) end
    lastFrameAt = love.timer.getTime()
end

function love.update(dt)
    throttleFrame()
    updateHeldInput(dt)
    scrollY = scrollY + (scrollTarget - scrollY) * math.min(1, dt * 14)
    if diagnostic.active then
        local event = love.thread.getChannel("diagnostic_done"):pop()
        if event then
            diagnostic.active = false
            diagnostic.ok = event.ok == true
            diagnostic.path = event.path or ""
            diagnostic.message = event.ok and
                ("Diagnostico criado com " .. tostring(event.logs or 0) .. " log(s).") or
                ("Falha: " .. tostring(event.error or "erro desconhecido")):sub(1, 120)
        end
    end
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
            detailsSeedLastRefresh = love.timer.getTime()
        end
    end
    if showDetails and catalog[selectedIdx] and catalog[selectedIdx].installed and
       not detailsSeed.loading and
       love.timer.getTime() - detailsSeedLastRefresh >= detailsSeedRefreshInterval then
        startSeedStatus(catalog[selectedIdx])
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
        if torrentEvent.kind == "peer_test" then
            download.phase = "p2p"
            download.progress = 0
            download.statusText = "Só P2P: removendo o pacote local e desativando HTTPS..."
            download.statusColor = {0.95, 0.7, 0.2}
        elseif torrentEvent.kind == "cached" then
            download.phase = "cache"
            download.progress = 100
            download.statusText = download.updateMode and
                "Atualização já baixada; verificando pacote..." or
                "Arquivo já baixado; verificando para reinstalar..."
            download.statusColor = {0.2, 0.75, 1.0}
        elseif torrentEvent.kind == "started" then
            download.phase = "conectando"
            download.statusText = download.peerOnly and
                "Download só P2P iniciado; procurando somente peers..." or
                "Torrent iniciado; procurando fontes..."
            download.statusColor = {0.0, 0.82, 1.0}
        elseif torrentEvent.kind == "progress" then
            download.phase = "baixando"
            download.progress = torrentEvent.percent or 0
            download.speedBps = torrentEvent.speed or 0
            download.downloadedBytes = torrentEvent.done or 0
            download.totalBytes = torrentEvent.total or 0
            local route = torrentEvent.transport == "hybrid" and
                string.format("HTTPS + %d peer(s)", torrentEvent.connections or 0) or
                (torrentEvent.transport == "webseed" and "mirror HTTPS" or
                (torrentEvent.transport == "peers" and
                    string.format("%d peer(s)", torrentEvent.connections or 0) or nil))
            download.statusText = torrentEvent.waiting and "Procurando fontes..." or
                string.format("Baixando via %s... (%d%%)", route or "rede", download.progress)
            download.statusColor = {0.0, 0.82, 1.0}
        elseif torrentEvent.kind == "installing" then
            download.phase = "extraindo"
            download.progress = 100
            download.statusText = download.updateMode and
                "Verificado. Atualizando port com rollback protegido..." or
                "Verificado. Instalando pacote..."
            download.statusColor = {0.7, 0.4, 1.0}
        elseif torrentEvent.kind == "done" then
            download.active = false
            download.phase = "none"
            download.progress = 100
            download.ext_progress = 100
            download.statusText = "Concluído! " .. download.game.name ..
                (torrentEvent.updated and " atualizado." or " instalado.")
            download.statusColor = {0.2, 0.85, 0.45}
            checkLocalFiles()
            showRestartPopup = true
            restartPopupTimer = 8
        elseif torrentEvent.kind == "client_ready" then
            download.active = false
            download.phase = "none"
            download.progress = 100
            download.statusText = "Atualização do KMP pronta para aplicar."
            download.statusColor = {0.2, 0.85, 0.45}
            showClientUpdatePopup = true
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

local function startDiagnostic()
    diagnostic = {active = true, ok = false, message = "Coletando e protegendo os logs...", path = ""}
    appState = "diagnostic"
    if TEST_MODE then
        recordTestEvent("diagnostic")
        diagnostic = {active = false, ok = true, message = "Diagnostico criado com 2 log(s).",
            path = "/roms/ports/KMP/diagnostics/test.zip"}
        return
    end
    while love.thread.getChannel("diagnostic_done"):pop() do end
    if PYTHON == "" or DIAGNOSTIC_TOOL == "" or GAME_DIR == "" or
       CONF_DIR == "" or DIAGNOSTIC_OUTPUT == "" then
        diagnostic.active = false
        diagnostic.message = "Exportador de diagnostico indisponivel."
        return
    end
    local worker = love.thread.newThread([[
        local python, tool, gameDir, confDir, outputDir, version = ...
        local Json = require("json")
        local function quote(value) return "'" .. tostring(value):gsub("'", "'\\''") .. "'" end
        local command = quote(python) .. " " .. quote(tool) ..
            " --game-dir " .. quote(gameDir) .. " --config-dir " .. quote(confDir) ..
            " --output-dir " .. quote(outputDir) .. " --app-version " .. quote(version) ..
            " 2>&1"
        local process = io.popen(command)
        local output = process and process:read("*a") or ""
        if process then process:close() end
        local result = Json.decode(output)
        if type(result) ~= "table" then
            result = {ok = false, error = output ~= "" and output or "processo indisponivel"}
        end
        love.thread.getChannel("diagnostic_done"):push(result)
    ]])
    worker:start(PYTHON, DIAGNOSTIC_TOOL, GAME_DIR, CONF_DIR, DIAGNOSTIC_OUTPUT, APP_VERSION)
end

local function startTorrentDownload(game, peerOnly, updateMode)
    if TEST_MODE then
        download.active = true
        download.game = game
        download.peerOnly = peerOnly == true
        download.updateMode = updateMode == true
        download.statusText = "Torrent iniciado; procurando fontes..."
        recordTestEvent(game.isClientUpdate and "client_update" or
            (updateMode and "update" or (peerOnly and "p2p_test" or "install")),
            {id = game.id})
        return
    end
    local endpoint = os.getenv("KMP_ARIA2_RPC")
    local secret = os.getenv("KMP_ARIA2_SECRET")
    local installer = os.getenv("KMP_INSTALLER")
    if not endpoint or not secret or not installer or PYTHON == "" or isWindows() then
        download.statusText = "BitTorrent indisponível neste dispositivo."
        download.statusColor = {1.0, 0.3, 0.3}
        return
    end
    local basePorts = sdPaths[currentSd]
    -- A atualização do Client fica onde o KMP.sh a procura, não no cartão de destino
    -- dos ports; com cartões diferentes ela era preparada e nunca aplicada.
    if game.isClientUpdate and CLIENT_BASE ~= "" then basePorts = CLIENT_BASE end
    local directory = basePorts .. "/.kmp/torrents/" .. game.id
    if game.isClientUpdate then
        directory = basePorts .. "/.kmp/client-downloads/" .. game.infoHash:lower()
    elseif updateMode then
        directory = basePorts .. "/.kmp/updates/" .. game.id .. "-" .. game.infoHash:lower()
    elseif peerOnly then
        directory = basePorts .. "/.kmp/p2p-tests/" .. game.id .. "-" ..
            tostring(os.time()) .. "-" .. tostring(math.floor(love.timer.getTime() * 1000))
    end
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
    download.peerOnly = peerOnly == true
    download.updateMode = updateMode == true
    download.statusText = "Procurando peers..."
    download.statusColor = {0.0, 0.82, 1.0}
    while love.thread.getChannel("torrent_cancel"):pop() do end

    local worker = love.thread.newThread([[
        local python, game, basePorts, directory, endpoint, secret, installer, selfUpdater,
            peerOnly, updateMode = ...
        require("love.timer")
        local Json = require("json")
        local Rpc = require("aria2_rpc")
        local Torrent = require("torrent")
        local channel = love.thread.getChannel("torrent_event")
        local cancel = love.thread.getChannel("torrent_cancel")
        local function quote(value) return "'" .. tostring(value):gsub("'", "'\\''") .. "'" end
        local function fail(message) channel:push({kind = "error", message = message}) end
        local backend = Torrent.new(Rpc.new(endpoint, secret),
            {peer = os.getenv("KMP_PEER"), peerOnly = peerOnly,
             downloadLimit = peerOnly and "1M" or nil})
        if peerOnly then
            channel:push({kind = "peer_test"})
            local forgotten, forgetError = backend:forget(game.infoHash)
            if not forgotten then fail(forgetError or "não foi possível limpar o cache"); return end
            love.timer.sleep(0.5)
            forgotten, forgetError = backend:forget(game.infoHash)
            if not forgotten then fail(forgetError or "não foi possível remover o torrent anterior"); return end
        end
        local gid, err, reused = backend:start(game, directory)
        if not gid then fail(err or "aria2c não iniciou o torrent"); return end
        channel:push({kind = reused and "cached" or "started"})
        if reused then love.timer.sleep(0.7) end
        local lastProgress = 0
        local lastActivity = love.timer.getTime()
        local lastState = nil
        local lastPeers = love.timer.getTime()
        while true do
            if love.timer.getTime() - lastPeers >= 60 then
                backend:addPeers(gid, game)
                lastPeers = love.timer.getTime()
            end
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
                if game.isClientUpdate then
                    if not selfUpdater or selfUpdater == "" then
                        fail("atualizador do KMP indisponível"); return
                    end
                    local prepareCommand = quote(python) .. " " .. quote(selfUpdater) ..
                        " prepare " .. quote(directory .. "/" .. game.packageFile) .. " " ..
                        quote(basePorts) .. " " .. quote(itemFile) .. " " .. quote(selfUpdater)
                    local process = io.popen(prepareCommand ..
                        "; code=$?; printf '\n__KMP_EXIT__=%s\n' \"$code\"")
                    if not process then fail("preparador de atualização indisponível"); return end
                    local output = process:read("*a")
                    process:close()
                    local exitCode = tonumber((output or ""):match("__KMP_EXIT__=(%d+)"))
                    if exitCode ~= 0 then
                        output = (output or ""):gsub("%s*__KMP_EXIT__=%d+%s*$", "")
                        fail((output ~= "" and output or
                            "falha ao preparar atualização"):sub(1, 160))
                        return
                    end
                    channel:push({kind = "client_ready"})
                    return
                end
                local operation = updateMode and "update" or "install"
                local installCommand = quote(python) .. " " .. quote(installer) .. " " .. operation .. " " ..
                    quote(directory .. "/" .. game.packageFile) .. " " ..
                    quote(basePorts) .. " " .. quote(itemFile)
                local command = installCommand ..
                    "; code=$?; printf '\n__KMP_EXIT__=%s\n' \"$code\""
                local process = io.popen(command)
                if not process then fail("instalador indisponível"); return end
                local output = process:read("*a")
                process:close()
                local exitCode = tonumber((output or ""):match("__KMP_EXIT__=(%d+)"))
                output = (output or ""):gsub("%s*__KMP_EXIT__=%d+%s*$", "")
                if exitCode ~= 0 then fail((output ~= "" and output or
                    "falha na instalação"):sub(1, 160)); return end
                local manifest = basePorts .. "/.kmp/manifests/" .. game.install.portId .. ".json"
                local manifestHandle = io.open(manifest, "r")
                if not manifestHandle then
                    fail("instalador terminou sem registrar o port")
                    return
                end
                manifestHandle:close()
                if updateMode and game.installedInfoHash and
                   game.installedInfoHash:lower() ~= game.infoHash:lower() then
                    local forgotten = backend:forget(game.installedInfoHash)
                    if forgotten then
                        os.execute("rm -rf -- " .. quote(basePorts .. "/.kmp/torrents/" .. game.id))
                        os.execute("rm -rf -- " .. quote(basePorts .. "/.kmp/updates/" ..
                            game.id .. "-" .. game.installedInfoHash:lower()))
                    end
                end
                channel:push({kind = "done", updated = updateMode})
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
                    transport = state.transport, connections = state.connections})
            end
            love.timer.sleep(1)
        end
    ]])
    worker:start(PYTHON, game, basePorts, directory, endpoint, secret, installer,
        SELF_UPDATE_TOOL, peerOnly == true, updateMode == true)
end

function love.threaderror(thread, errorMessage)
    if diagnostic.active then
        diagnostic.active = false
        diagnostic.ok = false
        diagnostic.message = "Falha interna: " .. tostring(errorMessage):sub(1, 100)
        return
    end
    syncing = false
    download.active = false
    download.phase = "none"
    download.statusText = "Erro interno: " .. tostring(errorMessage):sub(1, 100)
    download.statusColor = {1.0, 0.3, 0.3}
end

function startDownload(game, peerOnly, updateMode)
    if not game or download.active or (game.installed and not updateMode) then return end
    if game.downloadRevocation and game.downloadRevocation.action == "block-install" then
        download.statusText = "Instalação bloqueada: " .. tostring(game.downloadRevocation.reason)
        download.statusColor = {1.0, 0.3, 0.3}
        return
    end
    -- O autor não listou este firmware: pergunta antes de baixar. Atualizações de um port
    -- já instalado não perguntam de novo.
    if game.firmwareUnverified and not game.firmwareAccepted and not updateMode then
        firmwareWarning = {game = game, peerOnly = peerOnly}
        if TEST_MODE then recordTestEvent("firmware_warning", {id = game.id}) end
        return
    end
    return startTorrentDownload(game, peerOnly == true, updateMode == true)
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
    if TEST_MODE then recordTestEvent("reboot"); return end
    if isWindows() then love.event.quit() else os.execute("sudo reboot") end
end

local function handleShutdown()
    if TEST_MODE then recordTestEvent("shutdown"); return end
    if isWindows() then love.event.quit() else os.execute("sudo poweroff") end
end

local function handleActionExit()
    if TEST_MODE then recordTestEvent("exit"); return end
    if bgm then bgm:stop() end
    os.exit(0)
end

local function loadCatalogTrust()
    catalogTrust = {configured = false, verified = false, active = false,
        sequence = 0, mirrors = 0, healthyMirrors = 0,
        fingerprint = "", expiresAt = "", error = ""}
    if PYTHON == "" or CATALOG_SYNC == "" or CATALOG_SOURCES == "" or CATALOG_PUBLIC_KEY == "" then
        return
    end
    local command = shellQuote(PYTHON) .. " " .. shellQuote(CATALOG_SYNC) .. " status" ..
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

-- Na grade, cima/baixo pulam uma linha inteira e param nas bordas, como numa loja;
-- esquerda/direita seguem a ordem do catálogo.
local function moveSelection(delta)
    if download.active or syncing or #catalog == 0 then return end
    selectedIdx = math.max(1, math.min(#catalog, selectedIdx + delta))
end

local function handleNavUp()
    if selectedIdx > GRID_COLUMNS then moveSelection(-GRID_COLUMNS) end
end

local function handleNavDown()
    local lastRow = math.ceil(#catalog / GRID_COLUMNS)
    if math.ceil(selectedIdx / GRID_COLUMNS) < lastRow then moveSelection(GRID_COLUMNS) end
end

local function handleNavLeft() moveSelection(-1) end
local function handleNavRight() moveSelection(1) end

local function handleTab(delta)
    if download.active or syncing then return end
    switchTab(delta)
end

local function handleActionConfirm()
    if download.active or syncing or #catalog == 0 then return end
    local game = catalog[selectedIdx]
    showDetails = true
    detailsScroll = 0
    detailsSeed = {loading = false, found = false}
    detailsSeedLastRefresh = 0
    startSeedStatus(game)
end

local function handleActionReload()
    if download.active or syncing then return end
    if TEST_MODE then recordTestEvent("reload"); return end
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
        if TEST_MODE then
            recordTestEvent("uninstall", {id = gameToUninstall.itemId or gameToUninstall.portId})
            table.remove(installedPorts, uninstallerSelectedIdx)
            uninstallerSelectedIdx = math.max(1, math.min(uninstallerSelectedIdx, #installedPorts))
            showUninstallPopup = false
            gameToUninstall = nil
            return
        end
        if not gameToUninstall.managed then
            uninstallError = "Port legado sem manifesto: remova manualmente."
        else
            local installer = os.getenv("KMP_INSTALLER")
            if not installer then
                uninstallError = "Instalador indisponível."
            else
                local endpoint = os.getenv("KMP_ARIA2_RPC")
                local secret = os.getenv("KMP_ARIA2_SECRET")
                if type(gameToUninstall.infoHash) ~= "string" or not endpoint or not secret then
                    uninstallError = "Daemon BitTorrent indisponível; remoção completa cancelada."
                    showUninstallPopup = false
                    gameToUninstall = nil
                    return
                end
                local ok, forgotten, forgetError = pcall(function()
                    local Rpc = require("aria2_rpc")
                    local Torrent = require("torrent")
                    local backend = Torrent.new(Rpc.new(endpoint, secret))
                    local removed, err = backend:forget(gameToUninstall.infoHash)
                    if not removed then return nil, err end
                    love.timer.sleep(0.5)
                    return backend:forget(gameToUninstall.infoHash)
                end)
                if not ok or not forgotten then
                    uninstallError = (forgetError or forgotten or
                        "não foi possível remover a semeação"):sub(1, 100)
                    showUninstallPopup = false
                    gameToUninstall = nil
                    return
                end
                local uninstallCommand = shellQuote(PYTHON) .. " " .. shellQuote(installer) ..
                    " uninstall " .. shellQuote(gameToUninstall.path) .. " " ..
                    shellQuote(gameToUninstall.portId)
                local command = uninstallCommand ..
                    "; code=$?; printf '\n__KMP_EXIT__=%s\n' \"$code\""
                local process = io.popen(command)
                local output = process and process:read("*a") or "Instalador indisponível"
                if process then process:close() end
                local exitCode = tonumber((output or ""):match("__KMP_EXIT__=(%d+)"))
                output = (output or ""):gsub("%s*__KMP_EXIT__=%d+%s*$", "")
                local manifest = gameToUninstall.path .. "/.kmp/manifests/" ..
                    gameToUninstall.portId .. ".json"
                local manifestHandle = io.open(manifest, "r")
                if manifestHandle then manifestHandle:close() end
                if exitCode == 0 and not manifestHandle then
                    scanInstalledPorts()
                    checkLocalFiles()
                else
                    uninstallError = (output ~= "" and output or
                        "Desinstalador terminou sem remover o manifesto"):sub(1, 100)
                end
            end
        end
        showUninstallPopup = false
        gameToUninstall = nil
    end
end

if TEST_MODE then
    _G.KMP_TEST_API = {
        reset = function()
            appState = "main"
            showMenu, showSearch, showDetails = false, false, false
            showUninstallPopup, showRestartPopup, showClientUpdatePopup = false, false, false
            firmwareWarning = nil
            menuSelected, powerMenuSelected, selectedIdx = 1, 1, 1
            storeTab, heldInput, axisDirection = 1, nil, {leftx = 0, lefty = 0}
            searchQuery, searchSelected = "", 1
            syncing = false
            download = {active = false, phase = "none", progress = 0, ext_progress = 0,
                game = nil, statusText = "", statusColor = {0.55, 0.62, 0.72}, speedBps = 0}
            detailsSeed = {loading = false, found = false}
            testEvents = {}
            while love.thread.getChannel("torrent_cancel"):pop() do end
        end,
        setCatalog = function(items)
            catalogAll, catalog = items, items
            selectedIdx = 1
        end,
        setClientUpdate = function(item) clientUpdate = item end,
        setInstalledPorts = function(items) testInstalledPorts = items end,
        events = function() return testEvents end,
        snapshot = function()
            return {appState = appState, showMenu = showMenu, showSearch = showSearch,
                showDetails = showDetails, showUninstallPopup = showUninstallPopup,
                menuSelected = menuSelected, selectedIdx = selectedIdx,
                searchQuery = searchQuery, downloadActive = download.active,
                downloadStatus = download.statusText, diagnostic = diagnostic,
                clientUpdate = clientUpdate, showClientUpdatePopup = showClientUpdatePopup,
                firmwareWarning = firmwareWarning and firmwareWarning.game.id or nil,
                installedPorts = #installedPorts, storeTab = storeTab, visiblePorts = #catalog}
        end,
    }
end

local function answerFirmwareWarning(proceed)
    local pending = firmwareWarning
    firmwareWarning = nil
    if proceed and pending then
        pending.game.firmwareAccepted = true
        startDownload(pending.game, pending.peerOnly)
    end
end

local function onKey(key)
    if appState == "splash" then return end

    if firmwareWarning then
        if key == "return" then answerFirmwareWarning(true)
        elseif key == "escape" or key == "backspace" or key == "b" or key == "space" then
            answerFirmwareWarning(false)
        end
        return
    end

    if showClientUpdatePopup then
        if key == "b" or key == "return" then
            if TEST_MODE then recordTestEvent("apply_client_update") end
            love.event.quit()
        elseif key == "a" or key == "space" or key == "escape" or key == "backspace" then
            showClientUpdatePopup = false
        end
        return
    end

    if appState == "diagnostic" then
        if not diagnostic.active and (key == "a" or key == "b" or key == "return" or
           key == "space" or key == "escape" or key == "q" or key == "backspace") then
            appState = "main"
            showMenu = true
        end
        return
    end

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
        if key == "return" and game.installed and game.updateAvailable then
            showDetails = false
            startDownload(game, false, true)
        elseif key == "return" and game.installed then
            startSeedAction(detailsSeed.paused and "resume_one" or "pause_one", game)
        elseif key == "return" then
            showDetails = false
            startDownload(game)
        elseif key == "x" and game.installed then startSeedAction("pause_all", game)
        elseif key == "x" then
            showDetails = false
            startDownload(game, true)
        elseif key == "y" and game.installed then startSeedAction("resume_all", game)
        elseif key == "up" or key == "w" then detailsScroll = math.max(0, detailsScroll - detailsScrollStep)
        elseif key == "down" or key == "s" then detailsScroll = math.min(detailsScrollMax, detailsScroll + detailsScrollStep)
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
            if menuSelected < 1 then menuSelected = 8 end
        elseif key == "down" or key == "s" then
            menuSelected = menuSelected + 1
            if menuSelected > 8 then menuSelected = 1 end
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
                if clientUpdate then startDownload(clientUpdate) end
            elseif menuSelected == 6 then
                showMenu = false
                startDiagnostic()
            elseif menuSelected == 7 then
                toggleCommunity()
            elseif menuSelected == 8 then
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
    elseif key == "left" then handleNavLeft()
    elseif key == "right" then handleNavRight()
    elseif key == "pageup" then handleTab(-1)
    elseif key == "pagedown" then handleTab(1)
    elseif key == "b" or key == "return" then handleActionConfirm()
    elseif key == "x" then toggleMusic()
    elseif key == "y" then handleActionReload()
    elseif key == "space" or key == "escape" or key == "a" or key == "q" or key == "backspace" then
        showMenu = true
        menuSelected = 1
    end
end

function love.textinput(text)
    lastInputAt = love.timer.getTime()
    if showSearch and text:match("^[%w%s_-]+$") and #searchQuery < 40 then
        searchQuery = searchQuery .. text
        applySearch()
    end
end

local function onGamepadButton(joystick, button)
    if appState == "splash" then return end

    if firmwareWarning then
        if button == "a" then answerFirmwareWarning(true)
        elseif button == "b" or button == "back" then answerFirmwareWarning(false) end
        return
    end

    if showClientUpdatePopup then
        if button == "a" then
            if TEST_MODE then recordTestEvent("apply_client_update") end
            love.event.quit()
        elseif button == "b" or button == "back" or button == "start" then
            showClientUpdatePopup = false
        end
        return
    end

    if appState == "diagnostic" then
        if not diagnostic.active and
           (button == "a" or button == "b" or button == "back" or button == "start") then
            appState = "main"
            showMenu = true
        end
        return
    end

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
        if button == "a" and game.installed and game.updateAvailable then
            showDetails = false
            startDownload(game, false, true)
        elseif button == "a" and game.installed then
            startSeedAction(detailsSeed.paused and "resume_one" or "pause_one", game)
        elseif button == "a" then
            showDetails = false
            startDownload(game)
        elseif button == "x" and game.installed then
            startSeedAction("pause_all", game)
        elseif button == "x" then
            showDetails = false
            startDownload(game, true)
        elseif button == "y" and game.installed then
            startSeedAction("resume_all", game)
        elseif button == "dpup" then detailsScroll = math.max(0, detailsScroll - detailsScrollStep)
        elseif button == "dpdown" then detailsScroll = math.min(detailsScrollMax, detailsScroll + detailsScrollStep)
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
            if menuSelected < 1 then menuSelected = 8 end
        elseif button == "dpdown" then
            menuSelected = menuSelected + 1
            if menuSelected > 8 then menuSelected = 1 end
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
                if clientUpdate then startDownload(clientUpdate) end
            elseif menuSelected == 6 then
                showMenu = false
                startDiagnostic()
            elseif menuSelected == 7 then
                toggleCommunity()
            elseif menuSelected == 8 then
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
    elseif button == "dpleft" then handleNavLeft()
    elseif button == "dpright" then handleNavRight()
    elseif button == "leftshoulder" then handleTab(-1)
    elseif button == "rightshoulder" then handleTab(1)
    elseif button == "a" then handleActionConfirm()
    elseif button == "x" then toggleMusic()
    elseif button == "y" then handleActionReload()
    elseif button == "back" or button == "start" then
        showMenu = true
        menuSelected = 1
    end
end

local REPEAT_DELAY, REPEAT_INTERVAL = 0.32, 0.075
local REPEATABLE_BUTTONS = {dpup = true, dpdown = true, dpleft = true, dpright = true}
local REPEATABLE_KEYS = {up = true, down = true, left = true, right = true, w = true, s = true}

function love.keypressed(key)
    lastInputAt = love.timer.getTime()
    onKey(key)
    if REPEATABLE_KEYS[key] then heldInput = {kind = "key", id = key, timer = REPEAT_DELAY} end
end

function love.keyreleased(key)
    if heldInput and heldInput.kind == "key" and heldInput.id == key then heldInput = nil end
end

function love.gamepadpressed(joystick, button)
    lastInputAt = love.timer.getTime()
    onGamepadButton(joystick, button)
    if REPEATABLE_BUTTONS[button] then heldInput = {kind = "pad", id = button, timer = REPEAT_DELAY} end
end

function love.gamepadreleased(joystick, button)
    if heldInput and heldInput.kind == "pad" and heldInput.id == button then heldInput = nil end
end

function updateHeldInput(dt)
    if not heldInput then return end
    heldInput.timer = heldInput.timer - dt
    while heldInput and heldInput.timer <= 0 do
        heldInput.timer = heldInput.timer + REPEAT_INTERVAL
        if heldInput.kind == "pad" then onGamepadButton(nil, heldInput.id) else onKey(heldInput.id) end
    end
end

-- Cada evento do analógico acima do limite movia a seleção de novo, e ela saltava
-- vários itens; agora o eixo vira um direcional que só dispara ao cruzar o limite.
function love.gamepadaxis(joystick, axis, value)
    if axisDirection[axis] == nil then return end
    local previous = axisDirection[axis]
    local direction = previous
    if math.abs(value) >= 0.6 then direction = value < 0 and -1 or 1
    elseif math.abs(value) < 0.35 then direction = 0 end
    if direction == previous then return end
    local buttons = axis == "lefty" and {[-1] = "dpup", [1] = "dpdown"} or {[-1] = "dpleft", [1] = "dpright"}
    if previous ~= 0 then love.gamepadreleased(joystick, buttons[previous]) end
    axisDirection[axis] = direction
    if direction ~= 0 then love.gamepadpressed(joystick, buttons[direction]) end
end

-- ============================================================
-- LOJA: grade de cartões, abas e página do port
-- ============================================================
local ACCENT = {0.0, 0.82, 1.0}
local ICON_COLORS = {
    {0.16, 0.55, 0.98}, {0.96, 0.42, 0.25}, {0.20, 0.78, 0.52}, {0.70, 0.40, 0.98},
    {0.98, 0.70, 0.18}, {0.95, 0.32, 0.55}, {0.18, 0.72, 0.82}, {0.55, 0.62, 0.95},
}
local SMALL_WORDS = {["for"] = true, ["of"] = true, ["the"] = true, ["and"] = true,
    ["de"] = true, ["da"] = true, ["do"] = true, ["dos"] = true, ["das"] = true, ["e"] = true}

-- Os testes usam fontes falsas sem métricas; nesses casos o texto passa sem corte.
local function textWidth(font, text)
    if font and font.getWidth then return font:getWidth(text) end
    return #text * 7
end

local function ellipsize(font, text, width)
    text = tostring(text or "")
    if textWidth(font, text) <= width then return text end
    while #text > 0 and textWidth(font, text .. "…") > width do
        local cut = utf8.offset(text, -1) or #text
        text = text:sub(1, cut - 1)
    end
    return text .. "…"
end

local function wrapLines(font, text, width, maxLines)
    if not (font and font.getWrap) then return {tostring(text or "")} end
    local _, lines = font:getWrap(tostring(text or ""), width)
    if #lines > maxLines then
        local kept = {}
        for index = 1, maxLines do kept[index] = lines[index] end
        kept[maxLines] = ellipsize(font, kept[maxLines] .. " " .. lines[maxLines + 1], width)
        return kept
    end
    return lines
end

local function lineHeight(font, fallback)
    return font and font.getHeight and font:getHeight() or fallback
end

local function initials(name)
    local letters = {}
    for word in tostring(name or ""):gmatch("[%w\128-\255]+") do
        if not SMALL_WORDS[word:lower()] or #letters == 0 then
            local first = word:sub(1, (utf8.offset(word, 2) or #word + 1) - 1)
            letters[#letters + 1] = first:upper()
            if #letters == 2 then break end
        end
    end
    if #letters == 0 then return "?" end
    return table.concat(letters)
end

local function iconColor(game)
    local hash = 0
    for index = 1, #(game.id or "") do hash = (hash * 31 + game.id:byte(index)) % 2147483647 end
    return ICON_COLORS[hash % #ICON_COLORS + 1]
end

-- Sem capas no catálogo, cada port ganha um ícone com as iniciais e uma cor estável.
local function drawIcon(game, x, y, size, font)
    local color = iconColor(game)
    love.graphics.setColor(color[1], color[2], color[3])
    love.graphics.rectangle("fill", x, y, size, size, size * 0.24, size * 0.24)
    love.graphics.setColor(1, 1, 1, 0.14)
    love.graphics.rectangle("fill", x + size * 0.1, y + size * 0.08, size * 0.8, size * 0.1, size * 0.05, size * 0.05)
    love.graphics.setColor(1, 1, 1)
    love.graphics.setFont(font)
    love.graphics.printf(initials(game.name), x, y + (size - lineHeight(font, size * 0.5)) / 2, size, "center")
end

local function storeStatus(game)
    if game.revocation then return "ALERTA", {1.0, 0.35, 0.35} end
    if game.updateAvailable then return "ATUALIZAR", {0.95, 0.65, 0.2} end
    if game.installed then return "INSTALADO", {0.2, 0.85, 0.45} end
    return "OBTER", ACCENT
end

local function drawChip(text, color, x, y, alignRight)
    love.graphics.setFont(fontTiny)
    local width = textWidth(fontTiny, text) + 14
    if alignRight then x = x - width end
    love.graphics.setColor(color[1], color[2], color[3], 0.16)
    love.graphics.rectangle("fill", x, y, width, 18, 9, 9)
    love.graphics.setColor(color[1], color[2], color[3])
    love.graphics.printf(text, x, y + (18 - lineHeight(fontTiny, 12)) / 2, width, "center")
    return width
end

local function porterName(game)
    if type(game.porter) == "table" and game.porter.name then return game.porter.name end
    return "Port da comunidade"
end

-- Coordenadas da área visível em pixels de tela, para o recorte com setScissor.
local function scissor(x, y, width, height)
    love.graphics.setScissor(offsetX + x * scale, offsetY + y * scale, width * scale, height * scale)
end

local function drawScrollbar(x, top, height, contentHeight, offset)
    if contentHeight <= height then return end
    local thumb = math.max(24, height * height / contentHeight)
    local position = top + (height - thumb) * (offset / (contentHeight - height))
    love.graphics.setColor(1, 1, 1, 0.06)
    love.graphics.rectangle("fill", x, top, 3, height, 2, 2)
    love.graphics.setColor(ACCENT[1], ACCENT[2], ACCENT[3], 0.7)
    love.graphics.rectangle("fill", x, position, 3, thumb, 2, 2)
end

local function drawCard(game, x, y, selected)
    love.graphics.setColor(selected and 0.13 or 0.10, selected and 0.17 or 0.12, selected and 0.24 or 0.17)
    love.graphics.rectangle("fill", x, y, CARD_W, CARD_H, 12, 12)
    if selected then
        love.graphics.setColor(ACCENT[1], ACCENT[2], ACCENT[3], 0.9)
        love.graphics.setLineWidth(2)
        love.graphics.rectangle("line", x, y, CARD_W, CARD_H, 12, 12)
    end

    drawIcon(game, x + 12, y + 12, 52, fontIcon)
    local status, color = storeStatus(game)
    drawChip(status, color, x + CARD_W - 12, y + 12, true)
    love.graphics.setFont(fontTiny)
    love.graphics.setColor(0.55, 0.62, 0.72)
    love.graphics.printf(game.size or "", x + 72, y + 38, CARD_W - 84, "right")
    love.graphics.printf("v" .. tostring(game.version or "-"), x + 72, y + 52, CARD_W - 84, "right")

    love.graphics.setFont(fontItem)
    love.graphics.setColor(0.94, 0.96, 1.0)
    local lines = wrapLines(fontItem, game.name, CARD_W - 24, 2)
    local nameHeight = lineHeight(fontItem, 19)
    for index, line in ipairs(lines) do
        love.graphics.print(line, x + 12, y + 72 + (index - 1) * nameHeight)
    end
    love.graphics.setFont(fontSub)
    love.graphics.setColor(0.48, 0.55, 0.66)
    love.graphics.print(ellipsize(fontSub, porterName(game), CARD_W - 24), x + 12, y + 76 + #lines * nameHeight)
end

local function storeEmptyMessage()
    if #catalogAll > 0 and searchQuery ~= "" then return "Nenhum resultado para: " .. searchQuery end
    if storeTab == 2 and #catalogAll > 0 then return "Nenhum port instalado em " .. sdLabels[currentSd] .. "." end
    if storeTab == 3 and #catalogAll > 0 then return "Tudo em dia: nenhuma atualização pendente." end
    if syncStatus:find("(0 ports)", 1, true) then return "Nenhum homebrew no catálogo." end
    if isOffline then return "Conexao ou leitura falhou." end
    return "Aguardando lista de ports..."
end

local function drawStore()
    love.graphics.setColor(ACCENT[1], ACCENT[2], ACCENT[3])
    love.graphics.rectangle("fill", 24, 16, 46, 26, 7, 7)
    love.graphics.setColor(0.02, 0.06, 0.10)
    love.graphics.setFont(fontSub)
    love.graphics.printf("KPM", 24, 22, 46, "center")
    love.graphics.setFont(fontTitle)
    love.graphics.setColor(0.96, 0.97, 1.0)
    love.graphics.print("Loja de Ports", 80, 17)
    love.graphics.setFont(fontTiny)
    love.graphics.setColor(0.45, 0.52, 0.62)
    love.graphics.print("v" .. APP_VERSION .. "  ·  " .. sdLabels[currentSd], 82, 39)

    local pillColor = isOffline and {1.0, 0.4, 0.4} or ACCENT
    love.graphics.setFont(fontSub)
    local pillText = ellipsize(fontSub, syncStatus, 220)
    local pillWidth = textWidth(fontSub, pillText) + 24
    love.graphics.setColor(pillColor[1], pillColor[2], pillColor[3], 0.15)
    love.graphics.rectangle("fill", 616 - pillWidth, 18, pillWidth, 22, 11, 11)
    love.graphics.setColor(pillColor[1], pillColor[2], pillColor[3])
    love.graphics.printf(pillText, 616 - pillWidth, 18 + (22 - lineHeight(fontSub, 14)) / 2, pillWidth, "center")

    -- Abas: L1/R1 alternam entre todo o catálogo, instalados e atualizações.
    local tabX = 24
    for index, label in ipairs(STORE_TABS) do
        local count = index > 1 and countTab(index) or 0
        local text = count > 0 and (label .. "  " .. count) or label
        love.graphics.setFont(fontItem)
        local width = textWidth(fontItem, text) + 28
        local active = index == storeTab
        love.graphics.setColor(active and ACCENT[1] or 1, active and ACCENT[2] or 1, active and ACCENT[3] or 1,
            active and 0.18 or 0.04)
        love.graphics.rectangle("fill", tabX, 58, width, 30, 15, 15)
        if index == 3 and count > 0 and not active then love.graphics.setColor(0.95, 0.65, 0.2)
        elseif active then love.graphics.setColor(ACCENT[1], ACCENT[2], ACCENT[3])
        else love.graphics.setColor(0.62, 0.68, 0.78) end
        love.graphics.printf(text, tabX, 58 + (30 - lineHeight(fontItem, 18)) / 2, width, "center")
        tabX = tabX + width + 8
    end
    love.graphics.setFont(fontTiny)
    love.graphics.setColor(0.40, 0.46, 0.56)
    love.graphics.printf("L1 / R1", tabX, 67, 616 - tabX, "right")

    love.graphics.setFont(fontSub)
    love.graphics.setColor(0.62, 0.68, 0.78)
    local heading = searchQuery ~= "" and ("Busca: " .. searchQuery) or
        ({"Todos os ports", "Instalados em " .. sdLabels[currentSd], "Atualizações e alertas"})[storeTab]
    love.graphics.print(heading, 24, 96)
    love.graphics.setColor(0.40, 0.46, 0.56)
    love.graphics.printf(#catalog .. (#catalog == 1 and " port" or " ports"), 420, 96, 196, "right")

    if #catalog == 0 then
        love.graphics.setColor(0.45, 0.52, 0.62)
        love.graphics.setFont(fontItem)
        love.graphics.printf(storeEmptyMessage(), 24, 230, 592, "center")
        if isOffline and #catalogAll == 0 then
            love.graphics.setFont(fontSub)
            love.graphics.setColor(1.0, 0.4, 0.4)
            love.graphics.printf("Aperte (Y) para tentar de novo", 24, 260, 592, "center")
        end
        return
    end

    -- A linha selecionada sempre cabe inteira na área visível; update() anima até lá.
    local pitch = CARD_H + CARD_GAP
    local viewHeight = GRID_BOTTOM - GRID_TOP
    local rows = math.ceil(#catalog / GRID_COLUMNS)
    local contentHeight = rows * pitch - CARD_GAP
    local rowTop = (math.ceil(selectedIdx / GRID_COLUMNS) - 1) * pitch
    if rowTop < scrollTarget then scrollTarget = rowTop
    elseif rowTop + CARD_H > scrollTarget + viewHeight then scrollTarget = rowTop + CARD_H - viewHeight end
    scrollTarget = math.max(0, math.min(scrollTarget, math.max(0, contentHeight - viewHeight)))
    scrollY = math.max(0, math.min(scrollY, math.max(0, contentHeight - viewHeight)))

    scissor(0, GRID_TOP - 2, 640, viewHeight + 4)
    for index, game in ipairs(catalog) do
        local column = (index - 1) % GRID_COLUMNS
        local row = math.floor((index - 1) / GRID_COLUMNS)
        local y = GRID_TOP + row * pitch - scrollY
        if y + CARD_H >= GRID_TOP - 2 and y <= GRID_BOTTOM + 2 then
            drawCard(game, 24 + column * (CARD_W + CARD_GAP), y, index == selectedIdx)
        end
    end
    love.graphics.setScissor()
    drawScrollbar(630, GRID_TOP, viewHeight, contentHeight, scrollY)
end

-- Botão desenhado no rodapé; devolve a posição do próximo.
local function drawHint(x, y, label, text, color)
    love.graphics.setFont(fontSub)
    local labelWidth = math.max(18, textWidth(fontSub, label) + 8)
    love.graphics.setColor(color[1] * 0.35, color[2] * 0.35, color[3] * 0.35)
    love.graphics.rectangle("fill", x, y, labelWidth, 18, 4, 4)
    love.graphics.setColor(color[1], color[2], color[3])
    love.graphics.printf(label, x, y + 3, labelWidth, "center")
    love.graphics.setColor(0.52, 0.58, 0.68)
    love.graphics.print(text, x + labelWidth + 6, y + 3)
    return x + labelWidth + 6 + textWidth(fontSub, text) + 16
end

local HINT_A, HINT_B = {0.95, 0.85, 0.2}, {0.95, 0.35, 0.35}
local HINT_X, HINT_Y = {0.3, 0.6, 1.0}, {0.2, 0.85, 0.45}
local HINT_MENU = {0.75, 0.78, 0.85}

local function drawStoreFooter()
    love.graphics.setColor(0.04, 0.04, 0.07, 0.96)
    love.graphics.rectangle("fill", 0, 422, 640, 58)
    love.graphics.setColor(1, 1, 1, 0.06)
    love.graphics.line(0, 422, 640, 422)
    love.graphics.setColor(download.statusColor)
    love.graphics.setFont(fontSmall)
    love.graphics.print(ellipsize(fontSmall, download.statusText, 592), 24, 429)

    local x = drawHint(24, 452, "A", "Abrir", HINT_A)
    x = drawHint(x, 452, "Y", "Atualizar", HINT_Y)
    local music = not bgm and "Música" or (isMusicPaused and "Música: off" or "Música: on")
    x = drawHint(x, 452, "X", music, HINT_X)
    drawHint(x, 452, "SEL", "Menu", HINT_MENU)
end

local function drawDetailsPage(game)
    love.graphics.setColor(0.06, 0.07, 0.10)
    love.graphics.rectangle("fill", 0, 0, 640, 480)

    drawIcon(game, 24, 22, 84, fontIconBig)
    love.graphics.setFont(fontBig)
    love.graphics.setColor(0.96, 0.97, 1.0)
    local titleLines = wrapLines(fontBig, game.name, 492, 2)
    local titleHeight = lineHeight(fontBig, 26)
    for index, line in ipairs(titleLines) do love.graphics.print(line, 124, 22 + (index - 1) * titleHeight) end
    local metaY = 26 + #titleLines * titleHeight
    love.graphics.setFont(fontSub)
    love.graphics.setColor(ACCENT[1], ACCENT[2], ACCENT[3])
    love.graphics.print(ellipsize(fontSub, porterName(game), 492), 124, metaY)
    local status, statusColor = storeStatus(game)
    local statusText = status == "OBTER" and "DISPONÍVEL" or status
    drawChip(statusText, statusColor, 124, metaY + 22)

    -- Botão principal: a ação de A muda conforme o estado do port.
    local revoked = game.revocation ~= nil
    local action
    if game.installed and game.updateAvailable then
        action = "Atualizar para v" .. tostring(game.version or "-")
    elseif game.installed then
        action = detailsSeed.paused and "Retomar semeação" or "Pausar semeação"
    else
        action = "Instalar  ·  " .. tostring(game.size or "")
    end
    -- Antes da instalação, o download só P2P (X) fica ao lado do botão principal; no
    -- rodapé ele passava despercebido.
    local mainWidth = game.installed and 592 or 420
    local filled = not game.installed or game.updateAvailable
    local buttonColor = game.updateAvailable and {0.95, 0.65, 0.2} or ACCENT
    if filled then
        love.graphics.setColor(buttonColor[1], buttonColor[2], buttonColor[3])
        love.graphics.rectangle("fill", 24, 118, mainWidth, 40, 10, 10)
        love.graphics.setColor(0.02, 0.06, 0.10)
    else
        love.graphics.setColor(ACCENT[1], ACCENT[2], ACCENT[3])
        love.graphics.setLineWidth(1.5)
        love.graphics.rectangle("line", 24, 118, mainWidth, 40, 10, 10)
    end
    love.graphics.setFont(fontItem)
    local buttonTextY = 118 + (40 - lineHeight(fontItem, 18)) / 2
    love.graphics.printf("(A)  " .. action, 24, buttonTextY, mainWidth, "center")
    if not game.installed then
        love.graphics.setColor(HINT_X[1], HINT_X[2], HINT_X[3])
        love.graphics.setLineWidth(1.5)
        love.graphics.rectangle("line", 456, 118, 160, 40, 10, 10)
        love.graphics.printf("(X)  Só P2P", 456, buttonTextY, 160, "center")
    end

    -- Faixa de informações, como numa página de loja.
    local versionValue = game.installed and game.installedVersion and game.updateAvailable and
        (tostring(game.installedVersion) .. " > " .. tostring(game.version)) or tostring(game.version or "-")
    local stats = {{versionValue, "Versão"}, {game.size or "-", "Tamanho"},
        {game.license or "-", "Licença"}, {sdLabels[currentSd]:match("^(%S+)"), "Destino"}}
    for index, stat in ipairs(stats) do
        local x = 24 + (index - 1) * 148
        if index > 1 then
            love.graphics.setColor(1, 1, 1, 0.08)
            love.graphics.line(x, 176, x, 210)
        end
        love.graphics.setFont(fontItem)
        love.graphics.setColor(0.92, 0.94, 0.98)
        love.graphics.printf(ellipsize(fontItem, stat[1], 136), x + 6, 174, 136, "center")
        love.graphics.setFont(fontTiny)
        love.graphics.setColor(0.48, 0.55, 0.66)
        love.graphics.printf(stat[2], x + 6, 198, 136, "center")
    end

    local sectionY = 226
    if game.installed then
        love.graphics.setColor(1, 1, 1, 0.04)
        love.graphics.rectangle("fill", 24, 222, 592, 52, 8, 8)
        love.graphics.setFont(fontSub)
        local seedText = "Semeação: consultando..."
        if not detailsSeed.loading then
            if detailsSeed.error then seedText = "Semeação: " .. detailsSeed.error
            elseif not detailsSeed.found then seedText = "Semeação: torrent fora do daemon"
            elseif detailsSeed.seeding then seedText = "Semeação: ativa"
            elseif detailsSeed.paused then seedText = "Semeação: pausada (bateria ou usuário)"
            else seedText = "Semeação: " .. tostring(detailsSeed.phase or "inativa") end
        end
        local mapping = detailsSeed.portMapping or {}
        local networkText
        if mapping.active and mapping.addressScope == "cgnat" then
            networkText = "Rede: CGNAT; somente conexões de saída"
        elseif mapping.active then
            networkText = "Rede: " .. tostring(mapping.method or "automática"):upper() ..
                " na porta " .. tostring(mapping.port or 6881)
        else
            networkText = "Rede: sem abertura automática"
        end
        love.graphics.setColor(revoked and 1.0 or 0.82, revoked and 0.35 or 0.88, revoked and 0.35 or 0.95)
        love.graphics.print(revoked and ellipsize(fontSub, "ALERTA DE SEGURANÇA: " ..
            tostring(game.revocation.reason), 570) or seedText, 36, 230)
        love.graphics.setColor(0.55, 0.62, 0.72)
        local transfer = detailsSeed.found and string.format(
            "Enviado %.1f MB  ·  ratio %.2f  ·  %.1f KB/s  ·  %d peer(s)  ·  ",
            (detailsSeed.uploaded or 0) / 1048576, detailsSeed.ratio or 0,
            (detailsSeed.uploadSpeed or 0) / 1024, detailsSeed.connections or 0) or ""
        love.graphics.print(ellipsize(fontSub, transfer .. networkText, 570), 36, 252)
        sectionY = 286
    end

    love.graphics.setFont(fontTitle)
    love.graphics.setColor(0.96, 0.97, 1.0)
    love.graphics.print("Sobre este port", 24, sectionY)
    -- A área mostra linhas inteiras e a rolagem anda de linha em linha.
    love.graphics.setFont(fontItem)
    local textLine = lineHeight(fontItem, 19)
    local textTop = sectionY + 28
    local viewHeight = math.floor((414 - textTop) / textLine) * textLine
    local description = tostring(game.description or "Sem descrição")
    local lineCount = 1
    if fontItem.getWrap then
        local _, lines = fontItem:getWrap(description, 580)
        lineCount = #lines
    end
    local contentHeight = lineCount * textLine
    detailsScrollStep = textLine
    detailsScrollMax = math.max(0, contentHeight - viewHeight)
    detailsScroll = math.min(detailsScroll, detailsScrollMax)
    scissor(24, textTop, 600, viewHeight)
    love.graphics.setColor(0.72, 0.78, 0.86)
    love.graphics.printf(description, 24, textTop - detailsScroll, 580, "left")
    love.graphics.setScissor()
    drawScrollbar(612, textTop, viewHeight, contentHeight, detailsScroll)

    love.graphics.setColor(0.04, 0.04, 0.07, 0.96)
    love.graphics.rectangle("fill", 0, 422, 640, 58)
    love.graphics.setColor(1, 1, 1, 0.06)
    love.graphics.line(0, 422, 640, 422)
    love.graphics.setColor(download.statusColor)
    love.graphics.setFont(fontSmall)
    love.graphics.print(ellipsize(fontSmall, download.statusText, 592), 24, 429)
    local x
    if game.installed then
        x = drawHint(24, 452, "A", game.updateAvailable and "Atualizar" or
            (detailsSeed.paused and "Retomar" or "Pausar"), HINT_A)
        x = drawHint(x, 452, "X", "Pausar todos", HINT_X)
        x = drawHint(x, 452, "Y", "Retomar todos", HINT_Y)
    else
        x = drawHint(24, 452, "A", "Instalar", HINT_A)
    end
    if detailsScrollMax > 0 then x = drawHint(x, 452, "D-PAD", "Rolar", HINT_MENU) end
    drawHint(x, 452, "B", "Voltar", HINT_B)
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
            local visibleRows = 5

            if uninstallerSelectedIdx * rowH - uninstallerScrollY > visibleRows * rowH then
                uninstallerScrollY = (uninstallerSelectedIdx - visibleRows) * rowH
            elseif uninstallerSelectedIdx * rowH - uninstallerScrollY < rowH then
                uninstallerScrollY = (uninstallerSelectedIdx - 1) * rowH
            end

            for i, port in ipairs(installedPorts) do
                local y = startY + (i - 1) * rowH - uninstallerScrollY
                
                if y >= 60 and y <= 380 then
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
            love.graphics.printf("Port, saves, cache e semeacao serao apagados de " .. gameToUninstall.label .. ".",
                120, 245, 400, "center")
            love.graphics.setColor(0.45, 0.52, 0.62)
            love.graphics.setFont(fontSub)
            love.graphics.printf("A: Sim (Apagar)    B: Nao (Cancelar)", 120, 280, 400, "center")
        end

    else
        -- ==============================================
        -- TELA PRINCIPAL: LOJA DE PORTS
        -- ==============================================
        drawStore()

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
                love.graphics.printf(download.updateMode and "BAIXANDO ATUALIZAÇÃO..." or
                    "BAIXANDO PORT...", 120, 170, 400, "center")
            elseif download.phase == "p2p" then
                love.graphics.printf("PREPARANDO DOWNLOAD SÓ P2P...", 120, 170, 400, "center")
            elseif download.phase == "cache" then
                love.graphics.printf("REUTILIZANDO DOWNLOAD...", 120, 170, 400, "center")
            elseif download.phase == "conectando" then
                love.graphics.printf("PROCURANDO FONTES...", 120, 170, 400, "center")
            elseif download.phase == "extraindo" then
                love.graphics.printf(download.updateMode and "APLICANDO ATUALIZAÇÃO..." or
                    "VALIDANDO E INSTALANDO...", 120, 170, 400, "center")
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
            elseif download.phase == "p2p" then
                love.graphics.setColor(0.95, 0.7, 0.2)
                love.graphics.rectangle("fill", 150, 245, 34, 16, 8, 8)
            elseif download.phase == "cache" then
                love.graphics.setColor(0.2, 0.75, 1.0)
                love.graphics.rectangle("fill", 150, 245, 340, 16, 8, 8)
            elseif download.phase == "extraindo" then
                love.graphics.setColor(0.7, 0.4, 1.0)
                love.graphics.rectangle("fill", 150, 245, 340, 16, 8, 8)
            end

            love.graphics.setColor(0.96, 0.97, 1.0)
            love.graphics.setFont(fontSub)
            
            local infoText = ""
            if download.phase == "p2p" then
                infoText = "Apagando o ZIP local; mirrors HTTPS desativados."
            elseif download.phase == "baixando" then
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
            elseif download.phase == "cache" then
                infoText = "Usando o ZIP local e conferindo integridade."
            elseif download.phase == "conectando" then
                infoText = download.peerOnly and
                    "HTTPS bloqueado; procurando peers via rede local, DHT e trackers." or
                    "Consultando web seeds, DHT, trackers e peers locais."
            else
                infoText = "Download verificado; preparando instalação."
            end

            love.graphics.printf(infoText, 120, 280, 400, "center")
        end

        drawStoreFooter()

        if showMenu then
            love.graphics.setColor(0, 0, 0, 0.85)
            love.graphics.rectangle("fill", 0, 0, 640, 480)

            love.graphics.setColor(0.1, 0.15, 0.22, 0.98)
            love.graphics.rectangle("fill", 170, 50, 300, 385, 12, 12)

            love.graphics.setColor(0.0, 0.82, 1.0, 0.6)
            love.graphics.setLineWidth(2)
            love.graphics.rectangle("line", 170, 50, 300, 385, 12, 12)

            love.graphics.setColor(0.96, 0.97, 1.0)
            love.graphics.setFont(fontTitle)
            love.graphics.printf("MENU DE OPCOES", 170, 65, 300, "center")

            love.graphics.setColor(1, 1, 1, 0.1)
            love.graphics.line(190, 95, 450, 95)

            local opt1_y = 105
            if menuSelected == 1 then
                love.graphics.setColor(0.0, 0.82, 1.0, 0.2)
                love.graphics.rectangle("fill", 190, opt1_y - 6, 260, 36, 6, 6)
                love.graphics.setColor(0.0, 0.82, 1.0)
                love.graphics.rectangle("line", 190, opt1_y - 6, 260, 36, 6, 6)
                love.graphics.setColor(1, 1, 1)
            else love.graphics.setColor(0.6, 0.65, 0.75) end
            love.graphics.setFont(fontItem)
            love.graphics.printf("Mudar Destino: " .. sdLabels[currentSd], 170, opt1_y, 300, "center")

            local opt2_y = 147
            if menuSelected == 2 then
                love.graphics.setColor(1.0, 0.3, 0.3, 0.2)
                love.graphics.rectangle("fill", 190, opt2_y - 6, 260, 36, 6, 6)
                love.graphics.setColor(1.0, 0.3, 0.3)
                love.graphics.rectangle("line", 190, opt2_y - 6, 260, 36, 6, 6)
                love.graphics.setColor(1, 1, 1)
            else love.graphics.setColor(0.6, 0.65, 0.75) end
            love.graphics.printf("Pesquisar por nome", 170, opt2_y, 300, "center")

            local opt3_y = 189
            if menuSelected == 3 then
                love.graphics.setColor(0.85, 0.65, 0.2, 0.2)
                love.graphics.rectangle("fill", 190, opt3_y - 6, 260, 36, 6, 6)
                love.graphics.setColor(0.85, 0.65, 0.2)
                love.graphics.rectangle("line", 190, opt3_y - 6, 260, 36, 6, 6)
                love.graphics.setColor(1, 1, 1)
            else love.graphics.setColor(0.6, 0.65, 0.75) end
            love.graphics.printf("Desinstalador de Ports", 170, opt3_y, 300, "center")

            local opt4_y = 231
            if menuSelected == 4 then
                love.graphics.setColor(0.85, 0.65, 0.2, 0.2)
                love.graphics.rectangle("fill", 190, opt4_y - 6, 260, 36, 6, 6)
                love.graphics.setColor(0.85, 0.65, 0.2)
                love.graphics.rectangle("line", 190, opt4_y - 6, 260, 36, 6, 6)
                love.graphics.setColor(1, 1, 1)
            else love.graphics.setColor(0.6, 0.65, 0.75) end
            love.graphics.printf("Confianca do Catalogo", 170, opt4_y, 300, "center")

            local opt5_y = 273
            if menuSelected == 5 then
                love.graphics.setColor(0.2, 0.85, 0.45, 0.2)
                love.graphics.rectangle("fill", 190, opt5_y - 6, 260, 36, 6, 6)
                love.graphics.setColor(0.2, 0.85, 0.45)
                love.graphics.rectangle("line", 190, opt5_y - 6, 260, 36, 6, 6)
                love.graphics.setColor(1, 1, 1)
            else love.graphics.setColor(0.6, 0.65, 0.75) end
            local clientUpdateText = clientUpdate and
                ("Atualizar KMP: v" .. tostring(clientUpdate.version)) or
                ("KMP atualizado: v" .. APP_VERSION)
            love.graphics.printf(clientUpdateText, 170, opt5_y, 300, "center")

            local opt6_y = 315
            if menuSelected == 6 then
                love.graphics.setColor(0.2, 0.85, 0.45, 0.2)
                love.graphics.rectangle("fill", 190, opt6_y - 6, 260, 36, 6, 6)
                love.graphics.setColor(0.2, 0.85, 0.45)
                love.graphics.rectangle("line", 190, opt6_y - 6, 260, 36, 6, 6)
                love.graphics.setColor(1, 1, 1)
            else love.graphics.setColor(0.6, 0.65, 0.75) end
            love.graphics.printf("Exportar diagnostico", 170, opt6_y, 300, "center")

            local opt7_y = 353
            if menuSelected == 7 then
                love.graphics.setColor(0.2, 0.85, 0.45, 0.2)
                love.graphics.rectangle("fill", 190, opt7_y - 6, 260, 32, 6, 6)
                love.graphics.setColor(0.2, 0.85, 0.45)
                love.graphics.rectangle("line", 190, opt7_y - 6, 260, 32, 6, 6)
                love.graphics.setColor(1, 1, 1)
            else love.graphics.setColor(0.6, 0.65, 0.75) end
            love.graphics.printf("No comunitario: " .. (communityEnabled and "ativo" or "inativo"), 170, opt7_y, 300, "center")

            local opt8_y = 389
            if menuSelected == 8 then
                love.graphics.setColor(1.0, 0.3, 0.3, 0.2)
                love.graphics.rectangle("fill", 190, opt8_y - 6, 260, 32, 6, 6)
                love.graphics.setColor(1.0, 0.3, 0.3)
                love.graphics.rectangle("line", 190, opt8_y - 6, 260, 32, 6, 6)
                love.graphics.setColor(1, 1, 1)
            else love.graphics.setColor(0.6, 0.65, 0.75) end
            love.graphics.printf("Sair", 170, opt8_y, 300, "center")

            love.graphics.setColor(0.45, 0.52, 0.62)
            love.graphics.setFont(fontSub)
            love.graphics.printf("A: Confirmar   B: Voltar", 170, 421, 300, "center")
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

        if showDetails and catalog[selectedIdx] then drawDetailsPage(catalog[selectedIdx]) end

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

        if appState == "diagnostic" then
            love.graphics.setColor(0, 0, 0, 0.9)
            love.graphics.rectangle("fill", 0, 0, 640, 480)
            love.graphics.setColor(0.08, 0.12, 0.18, 0.99)
            love.graphics.rectangle("fill", 70, 95, 500, 290, 12, 12)
            love.graphics.setColor(diagnostic.active and 0.0 or (diagnostic.ok and 0.2 or 1.0),
                diagnostic.active and 0.82 or (diagnostic.ok and 0.85 or 0.35),
                diagnostic.active and 1.0 or (diagnostic.ok and 0.45 or 0.35), 0.8)
            love.graphics.setLineWidth(2)
            love.graphics.rectangle("line", 70, 95, 500, 290, 12, 12)
            love.graphics.setFont(fontTitle)
            love.graphics.printf("DIAGNOSTICO DE SUPORTE", 90, 120, 460, "center")
            love.graphics.setFont(fontItem)
            love.graphics.setColor(0.86, 0.9, 0.96)
            love.graphics.printf(diagnostic.message, 105, 180, 430, "center")
            if diagnostic.path ~= "" then
                love.graphics.setFont(fontSub)
                love.graphics.setColor(0.55, 0.68, 0.82)
                love.graphics.printf("Arquivo salvo em:", 105, 230, 430, "center")
                love.graphics.setColor(0.9, 0.94, 1.0)
                love.graphics.printf(diagnostic.path, 100, 255, 440, "center")
            end
            love.graphics.setFont(fontSub)
            love.graphics.setColor(0.48, 0.58, 0.7)
            local diagnosticHint = diagnostic.active and "Aguarde..." or "A/B: Voltar"
            love.graphics.printf(diagnosticHint, 105, 340, 430, "center")
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

        if firmwareWarning then
            local tested = table.concat(firmwareWarning.game.testedFirmwares or {}, ", ")
            local firmware = os.getenv("KMP_FIRMWARE") or ""
            love.graphics.setColor(0, 0, 0, 0.82)
            love.graphics.rectangle("fill", 0, 0, 640, 480)
            love.graphics.setColor(0.08, 0.12, 0.18, 0.99)
            love.graphics.rectangle("fill", 70, 115, 500, 255, 14, 14)
            love.graphics.setColor(1.0, 0.72, 0.25)
            love.graphics.setLineWidth(2)
            love.graphics.rectangle("line", 70, 115, 500, 255, 14, 14)
            love.graphics.setFont(fontTitle)
            love.graphics.printf("FIRMWARE NÃO CONFIRMADO", 90, 140, 460, "center")
            love.graphics.setColor(0.86, 0.9, 0.96)
            love.graphics.setFont(fontItem)
            love.graphics.printf("O autor de " .. firmwareWarning.game.name .. " não informou que ele roda no seu firmware" ..
                (firmware ~= "" and (" (" .. firmware .. ")") or "") .. ". Pode haver instabilidade ou travamento.",
                90, 182, 460, "center")
            if tested ~= "" then
                love.graphics.setColor(0.55, 0.68, 0.82)
                love.graphics.setFont(fontSub)
                love.graphics.printf("Testado pelo autor em: " .. tested, 90, 272, 460, "center")
            end
            love.graphics.setColor(0.86, 0.9, 0.96)
            love.graphics.setFont(fontItem)
            love.graphics.printf("Deseja prosseguir?", 90, 302, 460, "center")
            love.graphics.setColor(0.55, 0.68, 0.82)
            love.graphics.setFont(fontSub)
            love.graphics.printf("A: baixar mesmo assim   B: cancelar", 90, 335, 460, "center")
        end

        if showClientUpdatePopup then
            love.graphics.setColor(0, 0, 0, 0.82)
            love.graphics.rectangle("fill", 0, 0, 640, 480)
            love.graphics.setColor(0.08, 0.12, 0.18, 0.99)
            love.graphics.rectangle("fill", 85, 135, 470, 215, 14, 14)
            love.graphics.setColor(0.2, 0.85, 0.45)
            love.graphics.setLineWidth(2)
            love.graphics.rectangle("line", 85, 135, 470, 215, 14, 14)
            love.graphics.setFont(fontTitle)
            love.graphics.printf("ATUALIZAÇÃO DO KMP PRONTA", 105, 165, 430, "center")
            love.graphics.setColor(0.86, 0.9, 0.96)
            love.graphics.setFont(fontItem)
            love.graphics.printf("A versão verificada será aplicada depois que\na interface for encerrada.",
                105, 215, 430, "center")
            love.graphics.setColor(0.55, 0.68, 0.82)
            love.graphics.setFont(fontSub)
            love.graphics.printf("A: aplicar agora e sair   B: aplicar ao sair depois",
                105, 305, 430, "center")
        end
    end

    love.graphics.pop()
end
