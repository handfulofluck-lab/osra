"""Evaluation harness for the child-safety scorer (roadmap plan 4.2 and 4.3).

The package is deliberately dependency-free: it imports only `model.py` and the
standard library, so it runs in CI next to the pytest suite without torch,
transformers or an API key.

Entry points:
    python -m eval.generate        regenerate eval/dataset.jsonl from the banks
    python -m eval.run_eval        score a dataset and print precision/recall
    python -m eval.banks           validate every template bank
"""

import os
import sys

# `model.py` lives one level up (services/ai-engine/model.py). Google's
# convention here is flat modules run from this directory; adding the root
# explicitly keeps `python -m eval.*` working from any cwd and from pytest.
_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)
