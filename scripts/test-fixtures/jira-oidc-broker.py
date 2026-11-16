#!/usr/bin/env python3
"""Fake Jira OIDC token broker for the shell tests.

Usage: jira-oidc-broker.py LOG RESPONSES -- COMMAND [ARGS...]

Creates a socketpair, as fullsend run does, and runs COMMAND with one end
inherited and FULLSEND_JIRA_OIDC_TOKEN_FD set to its number. The other end
is served in a thread: each request line is logged to LOG (the request,
never a token), and answered with the next line of RESPONSES. Special
response lines: "hang" sends nothing, "close" closes the broker end,
"delay N LINE" sends LINE after N seconds, "partial TEXT" sends TEXT with
no newline and closes, "okclose LINE" sends LINE and closes.
Lines are sent with a trailing newline. Exits with COMMAND's exit code.

The first LOG line is "inode socket:[N]", the inode of the end the command
holds, so a test can look for it among another process's open fds.
"""

import os
import socket
import subprocess
import sys
import threading
import time


def serve(sock, log_path, responses):
    buf = b""
    with open(log_path, "a", encoding="utf-8") as log:
        for response in responses:
            while b"\n" not in buf:
                chunk = sock.recv(64)
                if not chunk:
                    return
                buf += chunk
            line, buf = buf.split(b"\n", 1)
            log.write("request " + line.decode("ascii", "replace") + "\n")
            log.flush()
            if response == "hang":
                continue
            if response == "close":
                sock.close()
                return
            if response.startswith("partial "):
                sock.sendall(response[len("partial "):].encode("ascii"))
                sock.close()
                return
            if response.startswith("okclose "):
                sock.sendall(response[len("okclose "):].encode("ascii") + b"\n")
                sock.close()
                return
            if response.startswith("delay "):
                _, seconds, response = response.split(" ", 2)
                time.sleep(float(seconds))
            sock.sendall(response.encode("ascii") + b"\n")
        # Out of scripted responses: refuse further requests.
        while True:
            chunk = sock.recv(64)
            if not chunk:
                return
            log.write("request beyond script\n")
            log.flush()
            sock.sendall(b"err bad_request\n")


def main():
    if len(sys.argv) < 5 or sys.argv[3] != "--":
        sys.stderr.write(__doc__)
        return 2
    log_path, responses_path, command = sys.argv[1], sys.argv[2], sys.argv[4:]
    with open(responses_path, encoding="utf-8") as f:
        responses = [line.rstrip("\n") for line in f if line.strip()]
    ours, theirs = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
    child_fd = theirs.fileno()
    with open(log_path, "w", encoding="utf-8") as log:
        log.write("inode socket:[%d]\n" % os.fstat(child_fd).st_ino)
    env = dict(os.environ)
    env["FULLSEND_JIRA_OIDC_TOKEN_FD"] = str(child_fd)
    # For fakes that check whether they still hold the fd.
    env["TEST_BROKER_FD"] = str(child_fd)
    thread = threading.Thread(target=serve, args=(ours, log_path, responses), daemon=True)
    thread.start()
    proc = subprocess.Popen(command, env=env, pass_fds=(child_fd,))
    theirs.close()
    rc = proc.wait()
    return rc


if __name__ == "__main__":
    sys.exit(main())
