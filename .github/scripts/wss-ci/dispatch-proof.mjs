import {isEntrypoint} from './entrypoint.mjs';
import {readFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {requireThat} from './verify.mjs';
import {channelContext} from './channels.mjs';
export function dispatchReuse({runs,run,expected}) {
  requireThat(Array.isArray(runs)&&runs.length<=1,'Ambiguous prior application dispatch; inspect manually');
  if(runs.length===0)return false;
  requireThat(/^[1-9][0-9]*$/.test(String(runs[0].id))&&String(run?.id)===String(runs[0].id),'Invalid prior application run identity');
  requireThat(run.repository?.full_name===expected.repository&&run.head_repository?.full_name===expected.repository&&run.path==='.github/workflows/promote-integration.yml'&&run.event==='workflow_dispatch'&&run.head_branch===channelContext(expected.channel||'dev').branch&&run.head_sha===expected.source_sha&&run.display_title===expected.title,'Prior application dispatch identity mismatch; inspect before write');
  requireThat(run.status==='completed'&&run.conclusion==='success','Prior application dispatch failed or remains uncertain; inspect before retry');
  return true;
}
export function dispatchIntent({artifacts,run_id,attempt,source_sha,required}) {
  requireThat(/^[1-9][0-9]*$/.test(run_id)&&attempt==='1','Automatic run-attempt replay is forbidden; inspect recovery');
  requireThat(Array.isArray(artifacts)&&artifacts.length<=1&&artifacts.every(a=>a.expired===false&&String(a.workflow_run?.id)===run_id&&a.workflow_run?.head_sha===source_sha),'Prior or uncertain application dispatch intent exists; inspect before replay');
  requireThat(!required||artifacts.length===1,'Durable current dispatch intent required before application writes');return true;
}
if(isEntrypoint(import.meta.url)) {
  const {operation,...context}=JSON.parse(readFileSync(process.argv[2],'utf8').replace(/^\uFEFF/,''));
  requireThat(['reuse','intent'].includes(operation),'Unknown dispatch proof operation');
  console.log(JSON.stringify(operation==='reuse'?dispatchReuse(context):dispatchIntent(context)));
}
