#!/usr/bin/env python3
# marvin kurulum gunlugu dinleyicisi — d-i log_host= ile buraya gonderir.
# Gelen satirlar /opt/llm-repo/install.log dosyasina yazilir ve
# http://<pi>:8080/install.log adresinden okunabilir.
import socket, time, os
OUT = "/opt/llm-repo/install.log"
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", 514))
with open(OUT, "a", buffering=1) as f:
    f.write(f"\n===== dinleyici basladi {time.strftime('%H:%M:%S')} =====\n")
    while True:
        try:
            data, addr = s.recvfrom(8192)
            line = data.decode("utf-8", "replace").rstrip()
            f.write(f"{time.strftime('%H:%M:%S')} {addr[0]} {line}\n")
        except Exception as e:
            f.write(f"HATA: {e}\n")
