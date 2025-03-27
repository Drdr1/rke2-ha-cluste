# RKE2 HA Cluster with Rancher Prime Installation Guide

## Prerequisites
- 3 Ubuntu 20.04 (or later) VMs provisioned in your cloud environment.
- SSH access to all VMs as the `ubuntu` user with root privileges (SSH keys configured in `~/.ssh/authorized_keys` on each VM).
- Helm installed on your workstation (`curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 && chmod +x get_helm.sh && ./get_helm.sh`).
- Python 3 installed (for serving the Helm chart).
- Your TLS certificates (`abc.cert`, `abc.key`, `cacerts.pem`) ready.

## Step 1: Prepare Your VMs
1. **Provision VMs**:
   - Create 3 Ubuntu VMs with static IPs in the same subnet.
   - Apply this cloud-config during VM creation (adjust SSH key and password):
     ```yaml
     #cloud-config
     package_update: true
     package_upgrade: true
     packages:
       - nfs-common
       - qemu-guest-agent
     write_files:
       - path: /etc/ssh/sshd_config.d/99-custom.conf
         content: |
           PasswordAuthentication yes
         permissions: '0644'
     users:
       - name: ubuntu
         ssh-authorized-keys:
           - ssh-rsa YOUR_PUBLIC_SSH_KEY_HERE
         passwd: "$6$rounds=4096$YOUR_HASHED_PASSWORD"
         lock_passwd: false
     runcmd:
       - systemctl disable --now ufw
       - systemctl enable --now qemu-guest-agent
       - apt autoremove -y
       - echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
       - sysctl -p
