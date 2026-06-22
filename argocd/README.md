# ArgoCD — kurulum ve bootstrap

Bu dizin, `multi-env` uygulamasının ArgoCD tarafını tanımlar. Tasarım kararları
için bkz. [`docs/CONTEXT.md`](../docs/CONTEXT.md) (özellikle md.8: "ApplicationSet'i git'e
koy; `kubectl apply` sadece bootstrap").

```
argocd/
├── root-app.yaml                 # app-of-apps (BOOTSTRAP: 1 kez elle apply)
├── apps/
│   └── applicationset.yaml       # ortam başına Application üretir (ArgoCD yönetir)
└── repositories/
    ├── oci-registry-repo.example.yaml  # OCI Helm registry creds (örnek)
    └── infra-repo.example.yaml         # infra-repo git creds (örnek)
```

## Mimari (özet)

- **ApplicationSet** `environments/*/config.yaml` dosyalarını okur (git *files* generator) ve
  her ortam için bir `multi-env-<env>` Application üretir.
- Her Application **multi-source**'tur:
  1. Chart → `registry.local/charts` OCI'dan, `chart: multi-env`, sürüm = `config.yaml`'daki `chartVersion`.
  2. Values → infra-repo git'ten, `$values/environments/<env>/values.yaml`.
- **Auto-sync yalnızca dev'de** (`config.yaml: autoSync: true`). test/uat/prod **manuel** kalır;
  Jenkins `argocd app sync` ile tetikler.

## Önkoşullar

- Cluster'da ArgoCD kurulu ve `argocd` namespace mevcut.
- `argocd` CLI kurulu (Helm ile kurulan platformdan ayrı bir client; bkz. CONTEXT.md md.8).
- OCI registry'de `multi-env` chart'ı yayınlanmış (bkz. `.github/workflows/chart-ci.yaml`).

## Bootstrap sırası

> Sıra önemlidir: önce credential'lar, sonra root-app.

1. **Repository credential'ları** (gerçek değerlerle doldurulmuş kopyalar):

   ```bash
   cp argocd/repositories/oci-registry-repo.example.yaml argocd/repositories/oci-registry-repo.yaml
   cp argocd/repositories/infra-repo.example.yaml        argocd/repositories/infra-repo.yaml
   # <REGISTRY_USER>/<REGISTRY_TOKEN>, <GIT_USER>/<GIT_TOKEN> alanlarını doldur
   kubectl apply -n argocd -f argocd/repositories/oci-registry-repo.yaml
   kubectl apply -n argocd -f argocd/repositories/infra-repo.yaml
   ```

   > `*.yaml` (örnek olmayanlar) `.gitignore`'dadır — gerçek credential commit'lenmez.
   > Üretimde Sealed Secrets / SOPS / External Secrets Operator tercih edin.

2. **Root-app** (app-of-apps) — yalnızca 1 kez:

   ```bash
   kubectl apply -n argocd -f argocd/root-app.yaml
   ```

   Bundan sonra root-app `argocd/apps/` dizinini izler; ApplicationSet'i ArgoCD senkronize eder.
   Elle `applicationset.yaml` apply etmeyin — git üzerinden yönetilir.

3. **Doğrulama**:

   ```bash
   argocd app list
   # multi-env-dev (Synced/Healthy, auto-sync), multi-env-{test,uat,prod} (OutOfSync, manuel)
   ```

## Jenkins için ArgoCD token (CONTEXT.md md.8 + açık adım 1)

Jenkins, gated ortamları (test/uat/prod) `argocd app sync` ile tetikleyen tek bileşendir.
Bunun için ayrı, dar yetkili bir hesap + token gerekir.

1. **`jenkins` hesabını apiKey yetkisiyle aç** (`argocd-cm` ConfigMap):

   ```yaml
   # kubectl -n argocd edit configmap argocd-cm
   data:
     accounts.jenkins: apiKey
   ```

2. **RBAC** — yalnızca `multi-env-*` app'lerini sync/get yetkisi (`argocd-rbac-cm`):

   ```yaml
   # kubectl -n argocd edit configmap argocd-rbac-cm
   data:
     policy.csv: |
       p, role:jenkins-deployer, applications, get,  default/multi-env-*, allow
       p, role:jenkins-deployer, applications, sync, default/multi-env-*, allow
       g, jenkins, role:jenkins-deployer
   ```

3. **Token üret** (Jenkins credential'ı `argocd-token` olarak saklanır):

   ```bash
   argocd account generate-token --account jenkins
   ```

> Not: Jenkins **asla** `kubectl apply` / `helm upgrade` yapmaz; yalnızca infra-repo'ya pin yazar
> ve `argocd app sync/wait` ile ArgoCD'yi tetikler (CONTEXT.md md.3).

## Uyarlama placeholder'ları

| Placeholder                      | Nerede                                   |
|----------------------------------|------------------------------------------|
| `https://git.local/infra-repo.git` | applicationset.yaml, root-app.yaml, infra-repo secret |
| `registry.local/charts`          | applicationset.yaml, oci-registry secret |
| `argocd` namespace               | tüm manifestler                          |
| `default` project                | root-app + applicationset (gerekirse özel AppProject) |
