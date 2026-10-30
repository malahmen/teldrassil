"""A stand-in for mangosd's remote console, for the shell tests.

  python3 fake_ra.py PORT_FILE LOG [ON_RESTART]

Listens on 127.0.0.1 (a free port, written to PORT_FILE), accepts any login,
answers every command with a prompt and logs it to LOG. A 'server restart'
command also runs ON_RESTART in a shell: the test's stand-in for what mangosd
and the container's restart policy do next. Runs until killed."""
import socket
import subprocess
import sys


def lines(conn):
    buf = b""
    while True:
        d = conn.recv(4096)
        if not d:
            return
        buf += d
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            yield line.rstrip(b"\r").decode("utf-8", "replace")


def main():
    port_file, log = sys.argv[1], sys.argv[2]
    on_restart = sys.argv[3] if len(sys.argv) > 3 else ""
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 0))
    srv.listen(4)
    with open(port_file, "w") as f:
        f.write(str(srv.getsockname()[1]))
    while True:
        conn, _ = srv.accept()
        with conn:
            conn.sendall(b"Username: ")
            it = lines(conn)
            try:
                next(it)
                conn.sendall(b"Password: ")
                next(it)
                conn.sendall(b"+Logged in.\r\nmangos>")
                for cmd in it:
                    with open(log, "a") as f:
                        f.write(cmd + "\n")
                    if cmd.startswith("server restart") and on_restart:
                        subprocess.Popen(["bash", "-c", on_restart])
                    conn.sendall(b"mangos>")
            except (StopIteration, OSError):
                pass


if __name__ == "__main__":
    main()
