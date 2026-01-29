Example:

HPe Gen 8/9 
[root@nagios]# ./check_esxi_raid65 -h 10.10.10.10 -u nagios
RAID OK - (HPE Smart Array P408i-a SR Gen10 in Slot 0 (Embedded) Array A logicaldrive 1 (2.18 TB, RAID 6, OK)) - 10.10.10.10

[root@nagios]# ./check_esxi_raid65 -h 10.10.10.30 -u nagios
RAID OK - (HPE Smart Array P408i-a SR Gen10 in Slot 0 (Embedded) Array A logicaldrive 1 (279.37 GB, RAID 1, OK)) - 10.10.10.30

HPe Gen 10/11
[root@nagios]# ./check_esxi_raid65 -h 10.10.10.20 -u nagios
RAID OK (MegaRAID) - All 1 Virtual Drives Optimal (VD0/238:Optimal ) - 10.10.10.20

