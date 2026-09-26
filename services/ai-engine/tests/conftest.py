import os
import sys

# Make model.py / app.py importable from the tests directory.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# Force the deterministic dev-mode fallback path regardless of the host env.
os.environ["MODEL_PATH"] = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), ".nonexistent-model"
)
