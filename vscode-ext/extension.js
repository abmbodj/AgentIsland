// Agent Island companion: <scheme>://abmbodj.agent-island-jump/focus?pids=1,2,3
// Shows the integrated terminal whose shell PID is one of the agent's ancestor PIDs.
const vscode = require('vscode');

exports.activate = (context) => {
  context.subscriptions.push(vscode.window.registerUriHandler({
    async handleUri(uri) {
      const pids = new Set((new URLSearchParams(uri.query).get('pids') || '').split(',').map(Number).filter(Boolean));
      for (const terminal of vscode.window.terminals) {
        const pid = await terminal.processId;
        if (pid && pids.has(pid)) {
          terminal.show(false);
          return;
        }
      }
    },
  }));
};

exports.deactivate = () => {};
