package.path = "KMP/game/?.lua;" .. package.path

local graphics = setmetatable({}, {__index = function() return function() end end})
graphics.getDimensions = function() return 640, 480 end
graphics.newFont = function() return {} end
local clock, slept = 100, {}
love = {
    graphics = graphics,
    system = {getOS = function() return "Linux" end},
    filesystem = {getInfo = function() return nil end, read = function() return nil end,
        write = function() return true end, getSaveDirectory = function() return "/tmp" end},
    thread = {getChannel = function() return {pop = function() return nil end, push = function() end} end},
    timer = {getTime = function() return clock end,
        sleep = function(seconds) slept[#slept + 1] = seconds; clock = clock + seconds end},
    event = {quit = function() end},
}

dofile("KMP/game/main.lua")
love.load()
local api = assert(KMP_TEST_API)
api.reset()

local function frame()
    slept = {}
    love.update(0.01)
    return slept[1] or 0
end
-- Dois quadros seguidos: o segundo dorme o que falta para completar o intervalo.
clock = clock + 10
frame()
assert(math.abs(frame() - 1 / 8) < 1e-6, "parado, o Client desenha 8 quadros por segundo")
love.gamepadpressed(nil, "dpright")
love.gamepadreleased(nil, "dpright")
frame()
assert(math.abs(frame() - 1 / 30) < 1e-6, "logo depois de um botão, volta a 30 quadros por segundo")
clock = clock + 0.5
assert(frame() == 0, "um quadro que já demorou mais que o limite não espera")
clock = clock + 4
frame()
assert(math.abs(frame() - 1 / 8) < 1e-6, "três segundos sem uso, volta ao ritmo lento")
print("main frame throttle: ok")
