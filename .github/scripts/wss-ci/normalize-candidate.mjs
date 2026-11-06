import {isEntrypoint} from './entrypoint.mjs';
import {readFileSync,writeFileSync} from 'node:fs';
import {resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
import {CORE,candidate,canonical,requireThat} from './verify.mjs';
export function normalizeCandidate(record) {
  const {release_tag,...normalized}=record;
  requireThat(canonical(Object.keys(normalized).sort())===canonical(['repository','commit','run_id','artifact_id','archive','sha256'].sort()),'Normalized candidate must have exactly six fields');
  for(const key of ['run_id','artifact_id']) {
    requireThat(typeof normalized[key]==='string' || (Number.isSafeInteger(normalized[key]) && normalized[key]>0),'Invalid candidate numeric identity');
    normalized[key]=String(normalized[key]);
  }
  if(normalized.archive==='WSS-Universal-ci.zip') candidate(normalized);
  else requireThat(normalized.repository===CORE && /^[a-f0-9]{40}$/.test(normalized.commit) && /^[1-9][0-9]*$/.test(normalized.run_id) && /^[1-9][0-9]*$/.test(normalized.artifact_id) && /^[a-f0-9]{64}$/.test(normalized.sha256) && typeof release_tag==='string' && /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(release_tag) && normalized.archive===`WSS-Universal-${release_tag}.zip`,'Invalid diagnostic release selection');
  requireThat(release_tag===undefined || typeof release_tag==='string','Invalid diagnostic metadata');
  return normalized;
}
if(isEntrypoint(import.meta.url)) {
  const record=JSON.parse(readFileSync(process.argv[2],'utf8').replace(/^\uFEFF/,''));
  writeFileSync(process.argv[3],canonical(normalizeCandidate(record))+'\n');
}
