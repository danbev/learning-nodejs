const async_hooks = require('async_hooks');
const fs = require('fs');
const util = require('util');
const asyncHook = async_hooks.createHook({ init, before, after, destroy });
asyncHook.enable();

function debug(...args) {
  fs.writeFileSync(1, `${util.format(...args)}\n`, { flag: 'a' });
}

function init(asyncId, type, triggerAsyncId, resource) {
  if (type === "Timeout") {
    debug("asyncId for Timout:",  asyncId);
  }
}

function before(asyncId) {
    debug("before:",  asyncId);
}

function after(asyncId) {
    debug("after:",  asyncId);
}

function destroy(asyncId) {
    debug("destroy:",  asyncId);
}

setTimeout(() => debug('in timeout...'), 0);
