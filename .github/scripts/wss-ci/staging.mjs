import {isEntrypoint} from './entrypoint.mjs';
// Common producer-policy interpretation for all four fanout adapters.
import {readFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {canonical,candidate,requireThat} from './verify.mjs';
import {channelContext,integrationConfiguration} from './channels.mjs';
import {execFileSync} from 'node:child_process';
const targets=JSON.parse(readFileSync(new URL('./staging-targets.json',import.meta.url),'utf8'));
export function stagingPolicy({tree,file,receiver,family,channel='dev'}) {
  const context=channelContext(channel);
  const expected=targets[family];requireThat(expected,'Unknown staged receiver');
  requireThat(receiver.schema===context.receiverSchema && receiver.core_workflow===context.stageWorkflow && receiver.staged_applications===true && receiver.fanout_workflow===expected.fanout && canonical([...receiver.applications].sort())===canonical([...expected.applications].sort()),'Invalid staged receiver declaration');
  requireThat(tree.truncated===false && Array.isArray(tree.tree) && /^[a-f0-9]{40}$/.test(tree.sha),'Complete verified producer tree required; lookup failure is never policy absence');
  const entries=tree.tree.filter(e=>e.path===context.stagePolicy);
  if(entries.length===0) {requireThat(context.channel==='dev','Main staging policy cannot be absent');requireThat(file===null || file===undefined,'Unexpected policy outside producer tree');return false;}
  requireThat(entries.length===1 && entries[0].type==='blob' && /^[a-f0-9]{40}$/.test(entries[0].sha),'Ambiguous/invalid immutable producer policy');
  requireThat(file?.type==='file' && file.encoding==='base64' && file.sha===entries[0].sha,'Producer policy content/tree identity mismatch');
  const policy=JSON.parse(Buffer.from(file.content,'base64').toString('utf8'));
  const matches=policy.libraries?.filter(t=>t.id===family);
  requireThat(policy.schema===context.stageSchema && policy.channel===context.channel && matches?.length===1,'Unsupported producer staging policy');
  const target=matches[0];
  requireThat(target.repository===expected.repository && target.fanout===expected.fanout && canonical([...target.applications].sort())===canonical([...expected.applications].sort()),'Producer staging policy does not match receiver');
  return true;
}
export function barrierExecution({barrier,family,source_root,env,channel='dev'}) {
  const context=channelContext(channel),expected=targets[family];
  requireThat(expected,'Unknown staged execution family');
  if(context.channel==='dev')return false;
  const accepted=barrier?.integrations?.[family],execution=accepted?.execution;
  candidate(barrier?.candidate);
  requireThat(barrier?.schema==='wss-integration-barrier/v3'&&barrier.channel==='main'&&accepted.repository===expected.repository&&
    /^[a-f0-9]{64}$/.test(barrier.plan_id)&&/^[1-9][0-9]*$/.test(barrier.emitter?.run_id)&&Number.isSafeInteger(barrier.emitter?.attempt)&&barrier.emitter.attempt>=1&&barrier.emitter.workflow===context.stageWorkflow&&
    /^[1-9][0-9]*$/.test(accepted.normal_ci?.run_id)&&Number.isSafeInteger(accepted.normal_ci?.attempt)&&accepted.normal_ci.attempt>=1&&
    /^[a-f0-9]{40}$/.test(accepted.head_sha)&&execution?.source_sha===accepted.head_sha&&/^[a-f0-9]{40}$/.test(execution.authority_source_sha),'Invalid accepted-main execution binding');
  const paths=['.github/scripts',integrationConfiguration(family),'.github/workflows'];
  requireThat(canonical(Object.keys(execution.trusted||{}).sort())===canonical([...paths].sort())&&Object.values(execution.trusted).every(x=>/^[a-f0-9]{40}$/.test(x)),'Missing frozen scripts/config/full-workflow authority');
  requireThat(env?.GITHUB_ACTIONS==='true'&&env.GITHUB_EVENT_NAME==='workflow_dispatch'&&env.GITHUB_REPOSITORY===expected.repository&&env.GITHUB_REF==='refs/heads/main'&&env.GITHUB_SHA===accepted.head_sha&&env.GITHUB_WORKFLOW_SHA===accepted.head_sha&&env.GITHUB_WORKFLOW_REF===`${expected.repository}/.github/workflows/${expected.fanout}@refs/heads/main`,'Fanout must execute the verified accepted main merge');
  const git=(...args)=>execFileSync('git',['-C',resolve(source_root),...args],{encoding:'utf8'}).trim();
  requireThat(git('rev-parse','HEAD')===accepted.head_sha&&git('status','--porcelain','--untracked-files=no')==='','Execution checkout differs from the clean accepted main source');
  for(const path of paths)requireThat(git('rev-parse',`HEAD:${path}`)===execution.trusted[path],`Accepted main execution changed frozen authority: ${path}`);
  return true;
}
if(isEntrypoint(import.meta.url)) {
  const context=JSON.parse(readFileSync(process.argv[2],'utf8').replace(/^\uFEFF/,''));
  requireThat(context.operation===undefined||context.operation==='execution','Unknown staging operation');
  console.log(JSON.stringify(context.operation==='execution'?barrierExecution(context):stagingPolicy(context)));
}
