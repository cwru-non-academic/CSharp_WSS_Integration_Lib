// Test-only external gh transport fixture. Loaded with NODE_OPTIONS --import;
// production entrypoints have no test hooks or environment-controlled bypasses.
import childProcess from 'node:child_process';
import {syncBuiltinESMExports} from 'node:module';
import {readFileSync,appendFileSync} from 'node:fs';
import {GitHub} from '../github.mjs';
const original=childProcess.execFileSync;
function fixtureBytes(args){
 const config=JSON.parse(readFileSync(process.env.WSS_TEST_GH_RESPONSES,'utf8').replace(/^\uFEFF/,''));
 if(config.calls_file)appendFileSync(config.calls_file,JSON.stringify(args)+'\n');
 const matches=config.routes.filter(r=>JSON.stringify(r.args)===JSON.stringify(args));
 if(matches.length!==1)throw Error('Unregistered/ambiguous test-only GitHub request: '+JSON.stringify(args));
 const route=matches[0];if(route.error)throw Error(route.error);
 return route.file?readFileSync(route.file):route.base64?Buffer.from(route.base64,'base64'):Buffer.from(route.json!==undefined?JSON.stringify(route.json):route.text||'');
}
childProcess.execFileSync=function(file,args,options){
 if(file!=='gh')return original.call(this,file,args,options);
 const bytes=fixtureBytes(args);
 return options?.encoding?bytes.toString(options.encoding):bytes;
};
// Use the existing raw-byte seam, also used by Core's preflight proof tests.
// Capture, hash, job/run/attempt binding and recollection remain production code.
GitHub.prototype.jobLogBytes=function(repository,jobId){
 return fixtureBytes(['api',`repos/${repository}/actions/jobs/${jobId}/logs`]);
};
syncBuiltinESMExports();
