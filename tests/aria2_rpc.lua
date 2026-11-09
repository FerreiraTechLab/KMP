package.path = "KMP/game/?.lua;" .. package.path
local Json = require("json")
local Rpc = require("aria2_rpc")

local original = {text = "Olá \"mundo\"", list = {1, true, "x"}}
assert(Json.encode(Json.array()) == "[]")
local decoded = assert(Json.decode(Json.encode(original)))
assert(decoded.text == original.text and decoded.list[2] == true)
assert(Json.decode('{"x":"\\u00e1"}').x == "á")
assert(Json.decode('{"x":') == nil)

local seen
local call = Rpc.new("http://127.0.0.1:6800/jsonrpc", "abcdef012345", function(command)
    seen = command
    return '{"jsonrpc":"2.0","id":"kmp","result":"1234"}'
end)
assert(call("aria2.addUri", {{"magnet:?xt=urn:btih:abc&dn=foo'bar"}}) == "1234")
assert(seen:find("curl --noproxy", 1, true))
assert(call("bad.method", {}) == nil)
local silent = Rpc.new("http://127.0.0.1:6800/jsonrpc", "abcdef012345", function() return "" end)
local result, message = silent("aria2.tellStatus", {"1"})
assert(result == nil and message:find("não respondeu", 1, true), "corpo vazio indica daemon sem resposta")
print("aria2 RPC tests: ok")
