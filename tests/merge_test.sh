#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

stub_dir=$(mktemp -d)
trap 'rm -rf "$stub_dir"' EXIT

config_dir="$stub_dir/config"
mkdir -p "$config_dir"

# Stand in for `wt`: list answers with one mergeable worktree, and merge/remove
# record their argv and fail when the test asks them to.
cat > "$stub_dir/wt" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WT_STUB_LOG"
case "$1" in
  list)
    printf '%s' '[
      {"branch":"main","kind":"worktree","path":"/repo","is_main":true},
      {"branch":"feature","kind":"worktree","path":"/repo.feature","is_main":false}
    ]'
    ;;
  merge)  exit "${WT_STUB_MERGE_STATUS:-0}" ;;
  remove) exit "${WT_STUB_REMOVE_STATUS:-0}" ;;
esac
EOF

# The selected branch's oldest reflog records its creation base. The git stub also
# controls whether that base still exists as a local branch.
cat > "$stub_dir/git" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GIT_STUB_LOG"
case $* in
  '-C /repo.feature reflog show --format=%gs refs/heads/feature')
    printf '%s\n' "${GIT_STUB_REFLOG:-branch: Created from parent/feature}"
    ;;
  '-C /repo.feature show-ref --verify --quiet refs/heads/'*)
    exit "${GIT_STUB_BASE_STATUS:-0}"
    ;;
  *)
    printf 'unexpected git call: %s\n' "$*" >&2
    exit 2
    ;;
esac
EOF

# fzf picks the only candidate; the picker's stdin has to be drained either way.
cat > "$stub_dir/fzf" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' "${FZF_STUB_PICK-feature}"
EOF

cat > "$stub_dir/herdr" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "worktree list")
    printf '%s' '{"result":{"worktrees":[{"path":"/repo.feature","open_workspace_id":"ws-feature"}]}}'
    ;;
  *) printf '%s\n' "$*" | tee -a "$HERDR_STUB_LOG" ;;
esac
EOF
chmod +x "$stub_dir"/wt "$stub_dir"/git "$stub_dir"/fzf "$stub_dir"/herdr

export PATH="$stub_dir:$PATH"
export WT_STUB_LOG="$stub_dir/wt.log"
export GIT_STUB_LOG="$stub_dir/git.log"
export GIT_STUB_REFLOG=$'commit: task work\nbranch: Created from parent/feature'
export GIT_STUB_BASE_STATUS=0
export HERDR_STUB_LOG="$stub_dir/herdr.log"
pane_out="$stub_dir/pane.out"

# Run merge.sh with the given argv and the config already in place, then expose
# what wt and herdr were asked to do and what the pane showed. The herdr stub
# echoes its calls into the pane too, so a message can be placed before or after
# them. With stdin at /dev/null a "press any key" read returns at once.
run_merge() {
  : > "$WT_STUB_LOG"
  : > "$GIT_STUB_LOG"
  : > "$HERDR_STUB_LOG"
  HERDR_PLUGIN_ROOT="$repo_root" \
  HERDR_BIN_PATH="$stub_dir/herdr" \
  HERDR_PLUGIN_CONFIG_DIR="$config_dir" \
    bash "$repo_root/merge.sh" "$@" </dev/null >"$pane_out" 2>&1
}

assert_log() {
  local label=$1 expected=$2 log=$3
  if ! grep -qxF -- "$expected" "$log"; then
    printf 'expected %s call %q, got:\n%s\n' "$label" "$expected" "$(cat "$log")" >&2
    exit 1
  fi
}

# Matches on the start of a recorded argv, so refuting `remove` can't trip over
# the `--no-remove` flag the merge call carries.
refute_log() {
  local label=$1 unexpected=$2 log=$3
  if grep -q -- "^$unexpected" "$log"; then
    printf 'unexpected %s call %q in:\n%s\n' "$label" "$unexpected" "$(cat "$log")" >&2
    exit 1
  fi
}

# Match an extended regex against the pane output flattened to one line, so a
# pattern can span the order things were shown in.
assert_pane() {
  local pattern=$1
  if ! tr '\n' ' ' < "$pane_out" | grep -qE -- "$pattern"; then
    printf 'expected pane output matching %q, got:\n%s\n' "$pattern" "$(cat "$pane_out")" >&2
    exit 1
  fi
}

refute_pane() {
  local pattern=$1
  if tr '\n' ' ' < "$pane_out" | grep -qE -- "$pattern"; then
    printf 'unexpected pane output matching %q in:\n%s\n' "$pattern" "$(cat "$pane_out")" >&2
    exit 1
  fi
}

# Default action: recover the picked branch's creation base, require it to remain
# a local branch, merge into that explicit target, then remove in the foreground.
# Removal runs from the main worktree so worktrunk has no directory-change warning.
: > "$config_dir/config.toml"
run_merge
assert_log git '-C /repo.feature reflog show --format=%gs refs/heads/feature' "$GIT_STUB_LOG"
assert_log git '-C /repo.feature show-ref --verify --quiet refs/heads/parent/feature' "$GIT_STUB_LOG"
assert_log wt 'merge --no-remove -C /repo.feature parent/feature' "$WT_STUB_LOG"
assert_log wt 'remove --foreground -C /repo feature' "$WT_STUB_LOG"
assert_log herdr 'workspace close ws-feature' "$HERDR_STUB_LOG"
refute_pane 'press any key to continue'

# The no-squash variant adds its flag; config flags come along too, once each.
printf 'merge_flags = "--no-rebase"\n' > "$config_dir/config.toml"
run_merge --no-squash
assert_log wt 'merge --no-remove -C /repo.feature --no-rebase --no-squash parent/feature' "$WT_STUB_LOG"

printf 'merge_flags = "--no-squash"\n' > "$config_dir/config.toml"
run_merge --no-squash
assert_log wt 'merge --no-remove -C /repo.feature --no-squash parent/feature' "$WT_STUB_LOG"

# An unsupported option is a plugin bug, not a merge to attempt.
: > "$config_dir/config.toml"
if run_merge --no-such-flag; then
  printf 'expected merge.sh to reject an unsupported option\n' >&2
  exit 1
fi
refute_log wt 'merge' "$WT_STUB_LOG"

# Cancelling the picker touches nothing.
FZF_STUB_PICK="" run_merge
refute_log wt 'merge' "$WT_STUB_LOG"
refute_log herdr 'workspace close' "$HERDR_STUB_LOG"

# A branch whose creation base can't be recovered is never merged or removed.
GIT_STUB_REFLOG='commit: task work' run_merge
assert_pane 'cannot determine creation base for feature.*press any key to close'
refute_log wt 'merge' "$WT_STUB_LOG"
refute_log wt 'remove' "$WT_STUB_LOG"
refute_log herdr 'workspace close' "$HERDR_STUB_LOG"

# A recorded base that no longer exists locally also fails without falling back to
# the default branch (or accepting a similarly named remote-tracking ref).
GIT_STUB_BASE_STATUS=1 run_merge
assert_pane 'base branch parent/feature for feature no longer exists locally.*press any key to close'
refute_log wt 'merge' "$WT_STUB_LOG"
refute_log wt 'remove' "$WT_STUB_LOG"
refute_log herdr 'workspace close' "$HERDR_STUB_LOG"

# A failed merge leaves the worktree and its workspace alone.
WT_STUB_MERGE_STATUS=1 run_merge
refute_log wt 'remove' "$WT_STUB_LOG"
refute_log herdr 'workspace close' "$HERDR_STUB_LOG"

# A merge that landed but a removal that didn't keeps the workspace open — it still
# holds the worktree.
WT_STUB_REMOVE_STATUS=1 run_merge
assert_log wt 'remove --foreground -C /repo feature' "$WT_STUB_LOG"
refute_log herdr 'workspace close' "$HERDR_STUB_LOG"

# hold_on_merge keeps the pane up after a successful merge, and asks for the key
# before the workspace closes: in a split the pane can sit in that workspace.
printf 'hold_on_merge = true\n' > "$config_dir/config.toml"
run_merge
assert_pane 'merged feature into parent/feature and removed the worktree\..*press any key to continue.*workspace close ws-feature'
assert_log herdr 'workspace close ws-feature' "$HERDR_STUB_LOG"

# hold_on_success covers the merge as well, unless hold_on_merge says otherwise.
printf 'hold_on_success = true\n' > "$config_dir/config.toml"
run_merge
assert_pane 'merged feature into parent/feature and removed the worktree\.'

printf 'hold_on_success = true\nhold_on_merge = false\n' > "$config_dir/config.toml"
run_merge
refute_pane 'press any key to continue'
assert_log herdr 'workspace close ws-feature' "$HERDR_STUB_LOG"

# A failure keeps its own message whatever the hold settings say.
printf 'hold_on_success = true\n' > "$config_dir/config.toml"
WT_STUB_MERGE_STATUS=1 run_merge
assert_pane 'wt merge failed \(see above\)\.'
refute_pane 'merged feature'
refute_log herdr 'workspace close' "$HERDR_STUB_LOG"

printf 'merge tests passed\n'
