# Repository Guidelines

## Project Structure & Module Organization
- Root directory holds the Nagios plugin scripts.
- ESXi (remote via ESXCLI): `check_esxcli_hparray_MegaRAID.sh`, `check_esxcli_hparray_MegaRAID.py`.
- Physical servers (local via StorCLI): `check_hparray_MegaRAID.sh`, `check_hparray_MegaRAID.py`.
- `CLAUDE.md` documents script usage, thresholds, and operational notes.
- There are no separate test or build directories.

## Build, Test, and Development Commands
- No build step; run scripts directly.
- ESXi Bash example:
  ```bash
  ./check_esxcli_hparray_MegaRAID.sh -h 10.10.10.20 -u nagios
  ```
- ESXi Python example:
  ```bash
  ./check_esxcli_hparray_MegaRAID.py -H 10.10.10.20 -u nagios
  ```
- Physical server Bash example:
  ```bash
  ./check_hparray_MegaRAID.sh -c 0
  ```
- Physical server Python example:
  ```bash
  ./check_hparray_MegaRAID.py -c 0
  ```
- Debug mode for shell scripts: `DEBUG=1 ./check_hparray_MegaRAID.sh`.
- Maintenance bypass: create `/tmp/NO_CHECK` to skip checks.

## Coding Style & Naming Conventions
- Shell scripts target POSIX `sh`; keep compatibility (no Bash-only features unless already used).
- Python scripts require Python 3.7+ and follow straightforward, module-level constants + `dataclass` usage.
- Follow existing naming: `check_*_MegaRAID.{sh,py}`; keep Nagios exit codes (0/1/2/3).
- Prefer uppercase constants for thresholds and exit codes; keep existing output formats and perfdata keys.

## Testing Guidelines
- There is no automated test suite in this directory.
- Validate changes by running the affected script against a safe test host or mocked output.
- Confirm Nagios exit codes and perfdata output remain stable.

## Commit & Pull Request Guidelines
- This directory is not a Git repository, so no commit history is available.
- If you add version control, use clear imperative commit messages (e.g., "Add media error threshold check").
- For pull requests, include a short summary, affected scripts, and example output (OK/WARNING/CRITICAL).

## Configuration & Security Notes
- ESXi Python script reads thumbprints from the `ESX_THUMBPRINTS` map; update it when adding hosts.
- ESXCLI path default: `/opt/vmware-vsphere-cli-distrib/lib/bin/esxcli/esxcli`.
- StorCLI path default: `/opt/MegaRAID/storcli/storcli64`.
- Physical server Bash script uses `timeout` when available to enforce `-t`.
- Output verbosity is controlled via env vars: `ENABLE_PERFDATA=1`, `ENABLE_LONG_OUTPUT=1` (defaults off), `SHOW_HOST=1` to append the host for ESXi checks, and `TERSE_OUTPUT=1` (default on) to minimize OK output. Short output includes battery/cache tokens when available.
- ESXi SSL thumbprints are maintained at the top of the ESXi scripts for quick editing.
- Avoid logging credentials; keep usernames in CLI args and store passwords in Nagios/monitoring config.
