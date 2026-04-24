"""Compare TorchAO FP8-quantized transformer weights against original BF16 weights.

Computes SNR, RMSE, and relative error to verify quantization quality.
"""

import gc
import sys
from pathlib import Path

import torch
from safetensors.torch import load_file

MODEL_DIR = "/home/pablo/models/Qwen-Image-2512-base"
TRANSFORMER_DIR = Path(MODEL_DIR) / "transformer"


def load_quantized_transformer():
    """Load the transformer with TorchAO FP8 quantization (same as runtime.py)."""
    from diffusers import QwenImageTransformer2DModel, TorchAoConfig
    from torchao.quantization import Float8WeightOnlyConfig

    quantization_config = TorchAoConfig(Float8WeightOnlyConfig())
    transformer = QwenImageTransformer2DModel.from_pretrained(
        MODEL_DIR,
        subfolder="transformer",
        quantization_config=quantization_config,
        torch_dtype=torch.bfloat16,
    )
    return transformer


def load_original_weights():
    """Load all original BF16 weights from safetensors shards."""
    shards = sorted(TRANSFORMER_DIR.glob("diffusion_pytorch_model-*.safetensors"))
    if not shards:
        # Try single file
        single = TRANSFORMER_DIR / "diffusion_pytorch_model.safetensors"
        if single.exists():
            shards = [single]
        else:
            print("ERROR: No safetensors files found in", TRANSFORMER_DIR)
            sys.exit(1)

    print(f"Loading original weights from {len(shards)} shard(s)...")
    all_weights = {}
    for shard in shards:
        print(f"  {shard.name}")
        weights = load_file(str(shard))
        all_weights.update(weights)
    return all_weights


def compute_metrics(orig: torch.Tensor, quant_f32: torch.Tensor):
    """Compute SNR (dB), RMSE, and mean relative error between two tensors.

    Both inputs must already be regular float32 tensors (not Float8Tensor).
    """
    orig_f32 = orig.to(torch.float32)

    diff = orig_f32 - quant_f32
    signal_power = (orig_f32 ** 2).mean()
    noise_power = (diff ** 2).mean()

    rmse = noise_power.sqrt().item()

    if noise_power > 0:
        snr_db = (10 * torch.log10(signal_power / noise_power)).item()
    else:
        snr_db = float("inf")

    # Mean relative error (avoid division by zero)
    abs_orig = orig_f32.abs()
    mask = abs_orig > 1e-8
    if mask.any():
        rel_error = (diff[mask].abs() / abs_orig[mask]).mean().item()
    else:
        rel_error = 0.0

    return snr_db, rmse, rel_error


def main():
    print("=" * 70)
    print("Quantization Quality Check: TorchAO Float8WeightOnly")
    print("=" * 70)

    # Step 1: Load original weights
    original_weights = load_original_weights()
    print(f"Original weights loaded: {len(original_weights)} tensors\n")

    # Step 2: Load quantized transformer
    print("Loading quantized transformer (TorchAO FP8)...")
    transformer = load_quantized_transformer()
    print("Quantized transformer loaded.\n")

    # Step 3: Compare
    results = []
    quantized_count = 0
    skipped_count = 0

    for name, param in transformer.named_parameters():
        if name not in original_weights:
            continue

        # Detect quantized tensors: Float8Tensor class name or has 'dequantize'
        is_quantized = (
            "Float8" in type(param.data).__name__
            or hasattr(param.data, "dequantize")
        )

        if is_quantized:
            quantized_count += 1
            # Dequantize: FP8 → regular BF16 torch.Tensor via .dequantize()
            dequantized = param.data.dequantize()
            orig = original_weights[name]

            if dequantized.shape != orig.shape:
                print(f"  SKIP {name}: shape mismatch {dequantized.shape} vs {orig.shape}")
                skipped_count += 1
                continue

            snr, rmse, rel_err = compute_metrics(orig, dequantized)
            results.append((name, snr, rmse, rel_err, orig.numel()))
        else:
            # Non-quantized param (bias, norm) — should be identical
            pass

    # Free memory
    del transformer
    gc.collect()

    # Step 4: Report
    print("=" * 70)
    print(f"RESULTS: {len(results)} quantized weight tensors compared")
    print(f"(Skipped: {skipped_count})")
    print("=" * 70)

    # Sort by SNR (worst first)
    results.sort(key=lambda x: x[1])

    # Show worst 10
    print("\n--- Worst 10 layers (lowest SNR) ---")
    print(f"{'Layer':<60} {'SNR(dB)':>8} {'RMSE':>10} {'RelErr%':>8}")
    print("-" * 90)
    for name, snr, rmse, rel_err, _ in results[:10]:
        short_name = name if len(name) < 58 else "..." + name[-55:]
        print(f"{short_name:<60} {snr:>8.1f} {rmse:>10.6f} {rel_err*100:>7.3f}%")

    # Show best 10
    print("\n--- Best 10 layers (highest SNR) ---")
    print(f"{'Layer':<60} {'SNR(dB)':>8} {'RMSE':>10} {'RelErr%':>8}")
    print("-" * 90)
    for name, snr, rmse, rel_err, _ in results[-10:]:
        short_name = name if len(name) < 58 else "..." + name[-55:]
        print(f"{short_name:<60} {snr:>8.1f} {rmse:>10.6f} {rel_err*100:>7.3f}%")

    # Global statistics
    total_params = sum(n for _, _, _, _, n in results)
    weighted_snr = sum(snr * n for _, snr, _, _, n in results) / total_params
    weighted_rmse = (sum(rmse**2 * n for _, _, rmse, _, n in results) / total_params) ** 0.5
    weighted_rel = sum(rel * n for _, _, _, rel, n in results) / total_params
    min_snr = min(snr for _, snr, _, _, _ in results)
    max_snr = max(snr for _, snr, _, _, _ in results)
    median_snr = results[len(results) // 2][1]

    print("\n" + "=" * 70)
    print("GLOBAL SUMMARY")
    print("=" * 70)
    print(f"  Quantized tensors:     {len(results)}")
    print(f"  Total parameters:      {total_params:,}")
    print(f"  Weighted avg SNR:      {weighted_snr:.1f} dB")
    print(f"  Median SNR:            {median_snr:.1f} dB")
    print(f"  Min SNR:               {min_snr:.1f} dB")
    print(f"  Max SNR:               {max_snr:.1f} dB")
    print(f"  Weighted RMSE:         {weighted_rmse:.6f}")
    print(f"  Weighted rel error:    {weighted_rel*100:.3f}%")
    print()

    # Quality assessment
    print("QUALITY ASSESSMENT:")
    if weighted_snr >= 30:
        print("  EXCELLENT — SNR >= 30 dB. Quantization error is negligible.")
        print("  Equivalent to <0.1% relative error. No perceptible quality loss.")
    elif weighted_snr >= 20:
        print("  GOOD — SNR 20-30 dB. Typical for FP8 weight-only quantization.")
        print("  Minor numerical differences, generally no visible impact on output.")
    elif weighted_snr >= 15:
        print("  ACCEPTABLE — SNR 15-20 dB. Some quality degradation possible.")
        print("  Fine details might be slightly affected.")
    else:
        print("  WARNING — SNR < 15 dB. Significant quantization error.")
        print("  Output quality may be noticeably degraded.")


if __name__ == "__main__":
    main()
