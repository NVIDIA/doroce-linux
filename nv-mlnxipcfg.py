#!/usr/bin/env python3

# The MIT License (MIT)
#
# Copyright (c) 2020, NVIDIA CORPORATION
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of
# this software and associated documentation files (the "Software"), to deal in
# the Software without restriction, including without limitation the rights to
# use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
# the Software, and to permit persons to whom the Software is furnished to do so,
# subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
# FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
# COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
# IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
# CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

import click
import glob
import ipaddress
import os
import re
import platform
import sys
import subprocess
import yaml
import pprint

@click.command()
#@click.argument('name')
@click.option('--verbose', '-v', help="verbose logging", is_flag=True)
@click.option('--ipaddr', '-i', required=True, help="Starting IP address with netmask (for example: 192.168.1.1/24 or 2001::66/64)")
@click.option('--flush', '-f', help="Flush IP addresses before adding new ones", is_flag=True)
@click.option('--dryrun', '-r', help="Dry run. Do not actually assign IP addresses or add netplan cfg", is_flag=True)
@click.option('--devices', '-d', help="""comma separated device list (for example: enp225s0f0,enp225s0f1) if '-d' not provided, tool will configure all found Ethernet devices""")
def main(ipaddr, devices, verbose, flush, dryrun):
    if devices is None:
        devices = get_mlnx_ethernet_ifnames()
    else:
        devices = devices.split(',')

    if verbose:
        print("devices are: {}".format(devices))
    if devices == []:
        print("Error: missing network devices to configure.")
        print("       Script could not find devices or -d")
        print("       was not provided. Please specify devices to work on.")
        sys.exit(1)

    try:
        ipaddr = ipaddress.ip_interface(ipaddr)
        network = ipaddr.network
        default = str(network.broadcast_address - 1)
        prefixlen = network.prefixlen
        network = str(network)
        subnet = str(ipaddr.network.network_address)
        netmask = str(ipaddr.netmask)
    except ValueError:
        print("Error: address/netmask {} is invalid:".format(ipaddr))
        sys.exit(1)

    osid = get_osid()
    count = 0
    netplanname = "/etc/netplan/55-nvidia-autoconfig.yaml"
    sysctlname = "/etc/sysctl.d/55-nvidia-arpdefaults.conf"
    netplancfg = {'network': {'version': 2, 'renderer': 'networkd', 'ethernets': {}}}
    sysctl_buf = ""
    currentip = ipaddr.ip
    tableid = 101
    for dev in devices:
        newip = str(currentip)
        if flush:
            flush_ip(dev, verbose)
        config_ip(dev, newip, prefixlen, default, network, tableid, verbose, dryrun)
        config_arp(dev, verbose, dryrun)
        config_netplan(dev, newip, prefixlen, default, network, tableid, netplancfg)
        if osid == 'rhel' or osid == 'centos':
            write_networkscripts(dev, newip, prefixlen, default, subnet, netmask, tableid, verbose, dryrun)
        sysctl_buf = sysctl_buf + get_sysctl(dev)

        count += 1
        currentip = currentip + 1
        tableid += 1

    if osid == 'ubuntu':
        write_netplan(netplancfg, netplanname, verbose, dryrun)
    write_sysctl(sysctl_buf, sysctlname, verbose, dryrun)

def get_osid():
    # Get the OS ID (rhel, ubuntu, or other)"
    release = '/etc/os-release'
    osid = ""
    if os.path.exists(release):
        with open('/etc/os-release') as f:
            read_data = f.read()
            osid = re.findall('(\nID=)"?(\w+)"?\n', read_data, re.M)
            # a tuple is returned with ID,value
            if len(osid) == 1:
                id,osid = osid[0]
            else:
                osid = ""
    return osid

def write_networkscripts(dev, newip, prefixlen, default, subnet, netmask, tableid, verbose, dryrun):
    """This function handles rhel network-scripts for each device"""
    ifcfgname = '/etc/sysconfig/network-scripts/ifcfg-{}'.format(dev)
    ifcfgbuf = """
BOOTPROTO=none
NAME={}
DEVICE={}
ONBOOT=yes
IPADDR={}
PREFIX={}
DEFROUTE=yes
GATEWAY={}
ROUTING_RULE="priority 32761 from {} table {}"
IPV4_FAILURE_FATAL=no
IPV6INIT=yes
IPV6_AUTOCONF=yes
IPV6_DEFROUTE=yes
IPV6_FAILURE_FATAL=no
""".format(dev, dev, newip, prefixlen, default, newip, tableid)
    if verbose:
        pprint.pprint("ifcfg cfg\n-----------\n{}".format(ifcfgbuf))
    try:
        if not dryrun:
            with open(ifcfgname, "w") as ifcfg:
                ifcfg.write(ifcfgbuf)
            print("wrote: ifcfg file {}".format(ifcfgname))
    except:
        print("Error: could not write ifcfg file {}".format(ifcfgname))

    routename = '/etc/sysconfig/network-scripts/route-{}'.format(dev)
    routebuf = """
ADDRESS0=0.0.0.0
NETMASK0=128.0.0.0
GATEWAY0={}
METRIC0={}
OPTIONS0="table {}"
ADDRESS1=128.0.0.0
NETMASK1=128.0.0.0
GATEWAY1={}
METRIC1={}
OPTIONS1="table {}"
ADDRESS2={}
NETMASK2={}
METRIC2={}
OPTIONS2="onlink src {} table {}"

""".format(default, tableid, tableid, default, tableid, tableid, subnet, netmask, tableid, newip, tableid)
    if verbose:
        pprint.pprint("route cfg\n-----------\n{}".format(routebuf))
    try:
        if not dryrun:
            with open(routename, "w") as route:
                route.write(routebuf)
            print("wrote: route file {}".format(routename))
    except:
        print("Error: could not write route file {}".format(routename))

    return

def write_netplan(netplancfg, netplanname, verbose, dryrun):
    if verbose:
        pprint.pprint("netplan cfg\n-----------\n{}".format(yaml.safe_dump(netplancfg)))
    try:
        if not dryrun:
            with open(netplanname, "w") as netplan:
                netplan.write(yaml.safe_dump(netplancfg))
    except:
        print("Error: could not write netplan file {}".format(netplanname))
        return

    print("nv-mlnsipcfg: wrote persistent config {}".format(netplanname))
    return

def write_sysctl(sysctl_buf, sysctlname, verbose, dryrun):
    if verbose:
        pprint.pprint("sysctl ARP settings\n-----------\n{}".format(sysctl_buf))
    try:
        if not dryrun:
            with open(sysctlname, "w") as sysctl:
                sysctl.write(sysctl_buf)
    except:
        print("Error: could not write sysctl ARP config file {}".format(sysctlname))
        return

    print("nv-mlnsipcfg: configured sysctl ARP settings")
    return

def config_netplan(dev, currentip, prefixlen, default, network, tableid, netplancfg):
    hostprefix = "{}/{}".format(currentip, prefixlen)
    netplancfg['network']['ethernets'][dev] = {}
    netplancfg['network']['ethernets'][dev]['addresses'] = [hostprefix]
    netplancfg['network']['ethernets'][dev]['routes'] = [
        {'metric': tableid, 'table': tableid, 'to': '0.0.0.0/1', 'via': default},
        {'metric': tableid, 'table': tableid, 'to': '128.0.0.0/1', 'via': default},
        {'from': currentip, 'metric': tableid, 'scope': 'link', 'table': tableid, 'to': network}]
    netplancfg['network']['ethernets'][dev]['routing-policy'] = [
        {'from': currentip, 'priority': 32761, 'table': tableid}]
    return

def get_sysctl(dev):
    return("""
net.ipv4.conf.{}.arp_accept = 1
net.ipv4.conf.{}.arp_announce = 1
net.ipv4.conf.{}.arp_filter = 0
net.ipv4.conf.{}.rp_filter = 2
net.ipv4.conf.{}.arp_ignore = 1
""".format(dev, dev, dev, dev, dev))


def config_arp(dev, verbose, dryrun):
    commandlist = []

    cmd = "/usr/sbin/sysctl -w net.ipv4.conf.{}.arp_accept=1".format(dev)
    commandlist.append(cmd)

    cmd = "/usr/sbin/sysctl -w net.ipv4.conf.{}.arp_announce=1".format(dev)
    commandlist.append(cmd)

    cmd = "/usr/sbin/sysctl -w net.ipv4.conf.{}.arp_filter=0".format(dev)
    commandlist.append(cmd)

    cmd = "/usr/sbin/sysctl -w net.ipv4.conf.{}.rp_filter=2".format(dev)
    commandlist.append(cmd)

    cmd = "/usr/sbin/sysctl -w net.ipv4.conf.{}.arp_ignore=1".format(dev)
    commandlist.append(cmd)

    for cmd in commandlist:
        try:
            if verbose:
                print(cmd)
            if not dryrun:
                rc = subprocess.check_output(cmd.split())
        except:
            print("Error: could not run command {}".format(cmd))
            print("       Continuing.")

    print("Configured sysctl ARP settings")
    return


def config_ip(dev, currentip, prefixlen, default, network, tableid, verbose, dryrun):
    commandlist = []
    hostprefix = "{}/{}".format(currentip, prefixlen)

    cmd = "/usr/sbin/ip addr add {} dev {}".format(hostprefix, dev)
    commandlist.append(cmd)

    cmd = "/usr/sbin/ip route add 0.0.0.0/1 via {} dev {} table {} proto static metric {}".format(default, dev, tableid, tableid)
    commandlist.append(cmd)

    cmd = "/usr/sbin/ip route add {} dev {} table {} proto static scope link src {} metric {}".format(network, dev, tableid, currentip, tableid)
    commandlist.append(cmd)

    cmd = "/usr/sbin/ip route add 128.0.0.0/1 via {} dev {} table {} proto static metric {}".format(default, dev, tableid, tableid)
    commandlist.append(cmd)

    cmd = "/usr/sbin/ip rule add from {} table {} priority 32761".format(currentip, tableid)
    commandlist.append(cmd)

    for cmd in commandlist:
        try:
            if verbose:
                print(cmd)
            if not dryrun:
                rc = subprocess.check_output(cmd.split())
        except:
            print("Error: could not run command {}".format(cmd))
            print("       Continuing.")

    print("Configured ip addr, ip route, and ip rule settings")
    return


def config_ip_rhel(dev, currentip, prefixlen, default, network, tableid, verbose):
    """This is not used but kept here for reference."""
    commandlist = []
    hostprefix = "{}/{}".format(currentip, prefixlen)

    cmd = "/usr/bin/nmcli connection mod {} +ipv4.addresses {}".format(dev, hostprefix)
    commandlist.append(cmd)

    cmd = '/usr/bin/nmcli connection mod {} +ipv4.routes "0.0.0.0/1 {} {} table={}"'.format(dev, default, tableid, tableid)
    commandlist.append(cmd)

    cmd = '/usr/bin/nmcli connection mod {} +ipv4.routes "128.0.0.0/1 {} {} table={}"'.format(dev, default, tableid, tableid)
    commandlist.append(cmd)

    cmd = '/usr/bin/nmcli connection mod {} +ipv4.routes "{} {} table={} src={} onlink=true"'.format(dev, network, tableid, tableid, currentip)
    commandlist.append(cmd)

    cmd = '/usr/bin/nmcli connection mod {} +ipv4.routing-rules "priority 32761 from {} table {}"'.format(dev, currentip, tableid)
    commandlist.append(cmd)

    cmd = "/usr/bin/nmcli connection up {}".format(dev)
    commandlist.append(cmd)

    for cmd in commandlist:
        try:
            if verbose:
                print(cmd)
            rc = subprocess.check_output(cmd.split())
        except:
            print("Error: could not run command {}".format(cmd))
            print("       Continuing.")
    return


def flush_ip(dev, verbose):
    flushcmd = "/usr/sbin/ip addr flush dev {}".format(dev)
    if verbose:
        print(flushcmd)

    try:
        fc = subprocess.check_output(flushcmd.split())
    except:
        print("Error: could not run command {}".format(flushcmd))
        print("       Continuing.")
    return

def get_mlnx_ifname(device):
   # get the ifname from the device
   netpath = "/sys/class/infiniband/{}/device/net/*".format(device)
   try:
        ifname = os.path.basename(glob.glob(netpath)[0])
   except:
        ifname = None
   return ifname

def is_device_ethernet(device):
   # Return True if the link_layer of the device is ethernet
   linkpath = "/sys/class/infiniband/{}/ports/*/link_layer".format(device)
   try:
       with open(glob.glob(linkpath)[0], 'r') as reader:
           linktype = reader.read()
           if "ethernet" in linktype.lower():
               return True
           else:
               return False
   except:
       return False
   return False

def get_mlnx_ethernet_ifnames():
   # We return a list of all device ifnames
   ifnames = []
   for device in [os.path.basename(x) for x in glob.glob("/sys/class/infiniband/*")]:
       if is_device_ethernet(device) and get_mlnx_ifname(device):
           ifnames.append(get_mlnx_ifname(device))
   return ifnames

if __name__ == "__main__":
    main()

