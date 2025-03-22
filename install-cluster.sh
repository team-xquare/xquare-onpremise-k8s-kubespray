#!/bin/bash

SERVER_LIST="./servers.txt"
INVENTORY_FILE="./inventory/xquare/inventory.ini"
GROUP_VARS_FILE="./inventory/xquare/group_vars/k8s_cluster/k8s-cluster.yml"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

if [ ! -f "$SERVER_LIST" ]; then
    echo "[ERROR] servers.txt 파일이 존재하지 않습니다."
    exit 1
fi

if ! command -v sshpass &>/dev/null; then
    echo "[INFO] sshpass 설치 중"
    brew install hudochenkov/sshpass/sshpass
fi

HOSTS_ENTRY=$(awk '{print $2" "$3}' "$SERVER_LIST")

read -r -d '' SETUP_COMMANDS <<'EOF'
echo "$SUDO_PASS" | sudo -S hostnamectl set-hostname "$HOSTNAME"

echo "$SUDO_PASS" | sudo -S bash -c "cat >> /etc/hosts <<EOL
__HOSTS_ENTRY__
EOL"

echo "$SUDO_PASS" | sudo -S ufw disable
echo "$SUDO_PASS" | sudo -S swapoff -a
echo "$SUDO_PASS" | sudo -S sed -i '/swap/d' /etc/fstab

echo "$SUDO_PASS" | sudo -S modprobe br_netfilter
echo 'br_netfilter' | echo "$SUDO_PASS" | sudo -S tee /etc/modules-load.d/br_netfilter.conf

echo "$SUDO_PASS" | sudo -S bash -c "cat > /etc/sysctl.d/k8s.conf <<EOL
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOL"

echo "$SUDO_PASS" | sudo -S sysctl --system
EOF

SETUP_COMMANDS=${SETUP_COMMANDS/__HOSTS_ENTRY__/$HOSTS_ENTRY}

mkdir -p "$(dirname "$INVENTORY_FILE")"
mkdir -p "$(dirname "$GROUP_VARS_FILE")"

echo -e "[kube_control_plane]" > "$INVENTORY_FILE"

ETCD_BLOCK=""
WORKER_BLOCK=""
LB_BLOCK=""
MASTER_INDEX=1

while read -r ROLE IP HOSTNAME SSH_USER SSH_PASS SSH_PORT SUDO_PASS; do
    echo "[SETTING..] $HOSTNAME ($IP:$SSH_PORT) | User: $SSH_USER | Role: $ROLE"

    sshpass -p "$SSH_PASS" ssh $SSH_OPTS -p "$SSH_PORT" "$SSH_USER@$IP" \
        "export HOSTNAME=$HOSTNAME SUDO_PASS=$SUDO_PASS; bash -s" <<< "$SETUP_COMMANDS"

    if [ $? -eq 0 ]; then
        echo "[SUCCESS] $HOSTNAME ($IP)"
    else
        echo "[FAILED] $HOSTNAME ($IP)"
    fi

    case "$ROLE" in
        master)
            LINE="$HOSTNAME ansible_host=$IP ip=$IP etcd_member_name=etcd$MASTER_INDEX ansible_user=$SSH_USER ansible_ssh_pass=$SSH_PASS ansible_become=yes ansible_become_pass=$SUDO_PASS"
            echo "$LINE" >> "$INVENTORY_FILE"
            ETCD_BLOCK+="$LINE"$'\n'
            ((MASTER_INDEX++))
            ;;
        worker)
            LINE="$HOSTNAME ansible_host=$IP ip=$IP ansible_user=$SSH_USER ansible_ssh_pass=$SSH_PASS ansible_become=yes ansible_become_pass=$SUDO_PASS"
            WORKER_BLOCK+="$LINE"$'\n'
            ;;
        lb)
            LINE="$HOSTNAME ansible_host=$IP ip=$IP ansible_user=$SSH_USER ansible_ssh_pass=$SSH_PASS ansible_become=yes ansible_become_pass=$SUDO_PASS"
            LB_BLOCK+="$LINE"$'\n'
            ;;
        *)
            echo "[WARN] 알 수 없는 역할: $ROLE"
            ;;
    esac

done < "$SERVER_LIST"

echo -e "\n[etcd]" >> "$INVENTORY_FILE"
echo -n "$ETCD_BLOCK" >> "$INVENTORY_FILE"

echo -e "\n[kube_node]" >> "$INVENTORY_FILE"
echo -n "$WORKER_BLOCK" >> "$INVENTORY_FILE"

if [ -n "$LB_BLOCK" ]; then
    echo -e "\n[kube_lb]" >> "$INVENTORY_FILE"
    echo -n "$LB_BLOCK" >> "$INVENTORY_FILE"
fi

echo -e "\n[k8s_cluster:children]\nkube_control_plane\nkube_node" >> "$INVENTORY_FILE"

echo "[INFO] inventory.ini 생성 완료: $INVENTORY_FILE"

LB_IP=$(awk '$1 == "lb" {print $2; exit}' "$SERVER_LIST")

if [ -n "$LB_IP" ]; then
  cat > "$GROUP_VARS_FILE" <<EOF
loadbalancer_apiserver:
  address: $LB_IP
  port: 6443
EOF

  echo "[INFO] k8s-cluster.yml 설정 완료: $GROUP_VARS_FILE"
else
  echo "[WARN] lb 노드가 없어 loadbalancer 설정 생략"
fi
