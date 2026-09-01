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

MODES = {
    "pxe":  "Intel(r) AMT: Force PXE Boot",
    "hdd":  "Intel(r) AMT: Force Hard-drive Boot",
    "cd":   "Intel(r) AMT: Force CD/DVD Boot",
}
mode = (sys.argv[1] if len(sys.argv) > 1 else "status").lower()
host = sys.argv[2] if len(sys.argv) > 2 else "localhost"
port = sys.argv[3] if len(sys.argv) > 3 else "16993"
user = "admin"
pw   = os.environ.get("AMT_PASSWORD")
if not pw:
    sys.exit("HATA: AMT_PASSWORD bos.")
if mode not in MODES and mode not in ("status", "bios"):
    sys.exit(f"HATA: bilinmeyen kip '{mode}'. pxe | hdd | cd | bios | status")

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
    try:
        return opener.open(req, timeout=40).read().decode("utf-8","replace")
    except urllib.error.HTTPError as e:
        return e.read().decode("utf-8","replace")

def rc(xml, name="ReturnValue"):
    m = re.search(rf"<[^>]*:{name}>([^<]*)</[^>]*:{name}>", xml)
    return m.group(1) if m else None

def show_fault(xml, label):
    reason = re.search(r"<[^>]*:Text[^>]*>([^<]*)<", xml)
    print(f"    {label}: HATA" + (f" — {reason.group(1).strip()}" if reason else ""))

# ---- durum ----
power = send("http://schemas.xmlsoap.org/ws/2004/09/transfer/Get",
             f"{CIM}/CIM_AssociatedPowerManagementService")
ps = rc(power, "PowerState")
DURUMLAR = {"2":"Acik (On)","3":"Uyku","4":"Uyku","6":"Kapali (Off-Hard)",
            "7":"Hazirda","8":"Kapali (Off-Soft)","9":"Guc kesik","13":"Kapali"}
print(f"Guc durumu: {DURUMLAR.get(ps, ps or '?')}")

if mode == "status":
    caps = send("http://schemas.xmlsoap.org/ws/2004/09/transfer/Get", f"{AMT}/AMT_BootSettingData")
    for f in ("BIOSSetup","BIOSPause","UseSOL","UseIDER","BootMediaIndex"):
        v = rc(caps, f)
        if v is not None: print(f"  {f:16s}: {v}")
    sys.exit(0)

print(f"\nHedef kip: {mode}")

# 1) BootSettingData — sade zorlama (SOL/IDER kapali, BIOS ekrani yok)
bios_setup = "true" if mode == "bios" else "false"
put_body = f'''<r:AMT_BootSettingData xmlns:r="{AMT}/AMT_BootSettingData">
 <r:ElementName>Intel(r) AMT Boot Configuration Settings</r:ElementName>
 <r:InstanceID>Intel(r) AMT:BootSettingData 0</r:InstanceID>
 <r:BIOSPause>false</r:BIOSPause>
 <r:BIOSSetup>{bios_setup}</r:BIOSSetup>
 <r:BootMediaIndex>0</r:BootMediaIndex>
 <r:ConfigurationDataReset>false</r:ConfigurationDataReset>
 <r:FirmwareVerbosity>0</r:FirmwareVerbosity>
 <r:ForcedProgressEvents>false</r:ForcedProgressEvents>
 <r:IDERBootDevice>0</r:IDERBootDevice>
 <r:LockKeyboard>false</r:LockKeyboard>
 <r:LockPowerButton>false</r:LockPowerButton>
 <r:LockResetButton>false</r:LockResetButton>
 <r:LockSleepButton>false</r:LockSleepButton>
 <r:ReflashBIOS>false</r:ReflashBIOS>
 <r:UseIDER>false</r:UseIDER>
 <r:UseSOL>false</r:UseSOL>
 <r:UseSafeMode>false</r:UseSafeMode>
 <r:UserPasswordBypass>false</r:UserPasswordBypass>
</r:AMT_BootSettingData>'''
r1 = send("http://schemas.xmlsoap.org/ws/2004/09/transfer/Put",
          f"{AMT}/AMT_BootSettingData", body=put_body)
print("  1) BootSettingData : " + ("OK" if "AMT_BootSettingData" in r1 and "Fault" not in r1 else "HATA"))
if "Fault" in r1: show_fault(r1, "     ")

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
if "Fault" in r2: show_fault(r2, "     ")

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
if "Fault" in r3: show_fault(r3, "     ")

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
r4 = send(f"{CIM}/CIM_PowerManagementService/RequestPowerStateChange",
          f"{CIM}/CIM_PowerManagementService",
          selectors='<w:Selector Name="Name">Intel(r) AMT Power Management Service</w:Selector>',
          body=pw_body)
v4 = rc(r4)
eylem = "Guc ver (On)" if state == "2" else "Reset"
print(f"  4) {eylem:19s}: {'OK' if v4 in ('0','4096') else 'HATA (ReturnValue=%s)' % v4}")
if "Fault" in r4: show_fault(r4, "     ")

if v2 == "0" and v3 == "0" and v4 in ("0","4096"):
    print(f"\nTAMAM — makine bir sonraki acilista '{mode}' aygitindan acacak (tek seferlik).")
else:
    print("\nAdimlardan biri basarisiz. Yukaridaki ReturnValue/HATA satirlarina bak.")
