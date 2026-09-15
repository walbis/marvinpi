# MeshCentral — sunucu taraflı IDER (ISO Pi'de durur)

**Neden:** MeshCommander'ın IDER'i **tarayıcıda** çalışır (`default.htm`), Node sunucusu
yalnızca ham TLS borusudur. Yani ISO, tarayıcının olduğu makinede olmak zorundadır ve
kurtarma laptopa bağımlı kalır. 15 Eyl 2026'da ofisten çıkınca bu sorun yaşandı:
ISO akışı yavaş bağlantıya takıldı.

MeshCentral IDER'i **sunucuda** yapar. `amt/amt-ider-module.js`:
```js
var stats = fs.statSync(cdromPath);
obj.cdrom = { size: stats.size, ptr: fs.openSync(cdromPath, 'r') };
```
Dosyayı sunucu açar; tarayıcı yalnızca tetikler. Web arayüzünde **"From server file"**.

## Kurulum
- Pi'de `/opt/meshcentral`, npm paketi `meshcentral`
- systemd: `meshcentral.service` (bu dizindeki dosya)
- Yapılandırma: `config.json` (bu dizinde) → `/opt/meshcentral/meshcentral-data/config.json`
- Adres: **https://100.101.117.47:4430** (ilk kayıt yönetici olur)
- ISO: `/opt/meshcentral/meshcentral-files/marvin-v3.iso`

## Tuzaklar
- **`allowedorigin` `settings` altında DEĞİL, `domains[""]` altındadır** ve
  **port içermez** — kod `originUrl.hostname` ile karşılaştırır. Yanlış yere
  yazılırsa "Invalid origin in HTTP request" alırsın.
- **`meshcmd.js` düz Node'da IDER YAPAMAZ.** `amt-wsman-duk` ve `amt-redir-duk`
  MeshAgent'ın duktape motoruna aittir, npm'de yoktur. Komut satırından
  betiklenebilir IDER bu yolla mümkün değil; web arayüzü kullanılmalı.
- `meshcmd` parametreleri: `--action X --hostname H --username U --password P`
  (yardım metni `--pass` der ama kod `--password` bekler; eylem `argv[1]`'de
  arandığı için `node meshcmd.js X` biçimi çalışmaz).

## Durum
Kurulu ve ayakta. **Sunucu taraflı IDER oturumu henüz test edilmedi** — kod
sunucudan okuduğunu gösteriyor ama gerçek oturum açılmadı. Test etmek makineyi
yeniden kurmak demek (IDER + reboot = sistem diski silinir).
