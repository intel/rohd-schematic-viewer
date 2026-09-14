/* ---------------------------------------------------------------------------
 Copyright (C) 2026 Intel Corporation.
 SPDX-License-Identifier: BSD-3-Clause
 Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>
 --------------------------------------------------------------------------- */

const vscode = require('vscode');
const path = require('path');
const fs = require('fs');

// Generated beside extension.js from rohd_devtools_widgets extension assets.
const { resolveFlcPath, buildModuleInfo, lookupSignalFrames } =
  require('./shared/module_info_helper');

// Output channel for extension logging
let outputChannel;
let nextViewerId = 1;

/**
 * @param {vscode.ExtensionContext} context
 */
function activate(context) {
  // Create output channel for debugging
  outputChannel = vscode.window.createOutputChannel('ROHD Schematic Viewer');
  outputChannel.appendLine('VSCode Schematic Visualizer is now active');
  console.log('VSCode Schematic Visualizer is now active');

  const provider = new SchematicEditorProvider(context);
  context.subscriptions.push(
    vscode.commands.registerCommand(
      'rohd-schematic-viewer.receiveSignals',
      payload => provider.receiveSignals(payload),
    ),
    vscode.commands.registerCommand(
      'rohd-schematic-viewer.signalViewerAvailability',
      payload => provider.updateSignalViewerAvailability(payload),
    ),
    vscode.window.registerCustomEditorProvider('vscodeSchematicViewer.yosysJson', provider, {
      webviewOptions: { retainContextWhenHidden: true },
      supportsMultipleEditorsPerDocument: false,
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('vscodeSchematicViewer.openSchematic', async (uri) => {
      if (!uri && vscode.window.activeTextEditor) uri = vscode.window.activeTextEditor.document.uri;
      if (uri) await vscode.commands.executeCommand('vscode.openWith', uri, 'vscodeSchematicViewer.yosysJson');
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('vscodeSchematicViewer.openDartAsSchematic', async (uri) => {
      try {
        if (!uri && vscode.window.activeTextEditor) uri = vscode.window.activeTextEditor.document.uri;
        if (!uri) return;
        // Run a simple dart command to verify Dart is available
        const { exec } = require('child_process');
        exec('dart --version', { cwd: vscode.workspace.rootPath || undefined }, (err, stdout, stderr) => {
          if (err) {
            vscode.window.showErrorMessage('Dart not available: ' + (err.message || stderr));
            return;
          }
          // Log the dart version
          try { console.log('Dart version:', stdout || stderr); } catch (e) {}
          // Compute corresponding JSON path: replace .dart with .json
          const fsPath = uri.fsPath;
          const jsonPath = fsPath.replace(/\.dart$/i, '.json');
          const jsonUri = vscode.Uri.file(jsonPath);
          // If the json file exists, open it with the custom editor; otherwise warn
          const fs = require('fs');
          if (fs.existsSync(jsonPath)) {
            vscode.commands.executeCommand('vscode.openWith', jsonUri, 'vscodeSchematicViewer.yosysJson');
          } else {
            vscode.window.showWarningMessage('Corresponding JSON not found: ' + jsonPath);
          }
        });
      } catch (e) {
        vscode.window.showErrorMessage('Error launching Dart: ' + e.message);
      }
    })
  );
}

class SchematicEditorProvider {
  constructor(context) {
    this._context = context;
    this._webviews = new Map();
  }

  receiveSignals(payload) {
    const targetViewerId = payload?.targetViewerId;
    const signalPaths = Array.isArray(payload?.signalPaths)
      ? payload.signalPaths.filter(signalPath => typeof signalPath === 'string')
      : [];
    if (typeof targetViewerId !== 'string' || signalPaths.length === 0) {
      outputChannel.appendLine('[SignalViewers] ignored invalid receiveSignals payload');
      return;
    }
    let targetWebview = this._webviews.get(targetViewerId);
    if (!targetWebview && this._webviews.size === 1) {
      targetWebview = this._webviews.values().next().value;
      outputChannel.appendLine(
        `[SignalViewers] target ${targetViewerId} was stale; using the active schematic webview`,
      );
    }
    if (!targetWebview) {
      outputChannel.appendLine(
        `[SignalViewers] no schematic webview found for ${targetViewerId}`,
      );
      return;
    }
    targetWebview.postMessage({
      type: 'incomingSignals',
      sourceViewerId: payload?.sourceViewerId,
      signalPaths,
    });
    outputChannel.appendLine(
      `[SignalViewers] delivered ${signalPaths.length} incoming signal(s) to ${targetViewerId}`,
    );
  }

  updateSignalViewerAvailability(payload) {
    const viewerId = payload?.viewerId;
    if (typeof viewerId !== 'string') {
      return;
    }
    const availableViewers = Array.isArray(payload?.availableViewers)
      ? payload.availableViewers
      : [];
    this._webviews.get(viewerId)?.postMessage({
      type: 'signalViewerAvailability',
      viewerId,
      canSendSignals: availableViewers.length > 0,
      availableViewers,
    });
  }

  async openCustomDocument(uri, openContext, token) { return { uri, dispose: () => {} }; }

  // ─── Source-trace resolution — delegated to shared helper ───────────────

  async _buildModuleInfo(documentUri, moduleName) {
    return buildModuleInfo(documentUri, moduleName, outputChannel);
  }

  async _resolveFlcPath(documentUri) {
    return resolveFlcPath(documentUri, outputChannel);
  }

  async _lookupSignalFrames(flcPath, moduleName, signalName, format) {
    return lookupSignalFrames(flcPath, moduleName, signalName, format, outputChannel);
  }

  // ─── Custom editor ────────────────────────────────────────────────

  async resolveCustomEditor(document, webviewPanel, token) {
    const localResourceRoots = [
      vscode.Uri.file(path.join(this._context.extensionPath, 'media')),
      vscode.Uri.file(path.dirname(document.uri.fsPath))
    ];

    // Add Flutter web build path
    const flutterWebPath = path.join(this._context.extensionPath, 'flutter_web');
    if (fs.existsSync(flutterWebPath)) {
      localResourceRoots.push(vscode.Uri.file(flutterWebPath));
    }

    webviewPanel.webview.options = { enableScripts: true, localResourceRoots };

    const jsonContent = await vscode.workspace.fs.readFile(document.uri);
    const jsonText = Buffer.from(jsonContent).toString('utf8');

    outputChannel.appendLine('[resolveCustomEditor] Loading Flutter renderer for: ' + document.uri.fsPath);
    webviewPanel.webview.html = this.getFlutterHtmlForWebview(webviewPanel.webview, document.uri, jsonText);

    const viewerId = `rohd-schematic-viewer:${nextViewerId++}`;
    this._webviews.set(viewerId, webviewPanel.webview);
    let registered = false;
    const registerSignalViewer = async () => {
      if (registered) {
        return;
      }
      registered = true;
      try {
        const availableViewers = await vscode.commands.executeCommand(
          'rohd.registerSignalViewer',
          {
            viewerId,
            label: `Schematic Viewer: ${path.basename(document.uri.fsPath)}`,
            receiveCommand: 'rohd-schematic-viewer.receiveSignals',
            availabilityCommand: 'rohd-schematic-viewer.signalViewerAvailability',
          },
        );
        webviewPanel.webview.postMessage({
          type: 'signalViewerAvailability',
          viewerId,
          canSendSignals: Array.isArray(availableViewers) && availableViewers.length > 0,
          availableViewers: Array.isArray(availableViewers) ? availableViewers : [],
        });
      } catch (error) {
        registered = false;
        outputChannel.appendLine(`[SignalViewers] register failed: ${error}`);
        webviewPanel.webview.postMessage({
          type: 'signalViewerAvailability',
          viewerId,
          canSendSignals: false,
          availableViewers: [],
        });
      }
    };
    webviewPanel.onDidDispose(() => {
      this._webviews.delete(viewerId);
      if (registered) {
        vscode.commands.executeCommand('rohd.unregisterSignalViewer', { viewerId }).then(
          undefined,
          error => outputChannel.appendLine(`[SignalViewers] unregister failed: ${error}`),
        );
      }
    });

    // Handle messages from the webview (e.g., reload-from-disk, cross-probe)
    webviewPanel.webview.onDidReceiveMessage(async (message) => {
      if (message.type === 'signalViewerReady') {
        await registerSignalViewer();
      } else if (message.type === 'sendSignals') {
        const signalPaths = Array.isArray(message.signalPaths)
          ? message.signalPaths.filter(signalPath => typeof signalPath === 'string')
          : [];
        if (signalPaths.length > 0) {
          try {
            await vscode.commands.executeCommand('rohd.sendSignals', {
              sourceViewerId: viewerId,
              signalPaths,
            });
          } catch (error) {
            outputChannel.appendLine(`[SignalViewers] send failed: ${error}`);
          }
        }
      } else if (message.type === 'goToSource') {
        // ── Source-trace cross-probe via rohd_extension ──
        const signals = message.signals || [];
        const format = message.format || null;  // 'rohd', 'sv', or null (both)
        outputChannel.appendLine('[crossProbe] goToSource: ' + signals.length +
          ' signal(s)' + (format ? ', format=' + format : ''));

        const flcPath = await this._resolveFlcPath(document.uri);
        if (!flcPath) {
          outputChannel.appendLine('[crossProbe] No source trace found for ' + document.uri.fsPath);
          vscode.window.showWarningMessage(
            'ROHD: No embedded source trace or .flc.json sidecar found.');
          return;
        }
        outputChannel.appendLine('[crossProbe] Using FLC: ' + flcPath);

        const allFrames = [];
        for (const sig of signals) {
          try {
            const frames = await this._lookupSignalFrames(flcPath, sig.module || null, sig.name, format || undefined);
            outputChannel.appendLine('[crossProbe] ' + sig.name + ': ' + frames.length + ' frame(s)');
            allFrames.push(...frames);
          } catch (e) {
            outputChannel.appendLine('[crossProbe] lookup error for ' + sig.name + ': ' + e.message);
          }
        }

        if (allFrames.length === 0) {
          const desc = format ? format.toUpperCase() + ' ' : '';
          outputChannel.appendLine('[crossProbe] No ' + desc + 'frames resolved');
          vscode.window.showInformationMessage(
            'ROHD: No ' + desc + 'source locations found in FLC for the selected signal(s).');
          return;
        }

        outputChannel.appendLine('[crossProbe] Resolved ' + allFrames.length +
          ' frames (' + allFrames.filter(f => f.type === 'sv').length + ' SV, ' +
          allFrames.filter(f => f.type === 'rohd').length + ' ROHD)');

        try {
          if (allFrames.length === 1) {
            await vscode.commands.executeCommand('rohd.openSourceLocation', allFrames[0]);
          } else {
            await vscode.commands.executeCommand('rohd.openSourceLocations', {
              frames: allFrames,
              index: 0,
            });
          }
        } catch (e) {
          outputChannel.appendLine('[crossProbe] rohd extension not available: ' + e.message);
          vscode.window.showInformationMessage('Install the ROHD extension for source navigation.');
        }
      } else if (message.type === 'openSourceLocation') {
        // ── Legacy: pre-resolved single-frame cross-probe ──
        outputChannel.appendLine('[crossProbe] openSourceLocation: ' + message.file + ':' + message.line + ':' + message.col);
        try {
          await vscode.commands.executeCommand('rohd.openSourceLocation', {
            file: message.file,
            line: message.line,
            col: message.col,
          });
        } catch (e) {
          outputChannel.appendLine('[crossProbe] rohd.openSourceLocation not available: ' + e.message);
          vscode.window.showInformationMessage('Install the ROHD extension for source navigation.');
        }
      } else if (message.type === 'openSourceLocations') {
        // ── Legacy: pre-resolved multi-frame cross-probe ──
        outputChannel.appendLine('[crossProbe] openSourceLocations: ' + (message.frames || []).length + ' frames');
        try {
          await vscode.commands.executeCommand('rohd.openSourceLocations', {
            frames: message.frames,
            index: message.index || 0,
          });
        } catch (e) {
          outputChannel.appendLine('[crossProbe] rohd.openSourceLocations not available: ' + e.message);
          vscode.window.showInformationMessage('Install the ROHD extension for source navigation.');
        }
      } else if (message.type === 'reload') {
        outputChannel.appendLine('[reload] Re-reading file from disk: ' + document.uri.fsPath);
        try {
          const content = await vscode.workspace.fs.readFile(document.uri);
          const text = Buffer.from(content).toString('utf8');
          const base64Data = Buffer.from(text, 'utf8').toString('base64');
          webviewPanel.webview.postMessage({ type: 'schematicData', jsonBase64: base64Data });
          outputChannel.appendLine('[reload] Sent updated schematic data, length=' + text.length);
        } catch (e) {
          outputChannel.appendLine('[reload] Error: ' + e.message);
          webviewPanel.webview.postMessage({ type: 'reloadError', error: e.message });
        }
      } else if (message.type === 'savePng') {
        // ── Save PNG with native file dialog ──
        const suggestedName = message.suggestedName || 'schematic.png';
        const base64Data = message.data;
        if (!base64Data) {
          outputChannel.appendLine('[savePng] No data received');
          webviewPanel.webview.postMessage({ type: 'savePngResult', success: false, error: 'No data' });
          return;
        }
        outputChannel.appendLine('[savePng] Prompting save dialog, suggested: ' + suggestedName);
        try {
          const defaultUri = vscode.Uri.file(
            path.join(
              vscode.workspace.workspaceFolders?.[0]?.uri?.fsPath || require('os').homedir(),
              suggestedName
            )
          );
          const saveUri = await vscode.window.showSaveDialog({
            defaultUri,
            filters: { 'PNG Image': ['png'] },
            title: 'Save Schematic Snapshot',
          });
          if (!saveUri) {
            outputChannel.appendLine('[savePng] User cancelled');
            webviewPanel.webview.postMessage({ type: 'savePngResult', success: false, error: 'Cancelled' });
            return;
          }
          const pngBytes = Buffer.from(base64Data, 'base64');
          await vscode.workspace.fs.writeFile(saveUri, pngBytes);
          const savedPath = saveUri.fsPath;
          outputChannel.appendLine('[savePng] Saved: ' + savedPath);
          vscode.window.showInformationMessage('Schematic saved: ' + path.basename(savedPath));
          webviewPanel.webview.postMessage({ type: 'savePngResult', success: true, path: savedPath });
        } catch (e) {
          outputChannel.appendLine('[savePng] Error: ' + e.message);
          vscode.window.showErrorMessage('Failed to save PNG: ' + e.message);
          webviewPanel.webview.postMessage({ type: 'savePngResult', success: false, error: e.message });
        }

      // ── Extension handshake: availability ping ────────────────────────────
      } else if (message.type === 'ping') {
        webviewPanel.webview.postMessage({
          type: 'pingResponse',
          available: true,
          version: '1.0',
          requestId: message.requestId || null,
        });

      // ── Extension handshake: module source info ───────────────────────────
      } else if (message.type === 'getModuleInfo' || message.type === 'setActiveModule') {
        const moduleName = message.module || null;
        outputChannel.appendLine('[moduleInfo] Query for module: ' + moduleName);
        const info = await this._buildModuleInfo(document.uri, moduleName);
        outputChannel.appendLine('[moduleInfo] Result: ' + JSON.stringify(info));
        const responseMsg = {
          type: message.type === 'setActiveModule' ? 'setActiveModuleResult' : 'getModuleInfoResult',
          requestId: message.requestId || null,
          ...info,
        };
        outputChannel.appendLine('[moduleInfo] Posting response: ' + JSON.stringify(responseMsg));
        webviewPanel.webview.postMessage(responseMsg);

      // ── FLC frame lookup: returns frames to webview for popup selection ──
      } else if (message.type === 'lookupSignalFrames') {
        const signals = message.signals || [];
        const format = message.format || null;
        const requestId = message.requestId || null;
        outputChannel.appendLine('[lookupFrames] ' + signals.length + ' signal(s), format=' + (format || 'all'));

        const flcPath = await this._resolveFlcPath(document.uri);
        if (!flcPath) {
          webviewPanel.webview.postMessage({
            type: 'lookupSignalFramesResult',
            requestId,
            frames: [],
            error: 'No embedded source trace or .flc.json sidecar found.',
          });
          return;
        }

        const allFrames = [];
        for (const sig of signals) {
          const frames = await this._lookupSignalFrames(
            flcPath, sig.module || null, sig.name, format || undefined);
          allFrames.push(...frames);
        }
        outputChannel.appendLine('[lookupFrames] Resolved ' + allFrames.length + ' frames');
        webviewPanel.webview.postMessage({
          type: 'lookupSignalFramesResult',
          requestId,
          frames: allFrames,
        });
      }
    });
  }

  getFlutterHtmlForWebview(webview, documentUri, jsonContent) {
    const flutterWebPath = path.join(this._context.extensionPath, 'flutter_web');
    
    outputChannel.appendLine('Flutter renderer requested for: ' + documentUri.fsPath);
    outputChannel.appendLine('Looking for Flutter web build at: ' + flutterWebPath);
    
    // Check if Flutter web build exists
    if (!fs.existsSync(flutterWebPath)) {
      outputChannel.appendLine('ERROR: Flutter web build not found');
      return `<!DOCTYPE html>
<html><head><meta charset="UTF-8"></head>
<body style="background:#1e1e1e;color:#f48771;padding:20px;font-family:monospace;">
<h2>Flutter Renderer Not Available</h2>
<p>The Flutter web build is not included in this extension package.</p>
<p>To use the Flutter renderer, rebuild the extension with:</p>
<pre>make web && make build</pre>
<p>Expected Flutter web build at: flutter_web/</p>
</body></html>`;
    }

    const flutterUri = webview.asWebviewUri(vscode.Uri.file(flutterWebPath));
    const jsonBase64 = Buffer.from(jsonContent, 'utf8').toString('base64');
    
    outputChannel.appendLine('Flutter URI: ' + flutterUri);
    outputChannel.appendLine('JSON content length: ' + jsonContent.length + ' bytes');
    
    // Read the Flutter web index.html and modify it to inject the schematic data
    const indexPath = path.join(flutterWebPath, 'index.html');
    let indexHtml = fs.readFileSync(indexPath, 'utf8');
    
    // Note: web/index.html already references assets at their correct bundled location (assets/assets/...)
    // since Flutter bundles assets declared as "assets/" to "assets/assets/" on web
    // No path rewriting needed if index.html already uses correct paths
    
    // Replace the base href with the correct webview URI (include trailing slash)
    // This allows Flutter's relative path loading to work correctly
    indexHtml = indexHtml.replace(/<base href="[^"]*">/g, `<base href="${flutterUri}/">`);
    
    // Remove X-UA-Compatible meta tag (not supported in webview)
    indexHtml = indexHtml.replace(/<meta[^>]*http-equiv="X-UA-Compatible"[^>]*>/gi, '');
    
    // Inject the schematic JSON data as a global variable before Flutter loads
    const injectScript = `<script>
      window.SCHEMATIC_JSON_BASE64 = "${jsonBase64}";
      window.VSCODE_WEBVIEW = true;
      window._vscodeApi = acquireVsCodeApi();
      console.log('ROHD Schematic Viewer: Injected schematic data, length=' + window.SCHEMATIC_JSON_BASE64.length);
    </script>`;
    indexHtml = indexHtml.replace('</head>', injectScript + '\n</head>');
    
    // Update CSP for Flutter web
    const csp = `default-src 'none'; connect-src ${webview.cspSource} https: blob:; style-src ${webview.cspSource} 'unsafe-inline' https:; script-src ${webview.cspSource} 'unsafe-inline' 'unsafe-eval' 'wasm-unsafe-eval' https: blob:; img-src ${webview.cspSource} https: data: blob:; font-src ${webview.cspSource} https: data:; worker-src ${webview.cspSource} blob:;`;
    indexHtml = indexHtml.replace(/<meta http-equiv="Content-Security-Policy"[^>]*>/i, '');
    indexHtml = indexHtml.replace('<head>', `<head>\n<meta http-equiv="Content-Security-Policy" content="${csp}">`);
    
    outputChannel.appendLine('Generated Flutter HTML, length: ' + indexHtml.length);
    
    return indexHtml;
  }
}

function deactivate() {}

module.exports = { activate, deactivate };
