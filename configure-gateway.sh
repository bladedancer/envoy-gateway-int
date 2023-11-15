#!/bin/sh

NAMESPACE=ampint
DOMAIN=dev.example.com

cat << EOF | kubectl apply -n $NAMESPACE -f -
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: ampint-gateway
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ampint-gateway
spec:
  gatewayClassName: ampint-gateway
  listeners:
    - name: apiproxy-tls
      protocol: TLS
      port: 4443
      hostname: $DOMAIN
      tls:
        mode: Passthrough
    - name: integration-tls
      protocol: TLS
      port: 9443
      hostname: $DOMAIN
      tls:
        mode: Passthrough
    - name: integration-http
      protocol: HTTP
      port: 9080
      hostname: $DOMAIN
    - name: webhook-tls
      protocol: TLS
      port: 443
      hostname: $DOMAIN
      tls:
        mode: Passthrough
    - name: sftp-tcp
      protocol: TCP
      port: 9022
---
apiVersion: gateway.networking.k8s.io/v1alpha2
kind: TLSRoute
metadata:
  name: apiproxy-route
spec:
  parentRefs:
    - name: ampint-gateway
      port: 4443
      sectionName: apiproxy-tls
  hostnames:
    - $DOMAIN
  rules:
    - backendRefs:
        - group: ""
          kind: Service
          name: ingress-dev
          port: 4443
          weight: 1
---
apiVersion: gateway.networking.k8s.io/v1alpha2
kind: TLSRoute
metadata:
  name: integration-tls-route
spec:
  parentRefs:
    - name: ampint-gateway
      port: 9443
      sectionName: integration-tls
  hostnames:
    - $DOMAIN
  rules:
    - backendRefs:
        - group: ""
          kind: Service
          name: inbound-worker-dev
          port: 9443
          weight: 1
---
apiVersion: gateway.networking.k8s.io/v1alpha2
kind: TLSRoute
metadata:
  name: webhook-tls-route
spec:
  parentRefs:
    - name: ampint-gateway
      port: 443
      sectionName: webhook-tls
  hostnames:
    - $DOMAIN
  rules:
    - backendRefs:
        - group: ""
          kind: Service
          name: inbound-worker-dev
          port: 8443
          weight: 1
---
apiVersion: gateway.networking.k8s.io/v1alpha2
kind: TCPRoute
metadata:
  name: sftp-route
spec:
  parentRefs:
    - name: ampint-gateway
      port: 9022
      sectionName: sftp-tcp
  rules:
    - backendRefs:
        - group: ""
          kind: Service
          name: inbound-worker-dev
          port: 2222
          weight: 1
EOF



ENVOY_SERVICE=$(kubectl get svc -n envoy-gateway-system --selector=gateway.envoyproxy.io/owning-gateway-namespace=$NAMESPACE,gateway.envoyproxy.io/owning-gateway-name=ampint-gateway -o jsonpath='{.items[0].metadata.name}')
GATEWAY_IP=$(kubectl get svc/${ENVOY_SERVICE} -n envoy-gateway-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

echo Set /etc/hosts with:
echo $DOMAIN: $GATEWAY_IP
sudo sed -i '/dev.example.com/d' /etc/hosts
sudo sh -c "echo $GATEWAY_IP $DOMAIN >> /etc/hosts"
