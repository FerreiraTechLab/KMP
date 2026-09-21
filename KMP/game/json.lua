local Json = {}

local function utf8char(code)
    if code < 0x80 then return string.char(code) end
    if code < 0x800 then return string.char(0xC0 + math.floor(code / 64), 0x80 + code % 64) end
    if code < 0x10000 then
        return string.char(0xE0 + math.floor(code / 4096), 0x80 + math.floor(code / 64) % 64, 0x80 + code % 64)
    end
    return string.char(0xF0 + math.floor(code / 262144), 0x80 + math.floor(code / 4096) % 64,
        0x80 + math.floor(code / 64) % 64, 0x80 + code % 64)
end

function Json.decode(source)
    if type(source) ~= "string" then return nil, "JSON não é texto" end
    local pos = 1
    local function skip()
        while source:sub(pos, pos):match("%s") and pos <= #source do pos = pos + 1 end
    end
    local value
    local function quoted()
        if source:sub(pos, pos) ~= '"' then error("texto esperado") end
        pos = pos + 1
        local out = {}
        while pos <= #source do
            local c = source:sub(pos, pos)
            pos = pos + 1
            if c == '"' then return table.concat(out) end
            if c == "\\" then
                local e = source:sub(pos, pos)
                pos = pos + 1
                local escapes = {['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t'}
                if e == "u" then
                    local hex = source:sub(pos, pos + 3)
                    if not hex:match("^%x%x%x%x$") then error("unicode inválido") end
                    local code = tonumber(hex, 16)
                    pos = pos + 4
                    if code >= 0xD800 and code <= 0xDBFF then
                        if source:sub(pos, pos + 1) ~= "\\u" then error("par surrogate incompleto") end
                        local low = tonumber(source:sub(pos + 2, pos + 5), 16)
                        if not low or low < 0xDC00 or low > 0xDFFF then error("par surrogate inválido") end
                        code = 0x10000 + (code - 0xD800) * 1024 + (low - 0xDC00)
                        pos = pos + 6
                    elseif code >= 0xDC00 and code <= 0xDFFF then
                        error("surrogate isolado")
                    end
                    out[#out + 1] = utf8char(code)
                elseif escapes[e] then out[#out + 1] = escapes[e]
                else error("escape inválido") end
            else
                if c:byte() < 32 then error("controle em texto") end
                out[#out + 1] = c
            end
        end
        error("texto sem fechamento")
    end
    local function array()
        pos = pos + 1
        local out = {}
        skip()
        if source:sub(pos, pos) == "]" then pos = pos + 1; return out end
        while true do
            out[#out + 1] = value()
            skip()
            local c = source:sub(pos, pos)
            pos = pos + 1
            if c == "]" then return out end
            if c ~= "," then error("separador de lista inválido") end
        end
    end
    local function object()
        pos = pos + 1
        local out = {}
        skip()
        if source:sub(pos, pos) == "}" then pos = pos + 1; return out end
        while true do
            skip()
            local key = quoted()
            skip()
            if source:sub(pos, pos) ~= ":" then error("dois pontos esperados") end
            pos = pos + 1
            out[key] = value()
            skip()
            local c = source:sub(pos, pos)
            pos = pos + 1
            if c == "}" then return out end
            if c ~= "," then error("separador de objeto inválido") end
        end
    end
    value = function()
        skip()
        local c = source:sub(pos, pos)
        if c == '"' then return quoted() end
        if c == "[" then return array() end
        if c == "{" then return object() end
        for _, literal in ipairs({"true", "false", "null"}) do
            if source:sub(pos, pos + #literal - 1) == literal then
                pos = pos + #literal
                if literal == "true" then return true end
                if literal == "false" then return false end
                return Json.null
            end
        end
        local number = source:sub(pos):match("^-?%d+%.?%d*[eE]?[+-]?%d*")
        if number and number ~= "" and tonumber(number) then
            pos = pos + #number
            return tonumber(number)
        end
        error("valor JSON inválido")
    end
    local ok, result = pcall(value)
    if not ok then return nil, result end
    skip()
    if pos <= #source then return nil, "dados após JSON" end
    return result
end

Json.null = {}

local function encode(value)
    local kind = type(value)
    if value == Json.null then return "null" end
    if kind == "nil" then return "null" end
    if kind == "boolean" or kind == "number" then return tostring(value) end
    if kind == "string" then
        return '"' .. value:gsub('[%z\1-\31\\"]', function(c)
            local escaped = {['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t'}
            return escaped[c] or string.format("\\u%04x", c:byte())
        end) .. '"'
    end
    if kind == "table" then
        local out = {}
        if #value > 0 then
            for i = 1, #value do out[#out + 1] = encode(value[i]) end
            return "[" .. table.concat(out, ",") .. "]"
        end
        for key, item in pairs(value) do
            if type(key) ~= "string" then error("chave JSON inválida") end
            out[#out + 1] = encode(key) .. ":" .. encode(item)
        end
        return "{" .. table.concat(out, ",") .. "}"
    end
    error("tipo JSON inválido")
end

Json.encode = encode
return Json
