// Opt-in campaign extension. No live policy or token permission is changed here.
import {canonical,requireThat,TARGETS} from './verify.mjs';
import {verifyTestSelection,verifySelectedTestEvidence} from './test-selection-contract.mjs';

export const CAMPAIGN_TEST_POLICY='wss-campaign-test-selection/v1';
const same=(a,b)=>canonical(a)===canonical(b);
const keys=(o,expected)=>o&&typeof o==='object'&&!Array.isArray(o)&&same(Object.keys(o).sort(),[...expected].sort());
const repository=x=>typeof x==='string'&&/^[A-Za-z0-9][A-Za-z0-9_-]*\/[A-Za-z0-9][A-Za-z0-9_.-]*$/.test(x)&&!x.includes('..')&&!x.endsWith('.git');
const definition=p=>p.manifest||p.policy;
export function testSelectionPolicy(m) {
  if(!Object.hasOwn(m,'test_selection_policy'))return null;
  const policy=m.test_selection_policy;
  requireThat(keys(policy,['schema','targets'])&&policy.schema===CAMPAIGN_TEST_POLICY&&Array.isArray(policy.targets),'Unknown campaign test-selection policy');
  requireThat(same(policy.targets.map(t=>t.id).sort(),[...TARGETS].sort()),'Test policy must cover all nine targets exactly');
  requireThat(new Set(policy.targets.map(t=>t.repository)).size===TARGETS.length,'Duplicate test target repositories');
  for(const t of policy.targets)requireThat(keys(t,['id','repository','default_test_repository','allowed_test_repositories'])&&repository(t.repository)&&Array.isArray(t.allowed_test_repositories)&&t.allowed_test_repositories.length>0&&t.allowed_test_repositories.every(repository)&&new Set(t.allowed_test_repositories).size===t.allowed_test_repositories.length&&t.allowed_test_repositories.includes(t.default_test_repository),'Invalid reviewed test source allowlist');
  if(m.targets)requireThat(same(policy.targets.map(t=>({id:t.id,repository:t.repository})).sort((a,b)=>a.id.localeCompare(b.id)),m.targets.map(t=>({id:t.id,repository:t.repository})).sort((a,b)=>a.id.localeCompare(b.id))),'Test policy targets differ from acceptance targets');
  if(m.libraries) {
    const repos=m.libraries.flatMap(t=>[t.repository,...t.applications]);
    requireThat(same([...repos].sort(),policy.targets.map(t=>t.repository).sort()),'Test policy targets differ from staged receivers');
    for(const t of m.libraries)requireThat(policy.targets.some(x=>x.id===`${t.id}-wrapper`&&x.repository===t.repository),'Test policy family identity differs');
  }
  return policy;
}
export function selectionRequest(m,c,snapshots) {
  const policy=testSelectionPolicy(m);
  requireThat(policy,'Campaign does not opt into test selection');
  if(snapshots!==undefined)requireThat(keys(snapshots,policy.targets.map(t=>t.id)),'Missing or extra effective variable snapshots');
  return {channel:m.channel,campaign:{repository:c.repository,commit:c.commit,run_id:c.run_id},targets:policy.targets.map(t=>({...t,variables:snapshots===undefined?{}:snapshots[t.id]}))};
}
export function selectionFields(m,c,selection) {
  if(!testSelectionPolicy(m)) {
    requireThat(selection===undefined,'Unexpected test selection under legacy policy');return {};
  }
  requireThat(selection,'Required frozen campaign test selection is missing');
  verifyTestSelection(selection,selectionRequest(m,c),selection.selection_id);
  return {test_selection:structuredClone(selection),test_selection_id:selection.selection_id};
}
export function validatePlanTestSelection(p) {
  const fields=selectionFields(definition(p),p.candidate,p.test_selection);
  requireThat(same(fields.test_selection_id,p.test_selection_id)&&(!Object.hasOwn(p,'test_selection')||fields.test_selection)&&(!Object.hasOwn(p,'test_selection_id')||fields.test_selection_id),'Plan test selection fields differ or are unexpected');
  return fields;
}
export function assertPairedTestSelection(a,s) {
  validatePlanTestSelection(a);validatePlanTestSelection(s);
  requireThat(same(testSelectionPolicy(a.manifest),testSelectionPolicy(s.policy))&&same(a.test_selection,s.test_selection)&&a.test_selection_id===s.test_selection_id,'Stage and acceptance must share the exact reviewed test selection');
}
export const selectedTestArtifactName=(targetId,attempt)=>`wss-selected-tests-${targetId}-a${attempt}`;
export function verifySelectedTestArtifact(p,targetId,run,proof) {
  validatePlanTestSelection(p);
  requireThat(p.test_selection,'Selected-test artifacts require an opted-in campaign');
  const target=p.test_selection.targets[targetId],a=proof?.artifact;
  requireThat(target&&run.repository?.full_name===target.repository&&run.head_repository?.full_name===target.repository&&run.status==='completed'&&run.conclusion==='success'&&Number.isSafeInteger(run.run_attempt)&&run.run_attempt>=1,'Selected-test run identity/status mismatch');
  requireThat(a&&/^[1-9][0-9]*$/.test(String(a.id))&&a.expired===false&&a.name===selectedTestArtifactName(targetId,run.run_attempt)&&String(a.workflow_run?.id)===String(run.id)&&a.workflow_run?.head_sha===run.head_sha,'Selected-test artifact is not bound to the authenticated run');
  requireThat(Buffer.isBuffer(proof.bytes),'Selected-test artifact bytes are missing');
  const evidence=JSON.parse(proof.bytes.toString('utf8'));
  verifySelectedTestEvidence(p.test_selection,selectionRequest(definition(p),p.candidate),p.test_selection_id,targetId,evidence);
  return evidence;
}
export function collectSelectedTestArtifact(g,p,targetId,run) {
  if(!testSelectionPolicy(definition(p)))return undefined;
  const repo=p.test_selection.targets[targetId]?.repository,name=selectedTestArtifactName(targetId,run.run_attempt);
  requireThat(repo,'Unknown selected-test target');
  const artifact=g.artifact(repo,String(run.id),name);
  const bytes=g.download(repo,String(run.id),name,['evidence.json'])['evidence.json'];
  const proof={artifact,bytes};verifySelectedTestArtifact(p,targetId,run,proof);return proof;
}

// Call after loadPlan/loadStage authenticates the producer and reviewed policy.
export function planTestSelection(p,kind=p.manifest?'acceptance':'stage') {
  requireThat(['acceptance','stage'].includes(kind)&&Boolean(kind==='acceptance'?p.manifest:p.policy),'Unknown selection plan kind');
  validatePlanTestSelection(p);
  return p.test_selection?{selection:p.test_selection,request:selectionRequest(definition(p),p.candidate),selection_id:p.test_selection_id}:null;
}
export function targetTestEvidence(p,targetId) {
  const context=planTestSelection(p),target=context?.selection.targets[targetId];
  requireThat(target,'Target requires an active frozen selection');
  return {selection_id:context.selection_id,target_id:targetId,repository:target.repository,test_repository:target.tests.repository,test_commit:target.tests.commit};
}

export function refreshSelectedTestArtifact(g,p,targetId,run,captured) {
  verifySelectedTestArtifact(p,targetId,run,captured);
  const artifact=structuredClone(g.artifact(run.repository.full_name,String(run.id),selectedTestArtifactName(targetId,run.run_attempt)));
  requireThat(String(artifact.id)===String(captured.artifact.id)&&artifact.digest===captured.artifact.digest,'Selected-test artifact replaced since authentication');
  const result={artifact,bytes:Buffer.from(captured.bytes)};verifySelectedTestArtifact(p,targetId,run,result);return result;
}
