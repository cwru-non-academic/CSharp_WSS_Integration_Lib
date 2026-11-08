// Test-only external gh transport fixture. Loaded with NODE_OPTIONS --import;
// production entrypoints have no test hooks or environment-controlled bypasses.
import childProcess from 'node:child_process';
import {syncBuiltinESMExports} from 'node:module';
import {readFileSync,appendFileSync} from 'node:fs';
const original=childProcess.execFileSync;
childProcess.execFileSync=function(file,args,options){
 if(file!=='gh')return original.call(this,file,args,options);
 const config=JSON.parse(readFileSync(process.env.WSS_TEST_GH_RESPONSES,'utf8').replace(/^\uFEFF/,''));
 const matches=config.routes.filter(r=>JSON.stringify(r.args)===JSON.stringify(args));
 if(matches.length!==1)throw Error('Unregistered/ambiguous test-only GitHub request: '+JSON.stringify(args));
 if(config.calls_file)appendFileSync(config.calls_file,JSON.stringify(args)+'\n');
 const route=matches[0];if(route.error)throw Error(route.error);
 const bytes=route.file?readFileSync(route.file):route.base64?Buffer.from(route.base64,'base64'):Buffer.from(route.json!==undefined?JSON.stringify(route.json):route.text||'');
 return options?.encoding?bytes.toString(options.encoding):bytes;
};
syncBuiltinESMExports();
