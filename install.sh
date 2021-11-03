#!/usr/bin/env bash

NODE_NAME=$(hostname)

#安装基础软件以及初始化环境
function env_Initialization() {
  echo "nameserver 223.5.5.5" >>/etc/resolv.conf
  echo "nameserver 8.8.8.8" >>/etc/resolv.conf
  #关闭防火墙
  systemctl stop firewalld
  systemctl disable firewalld
  echo -e "${YELOW_COLOR}============确认结果============${RESET}"
  systemctl status firewalld
  echo -e "${YELOW_COLOR}============确认结果============${RESET}"
  #关闭selinux
  sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
  setenforce 0
  echo -e "${YELOW_COLOR}============确认结果============${RESET}"
  getenforce
  echo "selinux stop"
  echo -e "${YELOW_COLOR}============确认结果============${RESET}"
  #修改yum源，并安装一些常用
  curl -o /etc/yum.repos.d/CentOS-Base.repo https://mirrors.aliyun.com/repo/Centos-7.repo
  curl -o /etc/yum.repos.d/epel.repo http://mirrors.aliyun.com/repo/epel-7.repo
  sed -i -e '/mirrors.cloud.aliyuncs.com/d' -e '/mirrors.aliyuncs.com/d' /etc/yum.repos.d/CentOS-Base.repo
  yum clean all
  yum makecache fast
  yum install -y vim ntpdate wget bash-completion zip
  #修改用户名
  # shellcheck disable=SC2162
  read -p "init name of system(命名规则:节点编号-节点职能-节点职能):" name
  hostnamectl set-hostname "${name}"
  #同步时间
  ntpdate time3.aliyun.com && hwclock -w

}

#优化k8s内核参数
function modification_kernel_file_k8s() {
  cat <<EOF >/etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
EOF
  sysctl --system

}

#安装docker
function install_docker() {
  GPUNUM=$(lspci | grep -i nvidia | wc -l)
  sudo yum install -y yum-utils \
    device-mapper-persistent-data \
    lvm2
  wget -O /etc/yum.repos.d/docker-ce.repo https://download.docker.com/linux/centos/docker-ce.repo
  sudo sed -i 's+download.docker.com+mirrors.tuna.tsinghua.edu.cn/docker-ce+' /etc/yum.repos.d/docker-ce.repo
  yum clean all
  yum makecache fast
  sudo yum install -y docker-ce-18.06.1.ce
  sudo systemctl enable docker && sudo systemctl start docker
  sleep 10
  if [ $GPUNUM != 0 ]; then
    install_gpu_runtime
    mv /etc/docker/daemon.json /etc/docker/daemon.json.bak
    cat <<EOF | sudo tee /etc/docker/daemon.json
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2",
  "graph": "/home/docker",
  "storage-opts": [
    "overlay2.override_kernel_check=true"
  ],
      "runtimes": {
        "nvidia": {
            "path": "nvidia-container-runtime",
            "runtimeArgs": []
        }
    }
}
EOF
  else
    cat <<EOF | sudo tee /etc/docker/daemon.json
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2",
  "graph": "/home/docker",
  "storage-opts": [
    "overlay2.override_kernel_check=true"
  ]
}
EOF
  fi

  sudo systemctl restart docker
}

#安装k8s
function install_K8S() {
  #1)关闭swap分区
  sed -i '/swap/s/^/#/' /etc/fstab
  swapoff -a
  #注释掉/etc/fstab下面的swap 分区那一段

  #3)k8s的yum源
  cat <<EOF >/etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://mirrors.aliyun.com/kubernetes/yum/repos/kubernetes-el7-x86_64/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://mirrors.aliyun.com/kubernetes/yum/doc/yum-key.gpg https://mirrors.aliyun.com/kubernetes/yum/doc/rpm-package-key.gpg
EOF

  #4)安装kubectl，kubelet，kubeadm
  yum install -y kubelet-1.15.3 kubeadm-1.15.3 kubectl-1.15.3
  systemctl enable kubelet
}

#安装helm
function install_helm() {
  ls -l /usr/local/bin/helm &> /dev/null
  if [ $? != 0 ]; then
        tar -zxvf ./tar/helm-v3.1.0-linux-amd64.tar.gz -C ./tar
        cp ./tar/linux-amd64/helm /usr/local/bin/
  fi

}

#install git
function install_git() {
  yum install -y http://opensource.wandisco.com/centos/7/git/x86_64/wandisco-git-release-7-2.noarch.rpm
  yum install -y git
  git config --global push.default simple
}

#安装http配置admin属组
function http_config() {
  yum install httpd -y
  sudo usermod -aG wheel,docker,apache admin
}

#去掉ssh的yes
function close_ssh_ask() {
  echo "StrictHostKeyChecking no" >>/etc/ssh/ssh_config && systemctl restart sshd
}

#安装mongo
function install_mongodb() {
  sudo tar xf ./mongodb/mongodb-linux-x86_64-rhel70-3.6.3.tgz -C /usr/local/
  cd /usr/local/
  sudo mv mongodb-linux-x86_64-rhel70-3.6.3/ mongodb-3.6.3
  sudo ln -sv mongodb-3.6.3/ mongodb
  sudo mkdir /usr/local/mongodb/{conf,data,log}
  echo "MONGODB_HOME=/usr/local/mongodb" >>~/.bash_profile
  echo "PATH=${MONGODB_HOME}/bin:$PATH" >>~/.bash_profile
  cat >/usr/local/mongodb/conf/mongod.conf <<EOF
# mongod.conf

# where to write logging data.
systemLog:
  destination: file
  logAppend: true
  path: /usr/local/mongodb/log/mongod.log

# Where and how to store data.
storage:
  dbPath: /usr/local/mongodb/data
  journal:
    enabled: true

# how the process runs
processManagement:
#  fork: true  # fork and run in background
  pidFilePath: /usr/local/mongodb/mongod.pid  # location of pidfile

# network interfaces
net:
  port: 27017
  bindIp: 0.0.0.0  # Listen to local interface only, comment to listen on all interfaces.

EOF

  cd -
}

#将mongodb加入supervisor启动
function add_mongodb_to_supervisor() {
  yum install supervisor -y && systemctl enable supervisord
  systemctl start supervisord
  systemctl status supervisord && cat >/etc/supervisord.d/mongo.ini <<EOF
[program:mongodb]
command=/usr/local/mongodb/bin/mongod --auth --noIndexBuildRetry -f /usr/local/mongodb/conf/mongod.conf
autostart=true
user=root
EOF
  supervisorctl update
  supervisorctl status
  echo "数据库安装完成"
}

#安装http_proxy
function install_http_proxy() {
  echo "安装http_proxy"
  yum install nodejs -y 
  curl -o- https://raw.githubusercontent.com/creationix/nvm/v0.33.11/install.sh | bash
  echo 'export NVM_DIR="$HOME/.nvm" ' >>/root/.bash_profile 
  echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh" ' >>/root/.bash_profile 
  source ~/.bash_profile 
  npm i configurable-http-proxy -g
  npm install pm2@4.2.3 -g
  sudo -u admin pm2 list 
  mkdir /home/admin/.httpproxy/ && cp http_proxy/config.json /home/admin/.httpproxy/
  cp http_proxy/httpproxy.sh /home/admin/www/
  cp http_proxy/ecosystem.config.js ecosystem.config.js /home/admin/.pm2/
  chown admin:admin /home/admin/.httpproxy/config.json /home/admin/www/httpproxy.sh /home/admin/.pm2/ecosystem.config.js
  sudo -u admin pm2 list
  sudo -u admin pm2 start /home/admin/.pm2/ecosystem.config.js
  sudo -u admin pm2 save 
  sudo -u admin pm2 startup
}

#安装nfs
function install_nfs() {
  #for backend
  sudo mkdir /mnt/user_directory
  sudo mkdir /mnt/modules
  sudo mkdir /mnt/datasets
  sudo mkdir /mnt/functions
  sudo mkdir /mnt/job_staging
  sudo mkdir /mnt/recording
  sudo mkdir /mnt/submissions
  sudo mkdir /mnt/dataset_zip
  sudo mkdir /mnt/teacher_course_practices
  sudo mkdir /mnt/teacher_courses
  sudo mkdir /mnt/registry
  sudo mkdir /mnt/competition

  yum install -y nfs-utils rsync
  systemctl enable rpcbind
  systemctl enable nfs
  systemctl restart rpcbind
  systemctl restart nfs
  # shellcheck disable=SC2129
  echo "/mnt/user_directory *(rw,async,no_subtree_check,anonuid=1000,anongid=1000)" >> /etc/exports
  echo "/mnt/modules *(rw,async,no_subtree_check,anonuid=1000,anongid=1000)" >> /etc/exports
  echo "/mnt/datasets *(rw,async,no_subtree_check,anonuid=1000,anongid=1000)" >> /etc/exports
  echo "/mnt/functions *(rw,async,no_subtree_check,anonuid=1000,anongid=1000)" >> /etc/exports
  echo "/mnt/job_staging *(rw,async,no_subtree_check,anonuid=1000,anongid=1000)" >> /etc/exports
  echo "/mnt/recording *(rw,async,no_subtree_check,anonuid=1000,anongid=1000)" >> /etc/exports
  echo "/mnt/submissions *(rw,async,all_squash,no_subtree_check,anonuid=1000,anongid=1000)" >> /etc/exports
  echo "/mnt/dataset_zip *(rw,async,all_squash,no_subtree_check,anonuid=1000,anongid=1000)" >> /etc/exports
  echo "/mnt/teacher_courses *(rw,async,all_squash,no_subtree_check,anonuid=1000,anongid=1000)" >> /etc/exports
  echo "/mnt/teacher_course_practices *(rw,async,all_squash,no_subtree_check,anonuid=1000,anongid=1000)" >> /etc/exports
  echo "/mnt/registry *(rw,async,all_squash,no_subtree_check,anonuid=1000,anongid=1000)" >> /etc/exports
  echo "/mnt/competition *(rw,async,all_squash,no_subtree_check,anonuid=1000,anongid=1000)" >> /etc/exports
  exportfs -ar
}

#初始化mongo
function init_mongo() {
  sleep 5
  echo $(pwd)
  /usr/local/mongodb/bin/mongo --port 27017 <$(pwd)/mongodb/init-mongo.sh
}

init_data() {
  sleep 10
  /usr/local/mongodb/bin/mongorestore --host 127.0.0.1:27017 -u admin -p q6KRoprgj95TtAP1bBOYb --dir=./mongodb/data
}

init_rocketchat_data() {
  tar xf ./tar/rocket.tar -C /home/
}

#初始化k8s
function init_k8s() {
  kubeadm init --image-repository=registry.aliyuncs.com/google_containers --kubernetes-version=v1.15.3
  mkdir -p "$HOME"/.kube
  sudo cp -i /etc/kubernetes/admin.conf "$HOME"/.kube/config
  sudo chown $(id -u):$(id -g) "$HOME"/.kube/config
  kubectl taint nodes --all node-role.kubernetes.io/master-
  kubectl apply -f "https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version | base64 | tr -d '\n')"
  #  kubectl apply -f ./init/net.yaml

}

#解压镜像
function tar_images() {
  #istio相关镜像
  docker load <images/istio/istio.tar
  docker load <images/istio/jaegertracing.tar
  docker load <images/istio/kiali.tar
  docker load <images/istio/prometheus.tar
  #minio和openfaas镜像
  docker load -i ./images/minio.tar.gz
  docker load -i ./images/openfaas.tar.gz
  #metric镜像
  docker load < images/metrics.tar
}

#添加label
function add_label() {
  NODE_NAME=$(hostname)
  kubectl label node "${NODE_NAME}" function1=backend
  kubectl label node "${NODE_NAME}" function=service
  kubectl label nodes "${NODE_NAME}" accelerator=gpu
  kubectl taint node "${NODE_NAME}" node-role.kubernetes.io/master-
  #kubectl label nodes "${NODE_NAME}" gpu=single
}

#创建目录
function mkdir_directory_for_k8s() {

  #for es
  sudo mkdir -p /data/elasticsearch/data
  sudo mkdir -p /data/elasticsearch/logs
  sudo chmod -R 775 /data/elasticsearch
  sudo mkdir -p /home/elasticsearch
  cp ./es/elasticsearch.docker.yml /home/elasticsearch/
  #for git
  sudo mkdir /var/www/
  sudo touch /var/www/passwd.git
  echo "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDXmPT/X5HedjcI3QDxKy4H3RsUMxvy+WUgLZOEeoNmqt2L7HnobvufRJ4CwTQ5h7+ak/60oh/MU8QQxgQZkPTJ2NEa41s7Gj/NauWqInupGHSJsTgErXnOd7i9kYm/JTT5LayHDGRugXaVY1Uw+w0cg7Zf83P9zuZwGuoJSzHkKjmFSVRFCwj+eg/UIgZXO3ueFRFgs+eWGwqo3GUZnTNE2/KRubYvPipJ/VHdFdW1cee8+c+6YwaWrNAOlnYv3Xogi7n2p9n7+SeggoZ/cqixjIWx+Nn+qKMQ66DIbe2ahVgVDAKETK1M35vcXX3wGHtGre6kd2Oc4N1IHAHTCjM3 box_pyserver" >>/home/admin/.ssh/authorized_keys
  chmod 600 /home/admin/.ssh/authorized_keys
  chown -R admin.admin /home/admin/.ssh/authorized_keys
  echo "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDXmPT/X5HedjcI3QDxKy4H3RsUMxvy+WUgLZOEeoNmqt2L7HnobvufRJ4CwTQ5h7+ak/60oh/MU8QQxgQZkPTJ2NEa41s7Gj/NauWqInupGHSJsTgErXnOd7i9kYm/JTT5LayHDGRugXaVY1Uw+w0cg7Zf83P9zuZwGuoJSzHkKjmFSVRFCwj+eg/UIgZXO3ueFRFgs+eWGwqo3GUZnTNE2/KRubYvPipJ/VHdFdW1cee8+c+6YwaWrNAOlnYv3Xogi7n2p9n7+SeggoZ/cqixjIWx+Nn+qKMQ66DIbe2ahVgVDAKETK1M35vcXX3wGHtGre6kd2Oc4N1IHAHTCjM3 box_pyserver" >>/root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
  #for jupyter
  mkdir -p /home/admin/www/mo_prod/pyserver/
  cp -r /root/.kube /home/admin/
  #for redis
  mkdir /etc/redis
  cp ./redis/redis.conf /etc/redis/
  cp ./redis/run.sh /etc/redis/

  #for rocket-chat
  #tar xf ./rocket_chat/rocket.tar -C /home/

  #for user
  mkdir /mnt/user_directory/
  chown -R admin.admin /mnt/user_directory/
  chown -R admin.admin /mnt/*
  cp ./tar/.localenv.tar.gz.tf23py37 /mnt/user_directory/
  cp ./tar/.localenv.tar.gz /mnt/user_directory/
  #课件
  tar xf ./tar/CourseTemplate.tar -C /mnt/user_directory/
  mv /mnt/user_directory/CourseTemplate /mnt/user_directory/.CourseTemplate

}

#跑yaml
function run_yaml() {
  #for init
  sleep 10
  kubectl apply -f init/namespace.yaml
  kubectl apply -f init/RBAC.yaml
  kubectl apply -f init/VirtualService.yaml
  kubectl apply -f init/ingrees-getway.yaml
  #for frontend
  kubectl apply -f frontend/frontend-web-server.yaml
  #for backend
  kubectl apply -f backend/backend.yaml
  #for backend_status
  kubectl apply -f backend_status/status.yaml
  #for es
  kubectl apply -f es/es.yaml
  #for git
  sudo mkdir /var/www/user_repos/
  kubectl apply -f git/git.yaml
  #for jupyter
  kubectl apply -f jupyterhub_and_db/jupyterhub_db.yaml
  sleep 10
  kubectl apply -f jupyterhub_and_db/jupyterhub.yaml
  #for klaus
  kubectl apply -f klaus/klaus.yaml
  #for pyls
  kubectl apply -f pyls/pyls.yaml
  #for rabbit
  kubectl apply -f rabbitmq/rabbitmq-controller.yaml
  # for celery 修改为本机ip
  kubectl apply -f rabbitmq/celery-controller.yaml
  #for redis
  kubectl apply -f redis/redis.yaml
  #for rocket

  kubectl apply -f rocket_chat/mongo.yaml
  sleep 10
  kubectl apply -f rocket_chat/rocket.yaml
  #for socket
  kubectl apply -f socketio/socketio.yaml
  #for script
  kubectl apply -f script/kube_job_cleaner.yaml
  kubectl apply -f script/schedule_notebook_check.yaml
  kubectl apply -f script/email_sender.yaml
  kubectl apply -f script/live_celery.yaml
  kubectl apply -f script/schedule_snap_uaa.yaml
  kubectl apply -f script/celery_for_notebook.yaml
  #kubectl apply -f script/temp_user_creator.yaml
  #for registry
  kubectl apply -f registry/registry.yaml
  #for pdf
  kubectl apply -f pdf_service/pdf.yaml
  #for metrics
  kubectl apply -f metrics/
}

#更新使用后端镜像的yaml
function update_backend_images() {
  kubectl apply -f script/kube_job_cleaner.yaml
  kubectl apply -f script/schedule_notebook_check.yaml
  kubectl apply -f script/email_sender.yaml
  kubectl apply -f script/live_celery.yaml
  kubectl apply -f script/schedule_snap_uaa.yaml
  kubectl apply -f script/job_service.yaml
  kubectl apply -f script/pods_cleaner.yaml
  kubectl apply -f backend/backend.yaml
  kubectl apply -f backend_status/status.yaml
}

#创建阿里云的secret用于拉镜像
function create_secret() {
  kubectl apply -f ./init/namespace.yaml
  kubectl create secret -n mo-service docker-registry aliyunkey \
  --docker-server=registry.cn-hangzhou.aliyuncs.com \
  --docker-username=lzfxxx@gmail.com \
  --docker-password=digital@lab \
  --docker-email=lzfxxx@gmail.com

  kubectl create secret -n mo-script docker-registry aliyunkey \
  --docker-server=registry.cn-hangzhou.aliyuncs.com \
  --docker-username=lzfxxx@gmail.com \
  --docker-password=digital@lab \
  --docker-email=lzfxxx@gmail.com

  kubectl create secret -n kube-system docker-registry aliyunkey \
  --docker-server=registry.cn-hangzhou.aliyuncs.com \
  --docker-username=lzfxxx@gmail.com \
  --docker-password=digital@lab \
  --docker-email=lzfxxx@gmail.com

  kubectl create secret  docker-registry aliyunkey \
  --docker-server=registry.cn-hangzhou.aliyuncs.com \
  --docker-username=lzfxxx@gmail.com \
  --docker-password=digital@lab \
  --docker-email=lzfxxx@gmail.com
}

#添加host解析
function add_host() {
  # shellcheck disable=SC2162
  #read -p "输入服务节点的ip(如果是初次安装则是本机节点):" LOCAL_IP

  echo $LOCAL_IP momodel-k8s >>/etc/hosts
  echo $LOCAL_IP momodel-k8s-mongo >>/etc/hosts
  echo $LOCAL_IP momodel-k8s-nfs >>/etc/hosts
  echo $LOCAL_IP momodel-k8s-git >>/etc/hosts

}

#安装istio
function install_istio() {
  tar xf ./tar/istio-1.6.8-linux-amd64.tar.gz -C ./tar/
  cd ./tar/istio-1.6.8
  export PATH=$PWD/bin:$PATH
  istioctl manifest apply --set profile=demo --set values.gateways.istio-ingressgateway.type=NodePort
  sleep 10
  kubectl -n istio-system get svc/istio-ingressgateway -o yaml | sed "/name: http2/{n;s/nodePort: [0-9]*/nodePort: 30936/;}" | kubectl replace -f -
  cd -
}

#添加admin以及sudo
function useradd_and_sudo() {
  adduser admin -u 1000
  echo 'admin    ALL=(ALL)       ALL' | sudo EDITOR='tee -a' visudo
  echo 'admin        ALL=(ALL)       NOPASSWD: ALL' | sudo EDITOR='tee -a' visudo

}

#拉取镜像


#初始化admin和root的key
function add_ssh_key() {
  #root key
  ssh-keygen -t rsa -N '' -f ~/.ssh/id_rsa
  touch /root/.ssh/authorized_keys
  cat /root/.ssh/id_rsa.pub >>/root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys

  #admin key
  sudo -u admin ssh-keygen -t rsa -N '' -f /home/admin/.ssh/id_rsa
  touch /home/admin/.ssh/authorized_keys
  cat /home/admin/.ssh/id_rsa.pub >>/home/admin/.ssh/authorized_keys
  chmod 600 /home/admin/.ssh/authorized_keys
  chown -R admin.admin /home/admin/.ssh/authorized_keys
}

#安装命令补全
#function add_tab() {
#yum install -y bash-completion
#source /usr/share/bash-completion/bash_completion
#source <(kubectl completion bash)
#echo "source <(kubectl completion bash)" >> ~/.bashrc
#}

#安装openfass
function install_openfass() {
  kubectl apply -f ./init/namespaces-openfaas.yaml
  # kubectl apply -f https://raw.githubusercontent.com/openfaas/faas-netes/master/namespaces.yml
  #  export https_proxy=192.168.3.30:7890
  #  export http_proxy=192.168.3.30:7890
  #helm repo add openfaas https://openfaas.github.io/faas-netes/
  sleep 5
  helm upgrade openfaas --install ./chart/openfaas \
    --version v3.3.0 \
    --namespace openfaas  \
    --set basic_auth=false \
    --set functionNamespace=openfaas-fn \
    --set gateway.nodePort=31419 \
    --set faasnetes.httpProbe=true \
    --set openfaasImagePullPolicy=IfNotPresent \
    --set faasIdler.dryRun=false
  sleep 10
  yum install -y jq
  sudo jq --arg ip "$(hostname -I | awk '{print $1}'):5000" '."insecure-registries"[0] = $ip' /etc/docker/daemon.json >/tmp/daemon.json && sudo mv -f /tmp/daemon.json /etc/docker/daemon.json
  sleep 5
  sudo systemctl restart docker
  sleep 30
}


#安装minio
function install_minio() {
  mkdir /home/admin/minio
  mkdir /mnt/minio
  chmod 777 /mnt
  chmod 777 /mnt/minio

  cat <<EOF >/home/admin/minio/minio_pv.yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: minio
  labels:
    type: local
    app: minio
spec:
  capacity:
    storage: 30Gi
  accessModes:
    - ReadWriteOnce
  hostPath:
    path: /mnt/minio
EOF
  sleep 5
  kubectl create -f /home/admin/minio/minio_pv.yaml
  sleep 5
  #helm repo add minio https://helm.min.io/
  #sleep 5
  #helm repo update && helm install minio --set accessKey=MOMINIO,secretKey=MOMODELMINIO,persistence.size=30Gi minio/minio
  helm install minio --set accessKey=MOMINIO,secretKey=MOMODELMINIO,persistence.size=30Gi ./chart/minio
  sleep 10
  kubectl get service/minio -o yaml | sed "s/type: ClusterIP/type: NodePort/" | sed "/port: 9000/a\    nodePort: 31651" | kubectl replace -f -
}

init_es() {
  docker rm es111
  #docker run --name es111 registry.cn-hangzhou.aliyuncs.com/momodel/backend:EDU-master-latest bash -c 'echo "'$LOCAL_IP' momodel-k8s-mongo" >> /etc/hosts && ENV=K8S python3 -m server3.service.search_service --all'
  backend_pod_name= `kubectl get pod -n mo-service  |grep pyserver |awk '{print $1}'`
  kubectl exec -it ${backend_pod_name}  -n mo-service -- echo "'$LOCAL_IP' momodel-k8s-mongo" >> /etc/hosts && ENV=K8S python3 -m server3.service.search_service --all
}

init_k8s_dns() {
  kubectl get configmap coredns -n kube-system -o yaml | sed "/prometheus/i\        hosts {\n            $LOCAL_IP m-model\n            $LOCAL_IP modelrc.cn\n            $LOCAL_IP momodel-k8s\n            $LOCAL_IP momodel-k8s-git\n            $LOCAL_IP momodel-k8s-mongo\n            $LOCAL_IP momodel-k8s-nfs\n            fallthrough\n        }\n" | kubectl replace -f -
  kubectl scale deployment coredns -n kube-system --replicas=0
  kubectl scale deployment coredns -n kube-system --replicas=2
}

init_GPU_drive() {
  echo "GPU驱动安装部署"
  yum install -y pciutils
  sudo rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org
  sudo rpm -Uvh http://www.elrepo.org/elrepo-release-7.0-3.el7.elrepo.noarch.rpm
  sed -i "s/blacklist nvidiafb/#blacklist nvidiafb/" /lib/modprobe.d/dist-blacklist.conf
  echo "blacklist nouveau" >>/lib/modprobe.d/dist-blacklist.conf
  echo "options nouveau modeset=0" >>/lib/modprobe.d/dist-blacklist.conf
  sudo mv /boot/initramfs-$(uname -r).img /home/initramfs-$(uname -r).img.bak
  sudo dracut /boot/initramfs-$(uname -r).img $(uname -r)
  echo "需要重启服务器,正在重启"
  reboot

}
install_GPU_drive() {
  sudo yum -y install kmod-nvidia
  echo "安装完之后会重启系统"
  reboot
}

init_GPU_manager() {
  echo "GPU隔离插件部署"
  kubectl label node "$NODE_NAME" nvidia-device-enable=enable
  cp ./GPU/scheduler-policy-config.json /etc/kubernetes/
  #将/etc/kubernetes/manifests/kube-scheduler.yaml替换为GPU的
  mv /etc/kubernetes/manifests/kube-scheduler.yaml /etc/kubernetes/manifests/kube-scheduler.yaml.bak
  sleep 3
  cp ./GPU/kube-scheduler.yaml /etc/kubernetes/manifests/
  kubectl apply -f ./GPU/gpu-manager.yaml
}

service_status() {
  sh ./init/web-status.sh "$LOCAL_IP:30936" frontend_proxy
  sh ./init/web-status.sh "$LOCAL_IP:30936" backend
  sh ./init/web-status.sh "$LOCAL_IP:30936" socketio
  sh ./init/web-status.sh "$LOCAL_IP:30936" user_manager
  sh ./init/web-status.sh "$LOCAL_IP:30936" cluster_nodes
  sh ./init/web-status.sh "$LOCAL_IP:30936" service_pods
  sh ./init/web-status.sh "$LOCAL_IP:30936" search_service
  sh ./init/web-status.sh "$LOCAL_IP:30936" chat_service
  sh ./init/web-status.sh "$LOCAL_IP:30936" registry

}

modify_k8s_config() {
  echo "修改k8s配置文件"
  sed -i "/tls-private-key-file/a\    - --feature-gates=TTLAfterFinished=true" /etc/kubernetes/manifests/kube-apiserver.yaml
  sed -i "/--leader-elect/a\    - --feature-gates=TTLAfterFinished=true" /etc/kubernetes/manifests/kube-scheduler.yaml
}

all_run() {
  sleep 10
  NORUN=$(kubectl get pods --all-namespaces | grep -v "Running" | wc -l)
  while [ "$NORUN" != 1 ]; do
    NORUN=$(kubectl get pods --all-namespaces | grep -v "Running" | wc -l)
    echo "还未启动完成的组件是"
    kubectl get pods --all-namespaces | grep -v "Running"
    echo 100s后再次显示
    sleep 100s
  done
}

install_gpu_runtime() {
    docker volume ls -q -f driver=nvidia-docker | xargs -r -I{} -n1 docker ps -q -a -f volume={} | xargs -r docker rm -f
    sudo yum remove nvidia-docker
    distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
    curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.repo | \
    sudo tee /etc/yum.repos.d/nvidia-docker.repo
    sudo yum install -y nvidia-docker2-2.0.3-1.docker18.06.1.ce
}

add_fstab() {
  yum install -y nfs-utils
  num=$(cat /etc/fstab | grep mnt | wc -l)

  if [[ $num -gt 1 ]]; then
    echo 已经输入了
  else
    echo "10.200.11.143:/mnt/modules  /mnt/modules       nfs     defaults,noatime,nodiratime,noresvport,soft 0 0" >>/etc/fstab
    echo "10.200.11.143:/mnt/datasets     /mnt/datasets   nfs defaults,noatime,nodiratime,noresvport,soft 0 0" >>/etc/fstab
    echo "10.200.11.143:/mnt/functions        /mnt/functions       nfs     defaults,noatime,nodiratime,noresvport,soft 0 0" >>/etc/fstab
    echo "10.200.11.143:/mnt/job_staging  /mnt/job_staging       nfs     defaults,noatime,nodiratime,noresvport,soft 0 0" >>/etc/fstab
    echo "10.200.11.143:/mnt/user_directory   /mnt/user_directory       nfs     defaults,noatime,nodiratime,noresvport,soft 0 0" >>/etc/fstab
    echo "10.200.11.143:/mnt/submissions   /mnt/submissions       nfs     defaults,noatime,nodiratime,noresvport,soft 0 0" >>/etc/fstab
    echo "10.200.11.143:/mnt/recording   /mnt/recording       nfs     defaults,noatime,nodiratime,noresvport,soft 0 0" >>/etc/fstab
    echo "10.200.11.143:/mnt/competition   /mnt/competition       nfs     defaults,noatime,nodiratime,noresvport,soft 0 0" >>/etc/fstab
  fi

  mkdir -p /mnt/modules
  mkdir -p /mnt/datasets
  mkdir -p /mnt/functions
  mkdir -p /mnt/job_staging
  mkdir -p /mnt/user_directory
  mkdir -p /mnt/submissions
  mkdir -p /mnt/recording
  mkdir -p /mnt/competition

  mount -a
}

join_k8s() {
  shell=$(ssh $LOCAL_IP "kubeadm token create $(kubeadm token generate) --print-join-command --ttl=0")
  $shell
  GPUNUM=$(lspci | grep -i nvidia | wc -l)
  if [ GPUNUM != 0 ]; then
    NODE_NAME=$(hostname)
    ssh $LOCAL_IP "kubectl label node "$NODE_NAME" nvidia-device-enable=enable "
  fi

}

function add_miyao() {
  sudo -u admin ssh-keygen -t rsa -N '' -f /home/admin/.ssh/id_rsa
  touch /home/admin/.ssh/authorized_keys
  cat /home/admin/.ssh/id_rsa.pub >>/home/admin/.ssh/authorized_keys
  chmod 600 /home/admin/.ssh/authorized_keys
  chown -R admin.admin /home/admin/.ssh/authorized_keys
}

check_mo() {
     curl $LOCAL_IP:30936|grep "人工智能在线建模平台"  >> /dev/null 2>&1
    if [ $? == 0 ]; then
        echo "平台已经部署,脚本将退出"
        exit
    fi
}

check_dir() {
  ls -l|grep lv9-install.sh &> /dev/null
    if [ $? != 0 ]; then
        echo "没有在lv9-install.sh的同级目录执行脚本,请到lv9-install.sh脚本的同级目录执行脚本"
        exit
    fi
}

check_ip() {
  ip=$(python init/get-ip.py)
  if [ $ip != $LOCAL_IP ]; then
    echo "输入IP与检测到的本机IP不同,请确实好本机IP再重新执行该脚本,如果确认无误依旧报该错误请将本方法注释"
      exit
  fi
}
function backup(){
  rm -rf  /opt/backup && mkdir /opt/backup &&  cd /opt/backup
  echo "---------------正在备份数据-------------------"
  systemctl stop kubelet  && systemctl stop docker && /usr/local/mongodb-3.6.3/bin/mongodump --port 27017 --archive=data.gz --gzip -d goldersgreen
  echo "--------------正在备份用户目录-----------------"
  tar -zcpPf backup.tar.gz   /mnt/* /home/rocket-chat/* /var/www/user_repos/* /home/admin/www/postgresql/* && systemctl start docker && systemctl start kubelet
  echo "----------------传压缩文件----------------------"
  ssh $REMOTE_IP "rm  -rf /opt/backup && mkdir /opt/backup"
  rsync backup.tar.gz data.gz $REMOTE_IP:/opt/backup
}
function restore() {
  echo '-----------------还原数据---------------------'
  ssh $REMOTE_IP  "systemctl stop docker  && systemctl stop kubelet && /usr/local/mongodb/bin/mongo  127.0.0.1:27017/goldersgreen --eval 'db.dropDatabase()'"
  ssh $REMOTE_IP  "/usr/local/mongodb/bin/mongorestore -u admin -p q6KRoprgj95TtAP1bBOYb  --gzip --archive=/opt/backup/data.gz"
  echo '-----------------还原用户目录---------------------'
  ssh $REMOTE_IP  "cd /opt/backup && rm /home/rocket-chat/ -rf && tar xpPf  /opt/backup/backup.tar.gz && systemctl start docker && systemctl start kubelet"
}
notebook_test() {
  docker run -it -v /dev/shm:/dev/shm auto-test:latest bash -c "python3 9love_auto_test.py "$LOCAL_IP":30936"
}

read -p "输入数字:1.安装GPU驱动初始化配置(服务器会重启,重启完成之后运行第2步) 2.安装GPU驱动 3.安装数据库  4.安装平台 5.平台检测 6.卸载平台(不影响数据库以及用户目录) 7.备份（备份前会停止当前系统运行） 8.恢复（在恢复数据前需要先安装平台）)"  NUM

case $NUM in
1)
  echo "init GPU"
  init_GPU_drive
  ;;
2)
  echo "install GPU drive"
  install_GPU_drive
  ;;
3)
  #安装mongo
  install_mongodb
  add_mongodb_to_supervisor
  #初始化mongo
  echo "安装 mongo"
  init_mongo
  init_data
  init_rocketchat_data
  #安装nfs
  echo "install nfs"
  install_nfs
  ;;
4)
  #服务器初始化以及安装软件
  nvidia-smi
  echo "如果能看到显卡型号和其他信息则正常"
  echo "服务器初始化"
  read -p "输入服务节点的ip(如果是初次安装则是本机节点):" LOCAL_IP
  check_dir
  check_ip
  check_mo
  env_Initialization
  add_host
  modification_kernel_file_k8s
  install_docker
  install_K8S
  init_k8s
  install_helm
  install_git
  useradd_and_sudo
  http_config
  add_ssh_key
  close_ssh_ask
  install_http_proxy
  tar_images
  add_label
  mkdir_directory_for_k8s
  install_istio
  echo "run"
  init_k8s_dns
  create_secret
  run_yaml
  #安装GPU隔离插件以及修改k8s配置以删除Completed的pod
  init_GPU_manager
  modify_k8s_config
  #在k8s中安装openfaas和minio
  echo "install openfaas and minio"
  install_minio
  install_openfass
  echo "init es"
  all_run
  init_es
  ;;
5)
  echo "平台检测开始"
  read -p "输入服务节点的ip(如果是初次安装则是本机节点):" LOCAL_IP
  service_status
  notebook_test
  ;;
  #跑自测脚本
6)
  echo "平台卸载"
  kubeadm reset
  ;;
  #跑自测脚本
7)
  read -p "输入需要恢复的节点IP:" REMOTE_IP
  echo "平台备份"
  backup
  ;;
8)
  read -p "输入需要恢复的节点IP(有删除数据库的操作,请输入正确的IP):" REMOTE_IP
  echo "数据恢复"
  restore
  ;;
9)
  echo "更新"
  read -p "请输入需要更新的tag:" TAG
  lv9_update
  ;;
959)
  echo "worker节点加入之前需要做好计算节点与服务节点之间的免密"
  read -p "输入服务节点的ip(如果是初次安装则是本机节点):" LOCAL_IP
  env_Initialization
  add_host
  modification_kernel_file_k8s
  install_docker
  install_K8S
  useradd_and_sudo
  add_miyao
  add_fstab
  join_k8s
  ;;
esac
