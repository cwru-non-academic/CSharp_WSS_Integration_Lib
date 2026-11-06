import {existsSync,realpathSync} from 'node:fs';
import {fileURLToPath} from 'node:url';

// One CLI/import boundary for Core and receiver modules. Canonical paths handle
// macOS /var aliases and Windows junctions; assertion sentinels never enter CLIs.
export function isEntrypoint(url,argv=process.argv,execArgv=process.execArgv) {
  // --eval imports are assertions, even if their fixed argv sentinel happens
  // to exist or is a symlink to this module. Never turn one into a receipt CLI.
  if(execArgv.some(arg=>['--eval','-e','--print','-p'].includes(arg)||arg.startsWith('--eval=')||arg.startsWith('--print=')))return false;
  const path=argv?.[1];
  return typeof path==='string'&&path!=='-'&&existsSync(path)&&realpathSync(path)===realpathSync(fileURLToPath(url));
}
