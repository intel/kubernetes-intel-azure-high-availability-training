<p align="center">
  <img src="../assets/logo-classicblue-800px.png?raw=true" alt="Intel Logo" width="250"/>
</p>

# Intel® Cloud Optimization Modules for Kubeflow 

© Copyright 2023, Intel Corporation
## Microsoft Azure

The Intel® Cloud Optimization Module for Kubeflow* is designed to facilitate building 
and deploying accelerated AI applications on the Azure cloud. In this module, we will 
demonstrate how to build a machine learning pipeline with Kubeflow using 
[Intel® optimizations for XGBoost](https://www.intel.com/content/www/us/en/developer/tools/oneapi/optimization-for-xgboost.html) 
and [Intel® oneDAL](https://www.intel.com/content/www/us/en/developer/tools/oneapi/onedal.html) 
to accelerate model training and inference. 

## Table of Contents
- [Solution Overview](#solution-overview)
- [Prerequisites](#prerequisites)
- [Setting up Azure Resources](#setting-up-azure-resources)
- [Installing Kubeflow](#install-kubeflow)
- [Setting up Kubernetes Resources](#setting-up-kubernetes-resources)
- [Running the Kubeflow Pipeline](#running-the-kubeflow-pipeline)
- [Cleaning up Resources](#cleaning-up-resources)

## Solution Overview

The Kubeflow pipeline we will be deploying is based on the 
[Loan Default Risk Prediction AI Reference Kit](https://github.com/oneapi-src/loan-default-risk-prediction).
Below is a graph of the full pipeline.
<p align="center">
  <img src="../assets/intel-xgb-d4p-pipeline.png" alt="Intel XGBoost Daal4py Pipeline" width="1100"/>
</p>

The pipeline consists of 7 components. A detailed description of each one is listed below:  
- **Load data**: This component loads the `credit_risk_dataset.csv` from the Azure 
file share and performs synthetic data augmentation.  
- **Create training and test sets**: This component splits the data into training and test 
sets, of an approximately 75:25 split for model evaluation.  
- **Preprocess features**: This component creates a data processing pipeline to
preprocess the training and test features for the XGBoost model.  
- **Train XGBoost model**: This component trains an XGBoost model, or continues training 
the model if selected, and stores the model in the Azure file share.  
- **Convert XGBoost model to Daal4py**: This component converts the XGBoost model to an
inference-optimized daal4py classifier.  
- **Daal4py Inference**:  This component computes predictions using the inference-optimized 
daal4py classifier and evaluates model performance. It returns an output summary of the 
precision, recall, F1 score for each class, as well as the area under the curve (AUC) and 
accuracy of the model.  
- **Plot ROC Curve**: This component performs model validation on the test data 
and generates a graph of the ROC curve.  

## Prerequisites

This module assumes you have a [Microsoft Azure](https://azure.microsoft.com/en-ca) account. 
While Azure is used for the infrastructure set up, the lessons learned in this module can 
be applied to other cloud platforms. 

### Install Tools:

Before getting started, download and install the required versions of the dependencies 
below for your operating system:
1. **[Microsoft Azure CLI](https://learn.microsoft.com/en-us/cli/azure/)** v2.46.0 or above.  
    To find your installation version, run:
    ```
    az version
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

## Setting up Azure Resources

### I. Sign in with the Azure CLI
To sign into your account interactively, use:

```
az login
```

### II. Create a Resource Group
We will first create an 
[Azure Resource Group](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/overview#resource-groups) 
to hold all of the related resources for our solution. The command below will create 
a resource group named `intel-aks-kubeflow` in the `westus` region.

```
export RG=intel-aks-kubeflow
export LOC=westus

az group create -n $RG -l $LOC
```

### III. Create a File Share
We will use an [Azure File Share](https://learn.microsoft.com/en-us/azure/storage/files/storage-files-introduction) 
for our pipeline's data and model object storage. To create the file share, we will first create an Azure Storage 
Account named `kubeflowstore` using the following command:

```
export STORAGE_NAME=kubeflowstore

az storage account create \
--resource-group $RG \
--name $STORAGE_NAME \
--kind StorageV2 \
--sku Standard_LRS \
--enable-large-file-share \
--allow-blob-public-access false
```

Next, we will create a new file share in our storage account named 
`kubeflow-file-share` with a quota of 1024 GiB.
```
export KUBEFLOW_FILE_SHARE=kubeflow-file-share

az storage share-rm create \
--resource-group $RG \
--storage-account $STORAGE_NAME \
--name $KUBEFLOW_FILE_SHARE \
--quota 1024
```

To upload the credit risk dataset to the file share, we'll create a new
directory called `data` using the command below.
```
export STORAGE_KEY=$(az storage account keys list -g $RG -n $STORAGE_NAME --query [0].value -o tsv)

az storage directory create \
--account-name $STORAGE_NAME \
--share-name $KUBEFLOW_FILE_SHARE \
--name "data" \
--account-key $STORAGE_KEY 
```

Now we'll upload the `credit_risk_dataset.csv` to the data directory.
> **Note**: The credit risk dataset can be downloaded frome Kaggle 
> [here](https://www.kaggle.com/datasets/laotse/credit-risk-dataset). Before executing 
> the command below, ensure the `credit_risk_dataset.csv`
> is located in your current working directory.
```
az storage file upload \
--account-name $STORAGE_NAME \
--share-name $KUBEFLOW_FILE_SHARE \
--source "credit_risk_dataset.csv" \
--path "data/credit_risk_dataset.csv" \
--account-key $STORAGE_KEY 
```

### IV. Create a Container Registry

We'll now create an 
[Azure Container Registry](https://learn.microsoft.com/en-us/azure/container-registry/container-registry-intro) 
to build, store, and manage the container image for our application. The command below 
will create a new container registry named `kubeflowregistry`.

```
export ACR=kubeflowregistry

az acr create --resource-group $RG \
--name $ACR \
--sku Standard
```

Before pushing and pulling container images, first log in to the registry 
using the command below.

```
az acr login -n $ACR
```

Next, we will build the image needed for the Kubeflow pipeline using the Dockerfile 
provided in this repository and push it to the container registry. We will name our 
image `loan-default-pipeline` with the tag `latest`.

```
az acr build --image loan-default-pipeline:latest --registry $ACR -g $RG --file Dockerfile .
```

Run the following command to verify the application image was successfully 
pushed to the repository:

```
az acr repository show -n $ACR --repository loan-default-pipeline -o table
```

Your output should be similar to:
```
CreatedTime                   ImageName              LastUpdateTime                ManifestCount    Registry                     TagCount
----------------------------  ---------------------  ----------------------------  ---------------  ---------------------------  ----------
2023-04-24T21:03:51.1741697Z  loan-default-pipeline  2023-04-24T21:03:51.2592323Z  1                kubeflowregistry.azurecr.io  1
```

### V. Create the AKS Cluster

Now we're ready to deploy our 
[Azure Kubernetes Service (AKS)](https://learn.microsoft.com/en-us/azure/aks/intro-kubernetes) 
cluster that we will use for Kubeflow with the container registry we 
created in the previous step attached.

```
AKS=aks-kubeflow
 
az aks create --resource-group $RG \
--name $AKS \
--node-vm-size Standard_D4_v5 \
--node-count 3 \
--kubernetes-version 1.25.6 \
--enable-managed-identity \
--generate-ssh-keys -l $LOC \
--attach-acr $ACR
```

Run the following command to log in to the cluster:
```
az aks get-credentials -n $AKS -g $RG
```

Run the following command to verify that the AKS cluster has been created properly:
```
kubectl get nodes
```

Your output should look similar to:
```
NAME                                STATUS   ROLES   AGE   VERSION
aks-nodepool1-13932128-vmss000019   Ready    agent   1h    v1.25.6
aks-nodepool1-13932128-vmss00001a   Ready    agent   1h    v1.25.6
aks-nodepool1-13932128-vmss00001b   Ready    agent   1h    v1.25.6
```

[Back to Table of Contents](#table-of-contents)

## Install Kubeflow

To install Kubeflow on Azure, first clone the [Kubeflow GitHub repo](https://github.com/kubeflow/manifests).

> **Note**: At the time of writing this, the Kubeflow version we have downloaded is 1.7.0.

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

> Istio is used by many Kubeflow components to secure their traffic, enforce
> network authorization and implement routing policies.

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

### IV. Configure TLS

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

### VII. Create a self-signed certificate

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

[Back to Table of Contents](#table-of-contents)

## Setting up Kubernetes Resources
Now that we've installed Kubeflow, we will configure persistent storage for the pipeline using the Azure file share that we created earlier. 

Create a Kubernetes secret containing the Azure storage account name and key.
```
kubectl create secret generic azure-secret \
--from-literal azurestorageaccountname=$STORAGE_NAME \
--from-literal azurestorageaccountkey=$STORAGE_KEY \
--type=Opaque 
```

Change the directory to `kubeflow`.
```
cd ../kubeflow/
```

Create the persistent volume and the persistent volume claim.
```
kubectl create -f kubernetes/pv-azure.yaml
kubectl create -f kubernetes/pvc-azure.yaml
```

[Back to Table of Contents](#table-of-contents)

## Running the Kubeflow Pipeline

### I. Create the Pipeline yaml file

The python code for our pipeline is located in the `src` directory. To generate the yaml file for 
the pipeline, run the following command:

```
python3 kubeflow/src/loan_default_pipeline.py
```

You should see a new file named `intel-xgboost-daal4py-pipeline.yaml` in your main directory.

### II. Log into the Kubeflow Central Dashboard

1.  In your browser, type in the external IP address of the Istio Ingress Gateway. 
    The DEX login screen should appear.
2.  Enter your username and password. The default username for Kubeflow is 
    `user@example.com` and the default password is `12341234`. Use the password created 
    in [Step I](#i-optional-create-a-unique-password) if completed.  

### III. Run the Pipeline
1.  Once you have logged into Kubeflow, click on the Pipelines tab from the sidebar 
    menu.
2.  Click on the Upload Pipeline button in the top right and type in a new name and 
    description for the Pipeline.
3.  Select Upload a file and navigate to the directory where the 
    `intel-xgboost-daal4py-pipeline.yaml` is located. Click Create.
4.  You should be redirected to a graph overview of the pipeline. In the top right,
    select Create run.
5.  In the Run parameters section at the bottom, you can review and update the default 
    values of the pipeline parameters. For this demo, we will use the parameters shown
    in the image below:

<p align="center">
  <img src="../assets/intel-xgb-d4p-pipeline-params.png" alt="Pipeline Params" width="500"/>
</p>

6.  Click Start to begin running the pipeline.  
> **Note**: Don't forget to check out the **Visualization** tab for both the `Daal4py Inference` 
> and `Plot ROC Curve` steps.

[Back to Table of Contents](#table-of-contents)

## Cleaning up Resources

Once you're finished running Kubeflow, you can turn off, or stop, the AKS Cluster by using the following command:
```
az aks stop -n $AKS -g $RG
```

When you're ready to delete all of the resources in the Resource Group, run:
```
az group delete -n $RG --yes --no-wait
```

[Back to Table of Contents](#table-of-contents)