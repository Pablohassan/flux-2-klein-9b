#!/bin/bash
set -euo pipefail

patch --forward -p1 -d /usr/local/lib/python3.12/dist-packages < "$(dirname "$0")/pr38361_min.diff" || true
