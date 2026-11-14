local Json = require("json")
local Rpc = {}

local function shellQuote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

function Rpc.new(endpoint, secret, runner)
    assert(type(endpoint) == "string" and endpoint:match("^http://127%.0%.0%.1:%d+/jsonrpc$"), "RPC local inválido")
    assert(type(secret) == "string" and secret:match("^[0-9a-f]+$"), "segredo RPC inválido")
    runner = runner or function(command)
        local handle = io.popen(command, "r")
        if not handle then return nil, "curl indisponível" end
        local body = handle:read("*a")
        local ok = handle:close()
        if not ok then return nil, "sem conexão com aria2c" end
        return body
    end
    return function(method, params)
        if type(method) ~= "string" or
           not (method:match("^aria2%.[%a]+$") or method:match("^kmp%.[%a]+$")) then
            return nil, "método RPC inválido"
        end
        local arguments = {"token:" .. secret}
        for _, parameter in ipairs(params or {}) do arguments[#arguments + 1] = parameter end
        local request = Json.encode({jsonrpc = "2.0", id = "kmp", method = method, params = arguments})
        -- Num console com o cartão ocupado, uma resposta legítima chegou a levar 2,7 s; 15 s
        -- separam o daemon ocupado do daemon parado.
        local command = "curl --noproxy '*' --connect-timeout 2 --max-time 15 --silent --show-error " ..
            "--header 'Content-Type: application/json' --data-binary " .. shellQuote(request) ..
            " " .. shellQuote(endpoint) .. " 2>/dev/null"
        local body, err = runner(command)
        if not body then return nil, err end
        -- No LuaJIT, close() do popen não devolve o código do curl: uma falha de conexão
        -- ou o tempo esgotado chegam aqui como corpo vazio.
        if not body:match("%S") then return nil, "kmp-torrentd não respondeu em 15 s (parado ou ocupado)" end
        local decoded, decodeError = Json.decode(body)
        if not decoded then return nil, "resposta RPC inválida: " .. tostring(decodeError) end
        if decoded.error then return nil, tostring(decoded.error.message or "erro no aria2c") end
        if decoded.id ~= "kmp" then return nil, "resposta RPC inesperada" end
        return decoded.result
    end
end

return Rpc
