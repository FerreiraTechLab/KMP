package.path = "KMP/game/?.lua;" .. package.path

assert(os.getenv("KMP_TEST_MODE") == "1", "execute com KMP_TEST_MODE=1")

local graphics = setmetatable({}, {__index = function() return function() end end})
graphics.getDimensions = function() return 640, 480 end
graphics.newFont = function() return {} end
local channels = {}
local quitCalled = false
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
    event = {quit = function() quitCalled = true end},
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
openMenuItem(6)
assert(event("diagnostic") and api.snapshot().diagnostic.ok)
love.gamepadpressed(nil, "b")
assert(api.snapshot().showMenu)

-- O Client baixa a própria atualização e pede confirmação antes de sair.
api.reset()
local client = game({id = "kmp-client", name = "KMP Client", version = "9.0",
    isClientUpdate = true, install = {portId = "kmp-client", paths = {"KMP.sh", "KMP/"}}})
api.setClientUpdate(client)
openMenuItem(5)
assert(event("client_update") and api.snapshot().downloadActive)
channel("torrent_event"):push({kind = "client_ready"})
love.update(0.1)
assert(api.snapshot().showClientUpdatePopup)
love.gamepadpressed(nil, "b")
assert(not api.snapshot().showClientUpdatePopup and not quitCalled)

api.reset()
api.setClientUpdate(client)
openMenuItem(5)
channel("torrent_event"):push({kind = "client_ready"})
love.update(0.1)
love.gamepadpressed(nil, "a")
assert(event("apply_client_update") and quitCalled)

-- O nó comunitário pode ser ativado pela interface sem editar arquivos.
api.reset()
openMenuItem(7)
assert(event("community_node") and not event("community_node").enabled)

-- Atualizar, sair, reiniciar e desligar geram as ações corretas sem executá-las.
api.reset()
love.gamepadpressed(nil, "y")
assert(event("reload"))
api.reset()
openMenuItem(8)
love.gamepadpressed(nil, "a")
assert(event("exit"))
api.reset()
openMenuItem(8)
love.gamepadpressed(nil, "dpdown")
love.gamepadpressed(nil, "a")
assert(event("reboot"))
api.reset()
openMenuItem(8)
love.gamepadpressed(nil, "dpdown")
love.gamepadpressed(nil, "dpdown")
love.gamepadpressed(nil, "a")
assert(event("shutdown"))

-- A loja navega em grade de três colunas e para nas bordas.
api.reset()
local shelf = {}
for index = 1, 8 do
    shelf[index] = game({id = "port" .. index, name = "Port " .. index,
        install = {portId = "port" .. index, paths = {"port" .. index .. ".sh"}},
        installed = index <= 2, updateAvailable = index == 2})
end
api.setCatalog(shelf)
love.gamepadpressed(nil, "dpdown")
assert(api.snapshot().selectedIdx == 4, "baixo pula uma linha")
love.gamepadpressed(nil, "dpright")
assert(api.snapshot().selectedIdx == 5)
love.gamepadpressed(nil, "dpdown")
assert(api.snapshot().selectedIdx == 8, "a última linha incompleta recebe a seleção")
love.gamepadpressed(nil, "dpdown")
assert(api.snapshot().selectedIdx == 8, "baixo para na última linha")
love.gamepadpressed(nil, "dpup")
love.gamepadpressed(nil, "dpup")
love.gamepadpressed(nil, "dpup")
assert(api.snapshot().selectedIdx == 2, "cima para na primeira linha")
love.gamepadreleased(nil, "dpup")

-- Segurar o direcional repete o movimento; soltar interrompe.
api.reset()
api.setCatalog(shelf)
love.gamepadpressed(nil, "dpright")
love.update(0.2)
assert(api.snapshot().selectedIdx == 2, "sem repetição antes do atraso")
love.update(0.2)
assert(api.snapshot().selectedIdx >= 3, "segurar repete o movimento")
love.gamepadreleased(nil, "dpright")
local stopped = api.snapshot().selectedIdx
love.update(0.5)
assert(api.snapshot().selectedIdx == stopped, "soltar interrompe a repetição")

-- O analógico só move ao cruzar o limite, não a cada evento do eixo.
api.reset()
api.setCatalog(shelf)
love.gamepadaxis(nil, "leftx", 0.7)
love.gamepadaxis(nil, "leftx", 0.8)
love.gamepadaxis(nil, "leftx", 0.9)
assert(api.snapshot().selectedIdx == 2, "eixo segurado move uma vez")
love.gamepadaxis(nil, "leftx", 0.1)
love.gamepadaxis(nil, "leftx", 0.9)
assert(api.snapshot().selectedIdx == 3)
love.gamepadaxis(nil, "leftx", 0)
love.gamepadaxis(nil, "lefty", 0.9)
assert(api.snapshot().selectedIdx == 6)
love.gamepadaxis(nil, "lefty", 0)

-- L1/R1 alternam as abas Início, Instalados e Atualizações.
api.reset()
api.setCatalog(shelf)
love.gamepadpressed(nil, "rightshoulder")
assert(api.snapshot().storeTab == 2 and api.snapshot().visiblePorts == 2)
love.gamepadpressed(nil, "rightshoulder")
assert(api.snapshot().storeTab == 3 and api.snapshot().visiblePorts == 1)
love.gamepadpressed(nil, "a")
assert(api.snapshot().showDetails, "A abre o port da aba de atualizações")
love.draw()
love.gamepadpressed(nil, "dpdown")
love.gamepadpressed(nil, "b")
love.gamepadpressed(nil, "rightshoulder")
assert(api.snapshot().storeTab == 1 and api.snapshot().visiblePorts == 8)
love.gamepadpressed(nil, "leftshoulder")
assert(api.snapshot().storeTab == 3)
love.draw()

print("main interface flows: ok")
