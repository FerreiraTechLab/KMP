local Catalog = {}

local function nonempty(value)
    return type(value) == "string" and value:match("%S") ~= nil
end

local function safeId(value)
    return type(value) == "string" and value:match("^[a-z0-9][a-z0-9_-]*$") ~= nil
end

local function safePath(value)
    if type(value) ~= "string" or value == "" or value:sub(1, 1) == "/" then return false end
    if value:find("\\", 1, true) or value:find("//", 1, true) or value:find(":", 1, true) then return false end
    if value:find("[%c]") then return false end
    for segment in value:gmatch("[^/]+") do
        if segment == "." or segment == ".." then return false end
    end
    return true
end

local function validateItem(item, ids, portIds, roots)
    if type(item) ~= "table" then return nil, "item não é um objeto" end
    if not safeId(item.id) then return nil, "id inválido" end
    if ids[item.id] then return nil, "id duplicado: " .. item.id end
    for _, field in ipairs({"name", "version", "description", "license"}) do
        if not nonempty(item[field]) then return nil, field .. " ausente" end
    end
    if type(item.sizeBytes) ~= "number" or item.sizeBytes < 1 or
       item.sizeBytes > 9007199254740991 or item.sizeBytes % 1 ~= 0 then
        return nil, "sizeBytes inválido"
    end
    if type(item.infoHash) ~= "string" or #item.infoHash ~= 40 or not item.infoHash:match("^[0-9a-fA-F]+$") then
        return nil, "infoHash inválido"
    end
    local magnetHash = type(item.magnet) == "string" and
        item.magnet:match("^magnet:%?.*[?&]xt=urn:btih:([0-9a-fA-F]+)")
    if not magnetHash then
        magnetHash = type(item.magnet) == "string" and
            item.magnet:match("^magnet:%?xt=urn:btih:([0-9a-fA-F]+)")
    end
    if not magnetHash or magnetHash:lower() ~= item.infoHash:lower() then
        return nil, "magnet não corresponde ao infoHash"
    end
    if not safePath(item.packageFile) or item.packageFile:find("/", 1, true) or
       not item.packageFile:lower():match("%.zip$") then
        return nil, "packageFile inválido"
    end
    if type(item.install) ~= "table" or not safeId(item.install.portId) or
       type(item.install.paths) ~= "table" or #item.install.paths == 0 then
        return nil, "install inválido"
    end
    if portIds[item.install.portId] then return nil, "portId duplicado" end
    for _, path in ipairs(item.install.paths) do
        if not safePath(path) then return nil, "caminho de instalação inválido" end
        local root = path:match("^[^/]+")
        if root == ".kmp" or root == "KMP" then return nil, "caminho reservado" end
        if roots[root] and roots[root] ~= item.id then return nil, "destino compartilhado: " .. root end
        roots[root] = item.id
    end
    ids[item.id] = true
    portIds[item.install.portId] = true
    return item
end

function Catalog.validate(document)
    if type(document) ~= "table" or document.schemaVersion ~= 1 or type(document.items) ~= "table" then
        return nil, "versão ou formato do catálogo inválido"
    end
    local ids = {}
    local portIds = {}
    local roots = {}
    local items = {}
    for index, item in ipairs(document.items) do
        local valid, err = validateItem(item, ids, portIds, roots)
        if not valid then return nil, "item " .. index .. ": " .. err end
        items[#items + 1] = valid
    end
    return items
end

function Catalog.search(items, query)
    local result = {}
    local needle = (query or ""):lower()
    for _, item in ipairs(items) do
        if item.name:lower():find(needle, 1, true) then result[#result + 1] = item end
    end
    return result
end

return Catalog
