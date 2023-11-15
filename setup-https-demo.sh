#!/bin/sh

NAMESPACE=ampint
DOMAIN=routing.example.com

openssl req -x509 -sha256 -nodes -days 365 -newkey rsa:2048 -subj '/O=example Inc./CN=example.com' -keyout example.com.key -out example.com.crt

openssl req -out $DOMAIN.csr -newkey rsa:2048 -nodes -keyout $DOMAIN.key -subj "/CN=$DOMAIN/O=some organization"
openssl x509 -req -sha256 -days 365 -CA example.com.crt -CAkey example.com.key -set_serial 0 -in $DOMAIN.csr -out $DOMAIN.crt

kubectl -n $NAMESPACE delete secret server-certs
kubectl -n $NAMESPACE create secret tls server-certs --key=$DOMAIN.key --cert=$DOMAIN.crt

cat << EOF | kubectl apply -n $NAMESPACE -f -
apiVersion: v1
kind: Service
metadata:
  name: routing-echoserver
  labels:
    run: routing-echoserver
spec:
  ports:
    - port: 8080
      targetPort: 3000
      protocol: TCP
  selector:
    run: routing-echoserver
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: routing-echoserver
spec:
  selector:
    matchLabels:
      run: routing-echoserver
  replicas: 3
  template:
    metadata:
      labels:
        run: routing-echoserver
    spec:
      containers:
        - name: routing-echoserver
          image: gcr.io/k8s-staging-ingressconformance/echoserver:v20221109-7ee2f3e
          ports:
            - containerPort: 8080
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: routing-gateway
spec:
  gatewayClassName: ampint-gateway
  listeners:
    - name: routing-https
      protocol: HTTPS
      port: 443
      hostname: $DOMAIN
      tls:
        mode: Terminate
        certificateRefs:
          - group: ""
            kind: Secret
            name: server-certs
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: routing-https
spec:
  parentRefs:
    - name: routing-gateway
      sectionName: routing-https
  rules:
    - backendRefs:
        - group: ""
          kind: Service
          name: routing-echoserver
          port: 8080
          weight: 1
---
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: routing-https-hash
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: routing-https
  loadBalancer:
    type: ConsistentHash
    consistentHash:
      type: SourceIP
EOF

sleep 5



ENVOY_SERVICE=$(kubectl get svc -n envoy-gateway-system --selector=gateway.envoyproxy.io/owning-gateway-namespace=$NAMESPACE,gateway.envoyproxy.io/owning-gateway-name=routing-gateway -o jsonpath='{.items[0].metadata.name}')
GATEWAY_IP=$(kubectl get svc/${ENVOY_SERVICE} -n envoy-gateway-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

echo Set /etc/hosts with:
echo $DOMAIN: $GATEWAY_IP
sudo sed -i "/$DOMAIN/d" /etc/hosts
sudo sh -c "echo $GATEWAY_IP $DOMAIN >> /etc/hosts"

echo "=== curl -ik https://routing.example.com/get ==="
curl -ik https://routing.example.com/get
echo "================================================="