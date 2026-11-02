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

local function contains(values, needle)
    if type(values) ~= "table" then return false end
    for _, value in ipairs(values) do if value == needle then return true end end
    return false
end

local function stringSet(value)
    local result = {}
    for part in tostring(value or ""):gmatch("[^,]+") do result[part] = true end
    return result
end

function Catalog.deviceProfile(environment)
    environment = environment or os.getenv
    return {
        architecture = environment("KMP_DEVICE_ARCH") or "",
        firmware = environment("KMP_FIRMWARE") or "",
        ramMB = tonumber(environment("KMP_RAM_MB")),
        analogSticks = tonumber(environment("KMP_ANALOG_STICKS")),
        renderers = stringSet(environment("KMP_RENDERERS")),
        runtimes = stringSet(environment("KMP_RUNTIMES")),
        capabilities = { ["org.ferreiratechlab.catalog-v3"] = true },
    }
end

local function compatible(variant, profile)
    local compatibility, requirements = variant.compatibility, variant.requirements
    if type(compatibility) ~= "table" or type(requirements) ~= "table" then return false end
    if not contains(compatibility.architectures, profile.architecture) then return false end
    local firmwares = compatibility.firmwares or {}
    if contains(firmwares.exclude, profile.firmware) then return false end
    if firmwares.include and not contains(firmwares.include, profile.firmware) then return false end
    for _, capability in ipairs(variant.requiredCapabilities or {}) do
        if not profile.capabilities[capability] then return false end
    end
    if requirements.minimumRamMB and
       (not profile.ramMB or profile.ramMB < requirements.minimumRamMB) then return false end
    if requirements.analogSticks and requirements.analogSticks > 0 and
       (not profile.analogSticks or profile.analogSticks < requirements.analogSticks) then return false end
    if type(requirements.renderers) ~= "table" or type(requirements.runtimes) ~= "table" then return false end
    if #requirements.renderers > 0 then
        local found = false
        for _, renderer in ipairs(requirements.renderers) do
            if profile.renderers[renderer] then found = true; break end
        end
        if not found then return false end
    end
    for _, runtime in ipairs(requirements.runtimes) do
        if not profile.runtimes[runtime] then return false end
    end
    return true
end

local function selectVariant(item, profile)
    local release = item.release
    if type(release) ~= "table" or type(release.variants) ~= "table" or #release.variants == 0 then
        return nil, "release sem variantes"
    end
    local selected
    for _, variant in ipairs(release.variants) do
        if not safeId(variant.id) or type(variant.priority) ~= "number" or
           variant.priority % 1 ~= 0 or variant.priority < 0 then
            return nil, "variante inválida"
        end
        if compatible(variant, profile) then
            if not selected or variant.priority > selected.priority then
                selected = variant
            elseif variant.priority == selected.priority then
                return nil, "variantes compatíveis empatadas"
            end
        end
    end
    return selected
end

local function normalizeV3(item, variant)
    local release, download = item.release, variant.download
    if type(download) ~= "table" or type(variant.install) ~= "table" then return nil end
    return {
        id = item.id, name = item.name, description = item.description,
        license = item.license, homepage = item.homepage, source = item.source,
        porter = item.porter, redistribution = item.redistribution,
        version = release.version, revision = release.revision,
        channel = release.channel, review = release.review,
        variantId = variant.id, compatibility = variant.compatibility,
        requirements = variant.requirements,
        sizeBytes = download.sizeBytes, infoHash = download.infoHash,
        magnet = download.magnet, torrent = download.torrent,
        packageFile = download.packageFile, packageSha256 = download.sha256,
        install = variant.install,
    }
end

local function validateItem(item, ids, portIds, roots, requirePackageHash)
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
    if item.torrent ~= nil and
       (type(item.torrent) ~= "string" or #item.torrent == 0 or
        #item.torrent > 90000 or not item.torrent:match("^[A-Za-z0-9+/]+=*$")) then
        return nil, "metainfo torrent inválido"
    end
    if not safePath(item.packageFile) or item.packageFile:find("/", 1, true) or
       not item.packageFile:lower():match("%.zip$") then
        return nil, "packageFile inválido"
    end
    if (requirePackageHash or item.packageSha256 ~= nil) and
       (type(item.packageSha256) ~= "string" or #item.packageSha256 ~= 64 or
        not item.packageSha256:match("^[0-9a-f]+$")) then
        return nil, "packageSha256 inválido ou ausente"
    end
    if type(item.install) ~= "table" or not safeId(item.install.portId) or
       type(item.install.paths) ~= "table" or #item.install.paths == 0 then
        return nil, "install inválido"
    end
    local clientPackage = item.id == "kmp-client" and
        item.install.portId == "kmp-client" and #item.install.paths == 2 and
        item.install.paths[1] == "KMP.sh" and item.install.paths[2] == "KMP/"
    if item.id == "kmp-client" and not clientPackage then
        return nil, "destinos da atualização do Client inválidos"
    end
    if portIds[item.install.portId] then return nil, "portId duplicado" end
    for _, path in ipairs(item.install.paths) do
        if not safePath(path) then return nil, "caminho de instalação inválido" end
        local root = path:match("^[^/]+")
        if root == ".kmp" or (root == "KMP" and not clientPackage) then
            return nil, "caminho reservado"
        end
        if roots[root] and roots[root] ~= item.id then return nil, "destino compartilhado: " .. root end
        roots[root] = item.id
    end
    ids[item.id] = true
    portIds[item.install.portId] = true
    return item
end

-- O catálogo assinado já é validado em Python; aqui uma entrada inválida só é
-- ignorada, para que os nós públicos nunca impeçam o uso do catálogo.
function Catalog.seedNodes(document)
    local extensions = type(document) == "table" and document.schemaVersion == 3 and
        type(document.extensions) == "table" and document.extensions or {}
    local nodes, seen = {}, {}
    local listed = extensions["kmp.seed-nodes"]
    for _, node in ipairs(type(listed) == "table" and listed or {}) do
        local a, b, c, d, port = tostring(node):match("^(%d+)%.(%d+)%.(%d+)%.(%d+):(%d+)$")
        local valid = type(node) == "string" and a and tonumber(port) >= 1 and tonumber(port) <= 65535
        for _, octet in ipairs(valid and {a, b, c, d} or {}) do
            if tonumber(octet) > 255 then valid = false end
        end
        if valid and not seen[node] and #nodes < 16 then
            nodes[#nodes + 1] = node; seen[node] = true
        end
    end
    return nodes
end

function Catalog.validate(document, profile)
    if type(document) ~= "table" or type(document.items) ~= "table" then
        return nil, "versão ou formato do catálogo inválido"
    end
    if document.schemaVersion == 2 or document.schemaVersion == 3 then
        if type(document.sequence) ~= "number" or document.sequence < 1 or
           document.sequence % 1 ~= 0 or type(document.generatedAt) ~= "string" or
           not document.generatedAt:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$") then
            return nil, "metadados do catálogo inválidos"
        end
    elseif document.schemaVersion ~= 1 then
        return nil, "versão ou formato do catálogo inválido"
    end
    local ids = {}
    local portIds = {}
    local roots = {}
    local items = {}
    local incompatible = 0
    profile = profile or Catalog.deviceProfile()
    for index, source in ipairs(document.items) do
        local item = source
        if document.schemaVersion == 3 then
            if type(source) ~= "table" or not safeId(source.id) or
               not nonempty(source.name) or not nonempty(source.description) or
               not nonempty(source.license) or type(source.release) ~= "table" or
               type(source.release.revision) ~= "number" or source.release.revision < 1 or
               source.release.revision % 1 ~= 0 or not nonempty(source.release.version) or
               source.release.channel ~= "stable" then
                return nil, "item " .. index .. ": release v3 inválida"
            end
            local variant, variantError = selectVariant(source, profile)
            if variantError then return nil, "item " .. index .. ": " .. variantError end
            if not variant then incompatible = incompatible + 1; item = nil
            else item = normalizeV3(source, variant) end
        end
        local valid, err
        if item then
            valid, err = validateItem(item, ids, portIds, roots,
                document.schemaVersion == 3 or
                (document.schemaVersion == 2 and document.sequence >= 3))
        end
        if item and not valid then return nil, "item " .. index .. ": " .. err end
        if valid then items[#items + 1] = valid end
    end
    return items, nil, {schemaVersion = document.schemaVersion,
        sequence = document.sequence, generatedAt = document.generatedAt,
        incompatible = incompatible, revocations = document.revocations or {},
        seedNodes = Catalog.seedNodes(document)}
end

function Catalog.search(items, query)
    local result = {}
    local needle = (query or ""):lower()
    for _, item in ipairs(items) do
        if item.name:lower():find(needle, 1, true) then result[#result + 1] = item end
    end
    return result
end

function Catalog.isUpdate(installed, available, installedRevision, availableRevision)
    if type(installedRevision) == "number" and type(availableRevision) == "number" then
        return availableRevision > installedRevision
    end
    installed, available = tostring(installed or ""), tostring(available or "")
    if installed == "" or available == "" or installed == available then return false end
    local function numericParts(value)
        value = value:gsub("^v", "")
        if not value:match("^%d[%d%.]*%d$") and not value:match("^%d$") then return nil end
        local parts = {}
        for part in value:gmatch("%d+") do parts[#parts + 1] = tonumber(part) end
        return parts
    end
    local old, new = numericParts(installed), numericParts(available)
    if old and new then
        for index = 1, math.max(#old, #new) do
            local left, right = old[index] or 0, new[index] or 0
            if right > left then return true end
            if right < left then return false end
        end
        return false
    end
    return true
end

return Catalog
