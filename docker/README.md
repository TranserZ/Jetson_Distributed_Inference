# Container image

기본값(`config/cluster.env`의 `IMAGE`)은 dusty-nv jetson-containers 분산추론 문서에서 쓰는 이미지입니다.

```
mitakad/vllm:0.11.2-r36.4.tegra-aarch64-cp310-cu126-22.04-truncated
```
- 이 이미지에는 Jetson용으로 패치된 **NCCL 2.27.7**, 그 NCCL로 빌드한 PyTorch, vLLM 0.11.2가 들어 있습니다.
- NCCL 패치 내용(PR #1429/#1446): Jetson에는 NVML이 없으므로, NVML 조회가 실패하면 `cudaDeviceGetByPCIBusId`로 대체하고 경고만 남깁니다(`src/graph/xml.cc`, `src/init.cc`).
- 제3자 이미지이므로, 실험 재현성을 위해 `setup/pull_images.sh`가 digest를 기록하고 `results/*/meta.json`에도 남깁니다.

## 직접 빌드 (이미지가 R36.5에서 문제를 일으킬 때)
jetson-containers로 Board A에서 빌드합니다. 수 시간이 걸립니다.
```bash
git clone https://github.com/dusty-nv/jetson-containers && bash jetson-containers/install.sh
ENABLE_DISTRIBUTED_JETSON_NCCL=1 PYTORCH_FORCE_BUILD=on jetson-containers build vllm
# 빌드된 태그를 config/cluster.env 의 IMAGE에 넣고, docker save | ssh B docker load 로 B에 복사
```
- PR #1429 시절의 플래그 이름은 `ENABLE_NCCL_DISTRIBUTED_JETSON`이었고, #1446에서 `ENABLE_DISTRIBUTED_JETSON_NCCL`로 바뀌었습니다.
