"""Tools to generate from OpenAI prompts.
Adopted from https://github.com/zeno-ml/zeno-build/"""

import asyncio
import json
import logging
import math
import os
import random
import time
from typing import Any
from contextvars import ContextVar

import aiolimiter
import httpx
import openai
from openai import AsyncOpenAI, OpenAI

base_url = os.environ.get("OPENAI_API_URL")
# Retry in this module only, rather than multiplying SDK and outer retries.
CLIENT_OPTIONS = {
    "timeout": float(os.environ.get("LLM_REQUEST_TIMEOUT", "180")),
    "max_retries": 0,
}
_request_deadline = ContextVar("llm_request_deadline", default=None)


def get_client_options():
    options = dict(CLIENT_OPTIONS)
    deadline = _request_deadline.get()
    if deadline is not None:
        options["timeout"] = min(options["timeout"], max(0.001, deadline - time.monotonic()))
    return options


client = OpenAI(api_key=os.environ["OPENAI_API_KEY"], base_url=base_url, **get_client_options())
aclient = AsyncOpenAI(api_key=os.environ["OPENAI_API_KEY"], base_url=base_url, **get_client_options())
from tqdm.asyncio import tqdm_asyncio


def retry_with_exponential_backoff(  # type: ignore
    func,
    initial_delay: float = 30,
    exponential_base: float = 2,
    jitter: bool = True,
    max_retries: int = 20,
    errors: tuple[Any] = (
        openai.RateLimitError,
        openai.InternalServerError,
        openai.APIConnectionError,
    ),
):
    """Retry a function with exponential backoff."""

    def wrapper(*args, **kwargs):  # type: ignore
        num_retries = 0
        delay = float(os.environ.get("LLM_RETRY_INITIAL_DELAY", str(initial_delay)))
        max_delay = float(os.environ.get("LLM_RETRY_MAX_DELAY", "120"))
        window = float(os.environ.get("LLM_RETRY_WINDOW", "1800"))
        retry_limit = int(os.environ.get("LLM_MAX_RETRIES", str(max_retries)))
        if retry_limit < 0 or any(not math.isfinite(v) or v <= 0 for v in (delay, max_delay, window)):
            raise ValueError("Invalid LLM retry policy: retries must be non-negative and delays/window positive and finite")
        started = time.monotonic()
        deadline = started + window
        token = _request_deadline.set(deadline)
        last_error = None
        logger = logging.getLogger("logger")
        try:
            while True:
                if time.monotonic() >= deadline:
                    raise RuntimeError(
                        f"LLM retry window ({window:g}s) exhausted after {num_retries} attempts: {last_error}"
                    ) from last_error
                try:
                    result = func(*args, **kwargs)
                    if num_retries:
                        logger.info("LLM recovered after %d retries (%.1fs); continuing the current task",
                                    num_retries, time.monotonic() - started)
                    return result
                except openai.APIError as e:
                    status = getattr(e, "status_code", None)
                    retryable = (isinstance(e, errors) or status in (408, 409)
                                 or (status == 404 and "ERR_NGROK_3200" in str(e)))
                    if not retryable:
                        raise  # Bad credentials, invalid requests and missing models need a fix.
                    num_retries += 1
                    last_error = e
                    remaining = deadline - time.monotonic()
                    if num_retries > retry_limit or remaining <= 0:
                        raise RuntimeError(
                            f"LLM request failed after {num_retries} attempts: "
                            f"{type(e).__name__} (HTTP {status}): {e}"
                        ) from e
                    wait = min(max_delay, delay * (1 + 0.2 * random.random() if jitter else 1), remaining)
                    logger.warning(
                        "LLM unavailable: %s (HTTP %s): %s; retry %d/%d in %.1fs (%.0fs retry window remaining)",
                        type(e).__name__, status, str(e).replace("\n", " ")[:400],
                        num_retries, retry_limit, wait, remaining,
                    )
                    time.sleep(wait)
                    delay = min(max_delay, delay * exponential_base)
        finally:
            _request_deadline.reset(token)

    return wrapper


async def _throttled_openai_completion_acreate(
    engine: str,
    prompt: str,
    temperature: float,
    max_tokens: int,
    top_p: float,
    limiter: aiolimiter.AsyncLimiter,
) -> dict[str, Any]:
    async with limiter:
        for _ in range(3):
            try:
                return await aclient.completions.create(
                    engine=engine,
                    prompt=prompt,
                    temperature=temperature,
                    max_tokens=max_tokens,
                    top_p=top_p,
                )
            except openai.RateLimitError:
                logging.warning(
                    "OpenAI API rate limit exceeded. Sleeping for 10 seconds."
                )
                await asyncio.sleep(10)
            except openai.APIError as e:
                logging.warning(f"OpenAI API error: {e}")
                break
        return {"choices": [{"message": {"content": ""}}]}


async def agenerate_from_openai_completion(
    prompts: list[str],
    engine: str,
    temperature: float,
    max_tokens: int,
    top_p: float,
    context_length: int,
    requests_per_minute: int = 300,
) -> list[str]:
    """Generate from OpenAI Completion API.

    Args:
        prompts: list of prompts
        temperature: Temperature to use.
        max_tokens: Maximum number of tokens to generate.
        top_p: Top p to use.
        context_length: Length of context to use.
        requests_per_minute: Number of requests per minute to allow.

    Returns:
        List of generated responses.
    """
    if "OPENAI_API_KEY" not in os.environ:
        raise ValueError(
            "OPENAI_API_KEY environment variable must be set when using OpenAI API."
        )

    limiter = aiolimiter.AsyncLimiter(requests_per_minute)
    async_responses = [
        _throttled_openai_completion_acreate(
            engine=engine,
            prompt=prompt,
            temperature=temperature,
            max_tokens=max_tokens,
            top_p=top_p,
            limiter=limiter,
        )
        for prompt in prompts
    ]
    responses = await tqdm_asyncio.gather(*async_responses)
    return [x["choices"][0]["text"] for x in responses]


@retry_with_exponential_backoff
def generate_from_openai_completion(
    prompt: str,
    model: str,
    temperature: float,
    max_tokens: int,
    top_p: float,
    stop_token: str | None = None,
    api_key: str | None = None,
    base_url: str | None = None
) -> str:
    if "OPENAI_API_KEY" not in os.environ and api_key is None:
        raise ValueError(
            "OPENAI_API_KEY environment variable must be set when using OpenAI API."
        )
    request_client = (OpenAI(api_key=api_key, base_url=base_url, **get_client_options())
                      if api_key is not None else client.with_options(**get_client_options()))
        
    response = request_client.completions.create(
        prompt=prompt,
        model=model,
        temperature=temperature,
        max_tokens=max_tokens,
        top_p=top_p,
        stop=[stop_token],
    )
    try:
        answer: str = response["choices"][0]["text"]
    except:
        answer: str = response.choices[0].text
    return answer


async def _throttled_openai_chat_completion_acreate(
    model: str,
    messages: list[dict[str, str]],
    temperature: float,
    max_tokens: int,
    top_p: float,
    limiter: aiolimiter.AsyncLimiter,
) -> dict[str, Any]:
    async with limiter:
        for _ in range(3):
            try:
                return await aclient.chat.completions.create(
                    model=model,
                    messages=messages,
                    temperature=temperature,
                    max_tokens=max_tokens,
                    top_p=top_p,
                )
            except openai.RateLimitError:
                logging.warning(
                    "OpenAI API rate limit exceeded. Sleeping for 10 seconds."
                )
                await asyncio.sleep(10)
            except asyncio.exceptions.TimeoutError:
                logging.warning("OpenAI API timeout. Sleeping for 10 seconds.")
                await asyncio.sleep(10)
            except openai.APIError as e:
                logging.warning(f"OpenAI API error: {e}")
                break
        return {"choices": [{"message": {"content": ""}}]}


async def agenerate_from_openai_chat_completion(
    messages_list: list[list[dict[str, str]]],
    engine: str,
    temperature: float,
    max_tokens: int,
    top_p: float,
    context_length: int,
    requests_per_minute: int = 300,
) -> list[str]:
    """Generate from OpenAI Chat Completion API.

    Args:
        messages_list: list of message list
        temperature: Temperature to use.
        max_tokens: Maximum number of tokens to generate.
        top_p: Top p to use.
        context_length: Length of context to use.
        requests_per_minute: Number of requests per minute to allow.

    Returns:
        List of generated responses.
    """
    if "OPENAI_API_KEY" not in os.environ:
        raise ValueError(
            "OPENAI_API_KEY environment variable must be set when using OpenAI API."
        )

    limiter = aiolimiter.AsyncLimiter(requests_per_minute)
    async_responses = [
        _throttled_openai_chat_completion_acreate(
            model=engine,
            messages=message,
            temperature=temperature,
            max_tokens=max_tokens,
            top_p=top_p,
            limiter=limiter,
        )
        for message in messages_list
    ]
    responses = await tqdm_asyncio.gather(*async_responses)
    return [x["choices"][0]["message"]["content"] for x in responses]


def _collect_chat_stream(stream) -> str:
    """Return only a completed answer; never expose partial output to the agent."""
    logger = logging.getLogger("logger")
    started = last_log = time.monotonic()
    content = []
    content_chars = reasoning_chars = 0
    first_token = False
    finish_reason = None
    request = stream.response.request
    logger.info("LLM stream opened; waiting for generated text")
    try:
        with stream:
            for chunk in stream:
                now = time.monotonic()
                deadline = _request_deadline.get()
                if deadline is not None and now >= deadline:
                    raise openai.APITimeoutError(request=request)
                for choice in chunk.choices:
                    if choice.index != 0:
                        continue
                    delta = choice.delta
                    text = delta.content or ""
                    reasoning = (getattr(delta, "reasoning_content", None)
                                 or getattr(delta, "reasoning", None) or "")
                    content.append(text)
                    content_chars += len(text)
                    reasoning_chars += len(reasoning)
                    if not first_token and (text or reasoning):
                        logger.info("LLM stream first text after %.1fs", now - started)
                        first_token = True
                    if choice.finish_reason is not None:
                        finish_reason = choice.finish_reason
                if now - last_log >= 30:
                    logger.info("LLM stream active: %.1fs; reasoning_chars=%d; content_chars=%d",
                                now - started, reasoning_chars, content_chars)
                    last_log = now
        if finish_reason is None:
            raise openai.APIConnectionError(
                message="LLM stream ended without finish_reason; discarding partial response",
                request=request,
            )
    except httpx.TimeoutException as exc:
        # The SDK wraps request setup errors, but raw httpx errors can escape
        # while iterating the body. Normalize them for the existing retry policy.
        raise openai.APITimeoutError(request=request) from exc
    except httpx.TransportError as exc:
        raise openai.APIConnectionError(
            message=f"LLM stream interrupted ({type(exc).__name__}); discarding partial response",
            request=request,
        ) from exc
    logger.info("LLM stream finished: %.1fs; finish_reason=%s; reasoning_chars=%d; content_chars=%d",
                time.monotonic() - started, finish_reason, reasoning_chars, content_chars)
    return "".join(content)


@retry_with_exponential_backoff
def generate_from_openai_chat_completion(
    messages: list[dict[str, str]],
    model: str,
    temperature: float,
    max_tokens: int,
    top_p: float,
    context_length: int,
    stop_token: str | None = None,
    api_key: str | None = None,
    base_url: str | None = None,
) -> str:
    
    if "OPENAI_API_KEY" not in os.environ and api_key is None:
        raise ValueError(
            "OPENAI_API_KEY environment variable must be set when using OpenAI API."
        )
    
    request_client = (OpenAI(api_key=api_key, base_url=base_url, **get_client_options())
                      if api_key is not None else client.with_options(**get_client_options()))
    actor_url = os.environ.get("OPENAI_API_URL")
    is_actor = (base_url or str(request_client.base_url)).rstrip("/") == (actor_url or "").rstrip("/")
    stream_value = os.environ.get("LLM_STREAM", "false").lower()
    if stream_value not in ("true", "false", "1", "0"):
        raise ValueError("LLM_STREAM must be true/false or 1/0")
    streaming = is_actor and stream_value in ("true", "1")
    stream_options = {"stream": True} if streaming else {}
    if model in ['o3-mini', 'o3', 'o4-mini']:
        response = request_client.chat.completions.create(
            model=model,
            messages=messages,
            temperature=temperature,
            max_completion_tokens=max_tokens,
            **stream_options,
            # top_p=top_p,
        )
    else:
        # Optional settings for OpenAI-compatible servers such as vLLM.
        request_options = {}
        if (os.environ.get("OPENAI_CHAT_TEMPLATE_KWARGS")
                and base_url == os.environ.get("OPENAI_API_URL")):
            request_options["extra_body"] = {
                "chat_template_kwargs": json.loads(
                    os.environ["OPENAI_CHAT_TEMPLATE_KWARGS"]
                )
            }
        response = request_client.chat.completions.create(
            model=model,
            messages=messages,
            temperature=temperature,
            max_tokens=max_tokens,
            top_p=top_p,
            **stream_options,
            **request_options,
        )
    if streaming:
        return _collect_chat_stream(response)
    answer: str = response.choices[0].message.content
    return answer


@retry_with_exponential_backoff
# debug only
def fake_generate_from_openai_chat_completion(
    messages: list[dict[str, str]],
    model: str,
    temperature: float,
    max_tokens: int,
    top_p: float,
    context_length: int,
    stop_token: str | None = None,
) -> str:
    if "OPENAI_API_KEY" not in os.environ:
        raise ValueError(
            "OPENAI_API_KEY environment variable must be set when using OpenAI API."
        )

    answer = "Let's think step-by-step. This page shows a list of links and buttons. There is a search box with the label 'Search query'. I will click on the search box to type the query. So the action I will perform is \"click [60]\"."
    return answer
