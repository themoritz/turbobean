import * as vscode from 'vscode';
import { LanguageClientOptions, ServerOptions, LanguageClient, Executable, TransportKind } from 'vscode-languageclient/node';

let client: LanguageClient;

export function activate(_: vscode.ExtensionContext) {
    const exe: Executable = {
        command: '/Users/moritz/code/zigcount/zig-out/bin/zigcount',
        args: ['--lsp'],
        transport: TransportKind.stdio,
    };

    const serverOptions: ServerOptions = {
        run: exe,
        debug: exe
    };

    const clientOptions: LanguageClientOptions = {
        documentSelector: [{ scheme: 'file', language: 'beancount' }],
        synchronize: {
            fileEvents: vscode.workspace.createFileSystemWatcher('**/.bean')
        },
        outputChannel: vscode.window.createOutputChannel('Zigcount'),
    };

    client = new LanguageClient(
        'zigcount',
        'zigcount VSCode extension',
        serverOptions,
        clientOptions
    );

    client.start();
}

export function deactivate(): Thenable<void> | undefined {
    if (!client) {
        return undefined;
    }
    return client.stop();
}
