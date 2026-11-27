# kernel/pcie_dma (Phase 2 — Exp 2b)

Direct DMA 커널 모듈이 들어갈 자리입니다. EP function 드라이버와 RP PCI 드라이버로 구성되며, 유저 인터페이스는 `/dev/pcie_dma0`입니다.
설계는 [docs/03_direct_dma_plan.md](../../docs/03_direct_dma_plan.md)를 참고하세요.
