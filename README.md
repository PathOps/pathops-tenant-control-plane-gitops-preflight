# pathops-tenant-control-plane-gitops-preflight

Preflight desired state of the PathOps Tenant Control Plane in its dev Cell,
and the delivery definitions that change and validate it (Decision 0051).
Forgejo is the operational authority; GitHub is a one-way push mirror.

## Desired state

`kustomization.yaml`, `deployment.yaml`, `service.yaml` and
`integration-test.yaml` (the current integration-test Job). Flux applies them,
from namespace `pathops-tenant-control-plane-flux-preflight` with a read-only
deploy key, to `pathops-tenant-control-plane-preflight` as `flux-deployer`. The
Cell bootstrap patches in the runtime configuration and credentials; none of
them are in Git.

`images[].newTag` is the immutable revision tag, the first 12 characters of the
source commit (Decision 0043). The OCI digest is integrity metadata checked by
the pipelines, not the desired-state reference.

## Delivery definitions: `.pathops/`

```text
.pathops/tekton/
├── pipelines/
│   ├── deploy-preflight.yaml        DEPLOY_PREFLIGHT
│   ├── build-preflight-tests.yaml   BUILD_PREFLIGHT_TESTS (runs in the build stage)
│   ├── run-preflight-tests.yaml     RUN_PREFLIGHT_TESTS
│   └── promote-release.yaml         PROMOTE_RELEASE
├── tasks/
│   ├── clone-gitops.yaml            CLONE_GITOPS (StepAction)
│   ├── push-gitops.yaml             PUSH_GITOPS (StepAction)
│   ├── update-image.yaml            UPDATE_IMAGE
│   ├── flux-reconcile.yaml          FLUX_RECONCILE
│   ├── verify-rollout.yaml          VERIFY_ROLLOUT
│   ├── build-preflight-tests.yaml   the integration-test image build (BUILD)
│   ├── prepare-preflight-tests.yaml PREPARE_PREFLIGHT_TESTS
│   ├── wait-preflight-tests.yaml    WAIT_PREFLIGHT_TESTS
│   ├── promote-release.yaml         the release tag and the GHCR check
│   └── request-stage.yaml           REQUEST_STAGE
└── triggers/preflight.yaml          the stage requests these pipelines accept
```

The chain, started by the source repository's BUILD_AND_PUSH:

```text
DEPLOY_PREFLIGHT       candidate tag -> Git -> Flux -> rollout verified
RUN_PREFLIGHT_TESTS    -> BUILD_PREFLIGHT_TESTS (build stage, BUILD role):
                          test image at the candidate's exact source commit
                       -> Job with that image -> Git -> Flux -> real result
PROMOTE_RELEASE        annotated tag release/<revision> (the release candidate
                       JSON) -> GitHub mirror -> .github/workflows/
                       promote-release.yml copies the same digest to
                       ghcr.io/pathops/pathops-tenant-control-plane:<revision>
                       -> the pipeline checks GHCR serves exactly that digest
```

Identities: the preflight pipelines are GENERAL and may only write this
repository; BUILD_PREFLIGHT_TESTS has BUILD, source read and test-image/cache
registry write, and no GitOps authority. Flux only reads. The release tag is
created once and never moved.

In the dev Cell these definitions are installed administratively
(`pathops-dev-cell-bootstrap/scripts/tenant-cp.sh <cell> install`) from this
repository's committed `.pathops/`: the Tenant Control Plane cannot provision the
delivery that builds itself. In a normal Cell the Tenant Control Plane
orchestrates.
