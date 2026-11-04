import os
import sys
import tempfile
from pathlib import Path

# Environment must be set BEFORE the app is imported.
_tmp = tempfile.mkdtemp()
os.environ["DATABASE_URL"] = f"sqlite:///{_tmp}/test.db"
os.environ["JWT_SECRET"] = "test-secret"
os.environ["MPESA_MODE"] = "mock"
os.environ["AUTO_SEED"] = "1"
os.environ["CALLBACK_SECRET"] = "cb-secret"
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
