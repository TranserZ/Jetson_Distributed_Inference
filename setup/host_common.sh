#!/usr/bin/env bash
# One-time host preparation. Run on BOTH boards:  sudo setup/host_common.sh
#  - packages (iperf3, jq, pciutils, ...)
#  - max performance mode (nvpmodel MAXN + jetson_clocks), persisted via systemd
#  - docker: nvidia runtime as default, user in docker group
#  - passwordless sudo ONLY for this repo's privileged scripts (orchestration over SSH)
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
need_root

REAL_USER="${SUDO_USER:-$USER}"
log "role detected: $(detect_role)   user: $REAL_USER"

log "packages"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  iperf3 jq pciutils ethtool python3 python3-pip openssh-server curl git >/dev/null
ok "packages installed"

log "L4T: $(head -n1 /etc/nv_tegra_release)"
grep -q "R36 (release), REVISION: 5" /etc/nv_tegra_release \
  || warn "expected L4T R36.5.x (JetPack 6.2.3) — both boards must run the SAME version"

log "performance mode"
nvpmodel -m 0 || warn "nvpmodel -m 0 failed"
jetson_clocks || warn "jetson_clocks failed"
cat > /etc/systemd/system/jdi-clocks.service <<'EOF'
[Unit]
Description=JDI: lock Jetson clocks for benchmarking
After=nvpmodel.service
[Service]
Type=oneshot
ExecStart=/usr/bin/jetson_clocks
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable jdi-clocks.service >/dev/null 2>&1
ok "MAXN + jetson_clocks (persisted)"

log "docker"
command -v docker >/dev/null || die "docker missing — install JetPack components (sudo apt install nvidia-jetpack) first"
if ! grep -q '"default-runtime": *"nvidia"' /etc/docker/daemon.json 2>/dev/null; then
  python3 - <<'PY'
import json, os
p = "/etc/docker/daemon.json"
d = json.load(open(p)) if os.path.exists(p) else {}
d.setdefault("runtimes", {})["nvidia"] = {"path": "nvidia-container-runtime", "runtimeArgs": []}
d["default-runtime"] = "nvidia"
json.dump(d, open(p, "w"), indent=4)
PY
  systemctl restart docker
fi
usermod -aG docker "$REAL_USER"
ok "docker nvidia runtime default; $REAL_USER in docker group (re-login once)"

log "sudoers for repo scripts"
cat > /etc/sudoers.d/jdi <<EOF
$REAL_USER ALL=(root) NOPASSWD: ${JDI_ROOT}/setup/pcie_mode.sh, ${JDI_ROOT}/bench/link/dma_test.sh, ${JDI_ROOT}/setup/net_ctrl.sh, /usr/bin/jetson_clocks, /usr/bin/dmesg
EOF
chmod 440 /etc/sudoers.d/jdi
visudo -cf /etc/sudoers.d/jdi >/dev/null || { rm -f /etc/sudoers.d/jdi; die "sudoers syntax error"; }
ok "NOPASSWD for repo scripts installed"

mkdir -p "$DATA_DIR" && chown "$REAL_USER" "$DATA_DIR"
ok "data dir: $DATA_DIR"
echo
echo "Next: sudo setup/net_ctrl.sh   (static 10GbE control IP)   then on Board A: setup/ssh_setup.sh"
