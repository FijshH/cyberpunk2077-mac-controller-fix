#!/bin/sh
# Build and install the fix into ~/.local/lib, then create a launcher in ~/.local/bin.
set -e
PREFIX="${PREFIX:-$HOME/.local}"
mkdir -p "$PREFIX/lib" "$PREFIX/bin"

clang -dynamiclib -arch arm64 -fobjc-arc -O2 \
      -framework Foundation -framework GameController \
      -o "$PREFIX/lib/cp2077-padfix.dylib" src/cp2077-padfix.m
codesign -f -s - "$PREFIX/lib/cp2077-padfix.dylib"
echo "built  $PREFIX/lib/cp2077-padfix.dylib"

cat > "$PREFIX/bin/cp2077" <<LAUNCHER
#!/bin/sh
# cp2077          launch with the controller fix
# cp2077 --hud    also enable Apple's Metal Performance HUD
GAME="\$HOME/Library/Application Support/Steam/steamapps/common/Cyberpunk 2077/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"
FIX="$PREFIX/lib/cp2077-padfix.dylib"
HUD=0
case "\$1" in --hud|-h) HUD=1; shift;; esac
[ -x "\$GAME" ] || { echo "cp2077: game not found at \$GAME" >&2; exit 1; }
if [ "\$HUD" = 1 ]; then
  exec env DYLD_INSERT_LIBRARIES="\$FIX" MTL_HUD_ENABLED=1 "\$GAME" "\$@"
else
  exec env DYLD_INSERT_LIBRARIES="\$FIX" "\$GAME" "\$@"
fi
LAUNCHER
chmod +x "$PREFIX/bin/cp2077"
echo "built  $PREFIX/bin/cp2077"
echo
echo "Run the game with:  cp2077"
echo "Or set this in Steam > Properties > General > Launch Options:"
echo "  DYLD_INSERT_LIBRARIES=\$HOME/.local/lib/cp2077-padfix.dylib %command%"
