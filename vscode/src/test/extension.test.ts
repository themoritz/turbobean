import * as assert from 'assert';
import * as vscode from 'vscode';
import { Position, TextDocument, DiagnosticSeverity } from 'vscode';

suite('LSP', () => {
    let doc: vscode.TextDocument;

    setup(async function() {
        doc = await openDoc('main.bean');
    });

    test('Hover', async function() {
        await testHover(doc, new Position(10, 4), (contents) => {
            assertContains('100.10', contents);
            assertContains('200.20', contents);
        });
    });

    test('Highlight', async function() {
        await testHighlight(doc, new Position(10, 4), [
            toRange(7, 16, 31),
            toRange(10, 4, 19),
            toRange(14, 4, 19),
            toRange(18, 4, 19),
            toRange(22, 4, 19),
            toRange(26, 4, 19),
        ]);

        await testHighlight(doc, new Position(2, 17), [
            toRange(2, 15, 40),
        ]);

        await testHighlight(doc, new Position(3, 17), [
            toRange(3, 16, 39),
        ]);
    });

    test('Diagnostics', async function() {
        testDiagnostics(doc, [
            {
                prefix: "Invalid date",
                range: toRange(29, 0, 10),
                severity: DiagnosticSeverity.Error
            },
            {
                prefix: "Account is not open",
                range: toRange(3, 16, 39),
                severity: DiagnosticSeverity.Warning
            },
        ])
    });
});

async function testHover(doc: TextDocument, pos: Position, check: (contents: string) => void) {
    await moveTo(doc, pos);
    const hovers = await vscode.commands.executeCommand<vscode.Hover[]>(
        'vscode.executeHoverProvider',
        doc.uri,
        pos
    );
    assert.equal(hovers.length, 1);
    const contents = hovers[0].contents
        .map(c => (typeof c === 'string' ? c : c.value))
        .join('\n');
    check(contents);
}

async function testHighlight(doc: TextDocument, pos: Position, expectedRanges: vscode.Range[]) {
    await moveTo(doc, pos);
    const actualHighlights = await vscode.commands.executeCommand<vscode.DocumentHighlight[]>(
        'vscode.executeDocumentHighlights',
        doc.uri,
        pos
    );
    assert.equal(actualHighlights.length, expectedRanges.length);
    expectedRanges.forEach((expected, i) => {
        const actual = actualHighlights[i].range;
        assert.deepEqual(expected, actual);
    });
}

function testDiagnostics(doc: TextDocument, expected: any[]) {
    const diagnostics = vscode.languages.getDiagnostics(doc.uri);
    assert.equal(diagnostics.length, expected.length);
    expected.forEach((e, i) => {
        const a = diagnostics[i];
        assert.ok(a.message.startsWith(e.prefix), `"${a.message}" should start with "${e.prefix}"`);
        assert.deepEqual(e.range, a.range);
        assert.equal(e.severity, a.severity);
    });
}

async function sleep(ms: number = 10) {
    return new Promise(resolve => setTimeout(resolve, ms));
}

async function openDoc(file: string): Promise<TextDocument> {
    const root = vscode.workspace.workspaceFolders![0].uri;
    const uri = vscode.Uri.joinPath(root, file);
    const doc = await vscode.workspace.openTextDocument(uri);
    await sleep();
    await vscode.window.showTextDocument(doc);
    await sleep();
    return doc;
}

async function moveTo(doc: TextDocument, position: Position) {
    await vscode.window.showTextDocument(doc, { selection: new vscode.Range(position, position) });
    await sleep();
}

function assertContains(needle: string, haystack: string) {
    assert.ok(haystack.includes(needle), `Expected "${haystack}" to contain "${needle}"`);
}

function toRange(line: number, sChar: number, eChar: number) {
    const start = new vscode.Position(line, sChar);
    const end = new vscode.Position(line, eChar);
    return new vscode.Range(start, end);
}
