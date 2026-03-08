/*
 * Hardened Softmax Pipeline — Bare-Metal Firmware
 * ================================================
 * Runs on Zynq UltraScale+ ARM Cortex-A53 (PS).
 * Drives the softmax engine IP via memory-mapped CSR at 0x80000000.
 *
 * Build: Vitis IDE → create platform from .xsa → create app from this file
 * Or: aarch64-none-elf-gcc -O2 -o fw.elf main.c -T lscript.ld
 */

#include <stdint.h>
#include <stdio.h>

/* ---- CSR Base Address (from block design address map) ---- */
#define SOFTMAX_BASE    0x80000000UL

/* ---- Register Offsets ---- */
#define REG_CTRL            0x00
#define REG_STATUS          0x04
#define REG_SEQ_LEN         0x08
#define REG_HEAD_DIM        0x0C
#define REG_TILE_BR         0x10
#define REG_TILE_BC         0x14
#define REG_Q_BASE          0x18
#define REG_K_BASE          0x1C
#define REG_V_BASE          0x20
#define REG_O_BASE          0x24
#define REG_SCALE_BASE      0x28
#define REG_PERF_CYCLES     0x30
#define REG_PERF_GEMM       0x34
#define REG_PERF_SOFTMAX    0x38
#define REG_PERF_STALL      0x3C  /* THE METRIC */
#define REG_PERF_MEM        0x40
#define REG_PERF_TILES      0x44
#define REG_PERF_EXP        0x48

/* ---- Control Bits ---- */
#define CTRL_START          (1U << 0)
#define CTRL_FP8_EN         (1U << 1)
#define CTRL_INCOHERENT_EN  (1U << 2)

/* ---- Status Bits ---- */
#define STATUS_BUSY         (1U << 0)
#define STATUS_DONE         (1U << 1)
#define STATUS_ERROR        (1U << 2)

/* ---- Register Access ---- */
static volatile uint32_t *const softmax_regs =
    (volatile uint32_t *)SOFTMAX_BASE;

static inline void reg_write(uint32_t offset, uint32_t value) {
    softmax_regs[offset / 4] = value;
}

static inline uint32_t reg_read(uint32_t offset) {
    return softmax_regs[offset / 4];
}

/* ---- DDR Addresses for Q/K/V/O Buffers ---- */
#define DDR_Q_BASE      0x10000000UL
#define DDR_K_BASE      0x20000000UL
#define DDR_V_BASE      0x30000000UL
#define DDR_O_BASE      0x40000000UL

/* ---- Run Attention ---- */
int run_attention(uint32_t seq_len, uint32_t head_dim,
                  uint32_t tile_br, uint32_t tile_bc) {

    printf("Configuring softmax engine: N=%u, d=%u, Br=%u, Bc=%u\n",
           seq_len, head_dim, tile_br, tile_bc);

    /* Configure */
    reg_write(REG_SEQ_LEN,    seq_len);
    reg_write(REG_HEAD_DIM,   head_dim);
    reg_write(REG_TILE_BR,    tile_br);
    reg_write(REG_TILE_BC,    tile_bc);
    reg_write(REG_Q_BASE,     DDR_Q_BASE);
    reg_write(REG_K_BASE,     DDR_K_BASE);
    reg_write(REG_V_BASE,     DDR_V_BASE);
    reg_write(REG_O_BASE,     DDR_O_BASE);

    /* Start */
    printf("Starting computation...\n");
    reg_write(REG_CTRL, CTRL_START);

    /* Poll for completion */
    uint32_t status;
    uint32_t timeout = 10000000;
    do {
        status = reg_read(REG_STATUS);
        timeout--;
    } while (!(status & STATUS_DONE) && timeout > 0);

    if (timeout == 0) {
        printf("ERROR: Timeout waiting for completion\n");
        return -1;
    }

    if (status & STATUS_ERROR) {
        printf("ERROR: Engine reported error (STATUS=0x%08x)\n", status);
        return -2;
    }

    /* Read performance counters */
    uint32_t cycles   = reg_read(REG_PERF_CYCLES);
    uint32_t gemm_c   = reg_read(REG_PERF_GEMM);
    uint32_t softmax_c = reg_read(REG_PERF_SOFTMAX);
    uint32_t stall_c  = reg_read(REG_PERF_STALL);
    uint32_t mem_c    = reg_read(REG_PERF_MEM);
    uint32_t tiles    = reg_read(REG_PERF_TILES);
    uint32_t exp_ops  = reg_read(REG_PERF_EXP);

    printf("\n");
    printf("=== Performance Report ===\n");
    printf("  Total cycles:         %u\n", cycles);
    printf("  GEMM cycles:          %u\n", gemm_c);
    printf("  Softmax cycles:       %u\n", softmax_c);
    printf("  Stall cycles:         %u  *** THE METRIC ***\n", stall_c);
    printf("  Memory stall cycles:  %u\n", mem_c);
    printf("  Tiles computed:       %u\n", tiles);
    printf("  Exp operations:       %u\n", exp_ops);
    printf("\n");

    if (stall_c == 0) {
        printf("  >>> ZERO STALL CYCLES — Softmax never blocked GEMM <<<\n");
    } else {
        printf("  WARNING: %u stall cycles detected\n", stall_c);
        printf("  Stall ratio: %.2f%%\n", (float)stall_c / cycles * 100.0f);
    }

    /* Compute throughput at 400 MHz */
    float time_us = (float)cycles / 400.0f;  /* 400 MHz = 400 cycles/us */
    uint64_t total_flops = 4ULL * seq_len * seq_len * head_dim;
    float tflops = (float)total_flops / (time_us * 1e6f);

    printf("\n");
    printf("  Wall time:            %.1f us\n", time_us);
    printf("  Throughput:           %.2f TFLOPS\n", tflops);
    printf("==========================\n\n");

    return 0;
}

/* ---- Main ---- */
int main(void) {
    printf("\n");
    printf("============================================\n");
    printf("  Hardened Softmax Pipeline — Firmware\n");
    printf("  ZCU104 @ 400 MHz\n");
    printf("============================================\n\n");

    /* Test 1: Small sequence */
    run_attention(128, 128, 128, 128);

    /* Test 2: Medium sequence */
    run_attention(256, 128, 128, 128);

    /* Test 3: Larger sequence */
    run_attention(1024, 128, 128, 128);

    printf("All tests complete.\n");
    return 0;
}
