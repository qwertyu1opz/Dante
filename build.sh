#!/bin/sh
set -e

PROJ="$(cd "$(dirname "$0")" && pwd)"
SDK_VERSION=6.1
SDK="$HOME/Documents/workspace/theos/sdks/iPhoneOS${SDK_VERSION}.sdk"
[ -d "$SDK" ] || SDK="/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS${SDK_VERSION}.sdk"
LDID="$HOME/Documents/workspace/theos/bin/ldid"
CLANG=/usr/bin/clang
SRC=Dante
ARCH=armv7
MIN_VER=5.0
OPT="-O2"

FRAMEWORKS="-framework UIKit -framework Foundation -framework CoreGraphics \
            -framework QuartzCore -framework CFNetwork -framework Security \
            -framework SystemConfiguration -lz \
            $PROJ/Vendor/openssl/libssl.a $PROJ/Vendor/openssl/libcrypto.a"

INCLUDES="-I$SRC -I$SRC/UI -I$SRC/Daemon -I$SRC/Fixer -I$SRC/Networking -I$SRC/Networking/AmneziaWG -I$SRC/Networking/DanteCurl -I$SRC/Networking/Power -I$PROJ/Vendor/openssl/include"

CFLAGS="-arch $ARCH -isysroot $SDK -miphoneos-version-min=$MIN_VER $OPT $INCLUDES -fobjc-arc -include $SRC/DanteCompat.h"

SOURCES="
$SRC/main.m
$SRC/DanteSubscriptShim.m
$SRC/AppDelegate.m
$SRC/DebugLog.m
$SRC/DanteViewController.m
$SRC/UI/DanteSkin.m
$SRC/UI/DanteJailbreakButton.m
$SRC/UI/DanteLCDView.m
$SRC/UI/DanteChrome.m
$SRC/UI/DanteLogBackdrop.m
$SRC/UI/DanteDCViewController.m
$SRC/Daemon/DanteControl.m
$SRC/Daemon/DanteRedirector.m
$SRC/Daemon/DanteDaemon.m
$SRC/Daemon/DanteHTTPProxy.m
$SRC/Daemon/DanteSystemProxy.m
$SRC/Daemon/DanteUtun.m
$SRC/Daemon/DanteTunNAT.c
$SRC/Daemon/nw_scope.c
$SRC/Daemon/DanteDCScanner.m
$SRC/Fixer/DanteFixer.m
$SRC/Fixer/DanteNetworkProbe.m
$SRC/Networking/TLSTrustManager.m
$SRC/Networking/DanteCurl/dcurl.c
$SRC/Networking/DanteCurl/DanteCurl.m
$SRC/Networking/Power/PowerVLESS.c
$SRC/Networking/Power/PowerSHA256.c
$SRC/Networking/Power/PowerReality.c
$SRC/Networking/Power/PowerConfig.m
$SRC/Networking/Power/PowerSession.m
$SRC/Networking/Power/PowerSelector.m
$SRC/Networking/Power/PowerSubscriptions.m
$SRC/Networking/AmneziaWG/monocypher.c
$SRC/Networking/AmneziaWG/chacha20_neon.c
$SRC/Networking/AmneziaWG/blake2s.c
$SRC/Networking/AmneziaWG/AWGCrypto.m
$SRC/Networking/AmneziaWG/AWGConfig.m
$SRC/Networking/AmneziaWG/AWGHandshake.m
$SRC/Networking/AmneziaWG/AWGTunnel.m
$SRC/Networking/AmneziaWG/AWGIPStack.m
$SRC/Networking/AmneziaWG/AWGHTTPSTransport.m
$SRC/Networking/AmneziaWG/AWGWarpRegistrar.m
$SRC/Networking/AmneziaWG/AmneziaWGManager.m
"

rm -rf obj
mkdir -p obj Dante.app

echo "=== Compiling (SDK $SDK_VERSION, min iOS $MIN_VER) ==="
for src in $SOURCES; do
    fname=$(basename "$src")
    objname="${fname%.*}.o"
    objfile="obj/$objname"
    file_cflags="$CFLAGS"
    if [ "$fname" = "monocypher.c" ] || [ "$fname" = "blake2s.c" ] || [ "$fname" = "chacha20_neon.c" ]; then
        file_cflags=$(echo "$CFLAGS" | sed -e 's/-O2/-O3/' -e 's/-Os/-O3/')
        echo "  $src -> $objfile (optimized with -O3)"
    else
        echo "  $src -> $objfile"
    fi
    $CLANG $file_cflags -c "$src" -o "$objfile"
done

echo "=== Linking ==="
$CLANG -arch $ARCH -isysroot $SDK -miphoneos-version-min=$MIN_VER obj/*.o \
    $FRAMEWORKS \
    -o Dante.app/Dante

cp Dante/Info.plist Dante.app/Info.plist

echo "=== Copying resources ==="
cp -R Dante/Resources/ Dante.app/

echo "=== Signing ==="
$LDID -Hsha1 -SDante/Dante.entitlements Dante.app/Dante

echo "=== dante-kick ==="
mkdir -p build
$CLANG -arch $ARCH -isysroot $SDK -miphoneos-version-min=$MIN_VER -Os \
    $SRC/Kick/dante-kick.c -o build/dante-kick
$LDID -Hsha1 -SDante/Dante.entitlements build/dante-kick

echo "=== Done: Dante.app ==="
