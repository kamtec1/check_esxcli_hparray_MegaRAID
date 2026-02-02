#!/usr/bin/env python3
"""
Nagios plugin for MegaRAID RAID monitoring on ESXi servers via ESXCLI
Version: v1.7
"""

import argparse
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from typing import List, Tuple

# ESXi SSL thumbprints (edit this list)
ESX_THUMBPRINTS = {
    "10.10.10.10": "55:45:DE:29:38:59:0F:02:F3:1D:57:81:38:99:68:96:37:BE:89:E2",
    "10.10.10.20": "5E:BF:B4:AF:A4:7E:F9:CF:71:D2:AB:16:86:68:80:A2:49:59:80:8B",
    "10.10.10.30": "DD:B5:4F:11:FA:8B:09:2A:40:3E:28:C0:AE:C0:08:68:E3:EC:E1:A8",
}

ESXCLI_PATH = "/opt/vmware-vsphere-cli-distrib/lib/bin/esxcli/esxcli"
ENABLE_PERFDATA = os.getenv("ENABLE_PERFDATA", "0").lower() in ("1", "true", "yes")
ENABLE_LONG_OUTPUT = os.getenv("ENABLE_LONG_OUTPUT", "0").lower() in ("1", "true", "yes")
SHOW_HOST = os.getenv("SHOW_HOST", "0").lower() in ("1", "true", "yes")
TERSE_OUTPUT = os.getenv("TERSE_OUTPUT", "1").lower() in ("1", "true", "yes")

# Nagios exit codes
STATE_OK = 0
STATE_WARNING = 1
STATE_CRITICAL = 2
STATE_UNKNOWN = 3

# Default thresholds
TEMP_WARN = 50
TEMP_CRIT = 60
SSD_WEAR_WARN = 20
SSD_WEAR_CRIT = 10
MEDIA_ERROR_WARN = 1
MEDIA_ERROR_CRIT = 10
OTHER_ERROR_WARN = 1


@dataclass
class RaidStatus:
    """Container for RAID status data"""
    vd_total: int = 0
    vd_ok: int = 0
    vd_warn: int = 0
    vd_crit: int = 0
    pd_total: int = 0
    pd_ok: int = 0
    pd_warn: int = 0
    pd_crit: int = 0
    spare_count: int = 0
    max_temp: int = 0
    media_errors: int = 0
    other_errors: int = 0
    ctrl_status: str = ""
    battery_status: str = ""
    hotspare_status: str = ""
    rebuild_status: str = ""
    cc_status: str = ""
    patrol_status: str = ""
    warnings: List[str] = field(default_factory=list)
    critical_warnings: List[str] = field(default_factory=list)
    long_output: List[str] = field(default_factory=list)


class ESXiStorCLIRunner:
    """Executes storcli commands via ESXi ESXCLI"""

    def __init__(self, host: str, user: str, timeout: int = 60, controller: str = "0"):
        self.host = host
        self.user = user
        self.timeout = timeout
        self.controller = controller
        self.thumb = ESX_THUMBPRINTS.get(host, "")

    def run(self, cmd: str) -> Tuple[str, int]:
        """Run a storcli command via esxcli and return output and exit code"""
        try:
            full_cmd = [
                ESXCLI_PATH, "-s", self.host, "-u", self.user,
                "-d", self.thumb, "storcli"
            ] + cmd.split()

            result = subprocess.run(
                full_cmd,
                capture_output=True,
                text=True,
                timeout=self.timeout
            )
            return result.stdout + result.stderr, result.returncode
        except subprocess.TimeoutExpired:
            return f"Timeout after {self.timeout}s", 124
        except Exception as e:
            return str(e), 1


def translate_status(status: str) -> str:
    """Translate storcli status codes to readable names"""
    translations = {
        'Optl': 'Optimal', 'Dgrd': 'Degraded', 'Rbld': 'Rebuilding',
        'Offln': 'Offline', 'OfLn': 'Offline', 'Pdgd': 'Partially Degraded',
        'Rec': 'Recovering', 'Failed': 'Failed', 'Msng': 'Missing',
        'Onln': 'Online', 'UBad': 'Unconfigured Bad',
    }
    return translations.get(status, status)


class RaidChecker:
    """Main RAID checking class"""

    def __init__(self, runner: ESXiStorCLIRunner, vd_num: str = None):
        self.runner = runner
        self.vd_num = vd_num
        self.status = RaidStatus()
        self.vd_output = ""
        self.pd_output = ""

    def check_all(self) -> Tuple[int, str]:
        """Run all checks and return exit code and message"""
        ctrl = f"/c{self.runner.controller}"
        self.vd_output, _ = self.runner.run(f"{ctrl}/vall show")
        self.pd_output, _ = self.runner.run(f"{ctrl}/eall/sall show")

        self.check_controller_health()
        self.check_battery()
        self.check_foreign_config()
        self.check_predictive_failure()
        self.check_smart_data()
        self.check_rebuild_progress()
        self.check_consistency_check()
        self.check_ssd_wear()
        self.check_drive_temperature()
        self.check_patrol_read()
        self.check_hotspare()
        self.build_perfdata()
        if ENABLE_LONG_OUTPUT:
            self.build_long_output()

        return self.evaluate_status()

    def check_controller_health(self):
        ctrl = f"/c{self.runner.controller}"
        output, _ = self.runner.run(f"{ctrl} show")
        match = re.search(r'Controller Status\s*:\s*(\S+)', output, re.IGNORECASE)
        if match:
            state = match.group(1)
            if re.match(r'(Optimal|OK|Good)', state, re.IGNORECASE):
                self.status.ctrl_status = "Controller:OK"
            else:
                self.status.ctrl_status = f"Controller:{state}"
                self.status.warnings.append(f"Controller status: {state}")

    def check_battery(self):
        ctrl = f"/c{self.runner.controller}"
        cv_output, _ = self.runner.run(f"cachevault show status -i {self.runner.controller}")
        match = None if "unsupported command" in cv_output.lower() else re.search(
            r'(?:State|Status)\s*[:=]\s*(\S+)', cv_output, re.IGNORECASE
        )
        if not match:
            alt_output, _ = self.runner.run(f"cachevault show basic -i {self.runner.controller}")
            match = None if "unsupported command" in alt_output.lower() else re.search(
                r'(?:State|Status)\s*[:=]\s*(\S+)', alt_output, re.IGNORECASE
            )
        if not match:
            alt_output, _ = self.runner.run(f"cachevault show all -i {self.runner.controller}")
            match = None if "unsupported command" in alt_output.lower() else re.search(
                r'(?:State|Status)\s*[:=]\s*(\S+)', alt_output, re.IGNORECASE
            )
        if not match:
            ctrl_output, _ = self.runner.run(f"controller show -i {self.runner.controller}")
            match = re.search(r'CacheVault.*?(?:State|Status)\s*[:=]\s*(\S+)', ctrl_output, re.IGNORECASE)
        if match:
            state = match.group(1)
            if re.match(r'(Optimal|Good)', state, re.IGNORECASE):
                self.status.battery_status = "CV:OK"
            else:
                self.status.battery_status = f"CV:{state}"
                if not re.match(r'(Optimal|Good)', state, re.IGNORECASE):
                    self.status.warnings.append(f"CacheVault {state}")

        bbu_output, _ = self.runner.run(f"battery show status -i {self.runner.controller}")
        match = None if "unsupported command" in bbu_output.lower() else re.search(
            r'(?:State|Status)\s*[:=]\s*(\S+)', bbu_output, re.IGNORECASE
        )
        if not match:
            alt_output, _ = self.runner.run(f"battery show basic -i {self.runner.controller}")
            match = None if "unsupported command" in alt_output.lower() else re.search(
                r'(?:State|Status)\s*[:=]\s*(\S+)', alt_output, re.IGNORECASE
            )
        if not match:
            alt_output, _ = self.runner.run(f"battery show all -i {self.runner.controller}")
            match = None if "unsupported command" in alt_output.lower() else re.search(
                r'(?:State|Status)\s*[:=]\s*(\S+)', alt_output, re.IGNORECASE
            )
        if not match:
            ctrl_output, _ = self.runner.run(f"controller show -i {self.runner.controller}")
            match = re.search(r'(?:BBU|Battery).*?(?:State|Status)\s*[:=]\s*(\S+)', ctrl_output, re.IGNORECASE)
        if match:
            state = match.group(1)
            if re.match(r'(Optimal|Good|OK)', state, re.IGNORECASE):
                bbu_status = "BBU:OK"
            else:
                bbu_status = f"BBU:{state}"
                self.status.warnings.append(f"BBU {state}")
            if self.status.battery_status:
                self.status.battery_status += f" {bbu_status}"
            else:
                self.status.battery_status = bbu_status

        if not self.status.battery_status:
            ctrl_output, _ = self.runner.run(f"controller show all -i {self.runner.controller}")
            ep_present = re.search(r'Energy Pack\s*=\s*(\S+)', ctrl_output, re.IGNORECASE)
            ep_status = re.search(r'Energy Pack Status\s*=\s*(\S+)', ctrl_output, re.IGNORECASE)
            present_val = ep_present.group(1) if ep_present else ""
            status_val = ep_status.group(1) if ep_status else ""
            if present_val or status_val:
                if re.match(r'(Present|Yes)', present_val, re.IGNORECASE):
                    if not status_val or status_val == "0" or re.match(r'(OK|Optimal|Good)', status_val, re.IGNORECASE):
                        self.status.battery_status = "Cache:OK Battery:OK"
                    else:
                        self.status.battery_status = f"Cache:EP{status_val} Battery:EP{status_val}"
                        self.status.warnings.append(f"Energy Pack status {status_val}")
                elif re.match(r'(Absent|No)', present_val, re.IGNORECASE):
                    self.status.warnings.append("Energy Pack Absent")

    def check_foreign_config(self):
        ctrl = f"/c{self.runner.controller}"
        output, _ = self.runner.run(f"{ctrl}/fall show")
        if re.search(r'foreign configuration|DG', output, re.IGNORECASE):
            foreign_count = len(re.findall(r'^[0-9]+', output, re.MULTILINE))
            if foreign_count > 0:
                self.status.warnings.append(f"Foreign config detected ({foreign_count})")

    def check_predictive_failure(self):
        ctrl = f"/c{self.runner.controller}"
        output, _ = self.runner.run(f"{ctrl}/eall/sall show all")
        if re.search(r'Predictive.*Yes', output, re.IGNORECASE):
            pred_drives = []
            for match in re.finditer(r'(\d+:\d+).*?Predictive.*?Yes', output, re.IGNORECASE | re.DOTALL):
                pred_drives.append(match.group(1))
            if pred_drives:
                self.status.warnings.append(f"Predictive failure on: {', '.join(pred_drives)}")

    def check_smart_data(self):
        ctrl = f"/c{self.runner.controller}"
        output, _ = self.runner.run(f"{ctrl}/eall/sall show all")
        pd_list = re.findall(r'^(\d+:\d+)', self.pd_output, re.MULTILINE)

        for drive in pd_list:
            pattern = rf'(Drive\s+{re.escape(drive)}|^{re.escape(drive)}).*?(?=Drive\s+\d+:\d+|$)'
            match = re.search(pattern, output, re.IGNORECASE | re.DOTALL)
            if not match:
                continue
            section = match.group(0)

            media_match = re.search(r'Media Error.*?(\d+)', section, re.IGNORECASE)
            if media_match:
                count = int(media_match.group(1))
                if count > 0:
                    self.status.media_errors += count
                    if count >= MEDIA_ERROR_CRIT:
                        self.status.critical_warnings.append(f"Drive {drive}: {count} media errors")
                    elif count >= MEDIA_ERROR_WARN:
                        self.status.warnings.append(f"Drive {drive}: {count} media errors")

            other_match = re.search(r'Other Error.*?(\d+)', section, re.IGNORECASE)
            if other_match:
                count = int(other_match.group(1))
                if count > 0:
                    self.status.other_errors += count
                    if count >= OTHER_ERROR_WARN:
                        self.status.warnings.append(f"Drive {drive}: {count} other errors")

            shield_match = re.search(r'Shield Counter.*?(\d+)', section, re.IGNORECASE)
            if shield_match:
                count = int(shield_match.group(1))
                if count > 0:
                    self.status.warnings.append(f"Drive {drive}: {count} shield errors")

            bbm_match = re.search(r'BBM Error.*?(\d+)', section, re.IGNORECASE)
            if bbm_match:
                count = int(bbm_match.group(1))
                if count > 0:
                    self.status.warnings.append(f"Drive {drive}: {count} BBM errors")

    def check_rebuild_progress(self):
        if ' Rbld ' in self.vd_output:
            ctrl = f"/c{self.runner.controller}"
            output, _ = self.runner.run(f"{ctrl}/vall show rebuild")
            match = re.search(r'Progress.*?(\d+)%', output, re.IGNORECASE)
            if match:
                self.status.rebuild_status = f"Rebuild:{match.group(1)}%"
            else:
                self.status.rebuild_status = "Rebuild:InProgress"

    def check_consistency_check(self):
        ctrl = f"/c{self.runner.controller}"
        output, _ = self.runner.run(f"{ctrl}/vall show cc")
        if re.search(r'\d+%|in progress', output, re.IGNORECASE):
            match = re.search(r'(\d+)%', output)
            if match:
                self.status.cc_status = f"CC:{match.group(1)}%"
            else:
                self.status.cc_status = "CC:Running"

    def check_ssd_wear(self):
        ctrl = f"/c{self.runner.controller}"
        output, _ = self.runner.run(f"{ctrl}/eall/sall show all")
        ssd_drives = re.findall(r'^(\d+:\d+).*SSD', self.pd_output, re.MULTILINE | re.IGNORECASE)
        for drive in ssd_drives:
            pattern = rf'Drive\s+{re.escape(drive)}.*?(?=Drive\s+\d+:\d+|$)'
            match = re.search(pattern, output, re.IGNORECASE | re.DOTALL)
            if match:
                section = match.group(0)
                wear_match = re.search(r'(Life Left|Wear|Wearout).*?(\d+)', section, re.IGNORECASE)
                if wear_match:
                    remaining = int(wear_match.group(2))
                    if remaining <= SSD_WEAR_CRIT:
                        self.status.critical_warnings.append(f"SSD {drive} wear critical ({remaining}% left)")
                    elif remaining <= SSD_WEAR_WARN:
                        self.status.warnings.append(f"SSD {drive} wear warning ({remaining}% left)")

    def check_drive_temperature(self):
        ctrl = f"/c{self.runner.controller}"
        output, _ = self.runner.run(f"{ctrl}/eall/sall show all")
        temps = re.findall(r'(?:Drive\s+)?Temperature.*?(\d+)', output, re.IGNORECASE)
        for temp_str in temps:
            temp = int(temp_str)
            if 0 < temp < 100:
                if temp > self.status.max_temp:
                    self.status.max_temp = temp
                if temp >= TEMP_CRIT:
                    self.status.critical_warnings.append(f"Drive overheating ({temp}C)")
                elif temp >= TEMP_WARN:
                    self.status.warnings.append(f"Drive temperature high ({temp}C)")

    def check_patrol_read(self):
        ctrl = f"/c{self.runner.controller}"
        output, _ = self.runner.run(f"{ctrl} show patrolread")
        match = re.search(r'State\s*:\s*(\S+)', output, re.IGNORECASE)
        if match:
            state = match.group(1)
            if re.match(r'(Active|Running)', state, re.IGNORECASE):
                progress_match = re.search(r'Progress.*?(\d+)%', output, re.IGNORECASE)
                if progress_match:
                    self.status.patrol_status = f"PR:{progress_match.group(1)}%"
                else:
                    self.status.patrol_status = "PR:Running"
            elif re.match(r'(Stopped|Paused)', state, re.IGNORECASE):
                self.status.patrol_status = "PR:Stopped"

    def check_hotspare(self):
        spare_ok = len(re.findall(r'(DHS|GHS)', self.pd_output, re.IGNORECASE))
        ugood_count = len(re.findall(r'UGood', self.pd_output, re.IGNORECASE))
        pd_total = self.status.pd_total or len(re.findall(r'^(\d+:\d+)', self.pd_output, re.MULTILINE))
        self.status.spare_count = spare_ok
        if spare_ok > 0:
            self.status.hotspare_status = f"Spares:{spare_ok}"
        elif ugood_count > 0:
            self.status.hotspare_status = f"UGood:{ugood_count}"
        else:
            self.status.hotspare_status = "Spares:0"
            if pd_total > 2:
                self.status.warnings.append("No hot spares configured")

    def build_perfdata(self):
        vd_lines = re.findall(r'^(\d+/\d+)\s+RAID\S*\s+(\S+)', self.vd_output, re.MULTILINE)
        self.status.vd_total = len(vd_lines)
        for vd_id, state in vd_lines:
            if state == 'Optl':
                self.status.vd_ok += 1
            elif state in ('Rbld', 'Pdgd'):
                self.status.vd_warn += 1
            else:
                self.status.vd_crit += 1

        pd_lines = re.findall(r'^(\d+:\d+)\s+\d+\s+(\S+)', self.pd_output, re.MULTILINE)
        self.status.pd_total = len(pd_lines)
        for pd_id, state in pd_lines:
            if state == 'Onln':
                self.status.pd_ok += 1
            elif state == 'Rbld':
                self.status.pd_warn += 1
            elif state in ('Offln', 'Failed', 'UBad', 'Msng'):
                self.status.pd_crit += 1

    def build_long_output(self):
        self.status.long_output.append("--- Virtual Drives ---")
        for match in re.finditer(r'^(\d+/\d+)\s+(RAID\S*)\s+(\S+).*?(\S+)\s*$', self.vd_output, re.MULTILINE):
            vd_id, raid_type, state, name = match.groups()
            self.status.long_output.append(f"VD{vd_id}: {raid_type} {state} ({name})")
        self.status.long_output.append("")
        self.status.long_output.append("--- Status ---")
        if self.status.ctrl_status:
            self.status.long_output.append(f"Controller: {self.status.ctrl_status}")
        if self.status.battery_status:
            self.status.long_output.append(f"Battery: {self.status.battery_status}")
        if self.status.hotspare_status:
            self.status.long_output.append(f"Hot Spares: {self.status.hotspare_status}")
        if self.status.patrol_status:
            self.status.long_output.append(f"Patrol Read: {self.status.patrol_status}")
        if self.status.cc_status:
            self.status.long_output.append(f"Consistency Check: {self.status.cc_status}")
        if self.status.rebuild_status:
            self.status.long_output.append(f"Rebuild: {self.status.rebuild_status}")
        if self.status.max_temp > 0:
            self.status.long_output.append(f"Max Temperature: {self.status.max_temp}C")
        if self.status.media_errors > 0:
            self.status.long_output.append(f"Total Media Errors: {self.status.media_errors}")
        if self.status.other_errors > 0:
            self.status.long_output.append(f"Total Other Errors: {self.status.other_errors}")

    def evaluate_status(self) -> Tuple[int, str]:
        s = self.status
        perfdata = (f"| vd_total={s.vd_total} vd_ok={s.vd_ok} vd_warn={s.vd_warn} "
                    f"vd_crit={s.vd_crit} pd_total={s.pd_total} pd_ok={s.pd_ok} "
                    f"pd_warn={s.pd_warn} pd_crit={s.pd_crit} spares={s.spare_count} "
                    f"max_temp={s.max_temp}C media_errors={s.media_errors} "
                    f"other_errors={s.other_errors}")
        perf_suffix = f" {perfdata}" if ENABLE_PERFDATA else ""
        host_suffix = f" - {self.runner.host}" if SHOW_HOST else ""
        long_out = "\n" + "\n".join(s.long_output) if ENABLE_LONG_OUTPUT and s.long_output else ""

        vd_lines = re.findall(r'^(\d+)/(\d+)\s+RAID\S*\s+(\S+).*?(\S+)\s*$', self.vd_output, re.MULTILINE)

        if self.vd_num:
            vd_lines = [(c, v, st, n) for c, v, st, n in vd_lines if v == self.vd_num]
            if not vd_lines:
                return STATE_CRITICAL, f"RAID CRITICAL - Virtual Drive {self.vd_num} not found"

        non_optimal = [(c, v, st, n) for c, v, st, n in vd_lines if st != 'Optl']
        if non_optimal:
            ctrl_id, vd_id, state, name = non_optimal[0]
            readable = translate_status(state)
            rebuild_info = f" [{s.rebuild_status}]" if s.rebuild_status else ""
            if state in ('Rbld', 'Pdgd'):
                if TERSE_OUTPUT:
                    msg = f"RAID WARNING (MegaRAID) - VD{vd_id} {readable}"
                else:
                    msg = f"RAID WARNING (MegaRAID) - VD{vd_id} ({name}) Status: {readable}{rebuild_info}"
                return STATE_WARNING, f"{msg}{host_suffix}{perf_suffix}{long_out}"
            else:
                if TERSE_OUTPUT:
                    msg = f"RAID CRITICAL (MegaRAID) - VD{vd_id} {readable}"
                else:
                    msg = f"RAID CRITICAL (MegaRAID) - VD{vd_id} ({name}) Status: {readable}"
                return STATE_CRITICAL, f"{msg}{host_suffix}{perf_suffix}{long_out}"

        if s.critical_warnings:
            crit_msg = "; ".join(s.critical_warnings)
            if TERSE_OUTPUT:
                msg = f"RAID CRITICAL (MegaRAID) - {crit_msg}"
            else:
                vd_info = ", ".join([f"VD{v}:Optimal" for c, v, st, n in vd_lines])
                msg = f"RAID CRITICAL (MegaRAID) - VDs Optimal but: {crit_msg} ({vd_info})"
            return STATE_CRITICAL, f"{msg}{host_suffix}{perf_suffix}{long_out}"

        if s.warnings:
            warn_msg = "; ".join(s.warnings)
            if TERSE_OUTPUT:
                msg = f"RAID WARNING (MegaRAID) - {warn_msg}"
            else:
                vd_info = ", ".join([f"VD{v}:Optimal" for c, v, st, n in vd_lines])
                msg = f"RAID WARNING (MegaRAID) - VDs Optimal but: {warn_msg} ({vd_info})"
            return STATE_WARNING, f"{msg}{host_suffix}{perf_suffix}{long_out}"

        extra = []
        if s.battery_status:
            extra.append(s.battery_status)
        if s.ctrl_status:
            extra.append(s.ctrl_status)
        if s.hotspare_status:
            extra.append(s.hotspare_status)
        if s.cc_status:
            extra.append(s.cc_status)
        if s.patrol_status:
            extra.append(s.patrol_status)
        if s.max_temp > 0:
            extra.append(f"Temp:{s.max_temp}C")
        extra_str = f" {' '.join(extra)}" if extra else ""

        if TERSE_OUTPUT:
            if self.vd_num:
                msg = f"RAID OK (MegaRAID) - VD{self.vd_num} Optimal"
            else:
                msg = "RAID OK (MegaRAID)"
        else:
            if self.vd_num:
                msg = f"RAID OK (MegaRAID) - VD{self.vd_num} Status: Optimal{extra_str}"
            else:
                vd_info = ", ".join([f"VD{v}:Optimal" for c, v, st, n in vd_lines])
                msg = f"RAID OK (MegaRAID) - All {s.vd_total} Virtual Drives Optimal ({vd_info}){extra_str}"

        return STATE_OK, f"{msg}{host_suffix}{perf_suffix}{long_out}"


def main():
    parser = argparse.ArgumentParser(
        description='Nagios plugin for MegaRAID RAID monitoring on ESXi servers',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s -H 10.10.10.20 -u nagios
  %(prog)s -H 10.10.10.20 -u nagios -v 0
  %(prog)s -H 10.10.10.20 -u nagios -c 1
"""
    )

    parser.add_argument('-H', '--host', required=True, help='ESXi host IP address')
    parser.add_argument('-u', '--user', required=True, help='Username for ESXi connection')
    parser.add_argument('-v', '--vd', help='Check specific virtual drive number')
    parser.add_argument('-c', '--controller', default='0', help='Controller ID (default: 0)')
    parser.add_argument('-t', '--timeout', type=int, default=60, help='Timeout in seconds (default: 60)')
    parser.add_argument('-V', '--version', action='version', version='%(prog)s v1.7')

    args = parser.parse_args()

    if args.host not in ESX_THUMBPRINTS:
        print(f"RAID UNKNOWN - Unknown host: {args.host} (no SSL thumbprint configured)")
        sys.exit(STATE_UNKNOWN)
    if not os.path.exists(ESXCLI_PATH):
        print(f"RAID UNKNOWN - esxcli not found at {ESXCLI_PATH}")
        sys.exit(STATE_UNKNOWN)
    if os.path.exists('/tmp/NO_CHECK'):
        print("RAID OK - Check skipped (maintenance mode)")
        sys.exit(STATE_OK)

    runner = ESXiStorCLIRunner(
        host=args.host,
        user=args.user,
        timeout=args.timeout,
        controller=args.controller
    )

    checker = RaidChecker(runner, vd_num=args.vd)

    try:
        exit_code, message = checker.check_all()
        print(message)
        sys.exit(exit_code)
    except Exception as e:
        print(f"RAID UNKNOWN - Error: {e}")
        sys.exit(STATE_UNKNOWN)


if __name__ == '__main__':
    main()
