
$controller='ingress-nginx-controller'
$ns='kiamol-ingress-nginx'
$ip=$(kubectl get svc $controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}' -n $ns)
if ($ip -eq 'localhost') {
	$ip='127.0.0.1'
}

Add-Content -Value "$ip  todo.kiamol.local$([Environment]::NewLine)$ip  api.todo.kiamol.local" -Path C:/windows/system32/drivers/etc/hosts