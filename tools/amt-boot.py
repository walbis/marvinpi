#!/usr/bin/env python3
"""
amt-boot.py — marvin'i AMT uzerinden belirli bir aygittan acmaya ZORLAR.

amt-check.py ForcePXEBoot'un desteklendigini gosterdi; WebUI bu secenegi
sunmuyor ama WS-MAN arayuzu sunuyor.

Kullanim (parola ortam degiskeninden, komut satirinda gorunmez):
    AMT_PASSWORD='...' python3 amt-boot.py pxe    [host] [port]
    AMT_PASSWORD='...' python3 amt-boot.py hdd    [host] [port]
    AMT_PASSWORD='...' python3 amt-boot.py bios   [host] [port]
    AMT_PASSWORD='...' python3 amt-boot.py status [host] [port]

Varsayilan host/port: localhost 16993 (SSH tuneli uzerinden).

Sira: BootSettingData ayarla -> ChangeBootOrder -> SetBootConfigRole(1)
      -> RequestPowerStateChange(reset). Ayar TEK SEFERLIKTIR.
"""
import os, ssl, sys, urllib.request, re, uuid


def _parola():
    """Parolayi sirasiyla: AMT_PASSWORD ortam degiskeni -> macOS Keychain.
    Keychain kullanimi parolanin komut gecmisine ve dosyaya girmesini onler."""
    import os, subprocess
    p = os.environ.get("AMT_PASSWORD")
    if p:
        return p
    try:
        r = subprocess.run(
            ["security", "find-generic-password", "-a", os.environ.get("USER", ""),
             "-s", "marvin-amt", "-w"],
            capture_output=True, text=True, timeout=10)
        if r.returncode == 0 and r.stdout.strip():
            return r.stdout.strip()
    except Exception:
        pass
    return None

MODES = {
    "pxe":  "Intel(r) AMT: Force PXE Boot",
    "hdd":  "Intel(r) AMT: Force Hard-drive Boot",
    "cd":   "Intel(r) AMT: Force CD/DVD Boot",
}
mode = (sys.argv[1] if len(sys.argv) > 1 else "status").lower()
host = sys.argv[2] if len(sys.argv) > 2 else "localhost"
port = sys.argv[3] if len(sys.argv) > 3 else "16993"
user = "admin"
pw   = _parola()
if not pw:
    sys.exit("HATA: parola bulunamadi. AMT_PASSWORD ver ya da Keychain'e kaydet:\n"
             "  security add-generic-password -a \"$USER\" -s marvin-amt -w")
if mode not in MODES and mode not in ("status", "bios", "enum"):
    sys.exit(f"HATA: bilinmeyen kip '{mode}'. pxe | hdd | cd | bios | status | enum")

url = f"https://{host}:{port}/wsman"
NS = {
 "s":"http://www.w3.org/2003/05/soap-envelope",
 "a":"http://schemas.xmlsoap.org/ws/2004/08/addressing",
 "w":"http://schemas.dmtf.org/wbem/wsman/1/wsman.xsd",
}
CIM = "http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2"
AMT = "http://intel.com/wbem/wscim/1/amt-schema/1"

ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
mgr = urllib.request.HTTPPasswordMgrWithDefaultRealm(); mgr.add_password(None, url, user, pw)
opener = urllib.request.build_opener(
    urllib.request.HTTPSHandler(context=ctx),
    urllib.request.HTTPDigestAuthHandler(mgr),
    urllib.request.HTTPBasicAuthHandler(mgr))

def send(action, resource, selectors="", body=""):
    sel = ""
    if selectors:
        sel = f"<w:SelectorSet>{selectors}</w:SelectorSet>"
    env = f'''<?xml version="1.0" encoding="UTF-8"?>
<s:Envelope xmlns:s="{NS['s']}" xmlns:a="{NS['a']}" xmlns:w="{NS['w']}">
 <s:Header>
  <a:Action s:mustUnderstand="true">{action}</a:Action>
  <a:To s:mustUnderstand="true">{url}</a:To>
  <w:ResourceURI s:mustUnderstand="true">{resource}</w:ResourceURI>
  <a:MessageID s:mustUnderstand="true">uuid:{uuid.uuid4()}</a:MessageID>
  <a:ReplyTo><a:Address>http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous</a:Address></a:ReplyTo>
  <w:OperationTimeout>PT60.000S</w:OperationTimeout>
  {sel}
 </s:Header>
 <s:Body>{body}</s:Body>
</s:Envelope>'''
    req = urllib.request.Request(url, data=env.encode(),
        headers={"Content-Type":"application/soap+xml;charset=UTF-8"}, method="POST")
    import time
    son = None
    for deneme in range(3):
        try:
            return opener.open(req, timeout=40).read().decode("utf-8","replace")
        except urllib.error.HTTPError as e:
            return e.read().decode("utf-8","replace")
        except Exception as e:
            # AMT ardisik isteklerde baglantiyi dusurebiliyor; kisa bekleyip tekrar dene.
            son = e
            time.sleep(1.5 * (deneme + 1))
    raise son

def enumerate_cls(resource):
    """Enumerate -> Pull. Enumerate yalnizca bir baglam dondurur;
    ogeleri almak icin ayrica Pull cagrilmalidir."""
    ENUM = "http://schemas.xmlsoap.org/ws/2004/09/enumeration"
    r = send(f"{ENUM}/Enumerate", resource,
             body=f'<e:Enumerate xmlns:e="{ENUM}"/>')
    m = re.search(r"<[^>]*:EnumerationContext>([^<]*)</[^>]*:EnumerationContext>", r)
    if not m:
        return r
    ctx_id, parcalar = m.group(1), []
    for _ in range(10):                       # sayfali cevaplari topla
        pr = send(f"{ENUM}/Pull", resource,
                  body=(f'<e:Pull xmlns:e="{ENUM}">'
                        f'<e:EnumerationContext>{ctx_id}</e:EnumerationContext>'
                        f'<e:MaxElements>64</e:MaxElements></e:Pull>'))
        parcalar.append(pr)
        if "EndOfSequence" in pr:
            break
        m2 = re.search(r"<[^>]*:EnumerationContext>([^<]*)</[^>]*:EnumerationContext>", pr)
        if not m2:
            break
        ctx_id = m2.group(1)
    return "\n".join(parcalar)

def rc(xml, name="ReturnValue"):
    m = re.search(rf"<[^>]*:{name}>([^<]*)</[^>]*:{name}>", xml)
    return m.group(1) if m else None

def show_fault(xml, label=""):
    reason = re.search(r"<[^>]*:Text[^>]*>([^<]*)<", xml)
    code   = re.search(r"<[^>]*:Subcode>\s*<[^>]*:Value>([^<]*)<", xml)
    detail = re.search(r"<[^>]*:Detail>(.*?)</[^>]*:Detail>", xml, re.S)
    if reason: print(f"       sebep  : {reason.group(1).strip()}")
    if code:   print(f"       kod    : {code.group(1).strip()}")
    if detail:
        d = re.sub(r"<[^>]+>", " ", detail.group(1))
        d = " ".join(d.split())
        if d: print(f"       ayrinti: {d[:300]}")
    if os.environ.get("AMT_DEBUG") == "1":
        print("       --- ham cevap ---")
        print(xml[:2000])

# ---- durum ----
power = send("http://schemas.xmlsoap.org/ws/2004/09/transfer/Get",
             f"{CIM}/CIM_AssociatedPowerManagementService")
ps = rc(power, "PowerState")
DURUMLAR = {"2":"Acik (On)","3":"Uyku","4":"Uyku","6":"Kapali (Off-Hard)",
            "7":"Hazirda","8":"Kapali (Off-Soft)","9":"Guc kesik","13":"Kapali"}
print(f"Guc durumu: {DURUMLAR.get(ps, ps or '?')}")

if mode == "enum":
    print("\n--- CIM_BootSourceSetting (acilabilecek kaynaklar) ---")
    x = enumerate_cls(f"{CIM}/CIM_BootSourceSetting")
    ids = re.findall(r"<[^>]*:InstanceID>([^<]*)</[^>]*:InstanceID>", x)
    ids += [v for v in re.findall(r'<w:Selector Name="InstanceID">([^<]*)</w:Selector>', x)]
    ids = list(dict.fromkeys(ids))
    if ids:
        for i in ids: print(f"    {i}")
    else:
        print("    (ayristirilamadi, ham cevap:)"); print(x[:1200])
    print("\n--- CIM_BootConfigSetting (boot yapilandirmasi) ---")
    y = enumerate_cls(f"{CIM}/CIM_BootConfigSetting")
    ids2 = re.findall(r"<[^>]*:InstanceID>([^<]*)</[^>]*:InstanceID>", y)
    for i in ids2 or []: print(f"    {i}")
    if not ids2: print(y[:800])
    print("\n--- CIM_BootService (servis adi) ---")
    z = enumerate_cls(f"{CIM}/CIM_BootService")
    for n in re.findall(r"<[^>]*:Name>([^<]*)</[^>]*:Name>", z) or []: print(f"    {n}")
    sys.exit(0)

if mode == "status":
    caps = send("http://schemas.xmlsoap.org/ws/2004/09/transfer/Get", f"{AMT}/AMT_BootSettingData")
    for f in ("BIOSSetup","BIOSPause","UseSOL","UseIDER","BootMediaIndex"):
        v = rc(caps, f)
        if v is not None: print(f"  {f:16s}: {v}")
    sys.exit(0)

print(f"\nHedef kip: {mode}")

# 1) BootSettingData — YALNIZCA ekstra gerekiyorsa (SOL / IDER / BIOS ekrani).
# Duz PXE icin gerekli DEGIL; bu firmware PUT'u sema hatasiyla reddediyor ve
# gereksiz yere zinciri kirmasin diye varsayilan olarak atlaniyor.
if mode == "bios" or os.environ.get("AMT_SOL") == "1" or os.environ.get("AMT_BOOTDATA") == "1":
    cur = send("http://schemas.xmlsoap.org/ws/2004/09/transfer/Get", f"{AMT}/AMT_BootSettingData")
    m = re.search(r"(<[a-zA-Z0-9]+:AMT_BootSettingData\b.*?</[a-zA-Z0-9]+:AMT_BootSettingData>)", cur, re.S)
    if m:
        obj = m.group(1)
        def setf(x, ad, deger):
            return re.sub(rf"(<([a-zA-Z0-9]+):{ad}>)[^<]*(</[a-zA-Z0-9]+:{ad}>)", rf"\g<1>{deger}\g<3>", x)
        obj = setf(obj, "BIOSSetup", "true" if mode == "bios" else "false")
        obj = setf(obj, "UseSOL", "true" if os.environ.get("AMT_SOL") == "1" else "false")
        r1 = send("http://schemas.xmlsoap.org/ws/2004/09/transfer/Put", f"{AMT}/AMT_BootSettingData", body=obj)
        print("  1) BootSettingData : " + ("OK" if "Fault" not in r1 else "HATA"))
        if "Fault" in r1: show_fault(r1, "     ")
    else:
        print("  1) BootSettingData : HATA — mevcut nesne okunamadi")
else:
    print("  1) BootSettingData : atlandi (duz boot icin gerekmiyor)")

# 2) ChangeBootOrder
if mode == "bios":
    order_body = f'<r:ChangeBootOrder_INPUT xmlns:r="{CIM}/CIM_BootConfigSetting"/>'
else:
    src = MODES[mode]
    order_body = f'''<r:ChangeBootOrder_INPUT xmlns:r="{CIM}/CIM_BootConfigSetting"
      xmlns:a="{NS['a']}" xmlns:w="{NS['w']}">
 <r:Source>
  <a:Address>http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous</a:Address>
  <a:ReferenceParameters>
   <w:ResourceURI>{CIM}/CIM_BootSourceSetting</w:ResourceURI>
   <w:SelectorSet><w:Selector Name="InstanceID">{src}</w:Selector></w:SelectorSet>
  </a:ReferenceParameters>
 </r:Source>
</r:ChangeBootOrder_INPUT>'''
sel = '<w:Selector Name="InstanceID">Intel(r) AMT: Boot Configuration 0</w:Selector>'
r2 = send(f"{CIM}/CIM_BootConfigSetting/ChangeBootOrder",
          f"{CIM}/CIM_BootConfigSetting", selectors=sel, body=order_body)
v2 = rc(r2)
print(f"  2) ChangeBootOrder : {'OK' if v2=='0' else 'HATA (ReturnValue=%s)' % v2}")
if "Fault" in r2: show_fault(r2)

# 3) SetBootConfigRole = 1 (bir sonraki acilista, tek seferlik)
role_body = f'''<r:SetBootConfigRole_INPUT xmlns:r="{CIM}/CIM_BootService"
   xmlns:a="{NS['a']}" xmlns:w="{NS['w']}">
 <r:BootConfigSetting>
  <a:Address>http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous</a:Address>
  <a:ReferenceParameters>
   <w:ResourceURI>{CIM}/CIM_BootConfigSetting</w:ResourceURI>
   <w:SelectorSet><w:Selector Name="InstanceID">Intel(r) AMT: Boot Configuration 0</w:Selector></w:SelectorSet>
  </a:ReferenceParameters>
 </r:BootConfigSetting>
 <r:Role>1</r:Role>
</r:SetBootConfigRole_INPUT>'''
r3 = send(f"{CIM}/CIM_BootService/SetBootConfigRole", f"{CIM}/CIM_BootService",
          selectors='<w:Selector Name="Name">Intel(r) AMT Boot Service</w:Selector>',
          body=role_body)
v3 = rc(r3)
print(f"  3) SetBootConfigRole: {'OK' if v3=='0' else 'HATA (ReturnValue=%s)' % v3}")
if "Fault" in r3: show_fault(r3)

# 4) Reset (PowerState 10 = Master Bus Reset), kapaliysa 2 = On
state = "2" if ps in ("6","8","9","13") else "10"
pw_body = f'''<r:RequestPowerStateChange_INPUT xmlns:r="{CIM}/CIM_PowerManagementService"
   xmlns:a="{NS['a']}" xmlns:w="{NS['w']}">
 <r:PowerState>{state}</r:PowerState>
 <r:ManagedElement>
  <a:Address>http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous</a:Address>
  <a:ReferenceParameters>
   <w:ResourceURI>{CIM}/CIM_ComputerSystem</w:ResourceURI>
   <w:SelectorSet>
    <w:Selector Name="Name">ManagedSystem</w:Selector>
தu   </w:SelectorSet>
  </a:ReferenceParameters>
 </r:ManagedElement>
</r:RequestPowerStateChange_INPUT>'''.replace("தu","")
if os.environ.get("AMT_NORESET") == "1":
    print("  4) Reset             : ATLANDI (AMT_NORESET=1)")
    print("\nBoot sirasi ayarlandi; reset atilmadi. Tetiklemek icin: amt " + mode)
    sys.exit(0 if (v2 == "0" and v3 == "0") else 1)

r4 = send(f"{CIM}/CIM_PowerManagementService/RequestPowerStateChange",
          f"{CIM}/CIM_PowerManagementService",
          selectors='<w:Selector Name="Name">Intel(r) AMT Power Management Service</w:Selector>',
          body=pw_body)
v4 = rc(r4)
eylem = "Guc ver (On)" if state == "2" else "Reset"
print(f"  4) {eylem:19s}: {'OK' if v4 in ('0','4096') else 'HATA (ReturnValue=%s)' % v4}")
if "Fault" in r4: show_fault(r4)

if v2 == "0" and v3 == "0" and v4 in ("0","4096"):
    print(f"\nTAMAM — makine bir sonraki acilista '{mode}' aygitindan acacak (tek seferlik).")
else:
    print("\nAdimlardan biri basarisiz. Yukaridaki ReturnValue/HATA satirlarina bak.")
