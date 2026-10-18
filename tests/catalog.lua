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
print("catalog tests: ok")
