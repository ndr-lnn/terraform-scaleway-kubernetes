# Basic Example

Deploys a minimal Kubernetes cluster on Scaleway with 1 control plane + 2 workers.

## Usage

```bash
export SCW_ACCESS_KEY="your-access-key"
export SCW_SECRET_KEY="your-secret-key"

terraform init
terraform apply -var="scaleway_project_id=your-project-uuid" \
                -var="scaleway_access_key=$SCW_ACCESS_KEY" \
                -var="scaleway_secret_key=$SCW_SECRET_KEY"

# Access the cluster
terraform output -raw kubeconfig > kubeconfig
terraform output -raw talosconfig > talosconfig
export KUBECONFIG=kubeconfig
export TALOSCONFIG=talosconfig
kubectl get nodes
```
