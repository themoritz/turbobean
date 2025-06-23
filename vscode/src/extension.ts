import * as vscode from 'vscode';
import { LanguageClientOptions, ServerOptions, LanguageClient, Executable, TransportKind } from 'vscode-languageclient/node';

let client: LanguageClient;

export function activate(context: vscode.ExtensionContext) {
	console.log('Shit, your extension "vscode" is now active!');

	const exe: Executable = {
		command: '/Users/moritz/code/zigcount/zig-out/bin/zigcount',
		args: ['--lsp'],
		transport: TransportKind.stdio,
	}

	const serverOptions: ServerOptions = {
		run: exe,
		debug: exe
	}

	// Options to control the language client
	const clientOptions: LanguageClientOptions = {
		// Register the server for plain text documents
		documentSelector: [{ scheme: 'file', language: 'beancount' }],
		synchronize: {
			fileEvents: vscode.workspace.createFileSystemWatcher('**/.bean')
		},
		outputChannel: vscode.window.createOutputChannel('Zigcount'),
	};

	// Create the language client and start the client.
	client = new LanguageClient(
		'zigcount',
		'zigcount VSCode extension',
		serverOptions,
		clientOptions
	);

	// Start the client. This will also launch the server
	client.start();
}

// This method is called when your extension is deactivated
export function deactivate(): Thenable<void> | undefined {
	if (!client) {
		return undefined;
	}
	return client.stop();
}
