"""Collect independent staging provider results under one monotonic deadline."""

import asyncio
from collections.abc import Awaitable, Callable, Mapping
from dataclasses import dataclass
from time import monotonic
from typing import Generic, Literal, TypeVar

Verdict = TypeVar("Verdict")
Provider = Literal["osra", "bedrock"]


@dataclass(frozen=True)
class ProviderResult(Generic[Verdict]):
    verdict: Verdict | None = None
    failure: Literal["timeout", "unavailable"] | None = None


async def collect_provider_results(
    providers: Mapping[Provider, Callable[[], Awaitable[Verdict]]], *, deadline: float
) -> dict[Provider, ProviderResult[Verdict]]:
    """Run the selected providers concurrently. Each caller validates its provider's reply."""
    async def score(invoke: Callable[[], Awaitable[Verdict]]) -> ProviderResult[Verdict]:
        if monotonic() >= deadline:
            return ProviderResult(failure="timeout")
        try:
            verdict = await invoke()
        except TimeoutError:
            return ProviderResult(failure="timeout")
        except Exception:
            # A provider may include private input or output in an exception.
            return ProviderResult(failure="unavailable")
        if monotonic() >= deadline:
            return ProviderResult(failure="timeout")
        if verdict is None:
            return ProviderResult(failure="unavailable")
        return ProviderResult(verdict=verdict)

    if not providers:
        return {}
    tasks = {name: asyncio.create_task(score(invoke)) for name, invoke in providers.items()}
    try:
        done, _ = await asyncio.wait(tasks.values(), timeout=max(0, deadline - monotonic()))
        outcomes = {}
        for name, task in tasks.items():
            if task not in done:
                outcomes[name] = ProviderResult(failure="timeout")
            elif task.cancelled():
                outcomes[name] = ProviderResult(failure="unavailable")
            else:
                outcomes[name] = task.result()
        return outcomes
    finally:
        for task in tasks.values():
            if not task.done():
                task.cancel()
        # Let cooperative HTTP clients release connections. A slow cancellation must not
        # extend the response deadline. The Bedrock SDK separately enforces socket timeouts.
        await asyncio.sleep(0)
