#!/bin/sh

NAMESPACE=ampint
DOMAIN=routing.example.com

openssl req -x509 -sha256 -nodes -days 365 -newkey rsa:2048 -subj '/O=example Inc./CN=example.com' -keyout example.com.key -out example.com.crt

openssl req -out $DOMAIN.csr -newkey rsa:2048 -nodes -keyout $DOMAIN.key -subj "/CN=$DOMAIN/O=some organization"
openssl x509 -req -sha256 -days 365 -CA example.com.crt -CAkey example.com.key -set_serial 0 -in $DOMAIN.csr -out $DOMAIN.crt

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
    - port: 443
      targetPort: 8443
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
            - containerPort: 8443
          env:
            - name: HTTPS_PORT
              value: "8443"
            - name: TLS_SERVER_CERT
              value: /etc/server-certs/tls.crt
            - name: TLS_SERVER_PRIVKEY
              value: /etc/server-certs/tls.key
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
          volumeMounts:
            - name: server-certs
              mountPath: /etc/server-certs
              readOnly: true
      volumes:
        - name: server-certs
          secret:
            secretName: server-certs
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: routing-gateway
spec:
  gatewayClassName: ampint-gateway
  listeners:
    - name: routing-tls
      protocol: TLS
      port: 443
      hostname: $DOMAIN
      tls:
        mode: Passthrough
---
apiVersion: gateway.networking.k8s.io/v1alpha2
kind: TLSRoute
metadata:
  name: tlsroute
spec:
  parentRefs:
    - name: routing-gateway
      sectionName: routing-tls
  hostnames:
    - $DOMAIN
  rules:
    - backendRefs:
        - group: ""
          kind: Service
          name: routing-echoserver
          port: 443
          weight: 1
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