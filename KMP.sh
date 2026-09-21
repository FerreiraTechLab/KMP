#!/bin/bash

XDG_DATA_HOME=${XDG_DATA_HOME:-$HOME/.local/share}

if [ -d "/opt/system/Tools/PortMaster/" ]; then
  controlfolder="/opt/system/Tools/PortMaster"
elif [ -d "/opt/tools/PortMaster/" ]; then
  controlfolder="/opt/tools/PortMaster"
elif [ -d "$XDG_DATA_HOME/PortMaster/" ]; then
  controlfolder="$XDG_DATA_HOME/PortMaster"
else
  controlfolder="/roms/ports/PortMaster"
fi

source $controlfolder/control.txt

[ -f "${controlfolder}/mod_${CFW_NAME}.txt" ] && source "${controlfolder}/mod_${CFW_NAME}.txt"

get_controls

GAMEDIR=/$directory/ports/KMP
CONFDIR="$GAMEDIR/conf/"

mkdir -p "$GAMEDIR/conf"
cd $GAMEDIR

> "$GAMEDIR/log.txt" && exec > >(tee "$GAMEDIR/log.txt") 2>&1

# Set the XDG environment variables for config & savefiles
export XDG_DATA_HOME="$CONFDIR"

#  If XDG Path does not work
# Use bind_directories to reroute that to a location within the ports folder.
bind_directories ~/.portfolder $GAMEDIR/conf/.portfolder 

export LD_LIBRARY_PATH="$GAMEDIR/libs.${DEVICE_ARCH}:$LD_LIBRARY_PATH"
export SDL_GAMECONTROLLERCONFIG="$sdl_controllerconfig"
export KMP_INSTALLER="$GAMEDIR/install.py"
if [ -f "$GAMEDIR/catalog-url.txt" ]; then
  IFS= read -r KMP_CATALOG_URL < "$GAMEDIR/catalog-url.txt"
  export KMP_CATALOG_URL
elif [ -f "$GAMEDIR/demo/catalog-v1.json" ]; then
  export KMP_CATALOG_URL="file://$GAMEDIR/demo/catalog-v1.json"
fi

# Prefer a PortMaster-local BitTorrent client; fall back to the firmware package.
# The application reports a missing backend when neither is available.
if [ -x "$GAMEDIR/libs.${DEVICE_ARCH}/aria2c" ]; then
  export KMP_ARIA2="$GAMEDIR/libs.${DEVICE_ARCH}/aria2c"
elif command -v aria2c >/dev/null 2>&1; then
  export KMP_ARIA2="$(command -v aria2c)"
else
  export KMP_ARIA2=""
fi

source $controlfolder/runtimes/"love_11.5"/love.txt

# Keep the RPC server private to this application and stop it on exit.
if [ -n "$KMP_ARIA2" ]; then
  mkdir -p "$CONFDIR/torrent"
  KMP_ARIA2_SECRET="$(od -An -N16 -tx1 /dev/urandom | tr -d '[:space:]')"
  KMP_ARIA2_PORT=$((20000 + RANDOM % 40000))
  export KMP_ARIA2_SECRET
  export KMP_ARIA2_RPC="http://127.0.0.1:${KMP_ARIA2_PORT}/jsonrpc"
  "$KMP_ARIA2" --enable-rpc=true --rpc-listen-all=false \
    --rpc-listen-port="$KMP_ARIA2_PORT" --rpc-secret="$KMP_ARIA2_SECRET" \
    --max-concurrent-downloads=1 --max-overall-upload-limit=100K \
    --bt-enable-lpd=true --file-allocation=none --dir="$CONFDIR/torrent" \
    --console-log-level=warn < /dev/null > "$CONFDIR/aria2.log" 2>&1 &
  KMP_ARIA2_PID=$!
  trap 'kill "$KMP_ARIA2_PID" 2>/dev/null; wait "$KMP_ARIA2_PID" 2>/dev/null' EXIT
fi

# Run the love runtime
$GPTOKEYB "$LOVE_GPTK" &
pm_platform_helper "$LOVE_BINARY"
$LOVE_RUN "$GAMEDIR/game.love"

pm_finish
