# Backend: Azure Container Apps

Deploy the backend to Azure for a persistent, publicly accessible endpoint with HTTPS and WebSocket support.

---

## Prerequisites

- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) installed
- An Azure subscription

---

## 1. Create Resource Group + Container Registry

```bash
az login
az group create -n corereader-rg -l westeurope
az acr create -n <acrName> -g corereader-rg --sku Basic
```

Get the registry login server:

```bash
az acr show -n <acrName> -g corereader-rg --query loginServer -o tsv
```

---

## 2. Build and Push Image

Build directly in Azure (no local Docker needed):

```bash
az acr build -r <acrName> -t corereader-backend:v1 -f backend/Dockerfile backend
```

The image tag will be: `<loginServer>/corereader-backend:v1`

---

## 3. Deploy Container App

```bash
az extension add --name containerapp --upgrade
az containerapp env create -g corereader-rg -n corereader-env -l westeurope

loginServer=$(az acr show -n <acrName> -g corereader-rg --query loginServer -o tsv)

az containerapp create \
  -g corereader-rg \
  -n corereader-backend \
  --environment corereader-env \
  --image "$loginServer/corereader-backend:v1" \
  --ingress external \
  --target-port 8000 \
  --registry-server "$loginServer"
```

---

## 4. Get Your URL

```bash
fqdn=$(az containerapp show -g corereader-rg -n corereader-backend \
  --query properties.configuration.ingress.fqdn -o tsv)
echo "wss://$fqdn"
```

In the Flutter app → **Settings** → **WebSocket base URL**:

```
wss://<fqdn>
```

---

## Notes

- First startup downloads models (~300 MB); allow extra time for the initial boot.
- Azure Container Apps supports WebSocket connections natively.
- If you change regions or names, use the commands above to retrieve the exact values.

---

[← Back to README](../README.md)
