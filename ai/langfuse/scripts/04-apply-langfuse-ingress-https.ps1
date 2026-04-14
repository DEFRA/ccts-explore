$ErrorActionPreference = "Stop"

param(
  [string]$Namespace = "langfuse",
  [string]$IngressName = "langfuse-ip",
  [string]$ServiceName = "langfuse-web",
  [int]$ServicePort = 3000,
  [string]$TlsSecretName = "langfuse-tls"
)

@"
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: $IngressName
  namespace: $Namespace
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
  - secretName: $TlsSecretName
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: $ServiceName
            port:
              number: $ServicePort
"@ | kubectl apply -f -

kubectl -n $Namespace get ingress $IngressName -o wide

Write-Host "If using raw IP over HTTPS, browser certificate warning is expected."
