#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp -n "$SCRIPT_DIR/.env.example" "$SCRIPT_DIR/.env" 2>/dev/null || true
set -a
source "$SCRIPT_DIR/.env"
set +a

python3.12 -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"

python -m pip install --upgrade pip setuptools wheel

# PyTorch with CUDA 13.0 support (DGX Spark GB10)
python -m pip install \
  --index-url https://download.pytorch.org/whl/cu130 \
  torch \
  torchvision

# diffusers from git (required for QwenImagePipeline + TorchAO quantization)
python -m pip install git+https://github.com/huggingface/diffusers

# Runtime dependencies
python -m pip install \
  fastapi==0.118.0 \
  uvicorn==0.37.0 \
  python-multipart==0.0.20 \
  pydantic==2.11.9 \
  accelerate==1.12.0 \
  transformers==4.56.1 \
  safetensors \
  sentencepiece \
  protobuf \
  torchao

mkdir -p "$OUTPUTS_DIR" "$LOG_DIR"
echo "Setup completed in $VENV_DIR"
