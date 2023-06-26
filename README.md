<p align="center">
  <img src="assets/logo-classicblue-800px.png?raw=true" alt="Intel Logo" width="250"/>
</p>

# Intel® Cloud Optimization Modules for Kubeflow 

© Copyright 2023, Intel Corporation
## Microsoft Azure

The Intel® Cloud Optimization Modules for Kubeflow* provide a reference solution for 
building and deploying accelerated AI applications on Kubeflow. The modules are 
designed to maximize the performance and productivity of industry-leading Python machine 
learning libraries. This set of reference architectures for Microsoft Azure also take 
advantage of secure and confidential computing virtual machines leveraging Intel® Software 
Guard Extensions (Intel® SGX) on the Azure cloud. 

Each module or reference architecture includes a complete instruction set, all source 
code published on GitHub*, and a video walk-through. Below are the Kubeflow Pipelines available 
for Microsoft Azure. You can check out the full suite of Intel Cloud Optimization Modules with 
additional resources for other cloud providers like AWS and GCP
[here](https://www.intel.com/content/www/us/en/developer/topic-technology/cloud-optimization.html). 

## Table of Contents

- [Kubeflow Pipelines](#kubeflow-pipelines)
- [Prerequisites](#prerequisites)
- [Install Kubeflow on Azure](#installing-kubeflow-on-azure)
- [Next Steps](#next-steps)

## Kubeflow Pipelines

- **[Loan Default Risk Prediction](pipelines/XGBoost/README.md)**: This reference solution provides an optimized
training and inference architecture of an AI model using XGBoost to predict the probability of a 
loan default from client characteristics and the type of loan obligation. This module enables the use 
of Intel® optimizations for XGBoost and Intel® daal4py.

## Prerequisites

This set of reference solutions assumes you have a [Microsoft Azure](https://azure.microsoft.com/en-ca) 
account. While Azure is used for the infrastructure set up, the lessons learned in this module can 
be applied to other cloud platforms. 

Before getting started, download and install the required versions of the dependencies 
below for your operating system:

1. **[Microsoft Azure CLI](https://learn.microsoft.com/en-us/cli/azure/)** v2.46.0 or above.  
    To find your installation version, run:
    ```
    az --version
    ```
2. **[`kubectl`](https://kubectl.docs.kubernetes.io/installation/kubectl/)** v1.25 or above.  
    To find the client version of your installation, run:
    ```
    kubectl version --client -o yaml
    ```
3. **[`kustomize`](https://kubectl.docs.kubernetes.io/installation/kustomize/)** v5.0.0 or above.  
    To find your installation version, run:
    ```
    kustomize version -o yaml
    ```

[Back to Table of Contents](#table-of-contents)

## Installing Kubeflow on Azure

Once you've set up the Azure resources for your [Pipeline](#kubeflow-pipelines),
follow the instructions below to install Kubeflow.

> **Note**: This installation guide corresponds to Kubeflow version 1.7.0.

To install Kubeflow on Azure, first clone the [Kubeflow manifests repository](https://github.com/kubeflow/manifests).

```
git clone https://github.com/kubeflow/manifests.git
```

Change directory into the newly cloned `manifests` directory.
```
cd manifests
```

### I. *Optional*: Create a unique password

Use the following command to create a unique password for Kubeflow and hash it using `bcrypt`. 

```
python3 -c 'from passlib.hash import bcrypt; import getpass; print(bcrypt.using(rounds=12, ident="2y").hash(getpass.getpass()))'
``` 

Navigate to the `common/dex/base/config-map.yaml` and copy the newly generated password 
in the `hash` value of the configuration file at around line 22.

```
    staticPasswords:
    - email: user@example.com
      hash:
```

### II. Modify the Istio Ingress Gateway service from ClusterIP to Load Balancer

> [Istio](https://istio.io/) is used by many Kubeflow components to secure their 
> traffic, enforce network authorization and implement routing policies.

Navigate to `common/istio-1-16/istio-install/base/patches/service.yaml` and change 
the `type` to `LoadBalancer` at around line 7.

```
apiVersion: v1
kind: Service
metadata:
  name: istio-ingressgateway
  namespace: istio-system
spec:
  type: LoadBalancer
```

### III. Disable the AKS admission enforcer from the Istio mutating admission webhook

Navigate to `common/istio-1-16/istio-install/base/install.yaml` and add the following 
annotation at around line 2694.

```
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  name: istio-sidecar-injector
  annotations:
    admissions.enforcer/disabled: 'true'
  labels:
    istio.io/rev: default
```

### IV. Configure the Transport Layer Security (TLS) Protocol

Next, we will update the Istio Gateway so that we can access the dashboard over HTTPS.
Navigate to `common/istio-1-16/kubeflow-istio-resources/base/kf-istio-resources.yaml`. 
At the end of the file, at around line 14, paste the following:

```
    tls:
      httpsRedirect: true
  - port:
      number: 443
      name: https
      protocol: HTTPS
    hosts:
    - "*"
    tls:
      mode: SIMPLE
      privateKey: /etc/istio/ingressgateway-certs/tls.key
      serverCertificate: /etc/istio/ingressgateway-certs/tls.crt
```

The `kf-istio-resources.yaml` file should now look like:

```
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: kubeflow-gateway
spec:
  selector:
    istio: ingressgateway
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "*"
    tls:
      httpsRedirect: true
  - port:
      number: 443
      name: https
      protocol: HTTPS
    hosts:
    - "*"
    tls:
      mode: SIMPLE
      privateKey: /etc/istio/ingressgateway-certs/tls.key
      serverCertificate: /etc/istio/ingressgateway-certs/tls.crt
```

### V. Install the Kubeflow components with a single command

```
while ! kustomize build example | awk '!/well-defined/' | kubectl apply -f -; do echo "Retrying to apply resources"; sleep 10; done
```

> **Note**: This may take several minutes for all components to be installed and some may fail 
> on the first try. This is inherent to how Kubernetes and kubectl work (e.g., CR must be created 
> after CRD becomes ready). The solution is to simply re-run the command until it succeeds.

### VI. Verify that Kubeflow was installed successfully

Check that all of the pods in the following namespaces are running:

```
kubectl get pods -n cert-manager
kubectl get pods -n istio-system
kubectl get pods -n auth
kubectl get pods -n knative-eventing
kubectl get pods -n knative-serving
kubectl get pods -n kubeflow
kubectl get pods -n kubeflow-user-example-com
```

*Optional*: If you created a new password for Kubeflow in [Step I](#i-optional-create-a-unique-password),
restart the `dex` pod to ensure it is using the updated password.

```
kubectl rollout restart deployment dex -n auth
```

### VII. Create a self-signed TLS certificate

Get the external IP address of the Istio Ingress Gateway:
```
kubectl get svc -n istio-system
```

Your output should look similar to:
```
NAME                    TYPE           CLUSTER-IP     EXTERNAL-IP     PORT(S)                                                                      AGE
authservice             ClusterIP      10.0.213.1     <none>          8080/TCP                                                                     11d
cluster-local-gateway   ClusterIP      10.0.114.183   <none>          15020/TCP,80/TCP                                                             11d
istio-ingressgateway    LoadBalancer   10.0.10.240    20.00.000.000   15021:30141/TCP,80:31633/TCP,443:32222/TCP,31400:32526/TCP,15443:30807/TCP   11d
```

Create a self-signed certificate:
```
nano certificate.yaml 
```

Paste the following contents into the `certificate.yaml`:
```
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: istio-ingressgateway-certs
  namespace: istio-system
spec:
  secretName: istio-ingressgateway-certs
  ipAddresses:
    - <enter your istio IP address here>
  isCA: true
  issuerRef:
    name: kubeflow-self-signing-issuer
    kind: ClusterIssuer
    group: cert-manager.io  
```

Apply the certificate:
```
kubectl apply -f certificate.yaml -n istio-system
```

Verify the certificate was created successfully:
```
kubectl get certificate -n istio-system
```

Your output should look similar to:

```
NAME                         READY   SECRET                       AGE
istio-ingressgateway-certs   True    istio-ingressgateway-certs   33s
```

## Next Steps

Once you've finished installing Kubeflow on Azure, continue following the instructions 
for the [Pipeline](#kubeflow-pipelines) you are running.

[Back to Table of Contents](#table-of-contents)