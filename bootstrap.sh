#!/usr/bin/env bash
# ============================================================
#  bootstrap.sh — marvin (LLM test makinesi) kurulum / kurtarma
#  Hedef: Debian 13 (trixie) · NVIDIA GPU · LM Studio
#
#  Kurar: NVIDIA sürücü → model diski → LM Studio + systemd →
#         güç ayarları → ufw → Wake-on-LAN → özet
#
#  Tailscale YOK, auth key YOK. Makine kasten tailnet dışındadır;
#  dışarıdan erişim Pi (Tailscale subnet router) üzerinden LAN'a düşer.
#
#  Idempotent: kaç kere çalıştırırsan çalıştır, güvenli.
#  Var olan modelleri, dolu dizinleri ve çalışan servisi bozmaz.
#
#  Kullanım (format sonrası / ilk kurulum):
#    sudo bash bootstrap.sh
#  Sürücü kurulumundan sonra kendisi yeniden başlatsın istersen:
#    sudo AUTO_REBOOT=1 bash bootstrap.sh
# ============================================================
set -euo pipefail

# ---------- AYARLAR (env ile ezilebilir) ----------
TARGET_USER="${TARGET_USER:-${SUDO_USER:-marvin}}"   # LM Studio bu kullanıcıya kurulur
MODELS_LABEL="${MODELS_LABEL:-SILME-MODELLER}"       # model diskinin etiketi
MOUNT_POINT="${MOUNT_POINT:-/mnt/models}"
LMS_PORT="${LMS_PORT:-1234}"
LMS_BIND="${LMS_BIND:-0.0.0.0}"
LAN_CIDR="${LAN_CIDR:-192.168.1.0/24}"               # ufw'de serbest bırakılacak ağ
IFACE="${IFACE:-}"                                   # boşsa varsayılan rota arayüzü
AUTO_REBOOT="${AUTO_REBOOT:-0}"                      # 1 → sürücü sonrası kendi reboot eder

log(){  echo -e "\n\033[1;32m==> $*\033[0m"; }
warn(){ echo -e "\033[1;33m!!  $*\033[0m" >&2; }
die(){  echo -e "\033[1;31mHATA: $*\033[0m" >&2; exit 1; }

# Dosyayı sadece içeriği değiştiyse yaz. Değiştiyse 0, aynıysa 1 döner.
write_if_changed(){
  local path="$1" tmp rc=0
  tmp="$(mktemp)"
  cat > "$tmp"
  if [[ -f "$path" ]] && cmp -s "$tmp" "$path"; then
    rc=1
  else
    install -D -m 0644 "$tmp" "$path"
  fi
  rm -f "$tmp"
  return $rc
}

# ---------- 0) Ön kontroller ----------
[[ $EUID -eq 0 ]] || die "Root gerekli: sudo bash bootstrap.sh"
[[ -f /etc/debian_version ]] || die "Bu script Debian içindir."

id "$TARGET_USER" >/dev/null 2>&1 || die "Kullanıcı yok: $TARGET_USER (TARGET_USER=... ile ver)"
USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -n "$USER_HOME" && -d "$USER_HOME" ]] || die "$TARGET_USER için ev dizini bulunamadı."
LMS_BIN="$USER_HOME/.lmstudio/bin/lms"

log "Hedef kullanıcı: $TARGET_USER ($USER_HOME)"

if ! command -v curl >/dev/null 2>&1; then
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates
fi

# ---------- 1) NVIDIA sürücüsü ----------
gpu_ready(){ command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; }
driver_pkg_installed(){
  dpkg-query -W -f='${Status}' nvidia-driver 2>/dev/null | grep -q "install ok installed"
}

if gpu_ready; then
  log "GPU hazır: $(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader)"
elif driver_pkg_installed; then
  # Paket kurulu ama çekirdek modülü yüklenmemiş → tek eksik reboot.
  warn "NVIDIA sürücüsü kurulu ama etkin değil. Yeniden başlatma gerekiyor."
  if [[ "$AUTO_REBOOT" == "1" ]]; then
    log "AUTO_REBOOT=1 → yeniden başlatılıyor. Açılıştan sonra bu script'i tekrar çalıştır."
    sleep 3; systemctl reboot; exit 0
  fi
  echo "*** Makineyi yeniden başlat, sonra bu script'i aynen tekrar çalıştır. ***"
  exit 0
else
  log "NVIDIA sürücüsü yok; non-free bileşenler açılıp kuruluyor..."
  # Debian 13 deb822 biçimi
  for f in /etc/apt/sources.list.d/*.sources; do
    [[ -f "$f" ]] || continue
    if grep -q '^Components:' "$f" && ! grep -q '^Components:.*non-free-firmware' "$f"; then
      sed -Ei 's/^Components:.*/Components: main contrib non-free non-free-firmware/' "$f"
    fi
  done
  # Klasik tek satır biçimi
  if [[ -f /etc/apt/sources.list ]] && \
     grep -qE '^deb[[:space:]].*[[:space:]]main([[:space:]]|$)' /etc/apt/sources.list && \
     ! grep -qE '^deb[[:space:]].*non-free-firmware' /etc/apt/sources.list; then
    sed -Ei 's/^(deb[[:space:]].*[[:space:]]main)([[:space:]].*)?$/\1 contrib non-free non-free-firmware/' \
      /etc/apt/sources.list
  fi
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y nvidia-driver firmware-misc-nonfree
  if [[ "$AUTO_REBOOT" == "1" ]]; then
    log "Sürücü kuruldu. AUTO_REBOOT=1 → yeniden başlatılıyor; açılışta script'i tekrar çalıştır."
    sleep 3; systemctl reboot; exit 0
  fi
  echo
  echo "*** Sürücü kuruldu. Makineyi YENİDEN BAŞLAT, sonra bu script'i aynen tekrar çalıştır. ***"
  exit 0
fi

# ---------- 2) Model diski (SILME-MODELLER → /mnt/models) ----------
# Disk yoksa kurulum durmaz; ama modeller sistem diskine YAZILMAZ (bkz. adım 3).
MODELS_OK=0
mkdir -p "$MOUNT_POINT"

if findmnt -rn "$MOUNT_POINT" >/dev/null 2>&1; then
  MODELS_OK=1
  log "Model diski zaten bağlı: $MOUNT_POINT ($(findmnt -rno SOURCE "$MOUNT_POINT"))"
elif [[ -e "/dev/disk/by-label/$MODELS_LABEL" ]]; then
  log "'$MODELS_LABEL' bulundu, $MOUNT_POINT altına bağlanıyor..."
  mount "/dev/disk/by-label/$MODELS_LABEL" "$MOUNT_POINT"
  MODELS_OK=1
else
  warn "'$MODELS_LABEL' etiketli disk YOK. Model diski olmadan devam ediliyor."
  warn "Diski taktıysan: lsblk ile kontrol et, etiket 'e2label /dev/... $MODELS_LABEL' ile verilir."
fi

# fstab kaydı — sadece bu bağlama noktası için kayıt yoksa eklenir. Disk yoksa da
# yazılır ki disk sonradan takıldığında açılışta kendiliğinden bağlansın (nofail).
if ! grep -qE "^[^#]*[[:space:]]$MOUNT_POINT[[:space:]]" /etc/fstab; then
  log "fstab kaydı ekleniyor (nofail — disk yoksa açılış takılmaz)."
  printf 'LABEL=%s %s ext4 defaults,nofail 0 2\n' "$MODELS_LABEL" "$MOUNT_POINT" >> /etc/fstab
  systemctl daemon-reload
fi

# ---------- 3) LM Studio + PATH + model dizini ----------
if [[ ! -x "$LMS_BIN" ]]; then
  log "LM Studio kuruluyor ($TARGET_USER kullanıcısına)..."
  # ÖNEMLİ: root olarak kurulursa /root/.lmstudio'ya gider ve servis çalışmaz.
  sudo -u "$TARGET_USER" -H bash -c 'curl -fsSL https://lmstudio.ai/install.sh | bash'
  [[ -x "$LMS_BIN" ]] || die "LM Studio kurulumu tamamlanamadı: $LMS_BIN yok."
else
  log "LM Studio zaten kurulu: $LMS_BIN"
fi

# PATH — tek dosyada, her çalıştırmada üzerine yazılır.
# (~/.bashrc'ye eklemek tekrar tekrar çalıştırıldığında satır yığar.)
if write_if_changed /etc/profile.d/lmstudio.sh <<EOF
# bootstrap.sh tarafından yönetilir — elle düzenleme.
# /usr/sbin: blkid, ethtool, ldconfig gibi araçlar için gerekli.
case ":\$PATH:" in
  *":$USER_HOME/.lmstudio/bin:"*) ;;
  *) PATH="$USER_HOME/.lmstudio/bin:\$PATH" ;;
esac
case ":\$PATH:" in
  *":/usr/sbin:"*) ;;
  *) PATH="\$PATH:/usr/sbin" ;;
esac
export PATH
EOF
then log "PATH ayarlandı: /etc/profile.d/lmstudio.sh"; fi

# Model dizini symlink'i — /mnt/models bağlı DEĞİLSE kurulmaz.
# Aksi hâlde LM Studio modelleri sistem diskindeki boş klasöre indirir:
# hem sda dolar hem de format sırasında modeller uçar (diskin tüm amacı buydu).
LMS_MODELS_DIR="$USER_HOME/.lmstudio/models"
if [[ "$MODELS_OK" == "1" ]]; then
  install -d -o "$TARGET_USER" -g "$TARGET_USER" "$MOUNT_POINT/lmstudio"
  if [[ -L "$LMS_MODELS_DIR" ]]; then
    if [[ "$(readlink -f "$LMS_MODELS_DIR")" == "$MOUNT_POINT/lmstudio" ]]; then
      log "Model symlink'i zaten doğru: $LMS_MODELS_DIR → $MOUNT_POINT/lmstudio"
    else
      warn "Symlink başka yeri gösteriyordu, düzeltiliyor."
      ln -sfn "$MOUNT_POINT/lmstudio" "$LMS_MODELS_DIR"
    fi
  elif [[ -d "$LMS_MODELS_DIR" ]]; then
    if [[ -z "$(ls -A "$LMS_MODELS_DIR" 2>/dev/null)" ]]; then
      rmdir "$LMS_MODELS_DIR"
      ln -sfn "$MOUNT_POINT/lmstudio" "$LMS_MODELS_DIR"
      log "Boş model dizini symlink'e çevrildi."
    else
      # Dolu gerçek dizin: içinde model olabilir, dokunmuyoruz.
      warn "$LMS_MODELS_DIR dolu bir DİZİN (symlink değil). İçeriği korumak için dokunulmadı."
      warn "Modelleri diske taşımak istersen elle:"
      warn "  systemctl stop lmstudio"
      warn "  rsync -a --remove-source-files $LMS_MODELS_DIR/ $MOUNT_POINT/lmstudio/"
      warn "  rmdir $LMS_MODELS_DIR && ln -s $MOUNT_POINT/lmstudio $LMS_MODELS_DIR"
    fi
  else
    ln -sfn "$MOUNT_POINT/lmstudio" "$LMS_MODELS_DIR"
    log "Model symlink'i kuruldu: $LMS_MODELS_DIR → $MOUNT_POINT/lmstudio"
  fi
else
  warn "Model diski bağlı değil → symlink KURULMADI (modeller sistem diskine yazılmasın diye)."
fi

# ---------- 4) systemd: lmstudio.service ----------
# Not: 'lms server start' arka plana çatallanır, bu yüzden Type=oneshot +
# RemainAfterExit=yes. Sunucudan önce 'lms daemon up' şart.
UNIT_CHANGED=0
if write_if_changed /etc/systemd/system/lmstudio.service <<EOF
[Unit]
Description=LM Studio Server
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=$TARGET_USER
Environment="HOME=$USER_HOME"
Environment="LMS_SERVER_HOST=$LMS_BIND"
ExecStartPre=$LMS_BIN daemon up
ExecStart=$LMS_BIN server start --bind $LMS_BIND --port $LMS_PORT
ExecStop=$LMS_BIN daemon down

[Install]
WantedBy=multi-user.target
EOF
then UNIT_CHANGED=1; log "lmstudio.service yazıldı."; else log "lmstudio.service zaten güncel."; fi

systemctl daemon-reload
systemctl enable lmstudio >/dev/null 2>&1 || true
if [[ "$UNIT_CHANGED" == "1" ]]; then
  systemctl restart lmstudio || warn "lmstudio başlatılamadı: journalctl -u lmstudio -n 50"
elif ! systemctl is-active --quiet lmstudio; then
  systemctl start lmstudio || warn "lmstudio başlatılamadı: journalctl -u lmstudio -n 50"
else
  # Çalışıyor ve unit aynı: yüklü modeli düşürmemek için dokunma.
  log "lmstudio çalışıyor, yeniden başlatılmadı."
fi

# ---------- 5) Uyku kapalı, grafik arayüz kapalı ----------
log "Güç ayarları: uyku hedefleri mask, varsayılan hedef multi-user."
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target >/dev/null 2>&1 || true
systemctl set-default multi-user.target >/dev/null 2>&1 || true

# ---------- 6) Güvenlik duvarı ----------
# SIRA HAYATİ: önce izin kuralları, EN SON enable/default.
# ufw zaten etkinken 'default deny' vermek anında tüm TCP'yi düşürür ve
# script'i çalıştıran SSH oturumunu da kesebilir; izinler o an henüz
# yazılmamışsa makine ağdan tamamen kilitlenir (ping açık, TCP kapalı).
if ! command -v ufw >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw
fi
log "ufw: $LAN_CIDR için 22 ve $LMS_PORT açılıyor."

# 1) Önce izin kuralları (ufw kapalıyken de yazılabilir, risksiz).
ufw allow from "$LAN_CIDR" to any port 22          proto tcp >/dev/null
ufw allow from "$LAN_CIDR" to any port "$LMS_PORT" proto tcp >/dev/null

# 2) Kuralların gerçekten yazıldığını doğrula. Yazılmadıysa güvenlik
#    duvarına HİÇ dokunma — kilitli makine, kapalı porttan iyidir.
if ufw show added 2>/dev/null | grep -q "port 22"; then
  # 3) Varsayılanlar ve enable ancak izinler hazırken.
  ufw default deny incoming  >/dev/null
  ufw default allow outgoing >/dev/null
  ufw --force enable >/dev/null
  log "ufw etkin. Açık: $LAN_CIDR → 22, $LMS_PORT"
else
  warn "ufw izin kuralları eklenemedi → güvenlik duvarı DEĞİŞTİRİLMEDİ."
  warn "Kilitlenmemek için ufw olduğu gibi bırakıldı. Elle kontrol: ufw status verbose"
fi

# ---------- 7) Wake-on-LAN (kalıcı) ----------
if ! command -v ethtool >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ethtool
fi
[[ -n "$IFACE" ]] || IFACE="$(ip -o route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')"
[[ -n "$IFACE" ]] || IFACE="$(ls /sys/class/net | grep -E '^(en|eth)' | head -n1)"

if [[ -n "$IFACE" && -e "/sys/class/net/$IFACE" ]]; then
  MAC_ADDR="$(cat "/sys/class/net/$IFACE/address")"
  if write_if_changed /etc/systemd/system/wol.service <<EOF
[Unit]
Description=Wake-on-LAN arm ($IFACE)
After=network.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/ethtool -s $IFACE wol g
[Install]
WantedBy=multi-user.target
EOF
  then systemctl daemon-reload; fi
  systemctl enable --now wol.service >/dev/null 2>&1 || warn "wol.service etkinleştirilemedi."
  # DİKKAT: ethtool çıktısında 'Wake-on:' iki kez geçer —
  #   "Supports Wake-on: pumbg"  (kartın YETENEĞİ)
  #   "Wake-on: g"               (AKTİF ayar)
  # Desen satır başına sabitlenmezse ilkine takılır ve saçma değer okunur.
  WOL_SUPPORTED="$(ethtool "$IFACE" 2>/dev/null | awk '/Supports Wake-on:/{print $3; exit}')"
  WOL_STATE="$(ethtool "$IFACE" 2>/dev/null | awk '/^[[:space:]]*Wake-on:/{print $2; exit}')"
  log "Wake-on-LAN: $IFACE ($MAC_ADDR) → Wake-on=${WOL_STATE:-?} (destek: ${WOL_SUPPORTED:-?})"
  if [[ "$WOL_STATE" == *g* ]]; then
    :
  elif [[ "$WOL_SUPPORTED" != *g* ]]; then
    warn "Kart magic packet (g) DESTEKLEMİYOR (destek: ${WOL_SUPPORTED:-?}). WoL bu arayüzde çalışmaz."
  else
    warn "WoL 'g' değil (şu an: ${WOL_STATE:-?}). BIOS'ta da açık olmalı (Power On By PCI-E)."
  fi
else
  MAC_ADDR="?"; WOL_STATE="?"
  warn "Ethernet arayüzü bulunamadı, WoL atlandı."
fi

# ---------- 8) Özet ----------
LAN_IP="$(ip -o -4 addr show "${IFACE:-}" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
[[ -n "$LAN_IP" ]] || LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"

if [[ "$MODELS_OK" == "1" ]]; then
  MODELS_STATE="BAĞLI  ($(df -h "$MOUNT_POINT" | awk 'NR==2{print $3" kullanilan / "$2" toplam"}'))"
  MODELS_COUNT="$(find "$MOUNT_POINT/lmstudio" -name '*.gguf' 2>/dev/null | wc -l | tr -d ' ') adet .gguf"
else
  MODELS_STATE="YOK — '$MODELS_LABEL' etiketli disk bulunamadi"
  MODELS_COUNT="symlink kurulmadi"
fi

SVC_STATE="$(systemctl is-active lmstudio 2>&1) / $(systemctl is-enabled lmstudio 2>&1)"

cat <<SUMMARY

============================================================
 KURULUM TAMAM — marvin
------------------------------------------------------------
 LAN IP        : ${LAN_IP:-?}   (arayüz: ${IFACE:-?})
 MAC           : ${MAC_ADDR}    (WoL: ${WOL_STATE})
 GPU           : $(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null || echo '?')
 Model diski   : ${MODELS_STATE}
 Modeller      : ${MODELS_COUNT}
 lmstudio      : ${SVC_STATE}
 Endpoint      : http://${LAN_IP:-?}:${LMS_PORT}/v1

 Pi'den hızlı test:
   curl -s http://${LAN_IP:-?}:${LMS_PORT}/v1/models

 Makineyi uzaktan uyandırma (Pi'den):
   sudo etherwake -i eth0 ${MAC_ADDR}
 Kapalıysa AMT: https://${LAN_IP:-?}:16993   (16992 kapalıdır, hep 16993)
============================================================
SUMMARY

# Kendi kendine canlılık testi
if curl -fsS --max-time 10 "http://127.0.0.1:$LMS_PORT/v1/models" >/dev/null 2>&1; then
  log "Doğrulandı: LM Studio $LMS_PORT portunda cevap veriyor."
else
  warn "LM Studio $LMS_PORT portunda cevap vermedi. Model yüklenirken ilk açılış uzun sürebilir."
  warn "Kontrol: systemctl status lmstudio ; journalctl -u lmstudio -n 50"
fi
