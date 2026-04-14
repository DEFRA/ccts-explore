$ErrorActionPreference = "Stop"

param(
  [string]$Namespace = "ingress-nginx",
  [string]$SubnetName = "TODO: SUBNET NAME"
)

kubectl get ns $Namespace *> $null 2>&1
if ($LASTEXITCODE -ne 0) { kubectl create ns $Namespace | Out-Null }

@"
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ingress-nginx
  namespace: $Namespace
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ingress-nginx
rules:
  - apiGroups: [""]
    resources: ["configmaps","endpoints","nodes","pods","secrets","services","namespaces"]
    verbs: ["get","list","watch"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses","ingresses/status","ingressclasses"]
    verbs: ["get","list","watch","update"]
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    verbs: ["get","list","watch","create","update","patch"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create","patch"]
  - apiGroups: ["discovery.k8s.io"]
    resources: ["endpointslices"]
    verbs: ["get","list","watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ingress-nginx
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: ingress-nginx
subjects:
  - kind: ServiceAccount
    name: ingress-nginx
    namespace: $Namespace
---
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: nginx
spec:
  controller: k8s.io/ingress-nginx
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ingress-nginx-controller
  namespace: $Namespace
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ingress-nginx
  template:
    metadata:
      labels:
        app: ingress-nginx
    spec:
      serviceAccountName: ingress-nginx
      containers:
        - name: controller
          image: registry.k8s.io/ingress-nginx/controller:v1.11.2
          args:
            - /nginx-ingress-controller
            - --ingress-class=nginx
            - --controller-class=k8s.io/ingress-nginx
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
          ports:
            - name: http
              containerPort: 80
            - name: https
              containerPort: 443
---
apiVersion: v1
kind: Service
metadata:
  name: ingress-nginx-controller
  namespace: $Namespace
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-internal: "true"
    service.beta.kubernetes.io/azure-load-balancer-internal-subnet: "$SubnetName"
spec:
  type: LoadBalancer
  selector:
    app: ingress-nginx
  ports:
    - name: http
      port: 80
      targetPort: http
    - name: https
      port: 443
      targetPort: https
"@ | kubectl apply -f -

kubectl -n $Namespace rollout status deploy/ingress-nginx-controller
kubectl -n $Namespace get svc ingress-nginx-controller -o wide

Write-Host "If EXTERNAL-IP is pending, check subnet RBAC on AKS managed identity."
