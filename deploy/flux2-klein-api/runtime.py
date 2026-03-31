from __future__ import annotations

import os
import random
import re
import threading
from pathlib import Path

import torch
from einops import rearrange
from PIL import ExifTags, Image
from safetensors.torch import load_file as load_sft


def _import_flux2(runtime_dir: Path) -> None:
    import sys

    src_dir = runtime_dir / "vendor" / "flux2" / "src"
    if str(src_dir) not in sys.path:
        sys.path.insert(0, str(src_dir))


class Flux2Runtime:
    def __init__(
        self,
        runtime_dir: Path,
        model_name: str,
        output_dir: Path,
    ) -> None:
        _import_flux2(runtime_dir)

        from flux2.autoencoder import AutoEncoder, AutoEncoderParams
        from flux2.sampling import (
            batched_prc_img,
            batched_prc_txt,
            denoise,
            denoise_cached,
            denoise_cfg,
            encode_image_refs,
            get_schedule,
            scatter_ids,
        )
        from flux2.util import FLUX2_MODEL_INFO, load_ae, load_flow_model, load_text_encoder

        self.FLUX2_MODEL_INFO = FLUX2_MODEL_INFO
        self.AutoEncoder = AutoEncoder
        self.AutoEncoderParams = AutoEncoderParams
        self.load_ae = load_ae
        self.load_flow_model = load_flow_model
        self.load_text_encoder = load_text_encoder
        self.batched_prc_img = batched_prc_img
        self.batched_prc_txt = batched_prc_txt
        self.denoise = denoise
        self.denoise_cached = denoise_cached
        self.denoise_cfg = denoise_cfg
        self.encode_image_refs = encode_image_refs
        self.get_schedule = get_schedule
        self.scatter_ids = scatter_ids

        self.runtime_dir = runtime_dir
        self.model_name = model_name
        self.output_dir = output_dir
        self.output_dir.mkdir(parents=True, exist_ok=True)
        self.device = torch.device("cuda")
        self.torch_compile = os.environ.get("TORCH_COMPILE", "0") == "1"
        self.torch_compile_mode = os.environ.get("TORCH_COMPILE_MODE", "reduce-overhead")
        self._lock = threading.Lock()
        self._loaded = False
        self.model = None
        self.ae = None
        self.text_encoder = None

    def _map_diffusers_ae_key(self, key: str) -> str | None:
        if key.startswith("bn."):
            return None
        if key.startswith("quant_conv."):
            return "encoder." + key
        if key.startswith("post_quant_conv."):
            return "decoder." + key
        if key.startswith("encoder.conv_norm_out."):
            return key.replace("encoder.conv_norm_out.", "encoder.norm_out.")
        if key.startswith("decoder.conv_norm_out."):
            return key.replace("decoder.conv_norm_out.", "decoder.norm_out.")

        replacements = {
            "encoder.mid_block.resnets.0.": "encoder.mid.block_1.",
            "encoder.mid_block.resnets.1.": "encoder.mid.block_2.",
            "decoder.mid_block.resnets.0.": "decoder.mid.block_1.",
            "decoder.mid_block.resnets.1.": "decoder.mid.block_2.",
            "encoder.mid_block.attentions.0.group_norm.": "encoder.mid.attn_1.norm.",
            "encoder.mid_block.attentions.0.to_out.0.": "encoder.mid.attn_1.proj_out.",
            "encoder.mid_block.attentions.0.to_q.": "encoder.mid.attn_1.q.",
            "encoder.mid_block.attentions.0.to_k.": "encoder.mid.attn_1.k.",
            "encoder.mid_block.attentions.0.to_v.": "encoder.mid.attn_1.v.",
            "decoder.mid_block.attentions.0.group_norm.": "decoder.mid.attn_1.norm.",
            "decoder.mid_block.attentions.0.to_out.0.": "decoder.mid.attn_1.proj_out.",
            "decoder.mid_block.attentions.0.to_q.": "decoder.mid.attn_1.q.",
            "decoder.mid_block.attentions.0.to_k.": "decoder.mid.attn_1.k.",
            "decoder.mid_block.attentions.0.to_v.": "decoder.mid.attn_1.v.",
        }
        for src, dst in replacements.items():
            if key.startswith(src):
                return key.replace(src, dst)

        match = re.match(r"^encoder\.down_blocks\.(\d+)\.resnets\.(\d+)\.(.+)$", key)
        if match:
            level, block, rest = match.groups()
            rest = rest.replace("conv_shortcut.", "nin_shortcut.")
            return f"encoder.down.{level}.block.{block}.{rest}"

        match = re.match(r"^encoder\.down_blocks\.(\d+)\.downsamplers\.0\.conv\.(.+)$", key)
        if match:
            level, rest = match.groups()
            return f"encoder.down.{level}.downsample.conv.{rest}"

        match = re.match(r"^decoder\.up_blocks\.(\d+)\.resnets\.(\d+)\.(.+)$", key)
        if match:
            level, block, rest = match.groups()
            level = str(3 - int(level))
            rest = rest.replace("conv_shortcut.", "nin_shortcut.")
            return f"decoder.up.{level}.block.{block}.{rest}"

        match = re.match(r"^decoder\.up_blocks\.(\d+)\.upsamplers\.0\.conv\.(.+)$", key)
        if match:
            level, rest = match.groups()
            level = str(3 - int(level))
            return f"decoder.up.{level}.upsample.conv.{rest}"

        return key

    def _load_diffusers_ae(self, weight_path: str) -> torch.nn.Module:
        state_dict = load_sft(weight_path, device="cpu")
        converted: dict[str, torch.Tensor] = {}

        for key, value in state_dict.items():
            mapped_key = self._map_diffusers_ae_key(key)
            if mapped_key is None:
                continue
            if mapped_key.endswith((".q.weight", ".k.weight", ".v.weight", ".proj_out.weight")) and value.ndim == 2:
                value = value[:, :, None, None]
            converted[mapped_key] = value

        ae = self.AutoEncoder(self.AutoEncoderParams())
        ae.load_state_dict(converted, strict=False)
        return ae.to(self.device)

    @property
    def model_info(self) -> dict:
        return self.FLUX2_MODEL_INFO[self.model_name]

    def defaults(self) -> tuple[int, float]:
        defaults = self.model_info.get("defaults", {})
        return defaults.get("num_steps", 4), defaults.get("guidance", 1.0)

    def ensure_loaded(self) -> None:
        if self._loaded:
            return
        with self._lock:
            if self._loaded:
                return
            self.text_encoder = self.load_text_encoder(self.model_name, device=self.device)
            self.model = self.load_flow_model(self.model_name, device=self.device)
            try:
                self.ae = self.load_ae(self.model_name, device=self.device)
            except RuntimeError as exc:
                ae_path = os.environ.get("AE_MODEL_PATH", "")
                if "Error(s) in loading state_dict for AutoEncoder" not in str(exc) or not ae_path:
                    raise
                self.ae = self._load_diffusers_ae(ae_path)
            self.model.eval()
            self.ae.eval()
            self.text_encoder.eval()
            if self.torch_compile:
                self.model = torch.compile(self.model, mode=self.torch_compile_mode)
            self._loaded = True

    def generate(
        self,
        *,
        prompt: str,
        width: int,
        height: int,
        steps: int | None,
        guidance: float | None,
        seed: int | None,
        input_images: list[Image.Image] | None = None,
        output_prefix: str,
    ) -> Path:
        self.ensure_loaded()

        num_steps_default, guidance_default = self.defaults()
        num_steps = num_steps if steps is not None else num_steps_default
        guidance = guidance if guidance is not None else guidance_default
        if self.model_info.get("fixed_params"):
            num_steps = num_steps_default
            guidance = guidance_default

        seed = seed if seed is not None else random.randrange(2**31)

        with torch.no_grad():
            ref_tokens, ref_ids = self.encode_image_refs(self.ae, input_images or [])

            if self.model_info["guidance_distilled"]:
                ctx = self.text_encoder([prompt]).to(torch.bfloat16)
            else:
                ctx_empty = self.text_encoder([""]).to(torch.bfloat16)
                ctx_prompt = self.text_encoder([prompt]).to(torch.bfloat16)
                ctx = torch.cat([ctx_empty, ctx_prompt], dim=0)

            ctx, ctx_ids = self.batched_prc_txt(ctx)

            shape = (1, 128, height // 16, width // 16)
            generator = torch.Generator(device="cuda").manual_seed(seed)
            randn = torch.randn(shape, generator=generator, dtype=torch.bfloat16, device="cuda")
            x, x_ids = self.batched_prc_img(randn)

            timesteps = self.get_schedule(num_steps, x.shape[1])
            if self.model_info["guidance_distilled"]:
                denoise_fn = (
                    self.denoise_cached
                    if (self.model_info.get("use_kv_cache") and ref_tokens is not None)
                    else self.denoise
                )
                x = denoise_fn(
                    self.model,
                    x,
                    x_ids,
                    ctx,
                    ctx_ids,
                    timesteps=timesteps,
                    guidance=guidance,
                    img_cond_seq=ref_tokens,
                    img_cond_seq_ids=ref_ids,
                )
            else:
                x = self.denoise_cfg(
                    self.model,
                    x,
                    x_ids,
                    ctx,
                    ctx_ids,
                    timesteps=timesteps,
                    guidance=guidance,
                    img_cond_seq=ref_tokens,
                    img_cond_seq_ids=ref_ids,
                )

            x = torch.cat(self.scatter_ids(x, x_ids)).squeeze(2)
            x = self.ae.decode(x).float()

        x = x.clamp(-1, 1)
        x = rearrange(x[0], "c h w -> h w c")
        img = Image.fromarray((127.5 * (x + 1.0)).cpu().byte().numpy())

        result_path = self.output_dir / f"{output_prefix}.png"
        exif_data = Image.Exif()
        exif_data[ExifTags.Base.Software] = "AI generated;flux2"
        exif_data[ExifTags.Base.Make] = "Black Forest Labs"
        img.save(result_path, exif=exif_data, quality=95, subsampling=0)
        return result_path


def load_runtime_from_env() -> Flux2Runtime:
    runtime_dir = Path(os.environ["RUNTIME_DIR"])
    model_name = os.environ.get("MODEL_NAME", "flux.2-klein-9b").lower()
    output_dir = Path(os.environ["OUTPUTS_DIR"])
    return Flux2Runtime(runtime_dir=runtime_dir, model_name=model_name, output_dir=output_dir)
