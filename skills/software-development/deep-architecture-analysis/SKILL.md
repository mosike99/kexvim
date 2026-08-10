---
name: deep-architecture-analysis
description: "Deep-read source code to document architecture and flow."
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux, macos, windows]
metadata:
  kexvim:
    tags: [architecture, analysis, code-reading, reverse-engineering, documentation, streaming]
    related_skills: [codebase-inspection, systematic-debugging, kexvim-skill-authoring]
---

# Deep Architecture Analysis

Systematically read, understand, and document the architecture of complex codebases — especially asynchronous/streaming agent loops, callback chains, and multi-layer systems.

## When to Use

- User asks "how does X work internally" — especially streaming, async, or event-driven systems
- You need to understand a subsystem deeply to debug, extend, or explain it
- The codebase is large (5K-50K+ lines) and you need structured understanding, not surface-level familiarity
- The system involves callbacks, streaming, tool execution, or multi-layer architecture (core → helper → gateway)
- You need to produce documentation, pseudocode, or flow diagrams from real source

**Do NOT use for:** quick LOC counts (use `codebase-inspection`), fixing a specific bug (use `systematic-debugging`), or evaluating a PR (use `github-code-review`).

## Core Methodology

### Phase 1: Identify the Entry Points

Start broad. Identify the key files from descriptions, imports, or file structure before reading any code deeply.

```python
# Pattern: find the key files
search_files("pattern", path="project/", file_glob="*.py", limit=50)

# Pattern: find function definitions
search_files("def key_function_name", path="project/", limit=20)

# Pattern: find files by name
search_files("pattern", target="files", path="project/")
```

### Phase 2: Structural Overview (Function Signatures First)

Read function/method signatures and docstrings BEFORE reading the body. Understand what each module provides before tracing how.

```python
# Read the first ~30 lines of each key file for module-level docstrings + imports
read_file("project/module.py", limit=30)

# Search for class definitions + their key methods
search_files("def (run|_call|_fire|_stream|_emit|_execute)", path="project/module.py")
```

### Phase 3: Follow the Data Flow

Trace the execution path through the code. For streaming/async systems, identify:

1. **Where the stream is created** (e.g. `client.chat.completions.create(stream=True)`)
2. **How chunks are iterated** (`for chunk in stream:`)
3. **How each chunk type is handled** (text delta, tool_call delta, reasoning delta, finish_reason)
4. **How the accumulated response is returned** (mock response, SimpleNamespace, etc.)
5. **How callbacks are fired** (which callback, what data, at what point)

```python
# For agent loop analysis, a typical read sequence:
search_files("for chunk in|async for", ...)          # Find stream iteration
search_files("delta\.content|delta\.tool_calls", ...) # Find chunk processing
search_files("stream_delta_callback|_fire_stream_delta", ...) # Find callback chain
search_files("finish_reason", ...)                     # Find termination logic
search_files("tool_progress_callback", ...)             # Find tool-lifecycle hooks
```

### Phase 4: Trace Callbacks Across Layers

Streaming/async systems often have callbacks that propagate through multiple layers (core → helper → gateway → adapter). Trace them end-to-end:

```
Agent core (run_agent.py)
  → agent._fire_stream_delta(text)
    → helper module (chat_completion_helpers.py)
      → stream_delta_callback(text)
        → gateway/CLI layer
          → gateway run.py: _stream_delta_cb(text)
            → adapter/platform
```

For each callback, identify:
- **Registration point:** where the callback is stored on the agent
- **Fire point:** where the callback is invoked
- **Consumer:** what receives and processes the callback data
- **De-duplication guards:** how the system avoids duplicate delivery (single-writer tokens, interim text dedup, etc.)

```python
# Find callback registration
search_files("stream_delta_callback =", path="agent/")

# Find callback invocation
search_files("stream_delta_callback\(", path="agent/")  
search_files("tool_progress_callback\(", path="agent/")

# Find callback consumer (gateway layer)
search_files("def _stream_delta_cb", path="gateway/")
```

### Phase 5: Read Critical Loops in Full

For the core loop (e.g. streaming iteration in a 3K+ line function):

1. Read the loop header (`for chunk in stream:`)
2. Read the first/last branches (early exit conditions, edge cases)
3. Read each chunk-type handler individually
4. Read the response assembly (how chunks become a final response)
5. Read error handling (empty stream, truncated args, connection drops)

```python
# Read the streaming chunk processing loop
read_file("chat_completion_helpers.py", offset=2759, limit=300)

# Read the mock response assembly
read_file("chat_completion_helpers.py", offset=2930, limit=50)
```

### Phase 6: Validate Understanding

Cross-reference your understanding against the code:

1. **Verify callback flow:** trace a text delta from chunk → callback chain → UI
2. **Verify tool execution flow:** trace from chunk → tool_calls_acc → mock response → run_conversation dispatching → tool_executor
3. **Verify error paths:** what happens when finish_reason=None, tool args truncated, connection dropped
4. **Verify flush points:** when does accumulated text actually reach the user

### Phase 7: Synthesize Into Documentation

Structure the output by **execution phase**, not by file/module. For streaming agent loops, a natural structure is:

1. **Stream initialization** — how the stream is created, conditions for streaming vs non-streaming
2. **Text chunk accumulation** — how text deltas are collected, callbacks fired, deduplication
3. **Tool_use chunk handling** — how tool_call deltas are accumulated, assignment of indices/IDs
4. **Flush timing** — when accumulated text reaches the user (real-time vs on completion)
5. **Tool execution** — how tools are dispatched (sequential, concurrent, segmented), callback lifecycle
6. **Done/final handling** — how the final response is assembled and returned
7. **Error handling** — stream drops, truncation, retry logic, fallback chains

Document key line numbers for each phase so future sessions can jump directly to the right code.

## Support Files

### references/

- `hermes-streaming-agent-loop.md` — Full pseudocode/flow diagram of Hermes streaming agent loop, covering all 7 phases above with exact line numbers across 4 key files (~16K lines of source analyzed).

## Pitfalls

1. **Don't read line-by-line from the start.** Start with signatures/docstrings, then search for the pattern you need. Reading a 5800-line function from line 1 wastes time.
2. **Don't stop at the core layer.** Callbacks are registered in one file, fired in another, and consumed in a third. Always trace all three.
3. **Don't describe what you would do — do it.** Execute actual `search_files` and `read_file` calls to verify every assertion against real source.
4. **Document line numbers.** Future sessions reading the same code can jump directly if you record where each phase lives.
5. **Beware of SimpleNamespace mocks.** Streaming code often constructs `SimpleNamespace` objects to return mock responses. These look like real API responses but are fabricated in code — understand the fabrication to avoid debugging the wrong layer.
6. **Check for single-writer guards.** Complex streaming systems with retry use thread-level tokens to fence stale streams. Without tracking these, you'll see "lost" deltas and think they're bugs.
7. **Track the `_has_stream_consumers()` gate.** Many decisions (whether to stream, whether to suppress content during tool generation, whether to fire interim callbacks) branch on whether any consumer is registered. This one Boolean controls multiple behavioral forks.
