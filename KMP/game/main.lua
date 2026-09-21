-- ============================================================
-- KDownloader PM - Versão Final com Velocidade e Rodapé Completo
-- ============================================================

local SCRIPT_URL = "https://script.google.com/macros/s/AKfycby6WpLHqHxdJPI_N6odgK0QYOpV8ob_MFSr2F4_ydKlj6AWbSCDY33GihPqy7TaEAIG/exec"

local sdPaths = { "/roms/ports", "/roms2/ports" }
local autoinstallPaths = { "/roms/ports/autoinstall", "/roms2/ports/autoinstall" }
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

local showRestartPopup = false
local restartPopupTimer = 0

local showUninstallPopup = false
local gameToUninstall = nil

local installedPorts = {}
local uninstallerSelectedIdx = 1
local uninstallerScrollY = 0

local bgm = nil
local bgmVolume = 0.5
local isMusicPaused = false

local function parse_json(str)
    local pos = 1
    local function skip_whitespace()
        while pos <= #str and str:sub(pos, pos):match("%s") do pos = pos + 1 end
    end
    local parse_value
    local function parse_string()
        pos = pos + 1
        local start = pos
        while pos <= #str do
            local c = str:sub(pos, pos)
            if c == '"' then
                local res = str:sub(start, pos - 1)
                pos = pos + 1
                return res
            elseif c == '\\' then pos = pos + 2 else pos = pos + 1 end
        end
        return ""
    end
    local function parse_number()
        local start = pos
        if str:sub(pos, pos) == '-' then pos = pos + 1 end
        while pos <= #str and str:sub(pos, pos):match("[%d%.eE%+]") do pos = pos + 1 end
        return tonumber(str:sub(start, pos - 1)) or 0
    end
    local function parse_array()
        pos = pos + 1
        local arr = {}
        skip_whitespace()
        if str:sub(pos, pos) == ']' then pos = pos + 1; return arr end
        while pos <= #str do
            table.insert(arr, parse_value())
            skip_whitespace()
            local c = str:sub(pos, pos)
            if c == ']' then pos = pos + 1; return arr
            elseif c == ',' then pos = pos + 1 else break end
        end
        return arr
    end
    local function parse_object()
        pos = pos + 1
        local obj = {}
        skip_whitespace()
        if str:sub(pos, pos) == '}' then pos = pos + 1; return obj end
        while pos <= #str do
            skip_whitespace()
            local key = parse_string()
            skip_whitespace()
            if str:sub(pos, pos) == ':' then pos = pos + 1 end
            skip_whitespace()
            obj[key] = parse_value()
            skip_whitespace()
            local c = str:sub(pos, pos)
            if c == '}' then pos = pos + 1; return obj
            elseif c == ',' then pos = pos + 1 else break end
        end
        return obj
    end
    parse_value = function()
        skip_whitespace()
        local c = str:sub(pos, pos)
        if c == '"' then return parse_string()
        elseif c == '{' then return parse_object()
        elseif c == '[' then return parse_array()
        elseif c:match("[%d%-]") then return parse_number()
        elseif str:sub(pos, pos + 3) == "true" then pos = pos + 4; return true
        elseif str:sub(pos, pos + 4) == "false" then pos = pos + 5; return false
        elseif str:sub(pos, pos + 3) == "null" then pos = pos + 4; return nil end
        pos = pos + 1
        return nil
    end
    return parse_value()
end

local catalog = {}
local selectedIdx = 1
local fontTitle, fontItem, fontSub, fontSmall
local syncStatus = "Conectando..."
local isOffline = true
local syncing = false

local download = {
    active = false,
    phase = "none",
    progress = 0,
    ext_progress = 0,
    game = nil,
    statusText = "Aguarde, verificando conexao...",
    statusColor = {0.55, 0.62, 0.72},
    lastT = nil,
    lastSize = 0,
    speedBps = 0
}

local function isWindows() return love.system.getOS() == "Windows" end

local function isInstalled(game)
    local basePorts = sdPaths[currentSd]
    if isWindows() then basePorts = "." end

    local p1 = basePorts .. "/" .. game.name
    local f1 = io.open(p1, "r")
    if f1 then f1:close(); return true end

    local p2 = basePorts .. "/" .. game.name .. ".sh"
    local f2 = io.open(p2, "r")
    if f2 then f2:close(); return true end

    return false
end

local function checkLocalFiles()
    for _, game in ipairs(catalog) do
        game.installed = isInstalled(game)
    end
end

local function scanInstalledPorts()
    installedPorts = {}
    local function scanDir(basePath, label)
        local h = io.popen('ls -1 "' .. basePath .. '"/*.sh 2>/dev/null')
        if h then
            for file in h:lines() do
                local name = file:match("([^/]+)%.sh$")
                if name then
                    table.insert(installedPorts, {
                        name = name,
                        filename = name .. ".sh",
                        path = basePath,
                        label = label
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
    syncStatus = "Sincronizando..."
    download.statusText = "Conectando ao servidor..."
    download.statusColor = {0.55, 0.62, 0.72}
    isOffline = false
    syncing = true

    if SCRIPT_URL == "" then
        syncStatus = "Sem Script"
        download.statusText = "Erro: URL do Script nao configurada."
        download.statusColor = {1.0, 0.3, 0.3}
        isOffline = true
        syncing = false
        return
    end

    local savePath = isWindows() and "kpm_catalog.json" or "/tmp/kpm_catalog.json"
    os.remove(savePath)

    local sync_thread = love.thread.newThread([[
        local url, path = ...
        os.execute(string.format('curl -L -k -s --max-time 20 -A "Mozilla/5.0" "%s" -o "%s"', url, path))
        love.thread.getChannel("sync_done"):push(true)
    ]])
    sync_thread:start(SCRIPT_URL, savePath)
end

function finishSync()
    syncing = false
    local savePath = isWindows() and "kpm_catalog.json" or "/tmp/kpm_catalog.json"
    
    local f = io.open(savePath, "r")
    if not f then
        syncStatus = "Modo Offline"
        download.statusText = "Sem Internet ou erro de rede."
        download.statusColor = {1.0, 0.3, 0.3}
        isOffline = true
        return
    end

    local content = f:read("*a") or ""
    f:close()

    if #content < 5 then
        syncStatus = "Erro de Leitura"
        download.statusText = "Servidor nao retornou dados."
        download.statusColor = {1.0, 0.3, 0.3}
        isOffline = true
        return
    end

    local head = content:sub(1, 200):lower()
    if head:match("<!doctype") or head:match("<html") then
        syncStatus = "Bloqueado"
        download.statusText = "Servidor devolveu HTML. Verifique o Script."
        download.statusColor = {1.0, 0.3, 0.3}
        isOffline = true
        return
    end

    local parsed = parse_json(content)
    if type(parsed) ~= "table" then
        syncStatus = "Erro no JSON"
        download.statusText = "Formato de resposta invalido."
        download.statusColor = {1.0, 0.3, 0.3}
        isOffline = true
        return
    end

    if parsed.error then
        syncStatus = "Erro no Script"
        download.statusText = "Script: " .. tostring(parsed.error):sub(1, 60)
        download.statusColor = {1.0, 0.3, 0.3}
        isOffline = true
        return
    end

    if #parsed == 0 then
        syncStatus = "Pasta Vazia"
        download.statusText = "Nenhum arquivo .zip encontrado."
        download.statusColor = {0.85, 0.7, 0.2}
        return
    end

    for _, item in ipairs(parsed) do
        table.insert(catalog, item)
    end

    selectedIdx = 1
    scrollY = 0
    checkLocalFiles()
    syncStatus = "Online (" .. #catalog .. " ports)"
    download.statusText = "Lista sincronizada com sucesso!"
    download.statusColor = {0.2, 0.85, 0.45}
    isOffline = false
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

    if not isWindows() then
        os.execute("mkdir -p " .. autoinstallPaths[currentSd])
    end
    
    if love.filesystem.getInfo("logo.png") then
        logoImg = love.graphics.newImage("logo.png")
    end

    if love.filesystem.getInfo("bgm.ogg") then
        bgm = love.audio.newSource("bgm.ogg", "stream")
    elseif love.filesystem.getInfo("bgm.mp3") then
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
    if appState == "splash" then
        splashTimer = splashTimer + dt
        if syncing then
            if love.thread.getChannel("sync_done"):pop() then
                finishSync()
            end
        else
            if splashTimer >= 2.0 then
                appState = "main"
            end
        end
        return
    end

    if syncing then
        if love.thread.getChannel("sync_done"):pop() then
            finishSync()
        end
    end

    if restartPopupTimer > 0 then
        restartPopupTimer = restartPopupTimer - dt
        if restartPopupTimer <= 0 then
            showRestartPopup = false
        end
    end

    if not download.active then return end

    local status = love.thread.getChannel("dl_status"):pop()
    if status == "extracting" then
        download.phase = "extraindo"
        download.ext_progress = 0
    elseif status == "done" then
        download.progress = 100
        download.ext_progress = 100
        download.active = false
        download.phase = "none"
        download.game.installed = true
        download.statusText = "Concluido! " .. download.game.name .. " instalado."
        download.statusColor = {0.2, 0.85, 0.45}

        local p = isWindows() and download.game.filename or (autoinstallPaths[currentSd] .. "/" .. download.game.filename)
        os.execute('rm -f "' .. p .. '"')
        checkLocalFiles()

        showRestartPopup = true
        restartPopupTimer = 8
    elseif status == "error_file" or status == "error_zip" then
        download.progress = 0
        download.ext_progress = 0
        download.active = false
        download.phase = "none"
        download.statusText = (status == "error_zip") and "Erro: Arquivo invalido (nao e ZIP)." or "Erro critico de download."
        download.statusColor = {1.0, 0.3, 0.3}
        local p = isWindows() and download.game.filename or (autoinstallPaths[currentSd] .. "/" .. download.game.filename)
        os.execute('rm -f "' .. p .. '"')
    end

    if download.phase == "baixando" then
        local p = isWindows() and download.game.filename or (autoinstallPaths[currentSd] .. "/" .. download.game.filename)
        local f = io.open(p, "rb")
        if f then
            local currentSize = f:seek("end") or 0
            f:close()
            
            local now = love.timer.getTime()
            if not download.lastT then
                download.lastT = now
                download.lastSize = 0
            end
            
            local timeDiff = now - download.lastT
            if timeDiff >= 0.5 then
                local bytesDiff = currentSize - (download.lastSize or 0)
                download.speedBps = bytesDiff / timeDiff
                download.lastT = now
                download.lastSize = currentSize
            end

            local totalSize = download.game.sizeBytes or 1
            if totalSize > 0 then
                download.progress = math.min(99, (currentSize / totalSize) * 100)
            end
        end
        download.statusText = string.format("Baixando %s... (%d%%)", download.game.name, math.floor(download.progress))
        download.statusColor = {0.0, 0.82, 1.0}
        
    elseif download.phase == "extraindo" then
        local p
        while true do
            local next_p = love.thread.getChannel("ext_progress"):pop()
            if not next_p then break end
            p = next_p
        end
        if p then download.ext_progress = p end
        download.statusText = string.format("Descompactando arquivos... (%d%%)", math.floor(download.ext_progress))
        download.statusColor = {0.7, 0.4, 1.0} 
    end
end

function startDownload(game)
    if not game or download.active or game.installed then return end
    download.active = true
    download.phase = "baixando"
    download.progress = 0
    download.ext_progress = 0
    download.game = game
    download.lastT = nil
    download.lastSize = 0
    download.speedBps = 0

    local path = autoinstallPaths[currentSd] .. "/" .. game.filename
    if isWindows() then path = game.filename end

    local url = game.downloadUrl
    if not url or url == "" then
        url = "https://pixeldrain.com/api/file/" .. game.driveId .. "?download"
    end

    local basePorts = sdPaths[currentSd]
    if isWindows() then basePorts = "." end

    local dl_thread = love.thread.newThread([[
        local url, path, basePorts = ...
        os.execute(string.format('curl -L -s -k --max-time 7200 -A "Mozilla/5.0" %q -o %q', url, path))

        local f = io.open(path, "rb")
        if f then
            local magic = f:read(2) or ""
            f:close()
            if magic ~= "PK" then
                love.thread.getChannel("dl_status"):push("error_zip")
                return
            end
        else
            love.thread.getChannel("dl_status"):push("error_file")
            return
        end

        love.thread.getChannel("dl_status"):push("extracting")
        local h1 = io.popen(string.format('unzip -l %q | wc -l', path))
        local total_str = h1:read("*a")
        h1:close()
        local total_lines = tonumber(total_str and total_str:match("%d+")) or 100
        if total_lines < 1 then total_lines = 1 end

        local h2 = io.popen(string.format('cd %q && unzip -o %q 2>&1', basePorts, path))
        local count = 0
        local last_pct = -1
        for line in h2:lines() do
            count = count + 1
            local pct = math.floor((count / total_lines) * 100)
            if pct > 100 then pct = 100 end
            if pct > last_pct then
                love.thread.getChannel("ext_progress"):push(pct)
                last_pct = pct
            end
        end
        h2:close()
        os.execute(string.format('chmod +x %q/*.sh 2>/dev/null', basePorts))
        love.thread.getChannel("dl_status"):push("done")
    ]])
    dl_thread:start(url, path, basePorts)
end

local function handleToggleSD()
    currentSd = (currentSd == 1) and 2 or 1
    if not isWindows() then
        os.execute("mkdir -p " .. autoinstallPaths[currentSd])
    end
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
    love.event.quit()
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
    if not game.installed then
        startDownload(game)
    end
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
        os.execute(string.format('rm -rf "%s/%s"', gameToUninstall.path, gameToUninstall.name))
        os.execute(string.format('rm -f "%s/%s"', gameToUninstall.path, gameToUninstall.filename))
        scanInstalledPorts()
        checkLocalFiles()
        showUninstallPopup = false
        gameToUninstall = nil
    end
end

function love.keypressed(key)
    if appState == "splash" then return end

    if showRestartPopup then
        if key == "return" or key == "b" or key == "space" or key == "a" or key == "escape" or key == "x" then
            showRestartPopup = false
            restartPopupTimer = 0
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
                    showUninstallPopup = true
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
            if menuSelected < 1 then menuSelected = 3 end
        elseif key == "down" or key == "s" then
            menuSelected = menuSelected + 1
            if menuSelected > 3 then menuSelected = 1 end
        elseif key == "b" or key == "return" then
            if menuSelected == 1 then handleToggleSD()
            elseif menuSelected == 2 then 
                showMenu = false
                scanInstalledPorts()
                appState = "uninstaller"
            elseif menuSelected == 3 then
                showMenu = false
                appState = "power_menu"
                powerMenuSelected = 1
            end
        elseif key == "a" or key == "space" or key == "escape" or key == "q" or key == "backspace" then
            showMenu = false
        end
        return
    end

    if download.active or syncing then return end

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

function love.gamepadpressed(joystick, button)
    if appState == "splash" then return end

    if showRestartPopup then
        if button == "a" or button == "b" or button == "back" or button == "start" then
            showRestartPopup = false
            restartPopupTimer = 0
        end
        return
    end

    if appState == "uninstaller" then
        if showUninstallPopup then
            if button == "b" then
                executeUninstall()
            elseif button == "a" or button == "back" or button == "start" then
                showUninstallPopup = false
                gameToUninstall = nil
            end
        else
            if button == "dpup" then handleUninstallerNavUp()
            elseif button == "dpdown" then handleUninstallerNavDown()
            elseif button == "leftshoulder" then handleUninstallerPageUp()
            elseif button == "rightshoulder" then handleUninstallerPageDown()
            elseif button == "b" then
                if #installedPorts > 0 then
                    gameToUninstall = installedPorts[uninstallerSelectedIdx]
                    showUninstallPopup = true
                end
            elseif button == "a" or button == "back" or button == "start" then
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
        elseif button == "b" then
            if powerMenuSelected == 1 then handleActionExit()
            elseif powerMenuSelected == 2 then handleReboot()
            elseif powerMenuSelected == 3 then handleShutdown() end
        elseif button == "a" or button == "back" or button == "start" then
            appState = "main"
            showMenu = true
        end
        return
    end

    if showMenu then
        if button == "dpup" then
            menuSelected = menuSelected - 1
            if menuSelected < 1 then menuSelected = 3 end
        elseif button == "dpdown" then
            menuSelected = menuSelected + 1
            if menuSelected > 3 then menuSelected = 1 end
        elseif button == "b" then
            if menuSelected == 1 then handleToggleSD()
            elseif menuSelected == 2 then 
                showMenu = false
                scanInstalledPorts()
                appState = "uninstaller"
            elseif menuSelected == 3 then
                showMenu = false
                appState = "power_menu"
                powerMenuSelected = 1
            end
        elseif button == "a" or button == "back" or button == "start" then
            showMenu = false
        end
        return
    end

    if download.active or syncing then return end

    if button == "dpup" then handleNavUp()
    elseif button == "dpdown" then handleNavDown()
    elseif button == "leftshoulder" then handleNavPageUp()
    elseif button == "rightshoulder" then handleNavPageDown()
    elseif button == "b" then handleActionConfirm()
    elseif button == "x" then toggleMusic()
    elseif button == "y" then handleActionReload()
    elseif button == "back" or button == "start" then
        showMenu = true
        menuSelected = 1
    end
end

function love.gamepadaxis(joystick, axis, value)
    if appState == "splash" or showRestartPopup or download.active or syncing then return end
    
    if axis == "lefty" then
        if value < -0.6 then
            if appState == "power_menu" then
                powerMenuSelected = powerMenuSelected - 1
                if powerMenuSelected < 1 then powerMenuSelected = 3 end
            elseif appState == "uninstaller" and not showUninstallPopup then
                handleUninstallerNavUp()
            elseif showMenu then
                menuSelected = menuSelected - 1
                if menuSelected < 1 then menuSelected = 3 end
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
                if menuSelected > 3 then menuSelected = 1 end
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
    
    elseif appState == "uninstaller" then
        love.graphics.setColor(1.0, 0.3, 0.3)
        love.graphics.rectangle("fill", 24, 18, 46, 22, 4, 4)
        love.graphics.setColor(1, 1, 1)
        love.graphics.setFont(fontSub)
        love.graphics.printf("KPM", 24, 23, 46, "center")

        love.graphics.setFont(fontTitle)
        love.graphics.setColor(0.96, 0.97, 1.0)
        love.graphics.print("Gerenciador de Ports (Desinstalador)", 78, 19)

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
                    love.graphics.printf(port.label, 520, y + 28, 80, "center")
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
        love.graphics.printf("B", 24, 453, 18, "center")
        love.graphics.setColor(0.40, 0.46, 0.56)
        love.graphics.print("Desinstalar", 48, 453)

        love.graphics.setColor(0.15, 0.25, 0.4)
        love.graphics.rectangle("fill", 150, 450, 18, 18, 4, 4)
        love.graphics.setColor(0.3, 0.6, 1.0)
        love.graphics.printf("A", 150, 453, 18, "center")
        love.graphics.setColor(0.40, 0.46, 0.56)
        love.graphics.print("Voltar", 174, 453)

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
            love.graphics.printf("Os arquivos serao apagados de " .. gameToUninstall.label .. ".", 120, 245, 400, "center")
            love.graphics.setColor(0.45, 0.52, 0.62)
            love.graphics.setFont(fontSub)
            love.graphics.printf("B: Sim (Apagar)    A: Nao (Cancelar)", 120, 280, 400, "center")
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
            if isOffline then
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
                love.graphics.printf("DESCOMPACTANDO...", 120, 170, 400, "center")
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
                love.graphics.rectangle("fill", 150, 245, 340 * (download.ext_progress / 100), 16, 8, 8)
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
                infoText = string.format("Progresso: %d%%   |   Velocidade: %s", math.floor(download.progress), speedStr)
            else
                infoText = string.format("Progresso: %d%%", math.floor(download.ext_progress))
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
        
        -- INSTALAR (B)
        love.graphics.setColor(0.35, 0.3, 0.1)
        love.graphics.rectangle("fill", 24, 452, 18, 18, 4, 4)
        love.graphics.setColor(0.95, 0.85, 0.2)
        love.graphics.printf("B", 24, 455, 18, "center")
        love.graphics.setColor(0.40, 0.46, 0.56)
        love.graphics.print("Instalar", 47, 455)

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
            love.graphics.rectangle("fill", 170, 120, 300, 240, 12, 12)

            love.graphics.setColor(0.0, 0.82, 1.0, 0.6)
            love.graphics.setLineWidth(2)
            love.graphics.rectangle("line", 170, 120, 300, 240, 12, 12)

            love.graphics.setColor(0.96, 0.97, 1.0)
            love.graphics.setFont(fontTitle)
            love.graphics.printf("MENU DE OPCOES", 170, 135, 300, "center")

            love.graphics.setColor(1, 1, 1, 0.1)
            love.graphics.line(190, 165, 450, 165)

            local opt1_y = 185
            if menuSelected == 1 then
                love.graphics.setColor(0.0, 0.82, 1.0, 0.2)
                love.graphics.rectangle("fill", 190, opt1_y - 6, 260, 36, 6, 6)
                love.graphics.setColor(0.0, 0.82, 1.0)
                love.graphics.rectangle("line", 190, opt1_y - 6, 260, 36, 6, 6)
                love.graphics.setColor(1, 1, 1)
            else love.graphics.setColor(0.6, 0.65, 0.75) end
            love.graphics.setFont(fontItem)
            love.graphics.printf("Mudar Destino: " .. sdLabels[currentSd], 170, opt1_y, 300, "center")

            local opt2_y = 235
            if menuSelected == 2 then
                love.graphics.setColor(1.0, 0.3, 0.3, 0.2)
                love.graphics.rectangle("fill", 190, opt2_y - 6, 260, 36, 6, 6)
                love.graphics.setColor(1.0, 0.3, 0.3)
                love.graphics.rectangle("line", 190, opt2_y - 6, 260, 36, 6, 6)
                love.graphics.setColor(1, 1, 1)
            else love.graphics.setColor(0.6, 0.65, 0.75) end
            love.graphics.printf("Desinstalador de Ports", 170, opt2_y, 300, "center")

            local opt3_y = 285
            if menuSelected == 3 then
                love.graphics.setColor(0.85, 0.65, 0.2, 0.2)
                love.graphics.rectangle("fill", 190, opt3_y - 6, 260, 36, 6, 6)
                love.graphics.setColor(0.85, 0.65, 0.2)
                love.graphics.rectangle("line", 190, opt3_y - 6, 260, 36, 6, 6)
                love.graphics.setColor(1, 1, 1)
            else love.graphics.setColor(0.6, 0.65, 0.75) end
            love.graphics.printf("Sair", 170, opt3_y, 300, "center")

            love.graphics.setColor(0.45, 0.52, 0.62)
            love.graphics.setFont(fontSub)
            love.graphics.printf("B: Confirmar   A: Voltar", 170, 330, 300, "center")
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
            love.graphics.printf("B: Confirmar   A: Voltar", 170, 330, 300, "center")
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
