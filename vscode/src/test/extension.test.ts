import * as assert from 'assert';
import * as vscode from 'vscode';
import { Position, TextDocument, DiagnosticSeverity } from 'vscode';
import * as fs from 'fs/promises';
import * as path from 'path';


suite('LSP', () => {
    let doc: vscode.TextDocument;

    setup(async function() {
        doc = await openDoc('main.bean');
    });

    test('Hover on Assets:Checking', async function() {
        const pos = findInLine(doc, 10, 'Assets:Checking');
        await moveTo(doc, pos);
        const hovers = await vscode.commands.executeCommand<vscode.Hover[]>(
            'vscode.executeHoverProvider',
            doc.uri,
            pos
        );
        await assertGolden('hover-assets-checking', formatHover(hovers));
    });

    test('Highlight Assets:Checking', async function() {
        const pos = findInLine(doc, 10, 'Assets:Checking');
        await moveTo(doc, pos);
        const highlights = await vscode.commands.executeCommand<vscode.DocumentHighlight[]>(
            'vscode.executeDocumentHighlights',
            doc.uri,
            pos
        );
        await assertGolden('highlight-assets-checking', formatHighlights(doc, highlights));
    });

    test('Highlight Equity:Ope𝄞ning-Balances', async function() {
        const pos = findInLine(doc, 2, 'Equity:Ope𝄞ning-Balances');
        await moveTo(doc, pos);
        const highlights = await vscode.commands.executeCommand<vscode.DocumentHighlight[]>(
            'vscode.executeDocumentHighlights',
            doc.uri,
            pos
        );
        await assertGolden('highlight-equity-opening-balances', formatHighlights(doc, highlights));
    });

    test('Diagnostics', async function() {
        const diagnostics = vscode.languages.getDiagnostics(doc.uri);
        await assertGolden('diagnostics', formatDiagnostics(doc, diagnostics));
    });

    test('Jump to definition', async function() {
        const pos = findInLine(doc, 10, 'Assets:Checking');
        const result = await vscode.commands.executeCommand<vscode.Location[]>(
            'vscode.executeDefinitionProvider',
            doc.uri,
            pos
        );
        assert.equal(result.length, 1);
        const formatted = await formatJumpToDefinition(result[0]);
        await assertGolden('jump-to-definition', formatted);
    });

    test('Autocomplete links', async function() {
        const result = await vscode.commands.executeCommand<vscode.CompletionList>(
            'vscode.executeCompletionItemProvider',
            doc.uri,
            new Position(0, 1),
            '^'
        );
        assert.ok(result);
        const actual = result.items.map(item => String(item.label));
        const expected = [
            '^link',
            '^link1',
            '^link2',
            '^mylink'
        ];
        assert.deepStrictEqual(actual, expected);
    });

    test('Autocomplete tags', async function() {
        const result = await vscode.commands.executeCommand<vscode.CompletionList>(
            'vscode.executeCompletionItemProvider',
            doc.uri,
            new Position(0, 1),
            '#'
        );
        assert.ok(result);
        const actual = result.items.map(item => String(item.label));
        const expected = [
            '#tag',
            '#tag2'
        ];
        assert.deepStrictEqual(actual, expected);
    });

    test('Autocomplete accounts', async function() {
        const result = await vscode.commands.executeCommand<vscode.CompletionList>(
            'vscode.executeCompletionItemProvider',
            doc.uri,
            new Position(1, 1),
            null
        );
        assert.ok(result);
        const actual = result.items.map(item => String(item.label));
        const expected = [
            'Assets:Checking',
            'Assets:Foo',
            'Equity:Ope𝄞ning-Balances',
            'Expenses:Food'
        ];
        assert.deepStrictEqual(actual, expected);
    });
});


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

/**
 * Find the position of text within a specific line (0-indexed).
 * Returns the position at the start of the found text.
 */
function findInLine(doc: TextDocument, line: number, text: string): Position {
    const lineText = doc.lineAt(line).text;
    const index = lineText.indexOf(text);
    if (index === -1) {
        throw new Error(`Could not find "${text}" in line ${line + 1}: "${lineText}"`);
    }
    return new Position(line, index);
}

// ============================================================================
// Golden Test Infrastructure
// ============================================================================

function formatHighlights(doc: TextDocument, highlights: vscode.DocumentHighlight[]): string {
    // Group highlights by line
    const lineMap = new Map<number, vscode.Range[]>();
    for (const h of highlights) {
        const line = h.range.start.line;
        if (!lineMap.has(line)) {
            lineMap.set(line, []);
        }
        lineMap.get(line)!.push(h.range);
    }

    const result: string[] = [];

    for (let lineNum = 0; lineNum < doc.lineCount; lineNum++) {
        const lineText = doc.lineAt(lineNum).text;
        result.push(lineText);

        // Add underline if this line has highlights
        const ranges = lineMap.get(lineNum);
        if (ranges) {
            // Build underline string
            const underline = new Array(lineText.length).fill(' ');
            for (const range of ranges) {
                for (let j = range.start.character; j < range.end.character; j++) {
                    underline[j] = '-';
                }
            }
            result.push(underline.join('').trimEnd());
        }
    }

    return result.join('\n');
}

function formatDiagnostics(doc: TextDocument, diagnostics: vscode.Diagnostic[]): string {
    if (diagnostics.length === 0) {
        return '(no diagnostics)';
    }

    // Group by line
    const byLine = new Map<number, vscode.Diagnostic[]>();
    for (const d of diagnostics) {
        const line = d.range.start.line;
        if (!byLine.has(line)) {
            byLine.set(line, []);
        }
        byLine.get(line)!.push(d);
    }

    const result: string[] = [];

    for (let lineNum = 0; lineNum < doc.lineCount; lineNum++) {
        const lineText = doc.lineAt(lineNum).text;
        result.push(lineText);

        // Add diagnostics if this line has any
        const diags = byLine.get(lineNum);
        if (diags) {
            for (const d of diags) {
                const arrows = ' '.repeat(d.range.start.character) + '^'.repeat(d.range.end.character - d.range.start.character);
                const severity = d.severity === DiagnosticSeverity.Error ? 'Error' :
                    d.severity === DiagnosticSeverity.Warning ? 'Warn' :
                        d.severity === DiagnosticSeverity.Information ? 'Info' : 'Hint';
                result.push(`${arrows} ${severity}: ${d.message}`);
            }
        }
    }

    return result.join('\n');
}

function formatHover(hovers: vscode.Hover[]): string {
    assert.equal(hovers.length, 1);
    const contents = hovers[0].contents;
    assert.equal(contents.length, 1);
    const c = contents[0];
    const text = typeof c === 'string' ? c : c.value;

    // Undo HTML formatting
    return text.replace(/\n\n/g, '\n').replace(/&nbsp;/g, ' ').trim();
}

async function formatJumpToDefinition(location: vscode.Location): Promise<string> {
    const toFile = location.uri.fsPath.split('/').pop();
    const targetLine = location.range.start.line;

    const targetDoc = await vscode.workspace.openTextDocument(location.uri);

    const result: string[] = [];
    result.push(`${toFile}:${targetLine + 1}:${location.range.start.character}`);
    result.push('');

    // Show entire destination file with marker on target line
    for (let i = 0; i < targetDoc.lineCount; i++) {
        const lineText = targetDoc.lineAt(i).text;
        const prefix = i === targetLine ? '>' : ' ';
        result.push(`${prefix} ${lineText}`);
    }

    return result.join('\n');
}

/**
 * Compare actual output with expected golden file.
 * If ACCEPT=true, update the expected file with actual output.
 */
async function assertGolden(testName: string, actual: string) {
    const root = vscode.workspace.workspaceFolders![0].uri.fsPath;
    const expectedPath = path.join(root, 'expected', `${testName}.txt`);

    const acceptMode = process.env.ACCEPT === 'true';

    if (acceptMode) {
        await fs.mkdir(path.dirname(expectedPath), { recursive: true });
        await fs.writeFile(expectedPath, actual, 'utf-8');
        return;
    }

    let expected: string;
    try {
        expected = await fs.readFile(expectedPath, 'utf-8');
    } catch (err) {
        assert.fail(`Expected file not found: ${expectedPath}\n\nRun with ACCEPT=true to create it.\n\nActual output:\n${actual}`);
    }

    const normalizeActual = actual.trim().replace(/\r\n/g, '\n');
    const normalizeExpected = expected.trim().replace(/\r\n/g, '\n');

    assert.equal(normalizeActual, normalizeExpected, `Golden test failed: ${testName}\nRun with ACCEPT=true to update expected output.`);
}
