#!/usr/bin/env bash
# model-router-test.sh — Smoke tests for the prompt complexity router
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUTER="$SCRIPT_DIR/model-router.ts"

PASS=0
FAIL=0
TOTAL=0

GREEN='\033[0;32m'
RED='\033[0;31m'
BOLD='\033[1m'
RESET='\033[0m'

assert_route() {
  local expected="$1"
  local prompt="$2"
  TOTAL=$((TOTAL + 1))

  local actual
  actual=$(echo "$prompt" | bun run "$ROUTER" 2>/dev/null | tr -d '[:space:]')

  if [[ "$actual" == "$expected" ]]; then
    PASS=$((PASS + 1))
    printf "${GREEN}  PASS${RESET} [%s] %s\n" "$expected" "$prompt"
  else
    FAIL=$((FAIL + 1))
    printf "${RED}  FAIL${RESET} expected=%s actual=%s — %s\n" "$expected" "$actual" "$prompt"
  fi
}

echo ""
printf "${BOLD}Model Router Tests${RESET}\n"
echo "─────────────────────────────────────────────────────"

# ── Fast tier ──────────────────────────────────────────────
echo ""
printf "${BOLD}Fast tier (llama3.2:3b)${RESET}\n"
assert_route "fast" "what is my git status"
assert_route "fast" "list all files in src/"
assert_route "fast" "show me the last 5 commits"
assert_route "fast" "what's the current branch"
assert_route "fast" "help"
assert_route "fast" "version"
assert_route "fast" "count lines in main.ts"
assert_route "fast" "hello"

# ── Qwen tier ─────────────────────────────────────────────
echo ""
printf "${BOLD}Qwen tier (Qwen3-Coder-30B)${RESET}\n"
assert_route "qwen" "add a health check endpoint to the Express server"
assert_route "qwen" "fix the bug in auth.ts where tokens expire early"
assert_route "qwen" "refactor the auth module"
assert_route "qwen" "write a test for the user registration flow"
assert_route "qwen" "implement pagination for the /api/users endpoint"
assert_route "qwen" "create a new React component for the dashboard sidebar"
assert_route "qwen" "update the database schema to add a created_at column"
assert_route "qwen" ""

# ── Claude tier ────────────────────────────────────────────
echo ""
printf "${BOLD}Claude tier (Claude API)${RESET}\n"
assert_route "claude" "design a migration strategy from MongoDB to PostgreSQL across all 15 microservices"
assert_route "claude" "review this PR for security vulnerabilities and explain the tradeoffs of each finding"
assert_route "claude" "design a distributed system for handling 10M events/sec with exactly-once semantics"
assert_route "claude" "architect a microservice mesh with circuit breakers and graceful degradation"
assert_route "claude" "explain why the current auth implementation has race conditions and design a fix that handles all edge cases across 8 files"

# ── Summary ────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────────────────"
if [[ "$FAIL" -eq 0 ]]; then
  printf "${GREEN}${BOLD}All %d tests passed${RESET}\n" "$TOTAL"
  exit 0
else
  printf "${RED}${BOLD}%d/%d tests failed${RESET}\n" "$FAIL" "$TOTAL"
  exit 1
fi
