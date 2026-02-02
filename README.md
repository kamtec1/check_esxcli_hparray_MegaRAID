# Nagios RAID Checks (HPE Smart Array + MegaRAID)

Lightweight Nagios RAID checker for ESXi 7/8 and physical servers. Supports HPE Smart Array (ssacli) and MegaRAID (storcli) controllers. MegaRAID (storcli) is used on Gen10P/Gen11 and is also applicable to Gen10 servers that ship with MegaRAID.

## Scripts

- ESXi (remote via ESXCLI):
  - `check_esxcli_hparray_MegaRAID.sh`
  - `check_esxcli_hparray_MegaRAID.py`
- Physical servers (local via storcli64):
  - `check_hparray_MegaRAID.sh`
  - `check_hparray_MegaRAID.py`

## Requirements

- ESXi: ESXCLI installed at `/opt/vmware-vsphere-cli-distrib/lib/bin/esxcli/esxcli`
- Physical: StorCLI at `/opt/MegaRAID/storcli/storcli64`
- Python scripts require Python 3.7+

## ESXi VIB Requirement

The HPE VIB bundle (ssacli/storcli) must be installed on the ESXi host, or use the official HPE ESXi image that includes it. See the HPE software download page (revision history) for the appropriate ESXi image/VIB bundle:
```
https://support.hpe.com/connect/s/softwaredetails?language=en_US&collectionId=MTX-4899e6b54e3941a4&tab=revisionHistory
```

## Quick Start

ESXi (bash):
```bash
./check_esxcli_hparray_MegaRAID.sh -h 10.10.10.20 -u nagios
```

ESXi (python):
```bash
./check_esxcli_hparray_MegaRAID.py -H 10.10.10.20 -u nagios
```

Physical (bash):
```bash
./check_hparray_MegaRAID.sh -c 0
```

Physical (python):
```bash
./check_hparray_MegaRAID.py -c 0
```

## Usage Examples

Short OK output (default, good for SMS gateways):
```bash
./check_esxcli_hparray_MegaRAID.sh -h 10.10.10.20 -u nagios
```

Verbose output with details:
```bash
TERSE_OUTPUT=0 ./check_esxcli_hparray_MegaRAID.sh -h 10.10.10.20 -u nagios
```

Include perfdata only:
```bash
ENABLE_PERFDATA=1 ./check_esxcli_hparray_MegaRAID.sh -h 10.10.10.20 -u nagios
```

## Nagios / NRPE Example

If you run the ESXi check via NRPE, define it on the NRPE host:
```
command[ESXI_RAID]=/usr/lib/nagios/plugins/check_esxcli_hparray_MegaRAID.sh -h 10.10.10.20 -u nagios
```

Then call it from Nagios (increase timeout if needed):
```
check_nrpe -H nrpe-host.example.com -c ESXI_RAID -t 30
```

## Configuration

- ESXi SSL thumbprints are defined at the top of the ESXi scripts. Add hosts there.
- Update the ESXCLI path if it differs from the default.
- Maintenance mode: create `/tmp/NO_CHECK` to skip checks.

## Output Controls (Env Vars)

These apply to all scripts unless noted.

- `TERSE_OUTPUT=1` (default) keeps OK output short. Set `TERSE_OUTPUT=0` for verbose lines.
- `ENABLE_PERFDATA=1` adds Nagios perfdata (default off).
- `ENABLE_LONG_OUTPUT=1` adds multi-line details (default off).
- `SHOW_HOST=1` appends host to output (ESXi scripts only, default off).

## Notes

- MegaRAID cache/battery OK can fall back to Energy Pack status when CacheVault/BBU commands are unsupported on ESXi.
- The scripts follow standard Nagios exit codes (0/1/2/3).

## Example Output (Verbose)

Set `TERSE_OUTPUT=0` and `SHOW_HOST=1` to get verbose legacy-style output:
```bash
# HPE Gen8/9 (Smart Array)
TERSE_OUTPUT=0 SHOW_HOST=1 ./check_esxi_raid65 -h 10.10.10.10 -u nagios
RAID OK - (HPE Smart Array P408i-a SR Gen10 in Slot 0 (Embedded) Array A logicaldrive 1 (2.18 TB, RAID 6, OK)) - 10.10.10.10

TERSE_OUTPUT=0 SHOW_HOST=1 ./check_esxi_raid65 -h 10.10.10.30 -u nagios
RAID OK - (HPE Smart Array P408i-a SR Gen10 in Slot 0 (Embedded) Array A logicaldrive 1 (279.37 GB, RAID 1, OK)) - 10.10.10.30

# HPE Gen10/11 (MegaRAID)
TERSE_OUTPUT=0 SHOW_HOST=1 ./check_esxi_raid65 -h 10.10.10.20 -u nagios
RAID OK (MegaRAID) - All 1 Virtual Drives Optimal (VD0/238:Optimal) - 10.10.10.20
```

check_esxcli_hparray_MegaRAID
check_hparray_MegaRAID

## License

GPL v2.0 (see script headers).
