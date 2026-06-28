/**
 * VS Code extension entry point for Ghostty config language support.
 *
 * Launches `ghostty-config-lsp` as a Language Server and wires it up to
 * files matching the Ghostty config path pattern.
 */

import * as path from "path";
import {
  workspace,
  ExtensionContext,
  window,
  OutputChannel,
} from "vscode";
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
  TransportKind,
} from "vscode-languageclient/node";

let client: LanguageClient | undefined;

export function activate(context: ExtensionContext): void {
  const config = workspace.getConfiguration("ghosttyConfig");
  const serverPath: string = config.get("serverPath", "ghostty-config-lsp");
  const traceServer: string = config.get("trace.server", "off");

  // The server is launched as a child process communicating over stdio.
  const serverOptions: ServerOptions = {
    run: {
      command: serverPath,
      transport: TransportKind.stdio,
    },
    debug: {
      command: serverPath,
      transport: TransportKind.stdio,
    },
  };

  const clientOptions: LanguageClientOptions = {
    // Activate for documents identified as 'ghostty-config' language.
    documentSelector: [{ language: "ghostty-config" }],
    synchronize: {
      // Re-validate when any .ghostty file changes (if the user has multi-file setups).
      fileEvents: workspace.createFileSystemWatcher("**/*.ghostty"),
    },
    traceOutputChannel: traceServer !== "off"
      ? window.createOutputChannel("Ghostty LSP Trace")
      : undefined,
  };

  client = new LanguageClient(
    "ghostty-config-lsp",
    "Ghostty Config Language Server",
    serverOptions,
    clientOptions,
  );

  client.start();
}

export function deactivate(): Thenable<void> | undefined {
  if (!client) return undefined;
  return client.stop();
}
