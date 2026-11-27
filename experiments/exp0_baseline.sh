#!/usr/bin/env bash
# Exp 0 — reference (Board A only): TP=1, no inter-board communication.
#   Upper bound for compute; shows the cost TP=2 pays in communication.
#   experiments/exp0_baseline.sh [suites...]      (suites: vit llm)
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
"${JDI_ROOT}/experiments/run.sh" exp0 single "$@"
