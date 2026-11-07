import {readFileSync,writeFileSync,appendFileSync} from 'node:fs';
import {captureLocalTestVariables,snapshotName} from './local-test-variable-snapshot.mjs';
import {canonical,requireThat} from './verify.mjs';
// Actual repository-local caller only. No secrets, API tokens or selected checkout.
const [output,...extra]=process.argv.slice(2);
requireThat(output&&extra.length===0&&process.env.GITHUB_OUTPUT,'Expected snapshot output and Actions output context');
const event=JSON.parse(readFileSync(process.env.GITHUB_EVENT_PATH,'utf8'));
const request=JSON.parse(event.inputs?.request||'null');
const snapshot=captureLocalTestVariables(request,process.env);
writeFileSync(output,canonical(snapshot)+'\n',{flag:'wx'});
appendFileSync(process.env.GITHUB_OUTPUT,`artifact_name=${snapshotName(request)}\n`);
