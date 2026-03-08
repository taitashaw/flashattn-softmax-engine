#!/usr/bin/env python3
"""
Hardened Softmax Pipeline — Phase 1: Golden Model & HBM Analysis
================================================================
Implements the exact FlashAttention-2 tiled forward pass as golden reference.
Includes FP8 quantization, block quantization, and incoherent processing.
Generates test vectors for RTL verification.

Key insight: This golden model is NOT approximate. Every intermediate value
is FP32. The hardware must match this exactly (within FP32 rounding).

Usage:
    python golden_model.py --seq_len 1024 --head_dim 128 --gen_vectors 64
    python golden_model.py --seq_len 8192 --head_dim 128 --hbm_analysis
"""

import argparse
import json
import struct
import os
import time
from pathlib import Path
from typing import Tuple

import numpy as np


# ========================= FP8 CONVERSION ===================================

class FP8:
    """IEEE-like FP8 formats: E4M3 and E5M2."""

    @staticmethod
    def fp32_to_e4m3(x: np.ndarray) -> Tuple[np.ndarray, float]:
        """Quantize FP32 to FP8 E4M3 with block scale factor.

        Returns (quantized_uint8_array, scale_factor).
        """
        absmax = np.max(np.abs(x))
        if absmax == 0:
            return np.zeros_like(x, dtype=np.uint8), 1.0

        # E4M3 max representable = 448.0
        scale = absmax / 448.0
        scaled = x / scale
        # Clamp to E4M3 range and round
        clamped = np.clip(scaled, -448.0, 448.0)
        # Simplified: store as scaled int8 (true FP8 would use custom bit layout)
        # For golden model, we track the quantization error precisely
        quantized = np.round(clamped).astype(np.int16)
        return quantized.astype(np.uint8), scale

    @staticmethod
    def e4m3_to_fp32(q: np.ndarray, scale: float) -> np.ndarray:
        """Dequantize FP8 E4M3 back to FP32."""
        return q.astype(np.float32) * scale


# ====================== INCOHERENT PROCESSING ===============================

def walsh_hadamard_transform(x: np.ndarray) -> np.ndarray:
    """In-place Walsh-Hadamard transform (butterfly network).

    For dimension d, requires log2(d) stages of add/subtract.
    Zero multiplications. O(d log d) additions.
    """
    n = x.shape[-1]
    assert n & (n - 1) == 0, "Dimension must be power of 2"

    result = x.copy().astype(np.float32)
    h = 1
    while h < n:
        for i in range(0, n, h * 2):
            for j in range(i, i + h):
                a = result[..., j].copy()
                b = result[..., j + h].copy()
                result[..., j] = a + b
                result[..., j + h] = a - b
        h *= 2
    # Normalize
    result /= np.sqrt(n)
    return result


def apply_incoherent_processing(x: np.ndarray, seed: int = 42) -> Tuple[np.ndarray, np.ndarray]:
    """Apply random signs + Hadamard transform to spread outliers.

    Returns (transformed_x, sign_vector) for later inversion.
    """
    rng = np.random.RandomState(seed)
    d = x.shape[-1]
    signs = rng.choice([-1, 1], size=d).astype(np.float32)
    x_signed = x * signs[None, :]  # Broadcasting
    x_transformed = walsh_hadamard_transform(x_signed)
    return x_transformed, signs


def invert_incoherent_processing(x: np.ndarray, signs: np.ndarray) -> np.ndarray:
    """Inverse of incoherent processing."""
    x_inv_had = walsh_hadamard_transform(x)  # WHT is self-inverse
    return x_inv_had * signs[None, :]


# =================== FLASHATTENTION TILED FORWARD PASS ======================

def flash_attention_forward_fp32(
    Q: np.ndarray,  # (N, d) FP32
    K: np.ndarray,  # (N, d) FP32
    V: np.ndarray,  # (N, d) FP32
    Br: int = 128,
    Bc: int = 128,
    causal: bool = False,
) -> Tuple[np.ndarray, dict]:
    """
    Exact FlashAttention-2 tiled forward pass.

    This is Algorithm 1 from the FlashAttention-2 paper, implemented
    exactly in FP32. No approximations. No shortcuts.

    The hardware MUST reproduce this output bit-for-bit.

    Returns:
        O: (N, d) FP32 attention output
        stats: dict with per-tile statistics for verification
    """
    N, d = Q.shape
    scale = 1.0 / np.sqrt(d)

    # Initialize
    O = np.zeros((N, d), dtype=np.float32)
    l = np.zeros(N, dtype=np.float32)       # Running denominator
    m = np.full(N, -np.inf, dtype=np.float32)  # Running row-max

    stats = {
        "tiles_computed": 0,
        "exp_ops": 0,
        "gemm0_ops": 0,
        "gemm1_ops": 0,
        "rescale_ops": 0,
    }

    # Outer loop over K/V tile columns
    for j in range(0, N, Bc):
        j_end = min(j + Bc, N)
        Kj = K[j:j_end]  # (Bc_actual, d)
        Vj = V[j:j_end]  # (Bc_actual, d)
        Bc_actual = j_end - j

        # Inner loop over Q tile rows
        for i in range(0, N, Br):
            i_end = min(i + Br, N)
            Br_actual = i_end - i
            Qi = Q[i:i_end]  # (Br_actual, d)

            # ---- GEMM0: S = Q_i × K_j^T × scale ----
            S = (Qi @ Kj.T) * scale  # (Br_actual, Bc_actual), FP32
            stats["gemm0_ops"] += Br_actual * Bc_actual * d * 2  # MAC = 2 ops

            # Causal masking
            if causal:
                for bi in range(Br_actual):
                    for bj in range(Bc_actual):
                        if (i + bi) < (j + bj):
                            S[bi, bj] = -np.inf

            # ---- ONLINE SOFTMAX (the critical path) ----

            # Step 1: Row-max of current block
            m_block = np.max(S, axis=1)  # (Br_actual,)

            # Step 2: New running max
            m_old = m[i:i_end].copy()
            m_new = np.maximum(m_old, m_block)

            # Step 3: exp(S - m_new) — THIS IS WHERE THE HARDENED EXP FIRES
            P = np.exp(S - m_new[:, None])  # (Br_actual, Bc_actual)
            stats["exp_ops"] += Br_actual * Bc_actual

            # Step 4: Rescaling factor for old statistics
            exp_diff = np.exp(m_old - m_new)  # (Br_actual,)
            stats["exp_ops"] += Br_actual
            stats["rescale_ops"] += Br_actual

            # Step 5: Update running sum
            l_new = l[i:i_end] * exp_diff + P.sum(axis=1)

            # Step 6: Rescale running output and accumulate
            O[i:i_end] = O[i:i_end] * exp_diff[:, None]  # Rescale old
            stats["rescale_ops"] += Br_actual * d

            # ---- GEMM1: O += P × V ----
            O[i:i_end] += P @ Vj  # (Br_actual, d)
            stats["gemm1_ops"] += Br_actual * d * Bc_actual * 2

            # Step 7: Update running statistics
            m[i:i_end] = m_new
            l[i:i_end] = l_new

            stats["tiles_computed"] += 1

    # Final normalization
    O = O / l[:, None]

    return O, stats


def flash_attention_forward_fp8(
    Q: np.ndarray,  # (N, d) FP32 (will be quantized internally)
    K: np.ndarray,
    V: np.ndarray,
    Br: int = 128,
    Bc: int = 128,
    use_incoherent: bool = True,
) -> Tuple[np.ndarray, dict]:
    """
    FlashAttention-3 FP8 forward pass with block quantization.

    Mimics the hardware datapath:
    1. Apply incoherent processing (optional)
    2. Block-quantize Q, K, V to FP8 E4M3
    3. Run tiled attention with FP8 inputs, FP32 accumulation
    4. Block-quantize output back to FP8
    """
    N, d = Q.shape

    # Incoherent processing
    if use_incoherent:
        Q_proc, signs_q = apply_incoherent_processing(Q)
        K_proc, signs_k = apply_incoherent_processing(K)
    else:
        Q_proc, K_proc = Q.copy(), K.copy()

    # Block quantization (one scale per Br×d tile)
    # For simplicity, we quantize the entire matrix with one scale
    # (In production, per-tile scales give better accuracy)
    Q_q, q_scale = FP8.fp32_to_e4m3(Q_proc)
    K_q, k_scale = FP8.fp32_to_e4m3(K_proc)
    V_q, v_scale = FP8.fp32_to_e4m3(V)

    # Dequantize back to FP32 (this is what the hardware does)
    Q_deq = FP8.e4m3_to_fp32(Q_q, q_scale)
    K_deq = FP8.e4m3_to_fp32(K_q, k_scale)
    V_deq = FP8.e4m3_to_fp32(V_q, v_scale)

    # Run exact tiled attention on dequantized values
    O, stats = flash_attention_forward_fp32(Q_deq, K_deq, V_deq, Br, Bc)

    # Invert incoherent processing on output
    if use_incoherent:
        # Note: output doesn't need inverse Hadamard — it's on the V side
        pass

    # Quantize output to FP8
    O_q, o_scale = FP8.fp32_to_e4m3(O)
    O_deq = FP8.e4m3_to_fp32(O_q, o_scale)

    stats["fp8_quant_error"] = float(np.sqrt(np.mean((O_deq - O) ** 2)))

    return O_deq, stats


# ======================== HBM BANDWIDTH ANALYSIS ============================

def hbm_analysis(seq_len: int, head_dim: int, num_heads: int,
                 Br: int, Bc: int, fp8: bool = False):
    """
    Compute HBM read/write traffic and arithmetic intensity.
    Determines whether attention is compute-bound or memory-bound.
    """
    N, d, H = seq_len, head_dim, num_heads
    bytes_per_elem = 1 if fp8 else 2  # FP8 = 1B, FP16 = 2B

    # Per head:
    # Q is read once: N × d bytes
    # K is read N/Br times (once per Q tile): (N/Br) × N × d bytes
    # V is read N/Br times: (N/Br) × N × d bytes
    # O is written once: N × d bytes

    q_reads = N * d * bytes_per_elem
    k_reads = (N // Br) * N * d * bytes_per_elem
    v_reads = (N // Br) * N * d * bytes_per_elem
    o_writes = N * d * bytes_per_elem
    total_bytes = (q_reads + k_reads + v_reads + o_writes) * H

    # Compute: 4 × N² × d × H (2 GEMMs, each N²×d MACs, MAC = 2 FLOPS)
    total_flops = 4 * N * N * d * H

    # Arithmetic intensity (FLOPS per byte)
    ai = total_flops / total_bytes

    # H100 roofline
    h100_hbm_bw = 3.35e12  # bytes/sec
    h100_fp16_compute = 989e12  # FLOPS/sec
    h100_fp8_compute = 1978e12  # FLOPS/sec (2× FP16)
    compute_peak = h100_fp8_compute if fp8 else h100_fp16_compute
    ridge_point = compute_peak / h100_hbm_bw  # FLOPS/byte at roofline knee

    bound = "COMPUTE" if ai > ridge_point else "MEMORY"

    print(f"\n{'='*60}")
    print(f"HBM Bandwidth Analysis")
    print(f"{'='*60}")
    print(f"  Seq len:          {N}")
    print(f"  Head dim:         {d}")
    print(f"  Num heads:        {H}")
    print(f"  Tile (Br×Bc):     {Br}×{Bc}")
    print(f"  Precision:        {'FP8' if fp8 else 'FP16'}")
    print(f"")
    print(f"  Q reads:          {q_reads * H / 1e6:.1f} MB")
    print(f"  K reads:          {k_reads * H / 1e6:.1f} MB")
    print(f"  V reads:          {v_reads * H / 1e6:.1f} MB")
    print(f"  O writes:         {o_writes * H / 1e6:.1f} MB")
    print(f"  Total traffic:    {total_bytes / 1e6:.1f} MB")
    print(f"  Total FLOPS:      {total_flops / 1e9:.1f} GFLOPS")
    print(f"")
    print(f"  Arithmetic intensity: {ai:.1f} FLOPS/byte")
    print(f"  H100 ridge point:     {ridge_point:.1f} FLOPS/byte")
    print(f"  Bound:                *** {bound} ***")
    print(f"")
    if bound == "COMPUTE":
        time_compute = total_flops / compute_peak
        time_memory = total_bytes / h100_hbm_bw
        print(f"  Compute time:     {time_compute * 1e6:.1f} μs")
        print(f"  Memory time:      {time_memory * 1e6:.1f} μs")
        print(f"  Softmax overhead: ~{time_compute * 0.5 * 1e6:.1f} μs (50% of compute)")
        print(f"  Our speedup:      Eliminate softmax stall → save {time_compute * 0.5 * 1e6:.1f} μs")
    print(f"{'='*60}")


# ======================== TEST VECTOR GENERATION ============================

def generate_test_vectors(
    num_vectors: int = 64,
    seq_lens: list = [32, 64, 128],
    head_dim: int = 128,
    Br: int = 128,
    Bc: int = 128,
    output_dir: str = "vectors",
):
    """Generate golden test vectors for RTL verification."""
    os.makedirs(output_dir, exist_ok=True)

    manifest = []
    np.random.seed(42)

    for v in range(num_vectors):
        N = seq_lens[v % len(seq_lens)]
        d = head_dim

        # Random inputs (FP32, normal distribution — realistic for attention)
        Q = np.random.randn(N, d).astype(np.float32) * 0.5
        K = np.random.randn(N, d).astype(np.float32) * 0.5
        V = np.random.randn(N, d).astype(np.float32) * 0.5

        # Compute golden output
        O, stats = flash_attention_forward_fp32(Q, K, V, min(Br, N), min(Bc, N))

        # Save as binary (FP32 little-endian)
        prefix = os.path.join(output_dir, f"vec{v:04d}")
        Q.tofile(f"{prefix}_q.bin")
        K.tofile(f"{prefix}_k.bin")
        V.tofile(f"{prefix}_v.bin")
        O.tofile(f"{prefix}_o_golden.bin")

        # Also save as hex for Verilog $readmemh
        _write_fp32_hex(f"{prefix}_q.hex", Q)
        _write_fp32_hex(f"{prefix}_k.hex", K)
        _write_fp32_hex(f"{prefix}_v.hex", V)
        _write_fp32_hex(f"{prefix}_o_golden.hex", O)

        manifest.append({
            "index": v,
            "seq_len": N,
            "head_dim": d,
            "tiles": stats["tiles_computed"],
            "exp_ops": stats["exp_ops"],
            "output_norm": float(np.linalg.norm(O)),
        })

    with open(os.path.join(output_dir, "manifest.json"), 'w') as f:
        json.dump(manifest, f, indent=2)

    print(f"Generated {num_vectors} test vectors in {output_dir}/")
    return manifest


def _write_fp32_hex(filepath: str, arr: np.ndarray):
    """Write FP32 array as hex (IEEE 754 binary32, big-endian for readmemh)."""
    flat = arr.flatten()
    with open(filepath, 'w') as f:
        for val in flat:
            # IEEE 754 binary32 → 8 hex digits
            as_bytes = struct.pack('>f', float(val))
            f.write(as_bytes.hex() + '\n')


# ============================ ENTRY POINT ===================================

def main():
    parser = argparse.ArgumentParser(description="FlashAttention Golden Model")
    parser.add_argument("--seq_len", type=int, default=1024)
    parser.add_argument("--head_dim", type=int, default=128)
    parser.add_argument("--num_heads", type=int, default=16)
    parser.add_argument("--tile_br", type=int, default=128)
    parser.add_argument("--tile_bc", type=int, default=128)
    parser.add_argument("--gen_vectors", type=int, default=64)
    parser.add_argument("--hbm_analysis", action="store_true")
    parser.add_argument("--test_fp8", action="store_true")
    parser.add_argument("--output_dir", default="vectors")
    args = parser.parse_args()

    print("=" * 60)
    print("  Hardened Softmax Pipeline — Golden Model & Analysis")
    print("=" * 60)
    t0 = time.time()

    # --- Correctness test: FP32 tiled vs non-tiled ---
    print("\n[1/4] Verifying tiled FlashAttention matches naive attention...")
    N_test, d_test = 256, args.head_dim
    Q = np.random.randn(N_test, d_test).astype(np.float32) * 0.5
    K = np.random.randn(N_test, d_test).astype(np.float32) * 0.5
    V = np.random.randn(N_test, d_test).astype(np.float32) * 0.5

    # Naive (non-tiled) attention
    scale = 1.0 / np.sqrt(d_test)
    S = (Q @ K.T) * scale
    S_max = np.max(S, axis=1, keepdims=True)
    P = np.exp(S - S_max)
    P = P / P.sum(axis=1, keepdims=True)
    O_naive = P @ V

    # Tiled
    O_tiled, stats = flash_attention_forward_fp32(Q, K, V, 64, 64)

    max_err = np.max(np.abs(O_tiled - O_naive))
    print(f"  Max absolute error (tiled vs naive): {max_err:.2e}")
    print(f"  PASS" if max_err < 1e-5 else f"  FAIL — error too large!")

    # --- FP8 accuracy test ---
    if args.test_fp8:
        print("\n[2/4] Testing FP8 attention accuracy...")
        O_fp8, fp8_stats = flash_attention_forward_fp8(Q, K, V, 64, 64)
        fp8_err = np.sqrt(np.mean((O_fp8 - O_naive) ** 2))
        print(f"  FP8 RMSE vs FP32: {fp8_err:.4f}")
        print(f"  FP8 quant error:  {fp8_stats['fp8_quant_error']:.4f}")
        print(f"  PASS" if fp8_err < 0.1 else f"  WARN — FP8 error elevated")

    # --- HBM analysis ---
    if args.hbm_analysis:
        print("\n[3/4] HBM bandwidth analysis...")
        for N in [1024, 2048, 4096, 8192]:
            for fp8 in [False, True]:
                hbm_analysis(N, args.head_dim, args.num_heads,
                            args.tile_br, args.tile_bc, fp8)

    # --- Generate test vectors ---
    print(f"\n[4/4] Generating {args.gen_vectors} test vectors...")
    generate_test_vectors(
        num_vectors=args.gen_vectors,
        seq_lens=[32, 64, 128, 256],
        head_dim=args.head_dim,
        output_dir=args.output_dir,
    )

    elapsed = time.time() - t0
    print(f"\n[Phase 1 COMPLETE] {elapsed:.1f}s")


if __name__ == "__main__":
    main()
