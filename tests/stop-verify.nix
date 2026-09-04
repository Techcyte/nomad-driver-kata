{ pkgs }:

pkgs.writeShellApplication {
  name = "kata-stop-verify";
  runtimeInputs = with pkgs; [
    containerd
    coreutils
    gnugrep
    jq
    nomad
    procps
    util-linux
  ];
  text = ''
    set -euo pipefail

    : "''${NOMAD_ADDR:?NOMAD_ADDR is required}"
    : "''${CONTAINERD_SOCK:?CONTAINERD_SOCK is required}"
    : "''${STOP_JOB:?STOP_JOB is required}"

    runtime_resources() {
      local alloc_id="$1"
      pgrep -af "$alloc_id" || true
      ctr -a "$CONTAINERD_SOCK" tasks list 2>/dev/null | grep "$alloc_id" || true
      findmnt -rn 2>/dev/null | grep '/run/kata' | grep "$alloc_id" || true
    }

    has_runtime_resources() {
      local alloc_id="$1"
      pgrep -f "$alloc_id" >/dev/null \
        || ctr -a "$CONTAINERD_SOCK" tasks list 2>/dev/null | grep -q "$alloc_id" \
        || findmnt -rn 2>/dev/null | grep '/run/kata' | grep -q "$alloc_id"
    }

    residual_resources() {
      local alloc_id="$1"
      runtime_resources "$alloc_id"
      ctr -a "$CONTAINERD_SOCK" containers list | grep "$alloc_id" || true
      ctr -a "$CONTAINERD_SOCK" snapshots list | grep "$alloc_id" || true
      find /run/kata /run/kata-containers -xdev -path "*$alloc_id*" -print 2>/dev/null || true
      find "/tmp/kata-driver/$alloc_id" -mindepth 1 -print 2>/dev/null || true
      findmnt -rn 2>/dev/null | grep "$alloc_id" || true
    }

    has_allocation_resources() {
      local alloc_id="$1"
      has_runtime_resources "$alloc_id" \
        || ctr -a "$CONTAINERD_SOCK" containers list | grep -q "$alloc_id" \
        || ctr -a "$CONTAINERD_SOCK" snapshots list | grep -q "$alloc_id" \
        || find /run/kata /run/kata-containers -xdev -path "*$alloc_id*" -print -quit 2>/dev/null | grep -q . \
        || find "/tmp/kata-driver/$alloc_id" -mindepth 1 -print -quit 2>/dev/null | grep -q . \
        || findmnt -rn 2>/dev/null | grep -q "$alloc_id"
    }

    if pgrep -af 'containerd-shim-kata|qemu-system-x86_64|virtiofsd' >/dev/null; then
      echo "[FAIL] fresh VM already contains Kata runtime processes"
      pgrep -af 'containerd-shim-kata|qemu-system-x86_64|virtiofsd' || true
      exit 1
    fi

    nomad job run -detach "$STOP_JOB"

    alloc_id=""
    ready=false
    for _ in $(seq 1 90); do
      alloc_id=$(nomad job status -json kata-stop 2>/dev/null | jq -r '.[0].Allocations[0].ID // ""' || true)
      if [ -n "$alloc_id" ]; then
        state=$(nomad alloc status -json "$alloc_id" 2>/dev/null | jq -r '.TaskStates.sleeper.State // "pending"' || true)
        if [ "$state" = "running" ] && nomad alloc logs "$alloc_id" sleeper 2>/dev/null | grep -q '^STOP_READY$'; then
          ready=true
          break
        fi
      fi
      sleep 1
    done

    if [ "$ready" != true ]; then
      echo "[FAIL] stop task never reached running readiness"
      [ -z "$alloc_id" ] || nomad alloc status "$alloc_id" || true
      exit 1
    fi
    echo "[OK] stop task reached running readiness"

    started_at=$(date +%s)
    nomad job stop -detach kata-stop >/dev/null

    state=running
    for _ in $(seq 1 30); do
      state=$(nomad alloc status -json "$alloc_id" 2>/dev/null | jq -r '.TaskStates.sleeper.State // "dead"' || echo dead)
      if [ "$state" = dead ] && ! has_runtime_resources "$alloc_id"; then
        break
      fi
      sleep 1
    done
    elapsed=$(( $(date +%s) - started_at ))

    exit_code=$(nomad alloc status -json "$alloc_id" 2>/dev/null \
      | jq -r '[.TaskStates.sleeper.Events[] | select(.Type == "Terminated")][-1].ExitCode // -1' \
      || echo -1)

    if [ "$state" != dead ] || [ "$elapsed" -gt 30 ] || has_runtime_resources "$alloc_id"; then
      echo "[FAIL] graceful stop result: state=$state exit=$exit_code elapsed=''${elapsed}s"
      runtime_resources "$alloc_id"
      exit 1
    fi
    if [ "$exit_code" = 255 ] || [ "$exit_code" = -1 ]; then
      echo "[FAIL] graceful stop produced invalid exit status $exit_code"
      exit 1
    fi
    echo "[OK] graceful stop completed: exit=$exit_code elapsed=''${elapsed}s"

    nomad job stop -purge -detach kata-stop >/dev/null
    for _ in $(seq 1 30); do
      if ! has_allocation_resources "$alloc_id"; then
        break
      fi
      sleep 1
    done
    if has_allocation_resources "$alloc_id"; then
      echo "[FAIL] delete left allocation-local resources"
      residual_resources "$alloc_id"
      exit 1
    fi
    echo "[OK] delete removed allocation-local resources"
  '';
}
