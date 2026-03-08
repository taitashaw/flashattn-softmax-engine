# Hardened Online Softmax Pipeline with FP8 Support and HBM-Aware Tiling
## FPGA Prototype for Next-Generation Attention Acceleration

### Revision 1.0 — March 2026

---

## 1. The Problem This Solves (In NVIDIA's Own Numbers)

The H100 SXM5 GPU delivers:
- **989 TFLOPS** of FP16 matrix multiply (via WGMMA on Tensor Cores)
- **3.9 TFLOPS** of special functions (exp, log — via MUFU)
- That is a **256× throughput gap**

For attention with head dimension 128:
- There are 512× more matmul FLOPS than exp operations
- But exp has 256× lower throughput
- **Result: exp (softmax) consumes ~50% of wall-clock cycles relative to matmul**

FlashAttention-3 partially hides this by overlapping softmax with GEMMs across
warpgroups ("pingpong scheduling"), achieving 75–85% peak utilization. But the
MUFU remains a shared, general-purpose bottleneck. It serves exp, log, sin, cos,
rsqrt — all through the same fixed-function unit.

**Thesis:** A dedicated, fully-pipelined softmax unit — purpose-built in silicon —
eliminates the MUFU bottleneck entirely. This FPGA prototype demonstrates the
architecture, proves the throughput, and quantifies the silicon cost.

---

## 2. What This Prototype Is (and Is Not)

**This IS:**
- A fully-pipelined online softmax engine in RTL, processing 1 element/cycle
- An FP8 (E4M3/E5M2) input path with FP32 internal accumulation
- A tiled attention datapath that implements the FlashAttention algorithm exactly
- An HBM bandwidth model that sizes tiles to match real memory hierarchy constraints
- A silicon area/power argument for hardening softmax in next-gen accelerators

**This is NOT:**
- An approximate softmax (no LUT, no polynomial shortcuts — exact online algorithm)
- A sparse attention engine (NVIDIA explicitly chose exact over approximate)
- A replacement for FlashAttention (it's the hardware that makes FlashAttention faster)

---

## 3. Architecture Overview

```
         HBM (DDR4 on FPGA)
              │
              │ AXI4 (models HBM bandwidth: 3.35 TB/s ÷ scale factor)
              │
    ┌─────────▼──────────┐
    │   Tile Prefetcher   │   Double-buffered, tile-aware DMA
    │   (Producer Stage)  │   Loads Q_tile[Br×d], K_tile[Bc×d], V_tile[Bc×d]
    └─────────┬──────────┘
              │ Circular SRAM Buffer (models GPU shared memory)
              │
    ┌─────────▼──────────┐
    │   GEMM0: Q × K^T   │   Systolic array, FP8 input → FP32 accumulator
    │   (Br × Bc tile)   │   With block dequantization (1 scale per tile)
    └─────────┬──────────┘
              │ FP32 score tile (Br × Bc)
              │
    ┌─────────▼──────────────────────────────────────────┐
    │          HARDENED ONLINE SOFTMAX PIPELINE           │
    │                                                     │
    │   Stage 1: Row-max update (streaming)               │
    │            m_new = max(m_old, max(current_block))   │
    │                                                     │
    │   Stage 2: Exponential (dedicated, fully pipelined) │
    │            exp(x - m_new) via CORDIC or             │
    │            range-reduced polynomial                  │
    │            Throughput: 1 element/cycle               │
    │                                                     │
    │   Stage 3: Rescaling + accumulation                 │
    │            l_new = l_old × exp(m_old - m_new)       │
    │                     + sum(exp(x - m_new))           │
    │            O_new = O_old × exp(m_old - m_new)/l_new │
    │                     + exp(x - m_new) × V / l_new   │
    │                                                     │
    │   *** No MUFU contention — dedicated hardware ***   │
    └─────────┬──────────────────────────────────────────┘
              │ FP32 attention weights (Br × Bc)
              │
    ┌─────────▼──────────┐
    │   GEMM1: P × V     │   Reuses systolic array
    │   (Br × d tile)    │   Accumulates into running output O
    └─────────┬──────────┘
              │
    ┌─────────▼──────────┐
    │  Output Writeback   │   Quantize FP32 → FP8, write to HBM
    │  (Consumer Stage)   │   With block quantization (1 scale per tile)
    └─────────┬──────────┘
              │
              ▼
         HBM (DDR4 on FPGA)
```

---

## 4. The Key Innovation: Dedicated Pipelined Exponential Unit

On the H100, the MUFU computes exp via a shared ROM-based interpolation unit.
16 ops/SM/cycle × 132 SMs × 1830 MHz = 3.9 TFLOPS. It's shared with log, sin,
cos, rsqrt — so effective exp throughput during attention is even lower.

Our hardened exp unit uses **range reduction + degree-4 polynomial**:

```
exp(x) for x ∈ [-∞, 0] (softmax inputs are always ≤ 0 after max subtraction):

1. Range reduction: x = n × ln(2) + r, where n = floor(x / ln(2)), |r| ≤ ln(2)/2
2. Polynomial on reduced range: exp(r) ≈ 1 + r + r²/2 + r³/6 + r⁴/24
3. Reconstruction: exp(x) = 2^n × exp(r)    (2^n is a bit shift)

Precision: max relative error < 2^-23 (exceeds FP32 mantissa precision)
Latency: 5 cycles (range reduce → mul chain → reconstruct)
Throughput: 1 element/cycle (fully pipelined)
Resources: 4 DSP48E2 (for the polynomial) + ~300 LUT (range reduction + shift)
```

**Comparison to MUFU:**

| Metric | GPU MUFU (H100) | Our Hardened Exp | Advantage |
|--------|----------------|------------------|-----------|
| Throughput | 16 ops/SM/cycle (shared) | 1 op/cycle (dedicated) | No contention |
| Latency | ~20 cycles | 5 cycles | 4× lower |
| Sharing | exp, log, sin, cos, rsqrt | exp only | No interference |
| Accuracy | 1 ULP | < 2^-23 relative | Equivalent |

On the FPGA, with 1728 DSP48E2 available (ZCU104), we can instantiate **16 parallel
exp units** consuming only 64 DSPs — leaving 1664 DSPs for the systolic array.
This models what custom silicon could achieve: dedicating ~4% of the math
transistor budget to a hardened softmax pipeline that eliminates 50% of the
attention bottleneck.

---

## 5. FP8 Datapath Design

### 5.1 FP8 Formats

| Format | Sign | Exponent | Mantissa | Range | Use |
|--------|------|----------|----------|-------|-----|
| E4M3 | 1 | 4 | 3 | ±448 | Weights, activations (forward) |
| E5M2 | 1 | 5 | 2 | ±57344 | Gradients (backward) |

### 5.2 Data Flow Through Pipeline

```
HBM: FP8 E4M3 (Q, K, V stored as 8-bit)
  │
  ▼ Block dequantize: FP8 × scale_factor → FP32 (1 scale per Br×d tile)
  │
GEMM0: FP32 accumulation (QK^T scores)
  │
  ▼ Already FP32 — no conversion needed
  │
Softmax: FP32 throughout (exp, max, sum, div — all FP32)
  │
  ▼ FP32 attention weights
  │
GEMM1: FP32 accumulation (P × V output)
  │
  ▼ Block quantize: FP32 → FP8 E4M3 (with rounding, 1 scale per Br×d tile)
  │
HBM: FP8 E4M3 (output stored as 8-bit)
```

### 5.3 Block Quantization

Following FlashAttention-3's approach:
- One FP32 scale factor per tile (e.g., per 64×128 block)
- Scale = max(|tile|) / max_representable_fp8
- Dequant: fp8_val × scale → fp32_val
- Quant: fp32_val / scale → round_to_nearest_fp8

### 5.4 Incoherent Processing (FP8 Error Mitigation)

FlashAttention-3 uses a Hadamard transform with random signs to "spread out"
outlier values before quantization, reducing quantization error by 2.6×.

Our implementation:
- Apply 64×64 Walsh-Hadamard transform to Q and K before FP8 quantization
- Random sign matrix S (±1) generated from a seed, applied as element-wise multiply
- Inverse transform after attention computation
- Implementation: Hadamard is a butterfly network — 6 stages of add/subtract
  for d=64, requires 0 multipliers, only ~400 LUT

---

## 6. HBM-Aware Tiling

### 6.1 Memory Hierarchy Model

We model the GPU's memory hierarchy on FPGA to make the tiling analysis
directly transferable:

| GPU Level | FPGA Equivalent | Capacity | Bandwidth |
|-----------|----------------|----------|-----------|
| HBM (80GB, 3.35 TB/s) | DDR4 (4GB, 25.6 GB/s) | Scaled down | Scaled proportionally |
| L2 Cache (50MB) | Not modeled | — | — |
| Shared Memory (228KB/SM) | BRAM (11.7 Mb total) | ~200 KB usable | ~400 GB/s on-chip |
| Register File (256KB/SM) | FF/LUTRAM | ~64 KB usable | Unlimited (on-die) |

### 6.2 Tile Size Selection

FlashAttention tiles must fit in shared memory:
```
Q_tile: Br × d bytes     (one block of queries)
K_tile: Bc × d bytes     (one block of keys)
V_tile: Bc × d bytes     (one block of values)
O_tile: Br × d bytes     (running output accumulator)
S_tile: Br × Bc bytes    (score tile, not stored in HBM)

Total SRAM: (2×Br + 2×Bc) × d × bytes_per_element

For FP8 (1 byte/element), d=128:
  SRAM = (2×Br + 2×Bc) × 128 bytes

With 200KB SRAM budget:
  Br = Bc = 128 → SRAM = 4 × 128 × 128 = 64 KB  ✓ (fits easily)
  Br = Bc = 256 → SRAM = 4 × 256 × 128 = 128 KB  ✓ (fits)
  Br = Bc = 512 → SRAM = 4 × 512 × 128 = 256 KB  ✗ (too large)

Selected: Br = Bc = 128 (conservative, matching FlashAttention-3 defaults)
```

### 6.3 HBM Traffic Analysis

Per attention head, sequence length N, head dimension d:
```
Total reads:  N/Br × (Br×d + N×d + N×d) = N×d + N²×d/Br + N²×d/Br
            = N×d × (1 + 2N/Br)

For N=8192, d=128, Br=128:
  Total reads = 8192 × 128 × (1 + 2×8192/128) = 8192 × 128 × 129 = 135 MB

Total writes: N × d = 8192 × 128 = 1 MB

This is IO-bound when: read_bytes / compute_flops > HBM_bandwidth / compute_throughput
  135 MB / (4 × 8192² × 128) FLOPS = 135 MB / 34.4 GFLOPS = 3.9 ns/FLOP
  HBM: 3.35 TB/s / 989 TFLOPS = 3.4 ns/byte÷FLOP

Tiling makes attention compute-bound for large sequence lengths.
Our prototype measures the exact crossover point.
```

---

## 7. Verification Strategy

### 7.1 Bit-Exact Golden Model

```python
# The golden model implements FlashAttention's online softmax EXACTLY
# No approximations. No shortcuts. Every intermediate value is FP32.
# The hardware must match this to the last bit (within FP32 rounding).

def flash_attention_forward(Q, K, V, Br, Bc):
    """FlashAttention-2 forward pass (Algorithm 1 from the paper)."""
    N, d = Q.shape
    O = np.zeros((N, d), dtype=np.float32)
    l = np.zeros(N, dtype=np.float32)     # Running sum
    m = np.full(N, -np.inf, dtype=np.float32)  # Running max

    for j in range(0, N, Bc):
        Kj = K[j:j+Bc]  # (Bc, d)
        Vj = V[j:j+Bc]  # (Bc, d)

        for i in range(0, N, Br):
            Qi = Q[i:i+Br]  # (Br, d)

            # GEMM0: S = Q × K^T
            S = Qi @ Kj.T  # (Br, Bc)

            # Online softmax: update running max and sum
            m_old = m[i:i+Br].copy()
            m_new = np.maximum(m_old, S.max(axis=1))
            # *** THIS is where the hardened exp unit fires ***
            P = np.exp(S - m_new[:, None])
            l_new = l[i:i+Br] * np.exp(m_old - m_new) + P.sum(axis=1)

            # Rescale running output
            scale = np.exp(m_old - m_new)
            O[i:i+Br] = O[i:i+Br] * scale[:, None] + P @ Vj

            # Update running statistics
            m[i:i+Br] = m_new
            l[i:i+Br] = l_new

    # Final normalization
    O = O / l[:, None]
    return O
```

### 7.2 Verification Levels

| Level | Test | Pass Criterion |
|-------|------|----------------|
| Exp unit | 2^20 random inputs in [-20, 0] | Max relative error < 2^-20 vs. libm exp() |
| Online softmax (single row) | Random score vectors, len 32-4096 | Bit-exact match to NumPy (FP32) |
| Online softmax (tiled) | Full tiled pass, Br=Bc=128 | Bit-exact match to non-tiled softmax |
| FP8 dequant→compute→quant | Round-trip through FP8 pipeline | Error within 1 ULP of reference FP8 path |
| Incoherent processing | Hadamard + FP8 quant + inverse | RMSE < 0.01 vs. FP16 attention output |
| Full attention (FP32) | FlashAttention on 8192 seq len | Bit-exact match to PyTorch scaled_dot_product |
| Full attention (FP8) | FlashAttention-3 FP8 path | Match FlashAttention-3 reference within 1e-3 |
| Throughput | Measure cycles for N=1024-8192 | Softmax never stalls GEMM pipeline |

---

## 8. Deliverables and What Each Proves

| Deliverable | What It Proves to NVIDIA |
|-------------|--------------------------|
| **Pipelined exp unit (5-cycle, 1/clk)** | Hardened exp is feasible at ~64 DSPs; eliminates MUFU contention |
| **Bit-exact online softmax** | Custom silicon can implement FlashAttention's algorithm without approximation |
| **FP8 E4M3/E5M2 datapath** | FP8 attention is implementable in fixed-function hardware |
| **Block quantization + incoherent processing** | FlashAttention-3's accuracy techniques work in dedicated silicon |
| **HBM tiling analysis** | Tile sizes are correctly matched to memory hierarchy; attention is compute-bound |
| **Throughput measurement: softmax never stalls GEMM** | 50% MUFU overhead → 0% with dedicated pipeline |
| **Area/power estimate** | Silicon cost of hardened softmax is ~4% of math budget — justified by 50% throughput gain |

---

## 9. Register Map (AXI4-Lite CSR)

| Offset | Name | RW | Description |
|--------|------|----|-------------|
| 0x00 | CTRL | RW | [0]=start [1]=fp8_enable [2]=incoherent_en [7:4]=num_heads |
| 0x04 | STATUS | RO | [0]=busy [1]=done [2]=error |
| 0x08 | SEQ_LEN | RW | Sequence length N |
| 0x0C | HEAD_DIM | RW | Head dimension d (64, 128, or 256) |
| 0x10 | TILE_BR | RW | Query tile rows (default 128) |
| 0x14 | TILE_BC | RW | Key tile columns (default 128) |
| 0x18 | Q_BASE | RW | DDR base address for Q matrix |
| 0x1C | K_BASE | RW | DDR base address for K matrix |
| 0x20 | V_BASE | RW | DDR base address for V matrix |
| 0x24 | O_BASE | RW | DDR base address for output O |
| 0x28 | SCALE_BASE | RW | DDR base address for FP8 scale factors |
| 0x30 | PERF_CYCLES | RO | Total cycles for last attention pass |
| 0x34 | PERF_GEMM_CYCLES | RO | Cycles spent in GEMM |
| 0x38 | PERF_SOFTMAX_CYCLES | RO | Cycles spent in softmax |
| 0x3C | PERF_STALL_CYCLES | RO | Cycles softmax stalled GEMM (target: 0) |
| 0x40 | PERF_MEM_STALLS | RO | Cycles waiting for DDR/HBM |
| 0x44 | PERF_TILES_COMPUTED | RO | Total tiles processed |
| 0x48 | PERF_EXP_OPS | RO | Total exp operations executed |

**The critical metric is 0x3C (PERF_STALL_CYCLES).** This is what NVIDIA cares about.
On H100, FlashAttention-3's pingpong scheduling reduces but doesn't eliminate softmax
stalls. Our prototype targets PERF_STALL_CYCLES = 0 — the softmax pipeline is fast
enough that it never blocks the GEMM, ever.

---

## 10. Implementation Phases

| Phase | Hours | Focus |
|-------|-------|-------|
| 1. Model Analysis | 2h | Python golden model implementing exact FlashAttention tiled forward pass; FP8 quantization reference; HBM bandwidth arithmetic |
| 2. HLS Prototype | 8h | Pipelined exp unit in Vitis HLS; verify 1-cycle throughput and < 2^-20 error; online softmax single-row kernel |
| 3. RTL Architecture | 12h | Hand-optimized SystemVerilog: exp pipeline, online softmax FSM, FP8 convert, tile sequencer, systolic array, AXI4-Lite CSR |
| 4. Integration | 5h | Vivado IP Integrator: wire to DDR4 via AXI4, double-buffered tile prefetch, full SoC on ZCU104 |
| 5. Verification | 4h | Bit-exact comparison vs. golden model at every level; PERF_STALL_CYCLES measurement |
| 6. Characterization | 1h | Synthesis: area (LUT/DSP/BRAM), Fmax, power; compute area-efficiency argument |
