# Gauge Review — Task 2 Iteration 1

**Reviewer**: Codex
**Date**: 2026-04-29

BLOCKING: [emacs-mcp-jsonrpc.el:38] parses JSON arrays as lists, but serialization only converts top-level batch lists to vectors. Nested arrays such as MCP `content` arrays fail to serialize with `wrong-type-argument symbolp`. This breaks later tool results unless every caller manually uses vectors.

BLOCKING: [emacs-mcp--jsonrpc-batch-p:47] detects batch status from element shape instead of preserving top-level JSON array identity. It misclassifies parsed `[{}]` as non-batch. The task requires detecting arrays vs single objects; this implementation cannot do that reliably.

WARNING: [request/notification predicates:61] use `alist-get` for `method`, so key presence is conflated with falsey parsed values like an empty array/object. The contract says "has `method`", so use key presence checks consistently.

NOTE: Existing 21 ERT tests pass. Byte-compilation is clean. The tests miss the failing nested-array and malformed-batch cases.

VERDICT: REVISE
