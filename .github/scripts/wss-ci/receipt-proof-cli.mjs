import {readFileSync,writeFileSync} from 'node:fs';
import {GitHub} from './github.mjs';
import {requireThat} from './verify.mjs';
import {startPreflightProof,capturePreflightArtifact,capturePreflightLog,collectPreflightProof} from './preflight-proof.mjs';
import {extractVerifiedProofArchive} from './verified-json-artifact.mjs';
import {isEntrypoint} from './entrypoint.mjs';
export function nativeProofRequest(g,input) {
  requireThat(input&&typeof input==='object','Invalid native proof request');
  if(input.operation==='start')return startPreflightProof(g,input.identity);
  const state=input.state;requireThat(state?.descriptor,'Missing captured native proof state');
  if(input.operation==='artifact'){
    const bytes=capturePreflightArtifact(g,state,input.name);
    extractVerifiedProofArchive(bytes,input.destination);return state;
  }
  if(input.operation==='log'){
    const bytes=capturePreflightLog(g,state,input.job_id);
    writeFileSync(input.destination,bytes,{flag:'wx'});return state;
  }
  if(input.operation==='complete'){
    collectPreflightProof(g,state.descriptor);return state.descriptor;
  }
  throw Error('Unknown native proof operation');
}
if(isEntrypoint(import.meta.url)){
  const [request,response]=process.argv.slice(2);requireThat(request&&response&&process.argv.length===4,'Expected native proof request/response paths');
  const result=nativeProofRequest(new GitHub(),JSON.parse(readFileSync(request,'utf8').replace(/^\uFEFF/,'')));
  writeFileSync(response,JSON.stringify(result)+'\n',{flag:'wx'});
}
