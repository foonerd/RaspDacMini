#!/bin/sh
# Pre-release validation (run on build host only — NOT installed on device).
# Catches trivial errors before packaging the plugin.

set -e

ROOT="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FAIL=0

fail() {
    echo "VALIDATE FAIL: $1" >&2
    FAIL=1
}

pass() {
    echo "VALIDATE OK: $1"
}

echo "=== RaspDacMini plugin validation ==="

# JavaScript syntax
if command -v node >/dev/null 2>&1; then
    for js in index.js compositor/index.js compositor/utils/volumiolistener.js; do
        if node --check "$js" 2>/dev/null; then
            pass "syntax $js"
        else
            fail "syntax $js"
        fi
    done
else
    echo "VALIDATE SKIP: node not available (JS syntax not checked)"
fi

# Shell scripts
for sh in install.sh uninstall.sh scripts/*.sh; do
    if sh -n "$sh" 2>/dev/null; then
        pass "shell $sh"
    else
        fail "shell $sh"
    fi
done

# Splash assets (architecture-independent, must ship complete)
SPLASH_SIZE=153600
for frame in boot starting shutdown reboot; do
    raw="assets/splash/${frame}.raw"
    if [ ! -f "$raw" ]; then
        fail "missing $raw"
        continue
    fi
    size=$(wc -c < "$raw" | tr -d ' ')
    if [ "$size" != "$SPLASH_SIZE" ]; then
        fail "$raw size $size (expected $SPLASH_SIZE)"
    else
        pass "$raw ($size bytes)"
    fi
done

if [ ! -f assets/splash/volumio-logo.png ]; then
    fail "missing assets/splash/volumio-logo.png"
else
    pass "assets/splash/volumio-logo.png"
fi

# Boot splash service must show boot frame only (not starting)
if grep -q 'rdmlcd-show-splash.sh boot' compositor/service/rdmlcd-splash.service 2>/dev/null; then
    pass "rdmlcd-splash.service uses boot frame"
else
    fail "rdmlcd-splash.service must ExecStart rdmlcd-show-splash.sh boot"
fi

if grep -q 'rdmlcd-show-splash.sh starting' compositor/service/rdmlcd-splash.service 2>/dev/null; then
    fail "rdmlcd-splash.service must not use starting frame"
fi

# dev-fb1.device never activates on Volumio/Pi despite /dev/fb1 existing — use ExecStartPre only
if grep -q 'dev-fb1\.device' compositor/service/rdmlcd-splash.service 2>/dev/null; then
    fail "rdmlcd-splash.service must not use dev-fb1.device (wait on /dev/fb1 in ExecStartPre)"
else
    pass "rdmlcd-splash.service does not depend on dev-fb1.device"
fi

if ! grep -q 'TimeoutStartSec=30' compositor/service/rdmlcd-splash.service 2>/dev/null; then
    fail "rdmlcd-splash.service must set TimeoutStartSec=30"
else
    pass "rdmlcd-splash.service TimeoutStartSec"
fi

# Plugin sync must not write starting splash (compositor owns Starting phase)
if grep -q 'rdmlcd-show-splash.sh starting' scripts/rdmlcd-plugin-services.sh 2>/dev/null; then
    fail "rdmlcd-plugin-services.sh must not call show-splash starting"
else
    pass "rdmlcd-plugin-services.sh does not write starting splash"
fi

# Compositor early splash must use starting.raw only
if grep -q 'starting\.raw' compositor/index.js 2>/dev/null; then
    pass "compositor early splash uses starting.raw"
else
    fail "compositor/index.js must paint starting.raw at compositor load"
fi

if grep -q 'boot\.raw' compositor/index.js 2>/dev/null; then
    fail "compositor must not write boot.raw (boot service owns Booting phase)"
fi

if ! grep -q 'first-frame-written' compositor/index.js 2>/dev/null; then
    fail "compositor must log first-frame-written after initial UI paint"
else
    pass "compositor first-frame-written log"
fi

if ! grep -q 'loop-start' compositor/index.js 2>/dev/null; then
    fail "compositor must log loop-start when UI interval begins"
else
    pass "compositor display loop-start log"
fi

if grep -q 'if(bufwrite_interval) updateFB' compositor/index.js 2>/dev/null; then
    fail "compositor must not gate updateFB on bufwrite_interval in ready handler"
fi

# Shutdown splash must NOT activate at boot
if grep -q 'WantedBy=multi-user.target' compositor/service/rdmlcd-shutdown.service 2>/dev/null; then
    fail "rdmlcd-shutdown.service must not use WantedBy=multi-user.target"
else
    pass "rdmlcd-shutdown.service install target"
fi

if ! grep -q 'WantedBy=shutdown.target' compositor/service/rdmlcd-shutdown.service 2>/dev/null; then
    fail "rdmlcd-shutdown.service must WantedBy shutdown.target"
else
    pass "rdmlcd-shutdown.service shutdown.target"
fi

# Compositor must not use path before require
if head -25 compositor/index.js | grep -q 'require("path")'; then
    pass "compositor/index.js path require order"
else
    fail "compositor/index.js must require path before SPLASH_DIR"
fi

# Native module source present
if [ ! -f native/rgb565/rgb565.cpp ]; then
    fail "missing native/rgb565/rgb565.cpp"
else
    pass "native rgb565 source"
fi

# Service templates present
for unit in rdmlcd.service rdmlcd-splash.service rdmlcd-shutdown.service; do
    if [ -f "compositor/service/$unit" ]; then
        pass "compositor/service/$unit"
    else
        fail "missing compositor/service/$unit"
    fi
done

echo "=== Validation complete ==="
if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
exit 0
