#!/usr/bin/env bash
# ============================================================
#  bootstrap.sh — Test makinesi tek komutla kurulum / kurtarma
#  Hedef: Debian 12/13 + NVIDIA GPU
#  Kurar: NVIDIA sürücü, Tailscale (+SSH), Docker, Ollama (GPU)
#  Idempotent: kaç kere çalıştırırsan çalıştır, güvenli.
#
#  Kullanım (format sonrası / ilk kurulum):
#    sudo TS_AUTHKEY=tskey-auth-XXXXX bash bootstrap.sh
#  Makine zaten tailnet'e bağlıysa key gerekmez:
#    sudo bash bootstrap.sh
# ============================================================
set -euo pipefail

# ---------- AYARLAR ----------
TS_HOSTNAME="${TS_HOSTNAME:-llm-test}"   # tailnet'te görünecek isim
MODEL="${MODEL:-qwen3:14b}"              # önden indirilecek model (12GB VRAM'e uygun)
                                         # daha hafif: llama3.1:8b veya qwen3:8b
APP_DIR="/opt/llm"
# docker-compose.yml'in çekileceği adres. Boşsa aşağıdaki gömülü şablon kullanılır.
#   GitHub:  RAW_BASE="https://raw.githubusercontent.com/KULLANICI/REPO/main"
#   Pi:      RAW_BASE="http://<pi-lan-ip>:8080"
RAW_BASE="${RAW_BASE:-}"

log(){ echo -e "\n\033[1;32m==> $*\033[0m"; }
die(){ echo -e "\033[1;31mHATA: $*\033[0m" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Root gerekli: sudo ile çalıştır."
command -v curl >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq curl; }

# ---------- 1) NVIDIA sürücüsü ----------
if ! command -v nvidia-smi >/dev/null 2>&1; then
  log "NVIDIA sürücüsü yok; non-free depolar açılıp kuruluyor..."
  if [[ -f /etc/apt/sources.list ]]; then
    sed -Ei '/non-free/! s/^(deb\s.*\bmain\b)/\1 contrib non-free non-free-firmware/' /etc/apt/sources.list
  fi
  if [[ -f /etc/apt/sources.list.d/debian.sources ]]; then
    sed -Ei 's/^Components:.*/Components: main contrib non-free non-free-firmware/' /etc/apt/sources.list.d/debian.sources
  fi
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y nvidia-driver firmware-misc-nonfree
  echo
  echo "*** Sürücü kuruldu. Makineyi YENİDEN BAŞLAT, sonra bu script'i aynen tekrar çalıştır. ***"
  exit 0
fi
log "GPU hazır: $(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader)"

# ---------- 2) Tailscale ----------
if ! command -v tailscale >/dev/null 2>&1; then
  log "Tailscale kuruluyor..."
  curl -fsSL https://tailscale.com/install.sh | sh
fi
if tailscale ip -4 >/dev/null 2>&1; then
  log "Tailscale zaten bağlı."
  tailscale up --ssh --hostname="$TS_HOSTNAME" >/dev/null 2>&1 || true
else
  [[ -n "${TS_AUTHKEY:-}" ]] || die "Makine tailnet'te değil. TS_AUTHKEY=tskey-... vererek çalıştır (üretimi: KURTARMA-README.md)."
  log "Tailnet'e katılınıyor..."
  tailscale up --authkey="$TS_AUTHKEY" --ssh --hostname="$TS_HOSTNAME"
fi
TS_IP="$(tailscale ip -4 | head -n1)"
log "Tailscale IP: $TS_IP  |  Uzaktan bağlantı: tailscale ssh $TS_HOSTNAME"

# ---------- 3) Docker ----------
if ! command -v docker >/dev/null 2>&1; then
  log "Docker kuruluyor..."
  curl -fsSL https://get.docker.com | sh
fi

# ---------- 4) NVIDIA Container Toolkit ----------
if ! command -v nvidia-ctk >/dev/null 2>&1; then
  log "NVIDIA Container Toolkit kuruluyor..."
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update && apt-get install -y nvidia-container-toolkit
fi
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker

# ---------- 5) Compose dosyaları ----------
mkdir -p "$APP_DIR"; cd "$APP_DIR"
if [[ -n "$RAW_BASE" ]] && curl -fsSL "$RAW_BASE/docker-compose.yml" -o docker-compose.yml.new 2>/dev/null; then
  mv docker-compose.yml.new docker-compose.yml
  log "docker-compose.yml repodan güncellendi."
elif [[ ! -f docker-compose.yml ]]; then
  log "Gömülü docker-compose.yml yazılıyor..."
  cat > docker-compose.yml <<'EOF'
# NOT: Bu dosyanın asıl kaynağı repodaki docker-compose.yml'dir.
# Değişiklik yaparsan iki kopyayı senkron tut.
services:
  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    restart: unless-stopped
    ports:
      - "${BIND_IP:-127.0.0.1}:11434:11434"
    volumes:
      - ollama_models:/root/.ollama
    environment:
      - OLLAMA_KEEP_ALIVE=30m
      # - OLLAMA_CONTEXT_LENGTH=8192
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]

  # ---- EKİP YÜKÜ GELİNCE: üstteki ollama bloğunu yorumla, bunu aç. ----
  # Aynı portu kullanır; Pi'de litellm-config.yaml içindeki vLLM bloğunu da aç.
  # vllm:
  #   image: vllm/vllm-openai:latest
  #   container_name: vllm
  #   restart: unless-stopped
  #   shm_size: "8gb"
  #   ports:
  #     - "${BIND_IP:-127.0.0.1}:11434:8000"
  #   volumes:
  #     - hf_cache:/root/.cache/huggingface
  #   command: >
  #     --model Qwen/Qwen2.5-14B-Instruct-AWQ
  #     --max-model-len 8192
  #     --gpu-memory-utilization 0.92
  #   deploy:
  #     resources:
  #       reservations:
  #         devices:
  #           - driver: nvidia
  #             count: all
  #             capabilities: [gpu]

volumes:
  ollama_models:
  # hf_cache:
EOF
fi

# API yalnızca tailnet arayüzünü dinlesin (ofis LAN'ına açık kalmasın)
echo "BIND_IP=$TS_IP" > .env

# ---------- 6) Servis ----------
log "Ollama başlatılıyor..."
docker compose up -d --remove-orphans

log "Servisin hazır olması bekleniyor..."
for i in {1..30}; do
  docker exec ollama ollama list >/dev/null 2>&1 && break
  sleep 2
done

log "Model indiriliyor: $MODEL (ilk seferde uzun sürebilir)"
docker exec ollama ollama pull "$MODEL"

# ---------- 7) Wake-on-LAN'ı kalıcı aç ----------
log "Wake-on-LAN ayarlanıyor..."
apt-get install -y -qq ethtool >/dev/null
IFACE="$(ip -o route get 1.1.1.1 | awk '{print $5; exit}')"
cat > /etc/systemd/system/wol.service <<EOF
[Unit]
Description=Wake-on-LAN arm ($IFACE)
After=network.target
[Service]
Type=oneshot
ExecStart=/usr/sbin/ethtool -s $IFACE wol g
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now wol.service || true
MAC_ADDR="$(cat /sys/class/net/$IFACE/address 2>/dev/null || echo '?')"
log "WoL hazır. Arayüz: $IFACE, MAC: $MAC_ADDR (Pi'den: sudo etherwake -i eth0 $MAC_ADDR)"

# ---------- 8) Özet ----------
cat <<SUMMARY

============================================================
 KURULUM TAMAM
 OpenAI uyumlu endpoint : http://$TS_IP:11434/v1
 Model                  : $MODEL
 Uzaktan erişim         : tailscale ssh $TS_HOSTNAME

 Hızlı test:
   curl http://$TS_IP:11434/v1/chat/completions \
     -H "Content-Type: application/json" \
     -d '{"model":"$MODEL","messages":[{"role":"user","content":"selam"}]}'
============================================================
SUMMARY
