# k8s cluster in OpenStack
##########################

# key management
################
resource "openstack_compute_keypair_v2" "keypair" {
  name       = "k8s_keys"
  public_key = "${file("secrets/id_rsa.pub")}"
}

# variables -modify with a terraform.tfvars-
#################################
variable "hyperkube_version" {
  default = "v1.5.4_coreos.0"
}
variable "ssh_private_key" {
  default = "secrets/id_rsa"
}
variable "number_of_workers" {
  default = "3"
}
variable "k8s_master_ip" {
  default = "192.168.1.20"
}
variable "k8s_etcd_ip" {
  default = "192.168.1.10"
}
variable "k8s_cluster_name" {
  default = "devKubeStack"
}

# build a private network
#########################
resource "openstack_networking_network_v2" "primary_network" {
  name           = "${var.k8s_cluster_name}Net"
  admin_state_up = "true"
}
resource "openstack_networking_subnet_v2" "primary_subnet_v4" {
  name        = "${var.k8s_cluster_name}Net-v4"
  network_id  = "${openstack_networking_network_v2.primary_network.id}"
  enable_dhcp = "true"
  cidr        = "192.168.1.0/24"
  ip_version  = 4
}

# create security groups
########################
resource "openstack_compute_secgroup_v2" "internal_security" {
  name        = "internal security"
  description = "Allows open communication between nodes"
  # tcp all
  rule {
    from_port   = 1
    to_port     = 65535
    ip_protocol = "tcp"
    self        = "true"
  }
  # udp all
  rule {
    from_port   = 1
    to_port     = 65535
    ip_protocol = "udp"
    self        = "true"
  }
  # icmp all
  rule {
    from_port   = -1
    to_port     = -1
    ip_protocol = "icmp"
    self        = "true"
  }
}
resource "openstack_compute_secgroup_v2" "etcd_external" {
  name        = "etcd external security"
  description = "Allows communication to etcd discovery service"
  # 4001/tcp
  rule {
    from_port   = 4001
    to_port     = 4001
    ip_protocol = "tcp"
    cidr        = "0.0.0.0/0"
  }
  # 2379/tcp
  rule {
    from_port   = 2379
    to_port     = 2379
    ip_protocol = "tcp"
    cidr        = "0.0.0.0/0"
  }
  # 2380/tcp
  rule {
    from_port   = 2380
    to_port     = 2380
    ip_protocol = "tcp"
    cidr        = "0.0.0.0/0"
  }
  # 80/tcp
  rule {
    from_port   = 80
    to_port     = 80
    ip_protocol = "tcp"
    cidr        = "0.0.0.0/0"
  }
 # 443/tcp
  rule {
    from_port   = 443
    to_port     = 443
    ip_protocol = "tcp"
    cidr        = "0.0.0.0/0"
  }
}

# etcd host
###########
resource "openstack_compute_instance_v2" "k8s_etcd" {
  image_name 			= "Container-Linux"
  name       			= "k8s-etcd"
  flavor_name			= "m1.small"
  config_drive    = "true"
  user_data       = "${file("${path.module}/00-etcd.yaml")}"
  key_pair        = "${openstack_compute_keypair_v2.keypair.name}"
  security_groups = [
    "${openstack_compute_secgroup_v2.internal_security.name}",
    "${openstack_compute_secgroup_v2.etcd_external.name}",
    "default"
  ]
  network {
    name           = "default"
    access_network = "true"
  }
  network {
    uuid        = "${openstack_networking_network_v2.primary_network.id}"
    fixed_ip_v4 = "${var.k8s_etcd_ip}"
  }
    # Generate the Certificate Authority
    provisioner "local-exec" {
        command = "${path.module}/cfssl/generate_ca.sh"
    }
    # Generate k8s-etcd server certificate
    provisioner "local-exec" {
        command = "${path.module}/cfssl/generate_server.sh k8s_etcd ${openstack_compute_instance_v2.k8s_etcd.network.1.fixed_ip_v4}"
    }
    # Provision k8s_etcd server certificate
    provisioner "file" {
        source = "./secrets/ca.pem"
        destination = "/home/core/ca.pem"
        connection {
            type = "ssh",
            host = "${openstack_compute_instance_v2.k8s_etcd.access_ip_v6}"
            user = "core",
            private_key = "${file(var.ssh_private_key)}"
        }
    }
    provisioner "file" {
      source = "./secrets/k8s_etcd.pem"
      destination = "/home/core/etcd.pem"
      connection {
        type = "ssh",
        host = "${openstack_compute_instance_v2.k8s_etcd.access_ip_v6}"
        user = "core",
        private_key = "${file(var.ssh_private_key)}"
      }
    }
    provisioner "file" {
      source = "./secrets/k8s_etcd-key.pem"
      destination = "/home/core/etcd-key.pem"
      connection {
        host = "${openstack_compute_instance_v2.k8s_etcd.access_ip_v6}"
        type = "ssh",
        user = "core",
        private_key = "${file(var.ssh_private_key)}"
      }
    }
}

# master host's user data template
##################################
data "template_file" "master_yaml" {
  template =  "${file("${path.module}/01-master.yaml")}"
  vars {
    DNS_SERVICE_IP = "10.3.0.10"
    ETCD_IP = "${openstack_compute_instance_v2.k8s_etcd.network.1.fixed_ip_v4}"
    POD_NETWORK = "10.2.0.0/16"
    SERVICE_IP_RANGE = "10.3.0.0/24"
    HYPERKUBE_VERSION = "${var.hyperkube_version}"
  }
}

# master host
#############
resource "openstack_compute_instance_v2" "k8s_master" {
  name            = "k8s-master"
  image_name      = "Container-Linux"
  flavor_name     = "m1.small"
  key_pair        = "${openstack_compute_keypair_v2.keypair.name}"
  security_groups = [
    "${openstack_compute_secgroup_v2.internal_security.name}",
    "default"
  ]
  config_drive    = "true"
  user_data       = "${data.template_file.master_yaml.rendered}"
  network {
    name          = "default"
    access_network = "true"
  }
  network {
    uuid          = "${openstack_networking_network_v2.primary_network.id}"
    fixed_ip_v4   = "${var.k8s_master_ip}"
  }
  # Generate k8s_master server certificate
  provisioner "local-exec" {
    command       = <<EOF
     ${path.module}/cfssl/generate_server.sh k8s_master "${openstack_networking_floatingip_v2.k8s_master_fip.address},${openstack_compute_instance_v2.k8s_master.network.1.fixed_ip_v4},10.3.0.1,kubernetes.default,kubernetes"
EOF
  }
  # Provision k8s_etcd server certificate
  provisioner "file" {
    source        = "./secrets/ca.pem"
    destination   = "/home/core/ca.pem"
      connection {
        type      = "ssh",
        host      = "${openstack_compute_instance_v2.k8s_master.access_ip_v6}"
        user      = "core",
        private_key = "${file(var.ssh_private_key)}"
      }
   }
   provisioner "file" {
     source = "./secrets/k8s_master.pem"
     destination = "/home/core/apiserver.pem"
     connection {
       type = "ssh",
       host = "${openstack_compute_instance_v2.k8s_master.access_ip_v6}"
       user = "core",
       private_key = "${file(var.ssh_private_key)}"
     }
   }
   provisioner "file" {
     source = "./secrets/k8s_master-key.pem"
     destination = "/home/core/apiserver-key.pem"
     connection {
       type = "ssh",
       host = "${openstack_compute_instance_v2.k8s_master.access_ip_v6}"
       user = "core",
       private_key = "${file(var.ssh_private_key)}"
     }
  }
  # Generate k8s_master client certificate
    provisioner "local-exec" {
      command = "${path.module}/cfssl/generate_client.sh k8s_master"
EOF
    }
  # Provision k8s_master client certificate
  provisioner "file" {
    source = "./secrets/client-k8s_master.pem"
    destination = "/home/core/client.pem"
    connection {
      type = "ssh",
       host = "${openstack_compute_instance_v2.k8s_master.access_ip_v6}"
      user = "core",
      private_key = "${file(var.ssh_private_key)}"
    }
  }
  provisioner "file" {
    source = "./secrets/client-k8s_master-key.pem"
    destination = "/home/core/client-key.pem"
    connection {
        type = "ssh",
        host = "${openstack_compute_instance_v2.k8s_master.access_ip_v6}"
        user = "core",
        private_key = "${file(var.ssh_private_key)}"
    }
  }
  # TODO: figure out permissions and chown, chmod key.pem files
  provisioner "remote-exec" {
      inline = [
          "sudo mkdir -p /etc/kubernetes/ssl",
          "sudo cp /home/core/{ca,apiserver,apiserver-key,client,client-key}.pem /etc/kubernetes/ssl/.",
          "rm /home/core/{apiserver,apiserver-key}.pem",
          "sudo mkdir -p /etc/ssl/etcd",
          "sudo mv /home/core/{ca,client,client-key}.pem /etc/ssl/etcd/."
      ]
      connection {
          type = "ssh",
          host = "${openstack_compute_instance_v2.k8s_master.access_ip_v6}"
          user = "core",
          private_key = "${file(var.ssh_private_key)}"
      }
  }
  # Start kubelet and create kube-system namespace
  provisioner "remote-exec" {
      inline = [
          "sudo systemctl daemon-reload",
          "curl --cacert /etc/kubernetes/ssl/ca.pem --cert /etc/kubernetes/ssl/client.pem --key /etc/kubernetes/ssl/client-key.pem -X PUT -d 'value={\"Network\":\"10.2.0.0/16\",\"Backend\":{\"Type\":\"vxlan\"}}' https://${openstack_compute_instance_v2.k8s_etcd.network.1.fixed_ip_v4}:2379/v2/keys/coreos.com/network/config",
          "sudo systemctl start flanneld",
          "sudo systemctl enable flanneld",
          "sudo systemctl start kubelet",
          "sudo systemctl enable kubelet"
      ]
      connection {
          type = "ssh",
          host = "${openstack_compute_instance_v2.k8s_master.access_ip_v6}"
          user = "core",
          private_key = "${file(var.ssh_private_key)}"
      }
  }
}
resource "openstack_networking_floatingip_v2" "k8s_master_fip" {
  pool = "public"
}
resource "openstack_compute_floatingip_associate_v2" "k8s_master_fip" {
  floating_ip = "${openstack_networking_floatingip_v2.k8s_master_fip.address}"
  instance_id = "${openstack_compute_instance_v2.k8s_master.id}"
  fixed_ip    = "${openstack_compute_instance_v2.k8s_master.network.0.fixed_ip_v4}"
}

# worker host's user data template
##################################
data "template_file" "worker_yaml" {
  template = "${file("${path.module}/02-worker.yaml")}"
  vars {
    DNS_SERVICE_IP = "10.3.0.10"
    ETCD_IP = "${openstack_compute_instance_v2.k8s_etcd.network.1.fixed_ip_v4}"
    MASTER_HOST = "${openstack_compute_instance_v2.k8s_master.network.1.fixed_ip_v4}"
    HYPERKUBE_VERSION = "${var.hyperkube_version}"
  }
}

# worker hosts
##############
resource "openstack_compute_instance_v2" "k8s_worker" {
  depends_on = [
    "openstack_compute_instance_v2.k8s_etcd",
    "openstack_compute_instance_v2.k8s_master",
  ]
  count = "${var.number_of_workers}"
  name = "${format("k8s-worker-%02d", count.index + 1)}"
  image_name = "Container-Linux"
  flavor_name = "m1.small"
  key_pair = "${openstack_compute_keypair_v2.keypair.name}"
  security_groups = [
    "${openstack_compute_secgroup_v2.internal_security.name}",
    "default"
  ]
  config_drive = "true"
  user_data = "${data.template_file.worker_yaml.rendered}"
 # network {
 #   name = "default"
 #   access_network = "true"
 # }
  network {
    uuid = "${openstack_networking_network_v2.primary_network.id}"
  }
  # Generate k8s_worker client certificate
  provisioner "local-exec" {
    command = "${path.module}/cfssl/generate_client.sh k8s_worker"
  }
  # Provision k8s_master client certificate
  provisioner "file" {
    source = "./secrets/ca.pem"
    destination = "/home/core/ca.pem"
    connection {
        type = "ssh",
       # host = "${format("openstack_compute_instance_v2.k8s_worker.%01d.access_ip_v6", count.index)}"
       # user = "core",
       # private_key = "${file(var.ssh_private_key)}"
      bastion_host = "${openstack_compute_instance_v2.k8s_master_fip.address}"
      bastion_user = "core"
      bastion_private_key = "${file(var.ssh_private_key)}"
    }
  }
  provisioner "file" {
    source = "./secrets/client-k8s_worker.pem"
    destination = "/home/core/worker.pem"
    connection {
        type = "ssh",
       # host = "${format("openstack_compute_instance_v2.k8s_worker.%01d.access_ip_v6", count.index)}"
       # user = "core",
       # private_key = "${file(var.ssh_private_key)}"
      bastion_host = "${openstack_compute_instance_v2.k8s_master_fip.address}"
      bastion_user = "core"
      bastion_private_key = "${file(var.ssh_private_key)}"
    }
  }
  provisioner "file" {
    source = "./secrets/client-k8s_worker-key.pem"
    destination = "/home/core/worker-key.pem"
    connection {
        type = "ssh",
       # host = "${format("openstack_compute_instance_v2.k8s_worker.%01d.access_ip_v6", count.index)}"
       # user = "core",
       # private_key = "${file(var.ssh_private_key)}"
      bastion_host = "${openstack_compute_instance_v2.k8s_master_fip.address}"
      bastion_user = "core"
      bastion_private_key = "${file(var.ssh_private_key)}"
    }
  }
  # TODO: permissions on these keys
  provisioner "remote-exec" {
    inline = [
       "sudo mkdir -p /etc/kubernetes/ssl",
       "sudo cp /home/core/{ca,worker,worker-key}.pem /etc/kubernetes/ssl/.",
       "sudo mkdir -p /etc/ssl/etcd/",
       "sudo mv /home/core/{ca,worker,worker-key}.pem /etc/ssl/etcd/."
    ]
    connection {
      type = "ssh",
       # host = "${format("openstack_compute_instance_v2.k8s_worker.%01d.access_ip_v6", count.index)}"
       # user = "core",
       # private_key = "${file(var.ssh_private_key)}"
      bastion_host = "${openstack_compute_instance_v2.k8s_master_fip.address}"
      bastion_user = "core"
      bastion_private_key = "${file(var.ssh_private_key)}"
    }
  }
   # Start kubelet
   provisioner "remote-exec" {
       inline = [
           "sudo systemctl daemon-reload",
           "sudo systemctl start flanneld",
           "sudo systemctl enable flanneld",
           "sudo systemctl start kubelet",
           "sudo systemctl enable kubelet"
       ]
       connection {
           type = "ssh",
       # host = "${format("openstack_compute_instance_v2.k8s_worker.%01d.access_ip_v6", count.index)}"
       # user = "core",
       # private_key = "${file(var.ssh_private_key)}"
      bastion_host = "${openstack_compute_instance_v2.k8s_master_fip.address}"
      bastion_user = "core"
      bastion_private_key = "${file(var.ssh_private_key)}"
       }
   }
}

# make config file and export variables for kubectl
###################################################
resource "null_resource" "make_admin_key" {
    depends_on = ["openstack_compute_instance_v2.k8s_worker"]
    provisioner "local-exec" {
        command = "${path.module}/cfssl/generate_admin.sh"
    }
}
resource "null_resource" "setup_kubectl" {
    depends_on = ["null_resource.make_admin_key"]
    provisioner "local-exec" {
        command = <<EOF
            echo export MASTER_HOST=${openstack_networking_floatingip_v2.k8s_master_fip.address} > $PWD/secrets/setup_kubectl.sh
            echo export CA_CERT=$PWD/secrets/ca.pem >> $PWD/secrets/setup_kubectl.sh
            echo export ADMIN_KEY=$PWD/secrets/admin-key.pem >> $PWD/secrets/setup_kubectl.sh
            echo export ADMIN_CERT=$PWD/secrets/admin.pem >> $PWD/secrets/setup_kubectl.sh
            . $PWD/secrets/setup_kubectl.sh
            kubectl config set-cluster default-cluster \
                --server=https://$MASTER_HOST --certificate-authority=$CA_CERT
            kubectl config set-credentials default-admin \
                 --certificate-authority=$CA_CERT --client-key=$ADMIN_KEY --client-certificate=$ADMIN_CERT
            kubectl config set-context default-system --cluster=default-cluster --user=default-admin
            kubectl config use-context default-system
EOF
    }
}
resource "null_resource" "deploy_dns_addon" {
    depends_on = ["null_resource.setup_kubectl"]
    provisioner "local-exec" {
        command = <<EOF
            until kubectl get pods 2>/dev/null; do printf '.'; sleep 5; done
            kubectl create -f ${path.module}/03-dns-addon.yaml
EOF
    }
}
