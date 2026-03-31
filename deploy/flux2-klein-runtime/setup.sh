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
python -m pip install \
  --index-url https://download.pytorch.org/whl/cu130 \
  torch \
  torchvision
python -m pip install \
  --no-deps \
  -e "$SCRIPT_DIR/vendor/flux2"
python -m pip install \
  fastapi==0.118.0 \
  uvicorn==0.37.0 \
  python-multipart==0.0.20 \
  pydantic==2.11.9 \
  accelerate==1.12.0 \
  einops==0.8.1 \
  fire==0.7.1 \
  openai==2.8.1 \
  safetensors==0.4.5 \
  transformers==4.56.1

mkdir -p "$OUTPUTS_DIR" "$LOG_DIR"
echo "Setup completed in $VENV_DIR"
