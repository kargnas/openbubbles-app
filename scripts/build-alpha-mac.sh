#!/usr/bin/env bash
# Build the OpenBubbles Alpha APK (com.bluebubbles.messaging.alpha) on an Apple Silicon Mac,
# signed with the fixed Alpha key so it installs over previous Alpha builds.
#
# Usage: scripts/build-alpha-mac.sh [--install [adb-serial]] [extra flutter build args...]
#   ALPHA_KEY_PROPERTIES  key.properties path (default ~/keys/openbubbles-alpha/key.properties)
#   ALLOW_DEBUG_KEY=1     build with the default debug key if the fixed key is missing
set -euo pipefail

FLUTTER_VERSION=3.24.0
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

die() { echo "error: $*" >&2; exit 1; }
warn() { echo "warning: $*" >&2; }

install=0
serial=""
flutter_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install)
      install=1
      if [[ $# -gt 1 && "$2" != -* ]]; then serial="$2"; shift; fi
      ;;
    *) flutter_args+=("$1") ;;
  esac
  shift
done

# --- Prerequisites ---
if command -v fvm >/dev/null 2>&1; then
  fvm install "$FLUTTER_VERSION" >/dev/null || die "fvm could not install Flutter $FLUTTER_VERSION"
  FLUTTER=(fvm flutter)
elif command -v flutter >/dev/null 2>&1; then
  FLUTTER=(flutter)
  version="$(flutter --version 2>/dev/null | head -n1 | awk '{print $2}')"
  [[ "$version" == "$FLUTTER_VERSION" ]] || warn "flutter on PATH is $version, expected $FLUTTER_VERSION (install fvm to pin it via .fvmrc)"
else
  die "Flutter $FLUTTER_VERSION not found. Install fvm (brew install fvm) or put flutter on PATH."
fi

command -v rustup >/dev/null 2>&1 || die "rustup not found (cargokit runs 'rustup run stable cargo'). Install from https://rustup.rs"
rustup run stable cargo --version >/dev/null 2>&1 || die "Rust stable toolchain missing. Run: rustup toolchain install stable"
command -v protoc >/dev/null 2>&1 || die "protoc not found. Run: brew install protobuf"

# /usr/libexec/java_home -v 21 silently returns another JDK when 21 isn't registered there
# (e.g. Homebrew's keg-only openjdk@21), so check each candidate's actual version.
is_java21() { [[ -x "$1/bin/java" ]] && "$1/bin/java" -version 2>&1 | head -n1 | grep -q '"21\.'; }
JAVA_HOME_21=""
for jh in "${JAVA_HOME:-}" \
          "$(/usr/libexec/java_home -v 21 2>/dev/null || true)" \
          /opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home; do
  if [[ -n "$jh" ]] && is_java21 "$jh"; then JAVA_HOME_21="$jh"; break; fi
done
[[ -n "$JAVA_HOME_21" ]] || die "Java 21 not found. Run: brew install openjdk@21"
export JAVA_HOME="$JAVA_HOME_21"
export PATH="$JAVA_HOME/bin:$PATH"

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
[[ -d "$ANDROID_HOME" ]] || die "Android SDK not found at $ANDROID_HOME (set ANDROID_HOME or install via Android Studio)"
export PATH="$ANDROID_HOME/platform-tools:$PATH"

# --- Fixed signing key ---
key_props="${ALPHA_KEY_PROPERTIES:-$HOME/keys/openbubbles-alpha/key.properties}"
if [[ ! -f "$key_props" ]]; then
  if [[ "${ALLOW_DEBUG_KEY:-}" == 1 ]]; then
    warn "$key_props missing; building with the debug key. This APK cannot update an Alpha installed with the fixed key."
  else
    die "fixed Alpha key not found at $key_props.
A debug-key APK cannot update an installed Alpha signed with the fixed key.
Restore the key (see README) or set ALLOW_DEBUG_KEY=1 to build with the debug key anyway."
  fi
fi

# --- Submodules (.gitmodules uses SSH URLs) ---
git -c url."https://github.com/".insteadOf="git@github.com:" submodule update --init --recursive

# --- Fake Fairplay certs (same as .github/workflows/build.yml) ---
cert_names=(
  "4056631661436364584235346952193"
  "4056631661436364584235346952194"
  "4056631661436364584235346952195"
  "4056631661436364584235346952196"
  "4056631661436364584235346952197"
  "4056631661436364584235346952198"
  "4056631661436364584235346952199"
  "4056631661436364584235346952200"
  "4056631661436364584235346952201"
  "4056631661436364584235346952208"
)
mkdir -p rustpush/certs/fairplay
for name in "${cert_names[@]}"; do
  [[ -f "rustpush/certs/fairplay/$name.pem" ]] || cp rustpush/certs/legacy-fairplay/fairplay.pem "rustpush/certs/fairplay/$name.pem"
  [[ -f "rustpush/certs/fairplay/$name.crt" ]] || cp rustpush/certs/legacy-fairplay/fairplay.crt "rustpush/certs/fairplay/$name.crt"
done

# --- Build ---
apk="build/app/outputs/flutter-apk/app-alpha-debug.apk"
start=$SECONDS
"${FLUTTER[@]}" build apk --flavor alpha --debug --target-platform android-arm64 ${flutter_args[@]+"${flutter_args[@]}"}
elapsed=$((SECONDS - start))

echo
echo "Built in $((elapsed / 60))m $((elapsed % 60))s"
echo "APK: $REPO_ROOT/$apk"
# minSdk 24 means v2/v3 signatures only (no META-INF), so use apksigner rather than keytool.
apksigner="$(ls -d "$ANDROID_HOME"/build-tools/*/ 2>/dev/null | sort -V | tail -n1)apksigner"
if [[ -x "$apksigner" ]]; then
  "$apksigner" verify --print-certs "$apk" | grep -i 'SHA-256' || warn "could not read signer certificate"
else
  warn "apksigner not found under $ANDROID_HOME/build-tools; skipping signer check"
fi

# --- Optional install (never uninstalls) ---
if [[ $install == 1 ]]; then
  command -v adb >/dev/null 2>&1 || die "adb not found (expected in $ANDROID_HOME/platform-tools)"
  adb_cmd=(adb)
  [[ -n "$serial" ]] && adb_cmd+=(-s "$serial")
  rc=0
  out="$("${adb_cmd[@]}" install -r "$apk" 2>&1)" || rc=$?
  if [[ $rc != 0 ]] || grep -q "Failure \[" <<<"$out"; then
    echo "$out" >&2
    if grep -qE "INSTALL_FAILED_UPDATE_INCOMPATIBLE|signatures do not match" <<<"$out"; then
      die "the installed Alpha is signed with a different key. Not uninstalling (that would wipe its data); build with the matching key instead."
    fi
    die "adb install failed"
  fi
  echo "$out"
fi
