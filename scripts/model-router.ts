#!/usr/bin/env bun
/**
 * model-router.ts — Rule-based prompt complexity classifier
 *
 * Routes prompts to the best LOCAL model for the task:
 *   fast   → llama3.2:3b      (simple, short, informational — 2GB, instant)
 *   qwen   → Qwen3-Coder-30B  (code generation, refactoring, standard dev tasks)
 *   gemma  → gemma4:26b       (hard reasoning, architecture, design — already loaded 24/7 for trading bots)
 *
 * Fully local, fully free. No cloud API calls.
 * gemma4 is always in RAM (Kalshi trading bots keep it warm) so routing to it costs 0 extra RAM.
 *
 * Usage:
 *   echo "what's my git status" | bun run scripts/model-router.ts
 *   # → fast
 */

export type ModelTier = "fast" | "qwen" | "gemma";

// ---------------------------------------------------------------------------
// Keyword sets
// ---------------------------------------------------------------------------

const FAST_KEYWORDS = [
  "status",
  "list",
  "show",
  "what is",
  "what's",
  "whats",
  "help",
  "version",
  "count",
  "summarize",
  "ls",
  "pwd",
  "whoami",
  "which",
  "where",
  "how many",
  "tell me",
  "describe",
  "check",
  "ping",
  "echo",
  "print",
  "log",
  "cat",
  "diff",
  "blame",
  "history",
  "lookup",
  "find file",
  "search for",
];

const CODE_GEN_KEYWORDS = [
  "implement",
  "refactor",
  "add feature",
  "write test",
  "write a test",
  "fix bug",
  "fix the bug",
  "create",
  "build",
  "update",
  "modify",
  "add a",
  "add an",
  "add the",
  "change",
  "convert",
  "generate",
  "scaffold",
  "hook up",
  "wire up",
  "set up",
  "setup",
  "configure",
  "endpoint",
  "handler",
  "middleware",
  "component",
  "function",
  "class",
  "module",
  "route",
  "api",
  "crud",
  "database",
  "schema",
  "migration",
  "deploy",
  "dockerfile",
  "ci/cd",
  "pipeline",
  "lint",
  "format",
  "optimize",
  "debug",
  "logging",
  "error handling",
  "validation",
  "parse",
  "serialize",
  "deserialize",
];

const COMPLEXITY_KEYWORDS = [
  "design",
  "architect",
  "distributed",
  "consensus",
  "security audit",
  "review",
  "explain why",
  "tradeoff",
  "trade-off",
  "tradeoffs",
  "trade-offs",
  "migrate",
  "migration strategy",
  "microservice",
  "microservices",
  "system design",
  "scalab",
  "fault toleran",
  "high availability",
  "load balanc",
  "event sourcing",
  "cqrs",
  "saga pattern",
  "exactly-once",
  "at-least-once",
  "idempoten",
  "race condition",
  "deadlock",
  "consistency model",
  "cap theorem",
  "partition",
  "replication",
  "sharding",
  "orchestrat",
  "choreograph",
  "backpressure",
  "circuit breaker",
  "evaluate",
  "compare and contrast",
  "pros and cons",
  "vulnerabilit",
  "attack surface",
  "threat model",
  "compliance",
];

const MULTI_FILE_PATTERN = /across\s+\d+\s+files?|across\s+all\s+\d+|all\s+\d+\s+(files?|services?|modules?|handlers?|routes?|microservices?)/i;

// ---------------------------------------------------------------------------
// Classifier
// ---------------------------------------------------------------------------

export function classifyPrompt(prompt: string): ModelTier {
  const trimmed = prompt.trim();

  // Empty prompt → interactive session default
  if (!trimmed) return "qwen";

  const lower = trimmed.toLowerCase();
  const wordCount = trimmed.split(/\s+/).length;

  // Score each tier
  const hasComplexityKeyword = COMPLEXITY_KEYWORDS.some((kw) => lower.includes(kw));
  const hasMultiFileSignal = MULTI_FILE_PATTERN.test(lower);
  const hasCodeGenKeyword = CODE_GEN_KEYWORDS.some((kw) => lower.includes(kw));
  const hasFastKeyword = FAST_KEYWORDS.some((kw) => lower.includes(kw));

  // --- Gemma tier (hard reasoning) ---
  // gemma4:26b is always loaded (Kalshi trading bots keep it warm 24/7).
  // Route architecture, design, security, and multi-file reasoning here — 0 extra RAM.
  if (hasComplexityKeyword || hasMultiFileSignal) {
    if (wordCount < 10 && !hasMultiFileSignal && !hasCodeGenKeyword) {
      // Short prompt with a single complexity keyword like "review" — qwen can handle it
      return "qwen";
    }
    return "gemma";
  }

  // Very long prompts with code-gen signals → gemma (needs deeper reasoning)
  if (wordCount > 200 && hasCodeGenKeyword) {
    return "gemma";
  }

  // --- Qwen tier (code generation) ---
  if (hasCodeGenKeyword) {
    return "qwen";
  }

  // Medium-length prompts without fast keywords → qwen (likely complex enough)
  if (wordCount >= 50 && !hasFastKeyword) {
    return "qwen";
  }

  // --- Fast tier ---
  if (hasFastKeyword && wordCount < 50) {
    return "fast";
  }

  // Short prompts without any signals → fast
  if (wordCount < 15) {
    return "fast";
  }

  // Default fallback for medium prompts
  return "qwen";
}

// ---------------------------------------------------------------------------
// CLI entry point — read from stdin
// ---------------------------------------------------------------------------

async function main() {
  const input = await Bun.stdin.text();
  const result = classifyPrompt(input);
  process.stdout.write(result + "\n");
  process.exit(0);
}

// Only run main when executed directly (not imported)
if (import.meta.main) {
  main();
}
