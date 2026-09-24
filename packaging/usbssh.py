#!/usr/bin/env python3
import plistlib
import select
import socket
import struct
import sys
import threading

MUX = '/var/run/usbmuxd'


def mux_msg(sock, payload, tag=1):
    body = plistlib.dumps(payload)
    sock.sendall(struct.pack('<IIII', 16 + len(body), 1, 8, tag) + body)


def mux_read(sock):
    hdr = b''
    while len(hdr) < 16:
        chunk = sock.recv(16 - len(hdr))
        if not chunk:
            raise ConnectionError('usbmuxd закрыл соединение')
        hdr += chunk
    length = struct.unpack('<IIII', hdr)[0]
    body = b''
    while len(body) < length - 16:
        chunk = sock.recv(length - 16 - len(body))
        if not chunk:
            raise ConnectionError('usbmuxd закрыл соединение')
        body += chunk
    return plistlib.loads(body)


def base(msg_type):
    return {'MessageType': msg_type, 'ClientVersionString': 'usbssh',
            'ProgName': 'usbssh', 'kLibUSBMuxVersion': 3}


def list_devices():
    s = socket.socket(socket.AF_UNIX)
    s.connect(MUX)
    mux_msg(s, base('ListDevices'))
    reply = mux_read(s)
    s.close()
    return [d['Properties'] for d in reply.get('DeviceList', [])
            if d.get('Properties', {}).get('ConnectionType') == 'USB']


def connect_device(device_id, port):
    s = socket.socket(socket.AF_UNIX)
    s.connect(MUX)
    msg = base('Connect')
    msg['DeviceID'] = device_id
    msg['PortNumber'] = socket.htons(port)
    mux_msg(s, msg)
    reply = mux_read(s)
    if reply.get('Number', 1) != 0:
        s.close()
        raise ConnectionError('устройство отказало в порту %d: %r' % (port, reply))
    return s


def pump(a, b):
    try:
        while True:
            r, _, _ = select.select([a, b], [], [])
            for src in r:
                data = src.recv(65536)
                if not data:
                    return
                (b if src is a else a).sendall(data)
    except OSError:
        pass
    finally:
        a.close()
        b.close()


def main():
    local = int(sys.argv[1]) if len(sys.argv) > 1 else 2222
    remote = int(sys.argv[2]) if len(sys.argv) > 2 else 22
    want = sys.argv[3] if len(sys.argv) > 3 else None
    devices = list_devices()
    if want:
        devices = [d for d in devices if d.get('SerialNumber') == want]
    if not devices:
        sys.exit('устройств по USB не найдено')
    dev = devices[0]
    print('устройство %s (id %d), 127.0.0.1:%d -> :%d' %
          (dev.get('SerialNumber'), dev['DeviceID'], local, remote), flush=True)

    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(('127.0.0.1', local))
    srv.listen(8)
    while True:
        client, _ = srv.accept()
        try:
            upstream = connect_device(dev['DeviceID'], remote)
        except Exception as e:
            print(e, flush=True)
            client.close()
            continue
        threading.Thread(target=pump, args=(client, upstream), daemon=True).start()


if __name__ == '__main__':
    main()
