# CONTEXT — Apinizer Gateway + App Server CI/CD Hattı

> Bu dosya, makale serisi için kurguladığımız mimarinin **kesinleşmiş kararlarını** ve
> repo'nun **güncel durumunu** tek yerde toplar. Yeni bir sohbete bu dosyayı referans
> göstermek yeterlidir. Kararlar veri kabul edilir; over-design yapılmaz.
>
> İlke seti: thread safety + performans + DRY/KISS/YAGNI/OWASP/DDD. Kütüphane/API dokümanı
> gerektiğinde güncel kaynaktan doğrulanır.

---

## 1. Proje hedefi

Bir app server sürümü çıktığında:

1. İmaj üretimi
2. (gerekiyorsa) Swagger/OpenAPI güncellenmesi
3. App'in **dev → test → uat → prod** aşamalı versiyon yönetimi
4. Her ortam güncellendikten sonra **Apinizer gateway'de ilgili ortamın proxy'sinin**
   güncellenip deploy edilmesi
5. **Coordinated rollback** (app + gateway birlikte)

---

## 2. Teknoloji ve temel kararlar

- **Kurum:** on-prem.
- **Repo:** 2 ayrı repo — `app-source` + `infra/GitOps` (bu repo).
- **Dallanma:** trunk-based. Tek immutable imaj tüm ortamlara terfi eder; ortam farkı config'te.
- **CI:** GitHub Actions.
- **CD:** Jenkins (orkestratör) + ArgoCD (deploy eden tek bileşen) + Helm.
- **Apinizer Promotion modülü KULLANILMIYOR** — prod proxy de update+deploy / deploy-history rollback ile yönetilir.

---

## 3. Sorumluluk dağılımı (altın kurallar)

- **GitHub Actions:** test, imaj build/push, OpenAPI artefaktı, Jenkins tetikleme.
  Cluster/infra/Apinizer'a **dokunmaz**.
- **Jenkins:** orkestratör. infra-repo'ya pin yazar, `argocd app sync/wait` ile tetikler,
  **Apinizer Management API'yi çağıran tek bileşen**, smoke test, onay kapıları, ledger,
  rollback. Cluster'a **asla** `kubectl apply` / `helm upgrade` yapmaz.
- **ArgoCD:** cluster'a deploy eden **tek** bileşen. **dev auto-sync**, test/uat/prod **gated**
  (Jenkins tetikler).
- **Helm:** paketleme. Chart **OCI registry**'de versiyonlu; ArgoCD **multi-source**
  (chart OCI'dan + values infra-repo'dan), ortam başına `chartVersion` pin.

---

## 4. Kritik tasarım kararları (gerekçeleriyle)

1. **Release kimliği = `(imageTag, chartVersion, valuesGitSha)`.**
   Chart ile app ayrı eksende versiyonlanır: **chart = SemVer/OCI** (sadece template değişince
   bump), **values = Git SHA** (git'in kendisi versiyonlama). İlişki çoktan-bire; her imajda
   chart bump edilmez.
2. **Tek CD pipeline, parametrik (`IMAGE_TAG` + `CHART_VERSION`).**
   App-only / chart-only / coupled değişiklikler hep aynı pipeline'dan; iki ayrı CD pipeline
   YOK. Coupled değişiklikte ArgoCD chart+values'ı **tek atomik manifest** olarak iner
   (yarım-uygulanma penceresi yok).
3. **Env-var'sız deploy riskine 3 katman savunma:**
   - (a) chart CI ortamı deploy etmez, **pin'leri sadece Jenkins yazar** (tek doğrulama noktası);
   - (b) app `deploy/required-chart-version` deklare eder, Jenkins **Validate** çift-uyumu kontrol eder;
   - (c) app **fail-closed** (zorunlu env yoksa başlamaz) + dev health/smoke gate →
     kötü kombinasyon prod'a geçemez.
4. **Values CI ayrı ve gereklidir** (sadece `charts/` CI'ı yetmez):
   `environments/**` PR'ında render + `values.schema.json` + kubeconform + (ops.) OPA.
   **Paketlemez, doğrular.** Auto-sync sadece dev'de → values PR'ı bile prod'a gate'siz inmez.
5. **Rollback = targeted + coordinated** ("bir önceki" sadece n-1 kısayolu).
   - App: ledger'dan pin'leri yaz → ArgoCD sync (asla `kubectl rollout undo` — self-heal ile çakışır).
   - Gateway: `deploy-histories/{revision}/rollback?environmentName=`.
6. **Apinizer drift/policy kaybı çözümü:** `reParse:true` **politikaları korur** (doğrulandı)
   → app rollback'inde **eski spec ile reParse** politikaları uçurmaz. Tam snapshot gerekiyorsa:
   bir versiyon yaşarken yapılan manuel değişiklikleri korumak için, **bir sonraki release'in
   CD'sinin EN BAŞINDA**, giden sürümün canlı halini **`persistent:true` ile redeploy edip yeni
   kalıcı revision mintle** (var olan revision'ı sonradan persistent yapan endpoint YOK),
   ledger'da giden sürümün revision'ını ona güncelle. **5-history limitine güvenme; persistent kullan.**
7. **Release ledger:** `infra-repo/releases/<env>.yaml`, ArgoCD'nin izlemediği path'te, ortam
   başına ayrı dosya, Jenkins `[skip ci]` + `git pull --rebase` ile yazar.
   Alanlar: `appVersion, chartVersion, valuesRef, apinizerRevision, status`.
8. **ApplicationSet'i git'e koy; `kubectl apply` sadece bootstrap.**
   App-of-apps: `argocd/root-app.yaml` 1 kez elle apply → `argocd/apps/applicationset.yaml`'ı
   ArgoCD yönetir. `argocd` CLI, Helm ile kurulan platformdan ayrı bir client'tır (kur + token
   ile Jenkins'e tanıt); sadece gated ortamların sync'i için gerekir.

---

## 5. Apinizer Management API (öğrenilenler)

Base: `<manager-url>/apiops` — `Authorization: Bearer <PAT>`

- **Var mı:** `GET .../projects/{prj}/apiProxies/{proxy}/`
- **Oluştur/Güncelle (URL):** `POST` / `PUT .../apiProxies/url/`
  - update'te **`reParse:true`** (politikalar korunur; endpoint'ler spec'e göre güncellenir;
    `Skip for Re-Parse` ile endpoint korunur).
  - `deploy:false` ile config'i deploy'dan ayır.
- **Ortama deploy:** `POST .../apiProxies/{proxy}/environments/{env}/` body `{description, persistent}`.
- **Export/Import (tam config + politikalar):** `GET .../export/` (ZIP), `POST .../apiProxies/import/`.
- **Deploy history:** `GET .../deploy-histories/` (revision, persistent, environment...).
  - **Rollback:** `POST .../deploy-histories/{revision}/rollback/?environmentName={env}`
    (opsiyonel atomik deploy). `persistent:true` auto-delete'ten muaf; **sadece deploy anında set edilir.**
- **Referans:** Apinizer resmi "Multi-Environment CI/CD Pipeline with GitHub Actions and Jenkins"
  dokümanı (bizim ArgoCD/Helm uyarlamamızın temeli; orada Jenkins `kubectl apply` yapıyor — biz
  onu ArgoCD'ye devrettik).

---

## 6. Örnek uygulama

FastAPI **"Messaging API"**, imaj **`apinizeren/multi-env:<tag>`** (örn. `v0.0.9`), port **8000**.

Uçlar: `/messages` (POST/GET), `/info` (APP_VERSION/ENVIRONMENT/BUILD_SHA env'lerini okur),
`/health`, `/test*`, `/openapi.json`.

---

## 7. Repo'nun GÜNCEL durumu (bu dosyanın yazıldığı an)

### Hazır ✅

- **Helm chart `charts/multi-env/`:**
  - `Chart.yaml` (v0.1.0 / appVersion `v0.0.9`)
  - `values.yaml`, `values.schema.json`
  - `templates/{_helpers.tpl, deployment.yaml, service.yaml}` (NodePort, `/health` probe)
- **Ortamlar `environments/<env>/{config.yaml, values.yaml}`:**

  | Ortam | namespace        | chartVersion | autoSync | replicaCount | nodePort | image.tag |
  |-------|------------------|--------------|----------|--------------|----------|-----------|
  | dev   | multi-env-dev    | 0.1.0        | true     | 1            | 30110    | v0.0.9    |
  | test  | multi-env-test   | 0.1.0        | false    | 1            | 30111    | v0.0.9    |
  | uat   | multi-env-uat    | 0.1.0        | false    | 2            | 30112    | v0.0.9    |
  | prod  | multi-env-prod   | 0.1.0        | false    | 2            | 30113    | v0.0.9    |

  > Not: chart pin `config.yaml`'da, image pin `values.yaml`'da. prod ek `resources` taşır.
  > (NodePort'lar repo'daki 30110-30113 değerleridir; eski taslaktaki 30080-30083 geçersizdir.)
- **infra-repo CI:**
  - `.github/workflows/chart-ci.yaml` — `charts/multi-env`'i lint/template + **immutable** OCI push.
  - `.github/workflows/values-ci.yaml` — `environments/**` PR'ında render + schema + kubeconform.
  - (Her ikisi de `multi-env` adına güncellendi; eski `myapp` referansları kaldırıldı.)
- **ArgoCD `argocd/`:**
  - `argocd/apps/applicationset.yaml` — git *files* generator (`environments/*/config.yaml`),
    multi-source (OCI chart `registry.local/charts` + `$values` infra-repo git), `templatePatch`
    ile koşullu auto-sync (sadece dev). Release adı `multi-env-<env>`.
  - `argocd/root-app.yaml` — app-of-apps bootstrap (1 kez `kubectl apply`).
  - `argocd/repositories/*.example.yaml` — OCI registry + infra-repo git credential örnekleri
    (gerçek `*.yaml` `.gitignore`'da).
  - `argocd/README.md` — bootstrap sırası + `jenkins` hesabı/token/RBAC.

### Açık / sıradaki adımlar 🔜

1. **ArgoCD bootstrap doğrulaması:** credential Secret'larını gerçek değerlerle doldurup apply,
   root-app apply, `argocd account generate-token --account jenkins` ile token üretimi + uçtan uca test.
2. **Jenkins pipeline'ları (henüz YOK) — `multi-env`'e uyarlanacak:**
   - `Jenkinsfile` (parametrik CD), `Jenkinsfile.rollback` (targeted)
   - shared-lib: `deployEnvironment`, `apinizerProxySync`, `recordRelease`, `resolveRelease`,
     `smokeTest`, `retryWithDelay` + eksik yardımcılar `validateRelease`, `deployPins`,
     `argoSyncWait`, `portFor`
   - proxy adı `multi-env`, `specUrl=http://<NODE_IP>:<nodePort>/openapi.json`,
     deployment adı `multi-env-<env>`
3. **Jenkins credentials:** `github-credentials`, `kubeconfig` (ya da argocd-token),
   `argocd-token`, `apinizer-management-url`, `apinizer-token`.
4. **`releases/<env>.yaml` ledger iskeleti** (henüz YOK).
5. (Ops.) Lokal `kind` + ArgoCD ile dev'i uçtan uca ayağa kaldırıp doğrulama.
6. (Ops.) Drift snapshot adımının (madde 4.6) shared-lib fonksiyonu; OPA/conftest policy;
   oasdiff breaking-change gate — "ileri seviye" makale notu.

---

## 8. Uyarlama placeholder'ları

| Placeholder            | Açıklama                          |
|------------------------|-----------------------------------|
| `registry.local`       | imaj + OCI chart registry         |
| `git.local/infra-repo.git` | infra-repo git remote         |
| `argocd.local`         | ArgoCD server                     |
| `<NODE_IP>`            | cluster node IP                   |
| NodePort'lar           | 30110-30113 (dev/test/uat/prod)   |
| Apinizer proje adları  | `multi-env-<env>`                 |
