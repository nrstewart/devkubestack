# Kubernetes - OpenStack - Terraform

Deploy your Kubernetes cluster on OpenStack using Terraform.

### On Mac

With brew installed, all tools can be installed with

```bash
brew install terraform cfssl kubectl
```

Do all the following steps from a development machine. It does not matter _where_ is it, as long as it is connected to the internet. This one will be subsequently used to access the cluster via `kubectl`.

## Generate private / public keys

```
ssh-keygen -t rsa -b 4096
```

The system will prompt you for a file path to save the key, we will go with `secrets/id_rsa`

## Invoke Terraform

We put our OpenStack credentials in `provisioner.tf` (this directory is in `.gitignore`, of course, so we don't leak it)

After setup, call `terraform apply`

```bash
terraform apply
```

That should do! `kubectl` is configured, so you can just check the nodes (`get no`) and the pods (`get po`).

```bash
$ kubectl get no
NAME          LABELS                               STATUS
X.X.X.X   kubernetes.io/hostname=X.X.X.X   Ready     2m
Y.Y.Y.Y   kubernetes.io/hostname=Y.Y.Y.Y   Ready     2m

$ kubectl --namespace=kube-system get po
NAME                                   READY     STATUS    RESTARTS   AGE
kube-apiserver-X.X.X.X                    1/1       Running   0          13m
kube-controller-manager-X.X.X.X           1/1       Running   0          12m
kube-proxy-X.X.X.X                        1/1       Running   0          12m
kube-proxy-X.X.X.X                        1/1       Running   0          11m
kube-proxy-X.X.X.X                        1/1       Running   0          12m
kube-scheduler-X.X.X.X                    1/1       Running   0          13m
```

You are good to go. Now, we can keep on reading to dive into the specifics.

## Deploy details

These scripts are mostly taken from the [CoreOS + Kubernetes Step by Step](https://coreos.com/kubernetes/docs/latest/getting-started.html) guide, with the addition of SSL/TLS and client certificate authentication for etcd2.

Certificate generation is covered in more detail by CoreOS's [Generate self-signed certificates](https://coreos.com/os/docs/latest/generate-self-signed-certificates.html) documentation.

These resources are excellent starting places for more in-depth documentation. Below is an overview of the cluster.

### K8s etcd

A dedicated host running a TLS secured + authenticated etcd2 instance for Kubernetes.

#### Cloud config

See the template `00-etcd.yaml`.

### K8s master

The cluster master, running:

* flanneld
* kubelet
* kube-proxy
* kube-apiserver
* kube-controller-manager
* kube-scheduler

#### Cloud config

See the template `01-master.yaml`.

#### Provisions

Once we create this droplet (and get its `IP`), the TLS assets will be created locally (i.e. on the development machine from which we run `terraform`), and put into the directory `secrets` (which, again, is mentioned in `.gitignore`). The TLS assets consist of a server key and certificate for the API server, as well as a client key and certificate to authenticate flanneld and the API server to etcd2.

The TLS assets are copied to appropriate directories on the K8s master using Terraform `file` and `remote-exec` provisioners.

Lastly, we start and enable both `kubelet` and `flanneld`, and finally create the `kube-system` namespace.

### K8s workers

Cluster worker nodes, each running:

* flanneld
* kubelet
* kube-proxy
* docker

#### Cloud config

See the template `02-worker.yaml`.

#### Provisions

For each droplet created, a TLS client key and certificate will be created locally (i.e. on the development machine from which we run `terraform`), and put into the directory `secrets` (which, again, is mentioned in `.gitignore`).

The TLS assets are then copied to appropriate directories on the worker using Terraform `file` and `remote-exec` provisioners.

Finally, we start and enable `kubelet` and `flanneld`.

### Setup `kubectl`

After the installation is complete, `terraform` will configure `kubectl` for you. The environment variables will be stored in the file `secrets/setup_kubectl.sh`.

Test your brand new cluster

```bash
kubectl get nodes
```

You should get something similar to

```
$ kubectl get nodes
NAME          LABELS                               STATUS
X.X.X.X       kubernetes.io/hostname=X.X.X.X       Ready
```
