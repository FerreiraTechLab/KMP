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
document.schemaVersion = 3
assert(Catalog.validate(document) == nil)
print("catalog tests: ok")
