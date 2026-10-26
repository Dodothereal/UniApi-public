#!/bin/bash
# Only the executable is replaced. Swift performs bounded protected-file,
# loaded-job/kernel-instance and immutable-report admission; no inference or controls.
uniapi_battery_handoff() (
  set -euo pipefail
  umask 077
  local_source="$1"; state_directory="$2"; installed_binary="$3"
  daemon_plist="$4"; daemon_label="$5"; local_uid="$6"; poll_attempts="${7:-40}"
  [[ "$poll_attempts" =~ ^[0-9]+$ && "$poll_attempts" -ge 1 && "$poll_attempts" -le 40 ]] || exit 64
  [[ "$(id -u)" == 0 ]] || { echo 'Charging handoff requires administrator ownership.' >&2; exit 1; }
  lock_directory="$state_directory/.upgrade-lock"
  mkdir "$lock_directory" 2>/dev/null || { echo 'Another charging upgrade owns the transaction.' >&2; exit 1; }
  trap 'handoff_result=$?; rmdir "$lock_directory" 2>/dev/null || true; exit "$handoff_result"' EXIT
  transaction="$(mktemp -d "$state_directory/.upgrade.XXXXXX")"
  candidate="$(mktemp "$(dirname "$installed_binary")/.uniapi-battery-new.XXXXXX")"
  validator="$transaction/validator"; changed=0; requested_target=unknown
  initial_instance=''; replaced_instance=''; previous_hash=''
  field() { plutil -extract "$2" raw -o - "$1"; }
  files() { "$validator" handoff-files "$state_directory" "$installed_binary" "$daemon_plist" "$daemon_label" "$local_uid"; }
  loaded() {
    if [[ -n "${1:-}" ]]; then
      launchctl print "system/$daemon_label" | "$validator" handoff-loaded "$state_directory" "$installed_binary" "$daemon_label" "$1"
    else launchctl print "system/$daemon_label" | "$validator" handoff-loaded "$state_directory" "$installed_binary" "$daemon_label"; fi
  }
  same_state() {
    local phase_hash="$1" current
    current="$(files)" || return 1
    printf '%s\n' "$current" > "$transaction/current-files.json" || return 1
    [[ "$(field "$transaction/current-files.json" binarySHA256)" == "$phase_hash" \
      && "$(field "$transaction/current-files.json" target)" == "$target_stamp" \
      && "$(field "$transaction/current-files.json" journal)" == "$journal_stamp" \
      && "$(field "$transaction/current-files.json" plist)" == "$plist_stamp" ]]
  }
  restart_controller() {
    local expected_instance="$1" proof actual_instance
    # Prove the loaded definition and root process again immediately before the
    # label signal. A missing image path is allowed only for the admitted birth.
    proof="$(loaded "$expected_instance")" || return 1
    printf '%s\n' "$proof" > "$transaction/before-signal.json" || return 1
    actual_instance="$(field "$transaction/before-signal.json" instance)" || return 1
    [[ "$actual_instance" == "$expected_instance" ]] || return 1
    if [[ "$expected_instance" != absent ]]; then launchctl kill SIGKILL "system/$daemon_label" || return 1; fi
    launchctl kickstart -p "system/$daemon_label" >/dev/null || return 1
  }
  heartbeat() {
    local expected_hash="$1" earliest="$2" mode="$3" forbidden="$4" proof pid instance acknowledgement after
    proof="$(loaded)" || return 1
    printf '%s\n' "$proof" > "$transaction/ack-instance.json" || return 1
    pid="$(field "$transaction/ack-instance.json" pid)" || return 1
    instance="$(field "$transaction/ack-instance.json" instance)" || return 1
    [[ "$instance" != "$forbidden" ]] || return 1
    acknowledgement="$("$validator" handoff-ack "$state_directory" "$installed_binary" "$pid" "$earliest" "$expected_hash" "$requested_target" "$mode")" || return 1
    printf '%s\n' "$acknowledgement" > "$transaction/ack.json" || return 1
    [[ "$(field "$transaction/ack.json" instance)" == "$instance" ]] || return 1
    # State parsing uses one protected descriptor. Then prove the same live
    # instance and all protected stamps again before relinquishing rollback.
    after="$(loaded)" || return 1
    [[ "$after" == "$proof" ]] || return 1
    same_state "$expected_hash" || return 1
    replaced_instance="$instance"
  }
  rollback() {
    local result=$? recovered=0 restore_candidate='' recovery_started proof
    set +e
    if [[ "$result" != 0 && "$changed" == 1 ]]; then
      # Capture the failed replacement's current birth before publishing old
      # bytes. Unknown owners are never signalled merely to make rollback pass.
      proof="$(loaded "${replaced_instance:-$initial_instance}")"
      if [[ "$?" == 0 ]]; then
        printf '%s\n' "$proof" > "$transaction/recovery-instance.json"
        replaced_instance="$(field "$transaction/recovery-instance.json" instance)"
      else replaced_instance=''; fi
      # Even a crashed replacement may have no PID. Restore only our published
      # bytes, then restart only a separately verified loaded job/instance.
      if files > "$transaction/recovery-files.json" \
        && [[ "$(field "$transaction/recovery-files.json" binarySHA256)" == "$expected_hash" ]]; then
        "$validator" handoff-clock > "$transaction/recovery-clock.json"
        recovery_started="$(field "$transaction/recovery-clock.json" micros)"
        restore_candidate="$(mktemp "$(dirname "$installed_binary")/.uniapi-battery-restore.XXXXXX")"
        if [[ -n "$restore_candidate" ]] && install -o root -g wheel -m 755 "$transaction/previous-binary" "$restore_candidate" \
          && mv -f "$restore_candidate" "$installed_binary"; then
          if [[ -n "$replaced_instance" ]] && restart_controller "$replaced_instance"; then
            for attempt in $(seq 1 "$poll_attempts"); do
              if heartbeat "$previous_hash" "$recovery_started" legacy "$replaced_instance"; then recovered=1; break; fi
              sleep 0.5
            done
          fi
        fi
      fi
      if [[ "$recovered" == 1 ]]; then echo 'Charging upgrade failed; a fresh previous controller instance is confirmed. Target and journal were not overwritten.' >&2
      else echo "Charging upgrade failed; recovery is unconfirmed. Executable backup retained at $transaction; target and journal were not overwritten." >&2; fi
      [[ -z "$restore_candidate" ]] || rm -f "$restore_candidate"
    fi
    rm -f "$candidate"
    rmdir "$lock_directory" 2>/dev/null || true
    exit "$result"
  }
  trap rollback EXIT
  install -o root -g wheel -m 755 "$local_source" "$candidate"
  codesign --verify --strict "$candidate"
  install -o root -g wheel -m 755 "$candidate" "$validator"
  codesign --verify --strict "$validator"
  # Protected prior code/job/report admission precedes backup or any signals.
  files > "$transaction/files.json"
  previous_hash="$(field "$transaction/files.json" binarySHA256)"
  previous_binary_stamp="$(field "$transaction/files.json" binary)"
  target_stamp="$(field "$transaction/files.json" target)"; journal_stamp="$(field "$transaction/files.json" journal)"; plist_stamp="$(field "$transaction/files.json" plist)"
  loaded > "$transaction/initial-instance.json"
  initial_instance="$(field "$transaction/initial-instance.json" instance)"
  [[ "$initial_instance" != absent ]] || { echo 'The prior charging job has no admitted running instance; recover it before upgrading.' >&2; exit 1; }
  "$validator" check-handoff "$state_directory" "$local_uid" > "$transaction/admission.json"
  [[ "$(field "$transaction/admission.json" compatible)" == true && "$(field "$transaction/admission.json" protocol)" == 1 \
    && "$(field "$transaction/admission.json" owner)" == "$local_uid" ]] || exit 1
  requested_target="$(field "$transaction/admission.json" target)"
  expected_hash="$(shasum -a 256 "$candidate" | awk '{print $1}')"
  install -o root -g wheel -m 755 "$installed_binary" "$transaction/previous-binary"
  [[ "$(shasum -a 256 "$transaction/previous-binary" | awk '{print $1}')" == "$previous_hash" ]] || exit 1
  "$validator" check-handoff "$state_directory" "$local_uid" > "$transaction/recheck.json"
  [[ "$(field "$transaction/recheck.json" compatible)" == true && "$(field "$transaction/recheck.json" protocol)" == 1 \
    && "$(field "$transaction/recheck.json" owner)" == "$local_uid" && "$(field "$transaction/recheck.json" target)" == "$requested_target" ]] || exit 1
  same_state "$previous_hash"
  [[ "$(field "$transaction/current-files.json" binary)" == "$previous_binary_stamp" ]] || exit 1
  [[ "$(loaded)" == "$(cat "$transaction/initial-instance.json")" ]] || exit 1
  "$validator" handoff-clock > "$transaction/started.json"
  started="$(field "$transaction/started.json" micros)"
  changed=1
  mv -f "$candidate" "$installed_binary"
  restart_controller "$initial_instance"
  confirmed=0
  for attempt in $(seq 1 "$poll_attempts"); do
    same_state "$expected_hash" || break
    if heartbeat "$expected_hash" "$started" swift "$initial_instance"; then confirmed=1; break; fi
    sleep 0.5
  done
  [[ "$confirmed" == 1 ]] || { echo 'The exact fresh replacement controller was not confirmed; restoring the previous executable.' >&2; exit 1; }
  changed=0
  printf 'Charging controller upgraded; target and journal retained. Recovery backup: %s\n' "$transaction"
)
