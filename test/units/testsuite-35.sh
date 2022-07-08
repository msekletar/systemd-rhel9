#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-2.1-or-later
set -eux
set -o pipefail

# shellcheck source=test/units/assert.sh
. "$(dirname "$0")"/assert.sh

cleanup_test_user() (
    set +ex

    pkill -u "$(id -u logind-test-user)"
    sleep 1
    pkill -KILL -u "$(id -u logind-test-user)"
    userdel -r logind-test-user
)

setup_test_user() {
    mkdir -p /var/spool/cron /var/spool/mail
    useradd -m -s /bin/bash logind-test-user
    trap cleanup_test_user EXIT
}

test_enable_debug() {
    mkdir -p /run/systemd/system/systemd-logind.service.d
    cat >/run/systemd/system/systemd-logind.service.d/debug.conf <<EOF
[Service]
Environment=SYSTEMD_LOG_LEVEL=debug
EOF
    systemctl daemon-reload
    systemctl stop systemd-logind.service
}

test_properties() {
    mkdir -p /run/systemd/logind.conf.d

    cat >/run/systemd/logind.conf.d/kill-user-processes.conf <<EOF
[Login]
KillUserProcesses=no
EOF

    systemctl restart systemd-logind.service
    assert_eq "$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager KillUserProcesses)" "b false"

    cat >/run/systemd/logind.conf.d/kill-user-processes.conf <<EOF
[Login]
KillUserProcesses=yes
EOF

    systemctl restart systemd-logind.service
    assert_eq "$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager KillUserProcesses)" "b true"

    rm -rf /run/systemd/logind.conf.d
}

test_started() {
    local pid

    systemctl restart systemd-logind.service

    # should start at boot, not with D-BUS activation
    pid=$(systemctl show systemd-logind.service -p ExecMainPID --value)

    # loginctl should succeed
    loginctl

    # logind should still be running
    assert_eq "$(systemctl show systemd-logind.service -p ExecMainPID --value)" "$pid"
}

wait_suspend() {
    timeout "${1?}" bash -c "while [[ ! -e /run/suspend.flag ]]; do sleep 1; done"
    rm /run/suspend.flag
}

teardown_suspend() (
    set +eux

    pkill evemu-device

    rm -rf /run/systemd/system/systemd-suspend.service.d
    systemctl daemon-reload

    rm -f /run/udev/rules.d/70-logindtest-lid.rules
    udevadm control --reload
)

test_suspend_on_lid() {
    local pid input_name lid_dev

    if systemd-detect-virt --quiet --container; then
        echo "Skipping suspend test in container"
        return
    fi
    if ! grep -s -q mem /sys/power/state; then
        echo "suspend not supported on this testbed, skipping"
        return
    fi
    if ! command -v evemu-device &>/dev/null; then
        echo "command evemu-device not found, skipping"
        return
    fi
    if ! command -v evemu-event &>/dev/null; then
        echo "command evemu-event not found, skipping"
        return
    fi

    trap teardown_suspend RETURN

    # save pid
    pid=$(systemctl show systemd-logind.service -p ExecMainPID --value)

    # create fake suspend
    mkdir -p /run/systemd/system/systemd-suspend.service.d
    cat >/run/systemd/system/systemd-suspend.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=touch /run/suspend.flag
EOF
    systemctl daemon-reload

    # create fake lid switch
    mkdir -p /run/udev/rules.d
    cat >/run/udev/rules.d/70-logindtest-lid.rules <<EOF
SUBSYSTEM=="input", KERNEL=="event*", ATTRS{name}=="Fake Lid Switch", TAG+="power-switch"
EOF
    udevadm control --reload

    cat >/run/lidswitch.evemu <<EOF
# EVEMU 1.2
# Input device name: "Lid Switch"
# Input device ID: bus 0x19 vendor 0000 product 0x05 version 0000
# Supported events:
#   Event type 0 (EV_SYN)
#     Event code 0 (SYN_REPORT)
#     Event code 5 (FF_STATUS_MAX)
#   Event type 5 (EV_SW)
#     Event code 0 (SW_LID)
# Properties:
N: Fake Lid Switch
I: 0019 0000 0005 0000
P: 00 00 00 00 00 00 00 00
B: 00 21 00 00 00 00 00 00 00
B: 01 00 00 00 00 00 00 00 00
B: 01 00 00 00 00 00 00 00 00
B: 01 00 00 00 00 00 00 00 00
B: 01 00 00 00 00 00 00 00 00
B: 01 00 00 00 00 00 00 00 00
B: 01 00 00 00 00 00 00 00 00
B: 01 00 00 00 00 00 00 00 00
B: 01 00 00 00 00 00 00 00 00
B: 01 00 00 00 00 00 00 00 00
B: 01 00 00 00 00 00 00 00 00
B: 01 00 00 00 00 00 00 00 00
B: 01 00 00 00 00 00 00 00 00
B: 02 00 00 00 00 00 00 00 00
B: 03 00 00 00 00 00 00 00 00
B: 04 00 00 00 00 00 00 00 00
B: 05 01 00 00 00 00 00 00 00
B: 11 00 00 00 00 00 00 00 00
B: 12 00 00 00 00 00 00 00 00
B: 15 00 00 00 00 00 00 00 00
B: 15 00 00 00 00 00 00 00 00
EOF

    evemu-device /run/lidswitch.evemu &

    timeout 20 bash -c 'while ! grep "^Fake Lid Switch" /sys/class/input/*/device/name; do sleep .5; done'
    input_name=$(grep -l '^Fake Lid Switch' /sys/class/input/*/device/name || :)
    if [[ -z "$input_name" ]]; then
        echo "cannot find fake lid switch." >&2
        exit 1
    fi
    input_name=${input_name%/device/name}
    lid_dev=/dev/${input_name#/sys/class/}
    udevadm info --wait-for-initialization=10s "$lid_dev"
    udevadm settle

    # close lid
    evemu-event "$lid_dev" --sync --type 5 --code 0 --value 1
    # need to wait for 30s suspend inhibition after boot
    wait_suspend 31
    # open lid again
    evemu-event "$lid_dev" --sync --type 5 --code 0 --value 0

    # waiting for 30s inhibition time between suspends
    sleep 30

    # now closing lid should cause instant suspend
    evemu-event "$lid_dev" --sync --type 5 --code 0 --value 1
    wait_suspend 2
    evemu-event "$lid_dev" --sync --type 5 --code 0 --value 0

    assert_eq "$(systemctl show systemd-logind.service -p ExecMainPID --value)" "$pid"
}

test_shutdown() {
    local pid

    # save pid
    pid=$(systemctl show systemd-logind.service -p ExecMainPID --value)

    # scheduled shutdown with wall message
    shutdown 2>&1
    sleep 5
    shutdown -c || :
    # logind should still be running
    assert_eq "$(systemctl show systemd-logind.service -p ExecMainPID --value)" "$pid"

    # scheduled shutdown without wall message
    shutdown --no-wall 2>&1
    sleep 5
    shutdown -c --no-wall || true
    assert_eq "$(systemctl show systemd-logind.service -p ExecMainPID --value)" "$pid"
}

cleanup_session() (
    set +ex

    systemctl stop getty@tty2.service
    rm -rf /run/systemd/system/getty@tty2.service.d
    systemctl daemon-reload

    pkill -u "$(id -u logind-test-user)"
    sleep 1
    pkill -KILL -u "$(id -u logind-test-user)"
)

teardown_session() (
    set +ex

    cleanup_session

    rm -f /run/udev/rules.d/70-logindtest-scsi_debug-user.rules
    udevadm control --reload
    rmmod scsi_debug
)

check_session() (
    set +ex

    local seat session leader_pid

    if [[ $(loginctl --no-legend | grep -c "logind-test-user") != 1 ]]; then
        echo "no session or multiple sessions for logind-test-user." >&2
        return 1
    fi

    seat=$(loginctl --no-legend | grep 'logind-test-user *seat' | awk '{ print $4 }')
    if [[ -z "$seat" ]]; then
        echo "no seat found for user logind-test-user" >&2
        return 1
    fi

    session=$(loginctl --no-legend | grep "logind-test-user" | awk '{ print $1 }')
    if [[ -z "$session" ]]; then
        echo "no session found for user logind-test-user" >&2
        return 1
    fi

    if ! loginctl session-status "$session" | grep -q "Unit: session-${session}\.scope"; then
        echo "cannot find scope unit for session $session" >&2
        return 1
    fi

    leader_pid=$(loginctl session-status "$session" | grep "Leader:" | awk '{ print $2 }')
    if [[ -z "$leader_pid" ]]; then
        echo "cannot found leader process for session $session" >&2
        return 1
    fi

    # cgroup v1: "1:name=systemd:/user.slice/..."; unified hierarchy: "0::/user.slice"
    if ! grep -q -E '(name=systemd|^0:):.*session.*scope' /proc/"$leader_pid"/cgroup; then
        echo "FAIL: process $leader_pid is not in the session cgroup" >&2
        cat /proc/self/cgroup
        return 1
    fi
)

create_session() {
    # login with the test user to start a session
    mkdir -p /run/systemd/system/getty@tty2.service.d
    cat >/run/systemd/system/getty@tty2.service.d/override.conf <<EOF
[Service]
Type=simple
ExecStart=
ExecStart=-/sbin/agetty --autologin logind-test-user --noclear %I $TERM
EOF
    systemctl daemon-reload

    systemctl restart getty@tty2.service

    # check session
    for ((i = 0; i < 30; i++)); do
        (( i != 0 )) && sleep 1
        check_session && break
    done
    check_session
    assert_eq "$(loginctl --no-legend | awk '$3=="logind-test-user" { print $5 }')" "tty2"
}

test_session() {
    local dev

    if systemd-detect-virt --quiet --container; then
        echo "Skipping ACL tests in container"
        return
    fi

    if [[ ! -c /dev/tty2 ]]; then
        echo "/dev/tty2 does not exist, skipping test ${FUNCNAME[0]}."
        return
    fi

    trap teardown_session RETURN

    create_session

    # scsi_debug should not be loaded yet
    if [[ -d /sys/bus/pseudo/drivers/scsi_debug ]]; then
        echo "scsi_debug module is already loaded." >&2
        exit 1
    fi

    # we use scsi_debug to create new devices which we can put ACLs on
    # tell udev about the tagging, so that logind can pick it up
    mkdir -p /run/udev/rules.d
    cat >/run/udev/rules.d/70-logindtest-scsi_debug-user.rules <<EOF
SUBSYSTEM=="block", ATTRS{model}=="scsi_debug*", TAG+="uaccess"
EOF
    udevadm control --reload

    # coldplug: logind started with existing device
    systemctl stop systemd-logind.service
    modprobe scsi_debug
    timeout 30 bash -c 'while ! ls /sys/bus/pseudo/drivers/scsi_debug/adapter*/host*/target*/*:*/block 2>/dev/null; do sleep 1; done'
    dev=/dev/$(ls /sys/bus/pseudo/drivers/scsi_debug/adapter*/host*/target*/*:*/block 2>/dev/null)
    if [[ ! -b "$dev" ]]; then
        echo "cannot find suitable scsi block device" >&2
        exit 1
    fi
    udevadm settle
    udevadm info "$dev"

    # trigger logind and activate session
    loginctl activate "$(loginctl --no-legend | grep "logind-test-user" | awk '{ print $1 }')"

    # check ACL
    sleep 1
    assert_in "user:logind-test-user:rw-" "$(getfacl -p "$dev")"

    # hotplug: new device appears while logind is running
    rmmod scsi_debug
    modprobe scsi_debug
    timeout 30 bash -c 'while ! ls /sys/bus/pseudo/drivers/scsi_debug/adapter*/host*/target*/*:*/block 2>/dev/null; do sleep 1; done'
    dev=/dev/$(ls /sys/bus/pseudo/drivers/scsi_debug/adapter*/host*/target*/*:*/block 2>/dev/null)
    if [[ ! -b "$dev" ]]; then
        echo "cannot find suitable scsi block device" >&2
        exit 1
    fi
    udevadm settle

    # check ACL
    sleep 1
    assert_in "user:logind-test-user:rw-" "$(getfacl -p "$dev")"
}

: >/failed

setup_test_user
test_enable_debug
test_properties
test_started
test_suspend_on_lid
test_shutdown
test_session

touch /testok
rm /failed
