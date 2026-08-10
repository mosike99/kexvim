# QQ Bot API 4000-Character Message Limit

QQ Bot API v2 enforces a **4000 character limit** per single message (C2C and group). Exceeding this causes the API to silently truncate or reject the message.

## Symptom

User sees only the first ~4000 characters of a long response. Sage's agent loop thinks it completed normally. User sends "继续" / follow-up, but Sage doesn't know the response was cut off. To the user, Sage "stopped responding."

## Root Cause

```typescript
// QQBotAPIAdapter.ts — ORIGINAL (silent truncation)
const body: Record<string, unknown> = {
  content: content.slice(0, MAX_MSG_LENGTH),  // ← silently drops everything after 4000
  msg_type: MSG_TYPE_TEXT,
  msg_seq: (Date.now() & 0xffffffff) >>> 0,
};
```

## Fix: `sendLongMessage` Helper

Replace the `slice()` with a split-and-send loop:

```typescript
private async sendLongMessage(
  sendFn: (chunk: string, replyTo?: string | null) => Promise<boolean>,
  content: string,
  replyTo?: string | null,
): Promise<boolean> {
  if (content.length <= MAX_MSG_LENGTH) {
    return sendFn(content, replyTo);
  }
  let ok = true;
  let remaining = content;
  let first = true;
  while (remaining.length > 0) {
    const chunk = remaining.slice(0, MAX_MSG_LENGTH);
    remaining = remaining.slice(MAX_MSG_LENGTH);
    const sent = await sendFn(chunk, first ? replyTo : null);
    if (!sent) ok = false;
    first = false;
  }
  return ok;
}
```

Then wrap each send method:

```typescript
private async sendC2CMessage(openid, content, replyTo): Promise<boolean> {
  return this.sendLongMessage(
    (chunk, reply) => this._doSendC2C(openid, chunk, reply),
    content, replyTo,
  );
}

private async sendGroupMessage(groupOpenid, content, replyTo): Promise<boolean> {
  return this.sendLongMessage(
    (chunk, reply) => this._doSendGroup(groupOpenid, chunk, reply),
    content, replyTo,
  );
}
```

## Details

- **First chunk** carries the `replyTo` (msg_id) for quote-reply. Subsequent chunks omit it to avoid confusing the QQ client with multiple quotes.
- **No delay between chunks** — QQ API accepts rapid sequential sends. No sleep/cooldown needed.
- **Error handling**: If any chunk fails, `ok` is set to `false` but remaining chunks still attempt delivery. The caller receives the overall result.
- **`msg_seq`**: Each chunk gets a new `msg_seq` (fresh `Date.now()`). QQ uses this for dedup; sequential messages are distinct, not duplicates.
