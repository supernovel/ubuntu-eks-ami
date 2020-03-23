#!/usr/bin/env bash

set -o pipefail
set -o nounset
set -o errexit

IFS=$'\n\t'

TEMPLATE_DIR=${TEMPLATE_DIR:-/tmp/worker}

################################################################################
### Validate Required Arguments ################################################
################################################################################
validate_env_set() {
    (
        set +o nounset

        if [ -z "${!1}" ]; then
            echo "Packer variable '$1' was not set. Aborting"
            exit 1
        fi
    )
}

validate_env_set BINARY_BUCKET_NAME
validate_env_set BINARY_BUCKET_REGION
validate_env_set DOCKER_VERSION
validate_env_set CNI_VERSION
validate_env_set CNI_PLUGIN_VERSION
validate_env_set KUBERNETES_VERSION
validate_env_set KUBERNETES_BUILD_DATE

################################################################################
### Machine Architecture #######################################################
################################################################################

MACHINE=$(uname -m)
if [ "$MACHINE" == "x86_64" ]; then
    ARCH="amd64"
elif [ "$MACHINE" == "aarch64" ]; then
    ARCH="arm64"
else
    echo "Unknown machine architecture '$MACHINE'" >&2
    exit 1
fi

################################################################################
### Packages ###################################################################
################################################################################

# Update the OS to begin with to catch up to the latest packages.
sudo add-apt-repository universe
sudo apt-get update -y

# It should be noted that this installs awscli 1.14, which does not contain EKS.
# We install the latest version of the awscli further down, after pip3 has been installed
sudo apt-get install -y \
    conntrack \
    chrony \
    awscli \
    wget \
    curl \
    socat \
    unzip \
    jq \
    nfs-kernel-server \
    apt-transport-https \
    ca-certificates \
    software-properties-common \
    gnupg2

################################################################################
### Time #######################################################################
################################################################################

# Make sure Amazon Time Sync Service starts on boot.
sudo update-rc.d chrony defaults 80 20

# However, chrony does not use Amazon Time Sync Service by default in Ubuntu
# So, we will have to configure it to prefer it according to this:
# https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/set-time.html#configure-amazon-time-service-ubuntu

sudo sed -i '1s/^/server 169.254.169.123 prefer iburst minpoll 4 maxpoll 4\n/' /etc/chrony/chrony.conf

# If current clocksource is xen, switch to tsc
if grep --quiet xen /sys/devices/system/clocksource/clocksource0/current_clocksource &&
  grep --quiet tsc /sys/devices/system/clocksource/clocksource0/available_clocksource; then
    echo "tsc" | sudo tee /sys/devices/system/clocksource/clocksource0/current_clocksource
else
    echo "tsc as a clock source is not applicable, skipping."
fi

################################################################################
### iptables ###################################################################
################################################################################

# Enable forwarding via iptables
sudo bash -c "iptables-save > /etc/network/iptables"

sudo mv $TEMPLATE_DIR/iptables-restore.service /etc/systemd/system/iptables-restore.service

sudo systemctl daemon-reload
sudo systemctl enable iptables-restore

################################################################################
### Docker #####################################################################
################################################################################

INSTALL_DOCKER="${INSTALL_DOCKER:-true}"
if [[ "$INSTALL_DOCKER" == "true" ]]; then
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
  sudo apt-key fingerprint 0EBFCD88

  sudo add-apt-repository \
    "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) \
    stable"

  sudo apt-get update -y
  sudo apt-get install -y \
    containerd.io \
    docker-ce=$DOCKER_VERSION \
    docker-ce-cli=$DOCKER_VERSION

  sudo usermod -aG docker $USER
  
  sudo mkdir -p /etc/docker
  sudo mv $TEMPLATE_DIR/docker-daemon.json /etc/docker/daemon.json
  sudo chown root:root /etc/docker/daemon.json
  
  # Enable docker daemon to start on boot.
  sudo systemctl daemon-reload
  sudo systemctl enable docker
fi

################################################################################
### Logrotate ##################################################################
################################################################################

# kubelet uses journald which has built-in rotation and capped size.
# See man 5 journald.conf
sudo mv $TEMPLATE_DIR/logrotate-kube-proxy /etc/logrotate.d/kube-proxy
sudo chown root:root /etc/logrotate.d/kube-proxy
sudo mkdir -p /var/log/journal

################################################################################
### Kubernetes #################################################################
################################################################################

sudo mkdir -p /etc/kubernetes/manifests
sudo mkdir -p /var/lib/kubernetes
sudo mkdir -p /var/lib/kubelet
sudo mkdir -p /opt/cni/bin

wget https://github.com/containernetworking/cni/releases/download/${CNI_VERSION}/cni-${ARCH}-${CNI_VERSION}.tgz
wget https://github.com/containernetworking/cni/releases/download/${CNI_VERSION}/cni-${ARCH}-${CNI_VERSION}.tgz.sha512
sudo sha512sum -c cni-${ARCH}-${CNI_VERSION}.tgz.sha512
sudo tar -xvf cni-${ARCH}-${CNI_VERSION}.tgz -C /opt/cni/bin
rm cni-${ARCH}-${CNI_VERSION}.tgz cni-${ARCH}-${CNI_VERSION}.tgz.sha512

wget https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGIN_VERSION}/cni-plugins-${ARCH}-${CNI_PLUGIN_VERSION}.tgz
wget https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGIN_VERSION}/cni-plugins-${ARCH}-${CNI_PLUGIN_VERSION}.tgz.sha512
sudo sha512sum -c cni-plugins-${ARCH}-${CNI_PLUGIN_VERSION}.tgz.sha512
sudo tar -xvf cni-plugins-${ARCH}-${CNI_PLUGIN_VERSION}.tgz -C /opt/cni/bin
rm cni-plugins-${ARCH}-${CNI_PLUGIN_VERSION}.tgz cni-plugins-${ARCH}-${CNI_PLUGIN_VERSION}.tgz.sha512

# Install kubelet, kubectl
sudo snap install kubectl-eks --channel=$KUBERNETES_VERSION/stable --classic
sudo snap install kubelet-eks --channel=$KUBERNETES_VERSION/stable --classic

# Install aws-iam-authenticator
echo "Downloading binaries from: s3://$BINARY_BUCKET_NAME"
S3_DOMAIN="amazonaws.com"
if [ "$BINARY_BUCKET_REGION" = "cn-north-1" ] || [ "$BINARY_BUCKET_REGION" = "cn-northwest-1" ]; then
    S3_DOMAIN="amazonaws.com.cn"
fi
S3_URL_BASE="https://$BINARY_BUCKET_NAME.s3.$BINARY_BUCKET_REGION.$S3_DOMAIN/$KUBERNETES_VERSION/$KUBERNETES_BUILD_DATE/bin/linux/$ARCH"
S3_PATH="s3://$BINARY_BUCKET_NAME/$KUBERNETES_VERSION/$KUBERNETES_BUILD_DATE/bin/linux/$ARCH"

BINARIES=(
    aws-iam-authenticator
)
for binary in ${BINARIES[*]} ; do
    if [[ ! -z "$AWS_ACCESS_KEY_ID" ]]; then
        echo "AWS cli present - using it to copy binaries from s3."
        aws s3 cp --region $BINARY_BUCKET_REGION $S3_PATH/$binary .
        aws s3 cp --region $BINARY_BUCKET_REGION $S3_PATH/$binary.sha256 .
    else
        echo "AWS cli missing - using wget to fetch binaries from s3. Note: This won't work for private bucket."
        sudo wget $S3_URL_BASE/$binary
        sudo wget $S3_URL_BASE/$binary.sha256
    fi
    sudo sha256sum -c $binary.sha256
    sudo chmod +x $binary
    sudo mv $binary /usr/bin/
done
sudo rm *.sha256

KUBERNETES_MINOR_VERSION=${KUBERNETES_VERSION%.*}

sudo mkdir -p /etc/kubernetes/kubelet
sudo mv $TEMPLATE_DIR/kubelet-kubeconfig /var/lib/kubelet/kubeconfig
sudo chown root:root /var/lib/kubelet/kubeconfig
sudo mv $TEMPLATE_DIR/kubelet-config.json /etc/kubernetes/kubelet/kubelet-config.json
sudo chown root:root /etc/kubernetes/kubelet/kubelet-config.json

################################################################################
### EKS ########################################################################
################################################################################

sudo mkdir -p /etc/eks
sudo mv $TEMPLATE_DIR/eni-max-pods.txt /etc/eks/eni-max-pods.txt
sudo mv $TEMPLATE_DIR/bootstrap.sh /etc/eks/bootstrap.sh
sudo chmod +x /etc/eks/bootstrap.sh

################################################################################
### AMI Metadata ###############################################################
################################################################################

BASE_AMI_ID=$(curl -s  http://169.254.169.254/latest/meta-data/ami-id)
cat <<EOF > /tmp/release
BASE_AMI_ID="$BASE_AMI_ID"
BUILD_TIME="$(date)"
BUILD_KERNEL="$(uname -r)"
ARCH="$(uname -m)"
EOF
sudo mv /tmp/release /etc/eks/release
sudo chown -R root:root /etc/eks

################################################################################
### Cleanup ####################################################################
################################################################################

# Clean up yum caches to reduce the image size
sudo apt-get -y autoremove && sudo apt-get clean

sudo rm -rf \
    $TEMPLATE_DIR  \
    /var/lib/apt/lists/*

# Clean up files to reduce confusion during debug
sudo rm -rf \
    /etc/ssh/ssh_host* \
    /root/.ssh/authorized_keys \
    /home/ubuntu/.ssh/authorized_keys \
    /var/log/secure \
    /var/log/wtmp \
    /var/lib/dhclient/* \
    /var/lib/dhcp/dhclient.* \
    /var/lib/cloud/sem \
    /var/lib/cloud/data \
    /var/lib/cloud/instance \
    /var/lib/cloud/instances \
    /var/log/cloud-init.log \
    /var/log/cloud-init-output.log