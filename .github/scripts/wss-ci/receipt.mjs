import {collectSelectedTestArtifact,verifySelectedTestArtifact} from './campaign-test-selection.mjs';
import {isEntrypoint} from './entrypoint.mjs';
// Receiver engine extracted from Python's reviewed Node receipt writer.
// Runtime-specific rich proof remains in the frozen PowerShell adapter.
import {execFileSync} from 'node:child_process';
import {mkdtempSync,readFileSync,writeFileSync,existsSync,mkdirSync,rmSync,appendFileSync} from 'node:fs';
import {join,resolve,dirname} from 'node:path';
import {tmpdir} from 'node:os';
import {fileURLToPath} from 'node:url';
import * as v from './verify.mjs';
import {GitHub,loadPlan,archive} from './github.mjs';
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
  if(t.branch==='main')v.requireThat(env.GITHUB_WORKFLOW_SHA===head&&env.GITHUB_WORKFLOW_REF===`${t.repository}/${WORKFLOW}@refs/heads/main`,'Main receipt must execute the exact registered workflow source');
  runIdentity(r,t.repository,WORKFLOW,head,'workflow_dispatch',t.branch);
  v.requireThat(String(r.id)===env.GITHUB_RUN_ID && Number.isSafeInteger(r.run_attempt) && r.run_attempt>=1 && r.run_attempt===Number(env.GITHUB_RUN_ATTEMPT),'Emitter run/attempt mismatch');
}
export function runIdentity(r,repository,path,head,event,channel='dev') {
  v.requireThat(r.repository?.full_name===repository && r.head_repository?.full_name===repository && r.path===path &&
    r.head_sha===head && r.head_branch===channelContext(channel).branch && r.event===event,'Run source/repository/workflow/channel mismatch');
}
const git=(root,...args)=>execFileSync('git',['-C',root,...args],{encoding:'utf8'}).trim();
const object=(root,path)=>git(root,'rev-parse',`HEAD:${path}`);

export async function runReceipt(config,{g=new ReadOnly(),env=process.env,adapter}={}) {
  const {sourceRoot,toolsRoot,outputRoot}=config;
  const validatorRoot=config.validatorRoot||toolsRoot,integrationRoot=config.integrationRoot||sourceRoot;
  const id=env.TARGET_ID,producerId=env.PRODUCER_RUN_ID,planId=env.PLAN_ID;
  const context=channelContext(env.WSS_CI_CHANNEL||'dev');
  v.requireThat(env.GITHUB_ACTIONS==='true' && env.GITHUB_EVENT_NAME==='workflow_dispatch' && env.GITHUB_REF===context.ref,'Receipt must execute at actual accepted channel source');
  v.requireThat(/^[1-9][0-9]*$/.test(producerId||'') && /^[a-f0-9]{64}$/.test(planId||''),'Invalid reconciliation inputs');
  const p=loadPlan(g,producerId);v.requireThat(p.plan_id===planId && p.channel===context.channel,'Input plan differs from frozen producer plan/channel');
  const profile=profiles[id],t=targetPolicy(p,id),snapshot=p.target_snapshots[id],head=g.head(t.repository,t.branch);
  changedHead(head,snapshot);
  v.requireThat(git(sourceRoot,'rev-parse','HEAD')===head && env.GITHUB_SHA===head && env.GITHUB_REPOSITORY===t.repository,'Actual reviewed dependency merge/source is required');
  for(const root of new Set([sourceRoot,toolsRoot,validatorRoot,integrationRoot])) v.requireThat(git(root,'status','--porcelain','--untracked-files=no')==='','Receipt validator checkouts must be clean');
  emitter(g.run(t.repository,env.GITHUB_RUN_ID),env,t,head);
  for(const path of t.trusted_paths) v.requireThat(g.object(t.repository,head,path).sha===snapshot.trusted[path],`Frozen receipt/CI tooling changed: ${path}`);
  if(profile.family==='csharp') {
    for(const path of [WORKFLOW,'.github/scripts/Write-ReleaseReceipt.ps1','.github/scripts/WssReleaseReceipt.ps1','.github/scripts/wss-ci']) v.requireThat(object(toolsRoot,path)===object(sourceRoot,path),`Trusted main receipt tooling differs: ${path}`);
  } else if(profile.family==='unity') {
    for(const path of ['.github/scripts',WORKFLOW]) v.requireThat(object(toolsRoot,path)===snapshot.trusted[path],`Trusted main receipt tooling differs: ${path}`);
  } else {
    v.requireThat(object(toolsRoot,'.github/scripts')===p.target_snapshots[profile.wrapper].trusted['.github/scripts'],'Pinned wrapper validator tree differs from frozen tooling');
    const configPath=`.github/${profile.family}-ci.json`;
    v.requireThat(object(toolsRoot,configPath)===p.target_snapshots[profile.wrapper].trusted[configPath],'Pinned wrapper execution configuration differs from frozen tooling');
  }
  if(profile.family==='matlab') {
    const readiness=JSON.parse(readFileSync(join(sourceRoot,'.github/matlab-ci.json'),'utf8'));
    v.requireThat(readiness.baseline_ready===true && readiness.candidate_preflight_ready===true,'Native candidate readiness is not reviewed');
  }
  const zip=archive(g,p.candidate),coreRun=g.run(v.CORE,producerId);
  v.producer(p,{run:coreRun,current_head:g.head(v.CORE,p.channel),jobs:g.jobs(v.CORE,coreRun),artifact:zip.artifact,archive_sha256:v.bytesDigest(zip.files[p.candidate.archive])});
  const associations=g.pages(`repos/${t.repository}/commits/${head}/pulls`).filter(pr=>pr.merge_commit_sha===head && pr.merged_at && pr.base?.ref===t.branch && pr.base?.repo?.full_name===t.repository && pr.head?.repo?.full_name===t.repository);
  v.requireThat(associations.length===1,'Current dev is not a unique reviewed dependency merge');
  const pr=g.get(`repos/${t.repository}/pulls/${associations[0].number}`);
  mergedPr(pr,t,head,p.candidate);
  const normalProof=()=>selectNormalRun(g.pages(`repos/${t.repository}/actions/workflows/${t.workflow.split('/').at(-1)}/runs?branch=${t.branch}&head_sha=${head}`,'workflow_runs'),t,head,pr.merged_at);
  const normal=normalProof();v.jobs(g.jobs(t.repository,normal),t.jobs);
  v.requireThat(g.tree(t.repository,normal.head_sha)===g.tree(t.repository,head),'Normal CI tested another tree');
  const parents=Object.fromEntries(Object.entries(t.parents).map(([parent,path])=>{
    const entry=g.object(t.repository,head,path);v.requireThat(entry.type==='commit' && entry.mode==='160000','Parent is not a Git submodule');return [parent,entry.sha];
  }));
  const work=mkdtempSync(join(tmpdir(),'wss-receipt-'));
  try {
    const adapterContext={plan:p,target:t,head,pr,parents,paths:{sourceRoot,toolsRoot,validatorRoot,integrationRoot}};
    let preflights;
    if(adapter) preflights=await adapter(adapterContext);
    else {
      writeFileSync(join(work,'context.json'),JSON.stringify(adapterContext));
      const script=profile.family==='csharp'||profile.family==='unity'?'Write-ReleaseReceipt.ps1':'Verify-ReleaseAcceptance.ps1';
      const args=['-NoProfile','-File',join(toolsRoot,'.github/scripts',script),'-ContextPath',join(work,'context.json')];
      if(script==='Write-ReleaseReceipt.ps1') args.push('-TargetId',id,'-ProducerRunId',producerId,'-PlanId',planId);
      else args.push('-ToolsRoot',toolsRoot);
      args.push('-WorkRoot',join(work,'validation'),'-OutputPath',join(work,'preflights.json'));
      execFileSync('pwsh',args,{stdio:'inherit',env:{...env,WSS_CI_CHANNEL:p.channel}});
      preflights=JSON.parse(readFileSync(join(work,'preflights.json'),'utf8').replace(/^\uFEFF/,''));
    }
    v.requireThat(Array.isArray(preflights) && preflights.length===profile.preflights,'Missing rich paired/actual merged-wrapper preflight proof');
    for(const d of preflights) {
      const r=g.run(d.repository,d.run_id);runIdentity(r,d.repository,d.workflow,d.source_sha,'workflow_dispatch',p.channel);
      v.requireThat(r.status==='completed' && r.conclusion==='success','Preflight is not successful');
      const normalized=JSON.parse(g.download(d.repository,d.run_id,'wss-candidate-provenance',['candidate.json'])['candidate.json']);
      v.candidate(normalized);v.requireThat(v.canonical(normalized)===v.canonical(p.candidate),'Normalized candidate differs from rich proof/frozen plan');
      if(p.test_selection) {
        const sourceTarget=p.manifest.targets.find(target=>target.repository===d.repository);
        v.requireThat(sourceTarget&&d.workflow==='.github/workflows/wss-preflight.yml'&&d.source_sha===p.target_snapshots[sourceTarget.id].head_sha&&String(r.id)===d.run_id,'Selected-test preflight differs from frozen target/source/run');
        collectSelectedTestArtifact(g,p,sourceTarget.id,r);
      }
    }
    v.requireThat(g.head(t.repository,t.branch)===head && g.head(v.CORE,p.channel)===p.candidate.commit,'Source moved during validation');
    for(const [parent,sha] of Object.entries(parents)) v.requireThat(g.head(profiles[parent].target.repository,p.channel)===sha,'Accepted wrapper moved during validation');
    const latest=normalProof(),live=g.run(t.repository,normal.id);
    v.requireThat(String(latest.id)===String(normal.id) && latest.run_attempt===normal.run_attempt && String(live.id)===String(normal.id) && live.run_attempt===normal.run_attempt,'Normal run/attempt changed during validation');
    runIdentity(live,t.repository,t.workflow,head,normal.event,p.channel);v.requireThat(live.status==='completed' && live.conclusion==='success','Normal CI is no longer successful');v.jobs(g.jobs(t.repository,live),t.jobs);
    for(const path of t.trusted_paths) v.requireThat(g.object(t.repository,head,path).sha===snapshot.trusted[path],`Frozen tooling changed during validation: ${path}`);
    // Never derive this declaration from adapter output or caller inputs. The
    // collector authenticates artifact ownership, source and attempt and checks
    // its downloaded bytes against the producer's frozen selection.
    const selectedTests=p.test_selection?verifySelectedTestArtifact(p,id,live,collectSelectedTestArtifact(g,p,id,live)):undefined;
    const receipt={...(selectedTests?{selected_tests:selectedTests}:{}),schema:context.receiptSchema,plan_id:p.plan_id,channel:p.channel,target_id:id,candidate:p.candidate,mode:'merged-pr',merge:{pr_number:String(pr.number),head_sha:pr.head.sha,sha:head},normal_ci:{run_id:String(normal.id),attempt:normal.run_attempt},preflights,parents,emitter:{run_id:env.GITHUB_RUN_ID,attempt:Number(env.GITHUB_RUN_ATTEMPT),source_sha:head,workflow:WORKFLOW},coverage:t.coverage};
    v.requireThat(!existsSync(join(outputRoot,'receipt.json')),'Receipt output must be new');mkdirSync(outputRoot,{recursive:true});writeFileSync(join(outputRoot,'receipt.json'),v.canonical(receipt)+'\n');
    if(env.GITHUB_OUTPUT) appendFileSync(env.GITHUB_OUTPUT,`artifact_name=wss-acceptance-${id}-${planId}-a${env.GITHUB_RUN_ATTEMPT}\n`);
    return receipt;
  } finally {rmSync(work,{recursive:true,force:true});}
}
if(isEntrypoint(import.meta.url)) {
  const config=JSON.parse(readFileSync(process.argv[2],'utf8').replace(/^\uFEFF/,''));
  for(const key of Object.keys(config)) config[key]=resolve(config[key]);
  await runReceipt(config);
}
