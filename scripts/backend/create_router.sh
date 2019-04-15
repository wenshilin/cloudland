#!/bin/bash

cd `dirname $0`
source ../cloudrc

[ $# -lt 5 ] && echo "$0 <router> <ext_gw_cidr> <int_gw_cidr> <vrrp_vni> <vrrp_ip>" && exit -1

router=$1
ext_ip=$2
int_ip=$3
vrrp_vni=$4
vrrp_ip=$5

[ -z "$router" -o -z "$ext_ip" -o -z "$int_ip" ] && exit 1

ip netns add $router
ip netns exec $router iptables -A INPUT -m mark --mark 0x1/0xffff -j ACCEPT
ip netns exec $router ip link set lo up
suffix=${router%%-*}

ip link add ext$suffix type veth peer name te-$suffix
apply_vnic -A te-$suffix
ip netns exec $router iptables -A FORWARD -o ext$suffix -m mark ! --mark 0x4000000/0xffff0000 -j DROP
ip link set ext$suffix netns $router
ip link set te-$suffix up
brctl addif br$external_vlan te-$suffix
ip netns exec $router ip link set ext$suffix up
if [ -n "$ext_ip" ]; then
    ext_gw=$(ipcalc --minaddr $ext_ip | cut -d= -f2)
    eip=${ext_ip%/*}
    ip netns exec $router iptables -t nat -A POSTROUTING ! -d 10.0.0.0/8 -j SNAT -o ext$suffix --to-source $eip
fi

ip link add int$suffix type veth peer name ti-$suffix
apply_vnic -A ti-$suffix
ip netns exec $router iptables -A FORWARD -o int$suffix -m mark ! --mark 0x4000000/0xffff0000 -j DROP
ip link set int$suffix netns $router
ip link set ti-$suffix up
brctl addif br$internal_vlan ti-$suffix
ip netns exec $router ip link set int$suffix up
if [ -n "$int_ip" ]; then
    int_gw=$(ipcalc --minaddr $int_ip | cut -d= -f2)
    iip=${int_ip%/*}
    ip netns exec $router iptables -t nat -A POSTROUTING -d 10.0.0.0/8 -j SNAT -o int$suffix --to-source $iip
fi

router_dir=/opt/cloudland/cache/router/$router
mkdir -p $router_dir
vrrp_conf=$router_dir/keepalived.conf
notify_sh=$router_dir/notify.sh
cat > $vrrp_conf <<EOF
vrrp_instance vrouter {
    interface ns-${vrrp_vni}
    track_interface {
        ns-${vrrp_vni}
        int$suffix
        ext$suffix
    }
    dont_track_primary
    state EQUAL
    virtual_router_id 100
    priority 100
    nopreempt
    advert_int 1

    virtual_ipaddress {
        $int_ip dev int$suffix
        $ext_ip dev ext$suffix
    }
    notify $notify_sh
}
EOF
cat > $notify_sh <<EOF
#!/bin/bash

TYPE=\$1
NAME=\$2
STATE=\$3

case \$STATE in
   "MASTER") 
        ip netns exec $router route add default gw $ext_gw
        ip netns exec $router arping -c 1 -S $eip $ext_gw
        ip netns exec $router route add -net 10.0.0.0/8 gw $int_gw
        ip netns exec $router arping -c 1 -S $iip $int_gw
        exit 0
        ;;
   "BACKUP") 
        exit 0
        ;;
   "FAULT") 
        exit 0
        ;;
    *)  echo "unknown state"
        exit 1
    ;;
esac
EOF
chmod +x $notify_sh
./set_gateway.sh $router $vrrp_ip $vrrp_vni hard
pid_file=$router_dir/keepalived.pid
ip netns exec $router keepalived -f $vrrp_conf -p $pid_file -r $router_dir/vrrp.pid -c $router_dir/checkers.pid
[ "$RECOVER" = "true" ] || sql_exec "insert into router values ('$router', '$int_ip', 'int$suffix', '$ext_ip', 'ext$suffix', '$vrrp_vni', '$vrrp_ip')"

while read line; do
    [ -z "$line" ] && continue 
    addr=$(echo $line | cut -d' ' -f1)
    vni=$(echo $line | cut -d' ' -f2)
    ./set_gateway.sh $router $addr $vni
done

ip netns exec $router bash -c "echo 1 >/proc/sys/net/ipv4/ip_forward"
echo "|:-COMMAND-:| `basename $0` '$router' '$SCI_CLIENT_ID' '$(hostname -s)'"
