package.path = "KMP/game/?.lua;" .. package.path
local graphics = setmetatable({}, {__index = function() return function() end end})
graphics.getDimensions = function() return 640, 480 end
graphics.newFont = function() return {} end
local channels, quitCalled = {}, false
local originalExit = os.exit
os.exit = function(code)
    assert(code == 0)
    quitCalled = true
end
love = {
    graphics = graphics,
    system = {getOS = function() return "Linux" end},
    filesystem = {getInfo = function() return nil end, read = function() return nil end,
        write = function() return true end, getSaveDirectory = function() return "/tmp" end},
    thread = {getChannel = function(name)
        if not channels[name] then
            channels[name] = {pop = function() return nil end, push = function() end}
        end
        return channels[name]
    end},
    timer = {getTime = os.clock},
    event = {quit = function() quitCalled = true end},
}
dofile("KMP/game/main.lua")
love.load()
love.update(2.1)
love.gamepadpressed(nil, "start")
for _ = 1, 4 do love.gamepadpressed(nil, "dpdown") end
love.gamepadpressed(nil, "a")
assert(not quitCalled, "Exportar diagnostico não deve sair do aplicativo")
love.gamepadpressed(nil, "b")
love.gamepadpressed(nil, "dpdown")
love.gamepadpressed(nil, "a")
assert(not quitCalled, "Sair deve primeiro abrir o menu de energia")
love.gamepadpressed(nil, "a")
assert(quitCalled, "A deve confirmar Sair do Aplicativo")
os.exit = originalExit
print("main controls tests: ok")
