#!/bin/bash
######################################################################
# Name: check_raid_physical_server
# Description: Nagios plugin for MegaRAID RAID monitoring on physical servers
# Version: v1.6
######################################################################

# Note: ESXi SSL thumbprints are only used in ESXi scripts.

# Debug mode via environment variable: DEBUG=1 ./check_raid_physical_server_not_esxi
[ -z "$DEBUG" ] || set -x

# Skip check if NO_CHECK file exists (useful for maintenance windows)
[ -e /tmp/NO_CHECK ] && exit 0

######################################################################
# Configuration
######################################################################

PROGNAME=$(basename $0)
REVISION="v1.7"
STORCLI_BIN="/opt/MegaRAID/storcli/storcli64"
STORCLI="$STORCLI_BIN"
CONTROLLER="/c0"
TIMEOUT=60
ENABLE_PERFDATA=${ENABLE_PERFDATA:-0}
ENABLE_LONG_OUTPUT=${ENABLE_LONG_OUTPUT:-0}
TERSE_OUTPUT=${TERSE_OUTPUT:-1}

# Thresholds
TEMP_WARN=50      # Temperature warning threshold (Celsius)
TEMP_CRIT=60      # Temperature critical threshold (Celsius)
SSD_WEAR_WARN=20  # SSD wear level warning (% remaining)
SSD_WEAR_CRIT=10  # SSD wear level critical (% remaining)
MEDIA_ERROR_WARN=1   # Media error count warning threshold
MEDIA_ERROR_CRIT=10  # Media error count critical threshold
OTHER_ERROR_WARN=1   # Other error count warning threshold

# Nagios exit codes
STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3

# Performance data counters
PERF_VD_COUNT=0
PERF_VD_OK=0
PERF_VD_WARN=0
PERF_VD_CRIT=0
PERF_PD_COUNT=0
PERF_PD_OK=0
PERF_PD_WARN=0
PERF_PD_CRIT=0
PERF_SPARE_COUNT=0
PERF_MAX_TEMP=0
PERF_MEDIA_ERRORS=0
PERF_OTHER_ERRORS=0

# Warning/status collectors
WARNINGS=""
CRITICAL_WARNINGS=""
CTRL_STATUS=""
BATTERY_STATUS=""
BATTERY_WARNING=""
HOTSPARE_STATUS=""
REBUILD_STATUS=""
CC_STATUS=""
PATROL_STATUS=""
LONG_OUTPUT=""

######################################################################
# Functions
######################################################################

print_usage() {
    echo ""
    echo "Usage: $PROGNAME [vd-number] [-c controller] [-t timeout] [-h|--help] [-V|--version]"
    echo ""
    echo "Options:"
    echo "  vd-number       (Optional) Check specific virtual drive number"
    echo "  -c controller   (Optional) Controller number (default: 0)"
    echo "  -t timeout      (Optional) Timeout in seconds (default: 60)"
    echo "  -h, --help      Show this help"
    echo "  -V, --version   Show version"
    echo ""
    echo "Environment variables:"
    echo "  DEBUG=1         Enable debug output"
    echo "  ENABLE_PERFDATA=1   Include performance data in output (default: off)"
    echo "  ENABLE_LONG_OUTPUT=1 Include multi-line long output (default: off)"
    echo "  TERSE_OUTPUT=1  Minimize OK output (default: on)"
    echo ""
    echo "Files:"
    echo "  /tmp/NO_CHECK   If exists, script exits with OK (for maintenance)"
    echo ""
    echo "Checks performed:"
    echo "  - Virtual drive status"
    echo "  - Physical drive status and predictive failures"
    echo "  - Controller health"
    echo "  - Battery/CacheVault status"
    echo "  - Foreign configuration detection"
    echo "  - Hot spare availability"
    echo "  - SMART data (media errors, other errors, shield counter, BBM errors)"
    echo "  - Rebuild progress"
    echo "  - Consistency check status"
    echo "  - SSD wear level (warning at ${SSD_WEAR_WARN}%, critical at ${SSD_WEAR_CRIT}%)"
    echo "  - Drive temperature (warning at ${TEMP_WARN}C, critical at ${TEMP_CRIT}C)"
    echo "  - Patrol read status"
    echo ""
}

print_version() {
    echo "$PROGNAME $REVISION"
}

translate_status() {
    local status=$1
    case $status in
        Optl) echo "Optimal" ;;
        Dgrd) echo "Degraded" ;;
        Rbld) echo "Rebuilding" ;;
        Offln) echo "Offline" ;;
        OfLn) echo "Offline" ;;
        Pdgd) echo "Partially Degraded" ;;
        Rec) echo "Recovering" ;;
        Failed) echo "Failed" ;;
        Msng) echo "Missing" ;;
        Onln) echo "Online" ;;
        UBad) echo "Unconfigured Bad" ;;
        *) echo "$status" ;;
    esac
}

# Check controller health
check_controller_health() {
    ctrl_check=$($STORCLI $CONTROLLER show 2>&1)

    if echo "$ctrl_check" | grep -qi "Controller Status"; then
        ctrl_state=$(echo "$ctrl_check" | grep -i "Controller Status" | awk -F: '{print $2}' | xargs | head -1)
        if [ ! -z "$ctrl_state" ]; then
            if echo "$ctrl_state" | grep -qiE "Optimal|OK|Good"; then
                CTRL_STATUS="Controller:OK"
            else
                CTRL_STATUS="Controller:$ctrl_state"
                WARNINGS="${WARNINGS} Controller status: $ctrl_state"
            fi
        fi
    fi
}

# Check battery/cachevault status
check_battery() {
    # Check cachevault
    cv_check=$($STORCLI $CONTROLLER/cv show 2>&1)
    if echo "$cv_check" | grep -qiE "State|Status"; then
        cv_state=$(echo "$cv_check" | awk -F'[:=]' 'BEGIN{IGNORECASE=1} /State|Status/ {print $2; exit}' | xargs)
    else
        cv_state=""
    fi
    if echo "$cv_check" | grep -qi "Unsupported Command"; then
        cv_state=""
    fi
    if [ -z "$cv_state" ]; then
        cv_check=$($STORCLI cv show -i ${CONTROLLER#/c} 2>&1)
        cv_state=$(echo "$cv_check" | awk -F'[:=]' 'BEGIN{IGNORECASE=1} /State|Status/ {print $2; exit}' | xargs)
        if echo "$cv_check" | grep -qi "Unsupported Command"; then
            cv_state=""
        fi
    fi
    if [ -z "$cv_state" ]; then
        ctrl_check=$($STORCLI $CONTROLLER show 2>&1)
        cv_state=$(echo "$ctrl_check" | awk -F'[:=]' 'BEGIN{IGNORECASE=1} /CacheVault/ && /State|Status/ {print $2; exit}' | xargs)
    fi
    if [ ! -z "$cv_state" ]; then
        if echo "$cv_state" | grep -qiE "Optimal|Good"; then
            BATTERY_STATUS="CV:OK"
        elif echo "$cv_state" | grep -qiE "Learning|Charging"; then
            BATTERY_STATUS="CV:$cv_state"
            BATTERY_WARNING="CacheVault $cv_state"
        else
            BATTERY_STATUS="CV:$cv_state"
            BATTERY_WARNING="CacheVault $cv_state"
        fi
    fi

    # Check BBU
    bbu_check=$($STORCLI $CONTROLLER/bbu show 2>&1)
    if echo "$bbu_check" | grep -qiE "State|Status"; then
        bbu_state=$(echo "$bbu_check" | awk -F'[:=]' 'BEGIN{IGNORECASE=1} /State|Status/ {print $2; exit}' | xargs)
    else
        bbu_state=""
    fi
    if echo "$bbu_check" | grep -qi "Unsupported Command"; then
        bbu_state=""
    fi
    if [ -z "$bbu_state" ]; then
        bbu_check=$($STORCLI bbu show -i ${CONTROLLER#/c} 2>&1)
        bbu_state=$(echo "$bbu_check" | awk -F'[:=]' 'BEGIN{IGNORECASE=1} /State|Status/ {print $2; exit}' | xargs)
        if echo "$bbu_check" | grep -qi "Unsupported Command"; then
            bbu_state=""
        fi
    fi
    if [ -z "$bbu_state" ]; then
        if [ -z "$ctrl_check" ]; then
            ctrl_check=$($STORCLI $CONTROLLER show 2>&1)
        fi
        bbu_state=$(echo "$ctrl_check" | awk -F'[:=]' 'BEGIN{IGNORECASE=1} /(BBU|Battery)/ && /State|Status/ {print $2; exit}' | xargs)
    fi
    if [ ! -z "$bbu_state" ]; then
        if echo "$bbu_state" | grep -qiE "Optimal|Good|OK"; then
            BATTERY_STATUS="${BATTERY_STATUS} BBU:OK"
        elif echo "$bbu_state" | grep -qiE "Learning|Charging"; then
            BATTERY_STATUS="${BATTERY_STATUS} BBU:$bbu_state"
            BATTERY_WARNING="${BATTERY_WARNING} BBU $bbu_state"
        else
            BATTERY_STATUS="${BATTERY_STATUS} BBU:$bbu_state"
            BATTERY_WARNING="${BATTERY_WARNING} BBU $bbu_state"
        fi
    fi
    # Fallback: parse Energy Pack status from controller summary if CV/BBU not available
    if [ -z "$BATTERY_STATUS" ]; then
        ctrl_summary=$($STORCLI $CONTROLLER show all 2>&1)
        ep_present=$(echo "$ctrl_summary" | awk -F'=' 'BEGIN{IGNORECASE=1} /Energy Pack =/ {print $2; exit}' | xargs)
        ep_status=$(echo "$ctrl_summary" | awk -F'=' 'BEGIN{IGNORECASE=1} /Energy Pack Status/ {print $2; exit}' | xargs)
        if [ ! -z "$ep_present" ] || [ ! -z "$ep_status" ]; then
            if echo "$ep_present" | grep -qiE "Present|Yes"; then
                if [ -z "$ep_status" ] || [ "$ep_status" = "0" ] || echo "$ep_status" | grep -qiE "OK|Optimal|Good"; then
                    BATTERY_STATUS="Cache:OK Battery:OK"
                else
                    BATTERY_STATUS="Cache:EP${ep_status} Battery:EP${ep_status}"
                    BATTERY_WARNING="Energy Pack status ${ep_status}"
                fi
            elif echo "$ep_present" | grep -qiE "Absent|No"; then
                BATTERY_WARNING="Energy Pack Absent"
            fi
        fi
    fi

    BATTERY_STATUS=$(echo "$BATTERY_STATUS" | xargs)
    BATTERY_WARNING=$(echo "$BATTERY_WARNING" | xargs)
}

# Check for foreign configurations
check_foreign_config() {
    foreign_check=$($STORCLI $CONTROLLER/fall show 2>&1)
    if echo "$foreign_check" | grep -qiE "foreign configuration|DG"; then
        foreign_count=$(echo "$foreign_check" | grep -E "^[0-9]+" | wc -l)
        if [ "$foreign_count" -gt 0 ]; then
            WARNINGS="${WARNINGS} Foreign config detected ($foreign_count)"
        fi
    fi
}

# Check hot spare status
check_hotspare() {
    pd_output=$($STORCLI $CONTROLLER/eall/sall show 2>&1)
    spare_ok=$(echo "$pd_output" | grep -iE "DHS|GHS" | wc -l)
    ugood_count=$(echo "$pd_output" | grep -i "UGood" | wc -l)

    PERF_SPARE_COUNT=$spare_ok

    if [ "$spare_ok" -gt 0 ]; then
        HOTSPARE_STATUS="Spares:$spare_ok"
    elif [ "$ugood_count" -gt 0 ]; then
        HOTSPARE_STATUS="UGood:$ugood_count"
    else
        HOTSPARE_STATUS="Spares:0"
        if [ "$PERF_PD_COUNT" -gt 2 ]; then
            WARNINGS="${WARNINGS} No hot spares configured"
        fi
    fi
}

# Check for predictive failures
check_predictive_failure() {
    pd_detail=$($STORCLI $CONTROLLER/eall/sall show all 2>&1)

    # Check for predictive failure
    if echo "$pd_detail" | grep -qi "Predictive.*Yes"; then
        pred_drives=$(echo "$pd_detail" | grep -B10 "Predictive.*Yes" | grep -E "^[0-9]+:[0-9]+" | awk '{print $1}' | xargs)
        if [ ! -z "$pred_drives" ]; then
            WARNINGS="${WARNINGS} Predictive failure on: $pred_drives"
        fi
    fi
}

# Check SMART data (media errors, bad blocks, other errors)
check_smart_data() {
    pd_detail=$($STORCLI $CONTROLLER/eall/sall show all 2>&1)
    pd_list=$($STORCLI $CONTROLLER/eall/sall show | grep -E "^[0-9]+:[0-9]+" | awk '{print $1}')

    total_media_errors=0
    total_other_errors=0
    drives_with_errors=""

    for drive in $pd_list; do
        # Extract SMART data for this drive
        drive_section=$(echo "$pd_detail" | grep -A50 "^Drive.*$drive\|^$drive" | head -50)

        # Get media error count
        media_count=$(echo "$drive_section" | grep -i "Media Error" | grep -oE "[0-9]+" | head -1)
        if [ ! -z "$media_count" ] && [ "$media_count" -gt 0 ]; then
            total_media_errors=$((total_media_errors + media_count))
            if [ "$media_count" -ge "$MEDIA_ERROR_CRIT" ]; then
                CRITICAL_WARNINGS="${CRITICAL_WARNINGS} Drive $drive: $media_count media errors"
                drives_with_errors="${drives_with_errors} $drive(ME:$media_count)"
            elif [ "$media_count" -ge "$MEDIA_ERROR_WARN" ]; then
                WARNINGS="${WARNINGS} Drive $drive: $media_count media errors"
                drives_with_errors="${drives_with_errors} $drive(ME:$media_count)"
            fi
        fi

        # Get other error count
        other_count=$(echo "$drive_section" | grep -i "Other Error" | grep -oE "[0-9]+" | head -1)
        if [ ! -z "$other_count" ] && [ "$other_count" -gt 0 ]; then
            total_other_errors=$((total_other_errors + other_count))
            if [ "$other_count" -ge "$OTHER_ERROR_WARN" ]; then
                WARNINGS="${WARNINGS} Drive $drive: $other_count other errors"
                drives_with_errors="${drives_with_errors} $drive(OE:$other_count)"
            fi
        fi

        # Check shield counter (uncorrectable errors)
        shield_count=$(echo "$drive_section" | grep -i "Shield Counter" | grep -oE "[0-9]+" | head -1)
        if [ ! -z "$shield_count" ] && [ "$shield_count" -gt 0 ]; then
            WARNINGS="${WARNINGS} Drive $drive: $shield_count shield errors"
            drives_with_errors="${drives_with_errors} $drive(SC:$shield_count)"
        fi

        # Check BBM (Bad Block Management) error count
        bbm_count=$(echo "$drive_section" | grep -i "BBM Error" | grep -oE "[0-9]+" | head -1)
        if [ ! -z "$bbm_count" ] && [ "$bbm_count" -gt 0 ]; then
            WARNINGS="${WARNINGS} Drive $drive: $bbm_count BBM errors"
            drives_with_errors="${drives_with_errors} $drive(BBM:$bbm_count)"
        fi
    done

    # Store totals for performance data
    PERF_MEDIA_ERRORS=$total_media_errors
    PERF_OTHER_ERRORS=$total_other_errors
}

# Check rebuild progress
check_rebuild_progress() {
    if $STORCLI $CONTROLLER/vall show | grep -qE " Rbld "; then
        rebuild_info=$($STORCLI $CONTROLLER/vall show rebuild 2>&1)
        rebuild_progress=$(echo "$rebuild_info" | grep -i "Progress" | grep -oE "[0-9]+%" | head -1)
        if [ ! -z "$rebuild_progress" ]; then
            REBUILD_STATUS="Rebuild:${rebuild_progress}"
        else
            REBUILD_STATUS="Rebuild:InProgress"
        fi
    fi
}

# Check consistency check status
check_consistency_check() {
    cc_info=$($STORCLI $CONTROLLER/vall show cc 2>&1)
    if echo "$cc_info" | grep -qiE "[0-9]+%|in progress"; then
        cc_progress=$(echo "$cc_info" | grep -oE "[0-9]+%" | head -1)
        if [ ! -z "$cc_progress" ]; then
            CC_STATUS="CC:${cc_progress}"
        else
            CC_STATUS="CC:Running"
        fi
    fi
}

# Check SSD wear level
check_ssd_wear() {
    pd_detail=$($STORCLI $CONTROLLER/eall/sall show all 2>&1)
    ssd_drives=$($STORCLI $CONTROLLER/eall/sall show | grep -i "SSD" | awk '{print $1}')

    if [ ! -z "$ssd_drives" ]; then
        for drive in $ssd_drives; do
            wear_level=$(echo "$pd_detail" | grep -A30 "^Drive $drive" | grep -iE "Life Left|Wear|Wearout" | grep -oE "[0-9]+" | head -1)
            if [ ! -z "$wear_level" ]; then
                if [ "$wear_level" -le "$SSD_WEAR_CRIT" ]; then
                    CRITICAL_WARNINGS="${CRITICAL_WARNINGS} SSD $drive wear critical (${wear_level}% left)"
                elif [ "$wear_level" -le "$SSD_WEAR_WARN" ]; then
                    WARNINGS="${WARNINGS} SSD $drive wear warning (${wear_level}% left)"
                fi
            fi
        done
    fi
}

# Check drive temperature
check_drive_temperature() {
    pd_detail=$($STORCLI $CONTROLLER/eall/sall show all 2>&1)
    temps=$(echo "$pd_detail" | grep -i "Drive Temperature" | grep -oE "[0-9]+" | head -20)

    max_temp=0
    for temp in $temps; do
        if [ "$temp" -gt 0 ] && [ "$temp" -lt 100 ]; then
            if [ "$temp" -gt "$max_temp" ]; then
                max_temp=$temp
            fi
            if [ "$temp" -ge "$TEMP_CRIT" ]; then
                CRITICAL_WARNINGS="${CRITICAL_WARNINGS} Drive overheating (${temp}C)"
            elif [ "$temp" -ge "$TEMP_WARN" ]; then
                WARNINGS="${WARNINGS} Drive temperature high (${temp}C)"
            fi
        fi
    done
    PERF_MAX_TEMP=$max_temp
}

# Check patrol read status
check_patrol_read() {
    pr_check=$($STORCLI $CONTROLLER show patrolread 2>&1)
    pr_state=$(echo "$pr_check" | grep -i "State" | awk -F: '{print $2}' | xargs | head -1)

    if [ ! -z "$pr_state" ]; then
        if echo "$pr_state" | grep -qiE "Active|Running"; then
            pr_progress=$(echo "$pr_check" | grep -i "Progress" | grep -oE "[0-9]+%" | head -1)
            if [ ! -z "$pr_progress" ]; then
                PATROL_STATUS="PR:${pr_progress}"
            else
                PATROL_STATUS="PR:Running"
            fi
        elif echo "$pr_state" | grep -qiE "Stopped|Paused"; then
            PATROL_STATUS="PR:Stopped"
        fi
    fi
}

# Build performance data
build_perfdata() {
    vd_output=$($STORCLI $CONTROLLER/vall show 2>&1)
    PERF_VD_COUNT=$(echo "$vd_output" | grep -E "^[0-9]+/[0-9]+" | wc -l)
    PERF_VD_OK=$(echo "$vd_output" | grep -E "^[0-9]+/[0-9]+" | grep -E " Optl " | wc -l)
    PERF_VD_WARN=$(echo "$vd_output" | grep -E "^[0-9]+/[0-9]+" | grep -E " (Rbld|Pdgd) " | wc -l)
    PERF_VD_CRIT=$(echo "$vd_output" | grep -E "^[0-9]+/[0-9]+" | grep -E " (Dgrd|OfLn|Offln|Failed) " | wc -l)

    pd_output=$($STORCLI $CONTROLLER/eall/sall show 2>&1)
    PERF_PD_COUNT=$(echo "$pd_output" | grep -E "^[0-9]+:[0-9]+" | wc -l)
    PERF_PD_OK=$(echo "$pd_output" | grep -E "^[0-9]+:[0-9]+" | grep -E " Onln " | wc -l)
    PERF_PD_WARN=$(echo "$pd_output" | grep -E "^[0-9]+:[0-9]+" | grep -E " Rbld " | wc -l)
    PERF_PD_CRIT=$(echo "$pd_output" | grep -E "^[0-9]+:[0-9]+" | grep -E " (Offln|Failed|UBad|Msng) " | wc -l)

    PERFDATA="| vd_total=$PERF_VD_COUNT vd_ok=$PERF_VD_OK vd_warn=$PERF_VD_WARN vd_crit=$PERF_VD_CRIT pd_total=$PERF_PD_COUNT pd_ok=$PERF_PD_OK pd_warn=$PERF_PD_WARN pd_crit=$PERF_PD_CRIT spares=$PERF_SPARE_COUNT max_temp=${PERF_MAX_TEMP}C media_errors=$PERF_MEDIA_ERRORS other_errors=$PERF_OTHER_ERRORS"
    if [ "$ENABLE_PERFDATA" != "1" ]; then
        PERFDATA=""
    fi
}

# Build long output for Nagios
build_long_output() {
    LONG_OUTPUT="\n--- Virtual Drives ---"
    vd_lines=$($STORCLI $CONTROLLER/vall show | grep -E "^[0-9]+/[0-9]+")
    while IFS= read -r line; do
        if [ ! -z "$line" ]; then
            vd_num=$(echo "$line" | awk '{print $1}')
            vd_type=$(echo "$line" | awk '{print $2}')
            vd_state=$(echo "$line" | awk '{print $3}')
            vd_name=$(echo "$line" | awk '{print $NF}')
            LONG_OUTPUT="${LONG_OUTPUT}\nVD$vd_num: $vd_type $vd_state ($vd_name)"
        fi
    done <<< "$vd_lines"

    LONG_OUTPUT="${LONG_OUTPUT}\n\n--- Status ---"
    [ ! -z "$CTRL_STATUS" ] && LONG_OUTPUT="${LONG_OUTPUT}\nController: $CTRL_STATUS"
    [ ! -z "$BATTERY_STATUS" ] && LONG_OUTPUT="${LONG_OUTPUT}\nBattery: $BATTERY_STATUS"
    [ ! -z "$HOTSPARE_STATUS" ] && LONG_OUTPUT="${LONG_OUTPUT}\nHot Spares: $HOTSPARE_STATUS"
    [ ! -z "$PATROL_STATUS" ] && LONG_OUTPUT="${LONG_OUTPUT}\nPatrol Read: $PATROL_STATUS"
    [ ! -z "$CC_STATUS" ] && LONG_OUTPUT="${LONG_OUTPUT}\nConsistency Check: $CC_STATUS"
    [ ! -z "$REBUILD_STATUS" ] && LONG_OUTPUT="${LONG_OUTPUT}\nRebuild: $REBUILD_STATUS"
    [ "$PERF_MAX_TEMP" -gt 0 ] && LONG_OUTPUT="${LONG_OUTPUT}\nMax Temperature: ${PERF_MAX_TEMP}C"
}

######################################################################
# Main
######################################################################

# Parse arguments
VD_NUM=""
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            print_usage
            exit 0
            ;;
        -V|--version)
            print_version
            exit 0
            ;;
        -c)
            CONTROLLER="/c$2"
            shift 2
            ;;
        -t)
            TIMEOUT="$2"
            shift 2
            ;;
        *)
            if [ -z "$VD_NUM" ] && echo "$1" | grep -qE "^[0-9]+$"; then
                VD_NUM="$1"
            fi
            shift
            ;;
    esac
done

# Build storcli command with timeout if available
if command -v timeout >/dev/null 2>&1; then
    STORCLI="timeout $TIMEOUT $STORCLI_BIN"
else
    STORCLI="$STORCLI_BIN"
fi

# Check if storcli exists
if [ ! -x "$STORCLI_BIN" ]; then
    echo "RAID UNKNOWN - storcli64 not found at $STORCLI_BIN"
    exit $STATE_UNKNOWN
fi

# Run all checks
check_controller_health
check_battery
check_foreign_config
check_predictive_failure
check_smart_data
check_rebuild_progress
check_consistency_check
check_ssd_wear
check_drive_temperature
check_patrol_read
build_perfdata
check_hotspare
if [ "$ENABLE_LONG_OUTPUT" = "1" ]; then
    build_long_output
fi

# Check specific VD if requested
if [ ! -z "$VD_NUM" ]; then
    VD_LINE=$($STORCLI $CONTROLLER/vall show | grep -E "^[0-9]+/$VD_NUM ")
    VD_STATUS=$(echo "$VD_LINE" | awk '{print $3}')
    VD_NAME=$(echo "$VD_LINE" | awk '{print $NF}')

    if [ -z "$VD_STATUS" ]; then
        echo "RAID CRITICAL - Virtual Drive $VD_NUM not found"
        exit $STATE_CRITICAL
    fi

    if [ "$VD_STATUS" != "Optl" ]; then
        READABLE_STATUS=$(translate_status "$VD_STATUS")
        PROBLEM_DISKS=$($STORCLI $CONTROLLER/vall show all | awk -v vd="$VD_NUM" '
            /^PDs for VD/ && $4 == vd {flag=1; next}
            flag && /^-----------/ {next}
            flag && /^EID=/ {flag=0}
            flag && /^[0-9]+:[0-9]+/ {
                if ($3 ~ /Rbld|Offln|Failed|Dgrd|UBad|Msng/) {
                    split($1, a, ":")
                    print "Bay" a[2] " Status:" $3
                }
            }
        ' | xargs)

        if [ "$TERSE_OUTPUT" = "1" ]; then
            printf "RAID CRITICAL - VD$VD_NUM $READABLE_STATUS\n"
        else
            if [ ! -z "$PROBLEM_DISKS" ]; then
                PROBLEM_DISKS_READABLE=$(echo "$PROBLEM_DISKS" | sed 's/Status:Rbld/Status:Rebuilding/g; s/Status:Offln/Status:Offline/g; s/Status:Failed/Status:Failed/g; s/Status:Msng/Status:Missing/g')
                printf "RAID CRITICAL - VD$VD_NUM ($VD_NAME) Status: $READABLE_STATUS - PROBLEM: $PROBLEM_DISKS_READABLE $PERFDATA$LONG_OUTPUT\n"
            else
                printf "RAID CRITICAL - VD$VD_NUM ($VD_NAME) Status: $READABLE_STATUS $PERFDATA$LONG_OUTPUT\n"
            fi
        fi
        exit $STATE_CRITICAL
    else
        if [ "$TERSE_OUTPUT" = "1" ]; then
            printf "RAID OK\n"
        else
            printf "RAID OK - VD$VD_NUM ($VD_NAME) Status: Optimal $PERFDATA$LONG_OUTPUT\n"
        fi
        exit $STATE_OK
    fi
fi

# Check all VDs
VD_CRITICAL=$($STORCLI $CONTROLLER/vall show | grep -E "^[0-9]+" | grep -v "Optl")

if [ ! -z "$VD_CRITICAL" ]; then
    FAILED_VD=$(echo "$VD_CRITICAL" | awk '{print $1}' | cut -d'/' -f2 | head -1)
    VD_STATUS=$(echo "$VD_CRITICAL" | awk '{print $3}' | head -1)
    VD_NAME=$(echo "$VD_CRITICAL" | awk '{print $NF}' | head -1)
    READABLE_STATUS=$(translate_status "$VD_STATUS")

    PROBLEM_DISKS=$($STORCLI $CONTROLLER/vall show all | awk -v vd="$FAILED_VD" '
        /^PDs for VD/ && $4 == vd {flag=1; next}
        flag && /^-----------/ {next}
        flag && /^EID=/ {flag=0}
        flag && /^[0-9]+:[0-9]+/ {
            if ($3 ~ /Rbld|Offln|Failed|Dgrd|UBad|Msng/) {
                split($1, a, ":")
                print "Bay" a[2] " Status:" $3
            }
        }
    ' | xargs)

    rebuild_info=""
    [ ! -z "$REBUILD_STATUS" ] && rebuild_info=" [$REBUILD_STATUS]"

    case "$VD_STATUS" in
        Rbld|Pdgd)
            if [ "$TERSE_OUTPUT" = "1" ]; then
                printf "RAID WARNING - VD$FAILED_VD $READABLE_STATUS\n"
            else
                if [ ! -z "$PROBLEM_DISKS" ]; then
                    PROBLEM_DISKS_READABLE=$(echo "$PROBLEM_DISKS" | sed 's/Status:Rbld/Status:Rebuilding/g; s/Status:Offln/Status:Offline/g')
                    printf "RAID WARNING - VD$FAILED_VD ($VD_NAME) Status: $READABLE_STATUS$rebuild_info - PROBLEM: $PROBLEM_DISKS_READABLE $PERFDATA$LONG_OUTPUT\n"
                else
                    printf "RAID WARNING - VD$FAILED_VD ($VD_NAME) Status: $READABLE_STATUS$rebuild_info $PERFDATA$LONG_OUTPUT\n"
                fi
            fi
            exit $STATE_WARNING
            ;;
        *)
            if [ "$TERSE_OUTPUT" = "1" ]; then
                printf "RAID CRITICAL - VD$FAILED_VD $READABLE_STATUS\n"
            else
                if [ ! -z "$PROBLEM_DISKS" ]; then
                    PROBLEM_DISKS_READABLE=$(echo "$PROBLEM_DISKS" | sed 's/Status:Rbld/Status:Rebuilding/g; s/Status:Offln/Status:Offline/g; s/Status:Failed/Status:Failed/g; s/Status:Msng/Status:Missing/g')
                    printf "RAID CRITICAL - VD$FAILED_VD ($VD_NAME) Status: $READABLE_STATUS - PROBLEM: $PROBLEM_DISKS_READABLE $PERFDATA$LONG_OUTPUT\n"
                else
                    printf "RAID CRITICAL - VD$FAILED_VD ($VD_NAME) Status: $READABLE_STATUS $PERFDATA$LONG_OUTPUT\n"
                fi
            fi
            exit $STATE_CRITICAL
            ;;
    esac
fi

# Check for critical warnings (SSD wear, temperature)
if [ ! -z "$CRITICAL_WARNINGS" ]; then
    crit_warnings=$(echo "$CRITICAL_WARNINGS" | xargs)
    if [ "$TERSE_OUTPUT" = "1" ]; then
        printf "RAID CRITICAL - $crit_warnings\n"
    else
        VD_INFO=$($STORCLI $CONTROLLER/vall show | grep -E "^[0-9]+" | awk '{print "VD"$1":Optimal"}' | xargs | sed 's/ /, /g')
        printf "RAID CRITICAL - VDs Optimal but: $crit_warnings ($VD_INFO) $PERFDATA$LONG_OUTPUT\n"
    fi
    exit $STATE_CRITICAL
fi

# Check for warnings
all_warnings=""
[ ! -z "$BATTERY_WARNING" ] && all_warnings="${all_warnings} ${BATTERY_WARNING}"
[ ! -z "$WARNINGS" ] && all_warnings="${all_warnings} ${WARNINGS}"
all_warnings=$(echo "$all_warnings" | xargs)

if [ ! -z "$all_warnings" ]; then
    if [ "$TERSE_OUTPUT" = "1" ]; then
        printf "RAID WARNING - $all_warnings\n"
    else
        VD_INFO=$($STORCLI $CONTROLLER/vall show | grep -E "^[0-9]+" | awk '{print "VD"$1":Optimal"}' | xargs | sed 's/ /, /g')
        printf "RAID WARNING - VDs Optimal but: $all_warnings ($VD_INFO) $PERFDATA$LONG_OUTPUT\n"
    fi
    exit $STATE_WARNING
fi

# All OK
VD_COUNT=$($STORCLI $CONTROLLER/vall show | grep -E "^[0-9]+" | wc -l)
VD_INFO=$($STORCLI $CONTROLLER/vall show | grep -E "^[0-9]+" | awk '{print "VD"$1":Optimal"}' | xargs | sed 's/ /, /g')

extra_info=""
[ ! -z "$BATTERY_STATUS" ] && extra_info=" $BATTERY_STATUS"
[ ! -z "$CTRL_STATUS" ] && { [ -z "$extra_info" ] && extra_info=" $CTRL_STATUS" || extra_info="${extra_info} $CTRL_STATUS"; }
[ ! -z "$HOTSPARE_STATUS" ] && { [ -z "$extra_info" ] && extra_info=" $HOTSPARE_STATUS" || extra_info="${extra_info} $HOTSPARE_STATUS"; }
[ ! -z "$CC_STATUS" ] && { [ -z "$extra_info" ] && extra_info=" $CC_STATUS" || extra_info="${extra_info} $CC_STATUS"; }
[ ! -z "$PATROL_STATUS" ] && { [ -z "$extra_info" ] && extra_info=" $PATROL_STATUS" || extra_info="${extra_info} $PATROL_STATUS"; }
[ "$PERF_MAX_TEMP" -gt 0 ] && { [ -z "$extra_info" ] && extra_info=" Temp:${PERF_MAX_TEMP}C" || extra_info="${extra_info} Temp:${PERF_MAX_TEMP}C"; }

if [ "$TERSE_OUTPUT" = "1" ]; then
    printf "RAID OK\n"
else
    printf "RAID OK - All $VD_COUNT Virtual Drives Optimal ($VD_INFO)$extra_info $PERFDATA$LONG_OUTPUT\n"
fi
exit $STATE_OK
