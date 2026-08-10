# 5-Second Defer Timer for Same-Key Rate Limiting

## Problem

Even with `child_process.spawn` (completely separate OS process with its own HTTP connection pool), the review's API call and the main agent's API call use the **same DeepSeek API key**. Two concurrent requests to `api.deepseek.com` with the same key can trigger server-side rate limiting, returning `503 Service Too Busy`.

## Root Cause

DeepSeek's API applies per-key rate limiting. The main agent's streaming call (`stream()`) may still be in-flight when the review's `chat()` call starts — even though they're in separate OS processes, the API key is the same, and DeepSeek sees concurrent requests from the same credential.

## Fix

5-second defer timer on the fork, cancelled when the next user message arrives:

```typescript
// After agent loop completes:
if (reviewMemory || reviewSkills) {
    s._reviewTimer = setTimeout(() => {
        s.spawnBackgroundReview(msgList, ...).catch(() => {});
    }, 5000);
}

// At start of next chat() turn:
if (s._reviewTimer) {
    clearTimeout(s._reviewTimer);
    s._reviewTimer = null;
}
```

## Why 5 seconds?

- Main agent's streaming call typically finishes within 2-4 seconds
- Response delivery to gateway takes <100ms
- User reading response + typing next message takes 5+ seconds
- If user replies within 5s, timer is cancelled → no concurrent calls
- After 5s, main agent is definitely idle → safe to start review

## Why Hermes Doesn't Hit This

Hermes uses `threading.Thread` in Python. The thread's API call doesn't start until the main thread has fully processed the response and returned from `chat()`. The sequential timing means the main agent's API call is always complete before the review starts. In Node.js, `fire-and-forget` starts the review synchronously after the agent loop, potentially before the streaming response is fully flushed to the gateway. The 5-second delay emulates Python's natural sequential timing.

## Verification

- Review works without 503 errors
- User sends message within 5s of response → review cancelled, no API call made
- User idles >5s → review starts, completes, no concurrent API calls
