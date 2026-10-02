#!/usr/bin/env bash
# Prepare an Ubuntu 24.04 host and create a Kubernetes cluster with kubeadm.
#
#   sudo ./scripts/bootstrap-node.sh                        # control-plane (single-node cluster)
#   sudo ./scripts/bootstrap-node.sh worker '<kubeadm join ...>'   # optional extra worker
#
# Idempotent: every step checks the current state first, so the script can be
# re-run safely (an existing cluster is left untouched).
#
# Env overrides: NODE_IP (advertise address), NODE_NAME, SKIP_OS_CHECK=1.

# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

ROLE="${1:-control-plane}"
JOIN_CMD="${2:-}"

[[ $EUID -eq 0 ]] || die "run as root: sudo $0 $*"
[[ "$ROLE" == control-plane || "$ROLE" == worker ]] || die "role must be 'control-plane' or 'worker'"
[[ "$ROLE" == control-plane || -n "$JOIN_CMD" ]] || die "worker role needs the join command as 2nd argument"

ARCH="$(arch)"
NODE_IP="$(node_ip)"
NODE_NAME="${NODE_NAME:-$(hostname -s | tr '[:upper:]' '[:lower:]')}"
export NODE_IP NODE_NAME K8S_VERSION POD_CIDR SERVICE_CIDR
[[ -n "$NODE_IP" ]] || die "cannot detect node IP, set NODE_IP=<ip>"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

preflight() {
  log "Preflight checks"
  # shellcheck source=/dev/null
  source /etc/os-release
  if [[ "${ID}-${VERSION_ID}" != "ubuntu-24.04" ]]; then
    [[ "${SKIP_OS_CHECK:-0}" == 1 ]] || die "tested on Ubuntu 24.04 only (found ${PRETTY_NAME}); set SKIP_OS_CHECK=1 to continue anyway"
    warn "running on ${PRETTY_NAME} (not tested)"
  fi
  local cpus mem_mb
  cpus=$(nproc)
  mem_mb=$(awk '/MemTotal/ {print int($2 / 1024)}' /proc/meminfo)
  ((cpus >= 2)) || die "kubeadm needs at least 2 CPUs (found ${cpus})"
  ((mem_mb >= 3500)) || warn "${mem_mb} MiB RAM found, 4 GiB+ recommended for the full stack"
  ok "${PRETTY_NAME}, ${cpus} CPU, ${mem_mb} MiB RAM, node ${NODE_NAME} (${NODE_IP}), ${ARCH}"
}

install_packages() {
  log "Installing base OS packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq apt-transport-https ca-certificates curl gpg gettext-base \
    conntrack socat ebtables ethtool iptables jq openssl >/dev/null
}

configure_kernel() {
  log "Disabling swap, loading kernel modules, setting sysctls"
  swapoff -a
  # Comment out swap entries so the change survives a reboot.
  sed -ri '/^[^#].*\sswap\s/s/^/#/' /etc/fstab
  # Ubuntu cloud images may use a swap unit instead of fstab.
  systemctl list-units --type swap --plain --no-legend 2>/dev/null | awk '{print $1}' | xargs -r systemctl mask >/dev/null 2>&1 || true

  cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
  modprobe overlay
  modprobe br_netfilter

  cat >/etc/sysctl.d/99-kubernetes.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
# Fluentd and many controllers use inotify heavily.
fs.inotify.max_user_instances       = 1024
fs.inotify.max_user_watches         = 524288
EOF
  sysctl --system >/dev/null
}

# download <url> <dest> <sha256-url-or-empty>
download_verified() {
  local url=$1 dest=$2 sum_url=$3
  curl -fsSL --retry 5 -o "$dest" "$url"
  if [[ -n "$sum_url" ]]; then
    local expected
    expected=$(curl -fsSL --retry 5 "$sum_url" | grep -E "$(basename "$url")\$" | awk '{print $1}')
    [[ -n "$expected" ]] || die "no checksum for $(basename "$url")"
    echo "${expected}  ${dest}" | sha256sum -c --quiet - || die "checksum mismatch for $url"
  fi
}

install_containerd() {
  if [[ -x /usr/local/bin/containerd ]] && /usr/local/bin/containerd --version | grep -q "v${CONTAINERD_VERSION} "; then
    ok "containerd v${CONTAINERD_VERSION} already installed"
  else
    log "Installing containerd v${CONTAINERD_VERSION} and runc v${RUNC_VERSION} (upstream static binaries, checksum verified)"
    local base="https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}"
    local tarball="containerd-${CONTAINERD_VERSION}-linux-${ARCH}.tar.gz"
    download_verified "${base}/${tarball}" "${TMP}/${tarball}" "${base}/${tarball}.sha256sum"
    # Stop a running daemon first, otherwise the binary is "text file busy".
    systemctl stop containerd 2>/dev/null || true
    tar -C /usr/local -xzf "${TMP}/${tarball}"
    curl -fsSL --retry 5 -o /etc/systemd/system/containerd.service \
      "https://raw.githubusercontent.com/containerd/containerd/v${CONTAINERD_VERSION}/containerd.service"

    local rbase="https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}"
    download_verified "${rbase}/runc.${ARCH}" "${TMP}/runc.${ARCH}" "${rbase}/runc.sha256sum"
    install -m 0755 "${TMP}/runc.${ARCH}" /usr/local/sbin/runc
  fi

  log "Configuring containerd (systemd cgroup driver, pause image)"
  mkdir -p /etc/containerd
  local pause_image
  pause_image="registry.k8s.io/pause:3.10.1"
  if command -v kubeadm >/dev/null; then
    pause_image=$(kubeadm config images list --kubernetes-version "v${K8S_VERSION}" 2>/dev/null | grep pause || echo "$pause_image")
  fi
  /usr/local/bin/containerd config default >"${TMP}/config.toml"
  sed -i -e 's/SystemdCgroup = false/SystemdCgroup = true/' \
    -e "s#sandbox = '.*'#sandbox = '${pause_image}'#" \
    -e "s#sandbox_image = \".*\"#sandbox_image = \"${pause_image}\"#" "${TMP}/config.toml"
  grep -q 'SystemdCgroup = true' "${TMP}/config.toml" || die "failed to enable SystemdCgroup in containerd config"
  if ! cmp -s "${TMP}/config.toml" /etc/containerd/config.toml; then
    install -m 0644 "${TMP}/config.toml" /etc/containerd/config.toml
    systemctl daemon-reload
    systemctl restart containerd
  fi
  systemctl daemon-reload
  systemctl enable --now containerd >/dev/null 2>&1
  retry 10 2 test -S /run/containerd/containerd.sock || die "containerd socket did not appear"

  cat >/etc/crictl.yaml <<'EOF'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
EOF
  ok "containerd $(/usr/local/bin/containerd --version | awk '{print $3}') is running"
}

install_kube_packages() {
  local want="${K8S_VERSION}-${K8S_PKG_REVISION}"
  if dpkg-query -W -f='${Version}' kubeadm 2>/dev/null | grep -qx "$want"; then
    ok "kubeadm/kubelet/kubectl ${want} already installed"
    return
  fi
  log "Installing kubeadm, kubelet, kubectl ${want} from pkgs.k8s.io"
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL --retry 5 "https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/Release.key" |
    gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_MINOR}/deb/ /" \
    >/etc/apt/sources.list.d/kubernetes.list
  apt-get update -qq
  apt-mark unhold kubeadm kubelet kubectl >/dev/null 2>&1 || true
  apt-get install -y -qq --allow-downgrades "kubeadm=${want}" "kubelet=${want}" "kubectl=${want}" >/dev/null
  apt-mark hold kubeadm kubelet kubectl >/dev/null
  systemctl enable kubelet >/dev/null 2>&1
}

install_helm() {
  if command -v helm >/dev/null && helm version --template '{{.Version}}' 2>/dev/null | grep -qx "v${HELM_VERSION}"; then
    ok "helm v${HELM_VERSION} already installed"
    return
  fi
  log "Installing helm v${HELM_VERSION}"
  local tarball="helm-v${HELM_VERSION}-linux-${ARCH}.tar.gz"
  curl -fsSL --retry 5 -o "${TMP}/${tarball}" "https://get.helm.sh/${tarball}"
  echo "$(curl -fsSL --retry 5 "https://get.helm.sh/${tarball}.sha256sum" | awk '{print $1}')  ${TMP}/${tarball}" | sha256sum -c --quiet -
  tar -C "$TMP" -xzf "${TMP}/${tarball}"
  install -m 0755 "${TMP}/linux-${ARCH}/helm" /usr/local/bin/helm
}

kubeadm_init() {
  if [[ -f /etc/kubernetes/admin.conf ]]; then
    ok "cluster already initialised (/etc/kubernetes/admin.conf exists), skipping kubeadm init"
  else
    log "Running kubeadm init (Kubernetes v${K8S_VERSION})"
    envsubst <"${REPO_ROOT}/kubeadm/kubeadm-config.yaml.tpl" >"${TMP}/kubeadm-config.yaml"
    kubeadm config validate --config "${TMP}/kubeadm-config.yaml"
    kubeadm config images pull --config "${TMP}/kubeadm-config.yaml"
    kubeadm init --config "${TMP}/kubeadm-config.yaml" --upload-certs
    install -m 0600 "${TMP}/kubeadm-config.yaml" /etc/kubernetes/kubeadm-config.yaml
  fi

  export KUBECONFIG=/etc/kubernetes/admin.conf
  retry 60 5 kubectl get --raw=/readyz >/dev/null 2>&1 || die "API server did not become ready"

  # Single-node cluster: allow workloads on the control-plane node.
  kubectl taint nodes --all node-role.kubernetes.io/control-plane:NoSchedule- >/dev/null 2>&1 || true

  # kubeconfig for the invoking (non-root) user, so deploy.sh runs without sudo.
  local user="${SUDO_USER:-root}" home
  home=$(getent passwd "$user" | cut -d: -f6)
  install -d -m 0700 -o "$user" -g "$(id -gn "$user")" "${home}/.kube"
  install -m 0600 -o "$user" -g "$(id -gn "$user")" /etc/kubernetes/admin.conf "${home}/.kube/config"
  ok "kubeconfig written to ${home}/.kube/config"
}

kubeadm_join() {
  if [[ -f /etc/kubernetes/kubelet.conf ]]; then
    ok "node already joined, skipping"
    return
  fi
  log "Joining the cluster as a worker"
  # shellcheck disable=SC2086
  eval "$JOIN_CMD"
}

preflight
install_packages
configure_kernel
install_kube_packages
install_containerd
install_helm
if [[ "$ROLE" == control-plane ]]; then
  kubeadm_init
  ok "control-plane is up. Next step (as a regular user): ./scripts/deploy.sh"
  echo "   To add workers: kubeadm token create --print-join-command"
else
  kubeadm_join
fi
