# Repository Review

Review of the AI-generated k3s GitOps repository for a single-node media server cluster on openSUSE Leap Micro 6.2 with FluxCD, media stack (*arr suite + Plex), and Immich photo management.

**Files reviewed:** 42 non-git files across `clusters/`, `infrastructure/`, `apps/`, `combustion/`, `scripts/`, and root config files.

---

## Overall Verdict

This is a high-quality, well-architected repository. The AI agent clearly understood k3s, FluxCD, SOPS/age, cert-manager, Intel GPU passthrough, and the *arr media stack. The layered FluxCD dependency graph is correctly modeled, security contexts are thorough, and the scripts are properly idempotent with good error handling. That said, there are several issues ranging from a deployment-blocking placeholder to subtle configuration risks.

---

## What's Done Well

- **FluxCD dependency graph** is correctly modeled: sources -> configs -> controllers -> certs/storage/netpol -> apps. The `dependsOn` chains in `clusters/conductor/infrastructure.yaml` and `apps.yaml` match the actual resource dependencies.
- **SOPS decryption** is only enabled on the two Kustomizations that contain encrypted files (`infra-certs` and `apps-immich`). `apps-media` correctly omits it.
- **Security contexts** are consistent across all 9 media pods: `runAsNonRoot`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]`, `seccompProfile: RuntimeDefault`. This is textbook.
- **Per-app UID isolation** (10001-10010) with shared GID (1500) is a strong pattern. Prevents lateral movement if a container is compromised while still allowing cross-app file access via the media group.
- **Shell scripts** (`combustion/script`, `bootstrap.sh`, `setup-nas.sh`) are excellent: `set -euo pipefail`, ERR traps, input validation, idempotent operations, clear logging, temp directory cleanup.
- **NetworkPolicies** are well-designed: default-deny per namespace, selective egress (SABnzbd only gets NNTP+HTTPS, Prowlarr gets HTTP+HTTPS, Plex gets full access for remote streaming).
- **Config mount paths** (`/{appname}/etc`) correctly follow the 11notes image convention across all deployments.
- **NFS PV/PVC pairs** correctly use `storageClassName: ""` to prevent dynamic provisioning and `volumeName` for static binding.
- **Bootstrap script** handles disaster recovery with the `SOPS_AGE_KEY` env var restore path.
- **README** is thorough, with service discovery URLs, root folder paths, data flow diagrams, UID table, troubleshooting guide, and backup checklist.

---

## Bugs and Issues

### Severity: HIGH (will break deployment)

**1. ClusterIssuer has placeholder email**
`infrastructure/certs/cluster-issuer.yaml:8`
```yaml
email: your-email@example.com
```
Let's Encrypt requires a valid email for ACME account registration. This placeholder will cause the ClusterIssuer to register with a fake email, which means no certificate renewal notifications and potential issues with ACME account creation. **Replace with your real email before deploying.**

**2. Immich Helm chart version is unpinned**
`apps/immich/helmrelease.yaml:9-14`
```yaml
chart:
  spec:
    chart: immich
    sourceRef:
      kind: HelmRepository
      name: immich
      namespace: flux-system
    # no version field!
```
Every other HelmRelease in the repo pins a version range (e.g., `">=1.16.0 <2.0.0"`). The Immich chart has no `version` constraint at all, meaning FluxCD will deploy whatever the latest chart version is. The Immich Helm chart has undergone **significant breaking restructuring** (values keys have changed across major versions). An unattended chart upgrade could break the entire Immich deployment. Add a version constraint like `version: ">=0.7.0 <1.0.0"` (or whatever matches your target chart version).

**3. Missing `/media/Books` directory on NAS**
`scripts/setup-nas.sh:78`
```bash
readonly -a HTPC_DIRS=("${HTPC_BASE}/Movies" "${HTPC_BASE}/Music" "${HTPC_BASE}/TV")
```
Readarr is deployed and mounts `/media` from the NFS share, but the NAS setup script only creates `Movies`, `Music`, and `TV` directories. There is no `Books` directory. Readarr will have nowhere to import books. The README's root folder table also omits Readarr. Add `"${HTPC_BASE}/Books"` to the array and add `Readarr | /media/Books` to the README table.

### Severity: MEDIUM (may cause issues)

**4. Node name mismatch risk in bootstrap**
`scripts/bootstrap.sh:205`
```bash
kubectl wait --for=condition=Ready node/conductor --timeout=120s
```
The combustion script sets hostname to `conductor.home.ameri.me` (FQDN). k3s uses the OS hostname as the node name. Depending on how openSUSE resolves the hostname, the node may register as `conductor.home.ameri.me` rather than `conductor`. If so, this wait command will fail. Consider using `kubectl wait --for=condition=Ready node --all --timeout=120s` instead, or verify the exact node name k3s will use.

**5. Overseerr image UID documentation mismatch**
`README.md:314`
```
| Overseerr | `sctx/overseerr` | `1.33.2` | Official, runs UID 1000 |
```
The README says Overseerr "runs UID 1000" but the deployment (`apps/media/overseerr.yaml:30`) sets `runAsUser: 10008`. The Kubernetes securityContext override is the right approach (consistent with the per-app UID strategy), but the README's "runs UID 1000" comment is misleading. It should say something like "Official image, overridden to UID 10008" to match the UID allocation table.

**6. Porkbun webhook chart version is unbounded above**
`infrastructure/controllers/porkbun-webhook.yaml:13`
```yaml
version: ">=1.0.0"
```
This has no upper bound. A major version bump could introduce breaking changes. Other charts use bounded ranges like `">=0.31.0 <1.0.0"`. Change to `">=1.0.0 <2.0.0"`.

**7. `ReadWriteOnce` PVC shared by 5 pods**
`infrastructure/storage/local-downloads.yaml` + `apps/media/{sabnzbd,sonarr,radarr,lidarr,readarr}.yaml`

The `local-downloads` PVC is `ReadWriteOnce` but is mounted by 5 different Deployments. This works on a single-node cluster (all pods are co-located), but would silently break if you ever add a second node. Consider adding a comment to `local-downloads.yaml` noting this constraint, or using `ReadWriteMany` if the underlying storage supports it (hostPath does on a single node anyway).

**8. Immich Helm chart values structure risk**
`apps/immich/helmrelease.yaml`

The Immich Helm chart has been known to restructure its values between versions. Specific concerns:
- `machine-learning:` as a top-level key (hyphenated) -- some chart versions use `machinelearning` instead
- `immich.persistence.library.existingClaim` -- the path may differ across chart versions
- `server.probes.liveness.spec` and `server.probes.startup.spec` -- the probes override structure varies

Since the chart version is unpinned (issue #2), this is especially risky. Pinning the version would mitigate this.

### Severity: LOW (cosmetic or minor)

**9. Deprecated NFS mount option `intr`**
`infrastructure/storage/nfs-htpc.yaml:12` and `nfs-immich.yaml:12`
```yaml
mountOptions: [nfsvers=4.2, hard, intr]
```
The `intr` option has been deprecated since Linux kernel 2.6.25 and is silently ignored. Remove it to avoid confusion: `mountOptions: [nfsvers=4.2, hard]`

**10. NFS mount options YAML syntax**
`infrastructure/storage/nfs-htpc.yaml:12`
```yaml
mountOptions: [nfsvers=4.2, hard, intr]
```
YAML flow sequence items containing periods/dots can sometimes be misinterpreted. While this works in practice, the more robust form is:
```yaml
mountOptions:
  - nfsvers=4.2
  - hard
```

**11. Kustomization API version**
All `kustomization.yaml` files use `apiVersion: kustomize.config.k8s.io/v1beta1`. The current stable version is `kustomize.config.k8s.io/v1beta1`, so this is correct but worth noting that `v1` may become the standard.

**12. README says "reconciles every hour" but Immich timeout is 15 minutes**
`clusters/conductor/apps.yaml:29`: `timeout: 15m` for `apps-immich`. This means if the Immich Helm install takes longer than 15 minutes (which it might on first deploy when pulling multiple large images), Flux will consider it failed. The 15-minute timeout is reasonable but could be tight for first-time deployments on slow connections.

---

## Inconsistencies

| Item | Location A | Location B | Discrepancy |
|------|-----------|-----------|-------------|
| Overseerr UID | README:314 says "runs UID 1000" | overseerr.yaml:30 has `runAsUser: 10008` | README describes image default, deployment overrides it. Confusing. |
| Readarr root folder | readarr.yaml mounts `/media` | setup-nas.sh only creates Movies/Music/TV | No `Books` dir exists for Readarr |
| Immich version pinning | README:319 "No `:latest` tags" | helmrelease.yaml has no chart version | Chart version is effectively "latest" |
| Repo name | .env.example has `GITHUB_REPO="k3s-cluster"` | README step 4 says `git clone .../k3s-cluster.git` | User must ensure these match their actual repo name |
| `.sops.yaml` | README lists it in tree structure | Not present in repo (generated by bootstrap) | Expected but could confuse someone reading the tree |

---

## File-by-File Notes

### Scripts
| File | Status | Notes |
|------|--------|-------|
| `combustion/script` | Good | Proper validation, idempotent, good error handling. SETGID bit (2775) on downloads dir is correct. |
| `scripts/bootstrap.sh` | Good | Well-structured 8-step process. `--dry-run=client -o yaml \| kubectl apply` pattern is idempotent. One concern: `git push origin main` at line 325 could fail if the repo doesn't have a remote configured yet (bootstrap is for first-time setup on a fresh clone). |
| `scripts/setup-nas.sh` | Good (missing Books) | Missing `Books` directory for Readarr. `_ensure_export` function is well-designed for idempotency. |

### Infrastructure
| File | Status | Notes |
|------|--------|-------|
| `infrastructure/sources/*.yaml` | Good | All HelmRepository URLs are correct and current. |
| `infrastructure/configs/namespaces.yaml` | Good | PSA labels are consistent with bootstrap's PSA config. |
| `infrastructure/configs/traefik-tls-store.yaml` | Good | Correctly references the wildcard cert secret in kube-system. |
| `infrastructure/controllers/cert-manager.yaml` | Good | CRDs enabled, version range bounded. |
| `infrastructure/controllers/porkbun-webhook.yaml` | Minor issue | Unbounded upper version. |
| `infrastructure/controllers/nfd.yaml` | Good | Worker tolerations correct for single-node. |
| `infrastructure/controllers/intel-*.yaml` | Good | Correct dependency chain, `sharedDevNum: 5` provides headroom for 3 current GPU consumers. |
| `infrastructure/certs/cluster-issuer.yaml` | Needs fix | Placeholder email. YAML structure for webhook solver is correct. |
| `infrastructure/certs/wildcard-cert.yaml` | Good | Covers both `*.ameri.me` and bare `ameri.me`. |
| `infrastructure/storage/*.yaml` | Good | PV/PVC pairs correctly matched. `storageClassName: ""` prevents dynamic provisioning. |
| `infrastructure/network-policies/media.yaml` | Good | Thoughtful per-app egress rules. SABnzbd gets port 563 (NNTPS) + 443. Plex gets full access. |
| `infrastructure/network-policies/immich.yaml` | Good | Intra-namespace + NFS + Traefik ingress + internet for maps/models. |

### Apps
| File | Status | Notes |
|------|--------|-------|
| `apps/media/sabnzbd.yaml` | Good | Only mounts downloads, not media (correct -- SABnzbd doesn't need media access). |
| `apps/media/sonarr.yaml` | Good | Mounts both media and downloads for import workflow. |
| `apps/media/radarr.yaml` | Good | Same pattern as sonarr. |
| `apps/media/lidarr.yaml` | Good | Same pattern. |
| `apps/media/readarr.yaml` | Good (needs NAS dir) | Structurally correct but NAS lacks Books directory. |
| `apps/media/prowlarr.yaml` | Good | Correctly omits media/downloads mounts (indexer only). |
| `apps/media/bazarr.yaml` | Good | Mounts media but not downloads (correct for subtitle management). |
| `apps/media/overseerr.yaml` | Good | Next.js cache emptyDir is a nice touch. Config path `/app/config` is correct for sctx/overseerr. |
| `apps/media/plex.yaml` | Good | LoadBalancer service type correct for remote access. GPU resource request. Separate transcode emptyDir with size limit. |
| `apps/immich/helmrelease.yaml` | Needs fixes | Unversioned chart. Values structure may not match target chart version. |
| `apps/immich/ingress.yaml` | Good | Port 2283 is correct for Immich server. |

---

## Recommendations

1. **Before first deploy**: Replace `your-email@example.com` in `cluster-issuer.yaml` with your real email.
2. **Pin the Immich chart version**: Add `version: ">=0.8.0 <1.0.0"` (or check current chart version) to the HelmRelease spec.
3. **Add Books directory**: Add `"${HTPC_BASE}/Books"` to `setup-nas.sh` HTPC_DIRS array and add Readarr to the README root folders table.
4. **Bound the porkbun webhook version**: Change `">=1.0.0"` to `">=1.0.0 <2.0.0"`.
5. **Fix node name in bootstrap**: Use `kubectl wait --for=condition=Ready node --all` or verify what name k3s assigns with the FQDN hostname.
6. **Clean up README Overseerr entry**: Change "runs UID 1000" to "overridden to UID 10008" to match actual deployment.
7. **Remove deprecated `intr` mount option**: From both NFS PV definitions.
8. **Verify Immich chart values**: After pinning the chart version, check `helm show values immich/immich --version <pinned>` to confirm the values structure matches your HelmRelease.
