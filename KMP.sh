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

source "$controlfolder/control.txt"

[ -f "${controlfolder}/mod_${CFW_NAME}.txt" ] && source "${controlfolder}/mod_${CFW_NAME}.txt"

get_controls

GAMEDIR=/$directory/ports/KMP
CONFDIR="$GAMEDIR/conf/"

mkdir -p "$GAMEDIR/conf" "$GAMEDIR/conf/.portfolder" "$HOME/.portfolder"
cd "$GAMEDIR"

> "$GAMEDIR/log.txt" && exec > >(tee "$GAMEDIR/log.txt") 2>&1
KMP_VERSION="$(cat "$GAMEDIR/version.txt" 2>/dev/null || printf 'desconhecida')"
printf 'KDownloader PM v%s\n' "$KMP_VERSION"

# Set the XDG environment variables for config & savefiles
export XDG_DATA_HOME="$CONFDIR"

export LD_LIBRARY_PATH="$GAMEDIR/libs.${DEVICE_ARCH}:$LD_LIBRARY_PATH"
export SDL_GAMECONTROLLERCONFIG="$sdl_controllerconfig"
export KMP_INSTALLER="$GAMEDIR/install.py"
export KMP_CATALOG_SYNC="$GAMEDIR/catalog_sync.py"
export KMP_CATALOG_SECURITY="$GAMEDIR/catalog_security.py"
export KMP_DIAGNOSTIC="$GAMEDIR/diagnostic.py"
export KMP_GAME_DIR="$GAMEDIR"
export KMP_CONF_DIR="$CONFDIR"
export KMP_DIAGNOSTIC_OUTPUT="${GAMEDIR%/KMP}/KMP-diagnostics"

runtime_arch=${DEVICE_ARCH:-$(uname -m)}
[ "$runtime_arch" = "arm64" ] && runtime_arch=aarch64
export KMP_DEVICE_ARCH="$runtime_arch"
firmware_name=$(printf '%s' "${CFW_NAME:-unknown}" | tr '[:upper:]' '[:lower:]')
case "$firmware_name" in
  *darkos*) firmware_name=darkos ;;
  *rocknix*) firmware_name=rocknix ;;
  *aurknix*) firmware_name=aurknix ;;
  *) firmware_name=$(printf '%s' "$firmware_name" | tr -cs 'a-z0-9_-' '_') ;;
esac
export KMP_FIRMWARE="${firmware_name%_}"
export KMP_RAM_MB="$(awk '/^MemTotal:/ {print int($2 / 1024); exit}' /proc/meminfo 2>/dev/null)"
export KMP_ANALOG_STICKS="${KMP_ANALOG_STICKS:-2}"
export KMP_RENDERERS="${KMP_RENDERERS:-gles2,opengl}"
runtime_list=""
if [ -d "$controlfolder/runtimes" ]; then
  for runtime_path in "$controlfolder"/runtimes/*; do
    [ -d "$runtime_path" ] || continue
    runtime_name=$(printf '%s' "${runtime_path##*/}" | tr '.-' '__')
    runtime_list="${runtime_list}${runtime_list:+,}${runtime_name}"
  done
fi
export KMP_RUNTIMES="$runtime_list"

if command -v python3 >/dev/null 2>&1; then
  export KMP_PYTHON="$(command -v python3)"
elif command -v python >/dev/null 2>&1; then
  export KMP_PYTHON="$(command -v python)"
else
  export KMP_PYTHON=""
  printf 'Python 3 não encontrado; catálogo e instalação indisponíveis.\n' >&2
fi

# Finish or roll back installations interrupted by a previous power loss.
for recovery_root in /roms/ports /roms2/ports; do
  if [ -n "$KMP_PYTHON" ] && [ -d "$recovery_root" ]; then
    recovery_result=$("$KMP_PYTHON" "$KMP_INSTALLER" recover "$recovery_root") || {
      printf 'Falha ao recuperar instalações em %s\n' "$recovery_root" >&2
      continue
    }
    [ "$recovery_result" = "[]" ] || \
      printf 'Instalações recuperadas em %s: %s\n' "$recovery_root" "$recovery_result"
  fi
done
if [ -f "$GAMEDIR/catalog-sources.txt" ] && [ -f "$GAMEDIR/catalog-root.pub" ]; then
  trusted_catalog_key="$CONFDIR/catalog/trusted-key.pem"
  if [ ! -s "$trusted_catalog_key" ]; then
    mkdir -p "$CONFDIR/catalog"
    install -m 600 "$GAMEDIR/catalog-root.pub" "$trusted_catalog_key"
  fi
  export KMP_CATALOG_SOURCES="$GAMEDIR/catalog-sources.txt"
  export KMP_CATALOG_PUBLIC_KEY="$trusted_catalog_key"
  export KMP_CATALOG_STATE="$CONFDIR/catalog/state.json"
  export KMP_CATALOG_PENDING="$CONFDIR/catalog/pending"
  export KMP_CATALOG_DOWNLOADS="$CONFDIR/catalog/torrents"
  export KMP_CATALOG_ACTIVE="$CONFDIR/catalog/active.json"
fi
if [ -f "$GAMEDIR/catalog-url.txt" ]; then
  IFS= read -r KMP_CATALOG_URL < "$GAMEDIR/catalog-url.txt"
  export KMP_CATALOG_URL
elif [ -f "$GAMEDIR/demo/catalog-v1.json" ]; then
  export KMP_CATALOG_URL="file://$GAMEDIR/demo/catalog-v1.json"
fi
if [ -f "$GAMEDIR/peer.txt" ]; then
  IFS= read -r KMP_PEER < "$GAMEDIR/peer.txt"
  KMP_PEER="$(printf '%s' "$KMP_PEER" | tr -d '[:space:]')"
  export KMP_PEER
fi

# Prefer a PortMaster-local BitTorrent client; fall back to the firmware package.
# The application reports a missing backend when neither is available.
bundled_aria2="$GAMEDIR/libs.${runtime_arch}/aria2c"
if [ -f "$bundled_aria2" ]; then
  chmod +x "$bundled_aria2" 2>/dev/null || true
fi
if [ -x "$bundled_aria2" ]; then
  export KMP_ARIA2="$bundled_aria2"
elif command -v aria2c >/dev/null 2>&1; then
  export KMP_ARIA2="$(command -v aria2c)"
else
  export KMP_ARIA2=""
fi

source $controlfolder/runtimes/"love_11.5"/love.txt

# The DarkOS image does not run a PipeWire user session. Set this after loading
# the runtime in case love.txt changes the audio environment.
printf '[general]\ndrivers=alsa\n' > "$CONFDIR/alsoft.conf"
export ALSOFT_CONF="$CONFDIR/alsoft.conf"
export ALSOFT_DRIVERS="alsa"

printf 'Backend BitTorrent: %s\n' "${KMP_ARIA2:-não encontrado}"
printf 'Python: %s\n' "${KMP_PYTHON:-não encontrado}"
printf 'Peer direto: %s\n' "${KMP_PEER:-não configurado}"

# Start or reuse the persistent BitTorrent daemon. It keeps completed torrents
# seeding after the graphical interface closes.
if [ -n "$KMP_ARIA2" ]; then
  if "$GAMEDIR/daemon.sh" start "$KMP_ARIA2" "$CONFDIR/daemon" "$CONFDIR/torrent" >/dev/null; then
    set -a
    source "$CONFDIR/daemon/rpc.env"
    set +a
  else
    export KMP_ARIA2_RPC=""
    export KMP_ARIA2_SECRET=""
  fi
fi

# Run the love runtime
$GPTOKEYB "$LOVE_GPTK" &
pm_platform_helper "$LOVE_BINARY"
$LOVE_RUN "$GAMEDIR/game.love"

printf 'Interface encerrada; restaurando frontend.\n'
pm_finish
printf 'KDownloader PM finalizado.\n'
