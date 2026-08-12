REGISTRY  := europe-north1-docker.pkg.dev/solvr-multitenant/internal-artifacts
IMAGE     := $(REGISTRY)/m365-mcp
TAG       := $(shell git rev-parse --short=7 HEAD)
NAMESPACE := mcphub
HOST      := m365.mcphub.no

.PHONY: tools build push bump ship deploy status logs rollout smoke run-local

## tools — regenerate the ENABLED_TOOLS ceiling from src/endpoints.json.
## Run after merging upstream: new endpoints do not join the filter by themselves.
tools:
	node k8s/gen-tool-filter.mjs > k8s/configmap.yaml
	@grep -c . k8s/configmap.yaml >/dev/null && echo "regenerated k8s/configmap.yaml"

## build — container image tagged with the current commit
build:
	docker build -t $(IMAGE):$(TAG) .

## push — publish that image to Artifact Registry
push:
	docker push $(IMAGE):$(TAG)

## bump — point the kustomization at the current commit's image
## (sed rather than `kustomize edit`, which needs the standalone binary)
bump:
	sed -i 's|^\( *newTag: \).*|\1"$(TAG)"|' k8s/kustomization.yaml
	@grep -q 'newTag: "$(TAG)"' k8s/kustomization.yaml || { echo "bump failed"; exit 1; }
	@kubectl kustomize k8s | grep -q '$(IMAGE):$(TAG)' && echo "kustomization -> $(IMAGE):$(TAG)"

## ship — build, push, bump, and commit the tag. ArgoCD syncs it from main.
## Refuses a dirty tree, since TAG would then name a commit that is not what
## got built.
ship:
	@git diff-index --quiet HEAD -- || { echo "working tree dirty — commit first"; exit 1; }
	$(MAKE) build
	$(MAKE) push
	$(MAKE) bump
	@git diff --quiet k8s/kustomization.yaml || git commit -q -m "Ship $(TAG) to $(HOST)" k8s/kustomization.yaml
	@echo "shipped $(IMAGE):$(TAG) — push to main for ArgoCD to sync"

## deploy — apply the ArgoCD Application (one-time bootstrap)
deploy:
	kubectl apply -f k8s/app.yaml

## status — what is actually running
status:
	kubectl -n $(NAMESPACE) get deploy,pod,svc,ingress -l app=m365-mcp
	@kubectl -n $(NAMESPACE) get deploy m365-mcp -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'

## logs — tail the running pods
logs:
	kubectl -n $(NAMESPACE) logs -l app=m365-mcp --tail=100 -f

## rollout — restart (e.g. after regenerating the tool filter)
rollout:
	kubectl -n $(NAMESPACE) rollout restart deployment/m365-mcp
	kubectl -n $(NAMESPACE) rollout status deployment/m365-mcp

## run-local — the deployed configuration on localhost:3000. Needs no secrets:
## the pod has none. Pass a real Graph token to exercise it, e.g.
##   curl -H "Authorization: Bearer $$TOKEN" ...
run-local:
	docker run --rm -p 3000:3000 \
	  -e ENABLED_TOOLS="$$(sed -n 's/^  ENABLED_TOOLS: //p' k8s/configmap.yaml | tr -d '\"')" \
	  -e MS365_MCP_RATE_LIMIT_DISABLED=true \
	  $(IMAGE):$(TAG) --http 3000 --org-mode

## smoke — an unauthenticated MCP call. A 401 carrying WWW-Authenticate is the
## expected, correct answer: it proves the bearer gate is live. Then the same
## call with a real Graph token in $$MS365_TOKEN, which should list the tools.
smoke:
	@printf '%s' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"make-smoke","version":"0"}}}' \
	| curl -sS -i -X POST https://$(HOST)/mcp \
	    -H 'Content-Type: application/json' \
	    -H 'Accept: application/json, text/event-stream' \
	    --data-binary @- | head -12
	@test -n "$$MS365_TOKEN" || { echo "\nset MS365_TOKEN=<a Graph access token> to smoke the authenticated path"; exit 0; }
	@printf '%s' '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
	| curl -sS -X POST https://$(HOST)/mcp \
	    -H "Authorization: Bearer $$MS365_TOKEN" \
	    -H 'Content-Type: application/json' \
	    -H 'Accept: application/json, text/event-stream' \
	    --data-binary @- | head -c 400; echo
