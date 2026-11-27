# 실행 가이드 (Step-by-step)

**Claude Code를 각 Jetson에 띄울 필요는 없습니다.** 모니터도 처음 설정할 때만 필요합니다.
명령은 모두 **Board A 한 곳에서만** 실행하고, Board B는 스크립트가 SSH로 알아서 제어합니다.

## 전체 그림

```
 [내 PC] ──SSH(Wi-Fi/공유기)──► [Board A (RP)] ══PCIe══ [Board B (EP)]
                                 │          └── 10GbE 랜선 ──┘
                                 └ 모든 명령은 여기서 실행 (B는 SSH로 자동 제어)
```

| 연결 | 용도 |
|---|---|
| **Wi-Fi (또는 공유기)** | 인터넷 연결용입니다. git clone, 컨테이너 이미지와 모델 다운로드(수십 GB)에 씁니다. |
| **10GbE 랜선** | A와 B를 직접 잇습니다. 제어용 전용(Ray, SSH)이라 인터넷은 이걸로 되지 않습니다. |
| **PCIe 케이블** | 실험 데이터(all-reduce)가 지나가는 경로입니다. |

---

## Step 1. OS 설치 (최초 1회, x86 Ubuntu PC 필요)

1. 두 보드 모두 **SDK Manager로 JetPack 6.2.3 (L4T R36.5)**을 설치합니다. USB-C 케이블로 연결한 상태에서 recovery 모드로 진행합니다.
2. **Board B만** EP 모드로 다시 플래시합니다. 이 레포를 PC에 clone한 뒤 실행합니다.
   ```bash
   sudo setup/flash/flash_ep.sh ~/nvidia/nvidia_sdk/JetPack_6.2.3_Linux_*/Linux_for_Tegra
   ```
   다시 플래시하면 CUDA와 docker가 빠질 수 있습니다. 그러면 B에서 아래 명령을 실행합니다.
   ```bash
   sudo apt update && sudo apt install nvidia-jetpack
   ```
3. 첫 부팅 설정(사용자 계정 만들기)은 **각 보드에 모니터와 키보드를 연결해서** 합니다.
   - 두 보드의 **사용자 이름을 같게** 하세요. `config/cluster.env`의 기본값이 같은 이름을 전제로 합니다.
   - 이때 **Wi-Fi도 같이 연결**하고, `ip a`로 Wi-Fi IP를 확인해 둡니다.

## Step 2. 케이블 연결 (전원 끈 상태에서)

1. PCIe: **Board A 슬롯 ← R33L ← K88VS → Board B 슬롯**
2. R33L 점퍼 **JP1–JP5를 분리(2–3)**로 설정합니다. 테스터로 3V_AUX_EP를 확인합니다.
3. 10GbE 랜선으로 A와 B를 직접 연결합니다.

자세한 그림과 주의사항은 [docs/01_hardware_and_flash.md](docs/01_hardware_and_flash.md)에 있습니다.

## Step 3. 두 보드 공통 설정 (각 보드에서 1회)

이 단계부터는 모니터 대신 PC에서 `ssh <user>@<Wi-Fi IP>`로 접속해도 됩니다.

```bash
git clone https://github.com/TranserZ/Jetson_Distributed_Inference.git ~/Jetson_Distributed_Inference
cd ~/Jetson_Distributed_Inference
sudo setup/host_common.sh      # 패키지, MAXN 성능 모드, docker 설정
sudo setup/net_ctrl.sh eth0    # 10GbE IP 설정 (A=10.0.0.1, B=10.0.0.2, 자동 판별)
sudo reboot
```

## Step 4. Board A에서 준비 (1회)

```bash
setup/ssh_setup.sh               # A→B 비밀번호 없이 SSH (B 비밀번호 한 번 입력)
setup/pull_images.sh             # 컨테이너 이미지를 양쪽에 다운로드
setup/download_models.sh --both  # GPT-OSS-20B, ViT 두 개를 양쪽에 다운로드
experiments/check.sh             # 모든 항목이 ✅인지 확인
```

## Step 5. 실험 실행 (Board A에서)

```bash
experiments/exp0_baseline.sh   # 참고값: 단일 보드
experiments/exp1_vnet.sh       # PCIe VNET: 링크, all-reduce, ViT, GPT-OSS
experiments/exp2_dma.sh 2a     # PCIe eDMA: 링크 대역폭
python3 analysis/report.py     # 결과는 analysis/out/summary.md 와 그래프
```

- 몇 시간씩 걸리므로 **`tmux` 안에서 실행**하세요. SSH가 끊겨도 실험은 계속됩니다.
- 처음에는 짧게 시험해 보는 걸 권합니다. 예: `experiments/exp1_vnet.sh link allreduce`
- 실험 범위(batch, 입력 길이, 반복 수 등)는 `config/cluster.env`에서 바꿉니다.

## Step 6. 문제가 생기면

- 결과와 로그는 `results/<실험>/<경로>/<시각>/`에 쌓입니다.
- 흔한 문제와 해결법은 [docs/troubleshooting.md](docs/troubleshooting.md)에 있습니다.
- 에러 출력이나 로그 폴더를 Claude Code(내 PC)에 보여주면 고쳐서 push합니다. 보드에서는 `git pull`만 하면 됩니다.
- Board A에만 Claude Code를 설치해서 직접 명령을 실행하며 디버깅할 수도 있습니다. B에는 설치할 필요가 없습니다.
