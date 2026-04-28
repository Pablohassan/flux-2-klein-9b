from pathlib import Path


TARGET = Path("/usr/local/lib/python3.12/dist-packages/vllm/env_override.py")

text = TARGET.read_text()

if "import inspect\nimport os\n" not in text:
    old_imports = "import importlib.util\nimport os\n"
    new_imports = "import importlib.util\nimport inspect\nimport os\n"
    if old_imports not in text:
        raise SystemExit("Could not find import block in env_override.py")
    text = text.replace(old_imports, new_imports, 1)

old_block = """def _apply_constrain_to_fx_strides_patch():
    \"\"\"Patch lowering.constrain_to_fx_strides globally. Safe to call
    multiple times; only the first call does anything.
    Only applies for torch >= 2.11 and < 2.12.\"\"\"
    global _constrain_to_fx_strides_patched
    if _constrain_to_fx_strides_patched:
        return
    _constrain_to_fx_strides_patched = True

    if not is_torch_equal_or_newer(\"2.11.0.dev\") or is_torch_equal_or_newer(
        \"2.12.0.dev\"
    ):
        return

    import torch._inductor.ir as _ir
    import torch._inductor.lowering as _lowering
    from torch._inductor.virtualized import V as _V
"""

new_block = """def _apply_constrain_to_fx_strides_patch():
    \"\"\"Patch lowering.constrain_to_fx_strides globally.

    Safe to call multiple times; only the first call does anything.
    Some vendor torch 2.12 dev builds still miss the upstream FakeScriptObject
    fix, so we feature-detect the buggy lowering implementation instead of
    relying on semver alone.
    \"\"\"
    global _constrain_to_fx_strides_patched
    if _constrain_to_fx_strides_patched:
        return
    _constrain_to_fx_strides_patched = True

    if not is_torch_equal_or_newer(\"2.11.0.dev\"):
        return

    import torch._inductor.lowering as _lowering

    try:
        source = inspect.getsource(_lowering.constrain_to_fx_strides)
    except (OSError, TypeError):
        # If source inspection is unavailable, prefer the compatibility path.
        source = \"\"

    has_tensor_meta_guard = (
        \"meta_val = fx_arg.meta.get(\\\"val\\\")\" in source
        and \"isinstance(meta_val, torch.Tensor)\" in source
    )
    if has_tensor_meta_guard:
        return

    if is_torch_equal_or_newer(\"2.12.0.dev\"):
        logger.warning(\"Torch reports >=2.12.0.dev but constrain_to_fx_strides still lacks the FakeScriptObject guard; applying compatibility patch.\")

    import torch._inductor.ir as _ir
    from torch._inductor.virtualized import V as _V
"""

if new_block not in text:
    if old_block not in text:
        raise SystemExit("Could not find constrain_to_fx_strides block in env_override.py")
    text = text.replace(old_block, new_block, 1)

TARGET.write_text(text)
