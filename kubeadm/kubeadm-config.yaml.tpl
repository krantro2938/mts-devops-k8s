# kubeadm configuration template. Rendered by scripts/bootstrap-node.sh
# (envsubst: ${NODE_IP} ${NODE_NAME} ${K8S_VERSION} ${POD_CIDR} ${SERVICE_CIDR}).
#
# Besides a plain single control-plane setup it exposes the metrics endpoints
# of the control-plane components so that Prometheus can scrape them
# (by default kubeadm binds them to 127.0.0.1 and the targets show as DOWN).
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${NODE_IP}
  bindPort: 6443
nodeRegistration:
  name: ${NODE_NAME}
  criSocket: unix:///run/containerd/containerd.sock
  # Single-node cluster: workloads run on the control-plane node.
  taints: []
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v${K8S_VERSION}
clusterName: mts-demo
controlPlaneEndpoint: ${NODE_IP}:6443
networking:
  podSubnet: ${POD_CIDR}
  serviceSubnet: ${SERVICE_CIDR}
  dnsDomain: cluster.local
apiServer:
  certSANs:
    - ${NODE_IP}
    - ${NODE_NAME}
    - 127.0.0.1
    - localhost
controllerManager:
  extraArgs:
    - name: bind-address
      value: 0.0.0.0
scheduler:
  extraArgs:
    - name: bind-address
      value: 0.0.0.0
etcd:
  local:
    extraArgs:
      - name: listen-metrics-urls
        value: http://0.0.0.0:2381
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
serverTLSBootstrap: false
rotateCertificates: true
# Protect the node from being starved by workloads.
systemReserved:
  cpu: 100m
  memory: 256Mi
evictionHard:
  memory.available: 200Mi
  nodefs.available: 10%
  imagefs.available: 10%
containerLogMaxSize: 20Mi
containerLogMaxFiles: 3
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: iptables
metricsBindAddress: 0.0.0.0:10249
