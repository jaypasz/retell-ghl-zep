"""
Lightweight Langfuse helper for this project.

Provides:
- `get_prompt(name, version=None, fallback=None)` -> returns object with `.prompt` and `.version`
- `create_trace(name, user_id=None, session_id=None, metadata=None)` -> returns a trace-like object with `generation`, `score`, `update` methods

This module is defensive: if Langfuse is not configured or the SDK is unavailable,
it provides fallbacks so the app continues to work.
"""
import os
import logging

logger = logging.getLogger(__name__)

LANGFUSE_PUBLIC_KEY = os.getenv("LANGFUSE_PUBLIC_KEY")
LANGFUSE_SECRET_KEY = os.getenv("LANGFUSE_SECRET_KEY")
LANGFUSE_BASE_URL = os.getenv("LANGFUSE_BASE_URL", "https://cloud.langfuse.com")
LANGFUSE_ENABLED = bool(LANGFUSE_PUBLIC_KEY and LANGFUSE_SECRET_KEY)

# Try to import the Langfuse SDK; if unavailable, operate in fallback mode
try:
    from langfuse import Langfuse  # type: ignore
except Exception:
    Langfuse = None


class _FallbackPrompt:
    def __init__(self, text: str, name: str = "fallback", version: int = 0):
        self.prompt = text or ""
        self.version = version
        self.name = name


class _DummyTrace:
    def __init__(self, name: str, user_id: str = None, session_id: str = None, metadata: dict = None):
        self.name = name
        self.user_id = user_id
        self.session_id = session_id
        self.metadata = metadata or {}

    def generation(self, **kwargs):
        logger.debug("DummyTrace.generation: %s", kwargs)

    def score(self, **kwargs):
        logger.debug("DummyTrace.score: %s", kwargs)

    def update(self, **kwargs):
        logger.debug("DummyTrace.update: %s", kwargs)


# Initialize Langfuse client if possible
_client = None
if LANGFUSE_ENABLED and Langfuse is not None:
    try:
        _client = Langfuse(
            public_key=LANGFUSE_PUBLIC_KEY,
            secret_key=LANGFUSE_SECRET_KEY,
            host=LANGFUSE_BASE_URL
        )
        logger.info("Langfuse client initialized")
    except Exception as e:
        logger.error("Failed to initialize Langfuse client: %s", e, exc_info=True)
        _client = None


def get_prompt(name: str, version: int = None, fallback: str = None):
    """Fetch a prompt object from Langfuse or return a fallback prompt.

    Returns an object with `.prompt` (string) and `.version` (int).
    """
    if _client is None:
        logger.warning("Langfuse client not available, returning fallback for %s", name)
        return _FallbackPrompt(fallback or "", name=name, version=0)

    try:
        if version is not None:
            p = _client.get_prompt(name, version=version)
        else:
            p = _client.get_prompt(name)

        # SDK prompt object shape may vary; try to return a minimal wrapper
        return p
    except Exception as e:
        logger.error("Error fetching prompt %s: %s", name, e, exc_info=True)
        return _FallbackPrompt(fallback or "", name=name, version=0)


def create_trace(name: str, user_id: str = None, session_id: str = None, metadata: dict = None):
    """Create and return a trace object (or dummy trace if Langfuse unavailable).

    The returned object should support `generation()`, `score()`, and `update()`.
    """
    if _client is None:
        return _DummyTrace(name=name, user_id=user_id, session_id=session_id, metadata=metadata)

    try:
        return _client.trace(name=name, user_id=user_id, session_id=session_id, metadata=metadata)
    except Exception as e:
        logger.error("Failed to create Langfuse trace: %s", e, exc_info=True)
        return _DummyTrace(name=name, user_id=user_id, session_id=session_id, metadata=metadata)
