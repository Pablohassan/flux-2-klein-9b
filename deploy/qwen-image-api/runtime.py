from __future__ import annotations

import gc
import os
import random
import threading
from pathlib import Path

import torch
from PIL import Image


class QwenImageRuntime:
    """Wraps the diffusers QwenImagePipeline for API serving.

    Uses TorchAO float8wo quantization for the transformer — loads shard by
    shard so peak memory stays low. Compatible with DGX Spark GB10 unified
    memory alongside other services (vLLM).
    """

    ASPECT_RATIOS = {
        "1:1": (1328, 1328),
        "16:9": (1664, 928),
        "9:16": (928, 1664),
        "4:3": (1472, 1104),
        "3:4": (1104, 1472),
        "3:2": (1584, 1056),
        "2:3": (1056, 1584),
    }

    DEFAULT_STEPS = 50
    DEFAULT_GUIDANCE = 4.0

    def __init__(self, base_model_dir: str, output_dir: Path) -> None:
        self.base_model_dir = base_model_dir
        self.output_dir = output_dir
        self.output_dir.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        self._loaded = False
        self.pipe = None

    def ensure_loaded(self) -> None:
        if self._loaded:
            return
        with self._lock:
            if self._loaded:
                return

            from diffusers import (
                QwenImagePipeline,
                QwenImageTransformer2DModel,
                TorchAoConfig,
            )
            from torchao.quantization import Float8WeightOnlyConfig

            # TorchAO float8 weight-only quantization.
            # Quantizes each shard during loading → peak ~5 GB per shard,
            # total ~20 GB for the transformer in memory.
            quantization_config = TorchAoConfig(Float8WeightOnlyConfig())

            transformer = QwenImageTransformer2DModel.from_pretrained(
                self.base_model_dir,
                subfolder="transformer",
                quantization_config=quantization_config,
                torch_dtype=torch.bfloat16,
            )
            gc.collect()

            # Load the rest of the pipeline (text encoder BF16 ~16 GB, VAE ~250 MB)
            self.pipe = QwenImagePipeline.from_pretrained(
                self.base_model_dir,
                transformer=transformer,
                torch_dtype=torch.bfloat16,
            )
            gc.collect()

            # CPU offload: only one component on GPU during forward pass.
            self.pipe.enable_model_cpu_offload()

            # VAE tiling: decode the image in tiles to avoid OOM during decode.
            self.pipe.vae.enable_tiling()
            self.pipe.vae.enable_slicing()

            self._loaded = True

    def generate(
        self,
        *,
        prompt: str,
        negative_prompt: str = "",
        width: int,
        height: int,
        steps: int | None,
        guidance: float | None,
        seed: int | None,
        output_prefix: str,
    ) -> Path:
        self.ensure_loaded()

        num_steps = steps if steps is not None else self.DEFAULT_STEPS
        cfg_scale = guidance if guidance is not None else self.DEFAULT_GUIDANCE
        seed = seed if seed is not None else random.randrange(2**31)

        generator = torch.Generator(device="cuda").manual_seed(seed)

        with torch.no_grad():
            result = self.pipe(
                prompt=prompt,
                negative_prompt=negative_prompt or None,
                width=width,
                height=height,
                num_inference_steps=num_steps,
                true_cfg_scale=cfg_scale,
                generator=generator,
            )

        img: Image.Image = result.images[0]
        result_path = self.output_dir / f"{output_prefix}.png"
        img.save(result_path, quality=95, subsampling=0)
        return result_path


def load_runtime_from_env() -> QwenImageRuntime:
    base_model_dir = os.environ["BASE_MODEL_DIR"]
    output_dir = Path(os.environ["OUTPUTS_DIR"])
    return QwenImageRuntime(
        base_model_dir=base_model_dir,
        output_dir=output_dir,
    )
