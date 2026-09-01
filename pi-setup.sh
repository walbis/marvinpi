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
# Test makinesinin MagicDNS adı. Çözülmezse 100.x.y.z Tailscale IP'sini yaz.
OLLAMA_BASE="${OLLAMA_BASE:-http://llm-test:11434}"

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
  - model_name: qwen3-14b
    litellm_params:
      model: ollama_chat/qwen3:14b
      api_base: $OLLAMA_BASE

  # Makine vLLM'e geçince üstteki bloğu yorumla, bunu aç:
  # - model_name: qwen-14b
  #   litellm_params:
  #     model: openai/Qwen/Qwen2.5-14B-Instruct-AWQ
  #     api_base: $OLLAMA_BASE/v1
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

# ---------- Özet ----------
cat <<SUMMARY

============================================================
 Pİ HAZIR
 Sabit API endpoint : http://$PI_TS_IP:4000/v1  (tailnet'ten)
 Yetki              : Authorization: Bearer <master-key veya üretilen key>
 Dosya sunucusu     : $REPO_DIR içine bootstrap.sh + KURTARMA-README.md kopyala;
                      LAN'dan http://<pi-lan-ip>:8080/bootstrap.sh ile çekilir.
                      (İnternetsiz kurtarma yolu budur — dizin boşsa çalışmaz.)
 Wake-on-LAN        : etherwake -i eth0 <MAKINE-MAC-ADRESI>
============================================================
SUMMARY
