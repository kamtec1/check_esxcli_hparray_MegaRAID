# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repository contains Nagios plugin scripts for monitoring HP Proliant hardware RAID status.

## Repository Guidelines

See `AGENTS.md` for contributor-oriented guidelines (structure, commands, style, and testing expectations).

## Scripts

### ESXi Scripts (for VMware ESXi servers via ESXCLI)

#### check_esxcli_hparray_MegaRAID.sh (v1.7)
Bash script for monitoring RAID on VMware ESXi servers.

**Supported Controllers:**
- HP Smart Array (ssacli) - Gen10 and older servers
- HPE MegaRAID (storcli) - Gen10P and Gen11 servers

The script auto-detects which controller type is present.

**Usage:**
```bash
./check_esxcli_hparray_MegaRAID.sh -h <host> -u <username> [-v <vd-number>] [-c <controller>] [-t <timeout>]

# Examples:
./check_esxcli_hparray_MegaRAID.sh -h 10.10.10.20 -u nagios
./check_esxcli_hparray_MegaRAID.sh -h 10.10.10.20 -u nagios -v 238
./check_esxcli_hparray_MegaRAID.sh -h 10.10.10.20 -u nagios -c 0
DEBUG=1 ./check_esxcli_hparray_MegaRAID.sh -h 10.10.10.20 -u nagios
```

#### check_esxcli_hparray_MegaRAID.py (v1.7)
Python 3 version for monitoring RAID on VMware ESXi servers.

**Usage:**
```bash
./check_esxcli_hparray_MegaRAID.py -H <host> -u <username> [-v <vd-number>] [-c <controller>] [-t <timeout>]

# Examples:
./check_esxcli_hparray_MegaRAID.py -H 10.10.10.20 -u nagios
./check_esxcli_hparray_MegaRAID.py -H 10.10.10.20 -u nagios -v 0
./check_esxcli_hparray_MegaRAID.py -H 10.10.10.20 -u nagios -c 1
```

**Requirements:**
- Python 3.7+
- esxcli at `/opt/vmware-vsphere-cli-distrib/lib/bin/esxcli/esxcli`

**Output controls (env vars):**
- `ENABLE_PERFDATA=1` to append perfdata (default: off)
- `ENABLE_LONG_OUTPUT=1` to append multi-line details (default: off)
- `SHOW_HOST=1` to append the host at end of the first line (default: off)
- `TERSE_OUTPUT=1` to minimize OK output (default: on); set to `0` for verbose output

### Physical Server Scripts (for local servers via storcli64)

#### check_hparray_MegaRAID.sh (v1.7)
Bash script for monitoring RAID on physical servers with MegaRAID controllers.

**Usage:**
```bash
./check_hparray_MegaRAID.sh [vd-number] [-c controller] [-t timeout]

# Examples:
./check_hparray_MegaRAID.sh
./check_hparray_MegaRAID.sh 238
./check_hparray_MegaRAID.sh -c 1
./check_hparray_MegaRAID.sh -t 120
DEBUG=1 ./check_hparray_MegaRAID.sh
```

**Notes:**
- Uses `timeout` (if available) to enforce the `-t` value for storcli commands.

#### check_hparray_MegaRAID.py (v1.7)
Python 3 version for monitoring RAID on physical servers.

**Usage:**
```bash
./check_hparray_MegaRAID.py [-v <vd-number>] [-c <controller>] [-t <timeout>]

# Examples:
./check_hparray_MegaRAID.py
./check_hparray_MegaRAID.py -v 0
./check_hparray_MegaRAID.py -c 1
```

**Requirements:**
- Python 3.7+
- StorCLI (`/opt/MegaRAID/storcli/storcli64`)

**Output controls (env vars):**
- `ENABLE_PERFDATA=1` to append perfdata (default: off)
- `ENABLE_LONG_OUTPUT=1` to append multi-line details (default: off)
- `TERSE_OUTPUT=1` to minimize OK output (default: on); set to `0` for verbose output

## Common Features (All Scripts v1.7)

**Checks Performed:**
1. Virtual drive status
2. Physical drive status
3. Controller health status
4. Battery/CacheVault status
5. Foreign configuration detection
6. Hot spare availability
7. Predictive failure detection (SMART)
8. SMART data monitoring:
   - Media error count per drive
   - Other error count per drive
   - Shield counter (uncorrectable errors)
   - BBM (Bad Block Management) errors
9. Rebuild progress with percentage
10. Consistency check status with percentage
11. SSD wear level monitoring
12. Drive temperature monitoring
13. Patrol read status

**Thresholds:**
| Check | Warning | Critical |
|-------|---------|----------|
| SSD Wear Level | <=20% remaining | <=10% remaining |
| Drive Temperature | >=50C | >=60C |
| Media Errors | >=1 error | >=10 errors |
| Other Errors | >=1 error | - |

**Performance Data (optional):**
Enable with `ENABLE_PERFDATA=1` (default: off) to append perfdata to the first line.
```
| vd_total=1 vd_ok=1 vd_warn=0 vd_crit=0 pd_total=2 pd_ok=2 pd_warn=0 pd_crit=0 spares=0 max_temp=35C media_errors=0 other_errors=0
```

**Short Output Extras:**
When available, extra status tokens (e.g., `CV:OK`, `BBU:OK`, `Cache:OK`, `Battery:OK`, `Controller:OK`, `Spares:0`) are included in the first line without needing long output. On MegaRAID, Energy Pack status is used as a fallback for cache/battery OK. Battery/cache failures are surfaced as WARNINGs.

**Long Output (optional):**
Enable with `ENABLE_LONG_OUTPUT=1` (default: off) to include detailed multi-line output for the Nagios web interface showing:
- Virtual drive details
- Physical drive details
- Controller status
- Battery status
- Hot spare count
- Patrol read status
- Consistency check progress
- Rebuild progress
- Max temperature
- Total media/other errors

**Example Outputs:**
```
# All OK
RAID OK - All 1 Virtual Drives Optimal (VD0/238:Optimal) [CV:OK Controller:OK Spares:0 Temp:35C] | ...

# Rebuilding with progress
RAID WARNING - VD238 (LDName_00) Status: Rebuilding [Rebuild:45%] - PROBLEM: Bay2 Status:Rebuilding | ...

# Predictive failure
RAID WARNING - VDs Optimal but: Predictive failure on: 252:2 | ...

# SMART media errors
RAID WARNING - VDs Optimal but: Drive 252:1: 3 media errors | ...

# Critical media errors
RAID CRITICAL - VDs Optimal but: Drive 252:1: 15 media errors | ...

# Temperature warning
RAID WARNING - VDs Optimal but: Drive temperature high (52C) | ...
```

## Exit Codes (Nagios Standard)

| Code | Status | Conditions |
|------|--------|------------|
| 0 | OK | RAID healthy, all checks pass |
| 1 | WARNING | Rebuilding, Partially Degraded, Battery Learning, Predictive Failure, No Spares, Foreign Config, High Temperature (>=50C), SSD Wear (<=20%), Media Errors (>=1) |
| 2 | CRITICAL | Degraded, Failed, Offline, Missing, Critical Temperature (>=60C), SSD Wear Critical (<=10%), Media Errors (>=10) |
| 3 | UNKNOWN | Unable to determine status, timeout, missing binary |

## Adding New ESXi Hosts

### For Bash Script (check_esxcli_hparray_MegaRAID.sh)
Add a new case in the thumbprint section near the top of the file:
```bash
        new.host.ip)
                thumb="XX:XX:XX:..."
                ;;
```

### For Python Script (check_esxcli_hparray_MegaRAID.py)
Add to the `ESX_THUMBPRINTS` dictionary at the top of the file:
```python
ESX_THUMBPRINTS = {
    ...
    "new.host.ip": "XX:XX:XX:...",
}
```

## Status Code Reference

### Virtual Drive Status
| Code | Meaning | Nagios Status |
|------|---------|---------------|
| Optl | Optimal | OK |
| Pdgd | Partially Degraded | WARNING |
| Dgrd | Degraded | CRITICAL |
| Rbld | Rebuilding | WARNING |
| OfLn | Offline | CRITICAL |
| Failed | Failed | CRITICAL |
| Msng | Missing | CRITICAL |

### Physical Drive Status
| Code | Meaning | Nagios Status |
|------|---------|---------------|
| Onln | Online | OK |
| Rbld | Rebuilding | WARNING |
| Offln | Offline | CRITICAL |
| Failed | Failed | CRITICAL |
| UBad | Unconfigured Bad | CRITICAL |
| Msng | Missing | CRITICAL |
| UGood | Unconfigured Good | OK (available) |
| DHS | Dedicated Hot Spare | OK |
| GHS | Global Hot Spare | OK |

## Version History

### v1.7
- Added comprehensive SMART data monitoring:
  - Media error count per drive (warning at 1, critical at 10)
  - Other error count per drive (warning at 1)
  - Shield counter errors
  - BBM (Bad Block Management) errors
- Added media_errors and other_errors to performance data
- Created Python 3 versions of both scripts
- Renamed scripts for clarity:
  - check_esxi_raid65 -> check_esxcli_hparray_MegaRAID.sh
  - check_raid_physical_server_not_esxi -> check_hparray_MegaRAID.sh

### v1.6
- Added patrol read status
- Added long output for Nagios web interface
- Updated physical server script with all ESXi features

### v1.5
- Rebuild progress with percentage
- Consistency check status
- SSD wear level monitoring
- Drive temperature monitoring

### v1.4
- Controller health monitoring
- Write cache status
- Foreign config detection
- Hot spare monitoring
- Predictive failure detection
- Multiple controller support (-c option)

### v1.3
- ESXCLI existence check
- Performance data
- Timeout handling
- Battery/cachevault check

### v1.2
- DEBUG environment variable
- NO_CHECK file support
- Specific VD checking (-v option)

### v1.1
- translate_status function
- Physical disk checking

### v1.0
- Initial storcli support
- Auto-detection of controller type
