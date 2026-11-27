# Jetson Distributed Inference over PCIe

Jetson AGX Orin 64GB 두 대를 **PCIe Gen4 x8**로 직접 연결하고, **Tensor Parallelism(TP=2)** 분산추론에서 보드 간 통신 경로를 바꿔 가며 성능을 비교하는 실험 레포입니다.

| 실험 | 데이터 경로 (all-reduce) | 상태 |
|---|---|---|
| **Exp 0** 기준선 | 단일 보드(TP=1) / 10GbE + NCCL Socket | ✅ 실행 가능 |
| **Exp 1** | PCIe + **Tegra VNET**(가상 Ethernet) + NCCL Socket | ✅ 실행 가능 |
| **Exp 2a** | PCIe **eDMA** 하드웨어 대역폭 (NVIDIA 테스트 드라이버) | ✅ 실행 가능 |
| **Exp 2b/2c** | PCIe **Direct DMA** 커널 드라이버 + NCCL net plugin → 분산추론 | 🚧 Phase 2 ([설계](docs/03_direct_dma_plan.md)) |

- **모델**: GPT-OSS-20B (vLLM), ViT-B/16 · ViT-H/14 (PyTorch, Megatron 방식 TP 직접 구현)
- **측정**: 링크 대역폭(iperf3, eDMA) → NCCL all-reduce(크기별 지연, 대역폭) → ViT(img/s, 통신 비중) → GPT-OSS(TTFT, TPOT, tok/s)
- **기반**: [dusty-nv/jetson-containers distributed inference](https://github.com/dusty-nv/jetson-containers/blob/master/docs/distributed-inference.md) (Jetson 패치 NCCL 2.27.7 + vLLM + Ray)

---

## 설계 원칙: 데이터 경로만 바꾼다

```
 Board A (RP, Ray head, orchestrator)               Board B (EP, Ray worker)
   10GbE  10.0.0.1  ════════ 제어: Ray/vLLM/torch store/SSH ════════  10.0.0.2
   VNET   192.168.2.2 ══════ Exp 1 데이터 (PCIe 위 TCP/IP) ══════════ 192.168.2.1
   eDMA   C5 RP      ═══════ Exp 2 데이터 (PCIe DMA) ═══════════════ C5 EP
```
- 실험마다 바뀌는 것은 **NCCL all-reduce가 지나는 경로뿐**입니다. `lib/transport.sh`가 transport별로 `NCCL_SOCKET_IFNAME`, `NCCL_NET` 등을 설정합니다.
- 모델, 코드, 컨테이너, 클럭(MAXN + `jetson_clocks`), 측정 스크립트는 모든 실험에서 같습니다.
- 각 실행의 NCCL 로그(`NET/Socket : Using <iface>`)를 저장해서 실제로 어느 경로를 썼는지 확인할 수 있게 합니다.

---

## 빠른 시작

### 0) 하드웨어와 OS (최초 1회) → [docs/01_hardware_and_flash.md](docs/01_hardware_and_flash.md)
1. 두 보드에 **JetPack 6.2.3 (L4T R36.5)**을 설치합니다.
2. **Board B만** EP 모드로 재플래시합니다: `setup/flash/flash_ep.sh`
3. 케이블을 연결합니다: **Board A 슬롯 ← R33L ← K88VS → Board B 슬롯**. 그리고 **R33L 전원 점퍼 JP1–JP5를 분리(2–3)**로 설정합니다.
4. 10GbE 랜선을 연결합니다.

### 1) 두 보드 공통
```bash
git clone https://github.com/TranserZ/Jetson_Distributed_Inference.git ~/Jetson_Distributed_Inference
cd ~/Jetson_Distributed_Inference
vi config/cluster.env            # IP, 사용자명 확인 (두 보드 동일하게)
sudo setup/host_common.sh        # 패키지, MAXN, docker, sudoers
sudo setup/net_ctrl.sh eth0      # 10GbE 고정 IP (A=10.0.0.1, B=10.0.0.2)
# 재로그인 (docker 그룹 반영)
```

### 2) Board A에서만
```bash
setup/ssh_setup.sh               # A→B 비밀번호 없는 SSH
setup/pull_images.sh             # 양쪽 이미지 pull + digest 비교 + NCCL/vLLM 버전 확인
setup/download_models.sh --both  # gpt-oss-20b, ViT-B/16, ViT-H/14, tiktoken
experiments/check.sh             # 사전 점검 체크리스트
```

### 3) 실험 (Board A에서 실행, B는 SSH로 자동 제어)
```bash
experiments/exp0_baseline.sh            # 단일 보드 + 10GbE TP=2
experiments/exp1_vnet.sh                # PCIe VNET (자동으로 bringup vnet)
experiments/exp2_dma.sh 2a              # PCIe eDMA 하드웨어 대역폭
python3 analysis/report.py              # → analysis/out/summary.md, *.png, *.csv
```
일부만 실행하려면 suite 이름을 붙입니다: `experiments/exp1_vnet.sh link allreduce` (선택지: `link` `allreduce` `vit` `llm`)

---

## 디렉토리 구조

```
config/cluster.env      ← 유일하게 수정하는 설정 (IP, 모델, sweep 범위, 반복 수)
lib/                    ← 공통 함수
  common.sh             역할 자동판별(EP 컨트롤러 존재 여부), 로깅, SSH, 결과 메타데이터
  transport.sh          transport → NCCL/Gloo/vLLM 환경변수 매핑 (실험 간 유일한 차이)
  cluster.sh            양쪽 컨테이너 기동, torchrun 2노드 실행
setup/                  ← 환경 구성
  flash/flash_ep.sh     Board B EP 모드 플래시 (x86 호스트)
  host_common.sh        패키지, MAXN, docker, sudoers
  net_ctrl.sh           10GbE 고정 IP
  ssh_setup.sh          A→B SSH
  pcie_mode.sh          C5 모드 전환: vnet | dmatest | off | status (각 보드, root)
  bringup.sh            양쪽 보드를 올바른 순서로 전환 (A에서 실행)
  pull_images.sh, download_models.sh
docker/run_node.sh      ← transport별 환경변수를 넣어 컨테이너 기동
bench/                  ← 측정 도구 (모든 실험 공유)
  link/iperf.sh         TCP/UDP, 단일·병렬 스트림, 양방향, ping
  link/dma_test.sh      NVIDIA eDMA 테스트 실행 + dmesg 파싱
  allreduce_bench.py    8 B ~ 256 MiB all-reduce 지연과 busbw, 정확성 검증
  vit_tp.py             ViT Megatron-TP (layer당 all-reduce 2회), 통신 시간 분해, --verify
  llm_vllm.sh           Ray + vllm serve + `vllm bench serve` sweep (TP / TP+EP)
experiments/            ← 실험 진입점
  check.sh, exp0_baseline.sh, exp1_vnet.sh, exp2_dma.sh, run.sh(공통 러너)
kernel/pcie_dma/        ← [Phase 2] Direct DMA 커널 모듈
nccl-plugin/pciedma/    ← [Phase 2] NCCL net plugin (ncclNet_v10)
results/<exp>/<transport>/<timestamp>/   ← 원본 로그 + JSON + meta.json (자동 생성)
analysis/report.py      ← 표, 그래프 생성
docs/                   ← 하드웨어·플래시, DMA 테스트, Phase 2 설계, 트러블슈팅
```

## 측정 항목

| 계층 | 도구 | 지표 | 비교 대상 |
|---|---|---|---|
| 링크 | iperf3 / eDMA test | Gbps, 손실률, ping RTT | 10GbE vs VNET vs eDMA |
| 통신 | `allreduce_bench.py` | 크기별 지연(us), busbw(GB/s) | 10GbE vs VNET (vs DMA plugin) |
| ViT-B/16, ViT-H/14 | `vit_tp.py` | img/s, 지연, **통신 시간 비중**, batch 1–64 | 단일 vs 10GbE vs VNET |
| GPT-OSS-20B | `vllm bench serve` | TTFT, TPOT, ITL, 출력 tok/s, 입력 128–2048, 동시 요청 1–8 | 단일 vs 10GbE vs VNET, TP vs TP+EP |

**예상 결과(검증 대상)**
- LLM 토큰 생성(decode)은 all-reduce 1회가 약 6 KB로 작아서 **지연에 민감**합니다.
- ViT의 큰 batch와 LLM prefill은 1회가 수 MB에서 수십 MB라 **대역폭에 민감**합니다.
- 따라서 경로에 따른 차이는 후자에서 크게 나타날 것으로 예상합니다.

## 참고
- NVIDIA Jetson Linux r36.5 — *PCIe Endpoint Mode* (ODMDATA, `pci-epf-tegra-vnet`, `pci-epf-dma-test`)
- NVIDIA Forum #340574 — AGX Orin↔Orin NX: eDMA 54 Gbps vs VNET 약 4.5 Gbps (Gen4 x4)
- dusty-nv/jetson-containers PR #1429, #1446 — Jetson NCCL 패치
