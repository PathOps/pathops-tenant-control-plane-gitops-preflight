#!/usr/bin/env bash
# Checks of this repository's delivery definitions in .pathops/ (no cluster, no
# registry, no GitHub), Decisions 0043, 0045, 0051, 0052:
#   - topology: DEPLOY_PREFLIGHT, RUN_PREFLIGHT_TESTS and PROMOTE_RELEASE in the
#     preflight stage namespace, BUILD_PREFLIGHT_TESTS in the build stage
#     namespace; the chain and its gates (each request after every other task);
#     credentials by boundary (no source key in preflight, no GitOps key in the
#     build); BUILD only for the test-image build, assigned by the TriggerTemplate
#   - the real step scripts against stubs: the stage request and its handoff
#     (and the awaited BUILD_PREFLIGHT_TESTS result), Flux, the rollout, the
#     test Job and the digest it ran, the release tag (created, adopted, never
#     moved) and the GHCR digest check
#   - GitOps edits with the real kustomize (pinned alpine/k8s image, Docker)
#
# usage: test/run.sh
# shellcheck disable=SC2016  # bash -c test snippets are single-quoted on purpose
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
P=$ROOT/.pathops/tekton
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
PASSED=0
FAILED=0
SKIPPED=0
ok() {
  PASSED=$((PASSED + 1))
  printf 'PASS %s\n' "$1"
}
ko() {
  FAILED=$((FAILED + 1))
  printf 'FAIL %s\n' "$1"
}
expect() { # description command...
  local d=$1
  shift
  if "$@"; then ok "$d"; else ko "$d"; fi
}
K8S_IMAGE=docker.io/alpine/k8s:1.36.5@sha256:094adf64cdc4827377cdbe7ea5747472ce115f9fbc64a4e35970ec66777f9a00
ZOT=zot-test.example
COMMIT=52a965a1b2c3e4f56789abcdef0123456789abcd
REV=52a965a1b2c3
D1=sha256:$(printf '1%.0s' $(seq 64))
D2=sha256:$(printf '2%.0s' $(seq 64))
export ZOT COMMIT REV D1 D2

# ------------------------------------------------------------------ topology

cat >"$T/defs.py" <<'DEFS'
import glob, json, re, sys, yaml
root = sys.argv[1]
docs = [d for f in sorted(glob.glob(root + "/*/*.yaml")) for d in yaml.safe_load_all(open(f)) if d]
pl = {d["metadata"]["name"].replace("tenant-control-plane-", ""): d for d in docs if d["kind"] == "Pipeline"}
tasks = {d["metadata"]["name"]: d for d in docs if d["kind"] in ("Task", "StepAction")}
tt = {d["metadata"]["name"].replace("tenant-control-plane-", ""): d for d in docs if d["kind"] == "TriggerTemplate"}
def t(n): return {x["name"]: x for x in pl[n]["spec"]["tasks"]}
def params(x): return {p["name"]: p["value"] for p in x.get("params", [])}
def deps(n):
    ts = t(n)
    d = {k: set(v.get("runAfter", [])) | set(re.findall(r"\$\(tasks\.([a-z0-9-]+)\.results", json.dumps(v))) for k, v in ts.items()}
    def anc(k, seen):
        for x in d[k]:
            if x not in seen:
                seen.add(x); anc(x, seen)
        return seen
    return lambda k: anc(k, set())
DEFS
pycheck() { # description python-body
  expect "$1" python3 -c "import sys; sys.path.insert(0, '$T'); sys.argv = ['x', '$P']; from defs import *; $2"
}
pycheck "topology: four pipelines, each in its stage namespace (BUILD_PREFLIGHT_TESTS in the build stage); no production" '
ns = {n: d["metadata"]["namespace"] for n, d in pl.items()}
p = "pathops-tenant-control-plane-tekton-"
assert ns == {"deploy-preflight": p + "preflight", "run-preflight-tests": p + "preflight", "promote-release": p + "preflight",
              "build-preflight-tests": p + "build"}, ns
import glob
for f in glob.glob(sys.argv[1] + "/*/*.yaml"):
    code = "\n".join(l for l in open(f).read().splitlines() if not l.lstrip().startswith("#"))
    assert "production" not in code.replace("PRODUCTION_GITOPS", ""), f
'
pycheck "chain: DEPLOY_PREFLIGHT -> RUN_PREFLIGHT_TESTS -> PROMOTE_RELEASE, each request after every other task of its pipeline" '
for n, ev in (("deploy-preflight", "run-preflight-tests"), ("run-preflight-tests", "promote-release")):
    ts = t(n); last = [k for k, v in ts.items() if v["taskRef"]["name"] == "request-stage" and params(v).get("WAIT", "false") != "true"]
    assert len(last) == 1 and params(ts[last[0]])["EVENT"] == ev, (n, last)
    assert deps(n)(last[0]) == set(ts) - {last[0]}, (n, deps(n)(last[0]))
    assert params(ts[last[0]])["PIPELINE"] == "tenant-control-plane-" + ev
assert "request-stage" not in [v["taskRef"]["name"] for v in pl["promote-release"]["spec"]["tasks"]]
'
pycheck "RUN_PREFLIGHT_TESTS: requests BUILD_PREFLIGHT_TESTS and waits for its digest, writes the Job with it, waits for the real Job, promotes only after" '
ts = t("run-preflight-tests")
b = params(ts["build-tests"])
assert b["EVENT"] == "build-preflight-tests" and b["WAIT"] == "true" and b["RESULT"] == "tests-digest" and b["TOKEN_SECRET"] == "tenant-cp-build-trigger"
assert b["NAMESPACE"] == "pathops-tenant-control-plane-tekton-build" and b["PIPELINE"] == "tenant-control-plane-build-preflight-tests"
assert params(ts["prepare-tests"])["TESTS_DIGEST"] == params(ts["wait-tests"])["TESTS_DIGEST"] == "$(tasks.build-tests.results.VALUE)"
assert ts["wait-tests"]["runAfter"] == ["flux-reconcile"] and "build-tests" in deps("run-preflight-tests")("prepare-tests")
r = params(ts["request-promote-release"])
assert r["TESTS_DIGEST"] == "$(tasks.build-tests.results.VALUE)" and r["GITOPS_COMMIT"] == "$(tasks.prepare-tests.results.GITOPS_COMMIT)"
'
pycheck "BUILD_PREFLIGHT_TESTS: one BUILD Task (no clone-source) clones and builds the test image of the candidate commit (HEAD must match); returns the digest" '
ts = t("build-preflight-tests")
assert [v["taskRef"]["name"] for v in pl["build-preflight-tests"]["spec"]["tasks"]] == ["build-preflight-tests"]
b = params(ts["build-preflight-tests"])
assert b == {"COMMIT": "$(params.commit)", "IMAGE_REVISION": "$(params.revision)"}
assert {"name": "source-head", "value": "$(tasks.build-preflight-tests.results.SOURCE_HEAD)"} in pl["build-preflight-tests"]["spec"]["results"]
assert "clone-source" not in json.dumps(pl) + json.dumps(tasks) + json.dumps(tt)
assert {"name": "tests-digest", "value": "$(tasks.build-preflight-tests.results.DIGEST)"} in pl["build-preflight-tests"]["spec"]["results"]
d = tasks["build-preflight-tests"]["spec"]
assert {p["name"]: p.get("default") for p in d["params"]}["DOCKERFILE"] == "test/integration/Dockerfile"
assert {p["name"]: p.get("default") for p in d["params"]}["REPO"] == "pathops/tenant-control-plane-integration-tests"
'
pycheck "execution roles: BUILD only for build-preflight-tests (placement, hostUsers=false, test-build identity); every preflight pipeline GENERAL" '
b = tt["build-preflight-tests"]["spec"]["resourcetemplates"][0]["spec"]
assert b["taskRunTemplate"]["serviceAccountName"] == "tenant-control-plane-ci" and len(b["taskRunSpecs"]) == 1
r = b["taskRunSpecs"][0]
assert r["pipelineTaskName"] == "build-preflight-tests" and r["serviceAccountName"] == "tenant-control-plane-test-build"
assert r["podTemplate"]["nodeSelector"] == {"pathops.io/node-role": "build"} and r["podTemplate"]["hostUsers"] is False
for n in ("deploy-preflight", "run-preflight-tests", "promote-release"):
    s = tt[n]["spec"]["resourcetemplates"][0]["spec"]
    assert "taskRunSpecs" not in s and s["taskRunTemplate"]["serviceAccountName"] == "tenant-control-plane-preflight", n
'
pycheck "credentials by boundary: preflight Tasks use only the GitOps write key; the test-image build only the source key; no registry or GHCR credential" '
pre = {x["taskRef"]["name"] for n in ("deploy-preflight", "run-preflight-tests", "promote-release") for x in pl[n]["spec"]["tasks"]}
for n in pre | {"clone-gitops", "push-gitops"}:
    s = json.dumps(tasks[n])
    assert "tenant-cp-source-read" not in s and "serviceAccountToken\": {\"audience" not in s, n
b = json.dumps(tasks["build-preflight-tests"])
assert "tenant-cp-gitops" not in b and "tenant-cp-source-read" in b
assert not any("ghcr" in json.dumps(tasks[n]).lower() and ("login" in json.dumps(tasks[n]) or "password" in json.dumps(tasks[n]).lower()) for n in tasks)
'
pycheck "GitOps changes clone current HEAD (no revision received) through the CLONE_GITOPS and PUSH_GITOPS StepActions" '
for n in ("update-image", "prepare-preflight-tests", "promote-release"):
    refs = [s["ref"]["name"] for s in tasks[n]["spec"]["steps"] if "ref" in s]
    assert "clone-gitops" in refs, n
s = tasks["clone-gitops"]["spec"]["script"]
assert "--branch main" in s and "checkout" not in s
assert "push --quiet origin HEAD:main" in tasks["push-gitops"]["spec"]["script"] and "--force" not in tasks["push-gitops"]["spec"]["script"]
'
expect "triggers: each stage event verifies its token and validates the body (revision, commit, digests, job)" \
  python3 -c '
import sys, yaml
docs = list(yaml.safe_load_all(open(sys.argv[1] + "/triggers/preflight.yaml")))
el = [d for d in docs if d["kind"] == "EventListener"][0]
assert [t["name"] for t in el["spec"]["triggers"]] == ["deploy-preflight", "run-preflight-tests", "promote-release"]
for tr in el["spec"]["triggers"]:
    g, c = tr["interceptors"]
    assert g["ref"]["name"] == "gitlab" and g["params"][0]["value"] == {"secretName": "tenant-cp-preflight-trigger", "secretKey": "token"}
    assert g["params"][1]["value"] == [tr["name"]] and "body.digest.matches" in c["params"][0]["value"]
assert "body.testsDigest.matches" in el["spec"]["triggers"][2]["interceptors"][1]["params"][0]["value"]
tr = [d for d in docs if d["kind"] == "Trigger"][0]
assert tr["metadata"]["labels"] == {"pathops.io/event-listener": "tenant-control-plane-build"}
assert tr["spec"]["interceptors"][0]["params"][0]["value"] == {"secretName": "tenant-cp-build-trigger", "secretKey": "token"}
' "$P"

# ------------------------------------------------------------------ step scripts against stubs

A="$T/run"
mkdir -p "$A/results" "$A/bin"
cat >"$A/extract.py" <<'EXTRACT'
import re, sys, yaml
f, step = sys.argv[1:3]
d = yaml.safe_load(open(f))
s = next(x["script"] for x in d["spec"]["steps"] if x.get("name") == step) if step != "-" else d["spec"]["script"]
s = s.replace("${ZOT_HOST}", "zot-test.example").replace("${CONTROL_PLANE_HOST}", "cp-test.example")
s = re.sub(r"\$\(params\.([A-Z_]+)\)", r"${P_\1}", s)
s = re.sub(r"\$\((?:step\.)?results\.([A-Z_]+)\.path\)", r"$R/\1", s)
print(s)
EXTRACT
step() { python3 "$A/extract.py" "$P/tasks/$1.yaml" "$2" >"$A/$1.$2.sh"; }
export CALLS="$A/calls"

# --- request-stage: token in a header file, 202 required, the handoff, and WAIT
step request-stage request
mkdir -p "$A/token" "$A/api"
printf 's3cr3t-token' >"$A/token/token"
printf 'api-t0ken' >"$A/api/token"
: >"$A/api/ca.crt"
sed -i "s#/pathops/token/token#$A/token/token#; s#/pathops/api/#$A/api/#g; s#/tmp/headers#$A/headers#; s#/tmp/api-headers#$A/api-headers#; s#/tmp/response#$A/response#; s#/tmp/runs#$A/runs#; s#/tmp/run\\b#$A/run#g; s#sleep [25]#sleep 0#g" \
  "$A/request-stage.request.sh"
mkdir -p "$A/reqbin"
cat >"$A/reqbin/curl" <<'STUB_EL'
#!/usr/bin/env bash
echo "curl $*" >>"$CALLS"
out=/dev/null url=
while [ $# -gt 0 ]; do case $1 in -o) out=$2; shift ;; -H | --cacert | -w | --data) shift ;; -*) ;; *) url=$1 ;; esac; shift; done
run() { printf '{"metadata":{"name":"%s"},"spec":{"pipelineRef":{"name":"%s"},"params":[{"name":"commit","value":"%s"},{"name":"revision","value":"%s"}]}}' "$1" "${2:-tenant-control-plane-deploy-preflight}" "${3:-$COMMIT}" "$REV"; }
case $url in
  http://el.example:8080)
    printf '{"eventListener":"x","eventID":"%s"}' "${EVENT_ID-0f4c2d1e-1111-4222-8333-944455556666}" >"$out"
    printf '%s' "${EL_STATUS:-202}" ;;
  https://kubernetes.default.svc/*/pipelineruns\?*)
    echo "$url" | grep -q "triggers-eventid%3D0f4c2d1e-1111-4222-8333-944455556666$" || { printf '{"items":[]}' >"$out"; printf 200; exit 0; }
    case ${RUNS:-one} in
      one) items=$(run deploy-preflight-abcde) ;;
      none) items= ;;
      two) items="$(run deploy-preflight-abcde),$(run deploy-preflight-fghij)" ;;
      wrong-pipeline) items=$(run x tenant-control-plane-run-preflight-tests) ;;
      wrong-commit) items=$(run x tenant-control-plane-deploy-preflight ffffffffffffffffffffffffffffffffffffffff) ;;
      api-error) printf '{"message":"forbidden"}' >"$out"; printf 403; exit 0 ;;
    esac
    printf '{"items":[%s]}' "$items" >"$out"; printf 200 ;;
  https://kubernetes.default.svc/*/pipelineruns/deploy-preflight-abcde)
    n=$(grep -c "pipelineruns/deploy-preflight-abcde" "$CALLS")
    if [ "$n" -lt 2 ]; then printf '{"status":{"conditions":[{"type":"Succeeded","status":"Unknown"}]}}' >"$out"
    elif [ "${REMOTE:-ok}" = ok ]; then printf '{"status":{"conditions":[{"type":"Succeeded","status":"True"}],"results":[{"name":"tests-digest","value":"%s"}]}}' "$D2" >"$out"
    else printf '{"status":{"conditions":[{"type":"Succeeded","status":"False","reason":"Failed","message":"build failed"}]}}' >"$out"; fi
    printf 200 ;;
esac
STUB_EL
chmod +x "$A/reqbin/curl"
cat >"$A/request" <<REQUEST
#!/usr/bin/env bash
: >"$A/calls"
rm -f "$A/results/RUN" "$A/results/VALUE"
env P_URL=http://el.example:8080 P_EVENT=deploy-preflight P_TOKEN_SECRET=x P_COMMIT=$COMMIT P_IMAGE_REVISION=$REV P_DIGEST=$D1 \\
  P_TESTS_DIGEST= P_GITOPS_COMMIT= P_TEST_JOB= P_HEALTH_PATH=/healthz P_NAMESPACE=pathops-tenant-control-plane-tekton-preflight \\
  P_PIPELINE=tenant-control-plane-deploy-preflight P_HANDOFF_TIMEOUT=3 P_WAIT=false P_WAIT_TIMEOUT=30 P_RESULT= R="$A/results" \\
  PATH="$A/reqbin:\$PATH" "\$@" bash "$A/request-stage.request.sh" 2>&1
REQUEST
chmod +x "$A/request"
PATH="$A:$PATH"
expect "request-stage: 202 and exactly one PipelineRun of that event, pipeline, commit and revision -> handoff confirmed" \
  bash -c 'out=$(request) && grep -q "event 0f4c2d1e-1111-4222-8333-944455556666 -> PipelineRun deploy-preflight-abcde" <<<"$out" && [ "$(cat "$1/results/RUN")" = deploy-preflight-abcde ]' _ "$A"
expect "request-stage: the body carries the candidate (commit, revision, digest)" \
  bash -c 'request >/dev/null; grep -q "\"digest\":\"$1\"" "$2/calls" || grep -q "$1" "$2/calls"' _ "$D1" "$A"
expect "request-stage: 202 without a PipelineRun (interceptor rejected) fails after the handoff timeout" \
  bash -c 'out=$(request RUNS=none); [ $? -ne 0 ] && grep -q "but no PipelineRun appeared" <<<"$out"'
expect "request-stage: a non-202 answer, two runs, another pipeline or commit, or an unreadable namespace fail" \
  bash -c 'for k in EL_STATUS=401 RUNS=two RUNS=wrong-pipeline RUNS=wrong-commit RUNS=api-error EVENT_ID=; do out=$(request $k); [ $? -ne 0 ] || exit 1; done'
expect "request-stage WAIT: waits for the requested run to succeed and returns its result" \
  bash -c 'out=$(request P_WAIT=true P_RESULT=tests-digest) && [ "$(cat "$1/results/VALUE")" = "$2" ] && grep -q "succeeded: tests-digest=$2" <<<"$out"' _ "$A" "$D2"
expect "request-stage WAIT: a failed requested run fails the request (no result)" \
  bash -c 'out=$(request P_WAIT=true P_RESULT=tests-digest REMOTE=failed); [ $? -ne 0 ] && grep -q "deploy-preflight-abcde failed: Failed: build failed" <<<"$out"'
expect "request-stage: the stage token and the API token travel in header files, never as arguments" \
  bash -c 'request >/dev/null; ! grep -qE "s3cr3t-token|api-t0ken" "$1/calls" && grep -qx "X-Gitlab-Token: s3cr3t-token" "$1/headers"' _ "$A"

# --- flux-reconcile, verify-rollout, wait-preflight-tests against a stub kubectl
mkdir -p "$A/kbin"
cat >"$A/kbin/kubectl" <<'STUB_KUBECTL'
#!/usr/bin/env bash
echo "kubectl $*" >>"$CALLS"
n=$(cat "$STATE.count" 2>/dev/null || echo 0); echo $((n + 1)) >"$STATE.count"
case "$*" in
  *annotate*) ;;
  *"get kustomization/"*) cat "$STATE.kustomization" ;;
  *"rollout status"*) [ -z "${ROLLOUT_FAIL:-}" ] ;;
  *"get pods -l job-name="*) printf '%s' "${JOB_IMAGE_ID:-zot/tests@$D2}" ;;
  *"get pods"*) cat "$STATE.pods" ;;
  *"get job "*) [ "$n" -ge "${JOB_APPEARS_AFTER:-0}" ] || exit 1; cat "$STATE.job" ;;
  *"logs job/"*) echo "--- FAIL: TestHealthz" ;;
esac
STUB_KUBECTL
chmod +x "$A/kbin/kubectl"
export STATE="$A/state"
step flux-reconcile reconcile
sed -i 's/sleep 5/sleep 0/' "$A/flux-reconcile.reconcile.sh"
expect "flux-reconcile: requests a reconcile and waits until Flux applied the GitOps commit; a commit never applied fails" \
  bash -c 'printf "{\"status\":{\"lastAppliedRevision\":\"main@sha1:abc123\",\"conditions\":[{\"type\":\"Ready\",\"status\":\"True\"}]}}" >"$STATE.kustomization"; out=$(P_FLUX_NAMESPACE=f P_GITREPOSITORY=g P_KUSTOMIZATION=k P_GITOPS_COMMIT=abc123 PATH="$1/kbin:$PATH" bash "$1/flux-reconcile.reconcile.sh") && grep -q "Flux applied abc123" <<<"$out" && printf "{\"status\":{\"lastAppliedRevision\":\"main@sha1:old\",\"conditions\":[]}}" >"$STATE.kustomization" && ! P_FLUX_NAMESPACE=f P_GITREPOSITORY=g P_KUSTOMIZATION=k P_GITOPS_COMMIT=abc123 PATH="$1/kbin:$PATH" bash "$1/flux-reconcile.reconcile.sh" >/dev/null 2>&1' _ "$A"
step verify-rollout verify
IMG="$ZOT/pathops/tenant-control-plane:$REV"
pods() { printf '{"items":[{"metadata":{"name":"p"},"spec":{"containers":[{"image":"%s"}]},"status":{"containerStatuses":[{"imageID":"x@%s","ready":%s}]}}]}' "$1" "$2" "$3" >"$STATE.pods"; }
export -f pods
expect "verify-rollout: every Pod runs the candidate tag and digest and is Ready; another revision, digest or an unready Pod fails" \
  bash -c 'v() { P_NAMESPACE=n P_IMAGE=$2 P_DIGEST=$3 P_HEALTH_URL= PATH="$1/kbin:$PATH" bash "$1/verify-rollout.verify.sh" >/dev/null 2>&1; }; pods "$2" "$3" true && v "$1" "$2" "$3" && pods "$2" sha256:bbb true && ! v "$1" "$2" "$3" && pods "$2" "$3" false && ! v "$1" "$2" "$3" && pods "${2%:*}:ffffffffffff" "$3" true && ! v "$1" "$2" "$3"' _ "$A" "$IMG" "$D1"
step wait-preflight-tests wait
sed -i 's/sleep 5/sleep 0/' "$A/wait-preflight-tests.wait.sh"
expect "wait-preflight-tests: waits for Flux to create the Job, requires the test image digest it was given, passes on Complete" \
  bash -c 'rm -f "$STATE.count"; printf "{\"status\":{\"conditions\":[{\"type\":\"Complete\",\"status\":\"True\"}]}}" >"$STATE.job"; out=$(JOB_APPEARS_AFTER=3 P_NAMESPACE=n P_JOB_NAME=j P_TESTS_DIGEST=$2 R=$1/results PATH="$1/kbin:$PATH" bash "$1/wait-preflight-tests.wait.sh") && [ "$(cat "$1/results/STATUS")" = passed ]' _ "$A" "$D2"
expect "wait-preflight-tests: a failed Job, or a Job that ran another test image, fails" \
  bash -c 'printf "{\"status\":{\"conditions\":[{\"type\":\"Failed\",\"status\":\"True\"}]}}" >"$STATE.job"; out=$(P_NAMESPACE=n P_JOB_NAME=j P_TESTS_DIGEST=$2 R=$1/results PATH="$1/kbin:$PATH" bash "$1/wait-preflight-tests.wait.sh"); [ $? -ne 0 ] && grep -q "FAIL: TestHealthz" <<<"$out" && printf "{\"status\":{\"conditions\":[{\"type\":\"Complete\",\"status\":\"True\"}]}}" >"$STATE.job" && out=$(JOB_IMAGE_ID=zot/tests@$3 P_NAMESPACE=n P_JOB_NAME=j P_TESTS_DIGEST=$2 R=$1/results PATH="$1/kbin:$PATH" bash "$1/wait-preflight-tests.wait.sh"); [ $? -ne 0 ] && grep -q "did not run the test image" <<<"$out"' _ "$A" "$D2" "$D1"

# --- build-preflight-tests clone: the current source HEAD must be the candidate's commit
step build-preflight-tests clone
git -c init.defaultBranch=main init -q "$A/source"
git -C "$A/source" -c user.name=t -c user.email=t@t commit -q --allow-empty -m candidate
SRC_HEAD=$(git -C "$A/source" rev-parse HEAD)
mkdir -p "$A/srcbin"
cat >"$A/srcbin/git" <<GIT
#!/usr/bin/env bash
args=()
for a in "\$@"; do case \$a in ssh://*) args+=("file://$A/source") ;; *) args+=("\$a") ;; esac; done
exec $(command -v git) "\${args[@]}"
GIT
printf '#!/usr/bin/env bash\n: # the deploy key copy\n' >"$A/srcbin/install"
chmod +x "$A/srcbin/git" "$A/srcbin/install"
sed -i "s#/work/src#$A/bpt#g; s#/pathops/source-key#$A#g" "$A/build-preflight-tests.clone.sh"
bptclone() { rm -rf "$A/bpt" "$A/results/SOURCE_HEAD"; R=$A/results PATH="$A/srcbin:$PATH" P_SOURCE_REPO=pathops/x P_COMMIT=$1 P_IMAGE_REVISION=${1:0:12} bash "$A/build-preflight-tests.clone.sh" 2>&1; }
export -f bptclone
export A
expect "build-preflight-tests clone: the cloned source HEAD is the candidate's commit -> built; SOURCE_HEAD is the clone's git rev-parse" \
  bash -c 'bptclone "$1" >/dev/null && [ "$(cat "$A/results/SOURCE_HEAD")" = "$1" ] && [ "$(git -C "$A/bpt" rev-parse HEAD)" = "$1" ]' _ "$SRC_HEAD"
expect "build-preflight-tests clone: a source HEAD that advanced past the candidate fails closed; no historical checkout" \
  bash -c 'git -C "$A/source" -c user.name=t -c user.email=t@t commit -q --allow-empty -m newer; new=$(git -C "$A/source" rev-parse HEAD); out=$(bptclone "$1"); [ $? -ne 0 ] && grep -q "source HEAD is $new, not the candidate $1" <<<"$out" && [ "$(cat "$A/results/SOURCE_HEAD")" = "$new" ] && ! grep -Eq "checkout|fetch" "$A/build-preflight-tests.clone.sh"' _ "$SRC_HEAD"

# --- promote-release: the release tag (created, adopted, conflict) and the GHCR digest
step promote-release tag
step promote-release publish
G="$A/gitops"
git -c init.defaultBranch=main init -q --bare "$A/remote.git"
git clone -q "$A/remote.git" "$G" 2>/dev/null
git -C "$G" -c user.name=t -c user.email=t@t commit -q --allow-empty -m tested
GITOPS_COMMIT=$(git -C "$G" rev-parse HEAD)
git -C "$G" push -q origin HEAD:main
export GITOPS_COMMIT
release_json() { # candidate-digest commit
  printf '{"schemaVersion":1,"kind":"TenantControlPlaneRelease","sourceCommit":"%s","imageRevision":"%s","candidate":{"repository":"r","tag":"%s","digest":"%s"},"tests":{"result":"passed"},"release":{"image":"ghcr.io/pathops/pathops-tenant-control-plane","tag":"%s","digest":"%s"}}\n' "$2" "$REV" "$REV" "$1" "$REV" "$1"
}
export -f release_json
sed -i "s#/work/gitops#$G#g; s#/work/release.json#$A/release.json#g; s#/work/adopted#$A/adopted#g; s#/tmp/message#$A/message#g; s#/pathops/key#$A#g; s#/tmp/git-identity#$A/git-identity#g" "$A/promote-release.tag.sh"
: >"$A/identity"
: >"$A/known_hosts"
cat >"$A/tag" <<TAG
#!/usr/bin/env bash
cd "$G" && env P_IMAGE_REVISION=$REV P_GITOPS_COMMIT=$GITOPS_COMMIT GIT_SSH_COMMAND=true "\$@" bash "$A/promote-release.tag.sh" 2>&1
TAG
chmod +x "$A/tag"
expect "promote-release tag: absent -> the annotated tag release/<revision> on the tested GitOps commit, its message the release, pushed" \
  bash -c 'release_json "$D1" "$COMMIT" >"$1/release.json"; out=$(tag) && grep -q "created and pushed release/$REV" <<<"$out" && [ "$(git -C "$1/remote.git" cat-file -t "refs/tags/release/$REV")" = tag ] && [ "$(git -C "$1/remote.git" rev-parse "release/$REV^{commit}")" = "$GITOPS_COMMIT" ] && git -C "$1/remote.git" for-each-ref --format="%(contents)" "refs/tags/release/$REV" | grep -q "\"digest\":\"$D1\"" && [ "$(cat "$1/adopted")" = false ]' _ "$A"
expect "promote-release tag: present for the same candidate -> adopted, nothing pushed" \
  bash -c 'git -C "$1/gitops" fetch -q --tags origin; out=$(tag) && grep -q "already exists for this candidate: adopted" <<<"$out" && [ "$(cat "$1/adopted")" = true ]' _ "$A"
expect "promote-release tag: present for another digest or source -> conflict, the tag never moves" \
  bash -c 'release_json "$D2" "$COMMIT" >"$1/release.json"; out=$(tag); [ $? -ne 0 ] && grep -q "conflict: release/$REV already names" <<<"$out" && git -C "$1/remote.git" for-each-ref --format="%(contents)" "refs/tags/release/$REV" | grep -q "\"digest\":\"$D1\""' _ "$A"
sed -i "s#/work/release.json#$A/release.json#g; s#/work/adopted#$A/adopted#g; s#/tmp/m.json#$A/m.json#g; s#/tmp/h#$A/h#g; s#/tmp/ghcr-auth#$A/ghcr-auth#g; s#sleep 15#sleep 0#" "$A/promote-release.publish.sh"
mkdir -p "$A/ghbin"
cat >"$A/ghbin/curl" <<'GHCR'
#!/usr/bin/env bash
out=/dev/stdout hdr=/dev/null url=
while [ $# -gt 0 ]; do case $1 in -o) out=$2; shift ;; -D) hdr=$2; shift ;; -H | -w) shift ;; -*) ;; *) url=$1 ;; esac; shift; done
case $url in
  *token*) echo '{"token":"anon"}' ;;
  */manifests/*)
    [ -n "${GHCR_MISSING:-}" ] && { printf 404; exit 0; }
    printf '%s' "$MANIFEST" >"$out"
    printf 'docker-content-digest: %s\r\n' "${GHCR_DIGEST:-$MDIGEST}" >"$hdr"
    printf 200 ;;
esac
GHCR
chmod +x "$A/ghbin/curl"
# shellcheck disable=SC2089,SC2090  # a JSON document compared as a string
MANIFEST='{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"digest":"sha256:c0"},"layers":[]}'
MDIGEST="sha256:$(printf '%s' "$MANIFEST" | sha256sum | cut -d' ' -f1)"
# shellcheck disable=SC2090
export MANIFEST MDIGEST
expect "promote-release publish: GHCR serves the tag with exactly the tested digest -> the release result" \
  bash -c 'release_json "$MDIGEST" "$COMMIT" >"$1/release.json"; echo false >"$1/adopted"; out=$(P_RELEASE_IMAGE=ghcr.io/pathops/pathops-tenant-control-plane P_IMAGE_REVISION=$REV P_DIGEST=$MDIGEST P_PUBLISH_TIMEOUT=5 R=$1/results PATH="$1/ghbin:$PATH" bash "$1/promote-release.publish.sh") && grep -q "same digest" <<<"$out" && jq -e ".release.digest == \"$MDIGEST\"" "$1/results/RELEASE" >/dev/null' _ "$A"
expect "promote-release publish: another digest on GHCR, or no tag in time -> no release (digest mismatch fails closed)" \
  bash -c 'rm -f "$1/results/RELEASE"; out=$(GHCR_DIGEST=$D2 P_RELEASE_IMAGE=ghcr.io/pathops/pathops-tenant-control-plane P_IMAGE_REVISION=$REV P_DIGEST=$MDIGEST P_PUBLISH_TIMEOUT=5 R=$1/results PATH="$1/ghbin:$PATH" bash "$1/promote-release.publish.sh"); [ $? -ne 0 ] && grep -q "artifact-integrity" <<<"$out" && [ ! -e "$1/results/RELEASE" ] && out=$(GHCR_MISSING=1 P_RELEASE_IMAGE=ghcr.io/pathops/pathops-tenant-control-plane P_IMAGE_REVISION=$REV P_DIGEST=$MDIGEST P_PUBLISH_TIMEOUT=0 R=$1/results PATH="$1/ghbin:$PATH" bash "$1/promote-release.publish.sh"); [ $? -ne 0 ] && grep -q "does not serve" <<<"$out" && [ ! -e "$1/results/RELEASE" ]' _ "$A"
expect "GitHub workflow: on release/* tags only; the same digest (--preserve-digests), adopt or fail, never move; attests; GITHUB_TOKEN only" \
  python3 -c '
import sys, yaml
w = yaml.safe_load(open(sys.argv[1]))
on = w[True] if True in w else w["on"]
assert on == {"push": {"tags": ["release/*"]}} and w["permissions"] == {}
j = w["jobs"]["publish"]
assert j["permissions"] == {"contents": "read", "packages": "write", "id-token": "write", "attestations": "write"}
s = yaml.safe_dump(j)
assert "--preserve-digests" in s and "a release never moves" in s and "actions/attest@" in s and "secrets." not in s and "password: ${{ github.token }}" in s
' "$ROOT/.github/workflows/promote-release.yml"

# --- GitOps edits with the real kustomize
if command -v docker >/dev/null && { docker image inspect "$K8S_IMAGE" >/dev/null 2>&1 || docker pull -q "$K8S_IMAGE" >/dev/null 2>&1; }; then
  W="$T/w"
  mkdir -p "$W"
  cp "$ROOT"/kustomization.yaml "$ROOT"/deployment.yaml "$ROOT"/service.yaml "$ROOT"/integration-test.yaml "$W/"
  step update-image update
  step prepare-preflight-tests job
  sed -i "s#/work/gitops#/w#; s#/work/message#/w/.message#" "$A/update-image.update.sh" "$A/prepare-preflight-tests.job.sh"
  k8s() { # script env...
    local s=$1
    shift
    local e=(); for v in "$@"; do e+=(-e "$v"); done
    docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$W:/w" -v "$A:/a:ro" -w /w "${e[@]}" "$K8S_IMAGE" sh -c "sh /a/$s && kustomize build ."
  }
  export -f k8s
  export W A K8S_IMAGE
  expect "update-image: sets exactly the candidate tag (real kustomize), the digest only in the message" \
    bash -c 'out=$(k8s update-image.update.sh "P_COMMIT=$COMMIT" "P_IMAGE_REVISION=$REV" "P_DIGEST=$D1" P_PIPELINE_RUN=pr 2>&1) && grep -q "image: $ZOT/pathops/tenant-control-plane:$REV" <<<"$out" && ! grep -q "@sha256" <<<"$out" && grep -q "digest: $D1" "$1/.message"' _ "$W"
  expect "update-image: a revision not derived from the commit, or a non-digest, is rejected" \
    bash -c '! k8s update-image.update.sh "P_COMMIT=$COMMIT" P_IMAGE_REVISION=ffffffffffff "P_DIGEST=$D1" P_PIPELINE_RUN=pr >/dev/null 2>&1 && ! k8s update-image.update.sh "P_COMMIT=$COMMIT" "P_IMAGE_REVISION=$REV" P_DIGEST=latest P_PIPELINE_RUN=pr >/dev/null 2>&1'
  expect "prepare-preflight-tests: a fresh Job with the test image of the revision, its digest annotated, the Cell login Secret and CA; listed once" \
    bash -c 'out=$(k8s prepare-preflight-tests.job.sh "P_COMMIT=$COMMIT" "P_IMAGE_REVISION=$REV" "P_TESTS_DIGEST=$D2" P_JOB_NAME=tenant-control-plane-run-preflight-tests-abcde P_TARGET_URL=http://svc:8080 P_HEALTH_PATH=/healthz P_PIPELINE_RUN=pr 2>&1) && grep -q "name: tenant-control-plane-run-preflight-tests-abcde" <<<"$out" && grep -q "image: $ZOT/pathops/tenant-control-plane-integration-tests:$REV" <<<"$out" && grep -q "pathops.io/tests-digest: $D2" <<<"$out" && grep -q "name: tenant-cp-preflight-login" <<<"$out" && grep -q "automountServiceAccountToken: false" <<<"$out" && [ "$(grep -c "^- integration-test.yaml$" "$1/kustomization.yaml")" = 1 ]' _ "$W"
else
  SKIPPED=$((SKIPPED + 3))
  echo "SKIP GitOps edits (no Docker or $K8S_IMAGE): 3 checks"
fi

expect "desired state: renders into the preflight namespace with the candidate tag" \
  bash -c 'out=$(kubectl kustomize "$1") && grep -q "namespace: pathops-tenant-control-plane-preflight" <<<"$out" && grep -qE "image: zot-dev.demo.pathops.io/pathops/tenant-control-plane:[0-9a-f]{12}$" <<<"$out"' _ "$ROOT"

printf '\n%d passed, %d failed, %d skipped\n' "$PASSED" "$FAILED" "$SKIPPED"
[ "$FAILED" -eq 0 ]
