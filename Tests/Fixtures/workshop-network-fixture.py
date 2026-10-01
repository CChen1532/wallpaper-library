#!/usr/bin/python3
"""Controlled loopback transfer for per-process network sampling. No internet."""
import socket
import threading
import time

server = socket.socket()
server.bind(('127.0.0.1', 0))
server.listen(1)

def sender():
    connection, _ = server.accept()
    time.sleep(1.5)
    for _ in range(40):
        connection.sendall(b'x' * 131072)
        time.sleep(.1)
    time.sleep(1)
    connection.close()

thread = threading.Thread(target=sender)
thread.start()
receiver = socket.create_connection(server.getsockname())
while receiver.recv(262144):
    pass
receiver.close()
thread.join()
server.close()
