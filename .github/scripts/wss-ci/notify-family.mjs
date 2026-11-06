import {isEntrypoint} from './entrypoint.mjs';
// A wake-up is not acceptance: the trusted Core coordinator still revalidates
// this family's actual merge, exact committed CI and saved application intent.
import {readFileSync,appendFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {execFileSync} from 'node:child_process';
import {GitHub,loadPlan} from './github.mjs';
import {targetPolicy} from './receipt.mjs';
import {candidate,canonical,CORE,requireThat} from './verify.mjs';
import {channelContext} from './channels.mjs';
import {mainWorkflowAuthority} from './promotion.mjs';
const profiles=JSON.parse(readFileSync(new URL('./receipt-targets.json',import.meta.url)));
const targets=JSON.parse(readFileSync(new URL('./staging-targets.json',import.meta.url)));
const same=(a,b)=>canonical(a)===canonical(b);
function json(g,path){const file=g.get(path);requireThat(file.type==='file'&&file.encoding==='base64','Expected immutable policy/record');return JSON.parse(Buffer.from(file.content,'base64'));}
export function prepareFamilyWakeup(g,c,{loadFrozenPlan=loadPlan,authorize=mainWorkflowAuthority,env=process.env}={}) {
  const profile=Object.values(profiles).find(p=>p.role==='wrapper'&&p.target.repository===c.repository);
  requireThat(profile,'Only registered integrations may notify the stage');
  const t=profile.target,source=targets[profile.family];let head,pr,context;
  // Both events execute the workflow on the default branch. The event's
  // dependency merge is evidence to inspect, never executable workflow source.
  requireThat(c.workflowRef===`${c.repository}/.github/workflows/notify-core-stage.yml@refs/heads/main` && c.sourceSha===g.head(c.repository,'main'),'Notification must execute current trusted main');
  requireThat(typeof source?.record==='string'&&source.record.length>0,'Missing integration record adapter');
  if(c.eventName==='pull_request_target'){
    requireThat(c.event.pull_request?.number>0,'Missing closed dependency PR');
    pr=g.get(`repos/${c.repository}/pulls/${c.event.pull_request.number}`);head=pr.merge_commit_sha;context=channelContext(pr.base?.ref);
  }else if(c.eventName==='workflow_run'){
    const id=String(c.event.workflow_run?.id);requireThat(/^[1-9][0-9]*$/.test(id),'Missing completed CI identity');
    const run=g.run(c.repository,id);head=run.head_sha;
    context=channelContext(run.head_branch);
    requireThat(run.repository?.full_name===c.repository&&run.head_repository?.full_name===c.repository&&run.path===t.workflow&&['push','workflow_dispatch'].includes(run.event)&&run.status==='completed'&&run.conclusion==='success','Wake-up is not successful committed integration CI');
    const prs=g.pages(`repos/${c.repository}/commits/${head}/pulls`).filter(p=>p.merged_at&&p.merge_commit_sha===head&&p.base?.ref===context.branch);
    if(prs.length===0)return {needed:false,reason:'Committed CI has no dependency PR to advance.'};
    requireThat(prs.length===1,'Completion is not a unique dependency merge');pr=g.get(`repos/${c.repository}/pulls/${prs[0].number}`);
    if(pr.user?.type!=='Bot')return {needed:false,reason:'Ordinary source/CI merge is not a bot dependency rollout.'};
    requireThat(Date.parse(run.created_at)>=Date.parse(pr.merged_at),'CI predates the actual dependency merge');
  }else throw Error('Unsupported integration notification event');
  requireThat(pr.merged===true&&pr.state==='closed'&&pr.merge_commit_sha===head&&pr.base?.ref===context.branch&&pr.base?.repo?.full_name===c.repository&&pr.head?.repo?.full_name===c.repository&&pr.user?.type==='Bot'&&pr.merged_by?.type==='User'&&g.head(c.repository,context.branch)===head,'Notification requires the current human-reviewed bot dependency merge');
  const record=json(g,`repos/${c.repository}/contents/${source.record}?ref=${head}`);candidate(record.candidate);
  const p=loadFrozenPlan(g,record.candidate.run_id);
  requireThat(p.channel===context.channel&&same(record.candidate,p.candidate)&&g.head(CORE,context.branch)===p.candidate.commit,'Notification candidate or Core source moved');
  targetPolicy(p,t.id);
  for(const path of t.trusted_paths)for(const ref of [head,g.head(c.repository,'main')])requireThat(g.object(c.repository,ref,path).sha===p.target_snapshots[t.id].trusted[path],'Notification tooling differs from frozen policy');
  const policy=json(g,`repos/${CORE}/contents/${context.stagePolicy}?ref=${p.candidate.commit}`);
  const family=policy.libraries?.find(lib=>lib.id===profile.family);
  requireThat(policy.schema===context.stageSchema&&policy.channel===context.channel&&family?.repository===c.repository&&family.record===source.record&&same(family.applications,source.applications),'Unreviewed family stage policy');
  if(policy.application_fanout!=='per-integration')return {needed:false,reason:'Earlier frozen policy uses scheduled all-integration staging.'};
  const producer=g.run(CORE,p.candidate.run_id);
  requireThat(producer.repository?.full_name===CORE&&producer.head_repository?.full_name===CORE&&producer.path==='.github/workflows/artifacts.yml'&&producer.head_branch===context.branch&&producer.head_sha===p.candidate.commit&&producer.event==='push'&&producer.status==='completed'&&producer.conclusion==='success','Notification producer is not canonical and successful');
  if(context.channel==='main')authorize({target_id:t.id,repository_root:env.GITHUB_WORKSPACE,candidate:p.candidate},env);
  return {needed:true,producer_run_id:p.candidate.run_id,family:profile.family,...(context.channel==='main'?{channel:'main'}:{})};
}
if(isEntrypoint(import.meta.url)){
  requireThat(process.env.GITHUB_ACTIONS==='true','Notifications execute only trusted hosted workflows');
  const sourceSha=process.env.GITHUB_WORKFLOW_SHA;
  requireThat(/^[a-f0-9]{40}$/.test(sourceSha||'')&&execFileSync('git',['rev-parse','HEAD'],{encoding:'utf8'}).trim()===sourceSha,'Notifier checkout must match the immutable workflow revision');
  const result=prepareFamilyWakeup(new GitHub(),{repository:process.env.GITHUB_REPOSITORY,eventName:process.env.GITHUB_EVENT_NAME,event:JSON.parse(readFileSync(process.env.GITHUB_EVENT_PATH)),sourceSha,workflowRef:process.env.GITHUB_WORKFLOW_REF});
  appendFileSync(process.env.GITHUB_OUTPUT,`needed=${result.needed}\nproducer_run_id=${result.producer_run_id||''}\nchannel=${result.channel||'dev'}\n`);
  if(process.env.GITHUB_STEP_SUMMARY)appendFileSync(process.env.GITHUB_STEP_SUMMARY,`Family stage wake-up: ${result.needed?result.family:result.reason}. This does not accept or publish a release.\n`);
}
