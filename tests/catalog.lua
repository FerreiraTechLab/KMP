package.path = "KMP/game/?.lua;" .. package.path
local Catalog = require("catalog")

local function item()
    return {
        id = "example-homebrew", name = "Example Homebrew", version = "1.0",
        description = "Exemplo", sizeBytes = 1024, license = "MIT",
        infoHash = "0123456789abcdef0123456789abcdef01234567",
        magnet = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567",
        packageFile = "example.zip",
        install = {portId = "example-homebrew", paths = {"example-homebrew.sh", "example-homebrew/"}}
    }
end

local document = {schemaVersion = 1, items = {item()}}
local valid, err = Catalog.validate(document)
assert(valid and not err)
assert(#Catalog.search(valid, "HOME") == 1)
assert(#Catalog.search(valid, "missing") == 0)
assert(Catalog.isUpdate("1.1.1", "1.2.0"))
assert(not Catalog.isUpdate("1.2.0", "1.1.1"))
assert(not Catalog.isUpdate("1.1", "1.1.0"))
assert(Catalog.isUpdate("custom-a", "custom-b"))
assert(Catalog.isUpdate("release-x", "release-y", 2, 3))
assert(not Catalog.isUpdate("release-x", "release-y", 3, 2))

document.items[1].install.paths = {"../escape"}
assert(Catalog.validate(document) == nil)
document.items[1].install.paths = {"port/../escape"}
assert(Catalog.validate(document) == nil)
document.items[1].install.paths = {"example-homebrew/"}

document.items[1].magnet = "magnet:?xt=urn:btih:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
assert(Catalog.validate(document) == nil)
document.items[1].magnet = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567"

document.items[2] = item()
assert(Catalog.validate(document) == nil)
document.items[2] = nil

document.schemaVersion = 2
document.sequence = 1
document.generatedAt = "2026-09-26T23:00:00Z"
local v2, v2err, metadata = Catalog.validate(document)
assert(v2 and not v2err and metadata.schemaVersion == 2 and metadata.sequence == 1)
document.sequence = 0
assert(Catalog.validate(document) == nil)
document.sequence = 1
document.generatedAt = "data inválida"
assert(Catalog.validate(document) == nil)
document.generatedAt = "2026-09-26T23:00:00Z"
document.sequence = 3
assert(Catalog.validate(document) == nil)
document.items[1].packageSha256 = string.rep("a", 64)
assert(Catalog.validate(document) ~= nil)
document.schemaVersion = 3
assert(Catalog.validate(document) == nil)

local Json = require("json")
local handle = assert(io.open("contract-examples/catalog-v3.json", "r"))
local v3document = assert(Json.decode(handle:read("*a")))
handle:close()
local profile = {
    architecture = "aarch64", firmware = "darkos", ramMB = 1024,
    analogSticks = 2, renderers = {gles2 = true}, runtimes = {love_11_5 = true},
    capabilities = {["org.ferreiratechlab.catalog-v3"] = true},
}
local v3items, v3error, v3metadata = Catalog.validate(v3document, profile)
assert(v3items and not v3error and #v3items == 1)
assert(v3items[1].variantId == "aarch64-portmaster")
assert(v3items[1].revision == 1 and
    v3items[1].packageSha256 == "8c0a31939409f76cf40a06f8542e9843e833e9efaf26f607821025208d13c91a")
assert(v3metadata.schemaVersion == 3 and v3metadata.incompatible == 0)

local client = item()
client.id, client.name, client.version = "kmp-client", "KMP Client", "0.2.32"
client.packageFile = "KMP-v0.2.32.zip"
client.install = {portId = "kmp-client", paths = {"KMP.sh", "KMP/"}}
local clientItems = assert(Catalog.validate({schemaVersion = 1, items = {client}}))
assert(clientItems[1].id == "kmp-client")
client.install.paths = {"KMP/"}
assert(Catalog.validate({schemaVersion = 1, items = {client}}) == nil)

profile.architecture = "armhf"
local incompatible, _, incompatibleMetadata = Catalog.validate(v3document, profile)
assert(incompatible and #incompatible == 0 and incompatibleMetadata.incompatible == 1)

-- Nós públicos inválidos são ignorados sem invalidar o catálogo.
v3document.extensions = {["kmp.seed-nodes"] = {"163.176.18.211:6881", "163.176.18.211:6881",
    "300.1.1.1:6881", "1.2.3.4:0", "1.2.3.4", 7, "8.8.8.8:65535"}}
local _, _, seededMetadata = Catalog.validate(v3document, profile)
assert(#seededMetadata.seedNodes == 2)
assert(seededMetadata.seedNodes[1] == "163.176.18.211:6881" and seededMetadata.seedNodes[2] == "8.8.8.8:65535")
v3document.extensions = {["kmp.seed-nodes"] = "163.176.18.211:6881"}
assert(#select(3, Catalog.validate(v3document, profile)).seedNodes == 0)
assert(#Catalog.seedNodes({schemaVersion = 2, extensions = {["kmp.seed-nodes"] = {"1.2.3.4:6881"}}}) == 0)
-- Firmware fora da lista do autor: o port aparece marcado como não confirmado; "exclude" bloqueia.
profile.architecture, profile.firmware = "aarch64", "unofficialos"
v3document.extensions = nil
local variant = v3document.items[1].release.variants[1]
variant.compatibility.firmwares = {include = {"darkos", "rocknix"}}
local soft, _, softMetadata = Catalog.validate(v3document, profile)
assert(#soft == 1 and soft[1].firmwareUnverified == true, "port fora da lista deveria aparecer")
assert(soft[1].testedFirmwares[1] == "darkos" and soft[1].testedFirmwares[2] == "rocknix")
assert(softMetadata.incompatible == 0 and softMetadata.unverified == 1)
profile.firmware = "rocknix"
local listed, _, listedMetadata = Catalog.validate(v3document, profile)
assert(#listed == 1 and listed[1].firmwareUnverified == false and listedMetadata.unverified == 0)
variant.compatibility.firmwares = {include = {"darkos"}, exclude = {"rocknix"}}
local blocked, _, blockedMetadata = Catalog.validate(v3document, profile)
assert(#blocked == 0 and blockedMetadata.incompatible == 1, "exclude continua bloqueando")
variant.compatibility.firmwares = nil
profile.architecture = "armhf"
assert(#Catalog.validate(v3document, profile) == 0, "arquitetura continua obrigatória")
profile.architecture = "aarch64"

-- Mensagens de falha da sincronização: o relógio vem antes dos demais, mesmo misturado a outros espelhos.
local clock = Catalog.syncFailureMessage("nenhum head válido; https://a/: data de publicação está no futuro; https://b/: falha ao consultar https://b/ (timed out)")
assert(clock:find("Relógio do console atrasado", 1, true), clock)
assert(Catalog.syncFailureMessage("falha ao consultar https://a/ ([SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed: certificate is not yet valid)"):find("Relógio", 1, true))
assert(Catalog.syncFailureMessage("relógio local inválido ou atrasado"):find("Relógio", 1, true))
assert(Catalog.syncFailureMessage("nenhum head válido; https://a/: falha ao consultar https://a/ ([Errno -3] Temporary failure in name resolution)"):find("Sem DNS", 1, true))
assert(Catalog.syncFailureMessage("nenhum head válido; https://a/: falha ao consultar https://a/ (timed out)"):find("Sem acesso", 1, true))
assert(Catalog.syncFailureMessage("falha no RPC do aria2"):find("Motor BitTorrent", 1, true))
assert(Catalog.syncFailureMessage("head expirado"):find("vencido", 1, true))
assert(Catalog.syncFailureMessage("algo inesperado"):find("^Falha no catálogo: algo inesperado"))
assert(Catalog.syncFailureMessage("") == nil and Catalog.syncFailureMessage(nil) == nil)
print("catalog tests: ok")
