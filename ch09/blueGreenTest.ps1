
$url = $(kubectl get svc vweb -o jsonpath='http://{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}:8090/v.txt')

for($i = 0; $i -lt 10; $i++) { 
    curl -s "$url"
}