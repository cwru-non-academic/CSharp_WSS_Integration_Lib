import {canonical,requireThat,producer} from './verify.mjs';
import {findNormalRuns,selectNormalRun} from './normal-ci.mjs';
import {refreshPreflightProof,verifyPreflightProof} from './preflight-proof.mjs';
import {refreshSelectedTestArtifact,verifySelectedTestArtifact,validatePlanTestSelection} from './campaign-test-selection.mjs';

// Detached authenticated captures; Buffer must remain Buffer for byte validators.
export function detachAdmission(x) {
  if(Buffer.isBuffer(x))return Buffer.from(x);
  if(Array.isArray(x))return x.map(detachAdmission);
  if(x&&typeof x==='object')return Object.fromEntries(Object.entries(x).map(([k,v])=>[k,detachAdmission(v)]));
  return x;
}
const same=(a,b)=>canonical(a)===canonical(b);
const runIdentity=r=>[String(r.id),r.run_attempt,r.repository?.full_name,r.head_repository?.full_name,r.path,r.head_sha,r.head_branch,r.event,r.status,r.conclusion];
export function createAdmissionRefresh(g) {
  const runs=new Map(),attempts=new Map();
  return {preflights:new Map(),bracket(repository,captured,{identityOnly=false}={}){
    const physical=`${repository}:${captured.id}`;requireThat(!attempts.has(physical)||attempts.get(physical)===captured.run_attempt,'Conflicting captured run attempts');attempts.set(physical,captured.run_attempt);
    const key=`${repository}:${captured.id}:${captured.run_attempt}`,prior=runs.get(key),project=r=>identityOnly?runIdentity(r).slice(0,8):runIdentity(r);
    requireThat(!prior||same(prior.project(prior.captured),project(captured)),'Conflicting captured run expectations');
    const live=detachAdmission(g.run(repository,String(captured.id)));
    requireThat(same(project(live),project(captured)),'Producer attempt / Run repository/workflow/status / admission run identity changed');
    runs.set(key,{captured:detachAdmission(captured),project});return live;
  },finish(){
    // Never cache final reads. Every dependency was sampled between these brackets.
    for(const [key,{captured,project}]of runs){const repository=key.split(':')[0];requireThat(same(project(g.run(repository,String(captured.id))),project(captured)),'Admission run identity/attempt/status changed at final bracket');}
  }};
}
export function refreshProducerMetadata(g,p,captured,{session=createAdmissionRefresh(g)}={}) {
  const e=detachAdmission(captured),r=session.bracket(p.candidate.repository,e.run);
  e.jobs=detachAdmission(g.jobs(p.candidate.repository,r));e.artifact=detachAdmission(g.artifact(p.candidate.repository,p.candidate.run_id,'universal-release-assets'));
  requireThat(e.artifact.id===captured.artifact.id&&e.artifact.digest===captured.artifact.digest,'Producer artifact binding changed');
  e.run=session.bracket(p.candidate.repository,e.run);producer(p,e);return e;
}
export function refreshNormalMetadata(g,p,target,captured,{session=createAdmissionRefresh(g)}={}) {
  const r=session.bracket(target.repository,captured.run),jobs=detachAdmission(g.jobs(target.repository,r));
  const latest=selectNormalRun(findNormalRuns(g,target,captured.merge_sha,captured.merged_at),target,captured.merge_sha,captured.merged_at);
  requireThat(String(latest.id)===String(captured.run.id)&&latest.run_attempt===captured.run.run_attempt,'Normal post-merge CI run missing, ambiguous or different from receipt');
  const selected_tests=p.test_selection?refreshSelectedTestArtifact(g,p,target.id,r,captured.selected_tests):undefined;
  const run=session.bracket(target.repository,captured.run);
  return {run,jobs,...(selected_tests?{selected_tests}:{})};
}
export function refreshPreflightMetadata(g,p,captured,{session=createAdmissionRefresh(g)}={}) {
  const d=captured.descriptor;
  // Equality is not validation: every incoming capture must satisfy the same
  // pure predicates, even when an equivalent physical proof is already cached.
  verifyPreflightProof(d,captured.proof);validatePlanTestSelection(p);
  const target=p.manifest.targets.find(t=>t.repository===d.repository);
  requireThat(target,'Unknown preflight target');
  const selected=p.test_selection?verifySelectedTestArtifact(p,target.id,captured.proof.run,captured.selected_tests):undefined;
  const a=selected?captured.selected_tests.artifact:undefined;
  const expectation={descriptor:d,run:runIdentity(captured.proof.run),candidate:captured.candidate,
    ...(selected?{selected_tests:{artifact:{id:String(a.id),name:a.name,expired:a.expired,digest:a.digest,
      workflow_run:{id:String(a.workflow_run.id),head_sha:a.workflow_run.head_sha}},evidence:selected}}:{})};
  const key=`${d.repository}:${d.run_id}:${d.attempt}`,prior=session.preflights.get(key);
  if(prior){requireThat(same(prior.expectation,expectation),'Conflicting shared preflight expectations');return detachAdmission(prior.result);}
  session.bracket(d.repository,captured.proof.run);
  const proof=refreshPreflightProof(g,d,captured.proof);
  const selected_tests=p.test_selection?refreshSelectedTestArtifact(g,p,target.id,proof.run,captured.selected_tests):undefined;
  session.bracket(d.repository,captured.proof.run);
  const result={descriptor:detachAdmission(d),proof,candidate:detachAdmission(captured.candidate),...(selected_tests?{selected_tests}:{})};
  session.preflights.set(key,{expectation:detachAdmission(expectation),result:detachAdmission(result)});return result;
}
export function refreshEmitterMetadata(g,p,target,captured,{running=false,session=createAdmissionRefresh(g)}={}) {
  const run=session.bracket(target.repository,captured,{identityOnly:running});
  requireThat(run.repository?.full_name===target.repository&&run.head_repository?.full_name===target.repository&&run.path==='.github/workflows/release-receipt.yml'&&run.event==='workflow_dispatch'&&run.head_branch===p.channel,'Receipt emitter identity mismatch');
  if(!running)requireThat(run.status==='completed'&&run.conclusion==='success','Receipt emitter is not completed successfully');
  return run;
}
