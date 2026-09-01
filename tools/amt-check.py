#!/usr/bin/env python3
"""
amt-check.py — AMT/ISM firmware'inin NEYI DESTEKLEDIGINI sorar.

Asil soru: bu makinede uzaktan PXE boot ZORLANABILIYOR mu?
AMT_BootCapabilities nesnesi bunu dogrudan soyler (ForcePXEBoot alani).
WebUI'da secenegin gorunmemesi API'de de yok demek degildir.

Kullanim (parola ortam degiskeninden okunur, komut satirinda gorunmez):
    AMT_PASSWORD='...' python3 amt-check.py [host] [port] [user]

Ornekler:
    # Mac'ten, SSH tuneli uzerinden:
    ssh -f -N -L 16993:192.168.1.114:16993 pi
    AMT_PASSWORD='...' python3 amt-check.py localhost 16993

    # Pi'den, dogrudan:
    AMT_PASSWORD='...' python3 amt-check.py 192.168.1.114 16993

Bagimlilik yok - yalnizca Python standart kutuphanesi.
"""
import os, ssl, sys, urllib.request, re

host = sys.argv[1] if len(sys.argv) > 1 else "localhost"
port = sys.argv[2] if len(sys.argv) > 2 else "16993"
user = sys.argv[3] if len(sys.argv) > 3 else "admin"
pw   = os.environ.get("AMT_PASSWORD")

if not pw:
    sys.exit("HATA: AMT_PASSWORD ortam degiskeni bos.\n"
             "  AMT_PASSWORD='parola' python3 amt-check.py localhost 16993")

url = f"https://{host}:{port}/wsman"

def wsman_get(resource):
    body = f'''<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
            xmlns:a="http://schemas.xmlsoap.org/ws/2004/08/addressing"
            xmlns:w="http://schemas.dmtf.org/wbem/wsman/1/wsman.xsd">
  <s:Header>
    <a:Action s:mustUnderstand="true">http://schemas.xmlsoap.org/ws/2004/09/transfer/Get</a:Action>
    <a:To s:mustUnderstand="true">{url}</a:To>
    <w:ResourceURI s:mustUnderstand="true">{resource}</w:ResourceURI>
    <a:MessageID s:mustUnderstand="true">uuid:00000000-0000-0000-0000-000000000001</a:MessageID>
    <a:ReplyTo><a:Address>http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous</a:Address></a:ReplyTo>
    <w:OperationTimeout>PT60.000S</w:OperationTimeout>
  </s:Header>
  <s:Body/>
</s:Envelope>'''
    req = urllib.request.Request(url, data=body.encode(),
        headers={"Content-Type": "application/soap+xml;charset=UTF-8"}, method="POST")
    return opener.open(req, timeout=30).read().decode("utf-8", "replace")

# AMT sertifikasi kendinden imzali; dogrulama kapatiliyor (LAN icinde, tunel arkasinda).
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

mgr = urllib.request.HTTPPasswordMgrWithDefaultRealm()
mgr.add_password(None, url, user, pw)
opener = urllib.request.build_opener(
    urllib.request.HTTPSHandler(context=ctx),
    urllib.request.HTTPDigestAuthHandler(mgr),
    urllib.request.HTTPBasicAuthHandler(mgr),
)

def field(xml, name):
    m = re.search(rf"<[^>]*:{name}>([^<]*)</[^>]*:{name}>", xml)
    return m.group(1) if m else None

print(f"Hedef: {url}  (kullanici: {user})\n")

try:
    core = wsman_get("http://intel.com/wbem/wscim/1/amt-schema/1/AMT_GeneralSettings")
    print("BAGLANTI: OK — AMT WS-MAN cevap veriyor")
    for f in ("HostName", "DigestRealm", "AMTNetworkEnabled"):
        v = field(core, f)
        if v: print(f"  {f:22s}: {v}")
except Exception as e:
    sys.exit(f"BAGLANTI HATASI: {e}\n"
             "  401 ise parola/kullanici yanlis. Baglanti kurulamiyorsa tunel kapali olabilir.")

print("\n--- AMT_BootCapabilities (asil soru burada) ---")
try:
    caps = wsman_get("http://intel.com/wbem/wscim/1/amt-schema/1/AMT_BootCapabilities")
except Exception as e:
    sys.exit(f"BootCapabilities alinamadi: {e}")

ilgili = [
    ("ForcePXEBoot",        "UZAKTAN PXE BOOT  <<< BIZIM ICIN KRITIK"),
    ("ForceHardDriveBoot",  "Diskten acmaya zorla"),
    ("ForceCDorDVDBoot",    "CD/DVD'den acmaya zorla"),
    ("IDER",                "ISO yonlendirme (uzaktan imaj)"),
    ("KVM",                 "Uzaktan ekran (Hardware KVM)"),
    ("SOL",                 "Seri konsol (Serial-over-LAN)"),
    ("BIOSSetup",           "Acilista BIOS'a gir"),
    ("BIOSPause",           "Acilisi duraklat"),
    ("SecureErase",         "Guvenli silme"),
]
bulunan = 0
for ad, aciklama in ilgili:
    v = field(caps, ad)
    if v is None:
        continue
    bulunan += 1
    isaret = "VAR " if v.lower() == "true" else "YOK "
    print(f"  [{isaret}] {ad:20s} {aciklama}")

if bulunan == 0:
    print("  (alan ayristirilamadi — ham cevap asagida)")
    print(caps[:1500])

pxe = field(caps, "ForcePXEBoot")
print("\n=== SONUC ===")
if pxe and pxe.lower() == "true":
    print("  PXE ZORLANABILIYOR. Netboot kurulup uzaktan kurtarma yapilabilir.")
else:
    print("  PXE ZORLANAMIYOR. Uzaktan netboot yolu KAPALI;")
    print("  netboot ancak BIOS boot sirasi [disk -> ag] yapilirsa tetiklenebilir")
    print("  ve bu bir kez fiziksel erisim gerektirir.")
