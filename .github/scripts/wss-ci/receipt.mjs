import {proofDescriptor,collectPreflightProof,preflightCandidate} from './preflight-proof.mjs';
import {detachAdmission,createAdmissionRefresh,refreshProducerMetadata,refreshNormalMetadata,refreshPreflightMetadata,refreshEmitterMetadata} from './admission-context.mjs';
import {collectSelectedTestArtifact,verifySelectedTestArtifact} from './campaign-test-selection.mjs';
import {isEntrypoint} from './entrypoint.mjs';
// Receiver engine extracted from Python's reviewed Node receipt writer.
// Runtime-specific rich proof remains in the frozen PowerShell adapter.
import {execFileSync} from 'node:child_process';
import {mkdtempSync,readFileSync,writeFileSync,existsSync,mkdirSync,rmSync,appendFileSync} from 'node:fs';
import {join,resolve,dirname,basename,relative,isAbsolute,sep} from 'node:path';
import {realpathSync} from 'node:fs';
import {pathToFileURL} from 'node:url';
import {tmpdir} from 'node:os';
import {fileURLToPath} from 'node:url';
import * as v from './verify.mjs';
import {GitHub,loadPlan,archive} from './github.mjs';
import {renderReceiptWorkflow} from './receipt-workflows.mjs';
import {selectNormalRun} from './normal-ci.mjs';
import {channelContext,targetForChannel} from './channels.mjs';

const WORKFLOW='.github/workflows/release-receipt.yml';
export const RECEIPT_WORKFLOW=WORKFLOW;
const profiles=JSON.parse(readFileSync(new URL('./receipt-targets.json',import.meta.url),'utf8'));
export const familyTargets=(family,channel='dev')=>Object.fromEntries(Object.entries(profiles).filter(([,p])=>p.family===family).map(([id,p])=>[id,{...targetForChannel(p.target,channel),role:p.role}]));
export function readOnlyGh(args) {
  v.requireThat((args.length===2 && args[0]==='api' && /^repos\/cwru-non-academic\//.test(args[1])) ||
    (args[0]==='run' && args[1]==='download' && /^[1-9][0-9]*$/.test(args[2]) && args.length===9 && args[3]==='--repo' && args[5]==='--name' && args[7]==='--dir'),
  'Receipt transport permits only GitHub GET and artifact download');
}
class ReadOnly extends GitHub {command(args){readOnlyGh(args);return super.command(args);}}
export function targetPolicy(p,id) {
  const context=channelContext(p.channel);
  v.requireThat(p.manifest?.channel===context.channel && !(p.manifest.excluded||[]).some(t=>t.id===id),'Target is excluded or outside channel acceptance');
  const profile=profiles[id],matches=p.manifest.targets.filter(t=>t.id===id);
  v.requireThat(profile && matches.length===1,'Unknown/ambiguous receipt target');
  const {role,...declared}=matches[0];
  v.requireThat((role===undefined||role===profile.role) && v.canonical(declared)===v.canonical(targetForChannel(profile.target,context.channel)),'Frozen target differs from receiver-owned required checks/parents/coverage');
  return {...matches[0],role:profile.role};
}
export function changedHead(head,snapshot) {
  v.requireThat(/^[a-f0-9]{40}$/.test(head) && /^[a-f0-9]{40}$/.test(snapshot.head_sha) && head!==snapshot.head_sha,'No-op/preparation-only receipt requires an actual reviewed dependency merge');
}
export const normalRun=(runs,t,pr)=>selectNormalRun(runs,t,pr.merge_commit_sha,pr.merged_at);
export function mergedPr(pr,t,head,candidate) {
  const family=profiles[t.id]?.family;
  v.requireThat(pr.merged===true && pr.state==='closed' && pr.merge_commit_sha===head && pr.merged_by?.type==='User' && !pr.auto_merge && pr.user?.type==='Bot' && pr.base?.ref===t.branch && pr.base?.repo?.full_name===t.repository && pr.head?.repo?.full_name===t.repository,'Receipt requires actual human-reviewed same-repository bot dependency merge');
  if(family!=='csharp') v.requireThat(pr.head.ref===`automation/${family}-wss-${candidate.run_id}-${candidate.sha256}`,'Dependency branch differs from exact candidate');
}
export function emitter(r,env,t,head) {
  v.requireThat(env.GITHUB_ACTIONS==='true' && env.GITHUB_REPOSITORY===t.repository && env.GITHUB_REF===channelContext(t.branch).ref && env.GITHUB_SHA===head && env.GITHUB_EVENT_NAME==='workflow_dispatch','Receipt must execute at actual accepted channel source');
  v.requireThat(env.GITHUB_WORKFLOW_SHA===head&&env.GITHUB_WORKFLOW_REF===`${t.repository}/${WORKFLOW}@refs/heads/${t.branch}`,'Receipt must execute the exact registered workflow source');
  runIdentity(r,t.repository,WORKFLOW,head,'workflow_dispatch',t.branch);
  v.requireThat(String(r.id)===env.GITHUB_RUN_ID && Number.isSafeInteger(r.run_attempt) && r.run_attempt>=1 && r.run_attempt===Number(env.GITHUB_RUN_ATTEMPT),'Emitter run/attempt mismatch');
}
export function runIdentity(r,repository,path,head,event,channel='dev') {
  v.requireThat(r.repository?.full_name===repository && r.head_repository?.full_name===repository && r.path===path &&
    r.head_sha===head && r.head_branch===channelContext(channel).branch && r.event===event,'Run source/repository/workflow/channel mismatch');
}
const git=(root,...args)=>execFileSync('git',['-C',root,...args],{encoding:'utf8'}).trim();
const object=(root,path)=>git(root,'rev-parse',`HEAD:${path}`);

export const ROOT_KEYS=['sourceRoot','toolsRoot','validatorRoot','integrationRoot','engineRoot','coreRoot','outputRoot'];
const realpath=realpathSync.native;
const fullSha=value=>typeof value==='string'&&/^[a-f0-9]{40}$/.test(value);
export function receiptEligibility(env) {
  const profile=profiles[env.TARGET_ID],channel=env.WSS_CI_CHANNEL;
  v.requireThat(profile&&['dev','main'].includes(channel)&&env.GITHUB_ACTIONS==='true'&&env.GITHUB_EVENT_NAME==='workflow_dispatch'&&env.GITHUB_REF===`refs/heads/${channel}`&&env.GITHUB_REPOSITORY===profile.target.repository,'Receipt caller identity/channel/event is ineligible');
  v.requireThat(fullSha(env.GITHUB_SHA)&&env.GITHUB_WORKFLOW_SHA===env.GITHUB_SHA&&env.GITHUB_WORKFLOW_REF===`${env.GITHUB_REPOSITORY}/${WORKFLOW}@refs/heads/${channel}`,'Receipt workflow must execute the exact accepted source');
  v.requireThat(/^[1-9][0-9]*$/.test(env.PRODUCER_RUN_ID||'')&&/^[a-f0-9]{64}$/.test(env.PLAN_ID||''),'Invalid reconciliation inputs');
  return profile;
}
export function receiptLocalReadiness(sourceRoot,profile) {
  if(profile.family!=='matlab')return;
  const readiness=JSON.parse(readFileSync(join(sourceRoot,'.github/matlab-ci.json'),'utf8'));
  v.requireThat(readiness.baseline_ready===true&&readiness.candidate_preflight_ready===true,'Native candidate readiness is not reviewed');
}
export function receiptRoots(config,profile) {
  v.requireThat(config&&v.canonical(Object.keys(config).sort())===v.canonical([...ROOT_KEYS].sort()),'Receipt requires exactly the declared root roles');
  const roots={};
  for(const key of ROOT_KEYS) {
    v.requireThat(typeof config[key]==='string'&&isAbsolute(config[key]),'Receipt roots must be explicit absolute paths');
    roots[key]=key==='outputRoot'?join(realpath(dirname(config[key])),basename(config[key])):realpath(config[key]);
    if(key!=='outputRoot')v.requireThat(realpath(git(roots[key],'rev-parse','--show-toplevel'))===roots[key],'Receipt role must identify a checkout root');
  }
  if(profile.role==='wrapper')v.requireThat(['toolsRoot','validatorRoot','integrationRoot'].every(k=>roots[k]===roots.sourceRoot),'Wrapper native roles must alias its accepted product root');
  const contains=(a,b)=>{const r=relative(a,b);return r===''||(r!=='..'&&!r.startsWith('..'+sep)&&!isAbsolute(r));};
  for(const a of ROOT_KEYS)for(const b of ROOT_KEYS)if(a<b&&(contains(roots[a],roots[b])||contains(roots[b],roots[a]))) {
    v.requireThat(roots[a]===roots[b]&&profile.receipt.aliases.some(group=>group.includes(a)&&group.includes(b)),`Undeclared overlapping receipt root roles: ${a}/${b}`);
  }
  v.requireThat(!existsSync(roots.outputRoot),'Receipt output root must be new');
  for(const root of new Set(ROOT_KEYS.filter(k=>k!=='outputRoot').map(k=>roots[k])))v.requireThat(git(root,'status','--porcelain','--untracked-files=all')==='','Receipt checkouts must be clean, including untracked files');
  return roots;
}
export async function runReceipt(config,{g=new ReadOnly(),env=process.env}={}) {
  let phase='eligibility';
  try {
  const profile=receiptEligibility(env);
  phase='roots';
  const roots=receiptRoots(config,profile);
  const {sourceRoot,toolsRoot,validatorRoot,integrationRoot,engineRoot,coreRoot,outputRoot}=roots;
  const rootHeads=Object.fromEntries(ROOT_KEYS.filter(k=>k!=='outputRoot').map(k=>[k,git(roots[k],'rev-parse','HEAD')]));
  const id=env.TARGET_ID,producerId=env.PRODUCER_RUN_ID,planId=env.PLAN_ID;
  const context=channelContext(env.WSS_CI_CHANNEL);
  phase='pins';
  // These immutable bootstrap pins are rendered into the reviewed caller. This
  // check is not a sandbox for code already executed by the Node bootstrap.
  v.requireThat(fullSha(env.WSS_RECEIPT_ENGINE_SHA)&&git(engineRoot,'rev-parse','HEAD')===env.WSS_RECEIPT_ENGINE_SHA,'Immutable receipt engine source differs');
  v.requireThat(fullSha(env.WSS_RECEIPT_CORE_SHA)&&git(coreRoot,'rev-parse','HEAD')===env.WSS_RECEIPT_CORE_SHA,'Immutable Core guard source differs');
  const lock=JSON.parse(readFileSync(join(sourceRoot,'.github/scripts/wss-ci.lock.json'),'utf8'));
  v.requireThat(lock.repository===env.GITHUB_REPOSITORY&&lock.source_repository===v.CORE&&lock.source_commit===env.WSS_RECEIPT_CORE_SHA&&lock.origins?.integration?.commit===env.WSS_RECEIPT_ENGINE_SHA,'Receipt source lock differs from reviewed bootstrap pins');
  v.requireThat(git(sourceRoot,'show',`HEAD:${WORKFLOW}`)+'\n'===renderReceiptWorkflow(id,{core:env.WSS_RECEIPT_CORE_SHA,engine:env.WSS_RECEIPT_ENGINE_SHA,validator:env.WSS_RECEIPT_VALIDATOR_SHA}).text,'Receipt workflow differs from registered immutable shape/pins');
  const distributor=await import(pathToFileURL(join(coreRoot,'tools/ci/sync-tooling.mjs')).href);
  distributor.check(profile.target.repository.split('/')[1],sourceRoot,dirname(engineRoot));
  if(profile.role!=='wrapper')distributor.check(profiles[profile.wrapper].target.repository.split('/')[1],validatorRoot,dirname(engineRoot));
  if(profile.role!=='wrapper')v.requireThat(fullSha(env.WSS_RECEIPT_VALIDATOR_SHA)&&git(validatorRoot,'rev-parse','HEAD')===env.WSS_RECEIPT_VALIDATOR_SHA,'Immutable native validator pin differs');
  phase='authority';
  const p=loadPlan(g,producerId);v.requireThat(p.plan_id===planId&&p.channel===context.channel,'Input plan differs from frozen producer plan/channel');
  const t=targetPolicy(p,id),snapshot=p.target_snapshots[id],head=g.head(t.repository,t.branch);
  const authority=await import(pathToFileURL(join(coreRoot,'tools/ci/workflow-freeze.mjs')).href);
  authority.receiptAuthorization(g,p,id);
  changedHead(head,snapshot);
  v.requireThat(git(sourceRoot,'rev-parse','HEAD')===head&&env.GITHUB_SHA===head,'Actual reviewed dependency merge/source is required');
  const capturedEmitter=detachAdmission(g.run(t.repository,env.GITHUB_RUN_ID));
  emitter(capturedEmitter,env,t,head);
  for(const path of t.trusted_paths)v.requireThat(object(sourceRoot,path)===snapshot.trusted[path]&&g.object(t.repository,head,path).sha===snapshot.trusted[path],`Frozen receipt/CI tooling changed: ${path}`);
  const wrapperSnapshot=p.target_snapshots[profile.wrapper];
  for(const path of ['.github/scripts',...(profile.receipt.configuration?[profile.receipt.configuration]:[])])v.requireThat(object(validatorRoot,path)===wrapperSnapshot.trusted[path],`Native validator differs from frozen wrapper source: ${path}`);
  v.requireThat(toolsRoot===(profile.receipt.adapter_owner==='receiver'?sourceRoot:validatorRoot),'Native adapter root differs from registered owner');
  receiptLocalReadiness(sourceRoot,profile);
  const zip=archive(g,p.candidate),coreRun=detachAdmission(g.run(v.CORE,producerId));
  const producerEvidence=detachAdmission({run:coreRun,current_head:g.head(v.CORE,p.channel),jobs:g.jobs(v.CORE,coreRun),artifact:zip.artifact,archive_sha256:v.bytesDigest(zip.files[p.candidate.archive])});
  v.producer(p,producerEvidence);
  const associations=g.pages(`repos/${t.repository}/commits/${head}/pulls`).filter(pr=>pr.merge_commit_sha===head && pr.merged_at && pr.base?.ref===t.branch && pr.base?.repo?.full_name===t.repository && pr.head?.repo?.full_name===t.repository);
  v.requireThat(associations.length===1,'Current dev is not a unique reviewed dependency merge');
  const pr=detachAdmission(g.get(`repos/${t.repository}/pulls/${associations[0].number}`));
  mergedPr(pr,t,head,p.candidate);
  const normalProof=()=>selectNormalRun(g.pages(`repos/${t.repository}/actions/workflows/${t.workflow.split('/').at(-1)}/runs?branch=${t.branch}&head_sha=${head}`,'workflow_runs'),t,head,pr.merged_at);
  const normal=structuredClone(normalProof());v.jobs(g.jobs(t.repository,normal),t.jobs);
  v.requireThat(g.tree(t.repository,normal.head_sha)===g.tree(t.repository,head),'Normal CI tested another tree');
  const parents=Object.fromEntries(Object.entries(t.parents).map(([parent,path])=>{
    const entry=g.object(t.repository,head,path);v.requireThat(entry.type==='commit' && entry.mode==='160000','Parent is not a Git submodule');return [parent,entry.sha];
  }));
  for(const path of ['.github/scripts',...(profile.receipt.configuration?[profile.receipt.configuration]:[])])v.requireThat(object(integrationRoot,path)===wrapperSnapshot.trusted[path],`Accepted wrapper tooling differs from frozen source: ${path}`);
  for(const [parent,sha] of Object.entries(parents))v.requireThat(git(integrationRoot,'rev-parse','HEAD')===sha&&g.head(profiles[parent].target.repository,p.channel)===sha,'Actual integration root differs from accepted parent');
  const work=mkdtempSync(join(tmpdir(),'wss-receipt-'));
  try {
    const adapterContext={plan:p,target:t,head,pr,parents,paths:roots};
    phase='adapter';
    let preflights;
    {
      writeFileSync(join(work,'context.json'),JSON.stringify(adapterContext));
      const script=profile.receipt.adapter.split('/').at(-1);
      const args=['-NoProfile','-File',join(toolsRoot,'.github/scripts',script),'-ContextPath',join(work,'context.json')];
      if(script==='Write-ReleaseReceipt.ps1') args.push('-TargetId',id,'-ProducerRunId',producerId,'-PlanId',planId);
      else args.push('-ToolsRoot',toolsRoot);
      args.push('-WorkRoot',join(work,'validation'),'-OutputPath',join(work,'preflights.json'));
      execFileSync('pwsh',args,{stdio:'inherit',env:{...env,WSS_CI_CHANNEL:p.channel,WSS_CORE_TOOLS_ROOT:coreRoot,WSS_TARGET_ROOT:sourceRoot}});
      preflights=JSON.parse(readFileSync(join(work,'preflights.json'),'utf8').replace(/^\uFEFF/,''));
    }
    phase='proof';
    v.requireThat(Array.isArray(preflights) && preflights.length===profile.preflights,'Missing rich paired/actual merged-wrapper preflight proof');
    const seen=new Set(),capturedPreflights=[];
    for(const d of preflights) {
      proofDescriptor(d);
      const sourceTarget=p.manifest.targets.find(target=>target.repository===d.repository);
      const proofKey=`${d.repository}/${d.run_id}`;
      v.requireThat(sourceTarget&&d.workflow==='.github/workflows/wss-preflight.yml'&&d.source_sha===p.target_snapshots[sourceTarget.id].head_sha&&/^[1-9][0-9]*$/.test(d.run_id)&&!seen.has(proofKey),'Native proof differs from frozen source or duplicates a run');
      seen.add(proofKey);
      const proof=detachAdmission(collectPreflightProof(g,d)),r=proof.run;v.requireThat(String(r.id)===d.run_id&&r.run_attempt===d.attempt,'Native proof run/attempt identity differs');runIdentity(r,d.repository,d.workflow,d.source_sha,'workflow_dispatch',p.channel);
      v.requireThat(r.status==='completed' && r.conclusion==='success','Preflight is not successful');
      const normalized=preflightCandidate(g,d);
      v.candidate(normalized);v.requireThat(v.canonical(normalized)===v.canonical(p.candidate),'Normalized candidate differs from rich proof/frozen plan');
      let selectedProof;
      if(p.test_selection) {
        const sourceTarget=p.manifest.targets.find(target=>target.repository===d.repository);
        v.requireThat(sourceTarget&&d.workflow==='.github/workflows/wss-preflight.yml'&&d.source_sha===p.target_snapshots[sourceTarget.id].head_sha&&String(r.id)===d.run_id,'Selected-test preflight differs from frozen target/source/run');
        selectedProof=collectSelectedTestArtifact(g,p,sourceTarget.id,r);
      }
      capturedPreflights.push(detachAdmission({descriptor:d,proof,candidate:normalized,...(selectedProof?{selected_tests:selectedProof}:{})}));
    }
    phase='recheck';
    // Finish proof IO before final admission. Selected evidence belongs to the
    // originally captured normal attempt, never a newly observed rerun.
    const selectedProof=p.test_selection?detachAdmission(collectSelectedTestArtifact(g,p,id,normal)):undefined;
    const selectedTests=selectedProof?verifySelectedTestArtifact(p,id,normal,selectedProof):undefined;
    for(const d of preflights)collectPreflightProof(g,d);
    for(const path of t.trusted_paths) v.requireThat(g.object(t.repository,head,path).sha===snapshot.trusted[path],`Frozen tooling changed during validation: ${path}`);
    authority.receiptAuthorization(g,p,id);
    // Reuse the same metadata-only admission predicates as Core. Authenticated
    // candidate/log/selected bytes remain captured; this phase downloads none.
    const session=createAdmissionRefresh(g);
    v.producer(p,refreshProducerMetadata(g,p,producerEvidence,{session}));
    for(const captured of capturedPreflights) {
      const fresh=refreshPreflightMetadata(g,p,captured,{session});
      runIdentity(fresh.proof.run,captured.descriptor.repository,captured.descriptor.workflow,captured.descriptor.source_sha,'workflow_dispatch',p.channel);
      v.requireThat(v.canonical(fresh.candidate)===v.canonical(p.candidate),'Normalized candidate differs from frozen plan');
    }
    const refreshedNormal=refreshNormalMetadata(g,p,t,{run:normal,merge_sha:head,merged_at:pr.merged_at,...(selectedProof?{selected_tests:selectedProof}:{})},{session});
    runIdentity(refreshedNormal.run,t.repository,t.workflow,head,normal.event,p.channel);
    v.jobs(refreshedNormal.jobs,t.jobs);
    if(selectedProof)v.requireThat(v.canonical(verifySelectedTestArtifact(p,id,refreshedNormal.run,refreshedNormal.selected_tests))===v.canonical(selectedTests),'Selected evidence changed during admission');
    emitter(refreshEmitterMetadata(g,p,t,capturedEmitter,{running:true,session}),env,t,head);
    session.finish();
    // These last observations narrow the admission window; sequential reads
    // and local emission cannot form an atomic transaction with GitHub.
    const currentHead=g.head(t.repository,t.branch);
    const parentHeads=Object.fromEntries(Object.keys(parents).map(parent=>[parent,g.head(profiles[parent].target.repository,p.channel)]));
    const currentCore=g.head(v.CORE,p.channel);
    v.requireThat(currentHead===head&&currentCore===p.candidate.commit,'Source moved during validation');
    for(const [parent,sha] of Object.entries(parents))v.requireThat(parentHeads[parent]===sha,'Accepted wrapper moved during validation');
    receiptRoots(config,profile);
    for(const [key,sha] of Object.entries(rootHeads))v.requireThat(git(roots[key],'rev-parse','HEAD')===sha,'Receipt root moved during native validation');
    const receipt={...(selectedTests?{selected_tests:selectedTests}:{}),schema:context.receiptSchema,plan_id:p.plan_id,channel:p.channel,target_id:id,candidate:p.candidate,mode:'merged-pr',merge:{pr_number:String(pr.number),head_sha:pr.head.sha,sha:head},normal_ci:{run_id:String(normal.id),attempt:normal.run_attempt},preflights,parents,emitter:{run_id:env.GITHUB_RUN_ID,attempt:Number(env.GITHUB_RUN_ATTEMPT),source_sha:head,workflow:WORKFLOW},coverage:t.coverage};
    phase='emission';
    v.requireThat(!existsSync(join(outputRoot,'receipt.json')),'Receipt output must be new');mkdirSync(outputRoot,{recursive:true});writeFileSync(join(outputRoot,'receipt.json'),v.canonical(receipt)+'\n');
    if(env.GITHUB_OUTPUT) appendFileSync(env.GITHUB_OUTPUT,`artifact_name=wss-acceptance-${id}-${planId}-a${env.GITHUB_RUN_ATTEMPT}\n`);
    return receipt;
  } finally {rmSync(work,{recursive:true,force:true});}
  } catch(error) {error.code=`WSS_RECEIPT_${phase.toUpperCase()}`;error.message=`${error.code}: ${error.message}`;throw error;}
}
if(isEntrypoint(import.meta.url)) {
  if(process.argv[2]==='--eligibility') {
    v.requireThat(process.argv.length===4,'Usage: receipt.mjs --eligibility <accepted-root>');
    receiptLocalReadiness(resolve(process.argv[3]),receiptEligibility(process.env));
  } else {
    v.requireThat(process.argv.length===3,'Usage: receipt.mjs <closed-root-config.json>');
    const config=JSON.parse(readFileSync(process.argv[2],'utf8').replace(/^\uFEFF/,''));
    await runReceipt(config);
  }
}
