# 02. NVIDIA eDMA 테스트 (Exp 2a)

JetPack 6.2.3(r36.5) 문서 기준입니다. 참고로 r39(JetPack 7.2)부터는 공식 문서에서 이 테스트가 빠졌습니다. JetPack 6.2.3을 선택한 이유 중 하나입니다.

## 구성
- **EP (Board B)**: `pci-epf-dma-test` 모듈과 configfs function `tegra_pcie_dma_epf`(10de:229a)를 C5(`141a0000`)에 연결합니다.
- **RP (Board A)**: EP 장치를 인식하고, RP 측 테스트 드라이버가 있으면 로드합니다(`tegra_pcie_dma_test` 등). 문서에 모듈 이름이 명시되어 있지 않아서, 스크립트가 후보 이름을 차례로 시도합니다.
- 실행: `experiments/exp2_dma.sh 2a`
  - 내부적으로 `setup/bringup.sh dmatest`를 실행한 뒤 `bench/link/dma_test.sh`를 양쪽에서 실행합니다.

## debugfs 파라미터 (`config/cluster.env`)

| 변수 | 파일 | 의미 |
|---|---|---|
| `DMA_SIZE` | `dma_size` | 한 번의 소프트웨어 전송 크기 (기본 16 MiB) |
| `DMA_NENTS` | `nents` | 한 번 제출할 때의 descriptor 수 (기본 4) |
| `DMA_STRESS` | `stress_count` | 반복 횟수 (기본 1000) |
| `DMA_EDMA_CH` | `edma_ch` | bit[0:3] 채널별 sync(0)/async(1), bit[4:7] 채널 enable, bit31 remote eDMA 모드. 공백으로 나눠 여러 값을 적으면 모두 측정 |

- 제약: `nents × dma_size < 127 MB`
- 결과는 dmesg에서 `Perf is N Mbps` 또는 `Cumulative Perf N Mbps` 줄을 찾아 파싱합니다.

## 기준값
| 환경 | 결과 |
|---|---|
| 포럼 340574: AGX Orin(RP) ↔ Orin NX(EP), Gen4 x4, WR | 54,116 Mbps (이론치의 약 86%) |
| NVIDIA 문서 예시 로그 | 105,522 Mbps |

이번 구성(AGX↔AGX, Gen4 x8)에서는 **약 100 Gbps**를 기대합니다.

## 주의
- 이 테스트는 **테스트용 버퍼를 대상으로 한 DMA**입니다. GPU 텐서나 NCCL과는 무관하며, 경로의 하드웨어 상한을 측정하는 용도입니다.
- VNET 모드와 dmatest 모드는 같은 C5 function 자리를 쓰므로 **동시에 켤 수 없습니다.** 전환할 때는 `setup/bringup.sh vnet|dmatest`를 쓰세요.
