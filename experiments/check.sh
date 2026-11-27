#!/usr/bin/env bash
# Preflight check (Board A). Verifies everything an experiment needs, prints a checklist.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
fails=0
chk() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else warn "$d"; fails=$((fails+1)); fi; }

chk "this board is RP (Board A)"              test "$(detect_role)" = rp
chk "L4T R36.5 on A"                          grep -q "R36 (release), REVISION: 5" /etc/nv_tegra_release
chk "control IP $RP_CTRL_IP present"          test -n "$(iface_for_ip "$RP_CTRL_IP")"
chk "10GbE link speed 10000"                  bash -c "[[ \$(cat /sys/class/net/$(iface_for_ip "$RP_CTRL_IP" || echo none)/speed 2>/dev/null) == 10000 ]]"
chk "ping EP over 10GbE"                      ping -c 1 -W 2 "$EP_CTRL_IP"
chk "ssh to EP (key auth)"                    ep_ssh true
chk "EP detected as endpoint"                 bash -c "[[ \$(ssh -o BatchMode=yes ${EP_SSH_USER}@${EP_CTRL_IP} \"cd '${EP_REPO_DIR}' && bash -c 'source lib/common.sh; detect_role'\") == ep ]]"
chk "L4T R36.5 on B"                          ep_ssh "grep -q 'R36 (release), REVISION: 5' /etc/nv_tegra_release"
chk "same repo commit on A and B"             bash -c "[[ \$(git -C '$JDI_ROOT' rev-parse HEAD) == \$(ssh -o BatchMode=yes ${EP_SSH_USER}@${EP_CTRL_IP} git -C '${EP_REPO_DIR}' rev-parse HEAD) ]]"
chk "sudo -n works on EP"                     on_ep_sudo setup/pcie_mode.sh status
chk "docker usable on A"                      docker info
chk "image present on A"                      docker image inspect "$IMAGE"
chk "image present on B"                      ep_ssh "docker image inspect '$IMAGE'"
chk "gpt-oss-20b downloaded on A"             bash -c "ls '$DATA_DIR'/hf/hub/models--openai--gpt-oss-20b/snapshots/*/config.json"
chk "gpt-oss-20b downloaded on B"             ep_ssh "ls '$DATA_DIR'/hf/hub/models--openai--gpt-oss-20b/snapshots/*/config.json"
chk "tiktoken encodings on A"                 test -s "$DATA_DIR/encodings/o200k_base.tiktoken"
chk "PCIe EP visible at $PCIE_RP_BDF"         test -e "/sys/bus/pci/devices/$PCIE_RP_BDF"
if [[ -e /sys/bus/pci/devices/$PCIE_RP_BDF ]]; then
  echo "    $(lspci -vv -s "$PCIE_RP_BDF" 2>/dev/null | grep -E 'LnkSta:' | xargs)"
  echo "    (expect: Speed 16GT/s, Width x8)"
fi
echo "    pcie mode: $(cat "$STATE_DIR/pcie_mode" 2>/dev/null || echo none)"
echo
[[ $fails -eq 0 ]] && ok "all checks passed" || warn "$fails check(s) failed (PCIe ones are expected before 'setup/bringup.sh vnet')"
