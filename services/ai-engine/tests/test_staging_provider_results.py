"""Synthetic staging provider orchestration. No provider client or network is used."""

import asyncio
from time import monotonic

import pytest

from staging_provider_results import collect_provider_results


async def completed(result):
    return result


def run(providers, seconds=1):
    return asyncio.run(collect_provider_results(providers, deadline=monotonic() + seconds))


@pytest.mark.parametrize("positive,benign", [("bedrock", "own"), ("own", "bedrock")])
def test_each_provider_keeps_its_own_verdict(positive, benign):
    # Mutants: copy the first verdict to both providers, or rank logits again at a shared cutoff.
    flagged = {"flagged": True, "flagged_categories": {"cyberbullying": 0.41}}
    safe = {"flagged": False, "flagged_categories": {}}
    results = run({positive: lambda: completed(flagged), benign: lambda: completed(safe)})
    assert results[positive].verdict == flagged
    assert results[benign].verdict == safe
    assert all(outcome.failure is None for outcome in results.values())


def test_failed_provider_has_no_verdict_and_its_peer_survives():
    # Mutants: convert AdapterUnavailable to a safe result, or copy a provider's raw error to evidence.
    async def unavailable():
        raise RuntimeError("private synthetic input marker")

    positive = {"flagged": True}
    results = run({"own": unavailable, "bedrock": lambda: completed(positive)})
    assert results["own"].failure == "unavailable"
    assert results["own"].verdict is None
    assert results["bedrock"].verdict == positive
    assert "private synthetic input marker" not in repr(results)


def test_shared_deadline_runs_concurrently_and_preserves_finished_peer():
    # Mutants: run sequentially or throw away a completed result when its peer times out.
    async def sample():
        slow_started = asyncio.Event()
        cancelled = asyncio.Event()

        async def stuck():
            slow_started.set()
            try:
                await asyncio.Event().wait()
            finally:
                cancelled.set()

        async def benign():
            await slow_started.wait()
            return {"flagged": False}

        results = await collect_provider_results({"own": stuck, "bedrock": benign}, deadline=monotonic() + 0.05)
        assert cancelled.is_set()
        return results

    results = asyncio.run(sample())
    assert results["own"].failure == "timeout"
    assert results["own"].verdict is None
    assert results["bedrock"].verdict == {"flagged": False}


def test_expired_request_never_invokes_either_provider():
    # Mutant: schedule inference after expiry, then discard its reply.
    calls = []

    async def score():
        calls.append(1)
        return {"flagged": True}

    results = run({"own": score, "bedrock": score}, seconds=-1)
    assert calls == []
    assert [outcome.failure for outcome in results.values()] == ["timeout", "timeout"]


def test_one_provider_mode_invokes_only_selected_provider():
    calls = []

    async def selected():
        calls.append("own")
        return {"flagged": False}

    assert set(run({"own": selected})) == {"own"}
    assert calls == ["own"]


def test_no_result_or_provider_cancellation_is_unavailable():
    # Mutants: convert no reply into a benign verdict, or attribute a provider cancellation to our deadline.
    async def cancelled():
        raise asyncio.CancelledError

    results = run({"own": lambda: completed(None), "bedrock": cancelled})
    assert all(outcome.verdict is None and outcome.failure == "unavailable" for outcome in results.values())


def test_two_benign_results_and_two_failures_remain_distinct():
    benign = {"flagged": False, "flagged_categories": {}}
    providers = ("own", "bedrock")
    results = run({name: lambda: completed(benign) for name in providers})
    assert all(outcome.verdict == benign and outcome.failure is None for outcome in results.values())

    async def timed_out():
        raise TimeoutError

    results = run({name: timed_out for name in providers})
    assert all(outcome.verdict is None and outcome.failure == "timeout" for outcome in results.values())


def test_request_cancellation_releases_every_provider():
    async def sample():
        started = [asyncio.Event(), asyncio.Event()]
        stopped = [asyncio.Event(), asyncio.Event()]

        async def wait(index):
            started[index].set()
            try:
                await asyncio.Event().wait()
            finally:
                stopped[index].set()

        request = asyncio.create_task(collect_provider_results(
            {"own": lambda: wait(0), "bedrock": lambda: wait(1)}, deadline=monotonic() + 25,
        ))
        await asyncio.gather(*(event.wait() for event in started))
        request.cancel()
        with pytest.raises(asyncio.CancelledError):
            await request
        assert all(event.is_set() for event in stopped)

    asyncio.run(sample())
