#!/usr/bin/env bash
# Common helpers. Source this from every script:
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

set -euo pipefail

JDI_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export JDI_ROOT

# shellcheck source=../config/cluster.env
source "${JDI_ROOT}/config/cluster.env"
# Optional local overrides (git-ignored)
if [[ -f "${JDI_ROOT}/config/local.env" ]]; then
  # shellcheck disable=SC1091
  source "${JDI_ROOT}/config/local.env"
fi

EP_REPO_DIR="${EP_REPO_DIR:-$JDI_ROOT}"
STATE_DIR="${JDI_ROOT}/.state"
mkdir -p "$STATE_DIR"

# ---------------------------------------------------------------- logging ---
_c() { [[ -t 1 ]] && printf '\033[%sm' "$1" || true; }
log()  { echo "$(_c 36)[jdi $(date +%H:%M:%S)]$(_c 0) $*"; }
ok()   { echo "$(_c 32)[ OK ]$(_c 0) $*"; }
warn() { echo "$(_c 33)[WARN]$(_c 0) $*" >&2; }
die()  { echo "$(_c 31)[FAIL]$(_c 0) $*" >&2; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "run as root: sudo $0 $*"; }
need_cmd()  { command -v "$1" >/dev/null 2>&1 || die "missing command: $1 ($2)"; }

# ------------------------------------------------------------ role detect ---
# EP board = has the C5 controller in endpoint mode (exists only after the
# EP ODMDATA flash). Override with JDI_ROLE=rp|ep.
detect_role() {
  if [[ -n "${JDI_ROLE:-}" ]]; then echo "$JDI_ROLE"; return; fi
  if [[ -e "/sys/bus/platform/devices/${PCIE_EP_ADDR}.pcie-ep" ]] \
     || [[ -e "/sys/kernel/config/pci_ep/controllers/${PCIE_EP_ADDR}.pcie-ep" ]]; then
    echo ep
  else
    echo rp
  fi
}

# Interface that owns a given IPv4 address
iface_for_ip() {
  ip -o -4 addr show | awk -v ip="$1" '{split($4,a,"/"); if (a[1]==ip) print $2}' | head -n1
}

# Control-plane interface on THIS node
ctrl_if() {
  local role; role=$(detect_role)
  local want ip
  if [[ $role == rp ]]; then want="$RP_CTRL_IF"; ip="$RP_CTRL_IP"; else want="$EP_CTRL_IF"; ip="$EP_CTRL_IP"; fi
  if [[ -n "$want" ]]; then echo "$want"; return; fi
  local f; f=$(iface_for_ip "$ip")
  [[ -n "$f" ]] || die "no interface has $ip on this node — run setup/net_ctrl.sh or set *_CTRL_IF"
  echo "$f"
}
ctrl_ip() { [[ $(detect_role) == rp ]] && echo "$RP_CTRL_IP" || echo "$EP_CTRL_IP"; }

# VNET interface on THIS node (recorded by setup/pcie_mode.sh vnet)
vnet_if() {
  [[ -f "$STATE_DIR/vnet_iface" ]] || die "VNET not up on this node (run: sudo setup/pcie_mode.sh vnet)"
  cat "$STATE_DIR/vnet_iface"
}

# ------------------------------------------------------------------ remote ---
ep_ssh() {
  ssh -o BatchMode=yes -o ConnectTimeout=5 "${EP_SSH_USER}@${EP_CTRL_IP}" "$@"
}
# run a repo script on the EP board: on_ep <relative/script> [args...]
on_ep() {
  local script="$1"; shift
  ep_ssh "cd '${EP_REPO_DIR}' && ${script} $(printf '%q ' "$@")"
}
on_ep_sudo() {
  local script="$1"; shift
  ep_ssh "cd '${EP_REPO_DIR}' && sudo -n '${EP_REPO_DIR}/${script}' $(printf '%q ' "$@")"
}

# ---------------------------------------------------------------- results ---
new_result_dir() {   # new_result_dir <experiment> <transport>
  local d; d="${JDI_ROOT}/results/$1/$2/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$d/logs"
  echo "$d"
}

write_meta() {       # write_meta <dir> <experiment> <transport>
  local d="$1"
  python3 - "$d" "$2" "$3" <<'PY'
import json, os, subprocess, sys, platform, datetime
d, exp, tr = sys.argv[1:4]
def sh(c):
    try: return subprocess.run(c, shell=True, capture_output=True, text=True, timeout=10).stdout.strip()
    except Exception as e: return f"ERR {e}"
meta = {
  "experiment": exp, "transport": tr,
  "time": datetime.datetime.now().isoformat(timespec="seconds"),
  "host": platform.node(),
  "l4t": sh("head -n1 /etc/nv_tegra_release"),
  "jetpack": sh("dpkg-query -W -f='${Version}' nvidia-jetpack 2>/dev/null"),
  "kernel": platform.release(),
  "nvpmodel": sh("nvpmodel -q 2>/dev/null | head -n2 | tr '\\n' ' '"),
  "git_commit": sh(f"git -C {os.environ.get('JDI_ROOT','.')} rev-parse --short HEAD"),
  "image": os.environ.get("IMAGE",""),
  "image_digest": sh(f"docker image inspect --format '{{{{index .RepoDigests 0}}}}' {os.environ.get('IMAGE','')} 2>/dev/null"),
  "pcie_link": sh(f"lspci -vv -s {os.environ.get('PCIE_RP_BDF','')} 2>/dev/null | grep -E 'LnkSta:' | head -n1"),
}
json.dump(meta, open(os.path.join(d, "meta.json"), "w"), indent=2)
PY
}

export IMAGE PCIE_RP_BDF
