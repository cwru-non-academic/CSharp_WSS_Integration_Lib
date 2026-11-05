import {readFileSync} from 'node:fs';
import {selectNormalRun} from './normal-ci.mjs';
if(process.argv.length!==3) throw new Error('Usage: normal-ci-select.mjs context.json');
const {runs,target,head,merged_at}=JSON.parse(readFileSync(process.argv[2],'utf8').replace(/^\uFEFF/,''));
console.log(JSON.stringify(selectNormalRun(runs,target,head,merged_at)));
