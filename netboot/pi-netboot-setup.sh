#!/usr/bin/env bash
# ============================================================
#  pi-netboot-setup.sh — Pi'yi marvin için netboot sunucusu yapar
#
#  Kurar: dnsmasq (proxy-DHCP + TFTP) · Debian trixie netboot imajı
#         · GRUB menüsü (varsayılan: diskten aç) · preseed
#
#  GÜVENLİK: dnsmasq YALNIZCA marvin'in MAC'ine cevap verir
#  (dhcp-ignore=tag:!marvin). Ofisteki başka makineler etkilenmez.
#  IP dağıtmaz (proxy kipi) — router'ın DHCP'siyle çakışmaz.
#
#  Idempotent. Kullanım: sudo bash pi-netboot-setup.sh
# ============================================================
set -euo pipefail

TFTP_ROOT="${TFTP_ROOT:-/srv/tftp}"
REPO_DIR="${REPO_DIR:-/opt/llm-repo}"
HASH_FILE="${HASH_FILE:-/etc/marvin-preseed.hash}"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NETBOOT_URL="${NETBOOT_URL:-https://deb.debian.org/debian/dists/trixie/main/installer-amd64/current/images/netboot/netboot.tar.gz}"

log(){  echo -e "\n\033[1;32m==> $*\033[0m"; }
warn(){ echo -e "\033[1;33m!!  $*\033[0m" >&2; }
die(){  echo -e "\033[1;31mHATA: $*\033[0m" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Root gerekli: sudo bash pi-netboot-setup.sh"
for f in dnsmasq-netboot.conf grub.cfg preseed.cfg.template; do
  [[ -f "$SRC_DIR/$f" ]] || die "Kaynak dosya yok: $SRC_DIR/$f"
done

# ---------- 1) dnsmasq ----------
if ! command -v dnsmasq >/dev/null 2>&1; then
  log "dnsmasq kuruluyor..."
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq dnsmasq
fi

# ---------- 2) Netboot imajı ----------
mkdir -p "$TFTP_ROOT"
if [[ ! -f "$TFTP_ROOT/debian-installer/amd64/linux" ]]; then
  log "Debian netboot imajı indiriliyor (~55 MB)..."
  tmp="$(mktemp -d)"
  curl -fsSL --retry 3 "$NETBOOT_URL" -o "$tmp/netboot.tar.gz" || die "İndirilemedi: $NETBOOT_URL"
  tar -xzf "$tmp/netboot.tar.gz" -C "$TFTP_ROOT"
  rm -rf "$tmp"
  log "İmaj açıldı: $TFTP_ROOT"
else
  log "Netboot imajı zaten var, indirilmedi."
fi
[[ -f "$TFTP_ROOT/bootnetx64.efi" ]] || warn "bootnetx64.efi bulunamadı — UEFI istemci açılamayabilir."

# ---------- 3) GRUB menüsü ----------
# Debian'ın kendi menüsünün üzerine bizimkini koyarız (varsayılan: diskten aç).
GRUB_DIR="$TFTP_ROOT/debian-installer/amd64/grub"
mkdir -p "$GRUB_DIR"
if [[ -f "$GRUB_DIR/grub.cfg" && ! -f "$GRUB_DIR/grub.cfg.debian-orig" ]]; then
  cp "$GRUB_DIR/grub.cfg" "$GRUB_DIR/grub.cfg.debian-orig"
fi
install -m 644 "$SRC_DIR/grub.cfg" "$GRUB_DIR/grub.cfg"
log "Menü kuruldu: $GRUB_DIR/grub.cfg"

# ---------- 4) Parola karması ----------
# Repoda parola YOK. Karma burada, yerelde üretilir ve root-only saklanır.
if [[ ! -s "$HASH_FILE" ]]; then
  log "marvin kullanıcısı için parola belirle (kurulan sisteme yazılacak)."
  read -r -s -p "Parola: " p1; echo
  read -r -s -p "Tekrar : " p2; echo
  [[ "$p1" == "$p2" ]] || die "Parolalar eşleşmedi."
  [[ -n "$p1" ]] || die "Parola boş olamaz."
  openssl passwd -6 "$p1" > "$HASH_FILE"
  chmod 600 "$HASH_FILE"
  unset p1 p2
  log "Karma üretildi: $HASH_FILE (chmod 600)"
else
  log "Parola karması zaten var: $HASH_FILE"
fi

# ---------- 5) preseed ----------
mkdir -p "$REPO_DIR"
HASH="$(cat "$HASH_FILE")"
# Karma '$' ve '/' içerir; sed yerine awk ile güvenli ikame.
awk -v h="$HASH" '{gsub(/__PASSWORD_HASH__/, h); print}' \
  "$SRC_DIR/preseed.cfg.template" > "$REPO_DIR/preseed.cfg"
chmod 644 "$REPO_DIR/preseed.cfg"
grep -q '__PASSWORD_HASH__' "$REPO_DIR/preseed.cfg" && die "Karma yerleştirilemedi."
log "preseed hazır: $REPO_DIR/preseed.cfg (http://<pi-ip>:8080/preseed.cfg)"

# ---------- 6) dnsmasq yapılandırması ----------
install -m 644 "$SRC_DIR/dnsmasq-netboot.conf" /etc/dnsmasq.d/netboot.conf
if ! dnsmasq --test 2>&1 | grep -qi "syntax check ok"; then
  dnsmasq --test || true
  die "dnsmasq yapılandırması geçersiz — servis başlatılmadı."
fi
systemctl enable dnsmasq >/dev/null 2>&1 || true
systemctl restart dnsmasq
log "dnsmasq çalışıyor (yalnızca 60:cf:84:76:49:42 için PXE)."

# ---------- Özet ----------
cat <<SUMMARY

============================================================
 NETBOOT HAZIR
 TFTP kökü     : $TFTP_ROOT
 Menü          : $GRUB_DIR/grub.cfg
 preseed       : http://192.168.1.166:8080/preseed.cfg
 Cevap verilen : yalnızca marvin (60:cf:84:76:49:42)
 dnsmasq       : $(systemctl is-active dnsmasq)

 Menü girişleri (varsayılan 1, 10 sn):
   1) Diskten aç        — diske dokunmaz
   2) Kurtarma kipi     — live, diske dokunmaz
   3) YIKICI kurulum    — /dev/sda silinir, NVMe çekirdekte devre dışı

 Tatbikat: AMT'den (https://192.168.1.114:16993) tek seferlik
 ağdan açılışı tetikle, menüden 3'ü BİLEREK seç.
============================================================
SUMMARY
