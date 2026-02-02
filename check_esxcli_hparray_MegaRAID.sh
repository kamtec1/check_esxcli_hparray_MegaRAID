#! /bin/sh
# Debug mode via environment variable: DEBUG=1 ./check_esxi_raid65 ...
[ -z "$DEBUG" ] || set -x

# Skip check if NO_CHECK file exists (useful for maintenance windows)
[ -e /tmp/NO_CHECK ] && exit 0

######################################################################
# Name: check_esxcli_hparray
# By: Copyright (C) 2012 iceburn
# Credits to: andreiw, Magnus Glantz
######################################################################
# Licence: GPL 2.0
######################################################################
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
######################################################################
# Description:
#
#  A Nagios plugin that checks HP Proliant hardware raid via the
# VMWare ESXCLI tool on ESXi servers with the HP Util Bundle installed.
#
# Supports:
#  - HP Smart Array controllers (ssacli) - Gen10 and older
#  - HPE MegaRAID controllers (storcli) - Gen10P and Gen11
#
# This is based on the check_hparray plugin but with the checking
# order corrected in order to avoid false positives.
#
######################################################################

# ESXi SSL thumbprints (edit this list)
set_thumbprint() {
        case "$HOST" in
                10.10.10.10)
                        thumb="55:45:DE:29:38:59:0F:02:F3:1D:57:81:38:99:68:96:37:BE:89:E2"
                        ;;
                10.10.10.20)
                        thumb="5E:BF:B4:AF:A4:7E:F9:CF:71:D2:AB:16:86:68:80:A2:49:59:80:8B"
                        ;;
                10.10.10.30)
                        thumb="DD:B5:4F:11:FA:8B:09:2A:40:3E:28:C0:AE:C0:08:68:E3:EC:E1:A8"
                        ;;
                *)
                        thumb=""
                        ;;
        esac
}

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
PROGNAME=`basename $0`
PROGPATH=`echo $0 | sed -e 's,[\\/][^\\/][^\\/]*$,,'`
REVISION=v1.7
ESXCLI=/opt/vmware-vsphere-cli-distrib/lib/bin/esxcli/esxcli
TIMEOUT=60
ENABLE_PERFDATA=${ENABLE_PERFDATA:-0}
ENABLE_LONG_OUTPUT=${ENABLE_LONG_OUTPUT:-0}
SHOW_HOST=${SHOW_HOST:-0}
TERSE_OUTPUT=${TERSE_OUTPUT:-1}

# Thresholds
TEMP_WARN=50      # Temperature warning threshold (Celsius)
TEMP_CRIT=60      # Temperature critical threshold (Celsius)
SSD_WEAR_WARN=20  # SSD wear level warning (% remaining)
SSD_WEAR_CRIT=10  # SSD wear level critical (% remaining)
MEDIA_ERROR_WARN=1   # Media error count warning threshold
MEDIA_ERROR_CRIT=10  # Media error count critical threshold
OTHER_ERROR_WARN=1   # Other error count warning threshold

STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3
STATE_DEPENDENT=4

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
CTRL_COUNT=0
REBUILD_STATUS=""
CC_STATUS=""
BATTERY_STATUS=""
BATTERY_WARNING=""

print_usage() {
        echo ""
        echo "Usage: $PROGNAME -h <host> -u <username> [-v <vd-number>] [-c <controller>] [-t <timeout>]"
        echo "Usage: $PROGNAME [--help]"
        echo "Usage: $PROGNAME [-V | --version]"
        echo ""
        echo "Options:"
        echo "  -h <host>       ESXi host IP address"
        echo "  -u <username>   Username for ESXi connection"
        echo "  -v <vd-number>  (Optional) Check specific virtual drive number"
        echo "  -c <controller> (Optional) Controller ID (default: all, or specify 0, 1, etc.)"
        echo "  -t <timeout>    (Optional) Timeout in seconds (default: 60)"
        echo ""
        echo "Environment variables:"
        echo "  DEBUG=1         Enable debug output"
        echo "  ENABLE_PERFDATA=1   Include performance data in output (default: off)"
        echo "  ENABLE_LONG_OUTPUT=1 Include multi-line long output (default: off)"
        echo "  SHOW_HOST=1     Append host to output (default: off)"
        echo "  TERSE_OUTPUT=1  Minimize OK output (default: on)"
        echo ""
        echo "Files:"
        echo "  /tmp/NO_CHECK   If exists, script exits with OK (for maintenance)"
        echo ""
        echo "Checks performed:"
        echo "  - Virtual drive status"
        echo "  - Physical drive status and predictive failures"
        echo "  - Controller health"
        echo "  - Write cache status"
        echo "  - Foreign configuration detection"
        echo "  - Hot spare availability"
        echo "  - Battery/CacheVault status"
        echo "  - SMART data (media errors, other errors, shield counter, BBM errors)"
        echo "  - Rebuild progress (shows % when rebuilding)"
        echo "  - Consistency check status"
        echo "  - SSD wear level (warning at ${SSD_WEAR_WARN}%, critical at ${SSD_WEAR_CRIT}%)"
        echo "  - Drive temperature (warning at ${TEMP_WARN}C, critical at ${TEMP_CRIT}C)"
        echo "  - Patrol read status"
        echo ""
        echo "Long output: Detailed multi-line output is included for Nagios web interface."
        echo ""
}

print_help() {
        print_revision $PROGNAME $REVISION
        echo ""
        print_usage
        echo ""
        echo "This plugin checks hardware status for HP Proliant running ESXi servers using ESXCLI utility."
        echo "Supports both HP Smart Array (ssacli) and HPE MegaRAID (storcli) controllers."
        echo ""
        exit 0
}

print_revision() {
        echo $1" "$2
}

# Function to translate status codes to readable names
translate_status() {
        status=$1
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

check_cache_battery_ssacli()
{
        # Query controller status for cache/battery info (best effort)
        status_check=`timeout $TIMEOUT $ESXCLI -s $HOST -u $USER -d $thumb ssacli cmd -q "controller slot=0 show status" 2>&1`

        cache_state=`echo "$status_check" | awk -F'[:=]' 'BEGIN{IGNORECASE=1} /Cache Status/ {print $2; exit}' | xargs`
        battery_state=`echo "$status_check" | awk -F'[:=]' 'BEGIN{IGNORECASE=1} /Battery\\/Capacitor Status|Battery Status|Capacitor Status/ {print $2; exit}' | xargs`

        battery_status=""
        battery_warning=""

        if [ ! -z "$cache_state" ]; then
                battery_status="Cache:$cache_state"
                if ! echo "$cache_state" | grep -qiE "OK|Optimal|Good"; then
                        battery_warning="Cache $cache_state"
                fi
        fi

        if [ ! -z "$battery_state" ]; then
                if [ -z "$battery_status" ]; then
                        battery_status="Battery:$battery_state"
                else
                        battery_status="${battery_status} Battery:$battery_state"
                fi
                if ! echo "$battery_state" | grep -qiE "OK|Optimal|Good"; then
                        battery_warning="${battery_warning} Battery $battery_state"
                fi
        fi

        BATTERY_STATUS=`echo "$battery_status" | xargs`
        BATTERY_WARNING=`echo "$battery_warning" | xargs`
}

if [ $# -lt 1 ]; then
    print_usage
    exit $STATE_UNKNOWN
fi


check_raid_ssacli()
{
        check_cache_battery_ssacli

        # Extract logical drive lines
        ld_lines=`echo "$check" | grep -i "logicaldrive"`

        if [ -z "$ld_lines" ]; then
                checkm=`echo "$check" | sed -e '/^$/ d' | head -5`
                echo "$PROGNAME Error - No logical drives found. $checkm"
                exit $STATE_CRITICAL
        fi

        # If specific VD number requested, filter to just that VD
        if [ ! -z "$VD_NUM" ]; then
                ld_lines=`echo "$ld_lines" | grep -i "logicaldrive $VD_NUM "`
                if [ -z "$ld_lines" ]; then
                        echo "RAID CRITICAL - Logical Drive $VD_NUM not found$HOST_SUFFIX"
                        exit $STATE_CRITICAL
                fi
        fi

        # Count logical drives for performance data
        PERF_VD_COUNT=`echo "$ld_lines" | wc -l`

        # Check for various states
        raid_ok=`echo "$ld_lines" | grep -i ", OK)" | wc -l`
        raid_warning=`echo "$ld_lines" | grep -i "rebuild\|recovering" | wc -l`
        raid_critical=`echo "$ld_lines" | grep -i "failed\|offline\|degraded" | wc -l`

        PERF_VD_OK=$raid_ok
        PERF_VD_WARN=$raid_warning
        PERF_VD_CRIT=$raid_critical

        # Get physical drive count from full output
        pd_count=`echo "$check" | grep -i "physicaldrive" | wc -l`
        pd_ok=`echo "$check" | grep -i "physicaldrive" | grep -i "OK" | wc -l`
        pd_failed=`echo "$check" | grep -i "physicaldrive" | grep -iE "failed|predictive" | wc -l`
        PERF_PD_COUNT=$pd_count
        PERF_PD_OK=$pd_ok
        PERF_PD_CRIT=$pd_failed

        # Build performance data string
        PERFDATA="| vd_total=$PERF_VD_COUNT vd_ok=$PERF_VD_OK vd_warn=$PERF_VD_WARN vd_crit=$PERF_VD_CRIT pd_total=$PERF_PD_COUNT pd_ok=$PERF_PD_OK pd_crit=$PERF_PD_CRIT"
        if [ "$ENABLE_PERFDATA" != "1" ]; then
                PERFDATA=""
        fi

        extra_info=""
        if [ ! -z "$BATTERY_STATUS" ]; then
                extra_info=" $BATTERY_STATUS"
        fi

        err_check=`expr $raid_ok + $raid_warning + $raid_critical`

        if [ $err_check -eq "0" ]; then
                checkm=`echo "$check" | sed -e '/^$/ d'`
                echo "$PROGNAME Error. $checkm"
                exit $STATE_CRITICAL
        fi

        if [ $raid_critical -ge "1" ]; then
                exit_status=$STATE_CRITICAL
                msg_critical=`echo "$ld_lines" | grep -iE "failed|offline|degraded"`
                if [ "$TERSE_OUTPUT" = "1" ]; then
                        echo "RAID CRITICAL - $msg_critical"
                else
                        echo "RAID CRITICAL - $msg_critical$extra_info$HOST_SUFFIX $PERFDATA"
                fi
                exit $exit_status
        elif [ $raid_warning -ge "1" ]; then
                exit_status=$STATE_WARNING
                msg_warning=`echo "$ld_lines" | grep -i "rebuild\|recovering"`
                if [ "$TERSE_OUTPUT" = "1" ]; then
                        echo "RAID WARNING - $msg_warning"
                else
                        echo "RAID WARNING - $msg_warning$extra_info$HOST_SUFFIX $PERFDATA"
                fi
                exit $exit_status
        elif [ $raid_ok -ge "1" ]; then
                if [ ! -z "$BATTERY_WARNING" ]; then
                        exit_status=$STATE_WARNING
                        if [ ! -z "$VD_NUM" ]; then
                                if [ "$TERSE_OUTPUT" = "1" ]; then
                                        echo "RAID WARNING - $BATTERY_WARNING"
                                else
                                        echo "RAID WARNING - Logical Drive $VD_NUM OK but: $BATTERY_WARNING$extra_info$HOST_SUFFIX $PERFDATA"
                                fi
                        else
                                ld_info=`echo "$ld_lines" | sed 's/.*logicaldrive/LD/i' | sed 's/(.*//g' | xargs | sed 's/ /, /g'`
                                if [ "$TERSE_OUTPUT" = "1" ]; then
                                        echo "RAID WARNING - $BATTERY_WARNING"
                                else
                                        echo "RAID WARNING - All $PERF_VD_COUNT Logical Drives OK ($ld_info) but: $BATTERY_WARNING$extra_info$HOST_SUFFIX $PERFDATA"
                                fi
                        fi
                        exit $exit_status
                fi

                exit_status=$STATE_OK
                if [ "$TERSE_OUTPUT" = "1" ]; then
                        echo "RAID OK"
                else
                        if [ ! -z "$VD_NUM" ]; then
                                echo "RAID OK - Logical Drive $VD_NUM OK$extra_info$HOST_SUFFIX $PERFDATA"
                        else
                                ld_info=`echo "$ld_lines" | sed 's/.*logicaldrive/LD/i' | sed 's/(.*//g' | xargs | sed 's/ /, /g'`
                                echo "RAID OK - All $PERF_VD_COUNT Logical Drives OK ($ld_info)$extra_info$HOST_SUFFIX $PERFDATA"
                        fi
                fi
                exit $exit_status
        else
                echo "RAID UNKNOWN - Unable to determine RAID status$HOST_SUFFIX"
                exit $STATE_UNKNOWN
        fi
}

check_raid_storcli()
{
        # StorCLI VD status values:
        # Optl = Optimal (OK)
        # Pdgd = Partially Degraded (Warning)
        # Dgrd = Degraded (Critical)
        # Rbld = Rebuilding (Warning)
        # OfLn/Offln = Offline (Critical)
        # Failed = Failed (Critical)
        # Msng = Missing (Critical)

        # Extract VD status lines (format: "0/238 RAID1 Optl ...")
        vd_lines=`echo "$check" | grep -E "^[0-9]+/[0-9]+ +RAID"`

        if [ -z "$vd_lines" ]; then
                checkm=`echo "$check" | sed -e '/^$/ d' | head -5`
                echo "$PROGNAME StorCLI Error - No virtual drives found. $checkm"
                exit $STATE_CRITICAL
        fi

        # If specific VD number requested, filter to just that VD
        if [ ! -z "$VD_NUM" ]; then
                vd_lines=`echo "$vd_lines" | grep -E "^[0-9]+/$VD_NUM "`
                if [ -z "$vd_lines" ]; then
                        echo "RAID CRITICAL (MegaRAID) - Virtual Drive $VD_NUM not found$HOST_SUFFIX"
                        exit $STATE_CRITICAL
                fi
        fi

        # Count VDs for performance data
        PERF_VD_COUNT=`echo "$vd_lines" | wc -l`
        PERF_VD_OK=`echo "$vd_lines" | grep -E " Optl " | wc -l`
        PERF_VD_WARN=`echo "$vd_lines" | grep -E " (Rbld|Pdgd) " | wc -l`
        PERF_VD_CRIT=`echo "$vd_lines" | grep -E " (Dgrd|OfLn|Offln|Failed) " | wc -l`

        # Count physical drives for performance data
        pd_lines=`echo "$check" | grep -E "^[0-9]+:[0-9]+"`
        PERF_PD_COUNT=`echo "$pd_lines" | grep -v "^$" | wc -l`
        PERF_PD_OK=`echo "$pd_lines" | grep -E " Onln " | wc -l`
        PERF_PD_WARN=`echo "$pd_lines" | grep -E " Rbld " | wc -l`
        PERF_PD_CRIT=`echo "$pd_lines" | grep -E " (Offln|Failed|UBad|Msng) " | wc -l`

        # Build performance data string
        PERFDATA="| vd_total=$PERF_VD_COUNT vd_ok=$PERF_VD_OK vd_warn=$PERF_VD_WARN vd_crit=$PERF_VD_CRIT pd_total=$PERF_PD_COUNT pd_ok=$PERF_PD_OK pd_warn=$PERF_PD_WARN pd_crit=$PERF_PD_CRIT spares=$PERF_SPARE_COUNT max_temp=${PERF_MAX_TEMP}C media_errors=$PERF_MEDIA_ERRORS other_errors=$PERF_OTHER_ERRORS"
        if [ "$ENABLE_PERFDATA" != "1" ]; then
                PERFDATA=""
        fi

        # Check for any non-optimal VDs
        vd_critical=`echo "$vd_lines" | grep -v " Optl " | grep -v "^$"`

        if [ ! -z "$vd_critical" ]; then
                # Get VD number and status of problematic VD
                failed_vd=`echo "$vd_critical" | awk '{print $1}' | cut -d'/' -f2 | head -1`
                vd_status=`echo "$vd_critical" | awk '{print $3}' | head -1`
                vd_name=`echo "$vd_critical" | awk '{print $NF}' | head -1`

                # Translate status to readable name
                readable_status=`translate_status "$vd_status"`

                # Get problem disks from physical drives section
                # Format: "252:1     2 Onln   0 300.00 GB SAS  HDD..."
                # EID:Slt is column 1, State is column 3
                problem_disks=`echo "$check" | awk '
                        /^[0-9]+:[0-9]+/ {
                                if ($3 ~ /Rbld|Offln|Failed|Dgrd|UBad|Msng/) {
                                        split($1, a, ":")
                                        print "Bay" a[2] " Status:" $3
                                }
                        }
                ' | xargs`

                # Translate disk status to readable
                if [ ! -z "$problem_disks" ]; then
                        problem_disks_readable=`echo "$problem_disks" | sed 's/Status:Rbld/Status:Rebuilding/g; s/Status:Offln/Status:Offline/g; s/Status:Failed/Status:Failed/g; s/Status:Msng/Status:Missing/g; s/Status:UBad/Status:Bad/g'`
                fi

                # Determine severity based on status
                case "$vd_status" in
                        Rbld|Pdgd)
                                # Add rebuild progress if available
                                rebuild_info=""
                                if [ ! -z "$REBUILD_STATUS" ]; then
                                        rebuild_info=" [$REBUILD_STATUS]"
                                fi

                                if [ "$TERSE_OUTPUT" = "1" ]; then
                                        echo "RAID WARNING (MegaRAID) - VD$failed_vd $readable_status"
                                else
                                        if [ ! -z "$problem_disks_readable" ]; then
                                                echo "RAID WARNING (MegaRAID) - VD$failed_vd ($vd_name) Status: $readable_status$rebuild_info - PROBLEM: $problem_disks_readable$HOST_SUFFIX $PERFDATA"
                                        else
                                                echo "RAID WARNING (MegaRAID) - VD$failed_vd ($vd_name) Status: $readable_status$rebuild_info$HOST_SUFFIX $PERFDATA"
                                        fi
                                fi
                                exit $STATE_WARNING
                                ;;
                        Dgrd|OfLn|Offln|Failed|Msng)
                                if [ "$TERSE_OUTPUT" = "1" ]; then
                                        echo "RAID CRITICAL (MegaRAID) - VD$failed_vd $readable_status"
                                else
                                        if [ ! -z "$problem_disks_readable" ]; then
                                                echo "RAID CRITICAL (MegaRAID) - VD$failed_vd ($vd_name) Status: $readable_status - PROBLEM: $problem_disks_readable$HOST_SUFFIX $PERFDATA"
                                        else
                                                echo "RAID CRITICAL (MegaRAID) - VD$failed_vd ($vd_name) Status: $readable_status$HOST_SUFFIX $PERFDATA"
                                        fi
                                fi
                                exit $STATE_CRITICAL
                                ;;
                        *)
                                if [ "$TERSE_OUTPUT" = "1" ]; then
                                        echo "RAID CRITICAL (MegaRAID) - VD$failed_vd $vd_status"
                                else
                                        echo "RAID CRITICAL (MegaRAID) - VD$failed_vd ($vd_name) Unknown status: $vd_status$HOST_SUFFIX $PERFDATA"
                                fi
                                exit $STATE_CRITICAL
                                ;;
                esac
        else
                # All VDs are Optimal - also check physical drives for any issues
                pd_problems=`echo "$check" | awk '
                        /^[0-9]+:[0-9]+/ {
                                if ($3 ~ /Rbld|Offln|Failed|Dgrd|UBad|Msng/) {
                                        split($1, a, ":")
                                        print "Bay" a[2] " Status:" $3
                                }
                        }
                ' | xargs`

                if [ ! -z "$pd_problems" ]; then
                        pd_problems_readable=`echo "$pd_problems" | sed 's/Status:Rbld/Status:Rebuilding/g; s/Status:Offln/Status:Offline/g; s/Status:Failed/Status:Failed/g; s/Status:Msng/Status:Missing/g; s/Status:UBad/Status:Bad/g'`
                        if [ "$TERSE_OUTPUT" = "1" ]; then
                                pd_problem_short=`echo "$pd_problems_readable" | awk '{print $1" "$2}'`
                                echo "RAID WARNING (MegaRAID) - $pd_problem_short"
                        else
                                echo "RAID WARNING (MegaRAID) - VDs Optimal but disk issues detected: $pd_problems_readable$HOST_SUFFIX $PERFDATA"
                        fi
                        exit $STATE_WARNING
                fi

                # Check for critical warnings first (SSD wear critical, temperature critical)
                if [ ! -z "$CRITICAL_WARNINGS" ]; then
                        crit_warnings=`echo "$CRITICAL_WARNINGS" | xargs`
                        if [ "$TERSE_OUTPUT" = "1" ]; then
                                echo "RAID CRITICAL (MegaRAID) - $crit_warnings"
                        else
                                if [ ! -z "$VD_NUM" ]; then
                                        echo "RAID CRITICAL (MegaRAID) - VD$VD_NUM Optimal but: $crit_warnings$HOST_SUFFIX $PERFDATA"
                                else
                                        vd_info=`echo "$vd_lines" | awk '{print "VD"$1":Optimal"}' | xargs | sed 's/ /, /g'`
                                        echo "RAID CRITICAL (MegaRAID) - VDs Optimal but: $crit_warnings ($vd_info)$HOST_SUFFIX $PERFDATA"
                                fi
                        fi
                        exit $STATE_CRITICAL
                fi

                # Collect all warnings (battery, foreign config, predictive failure, etc.)
                all_warnings=""
                if [ ! -z "$BATTERY_WARNING" ]; then
                        all_warnings="${all_warnings} ${BATTERY_WARNING}"
                fi
                if [ ! -z "$WARNINGS" ]; then
                        all_warnings="${all_warnings} ${WARNINGS}"
                fi
                all_warnings=`echo "$all_warnings" | xargs`

                # If there are any warnings, report WARNING status
                if [ ! -z "$all_warnings" ]; then
                        # Add rebuild progress if applicable
                        rebuild_info=""
                        if [ ! -z "$REBUILD_STATUS" ]; then
                                rebuild_info=" [$REBUILD_STATUS]"
                        fi

                        if [ "$TERSE_OUTPUT" = "1" ]; then
                                echo "RAID WARNING (MegaRAID) - $all_warnings"
                        else
                                if [ ! -z "$VD_NUM" ]; then
                                        echo "RAID WARNING (MegaRAID) - VD$VD_NUM Optimal but: $all_warnings$rebuild_info$HOST_SUFFIX $PERFDATA"
                                else
                                        vd_info=`echo "$vd_lines" | awk '{print "VD"$1":Optimal"}' | xargs | sed 's/ /, /g'`
                                        echo "RAID WARNING (MegaRAID) - VDs Optimal but: $all_warnings ($vd_info)$HOST_SUFFIX $PERFDATA"
                                fi
                        fi
                        exit $STATE_WARNING
                fi

                # All OK - format output with commas
                extra_info=""
                if [ ! -z "$BATTERY_STATUS" ]; then
                        extra_info=" $BATTERY_STATUS"
                fi
                if [ ! -z "$CTRL_STATUS" ]; then
                        if [ -z "$extra_info" ]; then
                                extra_info=" $CTRL_STATUS"
                        else
                                extra_info="${extra_info} $CTRL_STATUS"
                        fi
                fi
                if [ ! -z "$HOTSPARE_STATUS" ]; then
                        if [ -z "$extra_info" ]; then
                                extra_info=" $HOTSPARE_STATUS"
                        else
                                extra_info="${extra_info} $HOTSPARE_STATUS"
                        fi
                fi
                # Add CC status if running
                if [ ! -z "$CC_STATUS" ]; then
                        if [ -z "$extra_info" ]; then
                                extra_info=" $CC_STATUS"
                        else
                                extra_info="${extra_info} $CC_STATUS"
                        fi
                fi
                # Add patrol read status if available
                if [ ! -z "$PATROL_STATUS" ]; then
                        if [ -z "$extra_info" ]; then
                                extra_info=" $PATROL_STATUS"
                        else
                                extra_info="${extra_info} $PATROL_STATUS"
                        fi
                fi
                # Add temperature if available
                if [ "$PERF_MAX_TEMP" -gt 0 ]; then
                        if [ -z "$extra_info" ]; then
                                extra_info=" Temp:${PERF_MAX_TEMP}C"
                        else
                                extra_info="${extra_info} Temp:${PERF_MAX_TEMP}C"
                        fi
                fi

                if [ "$TERSE_OUTPUT" = "1" ]; then
                        if [ ! -z "$VD_NUM" ]; then
                                printf "RAID OK (MegaRAID) - VD$VD_NUM Optimal\n"
                        else
                                printf "RAID OK (MegaRAID)\n"
                        fi
                else
                        if [ ! -z "$VD_NUM" ]; then
                                printf "RAID OK (MegaRAID) - VD$VD_NUM Status: Optimal$extra_info$HOST_SUFFIX $PERFDATA"
                                if [ ! -z "$LONG_OUTPUT" ]; then
                                        printf "$LONG_OUTPUT"
                                fi
                                printf "\n"
                        else
                                vd_info=`echo "$vd_lines" | awk '{print "VD"$1":Optimal"}' | xargs | sed 's/ /, /g'`
                                printf "RAID OK (MegaRAID) - All $PERF_VD_COUNT Virtual Drives Optimal ($vd_info)$extra_info$HOST_SUFFIX $PERFDATA"
                                if [ ! -z "$LONG_OUTPUT" ]; then
                                        printf "$LONG_OUTPUT"
                                fi
                                printf "\n"
                        fi
                fi
                exit $STATE_OK
        fi
}

# Check battery/cache vault status for MegaRAID
check_battery_storcli()
{
        battery_status=""
        battery_warning=""

        ctrl_id=${CTRL_ID:-0}

        # Check cachevault status
        cv_state=""
        cv_check=`timeout $TIMEOUT $ESXCLI -s $HOST -u $USER -d $thumb storcli cachevault show status -i $ctrl_id 2>&1`
        cv_state=`echo "$cv_check" | awk -F'[:=]' 'BEGIN{IGNORECASE=1} /State|Status/ {print $2; exit}' | xargs`
        if echo "$cv_check" | grep -qi "Unsupported Command"; then
                cv_state=""
        fi
        if [ -z "$cv_state" ]; then
                cv_check=`timeout $TIMEOUT $ESXCLI -s $HOST -u $USER -d $thumb storcli cachevault show basic -i $ctrl_id 2>&1`
                cv_state=`echo "$cv_check" | awk -F'[:=]' 'BEGIN{IGNORECASE=1} /State|Status/ {print $2; exit}' | xargs`
                if echo "$cv_check" | grep -qi "Unsupported Command"; then
                        cv_state=""
                fi
        fi
        if [ -z "$cv_state" ]; then
                cv_check=`timeout $TIMEOUT $ESXCLI -s $HOST -u $USER -d $thumb storcli cachevault show all -i $ctrl_id 2>&1`
                cv_state=`echo "$cv_check" | awk -F'[:=]' 'BEGIN{IGNORECASE=1} /State|Status/ {print $2; exit}' | xargs`
                if echo "$cv_check" | grep -qi "Unsupported Command"; then
                        cv_state=""
                fi
        fi
        if [ -z "$cv_state" ]; then
                ctrl_check=`timeout $TIMEOUT $ESXCLI -s $HOST -u $USER -d $thumb storcli controller show -i $ctrl_id 2>&1`
                cv_state=`echo "$ctrl_check" | awk -F'[:=]' 'BEGIN{IGNORECASE=1} /CacheVault/ && /State|Status/ {print $2; exit}' | xargs`
        fi

        if [ ! -z "$cv_state" ]; then
                if echo "$cv_state" | grep -qiE "Optimal|Good|OK"; then
                        battery_status="CV:OK"
                elif echo "$cv_state" | grep -qiE "Learning|Charging"; then
                        battery_status="CV:$cv_state"
                        battery_warning="CacheVault $cv_state"
                else
                        battery_status="CV:$cv_state"
                        battery_warning="CacheVault $cv_state"
                fi
        fi

        # Check BBU status if exists
        bbu_state=""
        bbu_check=`timeout $TIMEOUT $ESXCLI -s $HOST -u $USER -d $thumb storcli battery show status -i $ctrl_id 2>&1`
        bbu_state=`echo "$bbu_check" | awk -F'[:=]' 'BEGIN{IGNORECASE=1} /State|Status/ {print $2; exit}' | xargs`
        if echo "$bbu_check" | grep -qi "Unsupported Command"; then
                bbu_state=""
        fi
        if [ -z "$bbu_state" ]; then
                bbu_check=`timeout $TIMEOUT $ESXCLI -s $HOST -u $USER -d $thumb storcli battery show basic -i $ctrl_id 2>&1`
                bbu_state=`echo "$bbu_check" | awk -F'[:=]' 'BEGIN{IGNORECASE=1} /State|Status/ {print $2; exit}' | xargs`
                if echo "$bbu_check" | grep -qi "Unsupported Command"; then
                        bbu_state=""
                fi
        fi
        if [ -z "$bbu_state" ]; then
                bbu_check=`timeout $TIMEOUT $ESXCLI -s $HOST -u $USER -d $thumb storcli battery show all -i $ctrl_id 2>&1`
                bbu_state=`echo "$bbu_check" | awk -F'[:=]' 'BEGIN{IGNORECASE=1} /State|Status/ {print $2; exit}' | xargs`
                if echo "$bbu_check" | grep -qi "Unsupported Command"; then
                        bbu_state=""
                fi
        fi
        if [ -z "$bbu_state" ]; then
                if [ -z "$ctrl_check" ]; then
                        ctrl_check=`timeout $TIMEOUT $ESXCLI -s $HOST -u $USER -d $thumb storcli controller show -i $ctrl_id 2>&1`
                fi
                bbu_state=`echo "$ctrl_check" | awk -F'[:=]' 'BEGIN{IGNORECASE=1} /(BBU|Battery)/ && /State|Status/ {print $2; exit}' | xargs`
        fi

        if [ ! -z "$bbu_state" ]; then
                if echo "$bbu_state" | grep -qiE "Optimal|Good|OK"; then
                        battery_status="${battery_status} BBU:OK"
                elif echo "$bbu_state" | grep -qiE "Learning|Charging"; then
                        battery_status="${battery_status} BBU:$bbu_state"
                        battery_warning="${battery_warning} BBU $bbu_state"
                else
                        battery_status="${battery_status} BBU:$bbu_state"
                        battery_warning="${battery_warning} BBU $bbu_state"
                fi
        fi

        # Fallback: parse Energy Pack status from controller summary if CV/BBU not available
        if [ -z "$battery_status" ]; then
                ctrl_summary=`timeout $TIMEOUT $ESXCLI -s $HOST -u $USER -d $thumb storcli controller show all -i $ctrl_id 2>&1`
                ep_present=`echo "$ctrl_summary" | awk -F'=' 'BEGIN{IGNORECASE=1} /Energy Pack =/ {print $2; exit}' | xargs`
                ep_status=`echo "$ctrl_summary" | awk -F'=' 'BEGIN{IGNORECASE=1} /Energy Pack Status/ {print $2; exit}' | xargs`
                if [ -n "$ep_present" ] || [ -n "$ep_status" ]; then
                        if echo "$ep_present" | grep -qiE "Present|Yes"; then
                                if [ -z "$ep_status" ] || [ "$ep_status" = "0" ] || echo "$ep_status" | grep -qiE "OK|Optimal|Good"; then
                                        battery_status="Cache:OK Battery:OK"
                                else
                                        battery_status="Cache:EP${ep_status} Battery:EP${ep_status}"
                                        battery_warning="Energy Pack status ${ep_status}"
                                fi
                        elif echo "$ep_present" | grep -qiE "Absent|No"; then
                                battery_warning="Energy Pack Absent"
                        fi
                fi
        fi

        # Return battery status (can be used in output)
        BATTERY_STATUS=`echo "$battery_status" | xargs`
        BATTERY_WARNING=`echo "$battery_warning" | xargs`
}

# Check controller health status
check_controller_health_storcli()
{
        ctrl_id=${CTRL_ID:-0}

        # Get controller info
        ctrl_check=`timeout $TIMEOUT $ESXCLI -s $HOST -u $USER -d $thumb storcli controller show -i $ctrl_id 2>&1`

        if echo "$ctrl_check" | grep -qi "Status"; then
                ctrl_state=`echo "$ctrl_check" | grep -i "Controller Status" | awk -F: '{print $2}' | xargs | head -1`
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

# Check write cache status
check_write_cache_storcli()
{
        # Write cache info is in the VD properties from the main check
        # Look for "Write Cache" or "Current Write Policy" in output

        wc_disabled=`echo "$check" | grep -iE "WriteThrough|WT" | grep -v "AWB" | head -1`

        if [ ! -z "$wc_disabled" ]; then
                # Check if it's intentionally WT or forced due to BBU issue
                if [ ! -z "$BATTERY_WARNING" ]; then
                        WARNINGS="${WARNINGS} WriteCache disabled (BBU issue)"
                else
                        # Just informational, some configs use WT intentionally
                        WRITE_CACHE_STATUS="WC:WT"
                fi
        else
                WRITE_CACHE_STATUS="WC:WB"
        fi
}

# Check for foreign configurations
check_foreign_config_storcli()
{
        ctrl_id=${CTRL_ID:-0}

        # Check for foreign configs
        foreign_check=`timeout $TIMEOUT $ESXCLI -s $HOST -u $USER -d $thumb storcli foreign show -i $ctrl_id 2>&1`

        if echo "$foreign_check" | grep -qiE "foreign configuration|DG"; then
                foreign_count=`echo "$foreign_check" | grep -E "^[0-9]+" | wc -l`
                if [ "$foreign_count" -gt 0 ]; then
                        WARNINGS="${WARNINGS} Foreign config detected ($foreign_count)"
                        FOREIGN_CONFIG="Foreign:$foreign_count"
                fi
        fi
}

# Check hot spare status
check_hotspare_storcli()
{
        # Hot spares show as "DHS" (Dedicated Hot Spare) or "GHS" (Global Hot Spare) in PD output
        # Or status "Hotspare" in the Type column

        spare_count=`echo "$check" | grep -E "^[0-9]+:[0-9]+" | grep -iE "DHS|GHS|Hotspare|UGood" | wc -l`
        spare_ok=`echo "$check" | grep -E "^[0-9]+:[0-9]+" | grep -iE "DHS|GHS" | wc -l`
        ugood_count=`echo "$check" | grep -E "^[0-9]+:[0-9]+" | grep -i "UGood" | wc -l`
        pd_count=`echo "$check" | grep -E "^[0-9]+:[0-9]+" | wc -l`

        PERF_SPARE_COUNT=$spare_ok

        if [ "$spare_ok" -gt 0 ]; then
                HOTSPARE_STATUS="Spares:$spare_ok"
        elif [ "$ugood_count" -gt 0 ]; then
                HOTSPARE_STATUS="UGood:$ugood_count"
        else
                HOTSPARE_STATUS="Spares:0"
                # Only warn if there are multiple physical drives (RAID setup)
                if [ "$pd_count" -gt 2 ]; then
                        WARNINGS="${WARNINGS} No hot spares configured"
                fi
        fi
}

# Check for predictive failures on physical drives
check_predictive_failure_storcli()
{
        # Check for predictive failure flag

        ctrl_id=${CTRL_ID:-0}

        # Get detailed PD info
        pd_detail=`timeout $TIMEOUT $ESXCLI -s $HOST -u $USER -d $thumb storcli physicaldrive show -i $ctrl_id -p all 2>&1`

        # Check for predictive failure flag
        predictive=`echo "$pd_detail" | grep -i "Predictive" | grep -iv "No\|0" | head -3`

        if [ ! -z "$predictive" ]; then
                # Extract which drive has predictive failure
                pred_drives=`echo "$pd_detail" | grep -B5 -i "Predictive.*Yes" | grep -E "^[0-9]+:[0-9]+" | awk '{print $1}' | xargs`
                if [ ! -z "$pred_drives" ]; then
                        WARNINGS="${WARNINGS} Predictive failure on: $pred_drives"
                        PREDICTIVE_STATUS="PredFail:YES"
                fi
        fi
}

# Check SMART data (media errors, bad blocks, other errors)
check_smart_data_storcli()
{
        ctrl_id=${CTRL_ID:-0}

        # Get detailed PD info for SMART data
        pd_detail=`timeout $TIMEOUT $ESXCLI -s $HOST -u $USER -d $thumb storcli physicaldrive show -i $ctrl_id -p all 2>&1`

        # Get list of physical drives
        pd_list=`echo "$check" | grep -E "^[0-9]+:[0-9]+" | awk '{print $1}'`

        total_media_errors=0
        total_other_errors=0
        drives_with_errors=""

        for drive in $pd_list; do
                # Extract SMART data for this drive
                drive_section=`echo "$pd_detail" | grep -A50 "^Drive.*$drive\|^$drive" | head -50`

                # Get media error count
                media_count=`echo "$drive_section" | grep -i "Media Error" | grep -oE "[0-9]+" | head -1`
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
                other_count=`echo "$drive_section" | grep -i "Other Error" | grep -oE "[0-9]+" | head -1`
                if [ ! -z "$other_count" ] && [ "$other_count" -gt 0 ]; then
                        total_other_errors=$((total_other_errors + other_count))
                        if [ "$other_count" -ge "$OTHER_ERROR_WARN" ]; then
                                WARNINGS="${WARNINGS} Drive $drive: $other_count other errors"
                                drives_with_errors="${drives_with_errors} $drive(OE:$other_count)"
                        fi
                fi

                # Check shield counter (uncorrectable errors)
                shield_count=`echo "$drive_section" | grep -i "Shield Counter" | grep -oE "[0-9]+" | head -1`
                if [ ! -z "$shield_count" ] && [ "$shield_count" -gt 0 ]; then
                        WARNINGS="${WARNINGS} Drive $drive: $shield_count shield errors"
                        drives_with_errors="${drives_with_errors} $drive(SC:$shield_count)"
                fi

                # Check BBM (Bad Block Management) error count
                bbm_count=`echo "$drive_section" | grep -i "BBM Error" | grep -oE "[0-9]+" | head -1`
                if [ ! -z "$bbm_count" ] && [ "$bbm_count" -gt 0 ]; then
                        WARNINGS="${WARNINGS} Drive $drive: $bbm_count BBM errors"
                        drives_with_errors="${drives_with_errors} $drive(BBM:$bbm_count)"
                fi
        done

        # Store totals for performance data
        PERF_MEDIA_ERRORS=$total_media_errors
        PERF_OTHER_ERRORS=$total_other_errors
        SMART_DRIVES_WITH_ERRORS=`echo "$drives_with_errors" | xargs`
}

# Get number of controllers
get_controller_count_storcli()
{
        # Query system for controller count
        sys_check=`timeout $TIMEOUT $ESXCLI -s $HOST -u $USER -d $thumb storcli system show 2>&1`

        if echo "$sys_check" | grep -qi "Controller"; then
                CTRL_COUNT=`echo "$sys_check" | grep -i "Number of Controllers" | awk -F: '{print $2}' | xargs`
                if [ -z "$CTRL_COUNT" ]; then
                        # Try alternate method - count controller lines
                        CTRL_COUNT=`echo "$sys_check" | grep -E "^[0-9]+ " | wc -l`
                fi
        fi

        if [ -z "$CTRL_COUNT" ] || [ "$CTRL_COUNT" -eq 0 ]; then
                CTRL_COUNT=1
        fi
}

# Check rebuild progress
check_rebuild_progress_storcli()
{
        ctrl_id=${CTRL_ID:-0}

        # Check for any VDs in rebuild state and get progress
        rebuild_check=`timeout $TIMEOUT $ESXCLI -s $HOST -u $USER -d $thumb storcli virtualdrive show init -i $ctrl_id -v all 2>&1`

        # Also check BGI (Background Initialization)
        bgi_progress=""
        rebuild_progress=""

        # Look for rebuild progress in the output
        if echo "$check" | grep -qiE " Rbld "; then
                # Get rebuild progress percentage
                rebuild_info=`timeout $TIMEOUT $ESXCLI -s $HOST -u $USER -d $thumb storcli virtualdrive show rebuild -i $ctrl_id -v all 2>&1`
                rebuild_progress=`echo "$rebuild_info" | grep -i "Progress" | awk -F: '{print $2}' | xargs | head -1`
                if [ ! -z "$rebuild_progress" ]; then
                        REBUILD_STATUS="Rebuild:${rebuild_progress}"
                else
                        REBUILD_STATUS="Rebuild:InProgress"
                fi
        fi

        # Check for BGI progress
        bgi_info=`timeout $TIMEOUT $ESXCLI -s $HOST -u $USER -d $thumb storcli virtualdrive show bgi -i $ctrl_id -v all 2>&1`
        if echo "$bgi_info" | grep -qiE "[0-9]+%"; then
                bgi_progress=`echo "$bgi_info" | grep -iE "Progress|%" | grep -oE "[0-9]+%" | head -1`
                if [ ! -z "$bgi_progress" ]; then
                        if [ -z "$REBUILD_STATUS" ]; then
                                REBUILD_STATUS="BGI:${bgi_progress}"
                        else
                                REBUILD_STATUS="${REBUILD_STATUS} BGI:${bgi_progress}"
                        fi
                fi
        fi
}

# Check consistency check status
check_consistency_check_storcli()
{
        ctrl_id=${CTRL_ID:-0}

        # Check for consistency check progress
        cc_info=`timeout $TIMEOUT $ESXCLI -s $HOST -u $USER -d $thumb storcli virtualdrive show cc -i $ctrl_id -v all 2>&1`

        if echo "$cc_info" | grep -qiE "[0-9]+%|in progress"; then
                cc_progress=`echo "$cc_info" | grep -iE "Progress|%" | grep -oE "[0-9]+%" | head -1`
                if [ ! -z "$cc_progress" ]; then
                        CC_STATUS="CC:${cc_progress}"
                else
                        CC_STATUS="CC:Running"
                fi
        fi
}

# Check SSD wear level
check_ssd_wear_storcli()
{
        ctrl_id=${CTRL_ID:-0}

        # Get detailed PD info for SSD wear
        pd_detail=`timeout $TIMEOUT $ESXCLI -s $HOST -u $USER -d $thumb storcli physicaldrive show -i $ctrl_id -p all 2>&1`

        # Look for SSD drives and their wear level
        # Common fields: "SSD Life Left", "Wear Remaining", "Media Wearout Indicator"
        ssd_drives=`echo "$check" | grep -E "^[0-9]+:[0-9]+" | grep -i "SSD" | awk '{print $1}'`

        if [ ! -z "$ssd_drives" ]; then
                for drive in $ssd_drives; do
                        # Get wear level for this drive
                        wear_level=`echo "$pd_detail" | grep -A20 "^$drive" | grep -iE "Life Left|Wear|Wearout" | grep -oE "[0-9]+" | head -1`

                        if [ ! -z "$wear_level" ]; then
                                # Update max wear tracking for perfdata
                                remaining=$wear_level

                                if [ "$remaining" -le "$SSD_WEAR_CRIT" ]; then
                                        CRITICAL_WARNINGS="${CRITICAL_WARNINGS} SSD $drive wear critical (${remaining}% left)"
                                elif [ "$remaining" -le "$SSD_WEAR_WARN" ]; then
                                        WARNINGS="${WARNINGS} SSD $drive wear warning (${remaining}% left)"
                                fi
                        fi
                done
        fi
}

# Check drive temperature
check_drive_temperature_storcli()
{
        ctrl_id=${CTRL_ID:-0}

        # Get detailed PD info for temperature
        pd_detail=`timeout $TIMEOUT $ESXCLI -s $HOST -u $USER -d $thumb storcli physicaldrive show -i $ctrl_id -p all 2>&1`

        # Look for temperature readings
        # Common fields: "Drive Temperature", "Temperature"
        temp_lines=`echo "$pd_detail" | grep -iE "Temperature|Temp" | grep -v "Threshold"`

        max_temp=0

        if [ ! -z "$temp_lines" ]; then
                # Extract temperatures and find max
                temps=`echo "$temp_lines" | grep -oE "[0-9]+" | head -10`

                for temp in $temps; do
                        # Skip unrealistic values (likely not temperature)
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
        fi

        PERF_MAX_TEMP=$max_temp
}

# Check patrol read status
check_patrol_read_storcli()
{
        ctrl_id=${CTRL_ID:-0}

        # Get patrol read info
        pr_check=`timeout $TIMEOUT $ESXCLI -s $HOST -u $USER -d $thumb storcli controller show -i $ctrl_id 2>&1`

        # Look for patrol read state
        pr_state=`echo "$pr_check" | grep -i "Patrol Read" | grep -i "State" | awk -F: '{print $2}' | xargs | head -1`

        if [ ! -z "$pr_state" ]; then
                if echo "$pr_state" | grep -qiE "Active|Running"; then
                        # Get progress if running
                        pr_progress=`echo "$pr_check" | grep -i "Patrol Read" | grep -i "Progress" | grep -oE "[0-9]+%" | head -1`
                        if [ ! -z "$pr_progress" ]; then
                                PATROL_STATUS="PR:${pr_progress}"
                        else
                                PATROL_STATUS="PR:Running"
                        fi
                elif echo "$pr_state" | grep -qiE "Stopped|Paused"; then
                        PATROL_STATUS="PR:Stopped"
                else
                        PATROL_STATUS="PR:$pr_state"
                fi
        fi
}

# Build long output for Nagios (multi-line detailed output)
build_long_output_storcli()
{
        LONG_OUTPUT=""

        # Virtual Drives summary
        LONG_OUTPUT="${LONG_OUTPUT}\n--- Virtual Drives ---"
        vd_summary=$(echo "$check" | grep -E "^[0-9]+/[0-9]+ +RAID" | while IFS= read -r line; do
                vd_num=$(echo "$line" | awk '{print $1}')
                vd_type=$(echo "$line" | awk '{print $2}')
                vd_state=$(echo "$line" | awk '{print $3}')
                vd_size=$(echo "$line" | awk '{print $10" "$11}')
                vd_name=$(echo "$line" | awk '{print $NF}')
                echo "VD$vd_num: $vd_type $vd_state $vd_size ($vd_name)"
        done)
        LONG_OUTPUT="${LONG_OUTPUT}\n${vd_summary}"

        # Physical Drives summary
        LONG_OUTPUT="${LONG_OUTPUT}\n\n--- Physical Drives ---"
        pd_summary=$(echo "$check" | grep -E "^[0-9]+:[0-9]+" | while IFS= read -r line; do
                pd_id=$(echo "$line" | awk '{print $1}')
                pd_state=$(echo "$line" | awk '{print $3}')
                pd_size=$(echo "$line" | awk '{print $5" "$6}')
                pd_type=$(echo "$line" | awk '{print $7" "$8}')
                echo "PD$pd_id: $pd_state $pd_size $pd_type"
        done)
        LONG_OUTPUT="${LONG_OUTPUT}\n${pd_summary}"

        # Status summary
        LONG_OUTPUT="${LONG_OUTPUT}\n\n--- Status ---"
        if [ ! -z "$CTRL_STATUS" ]; then
                LONG_OUTPUT="${LONG_OUTPUT}\nController: $CTRL_STATUS"
        fi
        if [ ! -z "$BATTERY_STATUS" ]; then
                LONG_OUTPUT="${LONG_OUTPUT}\nBattery: $BATTERY_STATUS"
        fi
        if [ ! -z "$HOTSPARE_STATUS" ]; then
                LONG_OUTPUT="${LONG_OUTPUT}\nHot Spares: $HOTSPARE_STATUS"
        fi
        if [ ! -z "$PATROL_STATUS" ]; then
                LONG_OUTPUT="${LONG_OUTPUT}\nPatrol Read: $PATROL_STATUS"
        fi
        if [ ! -z "$CC_STATUS" ]; then
                LONG_OUTPUT="${LONG_OUTPUT}\nConsistency Check: $CC_STATUS"
        fi
        if [ ! -z "$REBUILD_STATUS" ]; then
                LONG_OUTPUT="${LONG_OUTPUT}\nRebuild: $REBUILD_STATUS"
        fi
        if [ "$PERF_MAX_TEMP" -gt 0 ]; then
                LONG_OUTPUT="${LONG_OUTPUT}\nMax Temperature: ${PERF_MAX_TEMP}C"
        fi
}


# Parse command line arguments
VD_NUM=""
HOST=""
USER=""
CTRL_ID=""

while [ $# -gt 0 ]; do
        case "$1" in
                --help)
                        print_help
                        exit 0
                        ;;
                --version|-V)
                        print_revision $PROGNAME $REVISION
                        exit 0
                        ;;
                -h)
                        HOST="$2"
                        shift 2
                        ;;
                -u)
                        USER="$2"
                        shift 2
                        ;;
                -v)
                        VD_NUM="$2"
                        shift 2
                        ;;
                -c)
                        CTRL_ID="$2"
                        shift 2
                        ;;
                -t)
                        TIMEOUT="$2"
                        shift 2
                        ;;
                *)
                        print_usage
                        exit $STATE_UNKNOWN
                        ;;
        esac
done

# Check if ESXCLI exists
if [ ! -x "$ESXCLI" ]; then
        echo "RAID UNKNOWN - esxcli not found at $ESXCLI"
        exit $STATE_UNKNOWN
fi

# Validate required parameters
if [ -z "$HOST" ]; then
        echo "RAID UNKNOWN - Missing host parameter (-h)"
        print_usage
        exit $STATE_UNKNOWN
fi

if [ -z "$USER" ]; then
        echo "RAID UNKNOWN - Missing username parameter (-u)"
        print_usage
        exit $STATE_UNKNOWN
fi

# Set thumbprint based on host
set_thumbprint
if [ -z "$thumb" ]; then
        echo "RAID UNKNOWN - Unknown host: $HOST (no SSL thumbprint configured)"
        exit $STATE_UNKNOWN
fi
b=$HOST
HOST_SUFFIX=""
if [ "$SHOW_HOST" = "1" ]; then
        HOST_SUFFIX=" - $b"
fi

# First try ssacli (HP Smart Array) with timeout
check=`timeout $TIMEOUT $ESXCLI -s $HOST -u $USER -d $thumb ssacli cmd -q "controller slot=0 ld all show" 2>&1`
exit_code=$?

# Check for timeout
if [ $exit_code -eq 124 ]; then
        echo "RAID UNKNOWN - Timeout after ${TIMEOUT}s connecting to $HOST"
        exit $STATE_UNKNOWN
fi

# Check if ssacli failed due to controller not found
if echo "$check" | grep -qi "controller identified by.*was not detected\|no controllers detected"; then
        # Try storcli (MegaRAID) instead - Gen10P and Gen11 servers

        # Determine controller ID to use
        if [ -z "$CTRL_ID" ]; then
                CTRL_ID="all"
        fi

        check=`timeout $TIMEOUT $ESXCLI -s $HOST -u $USER -d $thumb storcli virtualdrive show all -i $CTRL_ID -v all 2>&1`
        exit_code=$?

        # Check for timeout
        if [ $exit_code -eq 124 ]; then
                echo "RAID UNKNOWN - Timeout after ${TIMEOUT}s connecting to $HOST"
                exit $STATE_UNKNOWN
        fi

        # Set controller ID for subsequent checks (use 0 if "all" was specified)
        if [ "$CTRL_ID" = "all" ]; then
                CTRL_ID=0
        fi

        # Run all additional checks (non-blocking, best effort)
        # 1. Controller health check
        check_controller_health_storcli

        # 2. Battery/cachevault status
        check_battery_storcli

        # 3. Write cache status
        check_write_cache_storcli

        # 4. Foreign configuration detection
        check_foreign_config_storcli

        # 5. Hot spare monitoring
        check_hotspare_storcli

        # 6. Predictive failure check
        check_predictive_failure_storcli

        # 7. SMART data check (media errors, bad blocks)
        check_smart_data_storcli

        # 8. Rebuild progress check
        check_rebuild_progress_storcli

        # 9. Consistency check status
        check_consistency_check_storcli

        # 10. SSD wear level check
        check_ssd_wear_storcli

        # 11. Drive temperature check
        check_drive_temperature_storcli

        # 12. Patrol read status
        check_patrol_read_storcli

        # 13. Build long output for Nagios (optional)
        if [ "$ENABLE_LONG_OUTPUT" = "1" ]; then
                build_long_output_storcli
        fi

        check_raid_storcli
else
        check_raid_ssacli
fi
