// Versioned local-workflow settings evidence; never execute selected test code here.
import {canonical,digest,bytesDigest,CORE,requireThat} from './verify.mjs';
import {TEST_VARIABLES} from './test-selection-contract.mjs';
const sha=x=>typeof x==='string'&&/^[a-f0-9]{40}$/.test(x);
const hash=x=>typeof x==='string'&&/^[a-f0-9]{64}$/.test(x);
const decimal=x=>typeof x==='string'&&/^[1-9][0-9]*$/.test(x);
const repo=x=>typeof x==='string'&&/^[A-Za-z0-9_-]+\/[A-Za-z0-9_.-]+$/.test(x)&&!x.includes('..');
const same=(a,b)=>canonical(a)===canonical(b);
const keys=(x,k)=>x&&typeof x==='object'&&!Array.isArray(x)&&same(Object.keys(x).sort(),[...k].sort());
export const SNAPSHOT_WORKFLOW='.github/workflows/test-variable-snapshot.yml';
export const SNAPSHOT_JOB='Capture effective test variables';
export function normalizeEffectiveTestVariables(values) {
  requireThat(values&&typeof values==='object'&&!Array.isArray(values),'Missing local settings');
  const flag=values[TEST_VARIABLES.enabled]===undefined?'':values[TEST_VARIABLES.enabled];
  requireThat(['','false','true'].includes(flag),'WSS_USE_PIN_TESTS must be exactly true, false or empty');
  if(flag!=='true')return {[TEST_VARIABLES.enabled]:'false'};
  requireThat(repo(values[TEST_VARIABLES.repository])&&sha(values[TEST_VARIABLES.commit]),'Enabled pin requires repository and full lowercase commit');
  return Object.fromEntries(Object.values(TEST_VARIABLES).map(k=>[k,values[k]]));
}
export function validateSnapshotRequest(r) {
  requireThat(keys(r,['schema','channel','producer','target','source','nonce','request_id'])&&r.schema==='wss-local-test-variable-request/v1','Invalid snapshot request schema');
  const {request_id,...body}=r;
  requireThat(hash(request_id)&&digest(body)===request_id&&hash(r.nonce),'Invalid snapshot request digest/nonce');
  requireThat(['dev','main'].includes(r.channel),'Invalid snapshot channel');
  requireThat(keys(r.producer,['repository','commit','run_id','attempt'])&&r.producer.repository===CORE&&sha(r.producer.commit)&&decimal(r.producer.run_id)&&r.producer.attempt===1,'Invalid snapshot producer');
  requireThat(keys(r.target,['id','repository'])&&/^[a-z][a-z0-9-]*$/.test(r.target.id)&&repo(r.target.repository),'Invalid snapshot target');
  requireThat(keys(r.source,['ref','commit','reviewed_commit','workflow','workflow_blob','tooling_tree','actor_id'])&&r.source.ref===`refs/heads/${r.channel}`&&sha(r.source.commit)&&sha(r.source.reviewed_commit)&&sha(r.source.tooling_tree)&&sha(r.source.workflow_blob)&&r.source.workflow===SNAPSHOT_WORKFLOW&&decimal(r.source.actor_id),'Unreviewed snapshot source');
  return r;
}
export function createSnapshotRequest(body) {
  return validateSnapshotRequest({...body,request_id:digest(body)});
}
export const snapshotName=r=>`wss-test-variables-${validateSnapshotRequest(r).request_id}`;
export const snapshotTitle=r=>`WSS test variables ${validateSnapshotRequest(r).request_id}`;
export function captureLocalTestVariables(r,env) {
  validateSnapshotRequest(r);
  requireThat(env.GITHUB_ACTIONS==='true'&&env.GITHUB_REPOSITORY===r.target.repository&&env.GITHUB_EVENT_NAME==='workflow_dispatch'&&env.GITHUB_REF===r.source.ref&&env.GITHUB_SHA===r.source.commit&&env.GITHUB_WORKFLOW_SHA===r.source.commit&&env.GITHUB_WORKFLOW_REF===`${r.target.repository}/${r.source.workflow}@${r.source.ref}`&&env.GITHUB_ACTOR_ID===r.source.actor_id&&env.GITHUB_RUN_ATTEMPT==='1'&&decimal(env.GITHUB_RUN_ID),'Snapshot runner/source/actor/attempt mismatch');
  return {schema:'wss-effective-test-variable-snapshot/v1',request:r,local:{repository:r.target.repository,commit:r.source.commit,workflow:r.source.workflow,run_id:env.GITHUB_RUN_ID,attempt:1},settings:normalizeEffectiveTestVariables(env)};
}
export function matchingSnapshotRuns(g,r) {
  validateSnapshotRequest(r);
  const runs=g.pages(`repos/${r.target.repository}/actions/workflows/test-variable-snapshot.yml/runs?event=workflow_dispatch&branch=${r.channel}`,'workflow_runs').filter(x=>x.display_title===snapshotTitle(r));
  requireThat(runs.length<=1,'Duplicate snapshot dispatch; inspect without retry');
  return runs;
}
export function verifySnapshotRun(g,r,run) {
  validateSnapshotRequest(r);
  requireThat(decimal(String(run.id))&&run.repository?.full_name===r.target.repository&&run.head_repository?.full_name===r.target.repository&&run.head_repository?.fork===false&&run.event==='workflow_dispatch'&&run.path===r.source.workflow&&run.head_branch===r.channel&&run.head_sha===r.source.commit&&run.run_attempt===1&&String(run.actor?.id)===r.source.actor_id&&String(run.triggering_actor?.id)===r.source.actor_id&&Array.isArray(run.pull_requests)&&run.pull_requests.length===0&&run.display_title===snapshotTitle(r),'Untrusted snapshot run/source/actor');
  const workflow=g.get(`repos/${r.target.repository}/actions/workflows/${run.workflow_id}`);
  requireThat(workflow.path===r.source.workflow&&workflow.state==='active','Wrong snapshot workflow registration');
  verifySnapshotSource(g,r);
  return run;
}
export function verifySnapshotSource(g,r) {
  validateSnapshotRequest(r);
  // A reviewed authority anchor constrains executable bytes, not future product
  // history. Each campaign separately records and freezes the actual live head.
  for(const commit of new Set([r.source.reviewed_commit,r.source.commit])) {
    const workflow=g.object(r.target.repository,commit,r.source.workflow);
    requireThat(workflow.type==='blob'&&workflow.mode==='100644'&&workflow.sha===r.source.workflow_blob,'Snapshot workflow source changed');
    const tooling=g.object(r.target.repository,commit,'.github/scripts/wss-ci');
    requireThat(tooling.type==='tree'&&tooling.mode==='040000'&&tooling.sha===r.source.tooling_tree,'Snapshot executable tooling source changed');
  }
}
export function collectLocalTestVariables(g,r) {
  const runs=matchingSnapshotRuns(g,r);
  requireThat(runs.length===1,'Missing snapshot run; do not redispatch an uncertain request');
  const run=verifySnapshotRun(g,r,g.run(r.target.repository,String(runs[0].id)));
  requireThat(run.status==='completed'&&run.conclusion==='success','Snapshot run not successful');
  const jobs=g.jobs(r.target.repository,run).filter(j=>j.name===SNAPSHOT_JOB);
  requireThat(jobs.length===1&&jobs[0].status==='completed'&&jobs[0].conclusion==='success'&&jobs[0].head_sha===r.source.commit&&String(jobs[0].run_id)===String(run.id),'Required snapshot job missing/failed/skipped');
  const artifacts=g.pages(`repos/${r.target.repository}/actions/runs/${run.id}/artifacts`,'artifacts').filter(a=>a.name===snapshotName(r));
  requireThat(artifacts.length===1,'Missing/duplicate snapshot artifact');
  const a=g.artifact(r.target.repository,String(run.id),snapshotName(r));
  requireThat(String(a.id)===String(artifacts[0].id)&&a.expired===false&&artifacts[0].expired===false&&a.workflow_run?.id===run.id&&a.workflow_run?.head_sha===r.source.commit&&/^sha256:[a-f0-9]{64}$/.test(a.digest),'Snapshot artifact identity/expiry/digest mismatch');
  // The transport must verify the actual archive against GitHub's authenticated digest.
  const bytes=g.downloadVerified(r.target.repository,a,['snapshot.json'])['snapshot.json'];
  const s=JSON.parse(bytes.toString('utf8'));
  requireThat(keys(s,['schema','request','local','settings'])&&s.schema==='wss-effective-test-variable-snapshot/v1'&&same(s.request,r)&&same(s.local,{repository:r.target.repository,commit:r.source.commit,workflow:r.source.workflow,run_id:String(run.id),attempt:1})&&same(normalizeEffectiveTestVariables(s.settings),s.settings),'Snapshot request/replay/channel/settings mismatch');
  return {settings:s.settings,binding:{request_id:r.request_id,run_id:String(run.id),artifact_id:String(a.id),archive_digest:a.digest,document_digest:bytesDigest(bytes)}};
}
// Call only with a separately authenticated durable write-ahead intent. An existing
// intent means dispatch may already have happened: correlate, NEVER automatically retry.
export function dispatchSnapshotOnce(g,r,{newIntent,authenticatedIntent,dispatch}) {
  validateSnapshotRequest(r);
  requireThat(same(authenticatedIntent,r),'Dispatch requires the independently loaded durable intent');
  const matches=matchingSnapshotRuns(g,r);
  if(matches.length){verifySnapshotRun(g,r,g.run(r.target.repository,String(matches[0].id)));return {dispatched:false,run_id:String(matches[0].id)};}
  requireThat(newIntent===true,'Dispatch outcome uncertain; inspect existing intent without retry');
  requireThat(g.head(r.target.repository,r.channel)===r.source.commit,'Snapshot dispatch ref moved');
  const workflow=g.get(`repos/${r.target.repository}/actions/workflows/test-variable-snapshot.yml`);
  requireThat(workflow.path===r.source.workflow&&workflow.state==='active','Snapshot workflow is not registered');
  verifySnapshotSource(g,r);
  requireThat(typeof dispatch==='function','Missing scoped dispatch transport');
  dispatch(r.target.repository,'test-variable-snapshot.yml',{ref:r.channel,inputs:{request:canonical(r)}});
  return {dispatched:true};
}
