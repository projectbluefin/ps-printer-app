#!/usr/bin/env python3
"""One-shot TCP sink that captures what a printer application sends to a device.

The CUPS socket backend speaks raw TCP to a printer, usually on port 9100.  This
sink stands in for that printer: it accepts a single connection, reads until the
peer closes the connection (or goes quiet), and stores every received byte in the
output file.  The caller then checks the captured bytes for the format header of
the driver that was supposed to run.

Usage:
    socket-sink.py PORT OUTPUT_PATH
"""
import socket
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} PORT OUTPUT_PATH", file=sys.stderr)
        return 2

    port = int(sys.argv[1])
    output_path = sys.argv[2]

    with socket.socket() as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", port))
        listener.listen(1)
        connection, _ = listener.accept()
        connection.settimeout(30)
        count = 0
        with connection, open(output_path, "wb") as output:
            while True:
                try:
                    data = connection.recv(65536)
                except socket.timeout:
                    # The backend kept the connection open; keep what arrived so
                    # far instead of failing the caller.
                    break
                if not data:
                    break
                output.write(data)
                count += len(data)

    print(f"socket-sink: captured {count} bytes into {output_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
