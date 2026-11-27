# 03. Direct DMA 분산추론 설계 (Exp 2b / 2c, Phase 2)

> 상태: **설계 단계**입니다. 2a(NVIDIA eDMA 테스트)는 바로 실행할 수 있지만, 2b와 2c는 보드에서 디버깅하며 구현할 예정입니다.

## 왜 별도 구현이 필요한가
- NVIDIA는 DMA를 **debugfs 테스트 데모**(`pci-epf-dma-test`)로만 제공합니다. 공식 문서에도 "EP function driver는 직접 구현해야 한다"고 명시되어 있습니다.
- vLLM과 PyTorch는 NCCL을 거쳐 통신합니다. 그래서 **NCCL이 DMA를 통신 수단으로 쓰게 만들면** 상위 코드를 수정할 필요가 없습니다.

## 구조
```
vLLM / PyTorch  (수정 없음)
      │ all-reduce
NCCL 2.27.7 (Jetson patch)
      │ NCCL_NET_PLUGIN=pciedma            ← bootstrap은 Socket(10GbE)
libnccl-net-pciedma.so  (ncclNet_v10, ptrSupport=NCCL_PTR_HOST)   [nccl-plugin/]
      │ ioctl / mmap
/dev/pcie_dma0          (EP/RP 커널 모듈)                          [kernel/pcie_dma/]
      │ eDMA write → 상대 BAR 윈도우, MSI/doorbell로 완료 통지
PCIe Gen4 x8
```

## 2b: 커널 모듈 (`kernel/pcie_dma/`)
- **출발점**: L4T r36.5 public sources의 `nvidia-oot` 아래 `pci-epf-dma-test.c`, `pci-epf-tegra-vnet.c`, `tegra_vnet.c`
  - VNET 드라이버가 BAR 공유 메모리, 링 버퍼, MSI 처리를 이미 구현하고 있어서 가장 좋은 참고 자료입니다.
- **EP function 드라이버**
  - DMA용 coherent 링 버퍼를 할당하고 BAR0로 노출합니다.
  - eDMA 채널로 RP의 버퍼(outbound iATU 윈도우)에 write합니다.
- **RP PCI 드라이버** (10de:<새 device id>)
  - BAR를 매핑하고, RP 측 수신 링을 할당한 뒤 그 주소를 EP에 알립니다.
- **유저 인터페이스**: `/dev/pcie_dma0`
  - `mmap`: 송신·수신 링을 유저 공간에 매핑
  - `ioctl(SUBMIT{off,len}) / ioctl(WAIT)`: 전송 요청과 완료 대기
  - 완료 통지: MSI(EP→RP), doorbell 레지스터(RP→EP)
- **단독 벤치**: 크기별 ping-pong으로 지연과 대역폭을 측정합니다. iperf(VNET), edmalib(2a) 결과와 같은 표에 넣어 비교합니다.
- **방향 주의**: eDMA 엔진은 EP 측에 있습니다. RP→EP 전송은 EP 엔진의 **read 채널**로 처리하거나, RP가 CPU로 BAR에 memcpy하는 방식(느림)과 비교 측정합니다.

## 2c: NCCL net plugin (`nccl-plugin/pciedma/`)
- **API**: NCCL 2.27.7은 `ncclNet_v10_t`를 사용합니다. 심볼 `ncclNetPlugin_v10`을 export합니다.
- **최소 구현 범위**
  - `ptrSupport = NCCL_PTR_HOST`만 지원합니다. NCCL이 GPU 데이터를 host 버퍼로 복사해 넘겨 줍니다.
  - Jetson은 GPU와 CPU가 같은 LPDDR5를 공유해서 이 복사 비용이 dGPU보다 작습니다.
  - `listen`, `connect`, `accept`는 non-blocking으로 구현합니다. handle(128 B 이하)에 `/dev` 정보와 링 offset을 담습니다.
  - `isend`, `irecv`, `test`: v1은 bounce 방식입니다. 등록된 host 버퍼의 데이터를 DMA 링으로 memcpy한 뒤 eDMA로 보냅니다.
  - v2(선택)는 zero-copy 방식입니다. `regMr`에서 사용자 페이지를 pin(`pin_user_pages` + `dma_map_sg`)해서 직접 전송합니다.
- **환경변수**
  - `NCCL_NET_PLUGIN=pciedma`
  - `NCCL_SOCKET_IFNAME=<10GbE>`: bootstrap 전용
  - transport 이름은 `dma` (`lib/transport.sh`)
- **검증 순서**
  1. `bench/allreduce_bench.py`로 정확성(correct=OK)을 확인합니다.
  2. 크기별 busbw를 VNET, 10GbE와 비교합니다.
  3. ViT와 vLLM을 실행합니다.

## 리스크
- 커널 모듈은 L4T 커널 버전에 묶여 있습니다. 두 보드 모두 R36.5.x로 고정하고, 빌드는 보드에서 `make -C /lib/modules/$(uname -r)/build`로 합니다.
- eDMA API(`tegra_pcie_edma_*`)는 nvidia-oot 내부 API라서 버전마다 바뀔 수 있습니다.
- NCCL이 plugin을 거쳐 소수의 큰 링 버퍼로 통신하므로, 링 크기와 채널 수 튜닝(`NCCL_BUFFSIZE`, `NCCL_NCHANNELS`)이 필요합니다.
