#!/usr/bin/env bash
# Exp 0 — baselines (Board A):
#   single : TP=1 on Board A only           -> compute upper bound, no communication
#   eth10g : TP=2 with NCCL over 10GbE       -> dusty-nv style baseline
#   experiments/exp0_baseline.sh [single|eth10g|all] [suites...]
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
which="${1:-all}"; shift || true
if [[ $which == single || $which == all ]]; then "${JDI_ROOT}/experiments/run.sh" exp0 single "$@"; fi
if [[ $which == eth10g || $which == all ]]; then "${JDI_ROOT}/experiments/run.sh" exp0 eth10g "$@"; fi
