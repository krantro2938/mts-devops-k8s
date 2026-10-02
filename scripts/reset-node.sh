#!/usr/bin/env bash
# DESTRUCTIVE: tear the kubeadm cluster down on this node (kubeadm reset + CNI/iptables cleanup).
# Packages (containerd, kubeadm, ...) stay installed, so bootstrap-node.sh can recreate the cluster.
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"
[[ $EUID -eq 0 ]] || die "run as root: sudo $0"

if [[ "${1:-}" != "--yes" ]]; then
  read -r -p "This deletes the Kubernetes cluster on $(hostname) including all data. Type 'yes' to continue: " answer
  [[ "$answer" == yes ]] || die "aborted"
fi

log "kubeadm reset"
kubeadm reset --force --cri-socket unix:///run/containerd/containerd.sock || true
rm -rf /etc/cni/net.d /var/lib/calico /var/run/calico /opt/local-path-provisioner
rm -f /var/log/fluentd-containers.log.pos
rm -rf /var/log/fluentd-buffers
iptables-save | grep -v -E 'KUBE|cali' | iptables-restore || true
ip link delete vxlan.calico 2>/dev/null || true
user="${SUDO_USER:-root}"
rm -f "$(getent passwd "$user" | cut -d: -f6)/.kube/config"
ok "node reset"
