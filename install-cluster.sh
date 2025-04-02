#!/bin/bash

# 파일 경로 설정
SERVER_LIST="./servers.txt"
INVENTORY_FILE="./inventory/xquare/inventory.ini"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# 필수 패키지 설치 확인 및 설치 함수
install_package() {
    PACKAGE_NAME=$1
    INSTALL_COMMAND=$2
    if ! command -v $PACKAGE_NAME &>/dev/null; then
        echo "[INFO] $PACKAGE_NAME를 설치합니다."
        eval $INSTALL_COMMAND
    else
        echo "[INFO] $PACKAGE_NAME가 이미 설치되어 있습니다."
    fi
}

# sshpass 설치
install_package "sshpass" "sudo apt-get update && sudo apt-get install -y sshpass"

# Python3 및 pip 설치
install_package "python3" "sudo apt-get install -y python3"
install_package "pip3" "sudo apt-get install -y python3-pip"

# Ansible 설치 (옵션 추가)
install_package "ansible" "pip3 install --break-system-packages ansible"

# Jinja2 설치 (옵션 추가)
install_package "jinja2" "pip3 install --break-system-packages Jinja2"

# netaddr 설치 (옵션 추가)
install_package "netaddr" "pip3 install --break-system-packages netaddr"

# Kubespray requirements 설치
if [ -f "requirements.txt" ]; then
    echo "[INFO] Kubespray requirements를 설치합니다."
    pip3 install --break-system-packages -r requirements.txt
else
    echo "[WARN] requirements.txt 파일을 찾을 수 없습니다. Kubespray requirements 설치를 건너뜁니다."
fi

# servers.txt 파일 존재 확인
if [ ! -f "$SERVER_LIST" ]; then
    echo "[ERROR] servers.txt 파일이 존재하지 않습니다."
    exit 1
fi

# 서버 목록에서 /etc/hosts에 추가할 엔트리 생성
HOSTS_ENTRY=$(awk '{print $2" "$3}' "$SERVER_LIST")

# 서버 설정 명령어 정의
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

# 호스트 엔트리 삽입
SETUP_COMMANDS=${SETUP_COMMANDS/__HOSTS_ENTRY__/$HOSTS_ENTRY}

# 인벤토리 디렉토리 생성
mkdir -p "$(dirname "$INVENTORY_FILE")"

# 인벤토리 파일 초기화
echo -e "[kube_control_plane]" > "$INVENTORY_FILE"

ETCD_BLOCK=""
WORKER_BLOCK=""
MASTER_INDEX=1

# servers.txt 파일을 읽어 각 서버에 설정 적용
while IFS=' ' read -r ROLE IP HOSTNAME SSH_USER SSH_PASS SSH_PORT SUDO_PASS; do
    echo "[SETTING..] $HOSTNAME ($IP:$SSH_PORT) | User: $SSH_USER | Role: $ROLE"

    # 서버에 설정 명령어 실행
    sshpass -p "$SSH_PASS" ssh $SSH_OPTS -p "$SSH_PORT" "$SSH_USER@$IP" \
        "export HOSTNAME=$HOSTNAME SUDO_PASS=$SUDO_PASS; bash -s" <<< "$SETUP_COMMANDS"

    if [ $? -eq 0 ]; then
        echo "[SUCCESS] $HOSTNAME ($IP) 설정 완료"
    else
        echo "[FAILED] $HOSTNAME ($IP) 설정 실패"
        continue
    fi

    # 역할에 따른 인벤토리 항목 추가
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
        *)
            echo "[WARN] 알 수 없는 역할: $ROLE"
            ;;
    esac

done < "$SERVER_LIST"

# etcd 및 kube_node 섹션 추가
echo -e "\n[etcd]" >> "$INVENTORY_FILE"
echo -n "$ETCD_BLOCK" >> "$INVENTORY_FILE"

echo -e "\n[kube_node]" >> "$INVENTORY_FILE"
echo -n "$WORKER_BLOCK" >> "$INVENTORY_FILE"

echo "[INFO] inventory.ini 생성 완료: $INVENTORY_FILE"

# 노드 PING 테스트
echo "[INFO] 노드 PING 테스트"
ansible all -m ping -i $INVENTORY_FILE

# Kubespray를 통한 Kubernetes 클러스터 설치
if [ -f "cluster.yml" ]; then
    echo "[INFO] Kubernetes 클러스터 설치 시작"
    ansible-playbook -i $INVENTORY_FILE cluster.yml
else
    echo "[ERROR] cluster.yml 파일을 찾을 수 없습니다. Kubernetes 클러스터 설치를 중단합니다."
    exit 1
fi
