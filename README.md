# pathops-tenant-control-plane-gitops-preflight

Preflight desired state of the PathOps Tenant Control Plane in its lab Cell
(Decision 0044). Forgejo is the operational authority; GitHub is a one-way push
mirror.

- **Reader:** Flux, from namespace `pathops-tenant-control-plane-flux-preflight`,
  with a read-only deploy key. It applies this repository to
  `pathops-tenant-control-plane-preflight` as `flux-deployer`.
- **Writer:** only the preflight Tekton stage
  (`pathops-tenant-control-plane-tekton-preflight`), with this repository's own
  write deploy key. DEPLOY PREFLIGHT sets the image and RUN PREFLIGHT TESTS adds the run's integration-test Job.
- **Image:** `images[].newTag` is the immutable revision tag, the first 12
  characters of the source commit (Decision 0043). The OCI digest is integrity
  metadata checked by the pipelines, not the desired-state reference.

The delivery definitions live in the source repository
(`pathops-tenant-control-plane/ci/`); this repository was seeded from
`ci/gitops/preflight/` when it was created.
