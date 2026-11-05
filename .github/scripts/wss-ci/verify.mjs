import {createHash} from 'node:crypto';

export const CORE = 'cwru-non-academic/WSSCore';
export const TARGETS = ['csharp-wrapper','csharp-cli','unity-wrapper','unity-gui','python-wrapper','python-cli','python-ros','matlab-wrapper','matlab-cli'];
export const CORE_JOBS = ['Build macOS universal BLE bridge','Core conformance','Build and validate artifacts',
  'BLE consumer (Linux)','BLE consumer (Windows)','BLE consumer (macOS arm64)','BLE consumer (macOS x86_64)',
  'BLE Consumer for Windows','BLE Consumer for Linux','BLE Consumer for Mac',
  ...['Serial','Core'].flatMap(x => ['Linux','Windows','macOS'].map(p => `${x} consumer (${p})`)),
  'Start routine downstream validation'];
export const canonical = value => JSON.stringify(sort(value));
function sort(value) {
  if (Array.isArray(value)) return value.map(sort);
  if (value && typeof value === 'object') return Object.fromEntries(Object.keys(value).sort().map(k => [k,sort(value[k])]));
  return value;
}
export const digest = value => createHash('sha256').update(canonical(value)).digest('hex');
export const bytesDigest = value => createHash('sha256').update(value).digest('hex');
export function requireThat(condition, message) { if (!condition) throw new Error(message); }
const same = (a,b) => canonical(a) === canonical(b);
const sha = value => typeof value === 'string' && /^[a-f0-9]{40}$/.test(value);
const hash = value => typeof value === 'string' && /^[a-f0-9]{64}$/.test(value);
const id = value => typeof value === 'string' && /^[1-9][0-9]*$/.test(value);
export function candidate(c) {
  requireThat(c && same(Object.keys(c).sort(), ['repository','commit','run_id','artifact_id','archive','sha256'].sort()), 'Candidate must have exactly six fields');
  requireThat(c.repository === CORE && sha(c.commit) && id(c.run_id) && id(c.artifact_id) && c.archive === 'WSS-Universal-ci.zip' && hash(c.sha256), 'Invalid canonical dev candidate');
}
export function manifest(m) {
  requireThat(m.schema === 'wss-required-targets/v1' && m.channel === 'dev' && m.release_kind === 'beta' && m.stable_enabled === false, 'Only dev beta policy is enabled');
  requireThat(same(m.targets.map(t => t.id).sort(), [...TARGETS].sort()), 'Required target set must be exact and unique');
  requireThat(Array.isArray(m.excluded) && m.excluded.length === 0, 'All nine targets are required; no exclusions are allowed');
  requireThat(new Set(m.targets.map(t => t.repository)).size === TARGETS.length, 'Target repositories must be unique');
  for (const t of m.targets) {
    requireThat(/^cwru-non-academic\/[A-Za-z0-9_]+$/.test(t.repository) && t.branch === 'dev', `Invalid target ${t.id}`);
    requireThat(t.workflow.startsWith('.github/workflows/') && t.workflow.endsWith('.yml'), 'Invalid normal CI workflow');
    requireThat(t.jobs.length > 0 && new Set(t.jobs).size === t.jobs.length && t.jobs.every(x => typeof x === 'string' && x.length > 0), 'Missing or duplicate required jobs');
    requireThat(t.trusted_paths.includes('.github/workflows/release-receipt.yml') && t.trusted_paths.includes('.github/scripts') && t.trusted_paths.includes(t.workflow), 'Receipt workflow, normal CI and validator scripts must be frozen');
    requireThat(t.trusted_paths.every(x => !x.includes('..') && !x.startsWith('/')), 'Invalid trusted path');
    requireThat(Object.keys(t.parents).every(p => TARGETS.includes(p) && p !== t.id), 'Unknown parent');
  }
}
export function plan(p) {
  requireThat(p.schema === 'wss-propagation-plan/v1' && p.channel === 'dev', 'Unsupported plan');
  candidate(p.candidate); manifest(p.manifest);
  requireThat(p.manifest_sha256 === digest(p.manifest), 'Manifest digest mismatch');
  const {plan_id,...body} = p;
  requireThat(hash(plan_id) && digest(body) === plan_id, 'Plan ID mismatch');
  requireThat(same(Object.keys(p.target_snapshots).sort(), [...TARGETS].sort()), 'Missing/extra target snapshots');
  for (const t of p.manifest.targets) {
    const s = p.target_snapshots[t.id];
    requireThat(sha(s.head_sha) && same(Object.keys(s.trusted).sort(), [...t.trusted_paths].sort()) && Object.values(s.trusted).every(sha), `Invalid snapshot ${t.id}`);
  }
  return p;
}
export function jobs(actual, required) {
  requireThat(Array.isArray(actual), 'Missing job evidence');
  for (const name of required) {
    const matches = actual.filter(j => j.name === name);
    requireThat(matches.length === 1 && matches[0].status === 'completed' && matches[0].conclusion === 'success', `Required unique successful job missing: ${name}`);
  }
}
function run(r, repository, workflow, attempt) {
  requireThat(r.repository?.full_name === repository && r.path === workflow && r.status === 'completed' && r.conclusion === 'success', 'Run repository/workflow/status mismatch');
  requireThat(Number.isSafeInteger(r.run_attempt) && r.run_attempt >= 1 && r.run_attempt === attempt, 'Run attempt mismatch');
  requireThat(r.head_repository?.full_name === repository, 'Fork run is ineligible');
}
export function producer(p, evidence) {
  const c = p.candidate, r = evidence.run;
  run(r, CORE, '.github/workflows/artifacts.yml', r.run_attempt);
  requireThat(String(r.id) === c.run_id && r.head_sha === c.commit && r.head_branch === 'dev' && r.event === 'push', 'Producer must be exact dev push');
  requireThat(evidence.current_head === c.commit, 'Core dev moved: candidate is stale');
  jobs(evidence.jobs, CORE_JOBS);
  const a = evidence.artifact;
  requireThat(String(a.id) === c.artifact_id && a.name === 'universal-release-assets' && a.expired === false && String(a.workflow_run?.id) === c.run_id && a.workflow_run?.head_sha === c.commit, 'Producer artifact mismatch/expired');
  requireThat(evidence.archive_sha256 === c.sha256, 'Accepted archive bytes mismatch');
}
export function receipt(p, t, r, e) {
  requireThat(r.schema === 'wss-acceptance-receipt/v1' && r.plan_id === p.plan_id && r.channel === 'dev' && r.target_id === t.id && same(r.candidate,p.candidate), 'Receipt candidate/plan/target mismatch');
  requireThat(r.mode === 'merged-pr', 'No-op equivalence is not yet eligible for publication');
  requireThat(id(r.merge?.pr_number) && sha(r.merge.sha) && sha(r.merge.head_sha), 'Missing actual merge identity');
  const pr = e.pr;
  requireThat(String(pr.number) === r.merge.pr_number && pr.merged === true && pr.state === 'closed' && pr.merge_commit_sha === r.merge.sha && pr.head?.sha === r.merge.head_sha, 'PR was not merged at declared commit');
  requireThat(pr.merged_by?.type === 'User', 'Required dependency merge must be performed by a human');
  requireThat(pr.user?.type === 'Bot', 'V1 acceptance requires an actual automated dependency PR, never a human migration');
  requireThat(pr.base?.ref === 'dev' && pr.base?.repo?.full_name === t.repository && pr.head?.repo?.full_name === t.repository, 'Wrong branch or fork PR');
  requireThat(e.current_head === r.merge.sha, 'Accepted target branch has moved');
  requireThat(e.merge_tree === e.tested_tree, 'Normal CI tested a different merged tree');
  requireThat(same(e.trusted,p.target_snapshots[t.id].trusted), 'Receipt validator code changed after plan freeze');
  requireThat(id(r.normal_ci?.run_id) && Number.isSafeInteger(r.normal_ci.attempt), 'Missing normal CI identity');
  const n = e.normal_run;
  requireThat(e.normal_latest_run_id === String(n.id), 'A newer normal CI run supersedes receipt');
  run(n,t.repository,t.workflow,r.normal_ci.attempt);
  requireThat(String(n.id) === r.normal_ci.run_id && ['push','workflow_dispatch'].includes(n.event), 'Release requires post-merge normal CI, never synthetic PR checkout');
  requireThat(n.head_sha === r.merge.sha && n.head_branch === 'dev', 'Normal CI did not test actual merged dev');
  jobs(e.normal_jobs,t.jobs);
  requireThat(same(Object.keys(r.parents || {}).sort(),Object.keys(t.parents).sort()) && same(r.parents,e.parent_gitlinks), 'Dependency pins do not match receipt');
  requireThat(same([...(r.coverage || [])].sort(),[...t.coverage].sort()), 'Coverage declaration mismatch');
  requireThat(id(r.emitter?.run_id) && sha(r.emitter.source_sha) && r.emitter.source_sha === r.merge.sha && r.emitter.workflow === '.github/workflows/release-receipt.yml', 'Invalid receipt emitter');
  const emitter = e.emitter_run;
  run(emitter,t.repository,r.emitter.workflow,r.emitter.attempt);
  requireThat(String(emitter.id) === r.emitter.run_id && emitter.head_branch === 'dev', 'Emitter identity/branch mismatch');
  requireThat(emitter.event === 'workflow_dispatch' && emitter.head_sha === r.merge.sha, 'Receipt emitter must dispatch at actual accepted merge');
  const artifact = e.artifact;
  requireThat(id(String(artifact.id)) && artifact.name === `wss-acceptance-${t.id}-${p.plan_id}-a${r.emitter.attempt}` && artifact.expired === false && String(artifact.workflow_run?.id) === r.emitter.run_id && artifact.workflow_run?.head_sha === emitter.head_sha, 'Receipt artifact not bound to successful emitter');
  requireThat(e.receipt_sha256 === bytesDigest(e.receipt_bytes) && same(JSON.parse(e.receipt_bytes.toString('utf8')),r), 'Receipt downloaded bytes mismatch');
  requireThat(Array.isArray(r.preflights) && r.preflights.length > 0 && e.preflights.length === r.preflights.length, 'Missing preflight evidence');
  for (let i=0;i<r.preflights.length;i++) {
    const declared = r.preflights[i], actual = e.preflights[i];
    requireThat(p.manifest.targets.some(x => x.repository === declared.repository) && id(declared.run_id) && sha(declared.source_sha) && declared.workflow === '.github/workflows/wss-preflight.yml', 'Invalid preflight descriptor');
    const sourceTarget = p.manifest.targets.find(x => x.repository === declared.repository);
    requireThat(declared.source_sha === p.target_snapshots[sourceTarget.id].head_sha, 'Preflight source differs from frozen target snapshot');
    run(actual.run,declared.repository,declared.workflow,actual.run.run_attempt);
    requireThat(String(actual.run.id) === declared.run_id && actual.run.head_sha === declared.source_sha && actual.run.event === 'workflow_dispatch' && same(actual.candidate,p.candidate), 'Preflight run/candidate mismatch');
  }
}
export function allClear(p, evidence) {
  plan(p); producer(p,evidence.producer);
  requireThat(same(Object.keys(evidence.targets).sort(),[...TARGETS].sort()), 'Missing/extra acceptance evidence');
  for (const t of p.manifest.targets) receipt(p,t,evidence.targets[t.id].receipt,evidence.targets[t.id]);
  for (const t of p.manifest.targets) for (const parent of Object.keys(t.parents)) {
    requireThat(evidence.targets[t.id].receipt.parents[parent] === evidence.targets[parent].receipt.merge.sha, 'Parent is not accepted exact wrapper merge');
  }
  return {schema:'wss-release-acceptance/v1',channel:'dev',kind:'beta',plan_id:p.plan_id,
    manifest_sha256:p.manifest_sha256,candidate:p.candidate,targets:Object.fromEntries(p.manifest.targets.map(t => [t.id,{
      repository:t.repository,merge:evidence.targets[t.id].receipt.merge,normal_ci:evidence.targets[t.id].receipt.normal_ci,
      preflights:evidence.targets[t.id].receipt.preflights,parents:evidence.targets[t.id].receipt.parents,
      emitter:evidence.targets[t.id].receipt.emitter,receipt_artifact_id:String(evidence.targets[t.id].artifact.id),
      receipt_sha256:evidence.targets[t.id].receipt_sha256,coverage:t.coverage
    }])),excluded:p.manifest.excluded};
}
