# Troubleshooting

| 증상 | 확인할 것 |
|---|---|
| RP에서 `0005:01:00.0`이 안 보임 | ① EP function을 먼저 start했는지 (`sudo setup/pcie_mode.sh status` on B) ② `sudo setup/pcie_mode.sh rescan` on A ③ 그래도 안 되면 B를 켜 둔 채 **A만 재부팅** ④ R33L이 A에, K88VS 금핀이 B에 꽂혔는지 ⑤ `3V_AUX_EP` 전압(PERST# 버퍼 전원) |
| 링크가 Gen3, x4 이하 | 케이블 재장착, 케이블 길이(20 cm 권장), `dmesg | grep -i pcie`, 신호 무결성 테스트 |
| VNET 인터페이스가 안 생김 | A: `dmesg | grep -i vnet`, `lspci -nn -d 10de:2296` / B: `dmesg | tail`. NetworkManager가 인터페이스를 가져갔으면 `nmcli dev set <if> managed no` |
| VNET ping 지연이 ms 단위 | 포럼 340574에서도 같은 현상이 보고됨(1.5–4.8 ms). 원인 분석 대상이며 결과로 기록 |
| NCCL이 엉뚱한 인터페이스를 씀 | `results/.../rank0.log`에서 `NET/Socket : Using ...` 줄 확인. `NCCL_SOCKET_IFNAME`은 `lib/transport.sh`에서 transport별로 자동 설정 |
| `Failed to find nvml device` WARN | Jetson NCCL 패치에서 의도된 경고(NVML 없음). 무시 가능 |
| vLLM 서버가 뜨지 않음 | `results/.../llm/<mode>/logs/vllm_server.log`. 첫 실행 시 커널 컴파일로 10분 이상 걸릴 수 있음. OOM이면 `LLM_KV_CACHE_BYTES`, `LLM_MAX_MODEL_LEN`을 줄임 |
| Ray worker가 안 붙음 | 두 보드 이미지 digest가 같은지 (`setup/pull_images.sh`), 6379 포트 방화벽, `VLLM_HOST_IP` |
| `sudo -n` 실패 (EP) | Board B에서 `sudo setup/host_common.sh`를 실행했는지. 레포 경로가 A와 같은지 (`EP_REPO_DIR`) |
| 이미지가 R36.5 호스트에서 오동작 | r36.4용 이미지임. `docker/README.md`의 직접 빌드 방법 사용 |
