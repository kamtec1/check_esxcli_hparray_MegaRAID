Project Information (Full Description)

  Nagios RAID checker for ESXi 7/8 and physical servers. Supports HPE Smart Array (ssacli) and MegaRAID (storcli) controllers. MegaRAID (storcli) is used on Gen10P/Gen11 and also applies to
  Gen10 servers that ship with MegaRAID.
  Short output is optimized for SMS gateways, with optional verbose output, perfdata, and long output.

  Requirements

  - ESXi: ESXCLI at /opt/vmware-vsphere-cli-distrib/lib/bin/esxcli/esxcli
  - Physical servers: StorCLI at /opt/MegaRAID/storcli/storcli64
  - Python scripts require Python 3.7+
  - HPE VIB bundle must be installed on ESXi (or use HPE official ESXi image).
    https://support.hpe.com/connect/s/softwaredetails?language=en_US&collectionId=MTX-4899e6b54e3941a4&tab=revisionHistory

  Configuration

  - Update ESXi SSL thumbprints at the top of ESXi scripts.
  - Update ESXCLI path if it differs from the default.
  - /tmp/NO_CHECK skips checks (maintenance mode).

  Examples (Verbose)

  # HPE Gen8/9 (Smart Array)
  TERSE_OUTPUT=0 SHOW_HOST=1 ./check_esxi_raid65 -h 10.10.10.10 -u nagios
  RAID OK - (HPE Smart Array P408i-a SR Gen10 in Slot 0 (Embedded) Array A logicaldrive 1 (2.18 TB, RAID 6, OK)) - 10.10.10.10

  TERSE_OUTPUT=0 SHOW_HOST=1 ./check_esxi_raid65 -h 10.10.10.30 -u nagios
  RAID OK - (HPE Smart Array P408i-a SR Gen10 in Slot 0 (Embedded) Array A logicaldrive 1 (279.37 GB, RAID 1, OK)) - 10.10.10.30

  # HPE Gen10/11 (MegaRAID)
  TERSE_OUTPUT=0 SHOW_HOST=1 ./check_esxi_raid65 -h 10.10.10.20 -u nagios
  RAID OK (MegaRAID) - All 1 Virtual Drives Optimal (VD0/238:Optimal) - 10.10.10.20

  Default (Short)

  ./check_esxi_raid65 -h 10.10.10.20 -u nagios
  RAID OK (MegaRAID)
