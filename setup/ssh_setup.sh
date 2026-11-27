#!/usr/bin/env bash
# Run on Board A once: passwordless SSH A -> B, then sanity checks.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
[[ $(detect_role) == rp ]] || die "run on Board A (RP)"

[[ -f ~/.ssh/id_ed25519 ]] || ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
ssh-copy-id -i ~/.ssh/id_ed25519.pub "${EP_SSH_USER}@${EP_CTRL_IP}"

ep_ssh true && ok "ssh to EP works"
ep_ssh "test -d '${EP_REPO_DIR}'" || die "repo not found on EP at ${EP_REPO_DIR} (clone it there or set EP_REPO_DIR)"
ep_ssh "cd '${EP_REPO_DIR}' && git rev-parse --short HEAD" | xargs -I{} echo "EP repo commit: {}   local: $(git -C "$JDI_ROOT" rev-parse --short HEAD)"
on_ep_sudo setup/pcie_mode.sh status >/dev/null && ok "passwordless sudo on EP works" \
  || die "sudo -n failed on EP — run 'sudo setup/host_common.sh' on Board B"
r=$(on_ep bash -c 'source lib/common.sh; detect_role')
[[ $r == ep ]] && ok "Board B detected as EP" || warn "Board B detected as '$r' — was it flashed with the EP ODMDATA? (docs/01_hardware_and_flash.md)"
