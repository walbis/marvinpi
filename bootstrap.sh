#!/usr/bin/env bash
# ============================================================
#  bootstrap.sh — marvin (LLM test makinesi) kurulum / kurtarma
#  Hedef: Debian 13 (trixie) · NVIDIA GPU · LM Studio
#
#  Kurar: NVIDIA sürücü → model diski → LM Studio + systemd →
#         güç ayarları → ufw → Wake-on-LAN → SSH anahtarı →
#         eğitim ortamı (venv + llama.cpp, NVMe önbellekli) → özet
#
#  Tailscale YOK, auth key YOK. Makine kasten tailnet dışındadır;
#  dışarıdan erişim Pi (Tailscale subnet router) üzerinden LAN'a düşer.
#
#  Idempotent: kaç kere çalıştırırsan çalıştır, güvenli.
#  Var olan modelleri, dolu dizinleri ve çalışan servisi bozmaz.
#
#  Model açılışta YÜKLENMEZ (17 Eyl 2026 kararı: GPU eğitim işleriyle
#  çakışmasın). İstek üzerine: lms-model load <anahtar>  (bkz. adım 10).
#
#  Kullanım (format sonrası / ilk kurulum):
#    sudo bash bootstrap.sh
#  Sürücü kurulumundan sonra kendisi yeniden başlatsın istersen:
#    sudo AUTO_REBOOT=1 bash bootstrap.sh
#  Eğitim ortamını atlamak için:  sudo EGITIM=0 bash bootstrap.sh
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
# Format sonrası SSH erişimini geri getiren public key listesi (Pi dosya sunucusu).
# Public key gizli bilgi değildir. Boş bırakılırsa bu adım tamamen atlanır.
AUTH_KEYS_URL="${AUTH_KEYS_URL:-http://192.168.1.166:8080/authorized_keys}"
# Açılışta sabitlenecek model. VARSAYILAN BOŞ: model açılışta yüklenmez, VRAM boş
# kalır (GPU eğitim işleri için). Yüklemek: lms-model load <anahtar>;
# eski davranışı isteyen: LMS_MODEL=qwen/qwen3.8-27b ya da 'lms-model pin'.
LMS_MODEL="${LMS_MODEL:-}"
LMS_CTX="${LMS_CTX:-8192}"
LMS_PARALLEL="${LMS_PARALLEL:-4}"
# JIT: true → model ilk istekte yüklenir ve TTL dolunca düşer.
# false → yalnızca açıkça yüklenen model yüklenir. false KALMALI: JIT açıkken
# eğitim sırasında LiteLLM'e gelen sıradan bir istek 17 GB modeli VRAM'e çeker
# ve eğitim işini OOM ile öldürür. Model yükleme kararı hep insanın olsun.
LMS_JIT="${LMS_JIT:-false}"
# ---- Eğitim ortamı (adım 10) ----
EGITIM="${EGITIM:-1}"                                # 0 → adım tamamen atlanır
EGITIM_VENV="${EGITIM_VENV:-/opt/egitim-venv}"
# uv312 | system | auto. VARSAYILAN uv312: sistem Python'u 3.13 ama torch 2.6 (cu124
# tavanı) ile uyumlu son xformers'ın (0.0.29.post3) cp313 tekerleği YOK; pip kaynaktan
# derlemeye kalkıp düşüyor (18 Eyl 2026 tatbikatı). Sürücü/torch yükselince 'system' denenir.
EGITIM_PYTHON="${EGITIM_PYTHON:-uv312}"
LLAMA_DIR="${LLAMA_DIR:-/opt/llama.cpp}"
LLAMA_TAG="${LLAMA_TAG:-v0.4.1}"                     # sabit etiket; 'latest' DEĞİL (17 Eyl 2026'da son sürüm)
TORCH_INDEX="${TORCH_INDEX:-https://download.pytorch.org/whl/cu124}"   # sürücü 550 → CUDA 12.4 tavanı
CACHE_DIR="${CACHE_DIR:-$MOUNT_POINT/cache}"         # model diskinde; formatı sağ atlatır
# Pinli paket listesi (egitim/requirements.txt). Pi'den alınır; yoksa önbellekteki
# kopya; o da yoksa gevşek listeyle kurulup dondurulur (ilk kurulum).
REQ_URL="${REQ_URL:-http://192.168.1.166:8080/egitim/requirements.txt}"

log(){  echo -e "\n\033[1;32m==> $*\033[0m"; }
warn(){ echo -e "\033[1;33m!!  $*\033[0m" >&2; }
die(){  echo -e "\033[1;31mHATA: $*\033[0m" >&2; exit 1; }

# Dosyayı sadece içeriği değiştiyse yaz. Değiştiyse 0, aynıysa 1 döner.
# İkinci parametre isteğe bağlı dosya kipi (varsayılan 0644).
write_if_changed(){
  local path="$1" mode="${2:-0644}" tmp rc=0
  tmp="$(mktemp)"
  cat > "$tmp"
  if [[ -f "$path" ]] && cmp -s "$tmp" "$path"; then
    rc=1
  else
    install -D -m "$mode" "$tmp" "$path"
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

# Temel araclar. Taze Debian kurulumunda jq/ufw/ethtool BULUNMAZ; script
# bunlari kullandigi icin basta kurulur (15 Eyl 2026 tatbikatinda eksiktiler).
MISSING=()
for c in curl jq; do command -v "$c" >/dev/null 2>&1 || MISSING+=("$c"); done
command -v ca-certificates >/dev/null 2>&1 || true
if [[ ${#MISSING[@]} -gt 0 ]]; then
  log "Eksik temel araclar kuruluyor: ${MISSING[*]}"
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates "${MISSING[@]}"
fi

# ---------- 1) NVIDIA sürücüsü ----------
gpu_ready(){ command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; }
driver_pkg_installed(){
  dpkg-query -W -f='${Status}' nvidia-driver 2>/dev/null | grep -q "install ok installed"
}
# DKMS modülü GERÇEKTEN derlenmiş mi? Başlık dizininin varlığı yetmez (18 Eyl 2026
# tatbikatı: derleme hata verse de "derlendi" yazardı). Modül adı 'nvidia-current'.
nvidia_module_built(){
  ls /lib/modules/"$(uname -r)"/updates/dkms/nvidia-current.ko* >/dev/null 2>&1 ||   dkms status 2>/dev/null | grep -qE "^nvidia(-current)?/.*: installed"
}

if gpu_ready; then
  log "GPU hazır: $(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader)"
elif driver_pkg_installed; then
  # Paket kurulu ama nvidia-smi çalışmıyor. İKİ ayrı sebep olabilir:
  #  a) modül derlenmiş, sadece yüklenmemiş  -> reboot çözer
  #  b) ÇEKİRDEK BAŞLIKLARI YOK, modül hiç derlenmemiş -> reboot ÇÖZMEZ,
  #     sonsuz "yeniden başlat" döngüsüne girer (15 Eyl 2026 tatbikatında yaşandı).
  if [[ ! -e "/lib/modules/$(uname -r)/build" ]]; then
    warn "Çekirdek başlıkları eksik → nvidia modülü hiç derlenmemiş. Kuruluyor..."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y "linux-headers-$(uname -r)" 2>/dev/null || \
      DEBIAN_FRONTEND=noninteractive apt-get install -y linux-headers-amd64
    command -v dkms >/dev/null 2>&1 && dkms autoinstall >/dev/null 2>&1 || true
    if [[ -e "/lib/modules/$(uname -r)/build" ]] && nvidia_module_built; then
      log "Başlıklar kuruldu, DKMS modülü derlendi (nvidia-current.ko doğrulandı)."
    elif [[ -e "/lib/modules/$(uname -r)/build" ]]; then
      warn "Başlıklar var ama nvidia modülü derlenmemiş. Derleme çıktısı:"
      dkms autoinstall 2>&1 | tail -n 15 >&2 || true
      die "nvidia DKMS derlemesi başarısız — reboot ÇÖZMEZ. Yukarıdaki çıktıya bak."
    else
      die "Çekirdek başlıkları kurulamadı. Elle: apt-get install linux-headers-\$(uname -r)"
    fi
  fi
  # Modül şimdi yüklenebiliyor mu? Yükleniyorsa reboot'a gerek yok.
  if /usr/sbin/modprobe nvidia 2>/dev/null && gpu_ready; then
    log "GPU etkinleşti (reboot gerekmedi): $(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader)"
  else
  warn "NVIDIA sürücüsü kurulu ama etkin değil. Yeniden başlatma gerekiyor."
  if [[ "$AUTO_REBOOT" == "1" ]]; then
    log "AUTO_REBOOT=1 → yeniden başlatılıyor. Açılıştan sonra bu script'i tekrar çalıştır."
    sleep 3; systemctl reboot; exit 0
  fi
  echo "*** Makineyi yeniden başlat, sonra bu script'i aynen tekrar çalıştır. ***"
  exit 0
  fi
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
  # ÇEKİRDEK BAŞLIKLARI ŞART: nvidia-kernel-dkms modülü derlemek için
  # /lib/modules/$(uname -r)/build gerekir. Başlıklar yoksa paket kurulur ama
  # modül HİÇ derlenmez ve GPU ölü kalır (15 Eyl 2026 format tatbikatında yaşandı).
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
      nvidia-driver firmware-misc-nonfree \
      "linux-headers-$(uname -r)" 2>/dev/null || \
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      nvidia-driver firmware-misc-nonfree linux-headers-amd64
  # Başlıklar sonradan geldiyse modülü şimdi derlet.
  command -v dkms >/dev/null 2>&1 && dkms autoinstall >/dev/null 2>&1 || true
  if [[ -e "/lib/modules/$(uname -r)/build" ]] && nvidia_module_built; then
    log "Çekirdek başlıkları yerinde, DKMS modülü derlendi (nvidia-current.ko doğrulandı)."
  elif [[ -e "/lib/modules/$(uname -r)/build" ]]; then
    warn "Başlıklar var ama nvidia modülü DERLENMEMİŞ — reboot çözmez. Derleme çıktısı:"
    dkms autoinstall 2>&1 | tail -n 15 >&2 || true
    die "nvidia DKMS derlemesi başarısız. Elle: dkms autoinstall; sonra bu script'i tekrar çalıştır."
  else
    warn "Çekirdek başlıkları YOK — nvidia modülü derlenemez, GPU açılmaz."
    warn "  Elle: apt-get install linux-headers-\$(uname -r) && dkms autoinstall"
  fi
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

# ---------- 4) JIT ayarı ----------
# CLI'da bu ayar yok; LM Studio'nun kendi yapılandırma dosyasında duruyor.
# systemd adımından ÖNCE yapılır ki tek bir yeniden başlatma yetsin —
# aksi hâlde 17 GB'lık model iki kez yüklenirdi.
JIT_CHANGED=0
HTTP_CFG="$USER_HOME/.lmstudio/.internal/http-server-config.json"
if [[ -f "$HTTP_CFG" ]] && command -v jq >/dev/null 2>&1; then
  cur_jit="$(jq -r '.justInTimeModelLoading' "$HTTP_CFG" 2>/dev/null || echo '?')"
  if [[ "$cur_jit" != "$LMS_JIT" ]]; then
    tmpc="$(mktemp)"
    if jq --argjson v "$LMS_JIT" '.justInTimeModelLoading = $v' "$HTTP_CFG" > "$tmpc" 2>/dev/null && [[ -s "$tmpc" ]]; then
      install -m 644 -o "$TARGET_USER" -g "$TARGET_USER" "$tmpc" "$HTTP_CFG"
      log "JIT ayarı değişti: justInTimeModelLoading=$LMS_JIT"
      JIT_CHANGED=1
    else
      warn "http-server-config.json güncellenemedi → dokunulmadı."
    fi
    rm -f "$tmpc"
  else
    log "JIT ayarı zaten doğru: justInTimeModelLoading=$LMS_JIT"
  fi
else
  warn "http-server-config.json yok (veya jq yok) → JIT ayarı atlandı."
  warn "Dosyayı LM Studio ilk çalıştığında oluşturur; script'i bir kez daha çalıştır."
fi

# ---------- 5) systemd: lmstudio.service ----------
# Not: 'lms server start' arka plana çatallanır, bu yüzden Type=oneshot +
# RemainAfterExit=yes. Sunucudan önce 'lms daemon up' şart.
# JIT kapalıysa modeli açılışta biz yüklemeliyiz, yoksa API "model yok" der.
# Başına '-' konur: model yüklenemezse (ör. disk yok) API sunucusu yine ayağa kalksın.
# Model anahtari kurulumdan kuruluma DEGISIR (taze kurulumda "qwen3.8-27b",
# eskisinde "qwen/qwen3.8-27b" idi). Sabit ad eslesmezse ExecStartPost sessizce
# basarisiz olur ve model yuklenmez (15 Eyl 2026 tatbikatinda yasandi).
# Bu yuzden once 'lms ls' ile gercek anahtari arariz: once tam eslesme, sonra son
# bilesen eslesmesi (qwen/qwen3.8-27b ~ qwen3.8-27b). Eslesme yoksa ayardaki ad kalir;
# "ilk satiri al" YAPILMAZ — iki LLM varken yanlis model sabitlenirdi.
if [[ -n "$LMS_MODEL" ]] && [[ -x "$LMS_BIN" ]]; then
  DETECTED="$(sudo -u "$TARGET_USER" -H "$LMS_BIN" ls 2>/dev/null \
                | awk -v want="$LMS_MODEL" -v base="${LMS_MODEL##*/}" '
                    NF>=3 && $1 !~ /^(LLM|EMBEDDING|You|No)/ {
                      if ($1 == want) { print $1; found=1; exit }
                      if (!hit && $1 ~ ("(^|/)" base "$")) hit=$1
                    }
                    END { if (!found && hit) print hit }')"
  if [[ -n "$DETECTED" ]]; then
    [[ "$DETECTED" != "$LMS_MODEL" ]] && log "Model anahtari tespit edildi: $DETECTED (ayardaki: $LMS_MODEL)"
    LMS_MODEL="$DETECTED"
  else
    warn "'$LMS_MODEL' lms ls çıktısında yok; unit yine bu adla yazılıyor (yükleme başarısız olabilir)."
  fi
fi

LOAD_LINE=""
if [[ -n "$LMS_MODEL" ]]; then
  LOAD_LINE="ExecStartPost=-$LMS_BIN load $LMS_MODEL -y --context-length $LMS_CTX --parallel $LMS_PARALLEL
"
fi

UNIT_CHANGED=0
if write_if_changed /etc/systemd/system/lmstudio.service <<EOF
[Unit]
Description=LM Studio Server
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
Restart=on-failure
RestartSec=15
User=$TARGET_USER
Environment="HOME=$USER_HOME"
Environment="LMS_SERVER_HOST=$LMS_BIND"
ExecStartPre=$LMS_BIN daemon up
# 'daemon up' llmster'i baslatir ve lms ikilisini yazma icin acik tutar.
# Hemen ardindan ayni dosya calistirilirsa cekirdek ETXTBSY verir:
# "Text file busy", status=203/EXEC ve servis DUSER (15 Eyl 2026, taze
# kurulumun ilk soguk acilisinda yasandi). Kisa bekleme yarisi cozer.
ExecStartPre=/bin/sleep 5
ExecStart=$LMS_BIN server start --bind $LMS_BIND --port $LMS_PORT
${LOAD_LINE}ExecStop=$LMS_BIN daemon down

[Install]
WantedBy=multi-user.target
EOF
then UNIT_CHANGED=1; log "lmstudio.service yazıldı."; else log "lmstudio.service zaten güncel."; fi

systemctl daemon-reload
systemctl enable lmstudio >/dev/null 2>&1 || true
if [[ "$UNIT_CHANGED" == "1" || "$JIT_CHANGED" == "1" ]]; then
  systemctl restart lmstudio || warn "lmstudio başlatılamadı: journalctl -u lmstudio -n 50"
elif ! systemctl is-active --quiet lmstudio; then
  systemctl start lmstudio || warn "lmstudio başlatılamadı: journalctl -u lmstudio -n 50"
else
  # Çalışıyor ve unit aynı: yüklü modeli düşürmemek için dokunma.
  log "lmstudio çalışıyor, yeniden başlatılmadı."
fi

# ---------- 6) Uyku kapalı, grafik arayüz kapalı ----------
log "Güç ayarları: uyku hedefleri mask, varsayılan hedef multi-user."
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target >/dev/null 2>&1 || true
systemctl set-default multi-user.target >/dev/null 2>&1 || true

# ---------- 6b) Açılışta otomatik onarım (insan beklemesin) ----------
# 1 Eylül'de makine açılamaz duruma geldi ve iki hafta öyle kaldı: BIOS "F1
# bekle" ekranı (BIOS'ta kapatıldı) + Debian'ın bozuk dosya sistemini bulunca
# initramfs isteminde İNSAN beklemesi. İkincisini bu adım kapatır:
#   fsck.mode=force  : her açılışta kök diski kontrol et
#   fsck.repair=yes  : hata bulursa SORMADAN onar (istemde asılı kalma)
# Böylece bozuk dosya sistemi uzaktan/kendiliğinden düzelir, kilitlenmez.
GRUB_DEF="/etc/default/grub"
# DIKKAT: "ls a b | head" KULLANMA. Dosyalardan biri yoksa ls 2 doner,
# pipefail yuzunden boru hatti da 2 doner ve set -e script'i OLDURUR
# (15 Eyl 2026 tatbikatinda tam burada, cikis kodu 2 ile oldu).
GRUB_CFG=""
for g in /boot/grub/grub.cfg /boot/grub2/grub.cfg; do
  [[ -f "$g" ]] && { GRUB_CFG="$g"; break; }
done
# Kaynak dosya (default/grub) ile DERLENMIS cikti (grub.cfg) ayri ayri kontrol edilir.
# Ilk kosu default/grub'a yazip cikti derlemeyi atlarsa, ikinci kosu bunu yakalar.
src_ok=0; cfg_ok=0
grep -q "fsck.repair=yes" "$GRUB_DEF" 2>/dev/null && src_ok=1
[[ -n "$GRUB_CFG" ]] && grep -q "fsck.repair=yes" "$GRUB_CFG" 2>/dev/null && cfg_ok=1
if [[ -f "$GRUB_DEF" && ( "$src_ok" == "0" || "$cfg_ok" == "0" ) ]]; then
  if [[ "$src_ok" == "0" ]]; then
    cur="$(sed -n 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"$/\1/p' "$GRUB_DEF")"
    new="$(printf '%s fsck.mode=force fsck.repair=yes' "$cur" | sed 's/^ *//')"
    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$new\"|" "$GRUB_DEF"
  fi
  # update-grub/grub-mkconfig /usr/sbin'de; sudo bash altında PATH'te olmayabilir,
  # bu yüzden mutlak yollarla ara. Derleme sonucu DOĞRULANIR — sessiz başarısızlık yok.
  grubmk=""
  for c in /usr/sbin/update-grub /sbin/update-grub update-grub; do command -v "$c" >/dev/null 2>&1 && { grubmk="$c"; break; }; done
  if [[ -n "$grubmk" ]]; then
    "$grubmk" >/dev/null 2>&1
  else
    for c in /usr/sbin/grub-mkconfig /sbin/grub-mkconfig grub-mkconfig; do command -v "$c" >/dev/null 2>&1 && { "$c" -o /boot/grub/grub.cfg >/dev/null 2>&1; grubmk="$c"; break; }; done
  fi
  if grep -q "fsck.repair=yes" /boot/grub/grub.cfg 2>/dev/null; then
    log "Açılışta otomatik fsck onarımı etkin (fsck.mode=force fsck.repair=yes), grub.cfg doğrulandı."
  else
    warn "GRUB güncellendi ama grub.cfg'de fsck.repair GÖRÜNMÜYOR."
    warn "  update-grub bulundu mu: ${grubmk:-HAYIR}. Elle: sudo /usr/sbin/update-grub"
  fi
else
  log "fsck otomatik onarımı zaten etkin (grub.cfg doğrulandı)."
fi

# ---------- 7) Güvenlik duvarı ----------
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

# ---------- 8) Wake-on-LAN (kalıcı) ----------
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

# ---------- 9) SSH anahtarları (format sonrası erişim) ----------
# Taze Debian'da authorized_keys boştur. Bu adım olmadan "uzaktan tek komutla
# geri gel" iddiası kapanmaz: servis geri döner ama makineye girilemez.
SSH_DIR="$USER_HOME/.ssh"
AUTH_FILE="$SSH_DIR/authorized_keys"
KEYS_STATE="atlandı"

if [[ -z "$AUTH_KEYS_URL" ]]; then
  log "AUTH_KEYS_URL boş → SSH anahtarı adımı atlandı."
else
  tmpk="$(mktemp)"
  if curl -fsSL --max-time 15 "$AUTH_KEYS_URL" -o "$tmpk" 2>/dev/null && [[ -s "$tmpk" ]]; then
    # İndirilen şey gerçekten public key mi? Sunucu 404 sayfası döndürürse ya da
    # indirme yarım kalırsa authorized_keys'e çöp yazılmasın diye her satır denetlenir.
    if awk 'NF && substr($1,1,1)!="#" && $1 !~ /^(ssh-|ecdsa-|sk-ssh-|sk-ecdsa-)/ {bad=1}
            END {exit bad?1:0}' "$tmpk"; then
      install -d -m 700 -o "$TARGET_USER" -g "$TARGET_USER" "$SSH_DIR"
      [[ -f "$AUTH_FILE" ]] || : > "$AUTH_FILE"
      added=0
      # Var olan anahtarlar KORUNUR; yalnızca eksik olanlar eklenir.
      # Böylece script defalarca çalışsa da mükerrer satır oluşmaz.
      while IFS= read -r k || [[ -n "$k" ]]; do
        [[ -n "${k// /}" ]] || continue
        case "$k" in \#*) continue ;; esac
        if ! grep -qxF "$k" "$AUTH_FILE"; then
          printf '%s\n' "$k" >> "$AUTH_FILE"
          added=$((added+1))
        fi
      done < "$tmpk"
      chown "$TARGET_USER:$TARGET_USER" "$AUTH_FILE"
      chmod 600 "$AUTH_FILE"
      total="$(grep -c . "$AUTH_FILE" 2>/dev/null || true)"
      KEYS_STATE="${added} yeni / ${total:-0} toplam"
      log "SSH anahtarları: $KEYS_STATE → $AUTH_FILE"
    else
      KEYS_STATE="geçersiz içerik, dokunulmadı"
      warn "$AUTH_KEYS_URL geçerli SSH public key vermedi → authorized_keys'e DOKUNULMADI."
    fi
  else
    KEYS_STATE="alınamadı"
    warn "Anahtar listesi alınamadı: $AUTH_KEYS_URL"
    warn "Erişimi elle aç: ssh-copy-id $TARGET_USER@<makine-ip>"
  fi
  rm -f "$tmpk"
fi

# 9b) SSH parola girişi KAPALI. sudo parolasız (preseed) olduğu için parolayla SSH açık
# kalırsa LAN'da parolayı tahmin eden herkes root olur. Preseed de aynı dosyayı yazar;
# elle kurulan Debian'da (USB ile format) yalnız bu adım tutar. Anahtar yoksa kilitlenme
# olmasın diye: authorized_keys'te en az bir anahtar varsa uygulanır.
if [[ -s "$AUTH_FILE" ]] && grep -qE '^(ssh-|ecdsa-|sk-)' "$AUTH_FILE"; then
  if write_if_changed /etc/ssh/sshd_config.d/99-nopw.conf <<'EOF'
# bootstrap.sh tarafından yönetilir — elle düzenleme. Giriş yalnız SSH anahtarıyla.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF
  then
    if sshd -t 2>/dev/null; then systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
      log "SSH parola girişi kapatıldı (sshd_config.d/99-nopw.conf)."
    else
      rm -f /etc/ssh/sshd_config.d/99-nopw.conf; warn "sshd -t başarısız → 99-nopw.conf geri alındı."
    fi
  fi
else
  warn "authorized_keys'te anahtar yok → SSH parola girişi KAPATILMADI (kilitlenmemek için)."
fi

# ---------- 10) Eğitim ortamı (GPU deney/eğitim katmanı) ----------
# Makine kısa süreli GPU işleri (LoRA/QLoRA, değerlendirme, GGUF çevirme/niceleme)
# için de kullanılıyor ve her kullanımdan sonra sıfırdan kuruluyor. Projeden
# bağımsız, herkese açık yazılım katmanı taze kurulumda hazır gelir. Proje verisi,
# kod ve anahtarlar oturumla gelip gider — bootstrap'ın işi DEĞİLDİR.
#
# ÖNBELLEK: indirilen her şey (apt .deb, pip wheel, llama.cpp derlemesi) model
# diskindeki $CACHE_DIR altında tutulur. Disk formatı sağ atlattığı için ikinci
# kurulum internete çıkmadan biter (65 Mbit hatta ~12 dk indirme → ~2 dk).
# Disk bağlı değilse önbellek YOK sayılır (sda'ya yazılmaz), her şey internetten.
#
# CUDA toolkit KURULMAZ: pip tekerlekleri kendi CUDA çalışma zamanını taşır.
# Sürücü 550 → CUDA 12.4 tavanı → yalnız cu124 tekerleri (torch ≤ 2.6).
EGITIM_T0=$SECONDS
EGITIM_STATE="atlandı"; EGITIM_FAIL=0; PY_YOLU="-"; TORCH_VER="-"; CACHE_STATE="kapalı"
ELOG="/var/log/marvin-bootstrap-egitim.log"
VENV_PY="$EGITIM_VENV/bin/python"
LLAMA_BIN="$LLAMA_DIR/build/bin"

run_u(){ sudo -u "$TARGET_USER" -H env HOME="$USER_HOME" "$@"; }

if [[ "$EGITIM" != "1" ]]; then
  log "EGITIM=$EGITIM → eğitim ortamı adımı atlandı."
else
  : >> "$ELOG"; chmod 600 "$ELOG"
  echo "===== $(date -Is) bootstrap eğitim adımı =====" >> "$ELOG"

  # -- 10a) Önbellek dizinleri (yalnız model diski bağlıysa)
  CACHE_OK=0
  if [[ "$MODELS_OK" == "1" ]]; then
    install -d -m 755 "$CACHE_DIR" "$CACHE_DIR/apt/partial" "$CACHE_DIR/egitim"
    install -d -o "$TARGET_USER" -g "$TARGET_USER" \
      "$CACHE_DIR/wheels" "$CACHE_DIR/pip" "$CACHE_DIR/llama.cpp" "$CACHE_DIR/uv"
    CACHE_OK=1; CACHE_STATE="açık ($CACHE_DIR)"
    log "Önbellek: $CACHE_DIR"
  else
    warn "Model diski bağlı değil → önbellek kullanılmıyor, her şey internetten inecek."
  fi

  # Kurulu olmayan paketleri kurar; önbellek varsa .deb'ler orada tutulur ve
  # ikinci kurulumda apt onları yeniden indirmez (sağlama tutuyorsa).
  apt_install(){
    local pk=() p opts=()
    for p in "$@"; do
      dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed" || pk+=("$p")
    done
    [[ ${#pk[@]} -gt 0 ]] || { log "apt: hepsi kurulu."; return 0; }
    log "apt: ${pk[*]}"
    [[ "$CACHE_OK" == "1" ]] && opts=(-o "Dir::Cache::archives=$CACHE_DIR/apt" -o "APT::Keep-Downloaded-Packages=true")
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${opts[@]}" "${pk[@]}"
  }

  # -- 10b) Sistem paketleri
  apt_install git curl rsync tmux htop jq zstd pigz build-essential cmake pkg-config \
              libcurl4-openssl-dev python3-venv python3-pip python3-dev

  # -- 10c) Python ortamı: $EGITIM_VENV (sahibi $TARGET_USER)
  PIPENV=(PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_PROGRESS_BAR=off PIP_NO_INPUT=1)
  [[ "$CACHE_OK" == "1" ]] && PIPENV+=("PIP_CACHE_DIR=$CACHE_DIR/pip")
  pip_u(){ run_u env "${PIPENV[@]}" "$VENV_PY" -m pip "$@" >> "$ELOG" 2>&1; }

  mk_venv_system(){
    log "venv (sistem Python $(python3 --version 2>&1 | awk '{print $2}')): $EGITIM_VENV"
    rm -rf "$EGITIM_VENV"
    install -d -o "$TARGET_USER" -g "$TARGET_USER" "$EGITIM_VENV"
    run_u python3 -m venv "$EGITIM_VENV"
    echo system > "$EGITIM_VENV/.python-yolu"
  }
  mk_venv_uv(){
    # Sistem Python'u (3.13) ile küme çözülmezse: uv ile 3.12. Python ikilisi
    # önbellekte tutulur (UV_PYTHON_INSTALL_DIR) — o da formatı sağ atlatsın.
    local UV="$USER_HOME/.local/bin/uv" uvenv=()
    [[ "$CACHE_OK" == "1" ]] && uvenv=("UV_CACHE_DIR=$CACHE_DIR/uv/cache" "UV_PYTHON_INSTALL_DIR=$CACHE_DIR/uv/python")
    if [[ ! -x "$UV" ]]; then
      log "uv kuruluyor ($TARGET_USER kullanıcısına)..."
      run_u env UV_INSTALL_DIR="$USER_HOME/.local/bin" UV_NO_MODIFY_PATH=1 \
        bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh' >> "$ELOG" 2>&1
      [[ -x "$UV" ]] || die "uv kurulamadı ($UV yok). Günlük: $ELOG"
    fi
    log "venv (uv, Python 3.12): $EGITIM_VENV"
    run_u env "${uvenv[@]}" "$UV" python install 3.12 >> "$ELOG" 2>&1
    rm -rf "$EGITIM_VENV"
    install -d -o "$TARGET_USER" -g "$TARGET_USER" "$EGITIM_VENV"
    run_u env "${uvenv[@]}" "$UV" venv --python 3.12 --seed "$EGITIM_VENV" >> "$ELOG" 2>&1
    echo uv312 > "$EGITIM_VENV/.python-yolu"
  }
  venv_ok(){ [[ -x "$VENV_PY" && -s "$EGITIM_VENV/.python-yolu" ]]; }
  # Kurulumun gerçekten çalıştığını ölçer; stamp'e değil import'a güvenir.
  venv_verify(){
    run_u "$VENV_PY" - <<'PY' >> "$ELOG" 2>&1
import torch, unsloth, bitsandbytes, peft, trl, transformers, datasets, accelerate, gguf, hf_transfer
assert torch.cuda.is_available(), "torch.cuda.is_available() False"
print("verify OK", torch.__version__, torch.version.cuda)
PY
  }

  # Var olan venv'i koru; yol açıkça değiştirildiyse yeniden kur.
  if venv_ok; then
    PY_YOLU="$(cat "$EGITIM_VENV/.python-yolu")"
    if [[ "$EGITIM_PYTHON" != "auto" && "$EGITIM_PYTHON" != "$PY_YOLU" ]]; then
      warn "EGITIM_PYTHON=$EGITIM_PYTHON ama venv '$PY_YOLU' ile kurulmuş → yeniden kuruluyor."
      if [[ "$EGITIM_PYTHON" == "uv312" ]]; then mk_venv_uv; else mk_venv_system; fi
      PY_YOLU="$(cat "$EGITIM_VENV/.python-yolu")"
    else
      log "venv zaten var ($PY_YOLU): $EGITIM_VENV"
    fi
  else
    if [[ "$EGITIM_PYTHON" == "uv312" ]]; then mk_venv_uv; else mk_venv_system; fi
    PY_YOLU="$(cat "$EGITIM_VENV/.python-yolu")"
  fi

  # Pinli liste: Pi → önbellek → yok (gevşek kurulum + dondurma)
  # DİKKAT: pip $TARGET_USER olarak koşar; pin/kısıt dosyaları /root'ta OLAMAZ
  # (700 → Permission denied; 18 Eyl 2026 tatbikatında yaşandı). venv içinde tutulur.
  EGITIM_REQ="$EGITIM_VENV/requirements.txt"; EGITIM_CON="$EGITIM_VENV/constraints.txt"
  REQ_FILE=""; REQ_SRC="yok"
  tmpr="$(mktemp)"
  if [[ -n "$REQ_URL" ]] && curl -fsSL --max-time 20 "$REQ_URL" -o "$tmpr" 2>/dev/null && grep -q '^torch==' "$tmpr"; then
    REQ_FILE="$EGITIM_REQ"; install -m 644 -o "$TARGET_USER" -g "$TARGET_USER" "$tmpr" "$REQ_FILE"; REQ_SRC="Pi ($REQ_URL)"
    [[ "$CACHE_OK" == "1" ]] && install -m 644 "$tmpr" "$CACHE_DIR/egitim/requirements.txt"
  elif [[ "$CACHE_OK" == "1" && -s "$CACHE_DIR/egitim/requirements.txt" ]]; then
    REQ_FILE="$CACHE_DIR/egitim/requirements.txt"; REQ_SRC="önbellek"
  fi
  rm -f "$tmpr"

  STAMP="$EGITIM_VENV/.bootstrap-stamp"
  if [[ -n "$REQ_FILE" ]]; then WANT="req:$(sha256sum "$REQ_FILE" | cut -c1-16)"; else WANT="gevsek"; fi

  if [[ "$(cat "$STAMP" 2>/dev/null)" == "$WANT" ]] && venv_verify; then
    log "Python paketleri güncel (stamp eşleşti, import doğrulandı) — atlandı."
  else
    # Gevşek liste — YALNIZ pinli dosya yokken. Doğrulama GEÇİNCE dondurulur ve
    # egitim/requirements.txt olarak depoya konması istenir. (Doğrulamadan önce
    # dondurulursa bozuk küme önbelleğe pin olarak yazılır — 18 Eyl 2026'da yaşandı.)
    GEVSEK="unsloth peft trl transformers datasets accelerate bitsandbytes sentencepiece protobuf gguf hf_transfer numpy httpx openai pytest"
    # torch 2.6 ile yaşayabilen üst sınırlar (18 Eyl 2026'da marvin'de ampirik: torchao
    # 0.13-0.16 import OK, 0.17+ torch 2.7 API'si ister). torch yükselince gevşetilir.
    KISITLAR="torchao<0.17"
    GEVSEK_MODU=0; [[ -z "$REQ_FILE" ]] && GEVSEK_MODU=1
    kur_paketler(){
      if [[ -n "$REQ_FILE" ]]; then
        log "Pinli kurulum ($REQ_SRC) — günlük: $ELOG"
        if [[ "$CACHE_OK" == "1" ]]; then
          # Önce tamamen çevrimdışı dene; olmazsa eksikleri indir, sonra yine çevrimdışı kur.
          if pip_u install --no-index --find-links "$CACHE_DIR/wheels" -r "$REQ_FILE"; then
            log "Wheel önbelleğinden kuruldu (internet kullanılmadı)."; return 0
          fi
          log "Önbellekte eksik wheel var → indiriliyor..."
          pip_u download -d "$CACHE_DIR/wheels" --extra-index-url "$TORCH_INDEX" -r "$REQ_FILE" || return 1
          pip_u install --no-index --find-links "$CACHE_DIR/wheels" -r "$REQ_FILE"
        else
          pip_u install --extra-index-url "$TORCH_INDEX" -r "$REQ_FILE"
        fi
      else
        log "Pinli liste YOK → gevşek listeyle kurulup dondurulacak (ilk kurulum, internetten ~10 dk)."
        local fl=()
        [[ "$CACHE_OK" == "1" ]] && fl=(--find-links "$CACHE_DIR/wheels")
        # 1) torch YALNIZ cu124 dizininden (sürücü 550 tavanı; cu126/cu128 girmesin)
        pip_u install "${fl[@]}" --index-url "$TORCH_INDEX" torch || return 1
        TORCH_VER="$(run_u "$VENV_PY" -c 'import torch;print(torch.__version__)')"
        # 2) gerisi, torch sürümü kilitli (unsloth/trl çözümü torch'u değiştirmesin)
        { printf 'torch==%s\n' "$TORCH_VER"; printf '%s\n' $KISITLAR; } > "$EGITIM_CON"
        chown "$TARGET_USER:$TARGET_USER" "$EGITIM_CON"
        # shellcheck disable=SC2086
        pip_u install "${fl[@]}" -c "$EGITIM_CON" --extra-index-url "$TORCH_INDEX" $GEVSEK || return 1
      fi
    }
    # Yalnız doğrulama geçtikten sonra: dondur → önbelleğe → wheel'leri indir
    dondur(){
      run_u "$VENV_PY" -m pip freeze --exclude-editable > "$EGITIM_REQ"; chown "$TARGET_USER:$TARGET_USER" "$EGITIM_REQ"
      [[ "$CACHE_OK" == "1" ]] && install -m 644 "$EGITIM_REQ" "$CACHE_DIR/egitim/requirements.txt"
      if [[ "$CACHE_OK" == "1" ]]; then
        pip_u download -d "$CACHE_DIR/wheels" --extra-index-url "$TORCH_INDEX" -r "$EGITIM_REQ" || warn "wheel önbelleği doldurulamadı (kurulum yine tamam)."
      fi
      REQ_FILE="$EGITIM_REQ"; WANT="req:$(sha256sum "$REQ_FILE" | cut -c1-16)"
      warn "DONDURULDU: $EGITIM_REQ → depoya 'egitim/requirements.txt' olarak koy (scp marvin:$EGITIM_REQ egitim/requirements.txt)."
    }
    if kur_paketler && venv_verify; then
      [[ "$GEVSEK_MODU" == "1" ]] && dondur
      echo "$WANT" > "$STAMP"
    elif [[ "$EGITIM_PYTHON" == "auto" && "$PY_YOLU" == "system" ]]; then
      warn "Sistem Python'u ile küme çözülmedi/doğrulanmadı → uv ile Python 3.12 deneniyor. Son 20 satır:"
      tail -n 20 "$ELOG" >&2 || true
      mk_venv_uv; PY_YOLU="uv312"
      if kur_paketler && venv_verify; then
        [[ "$GEVSEK_MODU" == "1" ]] && dondur
        echo "$WANT" > "$STAMP"
        warn "Python yolu: uv312 — REHBER §7'ye işle."
      else
        EGITIM_FAIL=1; warn "Eğitim venv kurulamadı (uv312 ile de). Günlük: $ELOG"
      fi
    else
      EGITIM_FAIL=1; warn "Eğitim venv kurulamadı ($PY_YOLU). Günlük: $ELOG"; tail -n 20 "$ELOG" >&2 || true
    fi
  fi
  TORCH_VER="$(run_u "$VENV_PY" -c 'import torch;print(torch.__version__, torch.version.cuda)' 2>/dev/null || echo '-')"

  # -- 10d) llama.cpp: sabit etiket, yalnız CPU (GGUF çevirme + niceleme)
  # DİKKAT: llama.cpp'nin requirements/requirements-convert_hf_to_gguf.txt dosyası
  # KURULMAZ — içinde CPU dizinli 'torch==2.11.0' pini var, CUDA torch'u sessizce
  # ezer. Çevirici ihtiyaçları (numpy, sentencepiece, transformers, gguf, protobuf)
  # zaten venv'de; convert_hf_to_gguf.py yerel gguf-py'yi kendisi sys.path'e alır.
  llama_ok(){ [[ -x "$LLAMA_BIN/llama-quantize" && -f "$LLAMA_DIR/convert_hf_to_gguf.py" \
               && "$(cat "$LLAMA_DIR/.marvin-tag" 2>/dev/null)" == "$LLAMA_TAG" ]]; }
  LTAR="$CACHE_DIR/llama.cpp/llama.cpp-$LLAMA_TAG.tar.zst"
  if llama_ok; then
    log "llama.cpp $LLAMA_TAG zaten derli: $LLAMA_BIN"
  else
    if [[ -d "$LLAMA_DIR" && "$(cat "$LLAMA_DIR/.marvin-tag" 2>/dev/null)" != "$LLAMA_TAG" ]]; then
      warn "llama.cpp farklı/eksik etiket → $LLAMA_DIR sıfırlanıyor."; rm -rf "$LLAMA_DIR"
    fi
    if [[ "$CACHE_OK" == "1" && -s "$LTAR" ]]; then
      log "llama.cpp $LLAMA_TAG önbellekten açılıyor..."
      rm -rf "$LLAMA_DIR"; tar -I zstd -xf "$LTAR" -C "$(dirname "$LLAMA_DIR")"
      chown -R "$TARGET_USER:$TARGET_USER" "$LLAMA_DIR"
    else
      if [[ ! -d "$LLAMA_DIR/.git" ]]; then
        log "llama.cpp $LLAMA_TAG klonlanıyor..."
        rm -rf "$LLAMA_DIR"; install -d -o "$TARGET_USER" -g "$TARGET_USER" "$LLAMA_DIR"
        run_u git clone -q --depth 1 --branch "$LLAMA_TAG" https://github.com/ggml-org/llama.cpp "$LLAMA_DIR" >> "$ELOG" 2>&1
      fi
      log "llama.cpp derleniyor (CPU, -j$(nproc)) — günlük: $ELOG"
      run_u cmake -S "$LLAMA_DIR" -B "$LLAMA_DIR/build" -DGGML_CUDA=OFF -DCMAKE_BUILD_TYPE=Release \
            -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF >> "$ELOG" 2>&1
      run_u cmake --build "$LLAMA_DIR/build" -j"$(nproc)" >> "$ELOG" 2>&1
      echo "$LLAMA_TAG" > "$LLAMA_DIR/.marvin-tag"; chown "$TARGET_USER:$TARGET_USER" "$LLAMA_DIR/.marvin-tag"
      if [[ "$CACHE_OK" == "1" ]]; then
        tar -I 'zstd -T0' -cf "$LTAR.tmp" -C "$(dirname "$LLAMA_DIR")" "$(basename "$LLAMA_DIR")" && mv "$LTAR.tmp" "$LTAR"
        chown "$TARGET_USER:$TARGET_USER" "$LTAR"; log "llama.cpp derlemesi önbelleğe alındı: $LTAR"
      fi
    fi
    llama_ok || { EGITIM_FAIL=1; warn "llama.cpp derlenemedi (llama-quantize yok). Günlük: $ELOG"; }
  fi

  # -- 10e) HF önbelleği NVMe'de + ortam değişkenleri
  # /mnt/models/hf yalnız disk bağlıyken oluşturulur (symlink kuralıyla aynı gerekçe).
  # HF_HOME giriş anında mountpoint kontrolüyle verilir: disk yoksa değişken
  # ayarlanmaz ve UYARI basılır — 100 GB model sessizce sda'ya inmesin.
  [[ "$MODELS_OK" == "1" ]] && install -d -o "$TARGET_USER" -g "$TARGET_USER" "$MOUNT_POINT/hf"
  if write_if_changed /etc/profile.d/egitim.sh <<EOF
# bootstrap.sh tarafından yönetilir — elle düzenleme.
# Eğitim ortamı yalnız $TARGET_USER için etkin; root ve sistem araçları etkilenmez.
if [ "\$(id -un)" = "$TARGET_USER" ]; then
  if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
    export HF_HOME="$MOUNT_POINT/hf"
  elif [ -n "\${PS1:-}" ]; then
    echo "UYARI: $MOUNT_POINT bağlı değil → HF_HOME ayarlanmadı; indirmeler sistem diskine gider." >&2
  fi
  export HF_HUB_ENABLE_HF_TRANSFER=1
  case ":\$PATH:" in *":$EGITIM_VENV/bin:"*) ;; *) PATH="$EGITIM_VENV/bin:\$PATH" ;; esac
  case ":\$PATH:" in *":$LLAMA_BIN:"*) ;; *) PATH="\$PATH:$LLAMA_BIN" ;; esac
  export PATH
fi
EOF
  then log "Ortam: /etc/profile.d/egitim.sh (HF_HOME, PATH)"; fi

  # -- 10f) lms-model: modeli İSTEK ÜZERİNE yükle/boşalt/açılışa sabitle
  # Açılışa sabitleme systemd DROP-IN ile yapılır; ana unit'e dokunmaz, bu yüzden
  # bootstrap tekrar koşunca write_if_changed unit'i "değişmiş" görmez ve pin kalır.
  if sed -e "s|@USER@|$TARGET_USER|g" -e "s|@LMS@|$LMS_BIN|g" \
         -e "s|@CTX@|$LMS_CTX|g" -e "s|@PAR@|$LMS_PARALLEL|g" <<'LMSEOF' | write_if_changed /usr/local/bin/lms-model 0755
#!/usr/bin/env bash
# lms-model — LM Studio modelini İSTEK ÜZERİNE yönetir. bootstrap.sh kurar.
# Model açılışta OTOMATİK YÜKLENMEZ (GPU eğitim işleriyle çakışmasın diye).
# LiteLLM'in cevap vermesi için önce:  lms-model load <anahtar>
#
#   lms-model status                 yüklü model + açılış sabitlemesi
#   lms-model ls                     diskteki modeller (lms ls)
#   lms-model load <anahtar> [--ctx N] [--parallel N]
#   lms-model unload                 tümünü boşalt (VRAM'i eğitime bırak)
#   sudo lms-model pin <anahtar> [--ctx N] [--parallel N]   açılışta da yükle
#   sudo lms-model unpin             açılış sabitlemesini kaldır
set -euo pipefail
U="@USER@"; LMS="@LMS@"; CTX="@CTX@"; PAR="@PAR@"
DROPIN="/etc/systemd/system/lmstudio.service.d/model.conf"
cmd="${1:-status}"; [[ $# -gt 0 ]] && shift
key=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ctx) CTX="$2"; shift 2 ;;
    --parallel) PAR="$2"; shift 2 ;;
    -*) echo "bilinmeyen seçenek: $1" >&2; exit 2 ;;
    *) key="$1"; shift ;;
  esac
done
as_user(){
  if [[ "$(id -un)" == "$U" ]]; then "$@"
  elif [[ $EUID -eq 0 ]]; then sudo -u "$U" -H "$@"
  else echo "HATA: bu komut $U ya da root olarak çalışmalı." >&2; exit 1; fi
}
need_root(){ [[ $EUID -eq 0 ]] || { echo "HATA: root gerekli: sudo lms-model $cmd" >&2; exit 1; }; }
keys(){ as_user "$LMS" ls 2>/dev/null | awk 'NF>=3 && $1 !~ /^(LLM|EMBEDDING|You|No)/ {print $1}'; }
resolve(){  # tam eşleşme → son bileşen eşleşmesi → hata + liste
  local want="$1" k
  [[ -n "$want" ]] || { echo "HATA: model anahtarı ver. Mevcutlar:" >&2; keys | sed 's/^/  /' >&2; exit 2; }
  for k in $(keys); do [[ "$k" == "$want" ]] && { echo "$k"; return; }; done
  for k in $(keys); do [[ "${k##*/}" == "${want##*/}" ]] && { echo "$k"; return; }; done
  echo "HATA: '$want' diskte yok. Mevcutlar:" >&2; keys | sed 's/^/  /' >&2; exit 1
}
case "$cmd" in
  status)
    as_user "$LMS" ps || true
    if [[ -f "$DROPIN" ]]; then echo "Açılışa sabitli: $(grep -o 'load [^ ]*' "$DROPIN" | cut -d' ' -f2)"
    else echo "Açılışa sabitli model yok (bootstrap varsayılanı)."; fi ;;
  ls) as_user "$LMS" ls ;;
  load)
    k="$(resolve "$key")"
    echo "Yükleniyor: $k (ctx=$CTX, parallel=$PAR)"
    as_user "$LMS" load "$k" -y --context-length "$CTX" --parallel "$PAR" ;;
  unload) as_user "$LMS" unload --all; echo "Tüm modeller boşaltıldı." ;;
  pin)
    need_root; k="$(resolve "$key")"
    mkdir -p "$(dirname "$DROPIN")"
    printf '[Service]\n# lms-model pin tarafından yazıldı — kaldırmak için: sudo lms-model unpin\nExecStartPost=-%s load %s -y --context-length %s --parallel %s\n' \
      "$LMS" "$k" "$CTX" "$PAR" > "$DROPIN"
    systemctl daemon-reload
    echo "Açılışa sabitlendi: $k. Şimdi yüklemek için: lms-model load $k" ;;
  unpin)
    need_root; rm -f "$DROPIN"; rmdir "$(dirname "$DROPIN")" 2>/dev/null || true
    systemctl daemon-reload; echo "Açılış sabitlemesi kaldırıldı." ;;
  *) sed -n '2,12p' "$0"; exit 2 ;;
esac
LMSEOF
  then log "lms-model kuruldu: /usr/local/bin/lms-model"; fi

  EGITIM_STATE="tamam"; [[ "$EGITIM_FAIL" == "1" ]] && EGITIM_STATE="HATA (bkz. $ELOG)"
fi
EGITIM_SURE=$((SECONDS - EGITIM_T0))

# ---------- 11) Özet ----------
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
 Açılış modeli : ${LMS_MODEL:-YOK (istek üzerine: lms-model load <anahtar>)}
 SSH anahtarı  : ${KEYS_STATE}
 Endpoint      : http://${LAN_IP:-?}:${LMS_PORT}/v1
------------------------------------------------------------
 Eğitim ortamı : ${EGITIM_STATE}  (${EGITIM_SURE} sn)
 venv          : ${EGITIM_VENV}  (python yolu: ${PY_YOLU})
 torch         : ${TORCH_VER}
 llama.cpp     : ${LLAMA_TAG} → ${LLAMA_BIN}
 Önbellek      : ${CACHE_STATE}
 HF_HOME       : ${MOUNT_POINT}/hf (giriş anında, disk bağlıysa)

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

# Eğitim ortamı kabul ölçütleri (REHBER §7 / egitim/TATBIKAT.md ile aynı)
if [[ "$EGITIM" == "1" && "$EGITIM_STATE" != "atlandı" ]]; then
  log "Eğitim ortamı kabul kontrolleri:"
  # unsloth import'ta banner basar; sonuç SON satırdır (18 Eyl 2026: banner yüzünden yanlış HATA).
  k1="$(run_u "$VENV_PY" -c 'import torch, unsloth, bitsandbytes; print(torch.cuda.is_available(), torch.version.cuda)' 2>/dev/null | tail -n 1 || true)"
  [[ -n "$k1" ]] || k1="HATA"
  echo "   torch/unsloth/bnb import → $k1   (beklenen: True 12.4)"
  # DİKKAT: '... | grep -q' KULLANMA — grep ilk eşleşmede çıkınca üretici SIGPIPE (141)
  # alır ve pipefail boru hattını "başarısız" sayar (18 Eyl 2026 tatbikatı). Çıktıyı yakala.
  qh="$("$LLAMA_BIN/llama-quantize" --help 2>&1 || true)"
  if [[ "$qh" == *usage* ]]; then echo "   llama-quantize --help    → OK"; else echo "   llama-quantize --help    → HATA"; EGITIM_FAIL=1; fi
  if run_u "$VENV_PY" "$LLAMA_DIR/convert_hf_to_gguf.py" --help >/dev/null 2>&1; then echo "   convert_hf_to_gguf.py    → OK"; else echo "   convert_hf_to_gguf.py    → HATA"; EGITIM_FAIL=1; fi
  k4="$(su - "$TARGET_USER" -c 'echo $HF_HOME' 2>/dev/null)"
  echo "   HF_HOME (giriş kabuğu)   → ${k4:-BOŞ}   (beklenen: $MOUNT_POINT/hf; disk bağlı değilse BOŞ normaldir)"
  [[ "$k1" == True* ]] || EGITIM_FAIL=1
  if [[ "$EGITIM_FAIL" == "1" ]]; then
    warn "Eğitim ortamı kabul ölçütlerinden en az biri BAŞARISIZ. Günlük: $ELOG"
    exit 1
  fi
fi
