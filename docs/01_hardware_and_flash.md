# 01. 하드웨어 연결과 플래시

## 1. 구성품

| 품목 | 모델 | 역할 |
|---|---|---|
| Jetson AGX Orin 64GB Devkit ×2 | Board A, Board B | A = Root Port(RP), B = Endpoint(EP) |
| ADT-Link **R33L** | PCIe x16 male→female **Tx-Rx SWAP** board | TX/RX 교차, 측대역 신호 버퍼 |
| ADT-Link **K88VS** (20 cm) | PCIe 4.0 x8 goldfinger↔goldfinger, **Tx→Tx 직결** | 보드 간 연장 |
| 10GbE 랜선 (또는 스위치) | Devkit RJ45 | 제어 경로 + 기준선 |

> ⚠️ **K88NS를 쓰면 안 됩니다.** K88NS도 Tx↔Rx를 교차하므로 R33L과 합쳐 두 번 교차하게 되고, 결과적으로 교차가 없는 상태가 됩니다. 교차는 R33L에서 **정확히 한 번**만 일어나야 합니다.

## 2. 연결 방법

```
 Board A (RP)                                                   Board B (EP)
 ┌──────────────┐                                               ┌──────────────┐
 │ PCIe x16 slot│◄── R33L 금핀(CN2, "_RP" 측)                    │ PCIe x16 slot│
 │   (C5, x8)   │    R33L 슬롯(CN1, "_EP" 측) ◄── K88VS 금핀 ─── K88VS 금핀 ──►│   (C5, x8)   │
 └──────────────┘                                               └──────────────┘
 └───────────── 10GbE RJ45 ◄────────── 랜선 ──────────► 10GbE RJ45 ─────────────┘
```

- R33L 회로도(V1.1) 기준으로 **금핀(CN2) 쪽 넷 이름이 `_RP`**, **슬롯(CN1) 쪽이 `_EP`**입니다. 따라서 **R33L은 Board A(RP)의 슬롯에 꽂습니다.**
- 링크 폭은 K88VS(x8)와 C5(x8)에 맞춰 **Gen4 x8**이 상한입니다. 이론 단방향 대역폭은 15.75 GB/s입니다.

### R33L 회로도에서 확인한 사항

| 신호 | 처리 방식 |
|---|---|
| TX/RX (16 lane) | CN1↔CN2 사이에서 교차 (`PETp0_RP` → EP 측 `PERp0`) |
| REFCLK± (A13/A14) | 버퍼 없이 그대로 통과 |
| PERST# | RP→EP 방향, `SN74AUP1G07`(U4) 버퍼 경유. 버퍼 전원은 **`3V_AUX_EP`** |
| WAKE# | EP→RP 방향, U3 버퍼 경유 (전원 `3V_AUX_RP`) |
| CLKREQ# | 양방향 각각 버퍼 (U1, U2) |
| 12V / 3.3V / 3.3VAUX | **JP1–JP5 점퍼(JP_SW)로 양측 연결 여부 선택** |

### ⚠️ 전원 점퍼 (JP1–JP5): 반드시 "분리"로 설정

각 JP_SW는 3핀입니다. **2번 핀이 공통, 1번이 상대측 전원, 3번은 미연결(NC)**입니다.

| 점퍼 | 연결 대상 | 설정 |
|---|---|---|
| JP1, JP2 | 12V_EP ↔ 12V_RP | **2–3 (분리)** 또는 점퍼 제거 |
| JP3, JP4 | 3V_EP ↔ 3V_RP | **2–3 (분리)** 또는 점퍼 제거 |
| JP5 | 3V_AUX | **2–3 (분리)** 또는 점퍼 제거 |

- 두 Devkit은 각자 어댑터로 전원을 받습니다. 그래서 **두 보드의 12V/3.3V 레일을 서로 묶으면 안 됩니다.**
- **전원을 켜기 전에** 멀티미터로 R33L의 `12V_RP`↔`12V_EP`, `3V_RP`↔`3V_EP` 사이가 **개방(open)** 상태인지 확인하세요.
- 확인 사항 하나 더: PERST# 버퍼(U4)는 `3V_AUX_EP`로 동작합니다. Board B를 부팅한 뒤 R33L의 `3V_AUX_EP` 쪽에 3.3V가 측정되는지 확인하세요. 측정되지 않으면 PERST#가 EP에 전달되지 않아 링크가 올라오지 않습니다. 이 경우 `docs/troubleshooting.md`를 참고하세요.

## 3. 플래시

### 3-1. 두 보드 모두: JetPack 6.2.3 (L4T R36.5.x)
- SDK Manager로 **JetPack 6.2.3**을 두 보드에 설치합니다. Jetson Linux와 Jetson Runtime/SDK Components를 모두 포함해야 합니다.
- 두 보드의 버전이 **반드시 같아야** 합니다. 확인 명령: `head -n1 /etc/nv_tegra_release` → `R36 (release), REVISION: 5.x`

### 3-2. Board B만: Endpoint 모드로 재플래시
NVIDIA Jetson Linux r36.5 "PCIe Endpoint Mode" 절차를 따릅니다.

1. x86 Ubuntu 플래시 호스트에서 SDK Manager가 만든 `Linux_for_Tegra` 경로를 확인합니다.
2. Board B를 Force Recovery 모드로 USB-C에 연결합니다.
3. 아래 명령을 실행합니다.
   ```bash
   sudo setup/flash/flash_ep.sh ~/nvidia/nvidia_sdk/JetPack_6.2.3_Linux_JETSON_AGX_ORIN_TARGETS/Linux_for_Tegra
   ```
   - 스크립트는 `jetson-agx-orin-devkit.conf`에 아래 줄을 임시로 추가해 플래시하고, 끝나면 conf를 원래대로 되돌립니다.
     `ODMDATA="gbe-uphy-config-22,nvhs-uphy-config-1,hsio-uphy-config-0,gbe0-enable-10g,hsstp-lane-map-3";`
   - `nvhs-uphy-config-1`이 C5를 EP 모드로 바꾸는 설정입니다. `gbe0-enable-10g`가 들어 있어 **10GbE는 계속 쓸 수 있습니다.**
4. Board B가 부팅하면 SDK Components(Docker, nvidia-container 등)를 다시 설치합니다. SDK Manager에서 "Jetson OS" 항목을 빼고 설치하면 됩니다.
5. 확인: `ls /sys/kernel/config/pci_ep/controllers/` → `141a0000.pcie-ep`가 보여야 합니다.

## 4. 부팅 순서
**EP(B) 기능을 먼저 시작하고, 그다음 RP(A)가 장치를 인식(enumerate)해야 합니다.**
- `setup/bringup.sh`가 이 순서를 자동으로 처리합니다. EP에서 function을 시작한 뒤 RP에서 rescan과 controller rebind를 수행합니다.
- rebind로도 EP가 보이지 않으면, B에서 function을 시작한 상태로 **A만 재부팅**합니다.

## 5. 링크 확인 (Board A)
```bash
sudo setup/pcie_mode.sh status
lspci -vv -s 0005:01:00.0 | grep -E 'LnkCap|LnkSta'
# 기대값: LnkSta: Speed 16GT/s, Width x8
```
Gen3나 x4 이하로 잡히면 케이블 장착 상태와 신호 품질을 의심해야 합니다. NVIDIA 포럼에서는 `pcie_ep_fdmatest -s`(신호 무결성 테스트)를 권장합니다.
