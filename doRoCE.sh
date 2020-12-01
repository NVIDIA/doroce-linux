#!/bin/bash
# Copyright (c) 2020, NVIDIA CORPORATION. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
VERSION=0.98
# TODOs
#- multi-port

uninst=0
run_once=0
lossless=0
lossy=0
debug=0
verbose=0
device_list=()
y_n=""
tos_val=106
gix_val=3
mtu_val=""
set_default=0
trust="dscp"
trust_val="2"
inparams=$@

function yn_question ()
{
    text=$1
    while true; do
        if [ -z $y_n ] ; then read -p "$text (Yy/Nn) " yn
        else yn=$y_n
        fi
        case $yn in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
                * ) echo "Yy/Nn";;
        esac
    done
}

function yn_question_cont_wo ()
{
    text="Continue without $1? (not recommended)"
    yn_question "$text"
    if [ 0 -ne $? ] ; then 
        echo "Exiting"
        exit 0
    fi
}

function run_cmd ()
{
    cmd_name=$1
    cmd_line=$2
    care=`sudo bash -c "$cmd_line" 2>&1`
    err=$?
    if [ 0 -ne $err ] ; then 
        echo "[E] Failed to run $cmd_name (err $err)"
        echo "[E] Failed command output:"
        echo "$cmd_line" ; echo "$care"
        return $err
    fi
    if [ 1 -eq $verbose ] ; then 
        echo "-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-"
        echo "[V] Running $cmd_name:"
        echo "$cmd_line"
        echo "$care"
    fi
}

function mount_cm_configfs()
{
    if (! sudo cat /proc/mounts | \grep /sys/kernel/config > /dev/null) ; then
        if (! sudo mount -t configfs none /sys/kernel/config) ; then
            echo "[E] Fail to mount configfs"
            return 1
        fi  
    fi

    if (sudo modinfo configfs &> /dev/null) ; then
        if (! cat /proc/modules | \grep configfs > /dev/null) ; then
            if (! sudo modprobe configfs) ; then
                echo "[E] Fail to modprobe configfs"
                return 1
            fi
        fi  
    fi
    if [ ! -d /sys/kernel/config/rdma_cm ] ; then return 1 ; fi
}

function set_cm_tos()
{
    dev=$1
    dev_path="/sys/kernel/config/rdma_cm/${dev}"
    rem_after_set=0
    if [ ! -d $dev_path ] ; then
        rem_after_set=1
        run_cmd "create configfs dir for $dev" "mkdir $dev_path"
    fi
    for port in ${dev_path}/ports/* ; do        
        run_cmd "set TOS for $dev, port `basename $port`" "bash -c \"echo $tos_val > ${port}/default_roce_tos\""
    done
    if [ 1 -eq $rem_after_set ] ; then
        run_cmd "remove configfs dir for $dev" "rmdir $dev_path"
    fi
}

\echo ""
\echo "  DoRoCE Version $VERSION"
\echo "---------------------------"
\echo "  NOTE - this script aggregates steps described in the Mellanox-NVIDIA community"
\echo "  pages and provided as a reference for recipe implementation"
\echo "  "
\echo "  It is recommended for use during bring-up and that you implement only"
\echo "  required components for deployment in production environments"
\echo ""

for arg in "$@"
do
    case "$arg" in
        -h|--help|--h)
            \echo ""
            \echo "  DoRoCE script configures Mellanox-NVIDIA NICs for RoCE deployments"
            \echo ""
            \echo "  Usage: ./doRoCE.sh (options)"
            \echo ""
            \echo "  Options:"
            \echo "      --run_once              - don't install to driver boot process, only run configuration"
            \echo "      --uninstall             - remove from boot process, don't run configuration"
            \echo "      -d <dev_a,dev_b...>     - comma separated RDMA device list (for example: mlx5_0)"
            \echo "                                if '-d' not provided, tool will configure all found devices"
            \echo "      -t <val>                - set TOS value (default: $tos_val) DSCP=TOS>>2, PRIO=DSCP>>3"
            \echo "      -m <val>                - set MTU value (default: don't change)"
            \echo "      -g <val>                - set NCCL conf GID-index value (default: $gix_val)"
            \echo "      -l / --lossless_opt     - assume lossless configuration for performance optimizations (default: $lossless)"
            \echo "                                use this option if you configured a Mellanox-NVIDIA switch with \"roce\" command"
            \echo "      -s / --lossy_buf        - disable PFC, use single larger buffer for all traffic types (default: $lossy)"
            \echo "      -u / --debug            - add debug prints"
            \echo "      -v / --verbose          - print commands and outputs"
            \echo "      -y / --yes              - ignore errors and proceed with what's available (default - ask)"
            \echo "      -n / --no               - exit on any missing component"
            \echo "      -b / --back_to_def      - restore OOB config (note - will not restore MTU, please set it manually)"
            \echo ""
            \echo "  List of configurations performed:"
            \echo "  - Installs the script (with selected parameters) to driver boot process"
            \echo "  - Set trust mode to DSCP"
            \echo "  - Enable/disable PFC on priority (TOS>>5) - aligns with default DSCP-to-Priority mapping"
            \echo "  - Enable/disable lossless performance optimizations"
            \echo "  - Set /etc/nccl.conf to TOS=106"
            \echo "    note: conf files are set once, not on every boot"
            \echo "    note: UCX uses UCX_IB_TRAFFIC_CLASS=106 by default. Change through command line, as conf file isn't supported yet"
            \echo "  - Set IB VERB override to TOS=106"
            \echo "  - Set RDMA-CM default TOS"
            \echo ""
            exit 5;
            ;;
            
        "--uninstall")          uninst=1;;
        "--run_once")           run_once=1;;
        "-l"|"--lossless_opt")  lossless=1;;
        "-s"|"--lossy_buf")     lossy=1;;
        "-u"|"--debug")         debug=1;;
        "-v"|"--verbose")       verbose=1;;
        "-y"|"--yes")           y_n="y";;
        "-n"|"--no")            y_n="n";;
        "-b"|"--back_to_def")   set_default=1;;
        -d)                     p_arg=${arg##"-"} ;;
        -t)                     p_arg=${arg##"-"} ;;
        -m)                     p_arg=${arg##"-"} ;;
        -g)                     p_arg=${arg##"-"} ;;
        *) case $p_arg in
           d)             device_list=(${arg//,/ })     ; p_arg=""  ;;
           t)             tos_val="$arg"                ; p_arg=""  ;;
           m)             mtu_val="$arg"                ; p_arg=""  ;;
           g)             gix_val="$arg"                ; p_arg=""  ;;
           *) echo "[E] Unknown paramater, see help (-h/--help)" ; exit 5 ;;
           esac
    esac
done

if [ -d "/etc/infiniband" ] && [ -f /etc/init.d/openibd ] ; then 
    psh_caller="openibd"
    psh_path="/etc/infiniband/post-start-hook.sh"
else
    psh_caller="rc.local"
    psh_path="/etc/rc.d/rc.local"
fi

nccl_conf_path="/etc/nccl.conf"
if [ 1 -eq $uninst ] || [ 1 -eq $set_default ] ; then
    echo "[I] Removing NCCL conf hook"
    if [ -f $nccl_conf_path ] ; then
        run_cmd "Clear NCCL conf DSCP" "\sed -i -- '/doRoCE\|NCCL_IB_TC\|NCCL_IB_GID_INDEX/I d' $nccl_conf_path"
    fi
    if [ 1 -eq $uninst ] ; then
        echo "[I] Removing script from boot process"
        if [ -f $psh_path ] ; then
            run_cmd "Clear post-start hook" "sed -i -- '/doRoCE/ d' $psh_path"
        fi
        echo "[I] Removing script from /usr/bin"
        run_cmd "Remove script from /usr/bin" "rm -f /usr/bin/doRoCE.sh"
        exit 0
    fi
fi

if [ ! -d /sys/bus/pci/drivers/mlx5_core/ ] ; then
    echo "[E] mlx5 driver is down, exiting"
    exit 6
fi

if [ 1 -eq $lossless ] && [ 1 -eq $lossy ] ; then echo "[E] Lossy and lossless can't be configured at the same time, exiting" ; exit 7 ; fi

if [ 1 -eq $set_default ] ; then
    lossless=0
    lossy=1
    tos_val=0
    trust="pcp"
    trust_val=1
fi

pfc_cmd_mask=$((1       << ($tos_val>>5)))
pfc_set_mask=$((!$lossy << ($tos_val>>5)))

if [ 1 -eq $debug ] ; then echo -n "[D] PFC-MASK=" ; printf "0x%.2x\n" $pfc_set_mask ; fi

if [ 1 -eq $debug ] ; then echo "[D] checking for mlxreg/mstreg" ; fi
mlxreg_cmd=""
if   (which mlxreg >/dev/null 2>&1) || [ -f "/usr/bin/mlxreg" ] ; then mlxreg_cmd="mlxreg"
elif (which mstreg >/dev/null 2>&1) || [ -f "/usr/bin/mstreg" ] ; then mlxreg_cmd="mstreg"
else
    echo "[E] Could not find mlxreg/mstreg tool in \$PATH"
    echo "to install: install MLNX_OFED, or:"
    echo "    "
    echo "# git clone https://github.com/Mellanox/mstflint.git"
    echo "# cd mstflint"
    echo "# ./autogen.sh"
    echo "# ./configure --disable-inband --enable-adb-generic-tools"
    echo "# make"
    echo "# sudo make install"
    
    yn_question_cont_wo "PFC, trust layer and lossy fabric accelarations"
fi

if [ 1 -eq $debug ] ; then echo "[D] checking for RDMA-CM configfs" ; fi
cm_configfs_found=1
if (! mount_cm_configfs) ; then
    cm_configfs_found=0
    yn_question_cont_wo "setting RDMA-CM default TOS"
fi

mlnx_qos_found=0
if [ 1 -eq $debug ] ; then echo "[D] checking for mlnx_qos/lldptool" ; fi
if (which mlnx_qos >/dev/null 2>&1) || [ -f "/usr/bin/mlnx_qos" ] ; then 
    mlnx_qos_found=1
fi

# Install to /usr/bin
PARENT_COMMAND=$(ps -o comm= $PPID)
if [ "$PARENT_COMMAND" = "$psh_caller" ] ; then let run_once=1 ; fi
if [ 0 -eq $run_once ] ; then
    mypath=`realpath $0`
    if [ 0 -ne $? ] ; then
        echo "[E] Could not determine current path, exiting"
        exit 5
    fi
    if [ "$mypath" != "/usr/bin/doRoCE.sh" ] ; then
        if [ 1 -eq $debug ] ; then echo "[D] Installing to /usr/bin" ; fi
        run_cmd "Copy to /usr/bin" "sudo cp -f $mypath /usr/bin/doRoCE.sh && chmod a+x /usr/bin/doRoCE.sh"
    fi

    if [ 1 -eq $debug ] ; then echo "[D] Adding to OFED post-start-hook" ; fi
    if [ -f $psh_path ] ; then
        run_cmd "Clear post-start-hook" "sed -i -- '/doRoCE/I d' $psh_path"
    fi
    run_cmd "Add post-start-hook" "echo -e \"# Added by doRoCE scirpt:\n/usr/bin/doRoCE.sh $inparams --yes >/dev/null\" >> $psh_path"
    if [ ! -x $psh_path ] ; then run_cmd "Set post-start-hook +x" "chmod a+x $psh_path" ; fi

fi

if [ "$PARENT_COMMAND" != "$psh_caller" ] && [ 1 -ne $set_default ] ; then
    # Set nccl.conf
    if [ 1 -eq $debug ] ; then echo "[D] setting NCCL conf" ; fi
    if [ -f $nccl_conf_path ] ; then 
        run_cmd "Clear NCCL conf DSCP" "\sed -i -- '/doRoCE\|NCCL_IB_TC\|NCCL_IB_GID_INDEX/I d' $nccl_conf_path"
    fi
    run_cmd "Add NCCL conf DSCP" "echo -e \"# Added by doRoCE scirpt:\nNCCL_IB_TC=$tos_val\nNCCL_IB_GID_INDEX=$gix_val\" >> $nccl_conf_path"

    #set ucx.conf - not supported by UCX yet!
    if [ 106 -ne $tos_val ] ; then
        echo "[I] NOTE - for UCX, make sure to add to the command line: \"UCX_IB_TRAFFIC_CLASS=$tos_val\""
    fi
fi

if [ -z "$device_list" ] ; then
    for dev in `\ls /sys/class/infiniband/` ; do
        device_list+=("$dev")
    done
fi
if [ 1 -eq $debug ] ; then echo "[I] Device list: ${device_list[@]}" ; fi

for dev in ${device_list[@]} ; do
    if [ 1 -eq $debug ] ; then echo "[D] Starting device $dev" ; fi
    
    # Get device info
    dev_linktype=`\cat /sys/class/infiniband/${dev}/ports/1/link_layer`
    if [[ "Ethernet" != "$dev_linktype" ]] ; then 
        echo "[I] Device $dev - link type $dev_linktype, skipping"
        continue
    fi
    bdf=`\readlink /sys/class/infiniband/${dev}/device | \xargs basename`
    netdev=`\ls /sys/class/infiniband/${dev}/device/net/ | \xargs basename`

    if [ 1 -eq $debug ] ; then echo "[D] Device $dev - bdf: $bdf, netdev: $netdev" ; fi


    if [ ! -z $mlxreg_cmd ] ; then
        # Configure PFC, trust mode
        if [ 1 -eq $mlnx_qos_found ] ; then
            mlnx_qos_pfc_mask=""
            for i in {0..7} ; do
                mlnx_qos_pfc_mask+="$(( ($pfc_set_mask>>$i) & 0x1 ))"
                if [ 7 -ne $i ] ; then mlnx_qos_pfc_mask+="," ; fi
            done
            run_cmd mlnx_qos "mlnx_qos -i $netdev --trust=$trust --pfc=$mlnx_qos_pfc_mask"
        else
            run_cmd "Set trust DSCP" "$mlxreg_cmd -y -d $bdf --reg_name QPTS -i \"local_port=1\" --set \"trust_state=$trust_val\""
            run_cmd "Set PFC" "$mlxreg_cmd -y -d $bdf --reg_name PFCC -i \"local_port=1,pnat=0,dcbx_operation_type=0\" --set \"prio_mask_rx=${pfc_cmd_mask},prio_mask_tx=${pfc_cmd_mask},pfctx=${pfc_set_mask},pfcrx=${pfc_set_mask},pprx=0,pptx=0\""
        fi
        
        # Configure lossy accelarations
        accl_val=$((1-($lossless || $set_default)))
        run_cmd "Set lossy optimizations" "$mlxreg_cmd -y -d $bdf --reg_name ROCE_ACCL --set \"roce_adp_retrans_en=$accl_val,roce_tx_window_en=$accl_val,roce_slow_restart_en=$accl_val\""
    fi
    # Set MTU
    if [ ! -z $mtu_val ] ; then
        run_cmd "Set MTU" "ifconfig $netdev mtu $mtu_val"
    fi
    
    # Set verb default DSCP
    tc_filename="/sys/class/infiniband/${dev}/tc/1/traffic_class"
    if [ -f $tc_filename ] ; then
        run_cmd "Set verbs default DSCP" "echo $tos_val > ${tc_filename}"
    else
        echo "[E] Could not find $tc_filename, used to force verbs interface TCLASS"
        echo "[E] Make sure to configure TCLASS in your applications"
    fi
    
    # Set RDMA-CM
    set_cm_tos $dev

    # if back_to_def - set global pause
    if [ 1 -eq $set_default ] ; then
        care=`run_cmd "Back to default - set global pause" "ethtool -A $netdev rx on tx on"`
        if [ 1 -eq $? ] ; then echo $care ; fi
    fi
    echo "[I] Device $dev - done"
done

