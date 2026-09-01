#!/usr/bin/env bash
# ============================================================
#  pi-setup.sh — Raspberry Pi "kalıcı çapa" kurulumu
#  Pi hiç formatlanmaz; şunları üstlenir:
#   1) Tailscale: makine silinse bile ofis ağına giriş kapın
#   2) LiteLLM gateway + Postgres: sabit endpoint + API anahtarı yönetimi
#   3) Bootstrap dosyalarını LAN'a servis etme (port 8080)
#   4) Wake-on-LAN aracı (etherwake)
#  Gereksinim: 64-bit Raspberry Pi OS / Debian. Idempotent.
#  Kullanım: sudo bash pi-setup.sh   (ilk sefer Tailscale login linki verir)
# ============================================================
set -euo pipefail

GW_DIR="/opt/llm-gw"
REPO_DIR="/opt/llm-repo"
# Model sunucusu: marvin'deki LM Studio. marvin tailnet'e GİRMEZ, LAN IP'si kullanılır.
# IP router'da rezerve edilmelidir (MAC 60:cf:84:76:49:42).
MODEL_BASE="${MODEL_BASE:-http://192.168.1.114:1234}"
MODEL_NAME="${MODEL_NAME:-qwen/qwen3.8-27b}"
# GitHub'dan tazelenecek repo (dosya sunucusu içeriği)
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/walbis/marvinpi/main}"

log(){ echo -e "\n\033[1;32m==> $*\033[0m"; }
[[ $EUID -eq 0 ]] || { echo "sudo ile çalıştır"; exit 1; }

apt-get update -qq
apt-get install -y -qq curl openssl etherwake >/dev/null

# ---------- 1) Tailscale ----------
command -v tailscale >/dev/null 2>&1 || curl -fsSL https://tailscale.com/install.sh | sh
tailscale ip -4 >/dev/null 2>&1 || tailscale up --ssh --hostname=llm-pi
PI_TS_IP="$(tailscale ip -4 | head -n1)"

# ---------- 2) Docker ----------
command -v docker >/dev/null 2>&1 || curl -fsSL https://get.docker.com | sh

# ---------- 3) LiteLLM gateway + Postgres ----------
mkdir -p "$GW_DIR"; cd "$GW_DIR"

if [[ ! -f .env ]]; then
  MASTER_KEY="sk-$(openssl rand -hex 24)"
  cat > .env <<EOF
LITELLM_MASTER_KEY=$MASTER_KEY
DB_PASSWORD=$(openssl rand -hex 16)
EOF
  chmod 600 .env
  echo
  echo "*** MASTER KEY üretildi, güvenli bir yere kaydet: $MASTER_KEY ***"
fi

if [[ ! -f litellm-config.yaml ]]; then
  cat > litellm-config.yaml <<EOF
model_list:
  - model_name: qwen3.8-27b
    litellm_params:
      model: openai/$MODEL_NAME
      api_base: $MODEL_BASE/v1
      api_key: dummy

  # Ekip yükü gelip vLLM ayrı portta açılırsa ikinci satır olarak eklenir:
  # - model_name: qwen-vllm
  #   litellm_params:
  #     model: openai/Qwen/Qwen2.5-14B-Instruct-AWQ
  #     api_base: http://192.168.1.114:8000/v1
  #     api_key: dummy

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
EOF
fi

if [[ ! -f docker-compose.yml ]]; then
  cat > docker-compose.yml <<'EOF'
services:
  db:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      - POSTGRES_USER=llmproxy
      - POSTGRES_PASSWORD=${DB_PASSWORD}
      - POSTGRES_DB=litellm
    volumes:
      - pg_data:/var/lib/postgresql/data

  litellm:
    image: ghcr.io/berriai/litellm:main-latest
    restart: unless-stopped
    depends_on: [db]
    dns:
      - 100.100.100.100   # MagicDNS: konteynerden 'llm-test' adı çözülsün
    ports:
      - "4000:4000"        # anahtar zorunlu olduğu için LAN'a açık kalması kabul edilebilir
    volumes:
      - ./litellm-config.yaml:/app/config.yaml
    environment:
      - LITELLM_MASTER_KEY=${LITELLM_MASTER_KEY}
      - DATABASE_URL=postgresql://llmproxy:${DB_PASSWORD}@db:5432/litellm
    command: ["--config", "/app/config.yaml", "--port", "4000"]

volumes:
  pg_data:
EOF
fi

log "Gateway başlatılıyor..."
docker compose up -d

# ---------- 4) Bootstrap dosyalarını LAN'a servis et ----------
mkdir -p "$REPO_DIR"
cat > /etc/systemd/system/llm-repo.service <<EOF
[Unit]
Description=LLM bootstrap dosya sunucusu (LAN, port 8080)
After=network.target
[Service]
ExecStart=/usr/bin/python3 -m http.server 8080 --directory $REPO_DIR
Restart=always
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now llm-repo.service

# ---------- 5) Repo dosyalarını GitHub'dan tazele (timer) ----------
# Dosya sunucusundaki kopya elle güncellenmezse sessizce eskir: kurtarma anında
# eski bootstrap.sh çalışır ve kimse fark etmez. Bu timer günde bir tazeler.
# İnternet yoksa eldeki kopya korunur — offline yedek olma amacı bozulmaz.
cat > /usr/local/bin/llm-repo-sync <<EOF
#!/usr/bin/env bash
# pi-setup.sh tarafından yönetilir.
# NOT: -e YOK; bir dosya başarısız olursa diğerleri denenmeye devam etsin.
set -uo pipefail
RAW_BASE="\${RAW_BASE:-$RAW_BASE}"
REPO_DIR="\${REPO_DIR:-$REPO_DIR}"
# authorized_keys BİLEREK listede değil: repoda yok, senkron onu ezmemeli.
FILES="bootstrap.sh KURTARMA-README.md DURUM.md"

changed=0
for f in \$FILES; do
  tmp="\$(mktemp)"
  if ! curl -fsSL --max-time 30 --retry 2 "\$RAW_BASE/\$f" -o "\$tmp"; then
    echo "atlandı (indirilemedi): \$f"; rm -f "\$tmp"; continue
  fi
  if [ ! -s "\$tmp" ]; then
    echo "atlandı (boş dosya): \$f"; rm -f "\$tmp"; continue
  fi
  # Kabuk script'i bozuk inerse kurtarmayı öldürür: önce sözdizimini doğrula.
  case "\$f" in
    *.sh)
      if ! bash -n "\$tmp" 2>/dev/null; then
        echo "atlandı (sözdizimi bozuk): \$f"; rm -f "\$tmp"; continue
      fi ;;
  esac
  if [ -f "\$REPO_DIR/\$f" ] && cmp -s "\$tmp" "\$REPO_DIR/\$f"; then
    rm -f "\$tmp"; continue
  fi
  # Doğrulama geçtikten SONRA yerine koy (yarım dosya asla servis edilmez).
  install -m 644 "\$tmp" "\$REPO_DIR/\$f" && { echo "güncellendi: \$f"; changed=\$((changed+1)); }
  rm -f "\$tmp"
done
echo "senkron bitti, değişen dosya: \$changed"
EOF
chmod 755 /usr/local/bin/llm-repo-sync

cat > /etc/systemd/system/llm-repo-sync.service <<EOF
[Unit]
Description=LLM repo dosyalarını GitHub'dan tazele
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/llm-repo-sync
EOF

cat > /etc/systemd/system/llm-repo-sync.timer <<EOF
[Unit]
Description=llm-repo-sync günlük çalıştır
[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=1h
[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now llm-repo-sync.timer
# İlk doldurmayı hemen yap ki dizin boş kalmasın.
/usr/local/bin/llm-repo-sync || true

# ---------- Özet ----------
cat <<SUMMARY

============================================================
 Pİ HAZIR
 Sabit API endpoint : http://$PI_TS_IP:4000/v1  (tailnet'ten)
 Yetki              : Authorization: Bearer <master-key veya üretilen key>
 Dosya sunucusu     : $REPO_DIR içine bootstrap.sh + KURTARMA-README.md kopyala;
                      LAN'dan http://<pi-lan-ip>:8080/bootstrap.sh ile çekilir.
                      (İnternetsiz kurtarma yolu budur — dizin boşsa çalışmaz.)
 Repo senkronu      : llm-repo-sync.timer (günlük, GitHub'dan tazeler)
                      Elle: sudo /usr/local/bin/llm-repo-sync
 Wake-on-LAN        : etherwake -i eth0 <MAKINE-MAC-ADRESI>
============================================================
SUMMARY
