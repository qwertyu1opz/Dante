#!/bin/bash
set -e
PROJ="$HOME/Documents/Dante"
DEVICE="${DEVICE:-ipad}"
if [ "$DEVICE" = "iphone" ]; then
    CFG="$PROJ/ssh_iphone.conf"
elif [ "$DEVICE" = "iphone5" ]; then
    CFG="$PROJ/ssh_iphone5.conf"
elif [ "$DEVICE" = "ipad1" ]; then
    CFG="$PROJ/ssh_ipad1.conf"
else
    CFG="$HOME/Desktop/Архив/ssh_ipad.conf"
fi

cd "$PROJ"
./build.sh >/tmp/dante_build.log 2>&1 || { tail -20 /tmp/dante_build.log; exit 1; }
echo "  сборка OK"

rm -rf debwork && mkdir -p debwork/data/Applications debwork/data/Library/LaunchDaemons debwork/data/usr/bin
cp -R Dante.app debwork/data/Applications/
cp packaging/org.dante.fixerd.plist debwork/data/Library/LaunchDaemons/
cp build/dante-kick debwork/data/usr/bin/
cp packaging/postinst packaging/prerm debwork/
cat > debwork/control <<'EOF'
Package: com.dante.internetfixer
Name: Dante
Version: 1.2
Architecture: iphoneos-arm
Description: Однокнопочный чинитель интернета (AmneziaWG/WARP) для iOS 5 и 6: весь трафик устройства через туннель (iOS 5 — utun, iOS 6 — pf), выбор страны выхода
Maintainer: qwertyu1opz
Section: Utilities
EOF
cd debwork
python3 - <<'PY'
import tarfile, io, os, time
SRC, APP = 'data', 'Applications/Dante.app'
buf = io.BytesIO(); size = 0
with tarfile.open(fileobj=buf, mode='w:gz', format=tarfile.USTAR_FORMAT) as tf:
    def add(path, arc, mode=None):
        st = os.lstat(path)
        ti = tarfile.TarInfo(arc); ti.mtime = int(st.st_mtime)
        ti.uid = ti.gid = 0; ti.uname, ti.gname = 'root', 'wheel'
        if os.path.isdir(path):
            ti.type, ti.mode = tarfile.DIRTYPE, 0o755; tf.addfile(ti); return 0
        ti.type = tarfile.REGTYPE
        ti.mode = mode if mode is not None else (0o755 if (st.st_mode & 0o111) else 0o644)
        ti.size = st.st_size
        with open(path,'rb') as f: tf.addfile(ti, f)
        return st.st_size
    add(os.path.join(SRC,'Applications'), './Applications')
    add(os.path.join(SRC,'Library'), './Library')
    add(os.path.join(SRC,'Library/LaunchDaemons'), './Library/LaunchDaemons')
    size += add(os.path.join(SRC,'Library/LaunchDaemons/org.dante.fixerd.plist'),
                './Library/LaunchDaemons/org.dante.fixerd.plist')
    add(os.path.join(SRC,'usr'), './usr')
    add(os.path.join(SRC,'usr/bin'), './usr/bin')
    size += add(os.path.join(SRC,'usr/bin/dante-kick'), './usr/bin/dante-kick', mode=0o4755)
    for root, dirs, files in os.walk(os.path.join(SRC, APP)):
        rel = './' + os.path.relpath(root, SRC)
        size += add(root, rel)
        for n in sorted(files): size += add(os.path.join(root,n), rel+'/'+n)
data_tar = buf.getvalue()

ctrl = open('control').read() + 'Installed-Size: %d\n' % (size//1024)
cbuf = io.BytesIO()
with tarfile.open(fileobj=cbuf, mode='w:gz', format=tarfile.USTAR_FORMAT) as tf:
    ti = tarfile.TarInfo('./control'); ti.mtime = int(time.time())
    ti.uid = ti.gid = 0; ti.uname, ti.gname = 'root', 'wheel'
    ti.type = tarfile.REGTYPE; ti.mode = 0o644
    payload = ctrl.encode(); ti.size = len(payload)
    tf.addfile(ti, io.BytesIO(payload))
    for script in ('postinst', 'prerm'):
        body = open(script, 'rb').read()
        ti = tarfile.TarInfo('./' + script); ti.mtime = int(time.time())
        ti.uid = ti.gid = 0; ti.uname, ti.gname = 'root', 'wheel'
        ti.type = tarfile.REGTYPE; ti.mode = 0o755; ti.size = len(body)
        tf.addfile(ti, io.BytesIO(body))

def member(name, data):
    return ('%-16s%-12d%-6d%-6d%-8s%-10d`\n' % (name,int(time.time()),0,0,'100644',len(data))).encode() \
           + data + (b'\n' if len(data)%2 else b'')
with open('dante.deb','wb') as f:
    f.write(b'!<arch>\n')
    f.write(member('debian-binary', b'2.0\n'))
    f.write(member('control.tar.gz', cbuf.getvalue()))
    f.write(member('data.tar.gz', data_tar))
print('  deb: %d КБ' % (os.path.getsize('dante.deb')//1024))
PY

scp -q -F "$CFG" dante.deb $DEVICE:/tmp/dante.deb
ssh -F "$CFG" $DEVICE 'killall -TERM Dante 2>/dev/null; for i in 1 2 3 4 5 6; do killall -0 Dante 2>/dev/null || break; sleep 0.5; done; killall -9 Dante 2>/dev/null || true; dpkg -i /tmp/dante.deb >/dev/null && chmod +x /Applications/Dante.app/Dante && su mobile -c uicache >/dev/null 2>&1 && echo "  установлено"'

if [ "$1" = "--run" ]; then
    ssh -F "$CFG" $DEVICE 'uiopen "dante://fix" && echo "  запущено"'
fi
