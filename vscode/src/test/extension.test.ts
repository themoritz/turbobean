import * as assert from 'assert';
import * as vscode from 'vscode';
import * as path from 'path';

suite('LSP', () => {
    let projectDir: string;
    let doc: vscode.TextDocument;

    setup(async function() {
        projectDir = await openTestProject();
        doc = await openDoc(projectDir, 'main.bean');
    });

    test('Hover', async function() {
        const position = findEndOf('    Assets:Checking', doc);
        await moveTo(doc, position);

        const hovers = await vscode.commands.executeCommand<vscode.Hover[]>(
            'vscode.executeHoverProvider',
            doc.uri,
            position
        );

        assert.ok(hovers && hovers.length == 1, 'Expected one hover result');
        const contents = hovers[0].contents
            .map(c => (typeof c === 'string' ? c : c.value))
            .join('\n');
        assertContains('100.10', contents);
        assertContains('200.20', contents);
    });

    test('Highlight', async function() {
        const position = findEndOf('    Assets:Checking', doc);
        await moveTo(doc, position);

        const highlights = await vscode.commands.executeCommand<vscode.DocumentHighlight[]>(
            'vscode.executeDocumentHighlights',
            doc.uri,
            position
        );

        assert.equal(highlights.length, 9);
    });

    test('Diagnostics', async function() {
        const diagnostics = vscode.languages.getDiagnostics(doc.uri);

        assert.equal(diagnostics.length, 2);
    });
});

async function sleep(ms: number = 10) {
    return new Promise(resolve => setTimeout(resolve, ms));
}

async function openTestProject(): Promise<string> {
    const projectDir = path.resolve(__dirname, '../../../tests/project');
    const projectUri = vscode.Uri.file(projectDir);
    vscode.workspace.updateWorkspaceFolders(0, 0, { uri: projectUri });
    await sleep();
    return projectDir;
}

async function openDoc(projectDir: string, file: string): Promise<vscode.TextDocument> {
    const mainBeanPath = path.join(projectDir, file);
    const doc = await vscode.workspace.openTextDocument(mainBeanPath);
    await sleep();
    await vscode.window.showTextDocument(doc);
    await sleep();
    return doc
}

async function moveTo(doc: vscode.TextDocument, position: vscode.Position) {
    await vscode.window.showTextDocument(doc, { selection: new vscode.Range(position, position) });
    await sleep();
}

function assertContains(needle: string, haystack: string) {
    assert.ok(haystack.includes(needle), `Expected "${haystack}" to contain "${needle}"`);
}

function findEndOf(needle: string, doc: vscode.TextDocument): vscode.Position {
    const lines = doc.getText().split(/\r?\n/);
    const lineNum = lines.findIndex(l => l.includes(needle));
    assert.ok(lineNum >= 0, `Unable to find ${needle} in document`);
    const col = lines[lineNum].indexOf(needle) + needle.length - 1;
    return new vscode.Position(lineNum, col);
}
