# doRoCE linux

doRoCE configures and sets persistency behavior for optimal RoCE deployments
it supports both MLNX-OFED and upstream deployments

NOTE - this script aggregates steps described in the Mellanox-NVIDIA community
pages and provided as a reference for recipe implementation

It is recommended for use during bring-up and that you implement only
required components for deployment in production environments

use "-h" for more details


# nv-mlnxipcfg.py

nv-mlnxipcfg.py configures and sets persistency behavior for IP addresses, IP rules, IP route, and ARP settings

Requires: Python 3.x and python3-click

nv-mlnxipcfg.py --help

Usage: nv-mlnxipcfg.py [OPTIONS]

Options:
  -v, --verbose       verbose logging
  -i, --ipaddr TEXT   Starting IP address with netmask (for example:
                      192.168.1.1/24 or 2001::66/64)  [required]
  -f, --flush         Flush IP addresses before adding new ones
  -r, --dryrun        Dry run. Do not actually assign IP addresses or add
                      netplan cfg
  -d, --devices TEXT  comma separated device list (for example:
                      enp225s0f0,enp225s0f1) if '-d' not provided, tool will
                      configure all found Ethernet devices
  --help              Show this message and exit.
```
Debian/Ubuntu Based OS
======================
1. A required configuration of a starting IP address (IPv4 or IPv6) with netmask (i.e. 192.168.1.1/24) is provided.
2. It then looks at all the Infiniband interfaces it can find (under /sys/class/infiniband/*)
3. It then checks to make sure they are "Ethernet" link_type by checking /sys/class/infiniband/{}/ports/*/link_layer
4. If the flush option is provided (-f or --flush) it will remove all the IP address first on the interface (ip addr flush ...)
5. Now for all the Ethernet type interfaces, it adds an IP address starting with the one provided.
6. It will then run 3 ip route and one ip rule commands using the source IP address and a default gateway (Note: I assume the default gateway is one IP address less then the broadcast address for the network provided):
  a. ip route add 0.0.0.0/1 via {} dev {} table {} proto static metric {}
  b. ip route add {} dev {} table {} proto static scope link src {} metric {}
  c. ip route add 128.0.0.0/1 via {} dev {} table {} proto static metric {}
  d. ip rule add from {} table {} priority 32761
7. It will then run the sysctl command and set the following for each interface
  a. net.ipv4.conf.{}.arp_accept=1
  b. net.ipv4.conf.{}.arp_announce = 1
  c. net.ipv4.conf.{}.arp_filter = 0
  d. net.ipv4.conf.{}.rp_filter = 2
  e. net.ipv4.conf.{}.arp_ignore = 1
8. After that, it will create a netplan configuration with the IP addresses, routes, and route-policy as shown in the docs I was provided with the same config used in the ip addr add , ip route and ip rule commands. The file it will write to maintain persistence is called /etc/netplan/55-nvidia-autoconfig.yaml.
9. The sysctl configuration file is constructed with the same values for each interface for the 5 ARP and RP settings and written to /etc/sysctl.d/55-nvidia-arpdefaults.conf

RHEL Based OS
=============
To support for RHEL and CENTOS servers, the ifcfg and route scripts are written to

      /etc/sysconfig/network-scripts/

These are needed for persistence upon reboot.

In addition to the previous configs (ip addr add, ip route, ip rule, sysctl ARP settings) for RHEL servers,
this script adds an ifcfg and route config file for each interface on RHEL and CENTOS servers instead of a NETPLAN config file.

For example, for the single interface  enp225s0f0  with address 66.66.66.66/24:

[lab@cl1-fair-01 ~]$ cat  /etc/sysconfig/network-scripts/ifcfg-enp225s0f0
BOOTPROTO=none
NAME=enp225s0f0
DEVICE=enp225s0f0
ONBOOT=yes
IPADDR=66.66.66.66
PREFIX=24
DEFROUTE=yes
GATEWAY=66.66.66.254
ROUTING_RULE="priority 32761 from 66.66.66.66 table 101"
IPV4_FAILURE_FATAL=no
IPV6INIT=yes
IPV6_AUTOCONF=yes
IPV6_DEFROUTE=yes
IPV6_FAILURE_FATAL=no

[lab@cl1-fair-01 ~]$ cat  /etc/sysconfig/network-scripts/route-enp225s0f0
ADDRESS0=0.0.0.0
NETMASK0=128.0.0.0
GATEWAY0=66.66.66.254
METRIC0=101
OPTIONS0="table 101"
ADDRESS1=128.0.0.0
NETMASK1=128.0.0.0
GATEWAY1=66.66.66.254
METRIC1=101
OPTIONS1="table 101"
ADDRESS2=66.66.66.0
NETMASK2=255.255.255.0
METRIC2=101
OPTIONS2="onlink src 66.66.66.66 table 101"
