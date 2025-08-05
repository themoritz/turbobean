import * as assert from 'assert';
import * as vscode from 'vscode';
import { Position, TextDocument, DiagnosticSeverity } from 'vscode';

suite('LSP', () => {
    let doc: vscode.TextDocument;

    setup(async function() {
        doc = await openDoc('main.bean');
    });

    test('Hover', async function() {
        // Assets:Checking
        await testHover(doc, new Position(10, 4), (contents) => {
            assertContains('100.10', contents);
            assertContains('200.20', contents);
        });
    });

    test('Highlight', async function() {
        // Assets:Checking
        await testHighlight(doc, new Position(10, 4), [
            toRange(7, 16, 31),
            toRange(10, 4, 19),
            toRange(14, 4, 19),
            toRange(18, 4, 19),
            toRange(22, 4, 19),
            toRange(26, 4, 19),
        ]);

        // Equity:Ope𝄞ning-Balances
        await testHighlight(doc, new Position(2, 30), [
            toRange(2, 29, 54),
            toRange(3, 16, 41),
            toRange(30, 26, 51),
            toRange(34, 26, 51),
        ]);
    });

    test('Diagnostics', async function() {
        testDiagnostics(doc, [
            {
                prefix: "Flagged",
                range: toRange(9, 11, 12),
                severity: DiagnosticSeverity.Warning
            },
        ]);
    });

    test('Jump to definition', async function() {
        await testJumpToDefinition(doc, new Position(10, 4), 'open.bean', 0, 0);
    });

    test('Autocomplete', async function() {
        // Links
        await testAutocomplete(doc, new Position(0, 1), "^", 0, 1, [
            '^link',
            '^link1',
            '^link2',
            '^mylink'
        ]);
        // Tags
        await testAutocomplete(doc, new Position(0, 1), "#", 0, 1, [
            '#tag',
            '#tag2'
        ]);
        // Accounts
        await testAutocomplete(doc, new Position(1, 1), null, 0, 0, [
            'Assets:Checking',
            'Assets:Foo',
            'Equity:Ope𝄞ning-Balances',
            'Expenses:Food'
        ]);
        await testAutocomplete(doc, new Position(7, 20), null, 16, 31, [
            'Assets:Checking',
            'Assets:Foo',
            'Equity:Ope𝄞ning-Balances',
            'Expenses:Food'
        ]);
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

async function testJumpToDefinition(doc: TextDocument, pos: Position, file: string, line: number, char: number) {
    const result = await vscode.commands.executeCommand<vscode.Location[]>(
        'vscode.executeDefinitionProvider',
        doc.uri,
        pos
    );
    assert.equal(result.length, 1);
    const path = result[0].uri.fsPath;
    assert.ok(path.endsWith(file), `"${path}" should end with "${file}"`);
    assert.equal(result[0].range.start.line, line);
    assert.equal(result[0].range.start.character, char);
}

async function testAutocomplete(doc: TextDocument, pos: Position, trigger: string | null, exp_start: number, exp_end: number, expected: string[]) {
    const result = await vscode.commands.executeCommand<vscode.CompletionList>(
        'vscode.executeCompletionItemProvider',
        doc.uri,
        pos,
        trigger,
    );
    if (!result) {
        throw new Error('No result');
    }
    assert.equal(result.items.length, expected.length, JSON.stringify(result));
    result.items.forEach((item, i) => {
        const range = 'start' in item.range! ? item.range! : item.range!.inserting;
        assert.equal(range.start.character, exp_start);
        assert.equal(range.end.character, exp_end);
        assert.equal(item.label, expected[i]);
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
