function love.conf(t)
    t.identity = "kdownloader_pm"
    t.window.title = "KDownloader PM"
    t.window.width = 0
    t.window.height = 0
    t.window.fullscreen = true
    t.window.resizable = false
    t.modules.joystick = true
    -- DarkOS does not provide a PipeWire user session. Audio is optional for
    -- KMP, so keep OpenAL unloaded unless a future launcher explicitly enables
    -- it with KMP_AUDIO=1.
    t.modules.audio = os.getenv("KMP_AUDIO") == "1"
end
