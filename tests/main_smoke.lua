package.path = "KMP/game/?.lua;" .. package.path

local graphics = setmetatable({}, {__index = function() return function() end end})
graphics.getDimensions = function() return 640, 480 end
graphics.newFont = function() return {} end
local channels = {}
love = {
    graphics = graphics,
    system = {getOS = function() return "Linux" end},
    filesystem = {
        getInfo = function() return nil end,
        read = function() return nil end,
        write = function() return true end,
        getSaveDirectory = function() return "/tmp" end,
    },
    thread = {getChannel = function(name)
        if not channels[name] then
            channels[name] = {pop = function() return nil end, push = function() end}
        end
        return channels[name]
    end},
    timer = {getTime = os.clock},
    event = {quit = function() end},
}

dofile("KMP/game/main.lua")
love.load()
love.update(2.1)
love.draw()
love.keypressed("escape")
love.draw()
love.keypressed("down")
love.keypressed("return")
love.draw()
love.gamepadpressed(nil, "b")
love.gamepadpressed(nil, "a")
love.draw()
print("main UI smoke: ok")
