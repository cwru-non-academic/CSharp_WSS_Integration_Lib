import {execFileSync} from 'node:child_process';
import {mkdtempSync,readFileSync,writeFileSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {setTimeout as sleep} from 'node:timers/promises';
import {GitHub} from './github.mjs';
import {CORE,candidate,requireThat} from './verify.mjs';
import {normalizeCandidate} from './normalize-candidate.mjs';

const profiles=JSON.parse(readFileSync(new URL('./receipt-targets.json',import.meta.url)));
const sha=value=>typeof value==='string'&&/^[a-f0-9]{40}$/.test(value);
const id=value=>/^[1-9][0-9]*$/.test(String(value));
const known=repo=>repo===CORE||Object.values(profiles).some(p=>p.target.repository===repo);
export function profileFor(repository){
  const matches=Object.values(profiles).filter(p=>p.target.repository===repository);
  requireThat(matches.length===1,'Unknown or ambiguous preflight repository');return matches[0];
}

// One serializer and argv-only HTTP boundary for every receiver. Never pipe JSON
// through a host shell, and never retry a POST whose outcome is uncertain.
export function dispatchJson(repository,body,token,{execute=execFileSync,environment=process.env}={}){
  profileFor(repository);requireThat(typeof token==='string'&&token.length>0,'Scoped downstream Actions-write token required');
  requireThat(body.ref==='dev'&&body.inputs&&typeof body.inputs==='object','Invalid preflight request body');
  const directory=mkdtempSync(join(tmpdir(),'wss-preflight-'));
  try{
    const path=join(directory,'request.json');writeFileSync(path,JSON.stringify(body)+'\n','utf8');
    try{execute('gh',['api','--method','POST',`repos/${repository}/actions/workflows/wss-preflight.yml/dispatches`,'--input',path],{encoding:'utf8',maxBuffer:1024*1024,env:{...environment,GH_TOKEN:token}});}
    catch{throw Error('Preflight dispatch failed/uncertain; inspect the exact correlated run before any retry');}
  }finally{rmSync(directory,{recursive:true,force:true});}
}

export function request(context){
  const p=profileFor(context.repository),c=normalizeCandidate(context.candidate);candidate(c);
  const wrapper=context.wrapper_sha||'',application=context.application_sha||'',source=context.source_sha||'';
  requireThat(!source||sha(source),'Invalid expected preflight source');
  if(p.family==='csharp'){
    requireThat(p.role==='wrapper'?!wrapper:sha(wrapper),'C# application preflight requires its exact integration source');
    requireThat(!application,'C# source uses the explicit source_sha field');
  }else requireThat(sha(wrapper)&&sha(application),'Exact integration and application sources required');
  const correlation=context.correlation_id||`wss-${c.run_id}-${c.artifact_id}-${wrapper}-${application}`;
  requireThat(typeof correlation==='string'&&/^wss-[A-Za-z0-9-]{1,250}$/.test(correlation),'Invalid preflight correlation');
  const expected=source||(p.family==='csharp'?'':p.role==='wrapper'?wrapper:application);
  const inputs=p.family==='csharp'?{
    wss_producer_repository:c.repository,wss_run_id:c.run_id,wss_commit:c.commit,wss_archive:c.archive,wss_sha256:c.sha256,correlation_id:correlation,
    ...(wrapper?{integration_sha:wrapper}:{})
  }:{candidate_json:JSON.stringify(c),wrapper_sha:wrapper,[p.family==='unity'?'gui_sha':p.role==='ros'?'ros_sha':'cli_sha']:application,correlation_id:correlation};
  return {repository:context.repository,source_sha:expected,title:`WSS preflight ${c.run_id} / ${correlation}`,body:{ref:'dev',inputs}};
}

function expectation({repository,source_sha,workflow='wss-preflight.yml',event='workflow_dispatch'}){
  requireThat(known(repository)&&sha(source_sha)&&/^[A-Za-z0-9_-]+\.yml$/.test(workflow)&&['push','workflow_dispatch'].includes(event),'Invalid exact workflow expectation');
}
export function assertRun(run,{repository,source_sha,workflow='wss-preflight.yml',event='workflow_dispatch',title,run_id}){
  expectation({repository,source_sha,workflow,event});
  requireThat(id(run?.id)&&(!run_id||String(run.id)===String(run_id))&&run.repository?.full_name===repository&&run.head_repository?.full_name===repository&&run.path===`.github/workflows/${workflow}`&&run.head_sha===source_sha&&run.head_branch==='dev'&&run.event===event&&(!title||run.display_title===title),'Workflow run identity/source mismatch; no run substitution');
  if(run.status==='completed')requireThat(run.conclusion==='success','Required workflow failed; never substitute another green run');
  return run;
}

export function findPreflight(g,expected){
  profileFor(expected.repository);
  const matches=g.pages(`repos/${expected.repository}/actions/workflows/wss-preflight.yml/runs?event=workflow_dispatch`,'workflow_runs').filter(r=>r.display_title===expected.title);
  requireThat(matches.length<=1,'Ambiguous correlated preflight; no selection or redispatch');
  if(!matches.length)return null;
  const run=g.run(expected.repository,matches[0].id);
  return assertRun(run,{...expected,source_sha:expected.source_sha||run.head_sha,run_id:matches[0].id});
}

export async function startPreflight(g,context,{post=(repo,body)=>dispatchJson(repo,body,process.env.WSS_PREFLIGHT_TOKEN),now=Date.now,pause=sleep}={}){
  const expected=request(context),existing=findPreflight(g,expected);
  if(existing)return existing;
  const source=g.head(expected.repository);requireThat(sha(source)&&(!expected.source_sha||source===expected.source_sha),'Preflight dev source advanced before dispatch');
  expected.source_sha=source;
  const seconds=context.discovery_seconds??180;requireThat(Number.isInteger(seconds)&&seconds>=1&&seconds<=180,'Invalid discovery timeout');
  await post(expected.repository,expected.body); // exactly one attempt, even after transport failure
  const deadline=now()+seconds*1000;
  for(;;){
    const found=findPreflight(g,expected);if(found)return found;
    requireThat(now()<deadline,'Dispatched preflight not discovered; outcome uncertain, inspect before retry');
    await pause(5000);
  }
}

export async function waitRun(g,expected,{now=Date.now,pause=sleep}={}){
  expectation(expected);
  requireThat(id(expected.run_id),'Exact workflow run ID required');
  const seconds=expected.timeout_seconds??2400;requireThat(Number.isInteger(seconds)&&seconds>=1&&seconds<=7200,'Invalid workflow timeout');
  const deadline=now()+seconds*1000;
  for(;;){
    const run=assertRun(g.run(expected.repository,expected.run_id),expected);
    if(run.status==='completed')return run;
    requireThat(now()<deadline,'Timed out waiting for exact workflow; no promotion authorized');await pause(15000);
  }
}

if(process.argv[1]&&resolve(process.argv[1])===fileURLToPath(import.meta.url)){
  const {operation,...context}=JSON.parse(readFileSync(process.argv[2],'utf8').replace(/^\uFEFF/,''));
  requireThat(['start','wait'].includes(operation),'Unknown shared preflight operation');
  const g=new GitHub();console.log(JSON.stringify(await(operation==='start'?startPreflight(g,context):waitRun(g,context))));
}
