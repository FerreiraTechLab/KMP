local VERSION = "2.0"
local launches = 0
local createdBy = VERSION
local status = ""

local function savePath()
    return (os.getenv("KMP_UPDATE_TEST_DIR") or ".") .. "/conf/save.txt"
end

function love.load()
    love.graphics.setBackgroundColor(0.035, 0.055, 0.09)
    local path = savePath()
    local handle = io.open(path, "r")
    local previous = handle and handle:read("*a") or ""
    if handle then handle:close() end
    createdBy = previous:match("createdBy=([^\n]+)") or VERSION
    launches = (tonumber(previous:match("launches=(%d+)")) or 0) + 1
    handle = io.open(path, "w")
    if handle then
        handle:write("createdBy=", createdBy, "\nlastRun=", VERSION,
            "\nlaunches=", launches, "\n")
        handle:close()
        status = "SAVE GRAVADO COM SUCESSO"
    else
        status = "ERRO AO GRAVAR O SAVE"
    end
end

function love.draw()
    love.graphics.setColor(0.35, 1.0, 0.45)
    love.graphics.rectangle("fill", 0, 0, 640, 12)
    love.graphics.setColor(0.94, 0.97, 1.0)
    love.graphics.printf("KMP UPDATE TEST", 0, 75, 640, "center")
    love.graphics.setColor(0.35, 1.0, 0.45)
    love.graphics.printf("VERSAO " .. VERSION, 0, 125, 640, "center")
    love.graphics.setColor(0.75, 0.82, 0.9)
    love.graphics.printf("Save criado pela versao: " .. createdBy, 0, 195, 640, "center")
    love.graphics.printf("Execucoes registradas: " .. launches, 0, 230, 640, "center")
    love.graphics.setColor(status:match("SUCESSO") and 0.2 or 1.0,
        status:match("SUCESSO") and 0.85 or 0.3, 0.4)
    love.graphics.printf(status, 0, 285, 640, "center")
    love.graphics.setColor(0.55, 0.65, 0.75)
    love.graphics.printf("A/B: voltar ao menu", 0, 390, 640, "center")
end

function love.keypressed(key)
    if key == "return" or key == "escape" or key == "space" then love.event.quit() end
end

function love.gamepadpressed(_, button)
    if button == "a" or button == "b" or button == "start" or button == "back" then
        love.event.quit()
    end
end
