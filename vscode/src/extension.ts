import * as vscode from 'vscode';
import * as path from 'path';
import { LanguageClientOptions, ServerOptions, LanguageClient, Executable, TransportKind } from 'vscode-languageclient/node';

let client: LanguageClient | undefined;

export function activate(context: vscode.ExtensionContext) {
    const isTest = process.env.VSCODE_TURBOBEAN_TEST === 'true';

    const exe: Executable = isTest ? {
        command: 'bash',
        args: ['-c', `${path.join(context.extensionPath, '../zig-out/bin/turbobean')} --lsp 2> >(tee ${path.join(context.extensionPath, '../turbobean-vscode.log')} >&2)`],
        transport: TransportKind.stdio,
    } : {
        command: 'turbobean',
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
        outputChannel: vscode.window.createOutputChannel('TurboBean'),
    };

    client = new LanguageClient(
        'turbobean',
        'TurboBean VSCode extension',
        serverOptions,
        clientOptions
    );

    client.start();

    context.subscriptions.push(
        vscode.commands.registerCommand('turbobean.restartServer', async () => {
            if (client) {
                await client.stop();
                client = undefined;
            }
            client = new LanguageClient(
                'turbobean',
                'TurboBean VSCode extension',
                serverOptions,
                clientOptions
            );
            client.start();
            vscode.window.showInformationMessage('TurboBean language server restarted.');
        })
    );
}

export function deactivate(): Thenable<void> | undefined {
    if (!client) {
        return undefined;
    }
    return client.stop();
}
