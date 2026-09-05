# Environment-agnostic assertion body shared by both the sudo-based integration
# script (tests/integration.nix) and the NixOS VM test (tests/integration-vm.nix).
#
# This is the part of the integration test that does NOT care how containerd and
# Nomad were started. It talks to Nomad over $NOMAD_ADDR and to containerd over
# $CONTAINERD_SOCK, submits the shared jobs, and asserts driver behaviour.
#
# Required environment at call time:
#   NOMAD_ADDR       - http address of the Nomad agent (e.g. http://127.0.0.1:14646)
#   CONTAINERD_SOCK  - path to the containerd socket
#   SINGLE_JOB       - path to the single-VM job HCL   (tests/jobs.nix .single)
#   MULTI_VM_JOB     - path to the multi-VM job HCL     (tests/jobs.nix .multiVm)
#   EXIT_IO_JOB      - path to the exit/stdio job HCL   (tests/jobs.nix .exitIo)
#   STOP_JOB         - path to the forced-stop job HCL  (tests/jobs.nix .stop)
#   LIFECYCLE_JOB    - path to the cleanup loop job HCL (tests/jobs.nix .lifecycle)
# Optional:
#   NOMAD_LOG        - path to a Nomad log file for failure diagnostics; when
#                      unset (e.g. journald-based VM), log tails are skipped.
#   RESTART_NOMAD    - command that restarts Nomad and waits until it is ready.
{
  pkgs,
  restartTask ? true,
}:
pkgs.writeShellScript "kata-verify" ''
  set -euo pipefail

  export PATH="${
    pkgs.lib.makeBinPath [
      pkgs.nomad
      pkgs.containerd
      pkgs.jq
      pkgs.curl
    ]
  }:$PATH"

  : "''${NOMAD_ADDR:?NOMAD_ADDR must be set}"
  : "''${CONTAINERD_SOCK:?CONTAINERD_SOCK must be set}"
  : "''${SINGLE_JOB:?SINGLE_JOB must be set}"
  : "''${MULTI_VM_JOB:?MULTI_VM_JOB must be set}"
  : "''${EXIT_IO_JOB:?EXIT_IO_JOB must be set}"
  : "''${STOP_JOB:?STOP_JOB must be set}"
  : "''${LIFECYCLE_JOB:?LIFECYCLE_JOB must be set}"
  export NOMAD_ADDR

  # Optional environment-specific hooks.
  NOMAD_LOG="''${NOMAD_LOG:-}"
  RESTART_NOMAD="''${RESTART_NOMAD:-}"
  log_tail() {
    # $1 = number of lines. No-op when NOMAD_LOG is unset or missing.
    if [ -n "$NOMAD_LOG" ] && [ -f "$NOMAD_LOG" ]; then
      tail -"$1" "$NOMAD_LOG" 2>/dev/null || true
    fi
  }

  # Check driver is detected
  echo ""
  echo "=== Checking driver fingerprint ==="
  sleep 5
  DRIVER_STATUS=$(nomad node status -address="$NOMAD_ADDR" -self -json 2>/dev/null | jq -r '.Drivers.kata.Detected // false')
  if [ "$DRIVER_STATUS" = "true" ]; then
    echo "[OK] kata driver detected"
  else
    echo "[FAIL] kata driver not detected"
    nomad node status -self -json | jq '.Drivers' 2>/dev/null || true
    log_tail 30
    exit 1
  fi

  echo ""
  echo "=== Verifying images in containerd ==="
  ctr -a "$CONTAINERD_SOCK" image ls -q
  echo "[OK] images listed"

  # Submit test job
  echo ""
  echo "=== Submitting test job ==="
  nomad job run "$SINGLE_JOB"

  # Wait for allocation
  echo "Waiting for allocation..."
  for i in $(seq 1 60); do
    ALLOC_STATUS=$(nomad job status -json kata-driver-test 2>/dev/null | jq -r '.[0].Allocations[0].ClientStatus // "pending"')
    if [ "$ALLOC_STATUS" = "running" ] || [ "$ALLOC_STATUS" = "complete" ]; then
      break
    fi
    sleep 2
  done

  ALLOC_ID=$(nomad job status -json kata-driver-test | jq -r '.[0].Allocations[0].ID')
  echo "Allocation: $ALLOC_ID (status: $ALLOC_STATUS)"

  if [ "$ALLOC_STATUS" != "running" ] && [ "$ALLOC_STATUS" != "complete" ]; then
    echo "[FAIL] allocation did not reach running state"
    nomad alloc status "$ALLOC_ID" 2>/dev/null || true
    echo "--- nomad log tail ---"
    log_tail 100
    exit 1
  fi

  # Check task logs (retry — logs may take a moment to appear)
  echo ""
  echo "=== Task logs ==="
  echo "--- hello ---"
  HELLO_LOGS=""
  for i in $(seq 1 15); do
    HELLO_LOGS=$(nomad alloc logs "$ALLOC_ID" hello 2>/dev/null || echo "")
    if echo "$HELLO_LOGS" | grep -q "KATA_DRIVER_OK"; then
      break
    fi
    sleep 2
  done
  echo "$HELLO_LOGS"
  if echo "$HELLO_LOGS" | grep -q "KATA_DRIVER_OK"; then
    echo "[OK] hello task produced expected output"
  else
    echo "[FAIL] hello task missing KATA_DRIVER_OK in logs"
    nomad alloc status "$ALLOC_ID" 2>/dev/null || true
    exit 1
  fi

  echo ""
  echo "--- sidecar ---"
  SIDECAR_LOGS=""
  for i in $(seq 1 15); do
    SIDECAR_LOGS=$(nomad alloc logs "$ALLOC_ID" sidecar 2>/dev/null || echo "")
    if echo "$SIDECAR_LOGS" | grep -q "SIDECAR_OK"; then
      break
    fi
    sleep 2
  done
  echo "$SIDECAR_LOGS"
  if echo "$SIDECAR_LOGS" | grep -q "SIDECAR_OK"; then
    echo "[OK] sidecar task produced expected output"
  else
    echo "[FAIL] sidecar task missing SIDECAR_OK in logs"
    nomad alloc status "$ALLOC_ID" 2>/dev/null || true
    exit 1
  fi

  # Exec into container
  echo ""
  echo "=== Exec verification ==="
  EXEC_HOSTNAME=$(nomad alloc exec -i=false -t=false -task hello "$ALLOC_ID" /bin/hostname 2>/dev/null || echo "")
  echo "Hostname from exec: $EXEC_HOSTNAME"
  if [ "$EXEC_HOSTNAME" = "test" ]; then
    echo "[OK] sandbox hostname inherited (group name 'test')"
  else
    echo "[FAIL] expected sandbox hostname 'test', got '$EXEC_HOSTNAME'"
    exit 1
  fi

  EXEC_HOSTS=$(nomad alloc exec -i=false -t=false -task hello "$ALLOC_ID" /bin/cat /etc/hosts 2>/dev/null || echo "")
  echo "Hosts file:"
  echo "$EXEC_HOSTS"
  if echo "$EXEC_HOSTS" | grep -q "mydb" && echo "$EXEC_HOSTS" | grep -q "cache"; then
    echo "[OK] extra_hosts entries present"
  else
    echo "[FAIL] extra_hosts entries missing from /etc/hosts"
    exit 1
  fi

  echo ""
  echo "=== Streaming exec verification ==="
  STREAM_STDOUT=$(printf 'STREAM_INPUT\n' | nomad alloc exec -i=true -t=false -task hello "$ALLOC_ID" /bin/sh -c 'read value; echo "OUT:$value"; echo "ERR:$value" >&2; exit 23' 2>"/tmp/kata-stream-stderr"; printf ':%s' "$?")
  STREAM_STATUS="''${STREAM_STDOUT##*:}"
  STREAM_STDOUT="''${STREAM_STDOUT%:*}"
  STREAM_STDERR=$(cat /tmp/kata-stream-stderr)
  rm -f /tmp/kata-stream-stderr
  if printf '%s' "$STREAM_STDOUT" | grep -qx 'OUT:STREAM_INPUT' \
    && printf '%s' "$STREAM_STDERR" | grep -qx 'ERR:STREAM_INPUT' \
    && [ "$STREAM_STATUS" = "23" ]; then
    echo "[OK] streaming exec preserved stdin, stdout, stderr, and exit status"
  else
    echo "[FAIL] streaming exec result: stdout='$STREAM_STDOUT' stderr='$STREAM_STDERR' status='$STREAM_STATUS'"
    exit 1
  fi

  echo ""
  echo "=== Exec output drain verification ==="
  seq 1 65536 > /tmp/kata-exec-expected
  DRAIN_STATUS=0
  nomad alloc exec -i=false -t=false -task hello "$ALLOC_ID" /bin/sh -c 'seq 1 65536; seq 1 65536 >&2; exit 42' >/tmp/kata-exec-stdout 2>/tmp/kata-exec-stderr || DRAIN_STATUS=$?
  if [ "$DRAIN_STATUS" -ne 42 ] \
    || ! cmp /tmp/kata-exec-expected /tmp/kata-exec-stdout \
    || ! cmp /tmp/kata-exec-expected /tmp/kata-exec-stderr; then
    echo "[FAIL] exec output drain: status=$DRAIN_STATUS"
    wc -l /tmp/kata-exec-expected /tmp/kata-exec-stdout /tmp/kata-exec-stderr
    exit 1
  fi
  echo "[OK] exec drained 65536 lines on each stream with exit 42"

  if [ -n "$RESTART_NOMAD" ]; then
    echo ""
    echo "=== Driver restart recovery verification ==="
    eval "$RESTART_NOMAD"
    for i in $(seq 1 30); do
      RECOVERY_EXEC=$(nomad alloc exec -i=false -t=false -task hello "$ALLOC_ID" /bin/echo RECOVERY_OK 2>/dev/null || echo "")
      if [ "$RECOVERY_EXEC" = "RECOVERY_OK" ]; then
        break
      fi
      sleep 2
    done
    if [ "$RECOVERY_EXEC" = "RECOVERY_OK" ]; then
      echo "[OK] running Kata task recovered after driver restart"
    else
      echo "[FAIL] running Kata task did not recover after driver restart"
      nomad alloc status "$ALLOC_ID" 2>/dev/null || true
      exit 1
    fi
  fi

  # Signal test
  echo ""
  echo "=== Signal verification ==="
  nomad alloc signal -s SIGCONT -task sidecar "$ALLOC_ID" 2>/dev/null || {
    echo "[FAIL] nomad alloc signal failed"
    exit 1
  }
  sleep 1
  SIDECAR_STATE=$(nomad alloc status -json "$ALLOC_ID" | jq -r '.TaskStates.sidecar.State')
  if [ "$SIDECAR_STATE" = "running" ]; then
    echo "[OK] sidecar survived SIGCONT signal"
  else
    echo "[FAIL] sidecar state after signal: $SIDECAR_STATE"
    nomad alloc status "$ALLOC_ID" 2>/dev/null || true
    exit 1
  fi

  # Verify VM sharing via hostname — both tasks should see the sandbox hostname
  echo ""
  echo "=== VM sharing verification ==="
  SIDECAR_EXEC_STATUS=0
  SIDECAR_HOSTNAME=$(nomad alloc exec -i=false -t=false -task sidecar "$ALLOC_ID" /bin/hostname) || SIDECAR_EXEC_STATUS=$?
  echo "sidecar hostname exec status: $SIDECAR_EXEC_STATUS"
  echo "hello hostname:   $EXEC_HOSTNAME"
  echo "sidecar hostname: $SIDECAR_HOSTNAME"
  if [ "$SIDECAR_EXEC_STATUS" -eq 0 ] && [ "$EXEC_HOSTNAME" = "$SIDECAR_HOSTNAME" ]; then
    echo "[OK] both tasks share sandbox hostname — same Kata VM"
  else
    echo "[FAIL] hostname exec status/output mismatch"
    nomad alloc status "$ALLOC_ID" || true
    ctr -a "$CONTAINERD_SOCK" tasks list || true
    exit 1
  fi

  ${pkgs.lib.optionalString restartTask ''
    # Kill the main container with a failure exit while its sibling is running.
    # Nomad must restart only the failed task without disturbing the shared VM.
    echo ""
    echo "=== Container restart with live sibling verification ==="
    TASK_STATES_BEFORE=$(nomad alloc status -json "$ALLOC_ID" | jq '.TaskStates')
    HELLO_RESTARTS_BEFORE=$(echo "$TASK_STATES_BEFORE" | jq -r '.hello.Restarts')
    SIDECAR_RESTARTS_BEFORE=$(echo "$TASK_STATES_BEFORE" | jq -r '.sidecar.Restarts')
    SIDECAR_STARTED_AT_BEFORE=$(echo "$TASK_STATES_BEFORE" | jq -r '.sidecar.StartedAt')
    ctr -a "$CONTAINERD_SOCK" task kill --signal SIGKILL "kata-$ALLOC_ID-hello"

    RESTARTED=false
    for i in $(seq 1 30); do
      TASK_STATES_AFTER=$(nomad alloc status -json "$ALLOC_ID" | jq '.TaskStates')
      HELLO_STATE=$(echo "$TASK_STATES_AFTER" | jq -r '.hello.State')
      HELLO_RESTARTS_AFTER=$(echo "$TASK_STATES_AFTER" | jq -r '.hello.Restarts')
      TASK_RUNTIME_STATE=$(ctr -a "$CONTAINERD_SOCK" tasks list | awk -v id="kata-$ALLOC_ID-hello" '$1 == id { print $3 }')
      if [ "$HELLO_STATE" = "running" ] \
        && [ "$HELLO_RESTARTS_AFTER" -gt "$HELLO_RESTARTS_BEFORE" ] \
        && [ "$TASK_RUNTIME_STATE" = "RUNNING" ]; then
        RESTARTED=true
        break
      fi
      sleep 2
    done

    if [ "$RESTARTED" != "true" ]; then
      echo "[FAIL] hello container was not restarted: runtime_state=$TASK_RUNTIME_STATE"
      nomad alloc status "$ALLOC_ID" 2>/dev/null || true
      log_tail 100
      exit 1
    fi

    RESTART_EXEC=$(nomad alloc exec -i=false -t=false -task hello "$ALLOC_ID" /bin/echo RESTART_OK 2>/dev/null || echo "")
    if [ "$RESTART_EXEC" = "RESTART_OK" ]; then
      echo "[OK] failed hello container restarted and accepts exec"
    else
      echo "[FAIL] restarted hello container did not accept exec"
      nomad alloc status "$ALLOC_ID" 2>/dev/null || true
      exit 1
    fi

    SIDECAR_STATE=$(echo "$TASK_STATES_AFTER" | jq -r '.sidecar.State')
    SIDECAR_RESTARTS_AFTER=$(echo "$TASK_STATES_AFTER" | jq -r '.sidecar.Restarts')
    SIDECAR_STARTED_AT_AFTER=$(echo "$TASK_STATES_AFTER" | jq -r '.sidecar.StartedAt')
    SIDECAR_EXEC=$(nomad alloc exec -i=false -t=false -task sidecar "$ALLOC_ID" /bin/echo SIDECAR_STILL_RUNNING 2>/dev/null || echo "")
    if [ "$SIDECAR_STATE" = "running" ] \
      && [ "$SIDECAR_RESTARTS_AFTER" = "$SIDECAR_RESTARTS_BEFORE" ] \
      && [ "$SIDECAR_STARTED_AT_AFTER" = "$SIDECAR_STARTED_AT_BEFORE" ] \
      && [ "$SIDECAR_EXEC" = "SIDECAR_STILL_RUNNING" ]; then
      echo "[OK] sibling sidecar stayed running without restart"
    else
      echo "[FAIL] sibling sidecar was interrupted or restarted"
      nomad alloc status "$ALLOC_ID" 2>/dev/null || true
      exit 1
    fi

  ''}
  # Stop Phase 1 job and wait for its Kata VM before booting another sandbox.
  nomad job stop -purge -detach kata-driver-test >/dev/null 2>&1 || true
  for i in $(seq 1 45); do
    if ! pgrep -f "$ALLOC_ID" >/dev/null \
      && ! ctr -a "$CONTAINERD_SOCK" tasks list 2>/dev/null | grep -q "$ALLOC_ID"; then
      break
    fi
    sleep 1
  done
  if pgrep -f "$ALLOC_ID" >/dev/null \
    || ctr -a "$CONTAINERD_SOCK" tasks list 2>/dev/null | grep -q "$ALLOC_ID"; then
    echo "[FAIL] Phase 1 sandbox did not stop before focused lifecycle gates"
    pgrep -af "$ALLOC_ID" || true
    ctr -a "$CONTAINERD_SOCK" tasks list 2>/dev/null | grep "$ALLOC_ID" || true
    exit 1
  fi
  echo "[OK] Phase 1 sandbox runtime resources stopped"

  echo ""
  echo "=== Large stdio and exact exit status verification ==="
  nomad job run -detach "$EXIT_IO_JOB"
  EXIT_ALLOC=""
  EXIT_STATUS="pending"
  for i in $(seq 1 90); do
    EXIT_ALLOC=$(nomad job status -json kata-exit-io 2>/dev/null | jq -r '.[0].Allocations[0].ID // ""')
    if [ -n "$EXIT_ALLOC" ]; then
      EXIT_STATUS=$(nomad alloc status -json "$EXIT_ALLOC" 2>/dev/null | jq -r '.TaskStates.output.State // "pending"')
      if [ "$EXIT_STATUS" = "dead" ]; then
        break
      fi
    fi
    sleep 1
  done
  EXIT_CODE=$(nomad alloc status -json "$EXIT_ALLOC" | jq -r '[.TaskStates.output.Events[] | select(.Type == "Terminated")][-1].ExitCode // -1')
  STDOUT_COUNT=$(nomad alloc logs "$EXIT_ALLOC" output 2>/dev/null | grep -c '^STDOUT-' || true)
  STDERR_COUNT=$(nomad alloc logs -stderr "$EXIT_ALLOC" output 2>/dev/null | grep -c '^STDERR-' || true)
  if [ "$EXIT_STATUS" = "dead" ] \
    && [ "$EXIT_CODE" = "42" ] \
    && [ "$STDOUT_COUNT" = "4096" ] \
    && [ "$STDERR_COUNT" = "4096" ]; then
    echo "[OK] large stdout/stderr drained before exact exit status 42"
  else
    echo "[FAIL] exit/stdio result: state=$EXIT_STATUS code=$EXIT_CODE stdout=$STDOUT_COUNT stderr=$STDERR_COUNT"
    nomad alloc status "$EXIT_ALLOC" 2>/dev/null || true
    exit 1
  fi
  nomad job stop -purge -detach kata-exit-io >/dev/null
  for i in $(seq 1 30); do
    if ! pgrep -f "$EXIT_ALLOC" >/dev/null; then break; fi
    sleep 1
  done
  if pgrep -f "$EXIT_ALLOC" >/dev/null; then
    echo "[FAIL] exit/stdio sandbox resources leaked"
    pgrep -af "$EXIT_ALLOC" || true
    exit 1
  fi
  echo "[OK] exit/stdio sandbox cleaned"

  echo ""
  echo "=== Forced stop and bounded delete verification ==="
  nomad job run -detach "$STOP_JOB"
  STOP_ALLOC=""
  STOP_READY=false
  for i in $(seq 1 60); do
    STOP_ALLOC=$(nomad job status -json kata-stop 2>/dev/null | jq -r '.[0].Allocations[0].ID // ""' || true)
    if [ -n "$STOP_ALLOC" ]; then
      STOP_STATE=$(nomad alloc status -json "$STOP_ALLOC" 2>/dev/null | jq -r '.TaskStates.sleeper.State // "pending"' || true)
      if [ "$STOP_STATE" = "running" ] \
        && nomad alloc logs "$STOP_ALLOC" sleeper 2>/dev/null | grep -q '^STOP_READY$'; then
        STOP_READY=true
        break
      fi
    fi
    sleep 1
  done
  if [ "$STOP_READY" != "true" ]; then
    echo "[FAIL] stop task never reached running readiness"
    [ -z "$STOP_ALLOC" ] || nomad alloc status "$STOP_ALLOC" 2>/dev/null || true
    exit 1
  fi
  STOP_START=$(date +%s)
  nomad job stop -purge -detach kata-stop >/dev/null
  STOP_STATE="running"
  for i in $(seq 1 30); do
    STOP_STATE=$(nomad alloc status -json "$STOP_ALLOC" 2>/dev/null | jq -r '.TaskStates.sleeper.State // "dead"' || echo "dead")
    if [ "$STOP_STATE" = "dead" ] && ! pgrep -f "$STOP_ALLOC" >/dev/null; then break; fi
    sleep 1
  done
  STOP_ELAPSED=$(( $(date +%s) - STOP_START ))
  if [ "$STOP_STATE" = "dead" ] && [ "$STOP_ELAPSED" -le 30 ] && ! pgrep -f "$STOP_ALLOC" >/dev/null; then
    echo "[OK] forced stop and delete completed in ''${STOP_ELAPSED}s"
  else
    echo "[FAIL] forced stop/delete result: state=$STOP_STATE elapsed=''${STOP_ELAPSED}s"
    pgrep -af "$STOP_ALLOC" || true
    exit 1
  fi

  echo ""
  echo "=== Repeated lifecycle cleanup verification ==="
  for iteration in $(seq 1 10); do
    nomad job run -detach "$LIFECYCLE_JOB"
    LIFE_ALLOC=""
    LIFE_STATE="pending"
    for i in $(seq 1 60); do
      LIFE_ALLOC=$(nomad job status -json kata-lifecycle 2>/dev/null | jq -r '.[0].Allocations[0].ID // ""' || true)
      if [ -n "$LIFE_ALLOC" ]; then
        LIFE_STATE=$(nomad alloc status -json "$LIFE_ALLOC" 2>/dev/null | jq -r '.TaskStates.once.State // "pending"' || true)
        if [ "$LIFE_STATE" = "dead" ]; then break; fi
      fi
      sleep 1
    done
    LIFE_CODE=$(nomad alloc status -json "$LIFE_ALLOC" | jq -r '[.TaskStates.once.Events[] | select(.Type == "Terminated")][-1].ExitCode // -1')
    if [ "$LIFE_STATE" != "dead" ] || [ "$LIFE_CODE" != "0" ]; then
      echo "[FAIL] lifecycle iteration $iteration: state=$LIFE_STATE code=$LIFE_CODE"
      exit 1
    fi
    nomad job stop -purge -detach kata-lifecycle >/dev/null
    for i in $(seq 1 30); do
      if ! pgrep -f "$LIFE_ALLOC" >/dev/null; then break; fi
      sleep 1
    done
    if pgrep -f "$LIFE_ALLOC" >/dev/null; then
      echo "[FAIL] lifecycle iteration $iteration leaked sandbox resources"
      pgrep -af "$LIFE_ALLOC" || true
      exit 1
    fi
  done
  echo "[OK] 10 lifecycle iterations completed without allocation-local process leaks"

  echo ""
  echo "========================================="
  echo "=== Phase 2: Multi-VM Networking ==="
  echo "========================================="

  echo ""
  echo "=== Submitting multi-VM job ==="
  nomad job run -detach "$MULTI_VM_JOB"

  echo "Waiting for allocations..."
  SERVER_STATUS="pending"
  CLIENT_STATUS="pending"
  for i in $(seq 1 90); do
    if [ "$SERVER_STATUS" != "running" ]; then
      SERVER_STATUS=$(nomad job status -json kata-multi-vm 2>/dev/null | jq -r '[.[0].Allocations[] | select(.TaskGroup == "server")][0].ClientStatus // "pending"') || true
    fi
    if [ "$CLIENT_STATUS" != "running" ]; then
      CLIENT_STATUS=$(nomad job status -json kata-multi-vm 2>/dev/null | jq -r '[.[0].Allocations[] | select(.TaskGroup == "client")][0].ClientStatus // "pending"') || true
    fi
    if [ "$SERVER_STATUS" = "running" ] && [ "$CLIENT_STATUS" = "running" ]; then break; fi
    sleep 2
  done

  SERVER_ALLOC=$(nomad job status -json kata-multi-vm | jq -r '[.[0].Allocations[] | select(.TaskGroup == "server")][0].ID')
  CLIENT_ALLOC=$(nomad job status -json kata-multi-vm | jq -r '[.[0].Allocations[] | select(.TaskGroup == "client")][0].ID')
  echo "Server: $SERVER_ALLOC ($SERVER_STATUS)"
  echo "Client: $CLIENT_ALLOC ($CLIENT_STATUS)"
  if [ "$SERVER_STATUS" != "running" ]; then
    echo "[FAIL] server allocation not running (status: $SERVER_STATUS)"
    nomad alloc status "$SERVER_ALLOC" 2>/dev/null || true
    echo "--- nomad log tail ---"
    log_tail 50
    exit 1
  fi
  if [ "$CLIENT_STATUS" != "running" ]; then
    echo "[FAIL] client allocation not running (status: $CLIENT_STATUS)"
    nomad alloc status "$CLIENT_ALLOC" 2>/dev/null || true
    echo "--- nomad log tail ---"
    log_tail 50
    exit 1
  fi

  # VM isolation: different groups = different VMs
  echo ""
  echo "=== VM isolation ==="
  SERVER_HOSTNAME=$(nomad alloc exec -i=false -t=false -task web "$SERVER_ALLOC" /bin/hostname 2>/dev/null || echo "")
  CLIENT_HOSTNAME=$(nomad alloc exec -i=false -t=false -task fetcher "$CLIENT_ALLOC" /bin/hostname 2>/dev/null || echo "")
  echo "server VM: $SERVER_HOSTNAME"
  echo "client VM: $CLIENT_HOSTNAME"
  if [ -n "$SERVER_HOSTNAME" ] && [ -n "$CLIENT_HOSTNAME" ] && [ "$SERVER_HOSTNAME" != "$CLIENT_HOSTNAME" ]; then
    echo "[OK] different groups run in separate VMs"
  else
    echo "[FAIL] expected different hostnames for different VMs"
    exit 1
  fi

  # VM sharing: tasks within group share VM
  echo ""
  echo "=== Intra-group VM sharing ==="
  WEB_SIDECAR_HOSTNAME=$(nomad alloc exec -i=false -t=false -task web-sidecar "$SERVER_ALLOC" /bin/hostname 2>/dev/null || echo "")
  FETCHER_SIDECAR_HOSTNAME=$(nomad alloc exec -i=false -t=false -task fetcher-sidecar "$CLIENT_ALLOC" /bin/hostname 2>/dev/null || echo "")
  echo "web + web-sidecar:         $SERVER_HOSTNAME / $WEB_SIDECAR_HOSTNAME"
  echo "fetcher + fetcher-sidecar: $CLIENT_HOSTNAME / $FETCHER_SIDECAR_HOSTNAME"
  if [ "$SERVER_HOSTNAME" = "$WEB_SIDECAR_HOSTNAME" ] && [ "$CLIENT_HOSTNAME" = "$FETCHER_SIDECAR_HOSTNAME" ]; then
    echo "[OK] tasks within each group share a VM"
  else
    echo "[FAIL] tasks within a group have different hostnames"
    exit 1
  fi

  # Cross-VM networking
  echo ""
  echo "=== Cross-VM networking ==="
  SERVER_IP=$(nomad alloc exec -i=false -t=false -task web "$SERVER_ALLOC" /bin/ip addr 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*scope global.*/\1/p') || true
  echo "Server bridge IP: $SERVER_IP"

  if [ -z "$SERVER_IP" ] || [ "$SERVER_IP" = "null" ]; then
    echo "[FAIL] could not determine server bridge IP"
    nomad alloc status -json "$SERVER_ALLOC" | jq '.AllocatedResources.Shared' 2>/dev/null || true
    exit 1
  fi

  RESPONSE=""
  for i in $(seq 1 15); do
    RESPONSE=$(nomad alloc exec -i=false -t=false -task fetcher "$CLIENT_ALLOC" /bin/wget -q -O - "http://$SERVER_IP:8080/" 2>/dev/null || echo "")
    if echo "$RESPONSE" | grep -q "SERVER_OK"; then break; fi
    sleep 2
  done
  echo "Response: $RESPONSE"
  if echo "$RESPONSE" | grep -q "SERVER_OK"; then
    echo "[OK] cross-VM HTTP request succeeded via bridge"
  else
    echo "[FAIL] could not reach server from client VM"
    echo "--- diagnostics ---"
    echo "Server network:"
    nomad alloc exec -i=false -t=false -task web "$SERVER_ALLOC" /bin/ip addr 2>/dev/null || true
    echo "Client network:"
    nomad alloc exec -i=false -t=false -task fetcher "$CLIENT_ALLOC" /bin/ip addr 2>/dev/null || true
    nomad alloc exec -i=false -t=false -task fetcher "$CLIENT_ALLOC" /bin/ip route 2>/dev/null || true
    exit 1
  fi

  echo ""
  echo "=== Shared sandbox death cleanup and replacement ==="
  FAILED_ALLOC="$SERVER_ALLOC"
  FAILED_SANDBOX="kata-$FAILED_ALLOC-sandbox"
  HEALTHY_ALLOC="$CLIENT_ALLOC"
  HEALTHY_SANDBOX="kata-$HEALTHY_ALLOC-sandbox"

  FAILED_QEMU_PID=$(pgrep -f "qemu-system.*sandbox-$FAILED_SANDBOX" | head -1)
  FAILED_SHIM_PID=$(pgrep -f "containerd-shim-kata-v2.*-id $FAILED_SANDBOX" | head -1)
  HEALTHY_QEMU_PID=$(pgrep -f "qemu-system.*sandbox-$HEALTHY_SANDBOX" | head -1)
  HEALTHY_SHIM_PID=$(pgrep -f "containerd-shim-kata-v2.*-id $HEALTHY_SANDBOX" | head -1)

  if [ -z "$FAILED_QEMU_PID" ] || [ -z "$FAILED_SHIM_PID" ] || [ -z "$HEALTHY_QEMU_PID" ] || [ -z "$HEALTHY_SHIM_PID" ]; then
    echo "[FAIL] could not identify exact failed and healthy sandbox processes"
    pgrep -af 'qemu-system|containerd-shim-kata-v2|virtiofsd' || true
    exit 1
  fi

  # QEMU death leaves the shim alive long enough to exercise the driver's
  # confirmed-death cleanup path. The exact sandbox shim must then be reaped.
  kill -KILL "$FAILED_QEMU_PID"

  POISONED=false
  CLEANED=false
  for i in $(seq 1 60); do
    if [ -f "/tmp/kata-driver/$FAILED_ALLOC/sandbox-dead" ]; then
      POISONED=true
    fi
    if ! kill -0 "$FAILED_SHIM_PID" 2>/dev/null \
      && ! pgrep -f "sandbox-$FAILED_SANDBOX" >/dev/null \
      && ! pgrep -f "virtiofsd.*$FAILED_ALLOC" >/dev/null; then
      CLEANED=true
    fi
    if [ "$POISONED" = "true" ] && [ "$CLEANED" = "true" ]; then
      break
    fi
    sleep 1
  done

  if [ "$POISONED" != "true" ]; then
    echo "[FAIL] failed allocation was not poisoned after sandbox death"
    exit 1
  fi
  if [ "$CLEANED" != "true" ]; then
    echo "[FAIL] exact dead sandbox processes were not cleaned"
    pgrep -af "$FAILED_ALLOC" || true
    exit 1
  fi
  echo "[OK] exact QEMU, virtiofsd, and Kata shim processes were cleaned"

  if ! kill -0 "$HEALTHY_QEMU_PID" 2>/dev/null || ! kill -0 "$HEALTHY_SHIM_PID" 2>/dev/null; then
    echo "[FAIL] unrelated Kata sandbox processes were killed"
    exit 1
  fi
  HEALTHY_EXEC=$(nomad alloc exec -i=false -t=false -task fetcher "$HEALTHY_ALLOC" /bin/echo HEALTHY_SANDBOX_OK 2>/dev/null || echo "")
  if [ "$HEALTHY_EXEC" != "HEALTHY_SANDBOX_OK" ]; then
    echo "[FAIL] unrelated Kata allocation stopped accepting exec"
    exit 1
  fi
  echo "[OK] unrelated Kata allocation remained healthy"

  REPLACEMENT_ALLOC=""
  for i in $(seq 1 90); do
    REPLACEMENT_ALLOC=$(nomad job status -json kata-multi-vm 2>/dev/null \
      | jq -r --arg failed "$FAILED_ALLOC" '[.[0].Allocations[] | select(.TaskGroup == "server" and .ID != $failed and .ClientStatus == "running")][0].ID // ""')
    if [ -n "$REPLACEMENT_ALLOC" ] && nomad alloc status -json "$REPLACEMENT_ALLOC" \
      | jq -e '.TaskStates.web.State == "running" and .TaskStates["web-sidecar"].State == "running"' >/dev/null; then
      break
    fi
    REPLACEMENT_ALLOC=""
    sleep 2
  done

  if [ -z "$REPLACEMENT_ALLOC" ]; then
    echo "[FAIL] Nomad did not replace the poisoned allocation"
    nomad job status kata-multi-vm || true
    exit 1
  fi
  if pgrep -f "$FAILED_SANDBOX" >/dev/null; then
    echo "[FAIL] failed sandbox ID was recreated in the same allocation"
    pgrep -af "$FAILED_SANDBOX" || true
    exit 1
  fi
  REPLACEMENT_EXEC=$(nomad alloc exec -i=false -t=false -task web "$REPLACEMENT_ALLOC" /bin/echo REPLACEMENT_OK 2>/dev/null || echo "")
  if [ "$REPLACEMENT_EXEC" != "REPLACEMENT_OK" ]; then
    echo "[FAIL] replacement allocation did not accept exec"
    exit 1
  fi
  echo "[OK] poisoned allocation was replaced without same-ID sandbox recreation"

  echo ""
  echo "=== TaskStats verification ==="
  ALLOC_STATS=""
  for i in $(seq 1 30); do
    ALLOC_STATS=$(curl --fail --silent "$NOMAD_ADDR/v1/client/allocation/$HEALTHY_ALLOC/stats" 2>/dev/null || echo "")
    if echo "$ALLOC_STATS" | jq -e '.Tasks.fetcher.ResourceUsage.MemoryStats.Usage > 0 and .Tasks["fetcher-sidecar"].ResourceUsage.MemoryStats.Usage > 0' >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  echo "$ALLOC_STATS" | jq '.Tasks | with_entries(.value = .value.ResourceUsage)' 2>/dev/null || true
  if echo "$ALLOC_STATS" | jq -e '.Tasks.fetcher.ResourceUsage.MemoryStats.Usage > 0 and .Tasks["fetcher-sidecar"].ResourceUsage.MemoryStats.Usage > 0' >/dev/null 2>&1; then
    echo "[OK] Nomad received task resource statistics"
  else
    echo "[FAIL] client allocation stats did not contain task resource usage"
    log_tail 100
    exit 1
  fi

  echo ""
  echo "=== All integration tests passed ==="
''
