package.path = "KMP/game/?.lua;" .. package.path

assert(os.getenv("KMP_TEST_MODE") == "1", "execute com KMP_TEST_MODE=1")

local graphics = setmetatable({}, {__index = function() return function() end end})
graphics.getDimensions = function() return 640, 480 end
graphics.newFont = function() return {} end
local channels = {}
local function channel(name)
    if not channels[name] then
        local queue = {}
        channels[name] = {
            push = function(_, value) table.insert(queue, value) end,
            pop = function()
                if #queue == 0 then return nil end
                return table.remove(queue, 1)
            end,
        }
    end
    return channels[name]
end

love = {
    graphics = graphics,
    system = {getOS = function() return "Linux" end},
    filesystem = {getInfo = function() return nil end, read = function() return nil end,
        write = function() return true end, getSaveDirectory = function() return "/tmp" end},
    thread = {getChannel = channel},
    timer = {getTime = os.clock, sleep = function() end},
    event = {quit = function() error("quit real no modo de teste") end},
}

dofile("KMP/game/main.lua")
love.load()
local api = assert(KMP_TEST_API)

local function game(values)
    local item = {
        id = "example", name = "Example", version = "1.0", description = "Example",
        sizeBytes = 1024, size = "1 KB", license = "MIT",
        infoHash = string.rep("a", 40), packageFile = "example.zip",
        install = {portId = "example", paths = {"example.sh", "example/"}},
        installed = false, updateAvailable = false,
    }
    for key, value in pairs(values or {}) do item[key] = value end
    return item
end

local function event(action)
    for _, value in ipairs(api.events()) do
        if value.action == action then return value end
    end
    return nil
end

local function openMenuItem(index)
    love.gamepadpressed(nil, "start")
    for _ = 2, index do love.gamepadpressed(nil, "dpdown") end
    love.gamepadpressed(nil, "a")
end

-- Instalação e cancelamento usam o fluxo real dos botões A/B.
api.reset()
api.setCatalog({game()})
love.gamepadpressed(nil, "a")
assert(api.snapshot().showDetails)
love.gamepadpressed(nil, "a")
assert(event("install") and api.snapshot().downloadActive)
love.gamepadpressed(nil, "b")
assert(channel("torrent_cancel"):pop() == true)
assert(api.snapshot().downloadStatus == "Interrompendo download...")

-- O teste P2P é acionado por X em um port ainda não instalado.
api.reset()
api.setCatalog({game()})
love.gamepadpressed(nil, "a")
love.gamepadpressed(nil, "x")
assert(event("p2p_test"))

-- Atualização instalada segue uma ação diferente da instalação inicial.
api.reset()
api.setCatalog({game({installed = true, installedVersion = "1.0",
    version = "2.0", updateAvailable = true})})
love.gamepadpressed(nil, "a")
love.gamepadpressed(nil, "a")
assert(event("update"))

-- Controles de seed individual e global permanecem acessíveis nos detalhes.
api.reset()
api.setCatalog({game({installed = true})})
love.gamepadpressed(nil, "a")
love.gamepadpressed(nil, "a")
love.gamepadpressed(nil, "a")
love.gamepadpressed(nil, "x")
love.gamepadpressed(nil, "y")
assert(event("pause_one") and event("resume_one"))
assert(event("pause_all") and event("resume_all"))
love.gamepadpressed(nil, "b")
assert(not api.snapshot().showDetails)

-- Pesquisa sem teclado: A insere, Y apaga e B retorna.
api.reset()
api.setCatalog({game()})
openMenuItem(2)
assert(api.snapshot().showSearch)
love.gamepadpressed(nil, "a")
assert(api.snapshot().searchQuery == "A")
love.gamepadpressed(nil, "y")
assert(api.snapshot().searchQuery == "")
love.gamepadpressed(nil, "b")
assert(not api.snapshot().showSearch)

-- Desinstalação exige confirmação e B cancela sem remover.
api.reset()
api.setInstalledPorts({{name = "Example", filename = "example.sh", path = "/roms/ports",
    label = "SD1", portId = "example", itemId = "example", infoHash = string.rep("a", 40),
    managed = true}})
openMenuItem(3)
assert(api.snapshot().appState == "uninstaller")
love.gamepadpressed(nil, "a")
assert(api.snapshot().showUninstallPopup)
love.gamepadpressed(nil, "b")
assert(not api.snapshot().showUninstallPopup and not event("uninstall"))
love.gamepadpressed(nil, "a")
love.gamepadpressed(nil, "a")
assert(event("uninstall") and api.snapshot().installedPorts == 0)
love.gamepadpressed(nil, "b")
assert(api.snapshot().appState == "main")

-- Confiança do catálogo e diagnóstico retornam ao menu com B.
api.reset()
openMenuItem(4)
assert(api.snapshot().appState == "catalog_trust")
love.gamepadpressed(nil, "b")
assert(api.snapshot().showMenu)
api.reset()
openMenuItem(5)
assert(event("diagnostic") and api.snapshot().diagnostic.ok)
love.gamepadpressed(nil, "b")
assert(api.snapshot().showMenu)

-- Atualizar, sair, reiniciar e desligar geram as ações corretas sem executá-las.
api.reset()
love.gamepadpressed(nil, "y")
assert(event("reload"))
api.reset()
openMenuItem(6)
love.gamepadpressed(nil, "a")
assert(event("exit"))
api.reset()
openMenuItem(6)
love.gamepadpressed(nil, "dpdown")
love.gamepadpressed(nil, "a")
assert(event("reboot"))
api.reset()
openMenuItem(6)
love.gamepadpressed(nil, "dpdown")
love.gamepadpressed(nil, "dpdown")
love.gamepadpressed(nil, "a")
assert(event("shutdown"))

print("main interface flows: ok")
