#!/bin/bash
# Explicit production transfer only. --plan performs read-only preflight.
set -euo pipefail
umask 077
source_app="${UNIAPI_NATIVE_APP_SOURCE:-$(cd "$(dirname "$0")/.." && pwd)/build.noindex/UniApi.app}"
root="${UNIAPI_ROOT:-}"
data_root="${UNIAPI_DATA:-}"
provider_file="${UNIAPI_PROVIDERS:-}"
applications="${UNIAPI_NATIVE_APPLICATIONS:-$HOME/Applications}"
agents="${UNIAPI_NATIVE_LAUNCH_AGENTS:-$HOME/Library/LaunchAgents}"
action="${1:---plan}"
case "$action" in --plan|--install) ;; *) echo 'Expected --plan or --install.' >&2; exit 64;; esac
for label in app.devved.uniapi-server app.devved.uniapi-shim; do
  definition="$agents/$label.plist"
  [[ ! -L "$definition" ]] || { echo 'Linked LaunchAgent definition refused.' >&2; exit 1; }
  if [[ -f "$definition" ]]; then
    previous_root="$(plutil -extract EnvironmentVariables.UNIAPI_ROOT raw -o - "$definition" 2>/dev/null || true)"
    if [[ -z "$previous_root" ]]; then
      previous_root="$(plutil -extract WorkingDirectory raw -o - "$definition" 2>/dev/null || true)"
      if [[ "$label" == app.devved.uniapi-server && "$previous_root" == */server ]]; then previous_root="${previous_root%/server}"; fi
    fi
    if [[ -n "$previous_root" ]]; then
      [[ "$previous_root" == /* ]] || { echo 'Legacy service has an invalid data root.' >&2; exit 1; }
      [[ -z "$root" || "$root" == "$previous_root" ]] || { echo 'Existing services and requested data root disagree; transfer refused.' >&2; exit 1; }
      root="$previous_root"
    fi
    previous_directory="$(plutil -extract WorkingDirectory raw -o - "$definition" 2>/dev/null || true)"
    for key in UNIAPI_DATA UNIAPI_PROVIDERS CODEX_HOME ZCODE_HOME XDG_DATA_HOME; do
      previous="$(plutil -extract "EnvironmentVariables.$key" raw -o - "$definition" 2>/dev/null || true)"
      [[ -n "$previous" ]] || continue
      if [[ "$previous" != /* ]]; then
        [[ "$previous_directory" == /* ]] || { echo 'A relative service path lacks a known working directory.' >&2; exit 1; }
        previous="$previous_directory/$previous"
      fi
      current="${!key:-}"
      [[ -z "$current" || "$current" == "$previous" ]] || { echo 'Configured service paths disagree; data retained and transfer refused.' >&2; exit 1; }
      export "$key=$previous"
    done
  fi
done
root="${root:-$HOME/UniApi}"
export UNIAPI_ROOT="$root"
data_root="${UNIAPI_DATA:-$root/data}"
provider_file="${UNIAPI_PROVIDERS:-$root/providers.json}"
[[ "$data_root" == /* && "$provider_file" == /* ]] || { echo 'Managed storage paths must be absolute for transfer.' >&2; exit 1; }
export UNIAPI_DATA="$data_root" UNIAPI_PROVIDERS="$provider_file"
[[ ! -L "$source_app" && -d "$source_app" ]] || { echo 'Build the production native bundle first.' >&2; exit 1; }
identity="$(plutil -extract CFBundleIdentifier raw -o - "$source_app/Contents/Info.plist")"
[[ "$identity" == app.devved.uniapi.hub ]] || { echo 'Production transfer requires the preserved UniApi bundle identity.' >&2; exit 1; }
executable="$source_app/Contents/MacOS/UniApiNative"
[[ -x "$executable" && ! -L "$executable" ]] || exit 1
codesign --verify --strict "$source_app"
# Selection is based on protected launch definitions, never a failed transport.
# Both plans perform admission only and cannot construct an app runtime.
if plan="$("$executable" --prepare-install "$applications/UniApi.app")"; then :
else plan_result=$?; printf '%s\n' "$plan"; exit "$plan_result"; fi
printf '%s\n' "$plan"
installation_kind="$(plutil -extract kind raw -o - - <<< "$plan")"
case "$installation_kind" in native|legacy) ;; *) echo 'Unknown installation kind; no services changed.' >&2; exit 1;; esac
old_instance=""
if [[ "$installation_kind" == native ]]; then old_instance="$(plutil -extract oldInstance raw -o - - <<< "$plan")"; fi
if [[ "$action" == --plan ]]; then
  printf 'Native app: %s\nData retained: %s\nDestination: %s/UniApi.app\nServices: app.devved.uniapi-server, app.devved.uniapi-shim\n' "$source_app" "$root" "$applications"
  exit 0
fi
[[ ! -L "$applications/UniApi.app" ]] || { echo 'Linked destination app refused.' >&2; exit 1; }
for folder in "$root" "$applications" "$agents"; do
  [[ ! -L "$folder" ]] || { echo 'Linked installation directory refused.' >&2; exit 1; }
done
for folder in "$data_root" "$data_root/logs" "$data_root/native-install-backups"; do
  [[ ! -L "$folder" && ( ! -e "$folder" || -d "$folder" ) ]] \
    || { echo 'Linked or non-directory managed data ancestry refused.' >&2; exit 1; }
done
mkdir -p "$data_root/logs" "$applications" "$agents"
lock="$applications/.UniApi-native-install.lock"
mkdir "$lock" 2>/dev/null || { echo 'Another native transfer owns the installation lock.' >&2; exit 1; }
trap 'rmdir "$lock" 2>/dev/null || true' EXIT
nonce="$(uuidgen)"
[[ "$nonce" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]] \
  || { echo 'A valid new installation identity is required.' >&2; exit 1; }
nonce="$(printf '%s' "$nonce" | tr '[:lower:]' '[:upper:]')"
[[ "$installation_kind" != native || "$nonce" != "$old_instance" ]] \
  || { echo 'The update requires a fresh installation identity.' >&2; exit 1; }
[[ ! -L "$data_root/native-install-backups" ]] || { echo 'Linked backup directory refused.' >&2; exit 1; }
mkdir -p "$data_root/native-install-backups"
backup="$(mktemp -d "$data_root/native-install-backups/$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")"
for label in app.devved.uniapi-server app.devved.uniapi-shim; do
  if launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then touch "$backup/$label.loaded"; fi
  if [[ -f "$agents/$label.plist" ]]; then cp -p "$agents/$label.plist" "$backup/$label.plist"; fi
done
if [[ -d "$applications/UniApi.app" ]]; then cp -R "$applications/UniApi.app" "$backup/UniApi.app"; fi
staging="$(mktemp -d "$applications/.UniApi-native-stage.XXXXXX")"
staged="$staging/UniApi.app"
changed=0
app_changed=0
original_definition() {
  local label="$1" destination="$agents/$1.plist"
  [[ ! -L "$destination" ]] || return 1
  if [[ -f "$backup/$label.plist" ]]; then
    [[ -f "$destination" ]] && cmp -s "$backup/$label.plist" "$destination"
  else [[ ! -e "$destination" ]]; fi
}
restored_service_ready() {
  local label="$1" restored_pid="$2"
  if [[ "$installation_kind" == native ]]; then
    if [[ "$label" == app.devved.uniapi-server ]]; then "$executable" --native-health "$restored_pid" "$old_instance"
    else "$executable" --native-shim-health "$restored_pid" "$old_instance"; fi
  else "$executable" --legacy-health "$label"; fi
}
rollback() {
  local result=$?
  local recovery_failed=0
  set +e
  if [[ "$result" != 0 && "$changed" == 1 ]]; then
    # Never stop a label merely because our attempted install used it. The
    # Swift adapter proves this startup nonce, pauses admission and refuses
    # active/foreign owners before unregistering any new native process.
    cleanup="$backup/native-recovery.json"
    if ! "$executable" --retire-native-install "$nonce" "$applications/UniApi.app" > "$cleanup" \
       || [[ "$(plutil -extract safeToRestore raw -o - "$cleanup" 2>/dev/null)" != true ]]; then
      recovery_failed=1
      echo "Native recovery could not retire only this install's idle services; current app and definitions retained. Evidence: $cleanup" >&2
    fi
    for label in app.devved.uniapi-server app.devved.uniapi-shim; do
      [[ "$recovery_failed" == 0 ]] || break
      if [[ -f "$backup/$label.definition-attempted" ]] \
         && [[ ! -L "$agents/$label.plist" && -f "$agents/$label.plist" ]] \
         && cmp -s "$backup/$label.native-plist" "$agents/$label.plist"; then
        if [[ -f "$backup/$label.plist" ]]; then
          temporary="$(mktemp "$agents/.native-restore.XXXXXX")"
          cp -p "$backup/$label.plist" "$temporary" && mv -f "$temporary" "$agents/$label.plist" || recovery_failed=1
        else rm -f "$agents/$label.plist" || recovery_failed=1; fi
      elif ! original_definition "$label"; then
        recovery_failed=1
        echo 'A LaunchAgent definition changed independently; operator bytes retained.' >&2
      fi
    done
    if [[ "$recovery_failed" == 0 && "$app_changed" == 1 ]]; then
      if [[ -e "$applications/UniApi.app" ]]; then
        if [[ ! -e "$backup/failed-native.app" && ! -L "$backup/failed-native.app" ]] \
           && diff -rq "$backup/native-app" "$applications/UniApi.app" >/dev/null 2>&1; then
          mv "$applications/UniApi.app" "$backup/failed-native.app" || recovery_failed=1
        else recovery_failed=1; fi
      fi
      if [[ -d "$backup/replaced-UniApi.app" ]]; then
        if [[ ! -e "$applications/UniApi.app" && ! -L "$applications/UniApi.app" ]]; then
          mv "$backup/replaced-UniApi.app" "$applications/UniApi.app" || recovery_failed=1
        else recovery_failed=1; fi
      fi
      if [[ -d "$backup/UniApi.app" ]]; then
        [[ -d "$applications/UniApi.app" ]] && diff -rq "$backup/UniApi.app" "$applications/UniApi.app" >/dev/null 2>&1 || recovery_failed=1
      else [[ ! -e "$applications/UniApi.app" ]] || recovery_failed=1; fi
    fi
    if [[ "$recovery_failed" == 0 && "$app_changed" == 0 && -d "$backup/UniApi.app" ]] \
       && ! diff -rq "$backup/UniApi.app" "$applications/UniApi.app" >/dev/null 2>&1; then
      recovery_failed=1
      echo 'Installed app changed independently; operator bytes retained.' >&2
    fi
    for label in app.devved.uniapi-server app.devved.uniapi-shim; do
      [[ "$recovery_failed" == 0 ]] || break
      if [[ -f "$backup/$label.loaded" && -f "$agents/$label.plist" ]]; then
        launchctl bootstrap "gui/$(id -u)" "$agents/$label.plist" || recovery_failed=1
        restored=0
        for attempt in $(seq 1 20); do
          recovered_pid="$(launchctl print "gui/$(id -u)/$label" 2>/dev/null | awk '/pid =/ {print $3; exit}')"
          if [[ "$recovered_pid" =~ ^[0-9]+$ ]] && restored_service_ready "$label" "$recovered_pid" >/dev/null 2>&1; then restored=1; break; fi
          sleep 0.5
        done
        [[ "$restored" == 1 ]] || recovery_failed=1
      fi
    done
    if [[ "$recovery_failed" == 0 ]]; then echo 'Native installation failed; previous app/service definitions and running PIDs restored. Data and configs retained.' >&2
    else echo "Native installation failed; recovery is incomplete. Backups and configs retained at $backup; inspect restored services before continuing." >&2; fi
  fi
  rm -rf "$staging"
  rmdir "$lock" 2>/dev/null || true
}
trap rollback EXIT
cp -R "$source_app" "$staged"
codesign --verify --strict "$staged"
cp -R "$staged" "$backup/native-app"
# The adapter freezes admission and rechecks actual work/socket ownership. It
# restores its own partial removal on failure; sampled idle alone grants no stop.
if prepared_plan="$("$executable" --prepare-install "$applications/UniApi.app")"; then :
else plan_result=$?; printf '%s\n' "$prepared_plan"; exit "$plan_result"; fi
[[ "$(plutil -extract kind raw -o - - <<< "$prepared_plan")" == "$installation_kind" ]] \
  || { echo 'The installation owner changed; no retirement requested.' >&2; exit 1; }
if [[ "$installation_kind" == native ]]; then
  [[ "$(plutil -extract oldInstance raw -o - - <<< "$prepared_plan")" == "$old_instance" ]] \
    || { echo 'The native installation identity changed; no retirement requested.' >&2; exit 1; }
fi
for label in app.devved.uniapi-server app.devved.uniapi-shim; do
  original_definition "$label" || { echo 'A launch definition changed after backup; no retirement requested.' >&2; exit 1; }
done
if [[ -d "$backup/UniApi.app" ]]; then
  diff -rq "$backup/UniApi.app" "$applications/UniApi.app" >/dev/null 2>&1 \
    || { echo 'The installed app changed after backup; no retirement requested.' >&2; exit 1; }
fi
printf '%s\n' "$prepared_plan" > "$backup/prepared-install.json"
retirement="$backup/retirement.json"
if [[ "$installation_kind" == native ]]; then
  retirement_command=("$executable" --retire-native-update "$old_instance" "$applications/UniApi.app" "$prepared_plan")
else retirement_command=("$executable" --retire-legacy); fi
if ! "${retirement_command[@]}" > "$retirement"; then
  echo "Native transfer refused or recovery needs attention; installed files were retained. Retirement evidence: $retirement" >&2
  exit 1
fi
[[ "$(plutil -extract status raw -o - "$retirement")" == retired \
   && "$(plutil -extract safeToInstall raw -o - "$retirement")" == true ]] \
  || { echo 'Retirement did not prove safe installation; inspect retained evidence.' >&2; exit 1; }
changed=1
"$executable" --check-transfer
if [[ -d "$applications/UniApi.app" ]]; then
  diff -rq "$backup/UniApi.app" "$applications/UniApi.app" >/dev/null 2>&1 \
    || { echo 'Installed app changed independently; replacement refused.' >&2; exit 1; }
  mv "$applications/UniApi.app" "$backup/replaced-UniApi.app"
fi
app_changed=1
mv "$staged" "$applications/UniApi.app"
xml() { local value="$1"; value="${value//&/\&amp;}"; value="${value//</\&lt;}"; value="${value//>/\&gt;}"; printf '%s' "$value"; }
preserved_environment() {
  local key value
  for key in UNIAPI_DATA UNIAPI_PROVIDERS CODEX_HOME ZCODE_HOME XDG_DATA_HOME; do
    value="${!key:-}"
    if [[ -n "$value" ]]; then printf '<key>%s</key><string>%s</string>\n' "$key" "$(xml "$value")"; fi
  done
}
write_agent() {
  local label="$1" binary="$2" argument="$3" destination="$agents/$1.plist" output
  [[ ! -L "$destination" ]] || { echo 'Linked LaunchAgent destination refused.' >&2; return 1; }
  original_definition "$label" || { echo 'LaunchAgent definition changed independently; publication refused.' >&2; return 1; }
  output="$(mktemp "$agents/.native-agent.XXXXXX")"
  if [[ "$installation_kind" == native && -f "$backup/$label.plist" ]]; then
    # Native locations already match the admitted installation. Retain all
    # unrelated launch settings/environment, including its exit grace policy.
    plutil -convert xml1 -o "$output" "$backup/$label.plist"
    plutil -replace EnvironmentVariables.UNIAPI_NATIVE_INSTALL_NONCE -string "$nonce" "$output"
  else
    cat > "$output" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$(xml "$label")</string>
<key>ProgramArguments</key><array><string>$(xml "$binary")</string><string>$(xml "$argument")</string></array>
<key>WorkingDirectory</key><string>$(xml "$root")</string>
<key>EnvironmentVariables</key><dict><key>UNIAPI_ROOT</key><string>$(xml "$root")</string><key>UNIAPI_NATIVE_INSTALL_NONCE</key><string>$(xml "$nonce")</string><key>PATH</key><string>$(xml "$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")</string>$(preserved_environment)</dict>
<key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>5</integer>
<key>ProcessType</key><string>Interactive</string>
<key>StandardOutPath</key><string>$(xml "$data_root/logs/native-$label.log")</string>
<key>StandardErrorPath</key><string>$(xml "$data_root/logs/native-$label.stderr.log")</string>
</dict></plist>
PLIST
  fi
  chmod 600 "$output"
  plutil -lint "$output" >/dev/null
  cp -p "$output" "$backup/$label.native-plist"
  touch "$backup/$label.definition-attempted"
  original_definition "$label" || { echo 'LaunchAgent definition changed during publication; operator bytes retained.' >&2; return 1; }
  mv -f "$output" "$destination"
}
write_agent app.devved.uniapi-server "$applications/UniApi.app/Contents/MacOS/UniApiNative" --background
write_agent app.devved.uniapi-shim "$applications/UniApi.app/Contents/Resources/Helpers/uniapi-shim" --serve
for label in app.devved.uniapi-server app.devved.uniapi-shim; do launchctl bootstrap "gui/$(id -u)" "$agents/$label.plist"; done
confirmed=0
for attempt in $(seq 1 60); do
  pid="$(launchctl print "gui/$(id -u)/app.devved.uniapi-server" 2>/dev/null | awk '/pid =/ {print $3; exit}')"
  shim_pid="$(launchctl print "gui/$(id -u)/app.devved.uniapi-shim" 2>/dev/null | awk '/pid =/ {print $3; exit}')"
  if [[ "$pid" =~ ^[0-9]+$ && "$shim_pid" =~ ^[0-9]+$ ]] \
     && "$applications/UniApi.app/Contents/MacOS/UniApiNative" --native-health "$pid" "$nonce" >/dev/null 2>&1 \
     && "$applications/UniApi.app/Contents/MacOS/UniApiNative" --native-shim-health "$shim_pid" "$nonce" >/dev/null 2>&1; then confirmed=1; break; fi
  sleep 0.5
done
[[ "$confirmed" == 1 ]] || { echo 'Native startup was not confirmed; restoring the previous installation.' >&2; exit 1; }
changed=0
trap - EXIT
rmdir "$staging"
rmdir "$lock"
printf 'Installed the native Swift app. Recovery backup: %s\n' "$backup"
# Charging/fan helper installation is a separate explicit in-app administrator
# action. GUI installation never changes a physical control or target.
