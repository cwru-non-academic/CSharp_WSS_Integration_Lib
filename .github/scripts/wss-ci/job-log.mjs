import {execFileSync} from 'node:child_process';
import {constants,closeSync,fstatSync,lstatSync,mkdtempSync,openSync,readSync,realpathSync,rmdirSync,unlinkSync,writeSync} from 'node:fs';
import {request} from 'node:https';
import {dirname,isAbsolute,join} from 'node:path';
import {tmpdir} from 'node:os';
import {fileURLToPath} from 'node:url';
import {isEntrypoint} from './entrypoint.mjs';

// The API returns a temporary HTTPS Location (valid for one minute). Follow
// exactly one authenticated API redirect, without forwarding its credentials.
// No gh stdout, decoding, decompression, caller URL, or alternate HTTP method.
const MAX_BYTES=64*1024*1024, DEADLINE_MS=120000, MAX_INPUT=32768;
const failure=()=>new Error('Bounded GitHub job log download failed');
function ensure(value){if(!value)throw failure();}
function identity(repository,jobId){
  ensure(typeof repository==='string'&&repository.length<=140&&/^[A-Za-z0-9_-]+\/[A-Za-z0-9_.-]+$/.test(repository)&&!['.','..'].includes(repository.split('/')[1]));
  ensure(typeof jobId==='string'&&/^[1-9][0-9]{0,19}$/.test(jobId));
}
function tokenValue(token){ensure(typeof token==='string'&&token.length>0&&token.length<=16384&&/^[\x21-\x7e]+$/.test(token));return token;}
function privateDirectory(){
  const base=realpathSync(tmpdir()),directory=mkdtempSync(join(base,'wss-job-log-')),owner=lstatSync(directory);
  try {
    ensure(isAbsolute(directory)&&dirname(directory)===base&&!lstatSync(directory).isSymbolicLink()&&realpathSync(directory)===directory);
    if(process.platform==='win32'){
      // POSIX mkdtemp is 0700; Windows needs a protected current-user DACL.
      const script="$ErrorActionPreference='Stop';$sid=[Security.Principal.WindowsIdentity]::GetCurrent().User;$acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetOwner($sid);$acl.SetAccessRuleProtection($true,$false);$rule=[Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow');$acl.AddAccessRule($rule);Set-Acl -LiteralPath $env:WSS_PRIVATE_LOG_DIRECTORY -AclObject $acl";
      execFileSync('pwsh',['-NoProfile','-NonInteractive','-EncodedCommand',Buffer.from(script,'utf16le').toString('base64')],{env:{...childEnvironment(),WSS_PRIVATE_LOG_DIRECTORY:directory},stdio:['ignore','pipe','pipe'],maxBuffer:1024,timeout:10000,windowsHide:true});
    }else ensure((lstatSync(directory).mode&0o077)===0);
    directoryIdentity(directory,owner);return {directory,owner};
  }catch{try{directoryIdentity(directory,owner);rmdirSync(directory);}catch{}throw failure();}
}
function childEnvironment(){
  // The token travels only through the bounded stdin pipe. Do not inherit Node
  // preload/TLS overrides or unrelated credentials into this fixed-purpose child.
  return Object.fromEntries(Object.keys(process.env).filter(key=>['PATH','SYSTEMROOT','WINDIR','TEMP','TMP','TMPDIR','HOME','USERPROFILE','PATHEXT'].includes(key.toUpperCase())).map(key=>[key,process.env[key]]));
}
function sameFile(actual,expected){return expected&&actual.dev===expected.dev&&actual.ino===expected.ino;}
function directoryIdentity(directory,owner){
  const current=lstatSync(directory);
  ensure(isAbsolute(directory)&&current.isDirectory()&&!current.isSymbolicLink()&&realpathSync(directory)===directory&&sameFile(current,owner));
}
function fileIdentity(file,owner){
  const current=lstatSync(file);
  ensure(current.isFile()&&!current.isSymbolicLink()&&current.nlink===1&&sameFile(current,owner));
}
function cleanup(directory,directoryOwner,file,fileOwner){
  // No recursive cleanup. Delete only our exact file in our exact directory;
  // replacements are left untouched rather than following a path/reparse point.
  directoryIdentity(directory,directoryOwner);ensure(dirname(file)===directory);
  let last;
  for(let attempt=0;attempt<3;attempt++){
    try{
      directoryIdentity(directory,directoryOwner);
      if(fileOwner)try{fileIdentity(file,fileOwner);unlinkSync(file);}catch(error){if(error.code!=='ENOENT')throw error;}
      rmdirSync(directory);return;
    }catch(error){last=error;}
  }
  if(last)throw failure();
}

// Preserve the synchronous evidence API. The child writes to an already-open
// private file descriptor, never a pathname or a terminal. Its stdout is only a
// bounded byte-count acknowledgement; parent errors never include child output.
export function downloadJobLogBytes(g,repository,jobId){
  identity(repository,jobId);const token=tokenValue(g?.environment?.GH_TOKEN);
  let directory,directoryOwner,file,fileOwner,fd;
  try{
    ({directory,owner:directoryOwner}=privateDirectory());file=join(directory,'body');
    fd=openSync(file,constants.O_CREAT|constants.O_EXCL|constants.O_RDWR|(constants.O_NOFOLLOW||0),0o600);fileOwner=fstatSync(fd);
    const output=execFileSync(process.execPath,[fileURLToPath(import.meta.url),'--download-job-log'],{
      input:JSON.stringify({repository,jobId,token}),env:childEnvironment(),
      stdio:['pipe','pipe','pipe',fd],encoding:'utf8',maxBuffer:1024,timeout:DEADLINE_MS+5000,killSignal:'SIGKILL',windowsHide:true,
    });
    ensure(/^\{"bytes":(?:0|[1-9][0-9]{0,7})\}\n$/.test(output));
    directoryIdentity(directory,directoryOwner);fileIdentity(file,fileOwner);
    const {bytes}=JSON.parse(output),stat=fstatSync(fd);
    ensure(bytes<=MAX_BYTES&&stat.isFile()&&stat.nlink===1&&stat.size===bytes);
    const result=Buffer.alloc(bytes);let offset=0;
    while(offset<bytes){const count=readSync(fd,result,offset,bytes-offset,offset);ensure(count>0);offset+=count;}
    ensure(fstatSync(fd).size===bytes);directoryIdentity(directory,directoryOwner);fileIdentity(file,fileOwner);return result;
  }catch{throw failure();}
  finally{
    try{if(fd!==undefined)closeSync(fd);}catch{throw failure();}
    finally{if(directory)try{cleanup(directory,directoryOwner,file||join(directory,'body'),fileOwner);}catch{throw failure();}}
  }
}

async function response(url,headers,signal){
  return new Promise((resolve,reject)=>{
    let headerTimer;
    const req=request(url,{method:'GET',headers,signal,rejectUnauthorized:true,maxHeaderSize:32768},res=>{clearTimeout(headerTimer);resolve(res);});
    // DNS/connect/TLS/headers have a separate bound; socket inactivity remains
    // bounded while streaming. The outer deadline spans both HTTP hops.
    headerTimer=setTimeout(()=>req.destroy(failure()),15000);
    req.setTimeout(30000,()=>req.destroy(failure()));
    req.once('error',()=>{clearTimeout(headerTimer);reject(failure());});req.end();
  });
}
async function download({repository,jobId,token}){
  identity(repository,jobId);tokenValue(token);
  const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),DEADLINE_MS);
  let res;
  try{
    res=await response(`https://api.github.com/repos/${repository}/actions/jobs/${jobId}/logs`,{
      Authorization:`Bearer ${token}`,Accept:'application/vnd.github+json','Accept-Encoding':'identity',
      'User-Agent':'wss-native-proof','X-GitHub-Api-Version':'2022-11-28',
    },controller.signal);
    if(res.statusCode===302){
      const location=res.headers.location;
      ensure(typeof location==='string'&&location.length<=16384&&!/[\x00-\x20\x7f]/.test(location));
      const next=new URL(location);
      ensure(next.protocol==='https:'&&next.hostname&&(!next.port||next.port==='443')&&!next.username&&!next.password&&!next.hash);
      res.destroy();
      // Only this server-provided Location is accepted. Storage does not receive
      // Authorization, API headers, cookies, or a Referer, and cannot redirect.
      res=await response(next,{'Accept-Encoding':'identity','User-Agent':'wss-native-proof'},controller.signal);
    }
    ensure(res.statusCode===200&&(!res.headers['content-encoding']||res.headers['content-encoding']==='identity'));
    const declared=res.headers['content-length'];
    ensure(declared===undefined||typeof declared==='string'&&/^(0|[1-9][0-9]*)$/.test(declared)&&Number.isSafeInteger(Number(declared))&&Number(declared)<=MAX_BYTES);
    let bytes=0;
    for await(const chunk of res){
      ensure(Buffer.isBuffer(chunk)&&chunk.length<=MAX_BYTES-bytes);bytes+=chunk.length;
      let offset=0;while(offset<chunk.length){const count=writeSync(3,chunk,offset,chunk.length-offset);ensure(count>0);offset+=count;}
    }
    ensure(res.complete===true&&!res.aborted&&(declared===undefined||bytes===Number(declared))&&!controller.signal.aborted);
    return bytes;
  }finally{clearTimeout(timer);res?.destroy();}
}
if(isEntrypoint(import.meta.url)){
  try{
    ensure(process.argv.length===3&&process.argv[2]==='--download-job-log');
    let input='',count=0;
    for await(const chunk of process.stdin){count+=chunk.length;ensure(count<=MAX_INPUT);input+=chunk.toString('utf8');}
    const options=JSON.parse(input);ensure(options&&Object.keys(options).sort().join(',')==='jobId,repository,token');
    const bytes=await download(options);process.stdout.write(JSON.stringify({bytes})+'\n');
  }catch{process.stderr.write('Bounded GitHub job log download failed\n');process.exitCode=1;}
}
