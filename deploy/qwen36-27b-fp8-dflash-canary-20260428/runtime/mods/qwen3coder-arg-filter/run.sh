#!/bin/bash
set -euo pipefail

python3 - <<'PY'
from pathlib import Path
import sys

path = Path("/usr/local/lib/python3.12/dist-packages/vllm/tool_parsers/qwen3coder_tool_parser.py")
text = path.read_text()

old_nonstream = """            param_dict[param_name] = self._convert_param_value(
                param_value, param_name, param_config, function_name
            )
"""
new_nonstream = """            if param_config and param_name not in param_config:
                logger.debug(
                    "Dropping unsupported parameter '%s' for tool '%s'.",
                    param_name,
                    function_name,
                )
                continue

            param_dict[param_name] = self._convert_param_value(
                param_value, param_name, param_config, function_name
            )
"""

old_stream = """                converted_value = self._convert_param_value(
                    param_value,
                    current_param_name,
                    param_config,
                    self.current_function_name or "",
                )
"""
new_stream = """                if param_config and current_param_name not in param_config:
                    logger.debug(
                        "Dropping unsupported parameter '%s' for tool '%s' during streaming.",
                        current_param_name,
                        self.current_function_name or "",
                    )
                    continue

                converted_value = self._convert_param_value(
                    param_value,
                    current_param_name,
                    param_config,
                    self.current_function_name or "",
                )
"""

hydrate_nonstream = """        if not self.tools and request.tools:
            self.tools = list(request.tools)

"""

hydrate_stream = """        if not previous_text:
            self._reset_streaming_state()
            self.streaming_request = request
            if not self.tools and request.tools:
                self.tools = list(request.tools)
"""

if "Dropping unsupported parameter" in text and "self.tools = list(request.tools)" in text:
    print("qwen3coder arg filter already present; skipping")
    sys.exit(0)

if old_nonstream not in text or old_stream not in text:
    print("expected qwen3coder parser snippets not found; aborting", file=sys.stderr)
    sys.exit(1)

nonstream_anchor = """        try:
            function_calls = self._get_function_calls(model_output)
"""
nonstream_repl = """        try:
            if not self.tools and request.tools:
                self.tools = list(request.tools)
            function_calls = self._get_function_calls(model_output)
"""

stream_anchor = """        if not previous_text:
            self._reset_streaming_state()
            self.streaming_request = request
"""

if nonstream_anchor not in text or stream_anchor not in text:
    print("expected qwen3coder request hydration anchors not found; aborting", file=sys.stderr)
    sys.exit(1)

text = text.replace(nonstream_anchor, nonstream_repl, 1)
text = text.replace(stream_anchor, hydrate_stream, 1)
text = text.replace(old_nonstream, new_nonstream, 1)
text = text.replace(old_stream, new_stream, 1)
path.write_text(text)
print("Patched qwen3coder parser to hydrate request.tools and drop unsupported tool parameters")
PY
