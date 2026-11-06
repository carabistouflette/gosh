#!/usr/bin/env bash
# GOSH Comprehensive Automated Test Suite
# Tests functionality of GOSH (Native Unix Shell in Goose)

set -e

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
GOSH=${GOSH-"$REPO_ROOT/bin/gosh"}

if [ ! -f "$GOSH" ]; then
    printf 'Error: GOSH binary is missing or not a regular file: %s\n' "$GOSH" >&2
    printf 'Build it with: goose build -o bin/gosh src/gosh.goose (from %s)\nOr set GOSH to an executable path.\n' "$REPO_ROOT" >&2
    exit 1
fi
if [ ! -x "$GOSH" ]; then
    printf 'Error: GOSH binary is not executable: %s\nCheck its permissions (chmod +x) or set GOSH to an executable path.\n' "$GOSH" >&2
    exit 1
fi

TEST_TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/gosh-tests.XXXXXXXX")
trap 'rm -rf -- "$TEST_TMP_DIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Expand these paths inside GOSH so filename characters stay literal.
export TMP_FILE="$TEST_TMP_DIR/output.txt"
export TMP_ERR="$TEST_TMP_DIR/error.txt"
PASSED=0
FAILED=0

run_test() {
    local test_name="$1"
    local cmd="$2"
    local expected="$3"

    local expected_status="${4:-0}"
    local actual actual_status
    if actual=$("$GOSH" -c "$cmd" 2>&1); then
        actual_status=0
    else
        actual_status=$?
    fi

    if [ "$actual" = "$expected" ] && [ "$actual_status" -eq "$expected_status" ]; then
        echo -e "\033[32m[PASS]\033[0m $test_name"
        PASSED=$((PASSED + 1))
    else
        echo -e "\033[31m[FAIL]\033[0m $test_name"
        echo "  Command:  $cmd"
        echo "  Expected: [$expected]"
        echo "  Actual:   [$actual]"
        echo "  Expected status: $expected_status"
        echo "  Actual status:   $actual_status"
        FAILED=$((FAILED + 1))
    fi
}

echo "================================================"
echo " Running GOSH Automated Test Suite"
echo " Target Binary: $GOSH"
echo "================================================"

# 1. Echo Builtin
run_test "echo simple" "echo hello world" "hello world"
run_test "echo -n flag" "echo -n foo && echo bar" "foobar"
run_test "echo -e escapes" "echo -e 'a\tb'" "a	b"

# 2. PWD and CD
run_test "pwd builtin" "pwd" "$(pwd)"
run_test "cd and oldpwd" "cd /tmp && pwd && cd - > /dev/null && pwd" "/tmp
$(pwd)"

# 3. Variables & Expansions
run_test "variable assignment" "x=123 && echo \$x" "123"
run_test "variable in double quotes" "x=world && echo \"hello \$x\"" "hello world"
run_test "variable in single quotes" "x=world && echo 'hello \$x'" "hello \$x"
run_test "default parameter expansion" "unset UNSET_V && echo \${UNSET_V:-fallback}" "fallback"
run_test "string length expansion" "MSG=hello && echo \${#MSG}" "5"
run_test "arithmetic expansion addition" "echo \$(( 10 + 32 ))" "42"
run_test "arithmetic precedence" "echo \$(( 2 + 3 * 4 ))" "14"
run_test "arithmetic parentheses" "echo \$(( (2 + 3) * 4 ))" "20"
run_test "special var status 0" "echo success && echo \$?" "success
0"
run_test "special var status error" "false || echo \$?" "1"
run_test "failed command status" "false" "" 1
run_test "explicit exit status" "exit 7" "" 7

# 4. Command Substitution
run_test "command substitution simple" "echo \$(echo nested)" "nested"
run_test "command substitution with pipe" "echo \$(echo hello | tr 'a-z' 'A-Z')" "HELLO"
run_test "backtick substitution" "echo \`echo backtick\`" "backtick"

# 5. Redirection
run_test "redirect stdout >" "echo line1 > \"\$TMP_FILE\" && cat \"\$TMP_FILE\"" "line1"
run_test "redirect append >>" "echo line2 >> \"\$TMP_FILE\" && cat \"\$TMP_FILE\"" "line1
line2"
run_test "redirect stdin <" "cat < \"\$TMP_FILE\"" "line1
line2"
run_test "redirect stderr 2>" "sh -c 'echo error >&2; exit 1' 2> \"\$TMP_ERR\" || cat \"\$TMP_ERR\"" "error"
run_test "redirect 2>&1" "sh -c 'echo error >&2; exit 1' 2>&1 | grep error" "error"

# 6. Pipelines
run_test "two-stage pipeline" "echo -e 'banana\napple' | sort" "apple
banana"
run_test "three-stage pipeline" "echo -e '3\n1\n2' | sort | head -n 1" "1"
run_test "builtin in pipeline" "alias ll='ls -la' && alias | grep ll" "alias ll='ls -la'"
run_test "set in pipeline" "MYVAR=findme && set | grep MYVAR" "MYVAR=findme"

# 7. Subshells
run_test "subshell isolation" "(cd /tmp && pwd) && pwd" "/tmp
$(pwd)"
run_test "subshell redirection" "(echo sub1; echo sub2) > \"\$TMP_FILE\" && cat \"\$TMP_FILE\"" "sub1
sub2"

# 8. Conditionals (IF/THEN/ELSE/FI)
run_test "if true branch" "if test 1 -eq 1; then echo yes; else echo no; fi" "yes"
run_test "if false branch" "if test 1 -eq 2; then echo yes; else echo no; fi" "no"
run_test "if without else" "if test 'a' = 'a'; then echo matched; fi" "matched"

# 9. Loops (WHILE and FOR)
run_test "for loop" "for i in alpha beta gamma; do echo \$i; done" "alpha
beta
gamma"
run_test "while loop" "c=0; while test \$c -lt 3; do echo \$c; c=\$((c + 1)); done" "0
1
2"
run_test "for loop redirected" "for i in 1 2; do echo item_\$i; done > \"\$TMP_FILE\" && cat \"\$TMP_FILE\"" "item_1
item_2"

# Compound redirections must preserve shell state and restore descriptors.
run_test "redirected for preserves state" 'x=before; for i in one; do x=after; done > /dev/null; echo "$x"; echo "$i"' "after
one"
run_test "redirected if preserves state" 'x=before; if test 1 -eq 1; then x=after; echo hidden; fi > /dev/null; echo "$x"' "after"
run_test "redirected else preserves state" 'x=before; if test 1 -eq 2; then x=wrong; else x=after; fi > /dev/null; echo "$x"' "after"
run_test "redirected while preserves state" 'c=0; while test $c -lt 2; do c=$((c + 1)); echo hidden; done > /dev/null; echo "$c"' "2"
run_test "compound restores stdout after body failure" 'if test 1 -eq 1; then test 1 -eq 2; fi > /dev/null; echo "$?"; echo visible' "1
visible"
run_test "redirected subshell still isolates state" 'x=before; (x=after; echo hidden) > /dev/null; echo "$x"' "before"

# A file cannot be traversed as a directory: deterministic failing paths.
echo fixture > "$TMP_FILE"
run_test "for redirect failure skips body and restores stdout" "x=before; for i in one; do x=after; done > /dev/null < $TMP_FILE/missing; echo \$?; echo \$x" "1
before"
run_test "if redirect failure skips condition and body" "x=before; if x=condition; then x=after; fi > /dev/null < $TMP_FILE/missing; echo \$?; echo \$x" "1
before"
run_test "while redirect failure skips condition and body" "x=before; while x=condition; test 1 -eq 2; do x=after; done > /dev/null < $TMP_FILE/missing; echo \$?; echo \$x" "1
before"
run_test "compound output open failure" "x=before; for i in one; do x=after; done > /dev/null > $TMP_FILE/missing; echo \$?; echo \$x" "1
before"
run_test "compound restores stderr after partial failure" "for i in one; do echo wrong; done > /dev/null 2> $TMP_ERR < $TMP_FILE/missing; echo \$?; sh -c 'echo restored >&2'" "1
restored"
rm -f "$TMP_FILE" "$TMP_ERR"

# 10. Functions and Aliases
run_test "shell function" "greet() { echo \"Hello, \$1!\"; }; greet Gosh" "Hello, Gosh!"
run_test "alias expansion" "alias hi='echo welcome' && hi" "welcome"
run_test "unalias builtin" "alias foo='echo 1' && unalias foo && alias | grep foo || echo unset_ok" "unset_ok"

# 11. Builtins (export, unset, printf, test)
run_test "export and read env" "export GOSH_TEST_ENV=42 && echo \$GOSH_TEST_ENV" "42"
run_test "unset variable" "VAR=10 && unset VAR && echo \"[\$VAR]\"" "[]"
run_test "printf builtin" "printf 'num:%d str:%s\n' 42 'awesome'" "num:42 str:awesome"
run_test "test builtin operators" "if [ 10 -gt 5 ]; then echo gt; fi" "gt"

# 12. Background Jobs
run_test "background job" "sleep 0.1 & jobs | grep -o 'sleep'" "sleep"

# Startup modes require isolated HOME directories and pseudo-terminals.
if GOSH="$GOSH" python3 "$REPO_ROOT/test/test_startup.py"; then
    PASSED=$((PASSED + 1))
else
    FAILED=$((FAILED + 1))
fi

# Summary
echo "================================================"
echo " Test Suite Finished"
echo " Passed: $PASSED"
echo " Failed: $FAILED"
echo "================================================"

if [ "$FAILED" -eq 0 ]; then
    echo -e "\033[32mALL TESTS PASSED SUCCESSFULLY!\033[0m"
    exit 0
else
    echo -e "\033[31mSOME TESTS FAILED!\033[0m"
    exit 1
fi
