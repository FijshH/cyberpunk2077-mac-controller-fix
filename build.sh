#!/bin/sh
# Build and install the fix into ~/.local/lib, then create a launcher in ~/.local/bin.
set -e
PREFIX="${PREFIX:-$HOME/.local}"
mkdir -p "$PREFIX/lib" "$PREFIX/bin"

clang -dynamiclib -arch arm64 -fobjc-arc -O2 \
      -framework Foundation -framework GameController -framework IOKit -framework CoreFoundation \
      -o "$PREFIX/lib/cp2077-padfix.dylib" src/cp2077-padfix.m
codesign -f -s - "$PREFIX/lib/cp2077-padfix.dylib"
echo "built  $PREFIX/lib/cp2077-padfix.dylib"

# Steam on macOS does not accept "VAR=value %command%". It tries to execute the
# first token as a program, which fails with OS Error 260 (file not found).
# This launcher is a real program Steam can start; it sets the variable itself.
cat > "$PREFIX/bin/cp2077" <<LAUNCHER
#!/bin/sh
# cp2077                 launch with the controller fix
# cp2077 --hud           also enable Apple's Metal Performance HUD
# cp2077 %command%       Steam launch option (see below)
FIX="$PREFIX/lib/cp2077-padfix.dylib"
APP="\$HOME/Library/Application Support/Steam/steamapps/common/Cyberpunk 2077/Cyberpunk2077.app"
HUD=0
case "\$1" in --hud|-h) HUD=1; shift;; esac
if [ \$# -eq 0 ]; then
  set -- "\$APP"
fi
TARGET="\$1"
shift
if [ -d "\$TARGET" ]; then
  EXE=\$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "\$TARGET/Contents/Info.plist" 2>/dev/null) || {
    echo "cp2077: cannot read \$TARGET/Contents/Info.plist" >&2
    exit 1
  }
  TARGET="\$TARGET/Contents/MacOS/\$EXE"
fi
[ -x "\$TARGET" ] || { echo "cp2077: game not found at \$TARGET" >&2; exit 1; }
if [ "\$HUD" = 1 ]; then
  export MTL_HUD_ENABLED=1
fi
export DYLD_INSERT_LIBRARIES="\$FIX"
exec "\$TARGET" "\$@"
LAUNCHER
chmod +x "$PREFIX/bin/cp2077"
echo "built  $PREFIX/bin/cp2077"
echo
echo "Run the game with:  cp2077"
echo "Or set this in Steam > Properties > General > Launch Options:"
echo "  $PREFIX/bin/cp2077 %command%"
